#!/bin/bash
# Idempotent setup for the HubSpot -> GCS -> BigQuery raw/current loader.
# Do not run until the baseline and intended IAM delta are approved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

HUBSPOT_BQ_DATASET="${HUBSPOT_BQ_DATASET:-dl_hubspot}"
HUBSPOT_BQ_STAGING_DATASET="${HUBSPOT_BQ_STAGING_DATASET:-dl_hubspot_staging}"
HUBSPOT_RAW_BUCKET="${HUBSPOT_RAW_BUCKET:-wingtra-dwh-hubspot-raw}"
HUBSPOT_RAW_RETENTION_DAYS="${HUBSPOT_RAW_RETENTION_DAYS:-180}"
HUBSPOT_ARTIFACT_REPO="${HUBSPOT_ARTIFACT_REPO:-crm-pipelines}"
HUBSPOT_SERVICE_KEY_SECRET="${HUBSPOT_SERVICE_KEY_SECRET:-${HUBSPOT_ACCESS_TOKEN_SECRET:-${HUBSPOT_PRIVATE_APP_TOKEN_SECRET:-hubspot-service-key}}}"
SA_NAME="${HUBSPOT_RAW_LOADER_SA_NAME:-hubspot-raw-loader}"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "=== HubSpot raw loader infrastructure setup ==="
echo "Project:        ${PROJECT}"
echo "Region:         ${REGION}"
echo "Datasets:       ${HUBSPOT_BQ_DATASET}, ${HUBSPOT_BQ_STAGING_DATASET}"
echo "Raw bucket:     gs://${HUBSPOT_RAW_BUCKET}"
echo "Raw retention:  ${HUBSPOT_RAW_RETENTION_DAYS} days"
echo "Artifact repo:  ${HUBSPOT_ARTIFACT_REPO}"
echo "Runtime SA:     ${SA}"
echo "Secret:         ${HUBSPOT_SERVICE_KEY_SECRET}"
echo ""

echo "--- Baseline checks before mutation ---"
gcloud iam service-accounts describe "${SA}" --project="${PROJECT}" || true
bq --location="${REGION}" show "${PROJECT}:${HUBSPOT_BQ_DATASET}" || true
bq --location="${REGION}" show "${PROJECT}:${HUBSPOT_BQ_STAGING_DATASET}" || true
gcloud storage buckets describe "gs://${HUBSPOT_RAW_BUCKET}" --project="${PROJECT}" || true
gcloud secrets describe "${HUBSPOT_SERVICE_KEY_SECRET}" --project="${PROJECT}" || true

echo "--- Enabling APIs ---"
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  monitoring.googleapis.com \
  --project="${PROJECT}"

echo "--- BigQuery datasets ---"
for dataset in "${HUBSPOT_BQ_DATASET}" "${HUBSPOT_BQ_STAGING_DATASET}"; do
  if bq --location="${REGION}" show "${PROJECT}:${dataset}" >/dev/null 2>&1; then
    echo "Dataset ${dataset} already exists."
  else
    bq --location="${REGION}" mk -d \
      --description="HubSpot loader dataset (${dataset})." \
      "${PROJECT}:${dataset}"
  fi
done

echo "--- GCS raw landing bucket ---"
if gcloud storage buckets describe "gs://${HUBSPOT_RAW_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Bucket gs://${HUBSPOT_RAW_BUCKET} already exists."
else
  gcloud storage buckets create "gs://${HUBSPOT_RAW_BUCKET}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi
lifecycle_file="$(mktemp)"
cat > "${lifecycle_file}" <<JSON
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": ${HUBSPOT_RAW_RETENTION_DAYS}}
    }
  ]
}
JSON
gcloud storage buckets update "gs://${HUBSPOT_RAW_BUCKET}" \
  --project="${PROJECT}" \
  --lifecycle-file="${lifecycle_file}" >/dev/null
rm -f "${lifecycle_file}"

echo "--- Artifact Registry repo ---"
if gcloud artifacts repositories describe "${HUBSPOT_ARTIFACT_REPO}" \
    --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Repo ${HUBSPOT_ARTIFACT_REPO} already exists."
else
  gcloud artifacts repositories create "${HUBSPOT_ARTIFACT_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --project="${PROJECT}"
fi

echo "--- Service account ---"
if gcloud iam service-accounts describe "${SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Service account ${SA} already exists."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="HubSpot Raw Loader" \
    --project="${PROJECT}"
fi

echo "--- Secret container ---"
if gcloud secrets describe "${HUBSPOT_SERVICE_KEY_SECRET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Secret ${HUBSPOT_SERVICE_KEY_SECRET} already exists."
else
  gcloud secrets create "${HUBSPOT_SERVICE_KEY_SECRET}" \
    --replication-policy=automatic \
    --project="${PROJECT}"
  echo "Created empty secret container. Add the HubSpot service key as a secret version separately."
fi

echo "--- Scoped IAM roles ---"
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet

for dataset in "${HUBSPOT_BQ_DATASET}" "${HUBSPOT_BQ_STAGING_DATASET}"; do
  metadata_file="$(mktemp)"
  bq --format=prettyjson show "${PROJECT}:${dataset}" > "${metadata_file}"
  python3 - "${metadata_file}" "${SA}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
service_account = sys.argv[2]
metadata = json.loads(path.read_text())
access = metadata.setdefault("access", [])
entry = {"role": "WRITER", "userByEmail": service_account}
if entry not in access:
    access.append(entry)
path.write_text(json.dumps(metadata, indent=2, sort_keys=True))
PY
  bq --quiet update --dataset --source "${metadata_file}" "${PROJECT}:${dataset}" >/dev/null
  rm -f "${metadata_file}"
done

gcloud storage buckets add-iam-policy-binding "gs://${HUBSPOT_RAW_BUCKET}" \
  --project="${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/storage.objectCreator" \
  --quiet

gcloud secrets add-iam-policy-binding "${HUBSPOT_SERVICE_KEY_SECRET}" \
  --project="${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet >/dev/null

echo "--- Removing accidental broad runtime roles if present ---"
for role in \
  roles/bigquery.dataEditor \
  roles/storage.admin \
  roles/storage.objectAdmin \
  roles/secretmanager.secretAccessor \
  roles/run.invoker; do
    gcloud projects remove-iam-policy-binding "${PROJECT}" \
      --member="serviceAccount:${SA}" \
      --role="${role}" \
      --condition=None \
      --quiet >/dev/null 2>&1 || true
done

echo ""
echo "=== Done ==="
echo "Add the HubSpot service key as a secret version, then run infra/deploy.sh."
