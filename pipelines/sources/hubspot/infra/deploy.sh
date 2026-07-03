#!/bin/bash
# Build and deploy the dedicated HubSpot raw loader Cloud Run Job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

HUBSPOT_BQ_DATASET="${HUBSPOT_BQ_DATASET:-dl_hubspot}"
HUBSPOT_BQ_STAGING_DATASET="${HUBSPOT_BQ_STAGING_DATASET:-dl_hubspot_staging}"
HUBSPOT_RAW_BUCKET="${HUBSPOT_RAW_BUCKET:?HUBSPOT_RAW_BUCKET must be set}"
HUBSPOT_RAW_PREFIX="${HUBSPOT_RAW_PREFIX:-hubspot}"
HUBSPOT_SERVICE_KEY_SECRET="${HUBSPOT_SERVICE_KEY_SECRET:-${HUBSPOT_ACCESS_TOKEN_SECRET:-${HUBSPOT_PRIVATE_APP_TOKEN_SECRET:-hubspot-service-key}}}"
HUBSPOT_START_AT="${HUBSPOT_START_AT:-2026-01-01T00:00:00Z}"
HUBSPOT_LOOKBACK_DAYS="${HUBSPOT_LOOKBACK_DAYS:-14}"
HUBSPOT_PAGE_SIZE="${HUBSPOT_PAGE_SIZE:-100}"
HUBSPOT_RUN_MODE="${HUBSPOT_RUN_MODE:-incremental}"
ARTIFACT_REPO="${HUBSPOT_ARTIFACT_REPO:-crm-pipelines}"
SA_NAME="${HUBSPOT_RAW_LOADER_SA_NAME:-hubspot-raw-loader}"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
JOB_NAME="${HUBSPOT_RAW_LOADER_JOB_NAME:-hubspot-raw-loader}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/hubspot-raw-loader:latest"

echo "=== Deploy HubSpot raw loader job ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Image:   ${IMAGE}"
echo "Job:     ${JOB_NAME}"
echo ""

echo "--- Building and pushing image ---"
gcloud builds submit \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --config="${SOURCE_DIR}/cloudbuild.yaml" \
  --substitutions="_IMAGE=${IMAGE}" \
  "${SOURCE_DIR}"

echo "--- Deploying Cloud Run Job ---"
gcloud run jobs deploy "${JOB_NAME}" \
  --project="${PROJECT}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --service-account="${SA}" \
  --set-env-vars="\
GCP_PROJECT=${PROJECT},\
BQ_LOCATION=${REGION},\
HUBSPOT_BQ_DATASET=${HUBSPOT_BQ_DATASET},\
HUBSPOT_BQ_STAGING_DATASET=${HUBSPOT_BQ_STAGING_DATASET},\
HUBSPOT_RAW_BUCKET=${HUBSPOT_RAW_BUCKET},\
HUBSPOT_RAW_PREFIX=${HUBSPOT_RAW_PREFIX},\
HUBSPOT_SERVICE_KEY_SECRET=${HUBSPOT_SERVICE_KEY_SECRET},\
HUBSPOT_START_AT=${HUBSPOT_START_AT},\
HUBSPOT_LOOKBACK_DAYS=${HUBSPOT_LOOKBACK_DAYS},\
HUBSPOT_PAGE_SIZE=${HUBSPOT_PAGE_SIZE},\
HUBSPOT_RUN_MODE=${HUBSPOT_RUN_MODE}" \
  --task-timeout=1800 \
  --max-retries=2 \
  --memory=2Gi \
  --cpu=1

echo ""
echo "=== Done ==="
echo "Manual execution:"
echo "  gcloud run jobs execute ${JOB_NAME} --region=${REGION} --project=${PROJECT} --wait"
