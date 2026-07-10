# Odoo.sh to BigQuery Pipeline - How It Works

## Overview

A daily automated pipeline extracts data from Wingtra's Odoo.sh production
instance and loads it into BigQuery for reporting.

Repository location: `pipelines/sources/odoo/`

The pipeline keeps current raw tables in `dl_odoo` and, for selected business
critical tables, also writes mechanical raw SCD2 tables named `<table>_scd`.

## Step-by-step flow

### 1. Trigger (Cloud Scheduler)
- Cron fires daily at 18:30 UTC.
- Sends authenticated HTTP POST to Cloud Run.
- Cloud Run spins up the container.

### 2. Fetch backup (`fetch_backup.py`)
- Reads SSH private key from Secret Manager.
- Connects to Odoo.sh via SSH (`19751186@wingtra-18.odoo.com`).
- Finds newest `.sql.gz` in `~/backup.daily/`.
- Checks backup age and rejects backups older than 36 hours.
- Downloads via SCP with `-O` because Odoo.sh does not support SFTP.
- Uploads a copy to GCS for archival with 30-day retention.

### 3. Filtered restore (`restore.py` + `dump_filter.py`)
- Starts ephemeral Postgres 16 inside the container.
- Decompresses the `.sql.gz` and streams it through the dump filter.
- Skips noisy, technical, transient, or binary-heavy tables and columns.
- Pipes the filtered SQL directly into local `psql`.

### 4. Load to BigQuery (`pipeline.py`)
- dlt connects to the local restored Postgres database.
- dlt extracts all remaining `public` schema tables into `dl_odoo_staging` with
  `write_disposition="replace"`.
- Each staging table is promoted into the current `dl_odoo.<table>` table using
  BigQuery `MERGE`:
  - existing rows are updated by primary key (`id` where available)
  - new rows are inserted
  - rows absent from the full staging snapshot are marked with `_dlt_deleted_at`
- For selected tables, the same full staging snapshot is compared to the open
  row in `dl_odoo.<table>_scd` by primary key and row hash.

### 5. Selected SCD tables

The current selected SCD set is:

- `crm_lead`
- `mrp_bom`
- `mrp_production`
- `product_category`
- `product_product`
- `product_template`
- `purchase_order`
- `purchase_order_line`
- `res_company`
- `res_partner`
- `res_users`
- `sale_order`
- `sale_order_line`
- `stock_location`
- `stock_move`
- `stock_move_line`
- `stock_warehouse`

For each selected table:

- `dl_odoo.<table>` is the current raw state.
- `dl_odoo.<table>_scd` is the raw mechanical SCD2 history.

SCD rows include:

- `_scd_row_hash`
- `_scd_change_type`: `insert`, `update`, or `delete`
- `_scd_valid_from`
- `_scd_valid_to`
- `_scd_is_current`
- `_scd_run_id`
- `_scd_extracted_at`

Current raw records:

```sql
SELECT *
FROM `wingtra-dwh.dl_odoo.stock_move`
WHERE _dlt_deleted_at IS NULL;
```

Current SCD versions:

```sql
SELECT *
FROM `wingtra-dwh.dl_odoo.stock_move_scd`
WHERE _scd_is_current
  AND _dlt_deleted_at IS NULL;
```

Point-in-time SCD version:

```sql
SELECT *
FROM `wingtra-dwh.dl_odoo.stock_move_scd`
WHERE id = 123
  AND TIMESTAMP('2026-07-01') >= _scd_valid_from
  AND (_scd_valid_to IS NULL OR TIMESTAMP('2026-07-01') < _scd_valid_to);
```

### 6. Cleanup
- Container exits.
- The in-container Postgres data is destroyed.
- No persistent local state is kept between runs.

## What gets excluded (and why)

| Category | Example tables | Why excluded |
|---|---|---|
| Attachments | `ir_attachment` | Binary blobs, not useful for analytics |
| Mail/Chatter | `mail_message`, `mail_followers`, `mail_tracking_value` | High-volume notification noise |
| Quality TOAST columns | Selected columns on `quality_check`, `quality_alert`, `quality_point` | Embedded images and long-form HTML/text |
| IR Technical | `ir_model_*`, `ir_ui_*`, `ir_act_*`, `ir_translation` | Odoo internals, UI definitions, translations |
| Real-time | `bus_bus`, `bus_presence`, `discuss_*` | Ephemeral messaging state |
| Wizards | `base_import_*`, `change_password_*`, `*_wizard*` | Transient UI state |

## GCP resources

| Resource | Name | Purpose |
|---|---|---|
| Cloud Run Job | `odoo-to-bq` | Runs the pipeline |
| Cloud Scheduler | `odoo-to-bq-daily` | Triggers daily at 18:30 UTC |
| GCS Bucket | `wingtra-dwh-odoo-backups` | Backup archive |
| BigQuery Dataset | `dl_odoo` | Current raw and selected SCD tables |
| BigQuery Dataset | `dl_odoo_staging` | Full daily staging snapshot and temporary SCD change tables |
| Artifact Registry | `odoo-pipeline` | Docker image storage |
| Secret Manager | `odoo-sh-ssh-key` | SSH private key for Odoo.sh |
| Service Account | `odoo-pipeline@wingtra-dwh` | Pipeline runtime identity |

## Manual operations

Trigger a sync:

```bash
gcloud run jobs execute odoo-to-bq --region=europe-west1 --project=wingtra-dwh
```

Check last run status:

```sql
SELECT *
FROM `wingtra-dwh.dl_odoo._pipeline_runs`
ORDER BY started_at DESC
LIMIT 5;
```

Find rows no longer present in the latest Odoo snapshot:

```sql
SELECT *
FROM `wingtra-dwh.dl_odoo.stock_move`
WHERE _dlt_deleted_at IS NOT NULL
ORDER BY _dlt_deleted_at DESC
LIMIT 20;
```

View logs:

```bash
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=odoo-to-bq" \
  --project=wingtra-dwh --limit=20 --format="value(textPayload)" --freshness=1h
```
