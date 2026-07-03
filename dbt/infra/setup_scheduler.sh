#!/usr/bin/env bash
# Idempotent setup of selector-specific Cloud Scheduler triggers for dbt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

TARGET_JOB="${DBT_JOB_NAME:-dbt-runner}"
SCHEDULER_SA_NAME="${DBT_SCHEDULER_SA_NAME:-dbt-scheduler}"
SCHEDULER_SA="${SCHEDULER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
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

gcloud run jobs add-iam-policy-binding "${TARGET_JOB}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --member="serviceAccount:${SCHEDULER_SA}" \
  --role="roles/run.developer" \
  --quiet

build_run_body() {
  local selector="$1"

  python3 - "${selector}" <<'PY'
import json
import sys

selector = sys.argv[1]
body = {
    "overrides": {
        "containerOverrides": [
            {
                "env": [
                    {"name": "DBT_SELECTOR", "value": selector},
                ],
            },
        ],
    },
}
print(json.dumps(body, separators=(",", ":")))
PY
}

upsert_scheduler() {
  local job_name="$1"
  local selector="$2"
  local schedule="$3"
  local description="$4"
  local message_body
  local action
  local -a header_args

  message_body="$(build_run_body "${selector}")"

  if gcloud scheduler jobs describe "${job_name}" \
      --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
    action="update"
    header_args=(--update-headers="Content-Type=application/json")
  else
    action="create"
    header_args=(--headers="Content-Type=application/json")
  fi

  gcloud scheduler jobs "${action}" http "${job_name}" \
    --location="${REGION}" \
    --project="${PROJECT}" \
    --schedule="${schedule}" \
    --time-zone="${TIME_ZONE}" \
    --uri="${URI}" \
    --http-method=POST \
    --oauth-service-account-email="${SCHEDULER_SA}" \
    --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform" \
    "${header_args[@]}" \
    --message-body="${message_body}" \
    --description="${description}"

  echo
  echo "Scheduler job '${job_name}' ${action}d with DBT_SELECTOR=${selector}."
  gcloud scheduler jobs describe "${job_name}" \
    --location="${REGION}" --project="${PROJECT}" \
    --format="value(name,schedule,timeZone,state)"
}

if [[ "${DBT_ENABLE_DAILY_SCHEDULER:-false}" == "true" ]]; then
  upsert_scheduler \
    "${DBT_DAILY_SCHEDULER_JOB_NAME:-dbt-runner-daily}" \
    "${DBT_DAILY_SELECTOR:-daily}" \
    "${DBT_DAILY_SCHEDULE:-0 6 * * *}" \
    "Daily dbt build"
else
  echo
  echo "Daily dbt scheduler disabled. Set DBT_ENABLE_DAILY_SCHEDULER=true to create it."
fi

if [[ "${DBT_ENABLE_MORNING_SCHEDULER:-false}" == "true" ]]; then
  upsert_scheduler \
    "${DBT_MORNING_SCHEDULER_JOB_NAME:-dbt-runner-daily-morning}" \
    "${DBT_DAILY_SELECTOR:-daily}" \
    "${DBT_MORNING_SCHEDULE:-15 6 * * *}" \
    "Morning catch-up dbt build so overnight loader recoveries reach the modeled layer"
else
  echo
  echo "Morning dbt scheduler disabled. Set DBT_ENABLE_MORNING_SCHEDULER=true to create it."
fi

if [[ "${DBT_ENABLE_WEEKLY_SCHEDULER:-true}" == "true" ]]; then
  upsert_scheduler \
    "${DBT_WEEKLY_SCHEDULER_JOB_NAME:-dbt-runner-weekly}" \
    "${DBT_WEEKLY_SELECTOR:-weekly}" \
    "${DBT_WEEKLY_SCHEDULE:-0 7 * * 1}" \
    "Weekly dbt build"
else
  echo
  echo "Weekly dbt scheduler disabled. Set DBT_ENABLE_WEEKLY_SCHEDULER=true to create it."
fi
