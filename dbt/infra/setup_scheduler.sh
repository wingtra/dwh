#!/usr/bin/env bash
# Idempotent setup of the Cloud Scheduler trigger for the generic dbt runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

JOB_NAME="${DBT_SCHEDULER_JOB_NAME:-dbt-runner-daily}"
TARGET_JOB="${DBT_JOB_NAME:-dbt-runner}"
SCHEDULER_SA_NAME="${DBT_SCHEDULER_SA_NAME:-dbt-scheduler}"
SCHEDULER_SA="${SCHEDULER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
SCHEDULE="${DBT_SCHEDULE:-0 6 * * *}"
TIME_ZONE="${DBT_SCHEDULE_TIME_ZONE:-Europe/Zurich}"
URI="https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${TARGET_JOB}:run"

if gcloud iam service-accounts describe "${SCHEDULER_SA}" \
    --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Service account ${SCHEDULER_SA} already exists."
else
  gcloud iam service-accounts create "${SCHEDULER_SA_NAME}" \
    --display-name="dbt Scheduler Invoker" \
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
  --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform" \
  --headers="Content-Type=application/json" \
  --message-body="{}" \
  --description="Scheduled dbt build"

echo
echo "Scheduler job '${JOB_NAME}' ${action}d."
gcloud scheduler jobs describe "${JOB_NAME}" \
  --location="${REGION}" --project="${PROJECT}" \
  --format="value(name,schedule,timeZone,state)"
