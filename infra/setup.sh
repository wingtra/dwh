#!/bin/bash
set -euo pipefail

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

SA="odoo-pipeline@${PROJECT}.iam.gserviceaccount.com"
ODOO_BQ_DATASET="${ODOO_BQ_DATASET:-dl_odoo}"
ODOO_BQ_STAGING_DATASET="${ODOO_BQ_STAGING_DATASET:-dl_odoo_staging}"
ODOO_BQ_LOCATION="${ODOO_BQ_LOCATION:-${REGION}}"

echo "=== Phase 1: GCP Infrastructure Setup ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo ""

# 1. Enable APIs
echo "--- Enabling APIs ---"
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com

# 2. GCS bucket for backup archive
echo "--- Creating GCS bucket ---"
if gcloud storage buckets describe "gs://${PROJECT}-odoo-backups" &>/dev/null; then
  echo "Bucket gs://${PROJECT}-odoo-backups already exists, skipping."
else
  gcloud storage buckets create "gs://${PROJECT}-odoo-backups" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi

echo "Applying lifecycle policy..."
gcloud storage buckets update "gs://${PROJECT}-odoo-backups" \
  --lifecycle-file="${SCRIPT_DIR}/lifecycle.json"

# 3. BigQuery datasets
echo "--- Creating BigQuery datasets ---"
for dataset in "${ODOO_BQ_DATASET}" "${ODOO_BQ_STAGING_DATASET}"; do
  if bq show "${PROJECT}:${dataset}" &>/dev/null; then
    echo "Dataset ${dataset} already exists, skipping."
  else
    if [[ "${dataset}" == "${ODOO_BQ_STAGING_DATASET}" ]]; then
      description="Staging Odoo data used for validated upsert promotion"
    else
      description="Raw Odoo data, refreshed daily via upsert promotion"
    fi
    bq --location="${ODOO_BQ_LOCATION}" mk -d --description="${description}" \
      "${PROJECT}:${dataset}"
  fi
done

# 4. Artifact Registry repo
echo "--- Creating Artifact Registry repo ---"
if gcloud artifacts repositories describe odoo-pipeline --location="${REGION}" &>/dev/null; then
  echo "Repo odoo-pipeline already exists, skipping."
else
  gcloud artifacts repositories create odoo-pipeline \
    --repository-format=docker \
    --location="${REGION}"
fi

# 5. Service account + IAM
echo "--- Creating service account ---"
if gcloud iam service-accounts describe "${SA}" &>/dev/null; then
  echo "Service account ${SA} already exists, skipping creation."
else
  gcloud iam service-accounts create odoo-pipeline \
    --display-name="Odoo Pipeline Runner"
fi

# 6. SSH key secret
echo "--- Storing SSH key in Secret Manager ---"
if gcloud secrets describe odoo-sh-ssh-key &>/dev/null; then
  echo "Secret odoo-sh-ssh-key already exists, skipping."
else
  gcloud secrets create odoo-sh-ssh-key --replication-policy=automatic
  gcloud secrets versions add odoo-sh-ssh-key \
    --data-file="${SCRIPT_DIR}/odoo_sh_id_ed25519"
fi

# 7. Least-privilege IAM for the runtime service account.
echo "--- Binding scoped IAM roles ---"
gcloud secrets add-iam-policy-binding odoo-sh-ssh-key \
  --project="${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --quiet

gcloud storage buckets add-iam-policy-binding "gs://${PROJECT}-odoo-backups" \
  --member="serviceAccount:${SA}" \
  --role="roles/storage.objectCreator" \
  --quiet

gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA}" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  --quiet

for dataset in "${ODOO_BQ_DATASET}" "${ODOO_BQ_STAGING_DATASET}"; do
  python3 "${SCRIPT_DIR}/set_bq_dataset_iam.py" \
    --project="${PROJECT}" \
    --dataset="${dataset}" \
    --member="serviceAccount:${SA}" \
    --role="roles/bigquery.dataEditor"
done

echo "--- Removing legacy broad project IAM roles if present ---"
for role in \
  roles/secretmanager.secretAccessor \
  roles/storage.objectAdmin \
  roles/bigquery.dataEditor \
  roles/run.invoker; do
    gcloud projects remove-iam-policy-binding "${PROJECT}" \
      --member="serviceAccount:${SA}" \
      --role="${role}" \
      --condition=None \
      --quiet >/dev/null 2>&1 || true
done

echo "Keep project-level roles/bigquery.jobUser; BigQuery jobs are project-scoped."

echo ""
echo "=== Phase 1 Complete ==="
echo ""
echo "Verification:"
echo "  gcloud storage buckets list --filter='name:${PROJECT}-odoo-backups'"
echo "  bq ls ${PROJECT}:${ODOO_BQ_DATASET}"
echo "  bq ls ${PROJECT}:${ODOO_BQ_STAGING_DATASET}"
echo "  gcloud iam service-accounts describe ${SA}"
echo "  gcloud secrets list --filter='name:odoo-sh-ssh-key'"
echo "  gcloud artifacts repositories list --location=${REGION}"
