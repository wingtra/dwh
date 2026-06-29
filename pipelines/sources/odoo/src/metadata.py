"""Write pipeline run metadata to BigQuery for observability."""
import logging
import os
from datetime import datetime, timezone

from google.cloud import bigquery

from src.config import GCP_PROJECT, BQ_DATASET


log = logging.getLogger(__name__)


_TABLE_SCHEMA = [
    bigquery.SchemaField("run_id", "STRING"),
    bigquery.SchemaField("started_at", "TIMESTAMP"),
    bigquery.SchemaField("status", "STRING"),
    bigquery.SchemaField("duration_seconds", "FLOAT64"),
    bigquery.SchemaField("error_message", "STRING"),
]


def _ensure_table(client: bigquery.Client, table_ref: str) -> None:
    try:
        client.get_table(table_ref)
    except Exception:
        table = bigquery.Table(table_ref, schema=_TABLE_SCHEMA)
        client.create_table(table)
        log.info("Created metadata table %s", table_ref)


def record_run(
    status: str,
    error_message: str | None = None,
    duration_seconds: float | None = None,
):
    """Insert a row into _pipeline_runs with run details."""
    try:
        client = bigquery.Client(project=GCP_PROJECT)
        table_ref = f"{GCP_PROJECT}.{BQ_DATASET}._pipeline_runs"
        _ensure_table(client, table_ref)

        row = {
            "run_id": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S"),
            "started_at": datetime.now(timezone.utc).isoformat(),
            "status": status,
            "duration_seconds": duration_seconds,
            "error_message": error_message,
        }

        errors = client.insert_rows_json(table_ref, [row])
        if errors:
            log.warning("Failed to write pipeline metadata: %s", errors)
        else:
            log.info("Pipeline metadata recorded: status=%s", status)
    except Exception:
        log.exception("Failed to record pipeline metadata (non-fatal)")
