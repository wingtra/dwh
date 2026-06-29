# Odoo.sh → BigQuery Pipeline — Full Implementation Handover

> Archived initial implementation handover. This is not current operational guidance.
> See [pipeline-overview.md](../../pipeline-overview.md) for the current Odoo pipeline behavior.

> **For Claude Code.** This is the master document. Work through the phases in order. Each phase has a verification gate at the end — stop, run the checks, confirm with the user before proceeding to the next phase. Do not skip ahead.

## 1. Goal

Build an automated daily pipeline running in Wingtra's GCP project that extracts data from their Odoo.sh production instance and lands it in BigQuery for reporting. The pipeline:

- Pulls Odoo.sh's daily Postgres backup over SSH
- Filters out attachments, chatter, technical tables, and other operational noise
- Restores only the useful subset into an ephemeral Postgres running inside the Cloud Run Job container
- Loads that subset into BigQuery using `dlt` with full-replace write disposition
- Runs daily on a Cloud Scheduler cron
- Costs only a few dollars a month to operate

This handover stops at "raw Odoo data refreshed daily in BigQuery." Modeling layer (dbt etc.) is explicitly out of scope.

## 2. Architecture

```
Cloud Scheduler (daily cron, 04:00 UTC)
   │ OIDC-authenticated HTTP POST
   ▼
Cloud Run Job: odoo-to-bq
   │
   ├─ 1. SSH to Odoo.sh, find newest backup in ~/backup.daily/
   ├─ 2. SCP download .sql.gz (legacy -O flag) → upload to GCS bucket (archive)
   ├─ 3. Initialize in-container Postgres, create empty database
   ├─ 4. Stream backup from GCS through dump-filter (skip EXCLUDE tables)
   │       → pipe into local psql restore
   ├─ 5. Run dlt: sql_database (local PG) → BigQuery (replace mode)
   ├─ 6. Write pipeline run metadata to BigQuery (_pipeline_runs table)
   └─ 7. Exit — container destroyed, Postgres data discarded (intentional)
```

### Key non-obvious points

- **Postgres runs inside the Cloud Run Job container**, not as a separate Cloud SQL instance. The Dockerfile installs Postgres; an entrypoint script starts it as a background process before the Python pipeline runs.
- **The filter is what makes this viable.** Without it, the in-container Postgres would need to hold the full Odoo DB including attachments — typically >10GB. With it, the working set is <2GB and fits comfortably in a Cloud Run Job's memory/disk.
- **dlt connects to Postgres via Unix socket** at `/var/run/postgresql/` since both run in the same container. No network auth needed.
- **The Cloud Run Job's service account** authenticates to BigQuery via Application Default Credentials — no JSON key file required.
- **No persistent storage** for the pipeline beyond the GCS backup archive. Every run is fully self-contained.

## 3. Decisions locked in (do not revisit without good reason)

| # | Decision | Rationale |
|---|---|---|
| 1 | Backup-and-restore over API | Odoo.sh blocks direct DB access on shared hosting; XML-RPC is deprecated and slow; backup path is Odoo-recommended for warehousing |
| 2 | Ephemeral Postgres in Cloud Run Job (not Cloud SQL) | Filtered DB is small enough to fit in-container; saves $45-95/mo vs always-on Cloud SQL |
| 3 | Stream-filter the pg_dump during restore | Skips loading gigabytes of attachments/chatter we never use |
| 4 | Curated table whitelist | Only business-relevant tables reach BigQuery |
| 5 | Daily full replace via dlt | Simpler than incremental cursors; each run is a complete snapshot |
| 6 | `dlt` with `sql_database` source | Well-trodden path, native BigQuery destination, handles schema evolution |
| 7 | Region: europe-west1 (default — confirm with user) | Wingtra is in Switzerland; matches across Cloud Run, GCS, BigQuery |

### Fallback: Cloud SQL variant

If during testing the filtered DB grows beyond ~8GB (e.g., Wingtra adds heavy modules in the future), switch from ephemeral Postgres to Cloud SQL:
- Replace in-container Postgres with a Cloud SQL instance (db-custom-1-3840 starting tier)
- Update Dockerfile to drop the Postgres install and entrypoint script
- Pipeline connects to Cloud SQL via `--set-cloudsql-instances` Unix socket
- Add Cloud SQL admin steps to drop/recreate database before each restore

This variant adds ~$45/mo but supports larger workloads. Document but do not implement unless required.

## 4. Prerequisites — confirm with user before starting

Do not provision anything until all 7 are answered.

1. **GCP project ID** (e.g., `wingtra-data-platform`)
2. **Region** — suggest `europe-west1`, must match across all resources
3. **Odoo.sh SSH hostname** — typically `<project>.prod.odoo.com`; user finds it in Odoo.sh project → Branches → Production → SSH access
4. **Odoo.sh SSH username** — typically the project subdomain
5. **Odoo.sh SSH key handling** — does user have a key already registered, or generate fresh and have them add the public key via GitHub? If generating, store the private key in Secret Manager (see Phase 1).
6. **Odoo Postgres major version** — user runs `psql -V` in the Odoo.sh web shell. The in-container Postgres in our Dockerfile must match (likely 15 or 16 for Odoo 18). **This is critical** — version mismatch causes restore to fail.
7. **Final EXCLUDE / INCLUDE table lists** — based on the dump analysis we already did. See Section 6 for the structure; user provides the final lists.

Note: SSH host key pinning is not feasible on Odoo.sh because their SSH containers are ephemeral and host keys change between sessions. The pipeline uses `AutoAddPolicy` instead.

Store all answers in `infra/config.env` (gitignored). Do not hardcode in source files.

## 5. Project structure

```
dwh/
├── src/
│   ├── __init__.py
│   ├── main.py                  # Cloud Run Job entrypoint, orchestrates the 3 steps
│   ├── fetch_backup.py          # SSH to Odoo.sh → download → upload to GCS
│   ├── restore.py               # GCS → dump filter → local Postgres
│   ├── dump_filter.py           # streaming filter that skips excluded tables
│   ├── pipeline.py              # dlt: local Postgres → BigQuery
│   ├── metadata.py              # writes pipeline run metadata to BigQuery
│   ├── tables.py                # INCLUDE list + EXCLUDE list
│   └── config.py                # env vars, secret fetching
├── .dlt/
│   ├── config.toml              # dataset name, dlt config
│   └── secrets.toml.example     # template only; real secrets via Cloud Run env
├── infra/
│   ├── setup.sh                 # Phase 1: provision GCP infra (idempotent)
│   ├── deploy.sh                # Phase 3: build image, deploy Cloud Run Job + Scheduler
│   ├── lifecycle.json           # GCS bucket lifecycle rules
│   └── config.env.example       # template for project-specific config
├── docker/
│   └── entrypoint.sh            # starts in-container Postgres, then runs pipeline
├── Dockerfile
├── requirements.txt
├── .gitignore                   # MUST include .dlt/secrets.toml, *.env, *.key, *.pem
├── .dockerignore
└── README.md
```

## 6. Phase 1 — GCP infrastructure

Implement as `infra/setup.sh`. Make it idempotent (check before creating). User runs it once at project setup.

### 6.1 Enable APIs

```bash
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com
```

### 6.2 GCS bucket for backup archive

```bash
gcloud storage buckets create gs://${PROJECT}-odoo-backups \
  --location=${REGION} \
  --uniform-bucket-level-access
```

Apply lifecycle policy from `infra/lifecycle.json`:

```json
{
  "lifecycle": {
    "rule": [{
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    }]
  }
}
```

```bash
gcloud storage buckets update gs://${PROJECT}-odoo-backups \
  --lifecycle-file=infra/lifecycle.json
```

### 6.3 BigQuery dataset

```bash
bq --location=${REGION} mk -d --description="Raw Odoo data, refreshed daily" \
  ${PROJECT}:dl_odoo
```

### 6.4 Artifact Registry repo

```bash
gcloud artifacts repositories create odoo-pipeline \
  --repository-format=docker \
  --location=${REGION}
```

### 6.5 Service account + IAM

```bash
gcloud iam service-accounts create odoo-pipeline \
  --display-name="Odoo Pipeline Runner"

SA="odoo-pipeline@${PROJECT}.iam.gserviceaccount.com"

for role in \
  roles/secretmanager.secretAccessor \
  roles/storage.objectAdmin \
  roles/bigquery.dataEditor \
  roles/bigquery.jobUser \
  roles/run.invoker; do
    gcloud projects add-iam-policy-binding ${PROJECT} \
      --member="serviceAccount:${SA}" --role=${role}
done
```

Tighten `storage.objectAdmin` scope to the backup bucket only if you want to be strict; project-wide is fine to start.

### 6.6 Secrets

```bash
# SSH private key
gcloud secrets create odoo-sh-ssh-key --replication-policy=automatic
gcloud secrets versions add odoo-sh-ssh-key --data-file=/path/to/odoo_sh_id_ed25519
```

If user doesn't have a key yet:
```bash
ssh-keygen -t ed25519 -f ./odoo_sh_id_ed25519 -N ""
# Have user add the .pub file to Odoo.sh project settings → Branches → Production → SSH keys
```

### Verification gate (Phase 1)

- `gcloud storage buckets list` shows the backup bucket
- `bq ls` shows `dl_odoo` dataset
- `gcloud iam service-accounts get-iam-policy ${SA}` shows all 5 roles
- `gcloud secrets list` shows `odoo-sh-ssh-key`
- `gcloud artifacts repositories list` shows the docker repo

Have user confirm before proceeding.

## 7. Phase 2 — Code implementation

### 7.1 `src/tables.py`

Populate `INCLUDE_TABLES` and `EXCLUDE_TABLES` from the dump analysis we did. The user has already confirmed these — ask them to paste the final lists.

```python
"""Tables to include/exclude in the Odoo -> BigQuery extraction."""

# Tables we extract to BigQuery. Confirmed from dump analysis + user review.
INCLUDE_TABLES: list[str] = [
    # paste final list here, e.g.:
    # "res_partner", "res_users", "res_company",
    # "sale_order", "sale_order_line",
    # "account_move", "account_move_line",
    # ... Wingtra custom tables ...
]

# Tables whose COPY blocks the dump filter skips during restore.
# These never enter Postgres, so they cost zero time/storage.
EXCLUDE_TABLES: list[str] = [
    "ir_attachment",
    "mail_message",
    "mail_tracking_value",
    "mail_followers",
    "mail_notification",
    "mail_activity",
    "mail_message_subtype",
    "bus_bus",
    "bus_presence",
    "ir_logging",
    "ir_cron",
    "ir_translation",
    "base_import_import",
    "base_import_mapping",
    # ... add others from analysis
]
```

### 7.2 `src/dump_filter.py`

Streaming filter that drops COPY blocks for excluded tables.

```python
"""Filter a plain-SQL pg_dump on the fly, skipping COPY blocks for excluded tables.

Reads from stdin, writes to stdout. Schema statements (CREATE TABLE, indexes,
etc.) always pass through -- empty tables for excluded models are fine and keep
the schema consistent.
"""
import re
import sys
from typing import Iterable

COPY_START = re.compile(r'^COPY\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s*\(')


def filter_stream(stdin, stdout, exclude: set[str]) -> dict[str, int]:
    """Returns counts: rows skipped per table."""
    skipping_table = None
    skipped_counts: dict[str, int] = {}

    for line in stdin:
        if skipping_table is not None:
            if line.rstrip() == r"\.":
                skipping_table = None
            else:
                skipped_counts[skipping_table] = skipped_counts.get(skipping_table, 0) + 1
            continue

        m = COPY_START.match(line)
        if m and m.group(1) in exclude:
            skipping_table = m.group(1)
            continue

        stdout.write(line)

    return skipped_counts


def main():
    from src.tables import EXCLUDE_TABLES
    exclude = set(EXCLUDE_TABLES)
    skipped = filter_stream(sys.stdin, sys.stdout, exclude)
    for table, count in sorted(skipped.items(), key=lambda kv: -kv[1]):
        print(f"  skipped {count:>12,} rows from {table}", file=sys.stderr)


if __name__ == "__main__":
    main()
```

### 7.3 `src/fetch_backup.py`

```python
"""SSH to Odoo.sh, download newest backup, upload to GCS.

Uses SSH+SCP via subprocess instead of Paramiko/SFTP. Odoo.sh does not support
SFTP (protocol errors), but SCP with the -O flag (legacy protocol) works.
The SSH private key is fetched from Secret Manager and written to a temp file
for the duration of the connection.
"""
import logging
import os
import subprocess
import tempfile
from datetime import datetime, timezone

from google.cloud import secretmanager, storage


log = logging.getLogger(__name__)

SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=30",
    "-o", "LogLevel=ERROR",
]


def _write_ssh_key() -> str:
    """Fetch SSH key from Secret Manager, write to temp file, return path."""
    client = secretmanager.SecretManagerServiceClient()
    project = os.environ["GCP_PROJECT"]
    name = f"projects/{project}/secrets/odoo-sh-ssh-key/versions/latest"
    response = client.access_secret_version(request={"name": name})
    key_data = response.payload.data

    key_file = tempfile.NamedTemporaryFile(delete=False, prefix="odoo_ssh_", mode="wb")
    key_file.write(key_data)
    key_file.close()
    os.chmod(key_file.name, 0o600)
    return key_file.name


def _ssh_cmd(key_path: str) -> list[str]:
    return ["ssh", "-i", key_path] + SSH_OPTS


def _ssh_target() -> str:
    return f"{os.environ['ODOO_SSH_USER']}@{os.environ['ODOO_SSH_HOST']}"


def fetch() -> str:
    """Pulls latest backup from Odoo.sh, uploads to GCS, returns local path."""
    host = os.environ["ODOO_SSH_HOST"]
    user = os.environ["ODOO_SSH_USER"]
    bucket_name = os.environ["GCS_BUCKET"]
    target = f"{user}@{host}"

    key_path = _write_ssh_key()
    try:
        # Step 1: List backups and find the newest .sql.gz
        log.info("Listing backups on %s", host)
        result = subprocess.run(
            _ssh_cmd(key_path) + [target,
                "ls -t ~/backup.daily/*.sql.gz 2>/dev/null | head -1"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise RuntimeError(
                f"Failed to list backups via SSH (rc={result.returncode}): "
                f"{result.stderr.strip()}"
            )
        remote_path = result.stdout.strip()
        filename = os.path.basename(remote_path)
        log.info("Newest backup: %s", filename)

        # Step 2: Check backup freshness (mtime)
        result = subprocess.run(
            _ssh_cmd(key_path) + [target,
                f"stat -c %Y {remote_path}"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            mtime = int(result.stdout.strip())
            age_hours = (datetime.now(timezone.utc) -
                         datetime.fromtimestamp(mtime, timezone.utc)
                         ).total_seconds() / 3600
            if age_hours > 36:
                raise RuntimeError(
                    f"Newest backup is {age_hours:.1f}h old ({filename}). "
                    "Expected <36h. Aborting to avoid loading stale data."
                )
            log.info("Backup age: %.1fh", age_hours)

        # Step 3: SCP download (legacy protocol with -O flag)
        local_path = f"/tmp/{filename}"
        log.info("Downloading via SCP to %s", local_path)
        subprocess.run(
            ["scp", "-O", "-i", key_path] + SSH_OPTS +
            [f"{target}:{remote_path}", local_path],
            check=True, timeout=600,
        )

        # Step 4: Upload to GCS archive
        date_prefix = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        gcs_key = f"odoo/{date_prefix}/{filename}"
        storage.Client().bucket(bucket_name).blob(gcs_key).upload_from_filename(
            local_path)
        log.info("Uploaded to gs://%s/%s", bucket_name, gcs_key)

        return local_path

    finally:
        os.unlink(key_path)
```

### 7.4 `src/restore.py`

```python
"""Restore a filtered Odoo backup into the in-container Postgres."""
import gzip
import logging
import os
import subprocess
from pathlib import Path

from src.dump_filter import filter_stream
from src.tables import EXCLUDE_TABLES


log = logging.getLogger(__name__)


def restore(local_dump_path: str) -> None:
    """Stream the .sql.gz through the filter into psql."""
    db = os.environ.get("PG_DATABASE", "odoo_restore")
    user = os.environ.get("PG_USER", "postgres")
    socket_dir = os.environ.get("PG_SOCKET_DIR", "/var/run/postgresql")

    # Drop/recreate target DB
    log.info("Recreating database %s", db)
    subprocess.run(["dropdb", "-h", socket_dir, "-U", user, "--if-exists", db], check=True)
    subprocess.run(["createdb", "-h", socket_dir, "-U", user, db], check=True)

    log.info("Restoring (filtered) from %s into %s", local_dump_path, db)
    exclude = set(EXCLUDE_TABLES)

    psql = subprocess.Popen(
        ["psql", "-h", socket_dir, "-U", user, "-d", db,
         "-v", "ON_ERROR_STOP=on", "--quiet"],
        stdin=subprocess.PIPE, text=True,
    )

    skipped = {}
    with gzip.open(local_dump_path, "rt", encoding="utf-8", errors="replace") as f:
        skipped = filter_stream(f, psql.stdin, exclude)
    psql.stdin.close()
    rc = psql.wait()
    if rc != 0:
        raise RuntimeError(f"psql restore failed with exit code {rc}")

    for table, count in sorted(skipped.items(), key=lambda kv: -kv[1])[:10]:
        log.info("  skipped %s: %d rows", table, count)
    log.info("Restore complete.")
```

### 7.5 `src/pipeline.py`

```python
"""Run dlt: in-container Postgres -> BigQuery."""
import logging
import os

import dlt
from dlt.sources.sql_database import sql_database
from sqlalchemy import create_engine

from src.tables import INCLUDE_TABLES


log = logging.getLogger(__name__)


def _pg_url() -> str:
    db = os.environ.get("PG_DATABASE", "odoo_restore")
    user = os.environ.get("PG_USER", "postgres")
    socket_dir = os.environ.get("PG_SOCKET_DIR", "/var/run/postgresql")
    return f"postgresql+psycopg2://{user}@/{db}?host={socket_dir}"


def run():
    engine = create_engine(_pg_url())
    source = sql_database(credentials=engine, table_names=INCLUDE_TABLES)

    pipeline = dlt.pipeline(
        pipeline_name="odoo_to_bq",
        destination="bigquery",
        dataset_name=os.environ.get("BQ_DATASET", "dl_odoo"),
        progress="log",
    )
    info = pipeline.run(source, write_disposition="replace")
    log.info("dlt load info: %s", info)
    return info
```

### 7.6 `src/metadata.py`

```python
"""Write pipeline run metadata to BigQuery for observability."""
import logging
import os
from datetime import datetime, timezone

from google.cloud import bigquery


log = logging.getLogger(__name__)


def record_run(
    status: str,
    table_row_counts: dict[str, int] | None = None,
    error_message: str | None = None,
    duration_seconds: float | None = None,
):
    """Insert a row into dl_odoo._pipeline_runs with run details."""
    client = bigquery.Client()
    dataset = os.environ.get("BQ_DATASET", "dl_odoo")
    table_ref = f"{os.environ['GCP_PROJECT']}.{dataset}._pipeline_runs"

    row = {
        "run_id": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S"),
        "started_at": datetime.now(timezone.utc).isoformat(),
        "status": status,
        "duration_seconds": duration_seconds,
        "error_message": error_message,
        "table_row_counts": table_row_counts,
    }

    errors = client.insert_rows_json(table_ref, [row])
    if errors:
        log.warning("Failed to write pipeline metadata: %s", errors)
    else:
        log.info("Pipeline metadata recorded: status=%s", status)
```

### 7.7 `src/main.py`

```python
"""Cloud Run Job entrypoint."""
import logging
import sys
import time

from src.fetch_backup import fetch
from src.restore import restore
from src.pipeline import run as run_dlt
from src.metadata import record_run


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("pipeline")


def main():
    start = time.monotonic()
    try:
        log.info("=== Step 1/3: fetch backup from Odoo.sh ===")
        local_path = fetch()
        log.info("=== Step 2/3: filter and restore into local Postgres ===")
        restore(local_path)
        log.info("=== Step 3/3: dlt load into BigQuery ===")
        run_dlt()
        duration = time.monotonic() - start
        log.info("=== Pipeline complete (%.0fs) ===", duration)
        record_run(status="success", duration_seconds=duration)
    except Exception as e:
        duration = time.monotonic() - start
        log.exception("Pipeline failed after %.0fs", duration)
        record_run(status="failed", error_message=str(e), duration_seconds=duration)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

### 7.8 `requirements.txt`

```
dlt[bigquery,sql_database]>=0.5.0
google-cloud-storage>=2.16.0
google-cloud-secret-manager>=2.20.0
google-cloud-bigquery>=3.20.0
SQLAlchemy>=2.0
psycopg2-binary>=2.9.9
```

### 7.9 `Dockerfile`

```dockerfile
# Postgres major version MUST match Odoo.sh's version (gathered in prerequisites)
ARG PG_VERSION=16
FROM postgres:${PG_VERSION}-bookworm

# Install Python 3 + pip + SSH client (for SCP to Odoo.sh)
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps in a venv to avoid clashing with Debian's PEP 668 lock
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["/entrypoint.sh"]
```

### 7.10 `docker/entrypoint.sh`

```bash
#!/bin/bash
set -euo pipefail

PGDATA=${PGDATA:-/var/lib/postgresql/data}
SOCKET_DIR=/var/run/postgresql

# Initialize data directory on first boot (always, since container is ephemeral)
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "Initializing Postgres data directory at $PGDATA"
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  su postgres -c "/usr/lib/postgresql/${PG_MAJOR}/bin/initdb -D $PGDATA --auth=trust --no-locale --encoding=UTF8"
fi

mkdir -p "$SOCKET_DIR"
chown postgres:postgres "$SOCKET_DIR"

echo "Starting Postgres in background"
su postgres -c "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_ctl -D $PGDATA -l /tmp/pg.log -w start -o '-c unix_socket_directories=$SOCKET_DIR -c listen_addresses=\"\"'"

echo "Postgres ready. Running pipeline."
export PG_SOCKET_DIR=$SOCKET_DIR
exec python3 -m src.main
```

### Verification gate (Phase 2)

Locally (no Cloud Run yet):

1. Build the image: `docker build -t odoo-pipeline:dev .`
2. Run with mounted creds:
   ```bash
   docker run --rm \
     -e GCP_PROJECT=${PROJECT} \
     -e GCS_BUCKET=${PROJECT}-odoo-backups \
     -e ODOO_SSH_HOST=... \
     -e ODOO_SSH_USER=... \
     -e BQ_DATASET=dl_odoo \
     -v ${HOME}/.config/gcloud:/root/.config/gcloud:ro \
     odoo-pipeline:dev
   ```
3. Confirm logs show: SSH connect → download → upload to GCS → Postgres start → restore (with skip counts) → dlt load → metadata written → complete
4. `bq query 'SELECT COUNT(*) FROM dl_odoo.res_partner'` returns a sensible row count
5. `bq query 'SELECT * FROM dl_odoo._pipeline_runs ORDER BY started_at DESC LIMIT 1'` shows a successful run
6. Spot-check 2 more tables: e.g. `sale_order`, `account_move`

Have user confirm before proceeding.

## 8. Phase 3 — Build & deploy

Implement as `infra/deploy.sh`.

### 8.1 Build and push image

```bash
gcloud builds submit \
  --tag ${REGION}-docker.pkg.dev/${PROJECT}/odoo-pipeline/runner:latest \
  --substitutions=_PG_VERSION=${PG_VERSION}
```

### 8.2 Create / update Cloud Run Job

```bash
gcloud run jobs deploy odoo-to-bq \
  --image=${REGION}-docker.pkg.dev/${PROJECT}/odoo-pipeline/runner:latest \
  --region=${REGION} \
  --service-account=odoo-pipeline@${PROJECT}.iam.gserviceaccount.com \
  --set-env-vars=\
GCP_PROJECT=${PROJECT},\
GCS_BUCKET=${PROJECT}-odoo-backups,\
ODOO_SSH_HOST=${ODOO_SSH_HOST},\
ODOO_SSH_USER=${ODOO_SSH_USER},\
BQ_DATASET=dl_odoo,\
PG_DATABASE=odoo_restore,\
PG_USER=postgres \
  --task-timeout=3600 \
  --max-retries=1 \
  --memory=4Gi \
  --cpu=2
```

Tune `--memory` and `--task-timeout` based on what testing shows. Starting points:
- 4 GiB memory -- enough for a filtered DB under ~2GB with Postgres + Python
- 3600s timeout -- should be 5-15 min total in practice; bump if dump grows

### Verification gate (Phase 3)

- `gcloud run jobs describe odoo-to-bq --region=${REGION}` shows the job exists
- Trigger manually: `gcloud run jobs execute odoo-to-bq --region=${REGION} --wait`
- Tail logs: `gcloud logging tail "resource.type=cloud_run_job"`
- Confirm successful exit and BigQuery row counts updated
- `bq query 'SELECT * FROM dl_odoo._pipeline_runs ORDER BY started_at DESC LIMIT 1'` shows success

## 9. Phase 4 — Schedule

```bash
gcloud scheduler jobs create http odoo-pipeline-daily \
  --location=${REGION} \
  --schedule="0 4 * * *" \
  --time-zone="Etc/UTC" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/odoo-to-bq:run" \
  --http-method=POST \
  --oauth-service-account-email=odoo-pipeline@${PROJECT}.iam.gserviceaccount.com
```

Adjust the cron if Odoo.sh's daily backup isn't ready by 04:00 UTC. Ask user when the backup is typically complete.

### Verification gate (Phase 4)

- `gcloud scheduler jobs list --location=${REGION}` shows the job
- `gcloud scheduler jobs run odoo-pipeline-daily --location=${REGION}` triggers an execution
- Cloud Scheduler execution log shows 200 OK from the Cloud Run Job invocation
- Next scheduled run completes successfully

## 10. Phase 5 — Verify & smoke test

After the first scheduled run:

```sql
-- BigQuery: top-level row count check
SELECT
  table_name,
  total_rows
FROM `${PROJECT}.dl_odoo.__TABLES__`
ORDER BY total_rows DESC;
```

Cross-reference 3-5 tables against Odoo:
- `res_partner` row count → compare to Odoo UI count
- `sale_order` → same
- `account_move` → same
- Any Wingtra custom table → same

If counts match within ~1% (some movement is expected between backup time and check time), you're done.

### Final delivery checklist

- [ ] Phase 1: GCP infra provisioned, all 5 IAM roles set, SSH key in Secret Manager
- [ ] Phase 2: Code committed, local Docker run completes end-to-end, BigQuery has rows
- [ ] Phase 3: Cloud Run Job deployed, manual execution succeeds
- [ ] Phase 4: Cloud Scheduler created, first triggered run succeeds
- [ ] Phase 5: Row counts cross-referenced; pipeline accepted by user
- [ ] README.md written with: how to re-deploy, how to update table lists, how to debug failed runs, how new Odoo tables are handled
- [ ] Phase 6: Local ADC credentials revoked

## 11. Risks & known gotchas

| Risk | Mitigation |
|---|---|
| PG version mismatch between Odoo.sh and Docker image | Verify in prerequisites; pin `PG_VERSION` build arg explicitly |
| Odoo.sh backup not yet ready at scheduled run | Schedule conservatively (04:00 UTC); freshness check in fetch_backup.py fails fast if newest backup is >36h old |
| Cloud Run Job out-of-memory on restore | Start at 4 GiB; monitor and bump (max 32 GiB on Cloud Run Jobs) |
| Disk filling up in container | Cloud Run Jobs provide ample ephemeral disk; if needed, set `--task-temp-storage` or stream backup directly from GCS into psql without local copy |
| New tables added in Odoo aren't in INCLUDE_TABLES | Won't reach BigQuery until manually added. See README for the maintenance procedure |
| dlt schema evolution breaks downstream queries | dlt handles schema changes; document for downstream consumers |
| Odoo.sh SSH host key not pinned | Odoo.sh uses ephemeral SSH containers with rotating host keys; StrictHostKeyChecking=no is used. Risk is low (backup data is ours, private key still required) |
| Odoo.sh SSH availability | SSH container is on-demand, SFTP is not supported. Pipeline uses SSH+SCP with legacy -O flag. If SSH becomes unreliable, fall back to push-from-Odoo or web UI download automation |
| SSH private key compromised | Rotate via Secret Manager; remove old key from Odoo.sh |
| Sensitive PII in BigQuery (`res_partner`, `hr_employee`) | Flag for user; consider BigQuery column-level policy tags later |

## 12. Phase 6 -- Cleanup

After the pipeline is deployed and running in Cloud Run:

```bash
# Remove local Application Default Credentials (created for local Docker testing)
gcloud auth application-default revoke
```

This removes the OAuth token at `~/.config/gcloud/application_default_credentials.json`. It was only needed to let the local Docker container authenticate with GCP during testing. In production, the Cloud Run service account handles authentication automatically.

## 13. Out of scope

Explicitly not part of this build:
- dbt or any modeling layer
- Real-time / sub-daily refresh
- Alerting on pipeline failure (add Cloud Monitoring alert post-launch; `_pipeline_runs` table supports manual checks in the meantime)
- Backfill of historical pre-pipeline data (the first run loads everything)
- Cost dashboards
- Multi-environment (dev/staging/prod) setup -- single environment for now
- Data quality testing (great_expectations etc.)

## 14. Communication protocol with the user during execution

- After each phase verification gate, summarize what was done and what to check; wait for confirmation.
- If a step requires sensitive input (SSH key, credentials), ask the user to run the `gcloud secrets` command themselves rather than ever displaying or persisting the secret value.
- If costs differ materially from the dump-analysis estimate, flag immediately rather than continuing.
- Final delivery: a short README in the repo plus a short summary message explaining how to monitor and how to extend.
