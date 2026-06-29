# Revolut Business to BigQuery Pipeline - How It Works

## Overview

A weekly automated pipeline that extracts Revolut Business accounts and
transactions, stores immutable raw API responses in GCS, and appends flattened
raw tables into BigQuery for downstream modeling.

Repository location: `pipelines/sources/revolut/`

```
                    Revolut Business API
                    ┌──────────────────────┐
                    │  Accounts endpoint    │
                    │  Transactions endpoint│
                    │  OAuth/JWT auth       │
                    └──────────┬───────────┘
                               │
                      1. HTTPS API calls
                         Weekly at 05:00 Zurich
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│              Cloud Run Job: revolut-raw-loader                   │
│              (1 GiB RAM, 1 vCPU, ephemeral)                      │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐  │
│  │              │    │              │    │                   │  │
│  │  2. Auth     │───>│  3. Fetch    │───>│  4. Land + Load   │  │
│  │              │    │              │    │                   │  │
│  │  Private key │    │  Accounts    │    │  Write JSONL to   │  │
│  │  + refresh   │    │  Transactions│    │  GCS              │  │
│  │  token from  │    │  Paginated   │    │                   │  │
│  │  Secret Mgr  │    │  by created  │    │  Append flattened │  │
│  │              │    │  timestamp   │    │  rows to BQ       │  │
│  └──────────────┘    └──────────────┘    └───────────────────┘  │
│             │                  │                    │            │
│             │                  │                    │            │
│             ▼                  ▼                    ▼            │
│     _api_requests       _watermarks          _pipeline_runs      │
│     audit rows          cursor state         run status          │
└──────────────────────────────────────────────────────────────────┘
          │                                       │
          ▼                                       ▼
  ┌───────────────┐                     ┌──────────────────┐
  │ GCS Bucket    │                     │ BigQuery         │
  │               │                     │                  │
  │ wingtra-dwh-  │                     │ Dataset:         │
  │ revolut-raw   │                     │ dl_revolut       │
  │               │                     │                  │
  │ JSONL raw     │                     │ append-only raw  │
  │ extracts      │                     │ tables           │
  └───────────────┘                     └──────────────────┘
```

## Step-by-step flow

### 1. Trigger (Cloud Scheduler)
- Cron fires weekly at 05:00 Europe/Zurich
- Sends authenticated HTTP POST directly to Cloud Run Job `revolut-raw-loader`
- The cleaned target state is raw-loader only; dbt orchestration is handled separately

### 2. Authenticate (`revolut_raw_loader.py`)
- Reads the API private key and refresh token from **Secret Manager**
- Builds a short-lived JWT client assertion
- Exchanges the refresh token for an access token
- Logs a warning if Revolut returns a rotated refresh token; automatic persistence is not enabled

### 3. Prepare BigQuery state
- Creates dataset `dl_revolut` if missing
- Ensures these tables exist:
  - `transactions`
  - `accounts`
  - `_pipeline_runs`
  - `_api_requests`
  - `_watermarks`
- Reads `_watermarks` to determine the next transaction extraction window
- Applies a 31-day lookback to catch late updates

### 4. Fetch Revolut data
- Fetches accounts from `/accounts`
- Fetches transactions from `/transactions`
- Paginates backwards by `created_at`
- Retries transient HTTP errors and rate limits
- Fails rather than silently truncating if `REVOLUT_MAX_PAGES` is reached

### 5. Land raw extracts and load BigQuery
- Writes raw account and transaction API responses as JSONL to GCS
- Flattens account rows into `dl_revolut.accounts`
- Flattens transaction legs into `dl_revolut.transactions`
- Appends rows instead of mutating historical extracts
- Writes request audit rows into `_api_requests`
- Updates `_watermarks` after a successful run
- Records run status in `_pipeline_runs`

## BigQuery tables

| Table | Grain | Purpose |
|---|---|---|
| `transactions` | One row per transaction leg per extraction run | Append-only raw transaction facts with raw JSON retained |
| `accounts` | One row per account per extraction run | Append-only raw account snapshots |
| `_pipeline_runs` | One row per loader run | Run status, extracted window, loaded counts, errors |
| `_api_requests` | One row per API request | API audit trail, status code, duration, page metadata |
| `_watermarks` | One row per resource | Cursor state for the next extraction window |

## GCP resources

| Resource | Name | Purpose |
|---|---|---|
| Cloud Run Job | `revolut-raw-loader` | Runs the raw API extraction |
| Cloud Scheduler | `revolut-raw-loader-weekly` | Direct weekly trigger for the raw loader |
| GCS Bucket | `wingtra-dwh-revolut-raw` | Immutable raw JSONL landing |
| BigQuery Dataset | `dl_revolut` | Raw Revolut dataset |
| Artifact Registry | `finance-pipelines` | Docker image storage |
| Secret Manager | `revolut-business-api-private-key` | Revolut API private key |
| Secret Manager | `revolut-business-api-refresh-token` | Revolut API refresh token |
| Service Account | `revolut-raw-loader@wingtra-dwh` | Runtime identity for raw loader |
| Service Account | `revolut-scheduler@wingtra-dwh` | Scheduler identity for invoking the raw loader |

## Manual operations

**Trigger a raw sync:**
```bash
gcloud run jobs execute revolut-raw-loader --region=europe-west1 --project=wingtra-dwh --wait
```

**Check last run status:**
```sql
SELECT *
FROM `wingtra-dwh.dl_revolut._pipeline_runs`
ORDER BY started_at DESC
LIMIT 5
```

**Check latest watermark:**
```sql
SELECT *
FROM `wingtra-dwh.dl_revolut._watermarks`
ORDER BY updated_at DESC
LIMIT 5
```

**View logs:**
```bash
gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=revolut-raw-loader" \
  --project=wingtra-dwh --limit=50 --format="value(textPayload)" --freshness=2h
```

## Cleanup note

The old combined/dbt paths should not be reintroduced into this source pipeline.
After the direct raw-loader scheduler is confirmed, retire stale cloud resources
in a separate approval-gated step:

- Scheduler `revolut-raw-and-dbt-weekly`
- Workflow `revolut-raw-and-dbt`
- Legacy Cloud Run Job `revolut-to-bq-dbt`
- Cloud Run Job `revolut-dbt-build`, if dbt is not kept as a separate manual job
