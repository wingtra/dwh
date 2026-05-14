#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/odoo-pipeline/runner:latest"
SA="odoo-pipeline@${PROJECT}.iam.gserviceaccount.com"

echo "=== Phase 3: Build & Deploy ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Image:   ${IMAGE}"
echo ""

# 1. Build and push image via Cloud Build
echo "--- Building and pushing image ---"
gcloud builds submit \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --tag="${IMAGE}" \
  "${SCRIPT_DIR}/.."

# 2. Deploy Cloud Run Job
echo "--- Deploying Cloud Run Job ---"
gcloud run jobs deploy odoo-to-bq \
  --project="${PROJECT}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --service-account="${SA}" \
  --set-env-vars="\
GCP_PROJECT=${PROJECT},\
GCS_BUCKET=${PROJECT}-odoo-backups,\
ODOO_SSH_HOST=${ODOO_SSH_HOST},\
ODOO_SSH_USER=${ODOO_SSH_USER},\
BQ_DATASET=dl_odoo,\
PG_DATABASE=odoo_restore,\
PG_USER=postgres" \
  --task-timeout=3600 \
  --max-retries=1 \
  --memory=16Gi \
  --cpu=4

echo ""
echo "=== Phase 3 Complete ==="
echo ""
echo "Verification:"
echo "  gcloud run jobs describe odoo-to-bq --region=${REGION} --project=${PROJECT}"
echo "  gcloud run jobs execute odoo-to-bq --region=${REGION} --project=${PROJECT} --wait"
