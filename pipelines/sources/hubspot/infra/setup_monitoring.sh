#!/bin/bash
# Cloud Monitoring email alert for the HubSpot Cloud Run Job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

ALERT_EMAIL="${1:-${ALERT_EMAIL:-}}"
if [[ -z "${ALERT_EMAIL}" ]]; then
  echo "ERROR: ALERT_EMAIL not set. Pass as arg or export ALERT_EMAIL=<address>." >&2
  exit 1
fi

JOB_NAME="${HUBSPOT_RAW_LOADER_JOB_NAME:-hubspot-raw-loader}"
CHANNEL_DISPLAY_NAME="HubSpot Pipeline Alerts (${ALERT_EMAIL})"
POLICY_DISPLAY_NAME="${JOB_NAME} job failure"

echo "=== Cloud Monitoring setup ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Job:     ${JOB_NAME}"
echo "Email:   ${ALERT_EMAIL}"
echo ""

gcloud services enable monitoring.googleapis.com --project="${PROJECT}" --quiet

CHANNEL_ID=$(gcloud beta monitoring channels list \
  --project="${PROJECT}" \
  --filter="type=\"email\" AND labels.email_address=\"${ALERT_EMAIL}\"" \
  --format="value(name)" \
  --limit=1)

if [[ -z "${CHANNEL_ID}" ]]; then
  CHANNEL_ID=$(gcloud beta monitoring channels create \
    --project="${PROJECT}" \
    --display-name="${CHANNEL_DISPLAY_NAME}" \
    --type=email \
    --channel-labels="email_address=${ALERT_EMAIL}" \
    --format="value(name)")
fi

POLICY_JSON=$(mktemp)
trap 'rm -f "${POLICY_JSON}"' EXIT

cat > "${POLICY_JSON}" <<EOF
{
  "displayName": "${POLICY_DISPLAY_NAME}",
  "documentation": {
    "content": "Cloud Run Job ${JOB_NAME} finished with a non-success result after configured retries. Check logs with: gcloud logging read 'resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${JOB_NAME}\"' --project=${PROJECT} --freshness=2h --limit=100",
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
  gcloud alpha monitoring policies create \
    --project="${PROJECT}" \
    --policy-from-file="${POLICY_JSON}"
else
  echo "Policy already exists: ${EXISTING_POLICY}"
fi

echo ""
echo "=== Done ==="
