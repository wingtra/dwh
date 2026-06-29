#!/bin/bash
# Build and deploy the dedicated Revolut raw loader Cloud Run Job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

REVOLUT_BQ_DATASET="${REVOLUT_BQ_DATASET:-dl_revolut}"
REVOLUT_RAW_BUCKET="${REVOLUT_RAW_BUCKET:-${PROJECT}-revolut-raw}"
REVOLUT_RAW_PREFIX="${REVOLUT_RAW_PREFIX:-revolut}"
REVOLUT_CLIENT_ID="${REVOLUT_CLIENT_ID:?REVOLUT_CLIENT_ID must be set in infra/config.env}"
REVOLUT_JWT_ISSUER="${REVOLUT_JWT_ISSUER:?REVOLUT_JWT_ISSUER must be set in infra/config.env}"
REVOLUT_PRIVATE_KEY_SECRET="${REVOLUT_PRIVATE_KEY_SECRET:-revolut-business-api-private-key}"
REVOLUT_REFRESH_TOKEN_SECRET="${REVOLUT_REFRESH_TOKEN_SECRET:-revolut-business-api-refresh-token}"
REVOLUT_START_CREATED_AT="${REVOLUT_START_CREATED_AT:-2026-01-01T00:00:00Z}"
REVOLUT_LOOKBACK_DAYS="${REVOLUT_LOOKBACK_DAYS:-31}"
REVOLUT_PAGE_SIZE="${REVOLUT_PAGE_SIZE:-1000}"
REVOLUT_MAX_PAGES="${REVOLUT_MAX_PAGES:-100}"
ARTIFACT_REPO="${REVOLUT_ARTIFACT_REPO:-finance-pipelines}"
SA_NAME="${REVOLUT_RAW_LOADER_SA_NAME:-revolut-raw-loader}"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
JOB_NAME="${REVOLUT_RAW_LOADER_JOB_NAME:-revolut-raw-loader}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/revolut-raw-loader:latest"

echo "=== Deploy Revolut raw loader job ==="
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
REVOLUT_BQ_DATASET=${REVOLUT_BQ_DATASET},\
REVOLUT_RAW_BUCKET=${REVOLUT_RAW_BUCKET},\
REVOLUT_RAW_PREFIX=${REVOLUT_RAW_PREFIX},\
REVOLUT_CLIENT_ID=${REVOLUT_CLIENT_ID},\
REVOLUT_JWT_ISSUER=${REVOLUT_JWT_ISSUER},\
REVOLUT_PRIVATE_KEY_SECRET=${REVOLUT_PRIVATE_KEY_SECRET},\
REVOLUT_REFRESH_TOKEN_SECRET=${REVOLUT_REFRESH_TOKEN_SECRET},\
REVOLUT_START_CREATED_AT=${REVOLUT_START_CREATED_AT},\
REVOLUT_LOOKBACK_DAYS=${REVOLUT_LOOKBACK_DAYS},\
REVOLUT_PAGE_SIZE=${REVOLUT_PAGE_SIZE},\
REVOLUT_MAX_PAGES=${REVOLUT_MAX_PAGES}" \
  --task-timeout=1800 \
  --max-retries=1 \
  --memory=1Gi \
  --cpu=1

echo ""
echo "=== Done ==="
echo "Manual execution:"
echo "  gcloud run jobs execute ${JOB_NAME} --region=${REGION} --project=${PROJECT} --wait"
