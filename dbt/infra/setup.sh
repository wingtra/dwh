#!/usr/bin/env bash
# Idempotent setup for the generic dbt Cloud Run Job infrastructure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

ARTIFACT_REPO="${DBT_ARTIFACT_REPO:-warehouse-pipelines}"
SA_NAME="${DBT_SA_NAME:-dbt-runner}"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "=== dbt runner infrastructure setup ==="
echo "Project:       ${PROJECT}"
echo "Region:        ${REGION}"
echo "Artifact repo: ${ARTIFACT_REPO}"
echo "Service acct:  ${SA}"
echo

echo "--- Enabling APIs ---"
gcloud services enable \
  run.googleapis.com \
  bigquery.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  --project="${PROJECT}"

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
    --display-name="dbt Runner" \
    --project="${PROJECT}"
fi

echo "--- Project IAM ---"
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet

grant_dataset_access() {
  local dataset="$1"
  local role="$2"

  if ! bq --location="${REGION}" show "${PROJECT}:${dataset}" >/dev/null 2>&1; then
    echo "Dataset ${dataset} does not exist; skipping ${role} grant."
    return
  fi

  local metadata_file
  metadata_file="$(mktemp)"

  bq --format=prettyjson show "${PROJECT}:${dataset}" > "${metadata_file}"
  python3 - "${metadata_file}" "${SA}" "${role}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
service_account = sys.argv[2]
role = sys.argv[3]
metadata = json.loads(path.read_text())
access = metadata.setdefault("access", [])
entry = {"role": role, "userByEmail": service_account}
if entry not in access:
    access.append(entry)
path.write_text(json.dumps(metadata, indent=2, sort_keys=True))
PY
  bq --quiet update --dataset --source "${metadata_file}" "${PROJECT}:${dataset}" >/dev/null
  rm -f "${metadata_file}"
}

echo "--- Dataset IAM ---"
IFS=',' read -r -a read_datasets <<< "${DBT_READ_DATASETS:-}"
for dataset in "${read_datasets[@]}"; do
  [[ -n "${dataset}" ]] || continue
  grant_dataset_access "${dataset}" READER
done

IFS=',' read -r -a write_datasets <<< "${DBT_WRITE_DATASETS:-}"
for dataset in "${write_datasets[@]}"; do
  [[ -n "${dataset}" ]] || continue
  grant_dataset_access "${dataset}" WRITER
done

echo
echo "=== Done ==="
echo "Next: run dbt/infra/deploy.sh to deploy the dbt runner job."
