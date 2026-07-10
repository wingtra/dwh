# HubSpot to BigQuery Pipeline - How It Works

## Overview

A daily Cloud Run Job extracts HubSpot CRM data, lands immutable raw API page
evidence in GCS, stages normalized rows in BigQuery, maintains current raw
mirrors, and writes mechanical raw SCD2 versions in `dl_hubspot`.

Repository location: `pipelines/sources/hubspot/`

## Load Shape

The pipeline maintains two table styles per object:

- `<object>`: current raw mirror keyed by HubSpot object ID
- `<object>_scd`: raw SCD2 versions created by PK/hash comparison

For object resources, the loader performs full reads rather than relying on
`hs_lastmodifieddate`. Property metadata resources load before objects; when
available, the loader uses that metadata to request all non-hidden properties
for each object. This means net changes to requested object rows are captured
even when a HubSpot modified timestamp is incomplete or unreliable.

Association resources use the same current/SCD pattern:

- `association_edges`: current raw association edge set
- `association_edges_scd`: raw SCD2 association edge versions

## Step-by-step Flow

1. Cloud Scheduler invokes Cloud Run Job `hubspot-raw-loader`.
2. The loader reads the HubSpot service key from Secret Manager.
3. Metadata resources load first: owners, pipelines, schemas, and properties.
4. Object resources load next: companies, contacts, deals, tickets, products,
   line items, quotes, licences, and commissions.
5. Association resources load after objects.
6. Every fetched API page is written to GCS under a run ID and attempt number.
7. Rows are loaded into per-run BigQuery staging tables.
8. The current table is MERGEd by object ID or association key.
9. The SCD table closes changed/deleted current versions and inserts new
   `_scd_change_type` rows: `insert`, `update`, or `delete`.
10. Watermarks and run metadata advance only after the full resource load
    succeeds.

## Current And SCD Queries

Current raw records:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot.deals`
WHERE _dlt_deleted_at IS NULL;
```

Current SCD versions:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot.deals_scd`
WHERE _scd_is_current
  AND _dlt_deleted_at IS NULL;
```

Point-in-time SCD version:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot.deals_scd`
WHERE object_id = '123'
  AND TIMESTAMP('2026-07-01') >= _scd_valid_from
  AND (_scd_valid_to IS NULL OR TIMESTAMP('2026-07-01') < _scd_valid_to);
```

## Soft Deletes

The current mirror and SCD tables keep the repo-wide clean-layer convention:

- `_dlt_synced_at`
- `_dlt_deleted_at`

For HubSpot, `_dlt_deleted_at` is set when:

- HubSpot returns the object as archived/deleted, using `archivedAt` when
  available.
- A record that was previously current is missing from a successful full object
  load.
- An association edge that was previously current is missing from a successful
  full association load.

## Failure Handling

The loader retries transient HubSpot, GCS, and BigQuery failures. If in-process
retries are exhausted, the Cloud Run Job fails so job-level retries can rerun
the same resource load. Watermarks do not advance unless the resource load
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

The daily scheduler runs at 20:00 Europe/Zurich. This keeps HubSpot in the same
evening raw-load window as Odoo and before the 22:30 Europe/Zurich dbt daily
build.

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
