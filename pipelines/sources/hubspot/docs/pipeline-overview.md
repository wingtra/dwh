# HubSpot to BigQuery Pipeline - How It Works

## Overview

A daily Cloud Run Job extracts HubSpot CRM data, lands immutable raw API page
evidence in GCS, stages normalized rows in BigQuery, appends extract logs, and
MERGEs current raw mirrors in `dl_hubspot`.

Repository location: `pipelines/sources/hubspot/`

## Load Shape

The pipeline maintains two table styles per object:

- `<object>_extracts`: append-only extraction evidence
- `<object>`: current raw mirror keyed by HubSpot object ID

Daily incremental loads upsert what HubSpot returns. They never delete a row
just because it is absent from the current incremental window. Deletes use
explicit `archived` / `archivedAt` evidence or a separate reconciliation run.

## Step-by-step Flow

1. Cloud Scheduler invokes Cloud Run Job `hubspot-raw-loader`.
2. The loader reads the HubSpot service key from Secret Manager.
3. Metadata resources load first: owners, pipelines, schemas, and properties.
4. Object resources load next: companies, contacts, deals, products,
   line items, and quotes. Tickets are present in the manifest but disabled
   until HubSpot auth supports the required ticket scope.
5. Association resources load after objects.
6. Every fetched API page is written to GCS under a run ID and attempt number.
7. Rows are loaded into per-run BigQuery staging tables.
8. Staging rows are validated and deduped.
9. Rows append to `*_extracts`.
10. Current tables are MERGEd by object ID or association key.
11. Watermarks advance only after the full resource load succeeds.

## Soft Deletes

The current mirror tables keep the repo-wide clean-layer convention:

- `_dlt_synced_at`
- `_dlt_deleted_at`

For HubSpot, `_dlt_deleted_at` is set only when:

- HubSpot returns the object as archived/deleted, using `archivedAt` when
  available.
- A reconciliation run proves the source record or association is no longer
  active.

Missing from a daily incremental result is not deletion evidence.

## Failure Handling

The loader retries transient HubSpot, GCS, and BigQuery failures. If in-process
retries are exhausted, the Cloud Run Job fails so job-level retries can rerun
the same watermark window. Watermarks do not advance unless the resource load
fully succeeds.

Cloud Monitoring email alerts are configured by `infra/setup_monitoring.sh`.

## GCP Resources

| Resource | Name |
|---|---|
| Cloud Run Job | `hubspot-raw-loader` |
| Cloud Scheduler | `hubspot-raw-loader-daily` |
| BigQuery dataset | `dl_hubspot` |
| BigQuery staging dataset | `dl_hubspot_staging` |
| GCS bucket | `wingtra-dwh-hubspot-raw` |
| Secret Manager secret | `hubspot-service-key` |
| Runtime service account | `hubspot-raw-loader@wingtra-dwh.iam.gserviceaccount.com` |
| Scheduler service account | `hubspot-scheduler@wingtra-dwh.iam.gserviceaccount.com` |

## Manual Operations

Trigger a sync:

```bash
gcloud run jobs execute hubspot-raw-loader \
  --region=europe-west1 \
  --project=wingtra-dwh \
  --wait
```

Check recent runs:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot._pipeline_runs`
ORDER BY started_at DESC
LIMIT 10;
```

Check watermarks:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot._watermarks`
ORDER BY updated_at DESC;
```
