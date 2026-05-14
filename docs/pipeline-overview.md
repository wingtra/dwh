# Odoo.sh to BigQuery Pipeline - How It Works

## Overview

A daily automated pipeline that extracts data from Wingtra's Odoo.sh production instance and loads it into BigQuery for reporting.

```
                        Odoo.sh (Production)
                        ┌─────────────────────┐
                        │  Odoo 18 + Postgres  │
                        │                      │
                        │  ~/backup.daily/     │
                        │    *.sql.gz (2.4 GB) │
                        └──────────┬───────────┘
                                   │
                          1. SSH + SCP (-O flag)
                             Daily at 04:00 UTC
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────┐
│                     Cloud Run Job: odoo-to-bq                    │
│                     (16 GiB RAM, 4 vCPU, ephemeral)              │
│                                                                  │
│  ┌────────────┐    ┌──────────────┐    ┌───────────────────┐    │
│  │            │    │              │    │                   │    │
│  │  2. Fetch  │───>│  3. Restore  │───>│  4. Load (dlt)    │    │
│  │            │    │              │    │                   │    │
│  │  SSH key   │    │  Decompress  │    │  Read all tables  │    │
│  │  from      │    │  .sql.gz     │    │  from local PG    │    │
│  │  Secret    │    │              │    │                   │    │
│  │  Manager   │    │  Stream thru │    │  Write to BQ      │    │
│  │            │    │  dump filter │    │  (full replace)   │    │
│  │  Download  │    │  (skip mail, │    │                   │    │
│  │  backup    │    │  attachments,│    │  275 tables       │    │
│  │  via SCP   │    │  IR tables)  │    │  3.1M rows        │    │
│  │            │    │              │    │                   │    │
│  │  Upload to │    │  Pipe into   │    │  Record run in    │    │
│  │  GCS       │    │  local psql  │    │  _pipeline_runs   │    │
│  │  (archive) │    │              │    │                   │    │
│  └────────────┘    └──────────────┘    └───────────────────┘    │
│         │             │                         │                │
│         │          ┌──┴──┐                      │                │
│         │          │ PG  │ (ephemeral,          │                │
│         │          │ 16  │  inside container,   │                │
│         │          └─────┘  destroyed on exit)  │                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
          │                                       │
          ▼                                       ▼
  ┌───────────────┐                     ┌──────────────────┐
  │ GCS Bucket    │                     │ BigQuery         │
  │               │                     │                  │
  │ wingtra-dwh-  │                     │ Dataset: dl_odoo │
  │ odoo-backups  │                     │                  │
  │               │                     │ 275 tables       │
  │ 30-day        │                     │ Full replace     │
  │ retention     │                     │ daily            │
  └───────────────┘                     └──────────────────┘
```

## Step-by-step flow

### 1. Trigger (Cloud Scheduler)
- Cron fires daily at 04:00 UTC
- Sends authenticated HTTP POST to Cloud Run
- Cloud Run spins up the container

### 2. Fetch backup (`fetch_backup.py`)
- Reads SSH private key from **Secret Manager**
- Connects to Odoo.sh via SSH (`19751186@wingtra-18.odoo.com`)
- Finds newest `.sql.gz` in `~/backup.daily/`
- Checks backup age (rejects if older than 36 hours)
- Downloads via **SCP** with `-O` flag (legacy protocol; Odoo.sh doesn't support SFTP)
- Uploads a copy to **GCS** for archival (30-day retention)

### 3. Filtered restore (`restore.py` + `dump_filter.py`)
- Starts **ephemeral Postgres 16** inside the container
- Decompresses the `.sql.gz` and streams it through the **dump filter**
- The filter skips COPY blocks for excluded tables:
  - `mail_*` (chatter, 1M+ rows of messages/tracking)
  - `ir_attachment` (binary blobs, 55 MB)
  - `quality_check/alert/point` (3 GB of TOAST bloat)
  - `ir_*` (technical metadata, UI views, translations)
  - `bus_*`, `discuss_*`, `digest_*` (real-time/notification noise)
  - ~107 tables skipped total
- Schema (CREATE TABLE, indexes) passes through for all tables
- Filtered SQL piped directly into `psql` for restore

### 4. Load to BigQuery (`pipeline.py`)
- **dlt** connects to local Postgres via Unix socket
- Auto-discovers all tables in the `public` schema
- Extracts, normalizes, and loads to BigQuery dataset `dl_odoo`
- `write_disposition="replace"` - every run is a complete snapshot
- Postgres `numeric` without precision mapped to `Float` via `type_adapter_callback`
- Writes run metadata to `_pipeline_runs` table (status, duration, errors)

### 5. Cleanup
- Container exits, Postgres data is destroyed
- No persistent state between runs

## What gets excluded (and why)

| Category | Example tables | Why excluded |
|---|---|---|
| Attachments | `ir_attachment` | Binary blobs, 55 MB, not useful for analytics |
| Mail/Chatter | `mail_message`, `mail_followers`, `mail_tracking_value` | 1M+ rows of notification noise |
| Quality TOAST | `quality_check`, `quality_alert`, `quality_point` | 3 GB of embedded HTML/images in TOAST columns |
| IR Technical | `ir_model_*`, `ir_ui_*`, `ir_act_*`, `ir_translation` | Odoo internals, UI definitions, translations |
| Real-time | `bus_bus`, `bus_presence`, `discuss_*` | Ephemeral messaging state |
| Wizards | `base_import_*`, `change_password_*`, `*_wizard*` | Transient UI state |

## What gets included

Everything not in the EXCLUDE list. Key business tables:

| Domain | Tables | Example row counts |
|---|---|---|
| Inventory | `stock_move`, `stock_move_line`, `stock_quant`, `stock_lot` | 529K, 580K, 137K, 91K |
| Valuation | `stock_valuation_layer` | 439K |
| Purchasing | `purchase_order`, `purchase_order_line`, `purchase_product_price` | 4.6K, 9.2K, 266K |
| Sales | `sale_order`, `sale_order_line` | 6.2K, 20.6K |
| Manufacturing | `mrp_production`, `mrp_workorder`, `mrp_bom` | 32.3K, 38.9K, 850 |
| Quality | `quality_reason`, `quality_tag`, `quality_alert_team` | 742, 29, 3 |
| CRM | `crm_lead` | 14.5K |
| Partners | `res_partner`, `res_company`, `res_users` | 25.5K, 3, 149 |
| Accounting | `account_move`, `account_move_line` | 3.5K, 15.7K |
| Wingtra custom | `wt_hs_code`, `wt_product_revision`, `wt_product_expert` | 374, 151, 55 |

## GCP resources

| Resource | Name | Purpose |
|---|---|---|
| Cloud Run Job | `odoo-to-bq` | Runs the pipeline (16 GiB, 4 vCPU) |
| Cloud Scheduler | `odoo-pipeline-daily` | Triggers daily at 04:00 UTC |
| GCS Bucket | `wingtra-dwh-odoo-backups` | Backup archive (30-day retention) |
| BigQuery Dataset | `dl_odoo` | Target dataset (europe-west1) |
| Artifact Registry | `odoo-pipeline` | Docker image storage |
| Secret Manager | `odoo-sh-ssh-key` | SSH private key for Odoo.sh |
| Service Account | `odoo-pipeline@wingtra-dwh` | Pipeline identity (5 IAM roles) |

## Costs

Effectively free under GCP free tier for a single daily run (~28 min).
If free tier is exhausted: ~$2.50/month for Cloud Run compute.
GCS + BigQuery storage: pennies.

## Manual operations

**Trigger a sync:**
```bash
gcloud run jobs execute odoo-to-bq --region=europe-west1 --project=wingtra-dwh
```

**Check last run status:**
```sql
SELECT * FROM `wingtra-dwh.dl_odoo._pipeline_runs`
ORDER BY started_at DESC LIMIT 5
```

**View logs:**
```bash
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=odoo-to-bq" \
  --project=wingtra-dwh --limit=20 --format="value(textPayload)" --freshness=1h
```
