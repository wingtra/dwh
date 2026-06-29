#!/bin/bash
# Idempotent setup for the Revolut Business API -> GCS -> BigQuery raw loader.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

REVOLUT_BQ_DATASET="${REVOLUT_BQ_DATASET:-dl_revolut}"
REVOLUT_RAW_BUCKET="${REVOLUT_RAW_BUCKET:-${PROJECT}-revolut-raw}"
REVOLUT_PRIVATE_KEY_SECRET="${REVOLUT_PRIVATE_KEY_SECRET:-revolut-business-api-private-key}"
REVOLUT_REFRESH_TOKEN_SECRET="${REVOLUT_REFRESH_TOKEN_SECRET:-revolut-business-api-refresh-token}"
ARTIFACT_REPO="${REVOLUT_ARTIFACT_REPO:-finance-pipelines}"
SA_NAME="${REVOLUT_RAW_LOADER_SA_NAME:-revolut-raw-loader}"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "=== Revolut raw loader infrastructure setup ==="
echo "Project:        ${PROJECT}"
echo "Region:         ${REGION}"
echo "Dataset:        ${REVOLUT_BQ_DATASET}"
echo "Raw bucket:     gs://${REVOLUT_RAW_BUCKET}"
echo "Artifact repo:  ${ARTIFACT_REPO}"
echo "Service account:${SA}"
echo ""

echo "--- Enabling APIs ---"
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT}"

echo "--- BigQuery dataset ---"
if bq --location="${REGION}" show "${PROJECT}:${REVOLUT_BQ_DATASET}" >/dev/null 2>&1; then
  echo "Dataset ${REVOLUT_BQ_DATASET} already exists."
else
  bq --location="${REGION}" mk -d \
    --description="Append-only raw Revolut Business API extracts." \
    "${PROJECT}:${REVOLUT_BQ_DATASET}"
fi

echo "--- BigQuery raw table compatibility columns ---"
add_column_if_table_exists() {
  local table="$1"
  local column="$2"
  local type="$3"

  if bq --location="${REGION}" show "${PROJECT}:${REVOLUT_BQ_DATASET}.${table}" >/dev/null 2>&1; then
    bq query --project_id="${PROJECT}" --location="${REGION}" --use_legacy_sql=false \
      "alter table \`${PROJECT}.${REVOLUT_BQ_DATASET}.${table}\` add column if not exists ${column} ${type}" >/dev/null
  else
    echo "Table ${REVOLUT_BQ_DATASET}.${table} does not exist yet; raw loader will create it."
  fi
}

for spec in \
  "run_id:string" \
  "extracted_at:timestamp" \
  "request_from_created_at:timestamp" \
  "request_to_created_at:timestamp" \
  "page_number:int64" \
  "row_index:int64" \
  "gcs_uri:string" \
  "leg_amount_raw:string" \
  "leg_amount_numeric:numeric" \
  "leg_fee_raw:string" \
  "leg_fee_numeric:numeric" \
  "bill_amount_raw:string" \
  "bill_amount_numeric:numeric" \
  "balance_raw:string" \
  "balance_numeric:numeric"; do
  add_column_if_table_exists transactions "${spec%%:*}" "${spec##*:}"
done

for spec in \
  "run_id:string" \
  "extracted_at:timestamp" \
  "gcs_uri:string" \
  "balance_raw:string" \
  "balance_numeric:numeric" \
  "account_raw_json:json"; do
  add_column_if_table_exists accounts "${spec%%:*}" "${spec##*:}"
done

echo "--- GCS raw landing bucket ---"
if gcloud storage buckets describe "gs://${REVOLUT_RAW_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Bucket gs://${REVOLUT_RAW_BUCKET} already exists."
else
  gcloud storage buckets create "gs://${REVOLUT_RAW_BUCKET}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi

echo "--- Artifact Registry repo ---"
if gcloud artifacts repositories describe "${ARTIFACT_REPO}" \
    --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Repo ${ARTIFACT_REPO} already exists."
else
  gcloud artifacts repositories create "${ARTIFACT_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --project="${PROJECT}"
fi

echo "--- Service account ---"
if gcloud iam service-accounts describe "${SA}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Service account ${SA} already exists."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Revolut Raw Loader" \
    --project="${PROJECT}"
fi

echo "--- IAM roles ---"
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet

metadata_file="$(mktemp)"
bq --format=prettyjson show "${PROJECT}:${REVOLUT_BQ_DATASET}" > "${metadata_file}"
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
bq --quiet update --dataset --source "${metadata_file}" "${PROJECT}:${REVOLUT_BQ_DATASET}" >/dev/null
rm -f "${metadata_file}"

gcloud storage buckets add-iam-policy-binding "gs://${REVOLUT_RAW_BUCKET}" \
  --project="${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/storage.objectCreator" \
  --quiet

for secret in "${REVOLUT_PRIVATE_KEY_SECRET}" "${REVOLUT_REFRESH_TOKEN_SECRET}"; do
  if gcloud secrets describe "${secret}" --project="${PROJECT}" >/dev/null 2>&1; then
    echo "Secret ${secret} already exists."
  else
    gcloud secrets create "${secret}" \
      --replication-policy=automatic \
      --project="${PROJECT}"
    echo "Created empty secret container: ${secret}"
  fi
  gcloud secrets add-iam-policy-binding "${secret}" \
    --project="${PROJECT}" \
    --member="serviceAccount:${SA}" \
    --role="roles/secretmanager.secretAccessor" \
    --quiet >/dev/null
done

echo ""
echo "=== Done ==="
echo "Next: run infra/deploy.sh after REVOLUT_CLIENT_ID and REVOLUT_JWT_ISSUER are set."
