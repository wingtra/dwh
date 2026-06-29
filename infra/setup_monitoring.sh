#!/bin/bash
# Cloud Monitoring alert for the odoo-to-bq Cloud Run Job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

ALERT_EMAIL="${1:-${ALERT_EMAIL:-}}"
if [[ -z "${ALERT_EMAIL}" ]]; then
  echo "ERROR: ALERT_EMAIL not set. Pass as arg or export ALERT_EMAIL=<address>." >&2
  exit 1
fi

JOB_NAME="${ODOO_CLOUD_RUN_JOB_NAME:-odoo-to-bq}"
CHANNEL_DISPLAY_NAME="Odoo Pipeline Alerts (${ALERT_EMAIL})"
POLICY_DISPLAY_NAME="${JOB_NAME} job failure"

echo "=== Cloud Monitoring setup ==="
echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Job:     ${JOB_NAME}"
echo "Email:   ${ALERT_EMAIL}"
echo ""

echo "--- Enabling Cloud Monitoring API ---"
gcloud services enable monitoring.googleapis.com --project="${PROJECT}" --quiet

echo "--- Notification channel ---"
CHANNEL_ID=$(gcloud beta monitoring channels list \
  --project="${PROJECT}" \
  --filter="type=\"email\" AND labels.email_address=\"${ALERT_EMAIL}\"" \
  --format="value(name)" \
  --limit=1)

if [[ -z "${CHANNEL_ID}" ]]; then
  echo "Creating notification channel for ${ALERT_EMAIL}"
  CHANNEL_ID=$(gcloud beta monitoring channels create \
    --project="${PROJECT}" \
    --display-name="${CHANNEL_DISPLAY_NAME}" \
    --type=email \
    --channel-labels="email_address=${ALERT_EMAIL}" \
    --format="value(name)")
else
  echo "Channel already exists: ${CHANNEL_ID}"
fi

POLICY_JSON=$(mktemp)
trap 'rm -f "${POLICY_JSON}"' EXIT

cat > "${POLICY_JSON}" <<EOF
{
  "displayName": "${POLICY_DISPLAY_NAME}",
  "documentation": {
    "content": "Cloud Run Job ${JOB_NAME} finished with a non-success result. Investigate via 'gcloud run jobs executions list --job=${JOB_NAME} --region=${REGION} --project=${PROJECT}' and check logs.",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "Job execution failed (any non-success result)",
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

echo "--- Alert policy ---"
EXISTING_POLICY=$(gcloud alpha monitoring policies list \
  --project="${PROJECT}" \
  --filter="displayName=\"${POLICY_DISPLAY_NAME}\"" \
  --format="value(name)" \
  --limit=1)

if [[ -z "${EXISTING_POLICY}" ]]; then
  echo "Creating alert policy '${POLICY_DISPLAY_NAME}'"
  gcloud alpha monitoring policies create \
    --project="${PROJECT}" \
    --policy-from-file="${POLICY_JSON}"
else
  echo "Policy already exists: ${EXISTING_POLICY}"
  echo "(To update: delete with 'gcloud alpha monitoring policies delete ${EXISTING_POLICY}' and re-run.)"
fi

echo ""
echo "=== Done ==="
