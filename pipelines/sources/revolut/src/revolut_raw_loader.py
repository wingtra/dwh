"""Revolut Business API -> GCS raw landing -> BigQuery DL append tables.

This loader is intentionally raw-only. It does not run downstream transformations
and does not depend on the Odoo/Postgres pipeline image. The DL tables are
append-only extraction logs; CL is responsible for deduping to the latest
source-conformed state.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal, InvalidOperation
from typing import Any

import jwt
import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery, secretmanager, storage
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("revolut_raw_loader")


PROJECT = os.environ.get("GCP_PROJECT", "wingtra-dwh")
BQ_LOCATION = os.environ.get("BQ_LOCATION", "europe-west1")
BQ_DATASET = os.environ.get("REVOLUT_BQ_DATASET", "dl_revolut")
RAW_BUCKET = os.environ.get("REVOLUT_RAW_BUCKET")
RAW_PREFIX = os.environ.get("REVOLUT_RAW_PREFIX", "revolut").strip("/")
API_BASE_URL = os.environ.get(
    "REVOLUT_API_BASE_URL",
    "https://b2b.revolut.com/api/1.0",
).rstrip("/")
TOKEN_URL = os.environ.get("REVOLUT_TOKEN_URL", f"{API_BASE_URL}/auth/token")
CLIENT_ID = os.environ.get("REVOLUT_CLIENT_ID")
JWT_ISSUER = os.environ.get("REVOLUT_JWT_ISSUER")
JWT_AUDIENCE = os.environ.get("REVOLUT_JWT_AUDIENCE", "https://revolut.com")
JWT_TTL_SECONDS = int(os.environ.get("REVOLUT_JWT_TTL_SECONDS", "300"))
PRIVATE_KEY_SECRET = os.environ.get(
    "REVOLUT_PRIVATE_KEY_SECRET",
    "revolut-business-api-private-key",
)
REFRESH_TOKEN_SECRET = os.environ.get(
    "REVOLUT_REFRESH_TOKEN_SECRET",
    "revolut-business-api-refresh-token",
)
START_CREATED_AT = os.environ.get("REVOLUT_START_CREATED_AT", "2026-01-01T00:00:00Z")
EXPENSE_START_DATE = os.environ.get("REVOLUT_EXPENSE_START_DATE", START_CREATED_AT)
PAGE_SIZE = int(os.environ.get("REVOLUT_PAGE_SIZE", "1000"))
MAX_PAGES = int(os.environ.get("REVOLUT_MAX_PAGES", "100"))
HTTP_TIMEOUT_SECONDS = int(os.environ.get("REVOLUT_HTTP_TIMEOUT_SECONDS", "60"))
LOOKBACK_DAYS = int(os.environ.get("REVOLUT_LOOKBACK_DAYS", "31"))
CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
TRANSACTION_WATERMARK_RESOURCE = "transactions.created_at"


TRANSACTIONS_SCHEMA = [
    bigquery.SchemaField("run_id", "STRING"),
    bigquery.SchemaField("extracted_at", "TIMESTAMP"),
    bigquery.SchemaField("request_from_created_at", "TIMESTAMP"),
    bigquery.SchemaField("request_to_created_at", "TIMESTAMP"),
    bigquery.SchemaField("page_number", "INT64"),
    bigquery.SchemaField("row_index", "INT64"),
    bigquery.SchemaField("gcs_uri", "STRING"),
    bigquery.SchemaField("transaction_leg_key", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("transaction_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("leg_id", "STRING"),
    bigquery.SchemaField("transaction_type", "STRING"),
    bigquery.SchemaField("transaction_state", "STRING"),
    bigquery.SchemaField("reason_code", "STRING"),
    bigquery.SchemaField("request_id", "STRING"),
    bigquery.SchemaField("created_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("updated_at", "TIMESTAMP"),
    bigquery.SchemaField("completed_at", "TIMESTAMP"),
    bigquery.SchemaField("scheduled_for", "TIMESTAMP"),
    bigquery.SchemaField("related_transaction_id", "STRING"),
    bigquery.SchemaField("reference", "STRING"),
    bigquery.SchemaField("merchant_id", "STRING"),
    bigquery.SchemaField("merchant_name", "STRING"),
    bigquery.SchemaField("merchant_city", "STRING"),
    bigquery.SchemaField("merchant_category_code", "STRING"),
    bigquery.SchemaField("merchant_country", "STRING"),
    bigquery.SchemaField("leg_amount_raw", "STRING"),
    bigquery.SchemaField("leg_amount_numeric", "NUMERIC"),
    bigquery.SchemaField("leg_amount", "FLOAT64"),
    bigquery.SchemaField("leg_fee_raw", "STRING"),
    bigquery.SchemaField("leg_fee_numeric", "NUMERIC"),
    bigquery.SchemaField("leg_fee", "FLOAT64"),
    bigquery.SchemaField("leg_currency", "STRING"),
    bigquery.SchemaField("bill_amount_raw", "STRING"),
    bigquery.SchemaField("bill_amount_numeric", "NUMERIC"),
    bigquery.SchemaField("bill_amount", "FLOAT64"),
    bigquery.SchemaField("bill_currency", "STRING"),
    bigquery.SchemaField("account_id", "STRING"),
    bigquery.SchemaField("counterparty_account_id", "STRING"),
    bigquery.SchemaField("counterparty_account_type", "STRING"),
    bigquery.SchemaField("counterparty_id", "STRING"),
    bigquery.SchemaField("counterparty_description", "STRING"),
    bigquery.SchemaField("balance_raw", "STRING"),
    bigquery.SchemaField("balance_numeric", "NUMERIC"),
    bigquery.SchemaField("balance", "FLOAT64"),
    bigquery.SchemaField("card_first_name", "STRING"),
    bigquery.SchemaField("card_last_name", "STRING"),
    bigquery.SchemaField("transaction_raw_json", "JSON"),
    bigquery.SchemaField("leg_raw_json", "JSON"),
    bigquery.SchemaField("loaded_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("_dlt_deleted_at", "TIMESTAMP"),
]

ACCOUNTS_SCHEMA = [
    bigquery.SchemaField("run_id", "STRING"),
    bigquery.SchemaField("extracted_at", "TIMESTAMP"),
    bigquery.SchemaField("gcs_uri", "STRING"),
    bigquery.SchemaField("account_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("name", "STRING"),
    bigquery.SchemaField("currency", "STRING"),
    bigquery.SchemaField("state", "STRING"),
    bigquery.SchemaField("balance_raw", "STRING"),
    bigquery.SchemaField("balance_numeric", "NUMERIC"),
    bigquery.SchemaField("balance", "FLOAT64"),
    bigquery.SchemaField("is_public", "BOOL"),
    bigquery.SchemaField("created_at", "TIMESTAMP"),
    bigquery.SchemaField("updated_at", "TIMESTAMP"),
    bigquery.SchemaField("account_raw_json", "JSON"),
    bigquery.SchemaField("loaded_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("_dlt_deleted_at", "TIMESTAMP"),
]

EXPENSES_SCHEMA = [
    bigquery.SchemaField("run_id", "STRING"),
    bigquery.SchemaField("extracted_at", "TIMESTAMP"),
    bigquery.SchemaField("request_from_expense_date", "TIMESTAMP"),
    bigquery.SchemaField("request_to_expense_date", "TIMESTAMP"),
    bigquery.SchemaField("page_number", "INT64"),
    bigquery.SchemaField("row_index", "INT64"),
    bigquery.SchemaField("gcs_uri", "STRING"),
    bigquery.SchemaField("expense_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("expense_state", "STRING"),
    bigquery.SchemaField("transaction_type", "STRING"),
    bigquery.SchemaField("transaction_id", "STRING"),
    bigquery.SchemaField("description", "STRING"),
    bigquery.SchemaField("payer", "STRING"),
    bigquery.SchemaField("merchant", "STRING"),
    bigquery.SchemaField("expense_date", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("submitted_at", "TIMESTAMP"),
    bigquery.SchemaField("completed_at", "TIMESTAMP"),
    bigquery.SchemaField("labels", "JSON"),
    bigquery.SchemaField("splits", "JSON"),
    bigquery.SchemaField("receipt_ids", "JSON"),
    bigquery.SchemaField("spent_amount_raw", "STRING"),
    bigquery.SchemaField("spent_amount_numeric", "NUMERIC"),
    bigquery.SchemaField("spent_amount", "FLOAT64"),
    bigquery.SchemaField("spent_currency", "STRING"),
    bigquery.SchemaField("expense_raw_json", "JSON"),
    bigquery.SchemaField("loaded_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("_dlt_deleted_at", "TIMESTAMP"),
]

RUNS_SCHEMA = [
    bigquery.SchemaField("run_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("started_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("finished_at", "TIMESTAMP"),
    bigquery.SchemaField("status", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("from_created_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("to_created_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("watermark_before", "TIMESTAMP"),
    bigquery.SchemaField("watermark_after", "TIMESTAMP"),
    bigquery.SchemaField("transactions_fetched", "INT64"),
    bigquery.SchemaField("transaction_legs_loaded", "INT64"),
    bigquery.SchemaField("accounts_loaded", "INT64"),
    bigquery.SchemaField("expenses_fetched", "INT64"),
    bigquery.SchemaField("expenses_loaded", "INT64"),
    bigquery.SchemaField("expense_pages_fetched", "INT64"),
    bigquery.SchemaField("expense_from_date", "TIMESTAMP"),
    bigquery.SchemaField("expense_to_date", "TIMESTAMP"),
    bigquery.SchemaField("pages_fetched", "INT64"),
    bigquery.SchemaField("gcs_objects_written", "INT64"),
    bigquery.SchemaField("error_message", "STRING"),
]

API_REQUESTS_SCHEMA = [
    bigquery.SchemaField("run_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("request_id", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("requested_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("path", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("params_json", "JSON"),
    bigquery.SchemaField("status_code", "INT64"),
    bigquery.SchemaField("duration_ms", "INT64"),
    bigquery.SchemaField("page_number", "INT64"),
    bigquery.SchemaField("row_count", "INT64"),
    bigquery.SchemaField("cursor_created_at", "TIMESTAMP"),
    bigquery.SchemaField("error_message", "STRING"),
]

WATERMARKS_SCHEMA = [
    bigquery.SchemaField("resource", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("watermark_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("updated_at", "TIMESTAMP", mode="REQUIRED"),
    bigquery.SchemaField("run_id", "STRING", mode="REQUIRED"),
]


@dataclass
class PageResult:
    rows: list[dict[str, Any]]
    page_number: int
    gcs_uri: str
    cursor_created_at: str | None


class ApiRequestRecorder:
    def __init__(self, run_id: str):
        self.run_id = run_id
        self.rows: list[dict[str, Any]] = []

    def record(
        self,
        path: str,
        params: dict[str, Any] | None,
        status_code: int | None,
        duration_ms: int,
        page_number: int | None = None,
        row_count: int | None = None,
        cursor_created_at: str | None = None,
        error_message: str | None = None,
    ) -> None:
        self.rows.append(
            {
                "run_id": self.run_id,
                "request_id": uuid.uuid4().hex,
                "requested_at": _utc_now(),
                "path": path,
                "params_json": params or {},
                "status_code": status_code,
                "duration_ms": duration_ms,
                "page_number": page_number,
                "row_count": row_count,
                "cursor_created_at": cursor_created_at,
                "error_message": error_message,
            }
        )


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _parse_utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def _as_jsonl(rows: list[dict[str, Any]]) -> str:
    return "".join(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n" for row in rows)


def _as_raw(value: Any) -> str | None:
    if value is None or value == "":
        return None
    return str(value)


def _as_numeric_string(value: Any) -> str | None:
    raw = _as_raw(value)
    if raw is None:
        return None
    try:
        return str(Decimal(raw))
    except (InvalidOperation, ValueError):
        return None


def _as_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    return float(value)


def _retry_session() -> requests.Session:
    retry = Retry(
        total=5,
        connect=5,
        read=5,
        status=5,
        backoff_factor=1,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(["GET", "POST"]),
        respect_retry_after_header=True,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session = requests.Session()
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def _secret_value(secret_name: str) -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{PROJECT}/secrets/{secret_name}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("utf-8").strip()


def _credential_value(env_name: str, file_env_name: str, secret_name: str) -> str:
    env_value = os.environ.get(env_name)
    if env_value:
        return env_value.replace("\\n", "\n")

    file_path = os.environ.get(file_env_name)
    if file_path:
        with open(file_path, encoding="utf-8") as handle:
            return handle.read().strip()

    return _secret_value(secret_name)


def _client_assertion(private_key: str) -> str:
    if not CLIENT_ID:
        raise ValueError("REVOLUT_CLIENT_ID is required")
    if not JWT_ISSUER:
        raise ValueError("REVOLUT_JWT_ISSUER is required")

    now = datetime.now(UTC)
    payload = {
        "iss": JWT_ISSUER,
        "sub": CLIENT_ID,
        "aud": JWT_AUDIENCE,
        "exp": now + timedelta(seconds=JWT_TTL_SECONDS),
        "iat": now,
    }
    return jwt.encode(payload, private_key, algorithm="RS256", headers={"typ": "JWT"})


def _access_token() -> str:
    private_key = _credential_value(
        "REVOLUT_PRIVATE_KEY",
        "REVOLUT_PRIVATE_KEY_FILE",
        PRIVATE_KEY_SECRET,
    )
    refresh_token = _credential_value(
        "REVOLUT_REFRESH_TOKEN",
        "REVOLUT_REFRESH_TOKEN_FILE",
        REFRESH_TOKEN_SECRET,
    )
    response = _retry_session().post(
        TOKEN_URL,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data={
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_assertion_type": CLIENT_ASSERTION_TYPE,
            "client_assertion": _client_assertion(private_key),
        },
        timeout=HTTP_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    data = response.json()
    token = data.get("access_token")
    if not token:
        raise ValueError("Revolut token refresh did not return access_token")
    if data.get("refresh_token") and data["refresh_token"] != refresh_token:
        log.warning(
            "Revolut returned a rotated refresh token; persistence is not enabled yet. "
            "Update Secret Manager manually or grant secret version writer and implement rotation."
        )
    return token


class RevolutClient:
    def __init__(self, token: str, recorder: ApiRequestRecorder):
        self.recorder = recorder
        self.session = _retry_session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            }
        )

    def _get(
        self,
        path: str,
        params: dict[str, Any] | None = None,
        page_number: int | None = None,
        cursor_field: str = "created_at",
    ) -> Any:
        url = f"{API_BASE_URL}/{path.lstrip('/')}"
        started = time.monotonic()
        status_code = None
        try:
            response = self.session.get(url, params=params, timeout=HTTP_TIMEOUT_SECONDS)
            status_code = response.status_code
            response.raise_for_status()
            data = response.json()
            row_count = len(data) if isinstance(data, list) else None
            cursor = data[-1].get(cursor_field) if isinstance(data, list) and data else None
            self.recorder.record(
                path=path,
                params=params,
                status_code=status_code,
                duration_ms=int((time.monotonic() - started) * 1000),
                page_number=page_number,
                row_count=row_count,
                cursor_created_at=cursor,
            )
            return data
        except Exception as exc:
            self.recorder.record(
                path=path,
                params=params,
                status_code=status_code,
                duration_ms=int((time.monotonic() - started) * 1000),
                page_number=page_number,
                error_message=str(exc),
            )
            raise

    def accounts(self) -> list[dict[str, Any]]:
        data = self._get("/accounts")
        if isinstance(data, dict):
            return data.get("accounts", [])
        if isinstance(data, list):
            return data
        raise ValueError(f"Unexpected accounts response shape: {type(data)}")

    def _pages_backwards(
        self,
        path: str,
        cursor_field: str,
        from_value: str,
        to_value: str,
        page_size: int,
        label: str,
    ) -> list[tuple[int, list[dict[str, Any]]]]:
        """Paginate a list endpoint backwards by a timestamp cursor field."""
        pages: list[tuple[int, list[dict[str, Any]]]] = []
        seen_ids: set[str] = set()
        page_to = to_value

        for page_number in range(1, MAX_PAGES + 1):
            params = {
                "from": from_value,
                "to": page_to,
                "count": page_size,
            }
            page = self._get(path, params=params, page_number=page_number, cursor_field=cursor_field)
            if not page:
                break
            if not isinstance(page, list):
                raise ValueError(f"Unexpected {label} response shape: {type(page)}")

            new_rows = []
            for row in page:
                row_id = row.get("id")
                if row_id and row_id in seen_ids:
                    continue
                if row_id:
                    seen_ids.add(row_id)
                new_rows.append(row)

            last_cursor = page[-1].get(cursor_field)
            first_cursor = page[0].get(cursor_field)
            log.info(
                "Fetched %s page %s: %s rows, %s new, first_%s=%s, last_%s=%s",
                label,
                page_number,
                len(page),
                len(new_rows),
                cursor_field,
                first_cursor,
                cursor_field,
                last_cursor,
            )

            if new_rows:
                pages.append((page_number, new_rows))

            if len(page) < page_size or not last_cursor or not new_rows:
                break
            if last_cursor <= from_value:
                break
            if last_cursor >= page_to:
                raise ValueError(
                    f"Revolut {label} pagination did not move backwards by {cursor_field}; "
                    f"page_to={page_to}, last_{cursor_field}={last_cursor}"
                )
            if len(page) == page_size and first_cursor == last_cursor:
                raise ValueError(
                    f"Ambiguous Revolut {label} pagination: full page has identical {cursor_field} values. "
                    "Cannot safely advance without a cursor/tie-breaker."
                )
            page_to = last_cursor
        else:
            raise ValueError(f"Reached REVOLUT_MAX_PAGES={MAX_PAGES}; refusing to silently truncate")

        return pages

    def transaction_pages(self, from_created_at: str, to_created_at: str) -> list[tuple[int, list[dict[str, Any]]]]:
        return self._pages_backwards(
            "/transactions", "created_at", from_created_at, to_created_at, PAGE_SIZE, "transaction"
        )

    def expense_pages(self, from_expense_date: str, to_expense_date: str) -> list[tuple[int, list[dict[str, Any]]]]:
        """Fetch the current expense state as append-only snapshots.

        The Expenses API only paginates by ``expense_date`` and does not expose
        an update timestamp, so the caller re-reads the full window from
        REVOLUT_EXPENSE_START_DATE to recapture state, category, and receipt
        changes on old expenses. The API caps page size at 500.
        """
        return self._pages_backwards(
            "/expenses", "expense_date", from_expense_date, to_expense_date, min(PAGE_SIZE, 500), "expense"
        )


def _table_id(table_name: str) -> str:
    return f"{PROJECT}.{BQ_DATASET}.{table_name}"


def _ensure_dataset(client: bigquery.Client) -> None:
    dataset_ref = bigquery.DatasetReference(PROJECT, BQ_DATASET)
    try:
        client.get_dataset(dataset_ref)
        return
    except NotFound:
        pass

    dataset = bigquery.Dataset(dataset_ref)
    dataset.location = BQ_LOCATION
    dataset.description = "Raw Revolut Business data loaded from immutable API extracts."
    client.create_dataset(dataset)
    log.info("Created dataset %s", dataset_ref.path)


def _ensure_table(client: bigquery.Client, table_name: str, schema: list[bigquery.SchemaField]) -> None:
    table_ref = _table_id(table_name)
    try:
        table = client.get_table(table_ref)
        existing_columns = {field.name for field in table.schema}
        missing_columns = [field for field in schema if field.name not in existing_columns]
        if missing_columns:
            table.schema = [*table.schema, *missing_columns]
            client.update_table(table, ["schema"])
            log.info("Added columns to %s: %s", table_ref, ", ".join(field.name for field in missing_columns))
        return
    except NotFound:
        pass

    table = bigquery.Table(table_ref, schema=schema)
    client.create_table(table)
    log.info("Created table %s", table_ref)


def _load_append(
    client: bigquery.Client,
    table_name: str,
    rows: list[dict[str, Any]],
    schema: list[bigquery.SchemaField],
) -> int:
    if not rows:
        return 0
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
    )
    job = client.load_table_from_json(
        rows,
        _table_id(table_name),
        job_config=job_config,
        location=BQ_LOCATION,
    )
    job.result()
    return len(rows)


def _merge_one(
    client: bigquery.Client,
    table_name: str,
    schema: list[bigquery.SchemaField],
    key_columns: list[str],
    row: dict[str, Any],
) -> None:
    staging_name = f"{table_name}_stage_{uuid.uuid4().hex[:12]}"
    staging_id = _table_id(staging_name)
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
    )
    client.load_table_from_json([row], staging_id, job_config=job_config, location=BQ_LOCATION).result()

    columns = [field.name for field in schema]
    update_columns = [column for column in columns if column not in key_columns]
    on_clause = " and ".join([f"T.{column} = S.{column}" for column in key_columns])
    update_clause = ",\n            ".join([f"{column} = S.{column}" for column in update_columns])
    insert_columns = ", ".join(columns)
    insert_values = ", ".join([f"S.{column}" for column in columns])
    sql = f"""
        merge `{_table_id(table_name)}` T
        using `{staging_id}` S
        on {on_clause}
        when matched then update set
            {update_clause}
        when not matched then insert ({insert_columns})
        values ({insert_values})
    """
    try:
        client.query(sql, location=BQ_LOCATION).result()
    finally:
        client.delete_table(staging_id, not_found_ok=True)


def _current_watermark(client: bigquery.Client, resource: str, default: str) -> str:
    sql = f"""
        select watermark_at
        from `{_table_id('_watermarks')}`
        where resource = @resource
        order by updated_at desc
        limit 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("resource", "STRING", resource)]
    )
    rows = list(client.query(sql, job_config=job_config, location=BQ_LOCATION).result())
    if not rows:
        return default
    watermark = rows[0]["watermark_at"]
    if isinstance(watermark, datetime):
        return watermark.astimezone(UTC).isoformat().replace("+00:00", "Z")
    return str(watermark).replace("+00:00", "Z")


def _window_start(watermark: str, start: str, lookback_days: int) -> str:
    parsed = _parse_utc(watermark)
    lookback = parsed - timedelta(days=lookback_days)
    floor = _parse_utc(start)
    return max(lookback, floor).isoformat().replace("+00:00", "Z")


def _record_run(client: bigquery.Client, row: dict[str, Any]) -> None:
    _merge_one(client, "_pipeline_runs", RUNS_SCHEMA, ["run_id"], row)


def _record_watermark(client: bigquery.Client, resource: str, watermark_at: str, run_id: str) -> None:
    _merge_one(
        client,
        "_watermarks",
        WATERMARKS_SCHEMA,
        ["resource"],
        {
            "resource": resource,
            "watermark_at": watermark_at,
            "updated_at": _utc_now(),
            "run_id": run_id,
        },
    )


def _write_jsonl(storage_client: storage.Client, object_name: str, rows: list[dict[str, Any]]) -> str:
    if not RAW_BUCKET:
        raise ValueError("REVOLUT_RAW_BUCKET is required")
    bucket = storage_client.bucket(RAW_BUCKET)
    blob = bucket.blob(object_name)
    blob.upload_from_string(_as_jsonl(rows), content_type="application/jsonl")
    return f"gs://{RAW_BUCKET}/{object_name}"


def _raw_object_name(kind: str, run_id: str, filename: str, extracted_at: str) -> str:
    extracted_date = _parse_utc(extracted_at).date().isoformat()
    return f"{RAW_PREFIX}/{kind}/extracted_date={extracted_date}/run_id={run_id}/{filename}"


def _leg_key(transaction: dict[str, Any], leg: dict[str, Any], index: int) -> str:
    transaction_id = transaction.get("id")
    leg_id = leg.get("leg_id") or leg.get("id")
    if leg_id:
        return f"{transaction_id}:{leg_id}"

    parts = [
        transaction_id,
        leg.get("account_id"),
        leg.get("currency"),
        str(leg.get("amount")),
        str(index),
    ]
    return ":".join([part or "" for part in parts])


def _account_rows(accounts: list[dict[str, Any]], run_id: str, extracted_at: str, gcs_uri: str) -> list[dict[str, Any]]:
    rows = []
    for account in accounts:
        balance = account.get("balance")
        rows.append(
            {
                "run_id": run_id,
                "extracted_at": extracted_at,
                "gcs_uri": gcs_uri,
                "account_id": account.get("id"),
                "name": account.get("name"),
                "currency": account.get("currency"),
                "state": account.get("state"),
                "balance_raw": _as_raw(balance),
                "balance_numeric": _as_numeric_string(balance),
                "balance": _as_float(balance),
                "is_public": account.get("public"),
                "created_at": account.get("created_at"),
                "updated_at": account.get("updated_at"),
                "account_raw_json": account,
                "loaded_at": extracted_at,
                "_dlt_deleted_at": None,
            }
        )
    return rows


def _transaction_rows(
    pages: list[PageResult],
    run_id: str,
    extracted_at: str,
    request_from: str,
    request_to: str,
) -> list[dict[str, Any]]:
    rows = []
    global_index = 0
    for page in pages:
        for transaction in page.rows:
            merchant = transaction.get("merchant") or {}
            card = transaction.get("card") or {}
            legs = transaction.get("legs") or []
            if not legs:
                legs = [{}]

            for leg_index, leg in enumerate(legs):
                counterparty = leg.get("counterparty") or transaction.get("counterparty") or {}
                leg_amount = leg.get("amount")
                leg_fee = leg.get("fee")
                bill_amount = leg.get("bill_amount") or transaction.get("amount")
                balance = leg.get("balance")
                rows.append(
                    {
                        "run_id": run_id,
                        "extracted_at": extracted_at,
                        "request_from_created_at": request_from,
                        "request_to_created_at": request_to,
                        "page_number": page.page_number,
                        "row_index": global_index,
                        "gcs_uri": page.gcs_uri,
                        "transaction_leg_key": _leg_key(transaction, leg, leg_index),
                        "transaction_id": transaction.get("id"),
                        "leg_id": leg.get("leg_id") or leg.get("id"),
                        "transaction_type": transaction.get("type"),
                        "transaction_state": transaction.get("state"),
                        "reason_code": transaction.get("reason_code"),
                        "request_id": transaction.get("request_id"),
                        "created_at": transaction.get("created_at"),
                        "updated_at": transaction.get("updated_at"),
                        "completed_at": transaction.get("completed_at"),
                        "scheduled_for": transaction.get("scheduled_for"),
                        "related_transaction_id": transaction.get("related_transaction_id"),
                        "reference": transaction.get("reference"),
                        "merchant_id": merchant.get("id"),
                        "merchant_name": merchant.get("name"),
                        "merchant_city": merchant.get("city"),
                        "merchant_category_code": merchant.get("category_code"),
                        "merchant_country": merchant.get("country"),
                        "leg_amount_raw": _as_raw(leg_amount),
                        "leg_amount_numeric": _as_numeric_string(leg_amount),
                        "leg_amount": _as_float(leg_amount),
                        "leg_fee_raw": _as_raw(leg_fee),
                        "leg_fee_numeric": _as_numeric_string(leg_fee),
                        "leg_fee": _as_float(leg_fee),
                        "leg_currency": leg.get("currency"),
                        "bill_amount_raw": _as_raw(bill_amount),
                        "bill_amount_numeric": _as_numeric_string(bill_amount),
                        "bill_amount": _as_float(bill_amount),
                        "bill_currency": leg.get("bill_currency") or transaction.get("currency"),
                        "account_id": leg.get("account_id"),
                        "counterparty_account_id": counterparty.get("account_id"),
                        "counterparty_account_type": counterparty.get("account_type"),
                        "counterparty_id": counterparty.get("id"),
                        "counterparty_description": counterparty.get("description"),
                        "balance_raw": _as_raw(balance),
                        "balance_numeric": _as_numeric_string(balance),
                        "balance": _as_float(balance),
                        "card_first_name": card.get("first_name"),
                        "card_last_name": card.get("last_name"),
                        "transaction_raw_json": transaction,
                        "leg_raw_json": leg,
                        "loaded_at": extracted_at,
                        "_dlt_deleted_at": None,
                    }
                )
                global_index += 1
    return rows


def _expense_rows(
    pages: list[PageResult],
    run_id: str,
    extracted_at: str,
    request_from: str,
    request_to: str,
) -> list[dict[str, Any]]:
    rows = []
    row_index = 0
    for page in pages:
        for expense in page.rows:
            spent_amount = expense.get("spent_amount") or {}
            amount = spent_amount.get("amount")
            rows.append(
                {
                    "run_id": run_id,
                    "extracted_at": extracted_at,
                    "request_from_expense_date": request_from,
                    "request_to_expense_date": request_to,
                    "page_number": page.page_number,
                    "row_index": row_index,
                    "gcs_uri": page.gcs_uri,
                    "expense_id": expense.get("id"),
                    "expense_state": expense.get("state"),
                    "transaction_type": expense.get("transaction_type"),
                    "transaction_id": expense.get("transaction_id"),
                    "description": expense.get("description"),
                    "payer": expense.get("payer"),
                    "merchant": expense.get("merchant"),
                    "expense_date": expense.get("expense_date"),
                    "submitted_at": expense.get("submitted_at"),
                    "completed_at": expense.get("completed_at"),
                    "labels": expense.get("labels") or {},
                    "splits": expense.get("splits") or [],
                    "receipt_ids": expense.get("receipt_ids") or [],
                    "spent_amount_raw": _as_raw(amount),
                    "spent_amount_numeric": _as_numeric_string(amount),
                    "spent_amount": _as_float(amount),
                    "spent_currency": spent_amount.get("currency"),
                    "expense_raw_json": expense,
                    "loaded_at": extracted_at,
                    "_dlt_deleted_at": None,
                }
            )
            row_index += 1
    return rows


def _prepare() -> bigquery.Client:
    client = bigquery.Client(project=PROJECT, location=BQ_LOCATION)
    _ensure_dataset(client)
    for table_name, schema in (
        ("transactions", TRANSACTIONS_SCHEMA),
        ("accounts", ACCOUNTS_SCHEMA),
        ("expenses", EXPENSES_SCHEMA),
        ("_pipeline_runs", RUNS_SCHEMA),
        ("_api_requests", API_REQUESTS_SCHEMA),
        ("_watermarks", WATERMARKS_SCHEMA),
    ):
        _ensure_table(client, table_name, schema)
    return client


def main() -> None:
    if not RAW_BUCKET:
        raise ValueError("REVOLUT_RAW_BUCKET is required")

    run_id = os.environ.get("REVOLUT_RUN_ID") or uuid.uuid4().hex
    started_at = _utc_now()
    extracted_at = started_at
    bq_client = _prepare()
    storage_client = storage.Client(project=PROJECT)
    recorder = ApiRequestRecorder(run_id)
    watermark_before = _current_watermark(bq_client, TRANSACTION_WATERMARK_RESOURCE, START_CREATED_AT)
    from_created_at = _window_start(watermark_before, START_CREATED_AT, LOOKBACK_DAYS)
    to_created_at = _utc_now()
    # Expenses have no source update timestamp, so every run re-reads the full
    # window from EXPENSE_START_DATE; a watermark would never narrow it.
    expense_from_date = EXPENSE_START_DATE
    expense_to_date = to_created_at
    start_monotonic = time.monotonic()

    run_row = {
        "run_id": run_id,
        "started_at": started_at,
        "finished_at": None,
        "status": "running",
        "from_created_at": from_created_at,
        "to_created_at": to_created_at,
        "watermark_before": watermark_before,
        "watermark_after": None,
        "transactions_fetched": 0,
        "transaction_legs_loaded": 0,
        "accounts_loaded": 0,
        "expenses_fetched": 0,
        "expenses_loaded": 0,
        "expense_pages_fetched": 0,
        "expense_from_date": expense_from_date,
        "expense_to_date": expense_to_date,
        "pages_fetched": 0,
        "gcs_objects_written": 0,
        "error_message": None,
    }
    _record_run(bq_client, run_row)

    try:
        revolut = RevolutClient(_access_token(), recorder)

        accounts = revolut.accounts()
        accounts_object = _raw_object_name("accounts", run_id, "accounts.jsonl", extracted_at)
        accounts_gcs_uri = _write_jsonl(storage_client, accounts_object, accounts)
        accounts_loaded = _load_append(
            bq_client,
            "accounts",
            _account_rows(accounts, run_id, extracted_at, accounts_gcs_uri),
            ACCOUNTS_SCHEMA,
        )

        raw_pages = revolut.transaction_pages(from_created_at, to_created_at)
        page_results: list[PageResult] = []
        for page_number, page_rows in raw_pages:
            object_name = _raw_object_name("transactions", run_id, f"page-{page_number:05d}.jsonl", extracted_at)
            gcs_uri = _write_jsonl(storage_client, object_name, page_rows)
            cursor = page_rows[-1].get("created_at") if page_rows else None
            page_results.append(
                PageResult(rows=page_rows, page_number=page_number, gcs_uri=gcs_uri, cursor_created_at=cursor)
            )

        transaction_rows = _transaction_rows(page_results, run_id, extracted_at, from_created_at, to_created_at)
        transaction_legs_loaded = _load_append(bq_client, "transactions", transaction_rows, TRANSACTIONS_SCHEMA)

        raw_expense_pages = revolut.expense_pages(expense_from_date, expense_to_date)
        expense_page_results: list[PageResult] = []
        for page_number, page_rows in raw_expense_pages:
            object_name = _raw_object_name("expenses", run_id, f"page-{page_number:05d}.jsonl", extracted_at)
            gcs_uri = _write_jsonl(storage_client, object_name, page_rows)
            cursor = page_rows[-1].get("expense_date") if page_rows else None
            expense_page_results.append(
                PageResult(rows=page_rows, page_number=page_number, gcs_uri=gcs_uri, cursor_created_at=cursor)
            )

        expense_rows = _expense_rows(
            expense_page_results, run_id, extracted_at, expense_from_date, expense_to_date
        )
        expenses_loaded = _load_append(bq_client, "expenses", expense_rows, EXPENSES_SCHEMA)
        _load_append(bq_client, "_api_requests", recorder.rows, API_REQUESTS_SCHEMA)
        _record_watermark(bq_client, TRANSACTION_WATERMARK_RESOURCE, to_created_at, run_id)

        finished_at = _utc_now()
        _record_run(
            bq_client,
            {
                **run_row,
                "finished_at": finished_at,
                "status": "success",
                "watermark_after": to_created_at,
                "transactions_fetched": sum(len(page.rows) for page in page_results),
                "transaction_legs_loaded": transaction_legs_loaded,
                "accounts_loaded": accounts_loaded,
                "expenses_fetched": sum(len(page.rows) for page in expense_page_results),
                "expenses_loaded": expenses_loaded,
                "expense_pages_fetched": len(expense_page_results),
                "pages_fetched": len(page_results) + len(expense_page_results),
                "gcs_objects_written": len(page_results) + len(expense_page_results) + 1,
            },
        )
        log.info(
            "Revolut raw load complete in %.0fs: %s transaction pages, %s transaction legs, %s expense pages, %s expenses, %s accounts",
            time.monotonic() - start_monotonic,
            len(page_results),
            transaction_legs_loaded,
            len(expense_page_results),
            expenses_loaded,
            accounts_loaded,
        )
    except Exception as exc:
        if recorder.rows:
            try:
                _load_append(bq_client, "_api_requests", recorder.rows, API_REQUESTS_SCHEMA)
            except Exception:
                log.exception("Failed to write API request audit rows after loader failure")
        _record_run(
            bq_client,
            {
                **run_row,
                "finished_at": _utc_now(),
                "status": "failed",
                "error_message": str(exc),
            },
        )
        raise


if __name__ == "__main__":
    main()
