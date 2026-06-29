#!/usr/bin/env bash
# Build and deploy the generic dbt Cloud Run Job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/config.env"

ARTIFACT_REPO="${DBT_ARTIFACT_REPO:-warehouse-pipelines}"
IMAGE_NAME="${DBT_IMAGE_NAME:-dbt-runner}"
SA_NAME="${DBT_SA_NAME:-dbt-runner}"
JOB_NAME="${DBT_JOB_NAME:-dbt-runner}"
SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/${IMAGE_NAME}:latest"

echo "=== Deploy dbt runner ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Image:   ${IMAGE}"
echo "Job:     ${JOB_NAME}"
echo

echo "--- Building and pushing image ---"
gcloud builds submit \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --config="${DBT_DIR}/cloudbuild.yaml" \
  --substitutions="_IMAGE=${IMAGE}" \
  "${DBT_DIR}"

echo "--- Deploying Cloud Run Job ---"
gcloud run jobs deploy "${JOB_NAME}" \
  --project="${PROJECT}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --service-account="${SA}" \
  --set-env-vars="\
GCP_PROJECT=${PROJECT},\
BQ_LOCATION=${REGION},\
DBT_DATASET=${DBT_DATASET:-dbt},\
DBT_SELECTOR=${DBT_SELECTOR:-daily},\
DBT_COMMAND=${DBT_COMMAND:-build},\
DBT_THREADS=${DBT_THREADS:-4},\
DBT_TIMEOUT_SECONDS=${DBT_TIMEOUT_SECONDS:-300}" \
  --task-timeout=1800 \
  --max-retries=1 \
  --memory=1Gi \
  --cpu=1

echo
echo "=== Done ==="
echo "Manual execution:"
echo "  gcloud run jobs execute ${JOB_NAME} --region=${REGION} --project=${PROJECT} --wait"
