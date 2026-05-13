#!/bin/bash
set -euo pipefail

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

SA="odoo-pipeline@${PROJECT}.iam.gserviceaccount.com"

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

# 3. BigQuery dataset
echo "--- Creating BigQuery dataset ---"
if bq show "${PROJECT}:dl_odoo" &>/dev/null; then
  echo "Dataset dl_odoo already exists, skipping."
else
  bq --location="${REGION}" mk -d --description="Raw Odoo data, refreshed daily" \
    "${PROJECT}:dl_odoo"
fi

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

echo "Binding IAM roles..."
for role in \
  roles/secretmanager.secretAccessor \
  roles/storage.objectAdmin \
  roles/bigquery.dataEditor \
  roles/bigquery.jobUser \
  roles/run.invoker; do
    gcloud projects add-iam-policy-binding "${PROJECT}" \
      --member="serviceAccount:${SA}" --role="${role}" \
      --condition=None --quiet
done

# 6. SSH key secret
echo "--- Storing SSH key in Secret Manager ---"
if gcloud secrets describe odoo-sh-ssh-key &>/dev/null; then
  echo "Secret odoo-sh-ssh-key already exists, skipping."
else
  gcloud secrets create odoo-sh-ssh-key --replication-policy=automatic
  gcloud secrets versions add odoo-sh-ssh-key \
    --data-file="${SCRIPT_DIR}/odoo_sh_id_ed25519"
fi

echo ""
echo "=== Phase 1 Complete ==="
echo ""
echo "Verification:"
echo "  gcloud storage buckets list --filter='name:${PROJECT}-odoo-backups'"
echo "  bq ls ${PROJECT}:dl_odoo"
echo "  gcloud iam service-accounts describe ${SA}"
echo "  gcloud secrets list --filter='name:odoo-sh-ssh-key'"
echo "  gcloud artifacts repositories list --location=${REGION}"
