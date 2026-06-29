#!/usr/bin/env bash
# Idempotent setup of the weekly Cloud Scheduler trigger for revolut-raw-loader.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

JOB_NAME="${REVOLUT_SCHEDULER_JOB_NAME:-revolut-raw-loader-weekly}"
TARGET_JOB="${REVOLUT_RAW_LOADER_JOB_NAME:-revolut-raw-loader}"
SCHEDULER_SA_NAME="${REVOLUT_SCHEDULER_SA_NAME:-revolut-scheduler}"
SCHEDULER_SA="${SCHEDULER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
SCHEDULE="${REVOLUT_SCHEDULE:-0 5 * * 1}"
TIME_ZONE="${REVOLUT_SCHEDULE_TIME_ZONE:-Europe/Zurich}"
URI="https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${TARGET_JOB}:run"

if gcloud iam service-accounts describe "${SCHEDULER_SA}" \
    --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Service account ${SCHEDULER_SA} already exists."
else
  gcloud iam service-accounts create "${SCHEDULER_SA_NAME}" \
    --display-name="Revolut Scheduler Invoker" \
    --project="${PROJECT}"
fi

gcloud run jobs add-iam-policy-binding "${TARGET_JOB}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --member="serviceAccount:${SCHEDULER_SA}" \
  --role="roles/run.invoker" \
  --quiet

if gcloud scheduler jobs describe "${JOB_NAME}" \
    --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  action="update"
else
  action="create"
fi

gcloud scheduler jobs "${action}" http "${JOB_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT}" \
  --schedule="${SCHEDULE}" \
  --time-zone="${TIME_ZONE}" \
  --uri="${URI}" \
  --http-method=POST \
  --oauth-service-account-email="${SCHEDULER_SA}" \
  --headers="Content-Type=application/json" \
  --message-body="{}" \
  --description="Weekly Revolut Business API raw load into dl_revolut"

echo
echo "Scheduler job '${JOB_NAME}' ${action}d."
gcloud scheduler jobs describe "${JOB_NAME}" \
  --location="${REGION}" --project="${PROJECT}" \
  --format="value(name,schedule,timeZone,state)"
