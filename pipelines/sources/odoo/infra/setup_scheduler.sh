#!/usr/bin/env bash
# Idempotent setup for the daily Cloud Scheduler job that triggers odoo-to-bq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

JOB_NAME="${ODOO_SCHEDULER_JOB_NAME:-odoo-to-bq-daily}"
TARGET_JOB="${ODOO_CLOUD_RUN_JOB_NAME:-odoo-to-bq}"
SA_EMAIL="odoo-pipeline@${PROJECT}.iam.gserviceaccount.com"
SCHEDULE="${ODOO_SCHEDULE:-30 18 * * *}"
TIME_ZONE="${ODOO_SCHEDULE_TIME_ZONE:-Etc/UTC}"
URI="https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${TARGET_JOB}:run"

gcloud run jobs add-iam-policy-binding "${TARGET_JOB}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --member="serviceAccount:${SA_EMAIL}" \
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
  --oauth-service-account-email="${SA_EMAIL}" \
  --description="Daily run of the Odoo to BQ ingestion pipeline after the observed Odoo.sh dump availability window"

echo
echo "Scheduler job '${JOB_NAME}' ${action}d."
gcloud scheduler jobs describe "${JOB_NAME}" \
  --location="${REGION}" --project="${PROJECT}" \
  --format="value(name,schedule,scheduleTime)"
