#!/usr/bin/env bash
# Create Cloud Monitoring email alerts for Cloud Run Job failures.

set -euo pipefail

PROJECT="${PROJECT:-wingtra-dwh}"
REGION="${REGION:-europe-west1}"
ALERT_EMAIL="${1:-${ALERT_EMAIL:-}}"

if [[ -z "${ALERT_EMAIL}" ]]; then
  echo "Usage: $0 <alert-email> [job-name ...]" >&2
  echo "Or set ALERT_EMAIL=<address>." >&2
  exit 1
fi
shift || true

JOBS=("$@")
if [[ "${#JOBS[@]}" -eq 0 ]]; then
  JOBS=(odoo-to-bq revolut-raw-loader dbt-runner hubspot-raw-loader)
fi

echo "=== Cloud Run Job failure alerts ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Email:   ${ALERT_EMAIL}"
echo "Jobs:    ${JOBS[*]}"
echo

gcloud services enable monitoring.googleapis.com --project="${PROJECT}" --quiet

CHANNEL_ID=$(gcloud beta monitoring channels list \
  --project="${PROJECT}" \
  --filter="type=\"email\" AND labels.email_address=\"${ALERT_EMAIL}\"" \
  --format="value(name)" \
  --limit=1)

if [[ -z "${CHANNEL_ID}" ]]; then
  echo "Creating notification channel for ${ALERT_EMAIL}"
  CHANNEL_ID=$(gcloud beta monitoring channels create \
    --project="${PROJECT}" \
    --display-name="Pipeline Failure Alerts (${ALERT_EMAIL})" \
    --type=email \
    --channel-labels="email_address=${ALERT_EMAIL}" \
    --format="value(name)")
else
  echo "Notification channel already exists: ${CHANNEL_ID}"
fi

for JOB_NAME in "${JOBS[@]}"; do
  POLICY_DISPLAY_NAME="${JOB_NAME} job failure"
  POLICY_JSON=$(mktemp)

  cat > "${POLICY_JSON}" <<EOF
{
  "displayName": "${POLICY_DISPLAY_NAME}",
  "documentation": {
    "content": "Cloud Run Job ${JOB_NAME} finished with a non-success result. Check executions with: gcloud run jobs executions list --job=${JOB_NAME} --region=${REGION} --project=${PROJECT}. Then inspect logs with: gcloud logging read 'resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${JOB_NAME}\"' --project=${PROJECT} --freshness=4h --limit=100",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "Job execution failed",
      "conditionThreshold": {
        "filter": "metric.type=\"run.googleapis.com/job/completed_execution_count\" AND resource.type=\"cloud_run_job\" AND resource.label.\"job_name\"=\"${JOB_NAME}\" AND metric.label.\"result\"!=\"succeeded\"",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "perSeriesAligner": "ALIGN_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": {"count": 1}
      }
    }
  ],
  "combiner": "OR",
  "alertStrategy": {
    "autoClose": "604800s"
  },
  "notificationChannels": ["${CHANNEL_ID}"],
  "enabled": true
}
EOF

  EXISTING_POLICY=$(gcloud alpha monitoring policies list \
    --project="${PROJECT}" \
    --filter="displayName=\"${POLICY_DISPLAY_NAME}\"" \
    --format="value(name)" \
    --limit=1)

  if [[ -z "${EXISTING_POLICY}" ]]; then
    echo "Creating alert policy '${POLICY_DISPLAY_NAME}'"
    gcloud alpha monitoring policies create \
      --project="${PROJECT}" \
      --policy-from-file="${POLICY_JSON}" >/dev/null
  else
    echo "Policy already exists: ${EXISTING_POLICY}"
  fi

  rm -f "${POLICY_JSON}"
done

echo
echo "=== Done ==="
