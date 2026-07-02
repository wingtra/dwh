"""HubSpot CRM -> GCS raw pages -> BigQuery DL current mirrors.

The daily path is intentionally small:
fetch pages, archive raw evidence, stage rows, append extracts, MERGE current,
then advance the per-resource watermark. Missing from an incremental response
is never treated as deletion evidence.
"""

from __future__ import annotations

import logging
import os
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

try:
    from google.api_core.exceptions import NotFound
    from google.cloud import bigquery, secretmanager, storage
except ImportError:  # Allows local dry-runs without the full cloud SDK set.
    bigquery = None  # type: ignore[assignment]
    secretmanager = None  # type: ignore[assignment]
    storage = None  # type: ignore[assignment]

    class NotFound(Exception):
        pass


def schema_field(name: str, field_type: str, mode: str = "NULLABLE") -> Any:
    if bigquery is None:
        return {"name": name, "type": field_type, "mode": mode}
    return bigquery.SchemaField(name, field_type, mode=mode)

from src.load_semantics import (
    dedupe_current_rows,
    deletion_values,
    isoformat_utc,
    jsonl,
    parse_hubspot_timestamp,
    raw_gcs_object_name,
    request_window,
    sanitized_params,
    source_updated_at,
)
from src.manifest import HubSpotResource, V1_RESOURCES, manifest_by_name


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("hubspot_raw_loader")


CURRENT_SCHEMA = [
    schema_field("object_type", "STRING", mode="REQUIRED"),
    schema_field("object_id", "STRING", mode="REQUIRED"),
    schema_field("created_at", "TIMESTAMP"),
    schema_field("updated_at", "TIMESTAMP"),
    schema_field("archived", "BOOL"),
    schema_field("archived_at", "TIMESTAMP"),
    schema_field("deletion_source", "STRING"),
    schema_field("properties_json", "JSON"),
    schema_field("raw_json", "JSON"),
    schema_field("first_seen_at", "TIMESTAMP"),
    schema_field("last_seen_at", "TIMESTAMP"),
    schema_field("last_run_id", "STRING"),
    schema_field("last_gcs_uri", "STRING"),
    schema_field("loaded_at", "TIMESTAMP"),
    schema_field("_dlt_synced_at", "TIMESTAMP"),
    schema_field("_dlt_deleted_at", "TIMESTAMP"),
]

EXTRACT_SCHEMA = [
    schema_field("run_id", "STRING", mode="REQUIRED"),
    schema_field("attempt", "INT64", mode="REQUIRED"),
    schema_field("extracted_at", "TIMESTAMP", mode="REQUIRED"),
    schema_field("object_type", "STRING", mode="REQUIRED"),
    schema_field("object_id", "STRING", mode="REQUIRED"),
    schema_field("created_at", "TIMESTAMP"),
    schema_field("updated_at", "TIMESTAMP"),
    schema_field("archived", "BOOL"),
    schema_field("archived_at", "TIMESTAMP"),
    schema_field("properties_json", "JSON"),
    schema_field("raw_json", "JSON"),
    schema_field("gcs_uri", "STRING", mode="REQUIRED"),
    schema_field("loaded_at", "TIMESTAMP", mode="REQUIRED"),
]

ASSOCIATION_CURRENT_SCHEMA = [
    schema_field("from_object_type", "STRING", mode="REQUIRED"),
    schema_field("from_object_id", "STRING", mode="REQUIRED"),
    schema_field("to_object_type", "STRING", mode="REQUIRED"),
    schema_field("to_object_id", "STRING", mode="REQUIRED"),
    schema_field("association_category", "STRING"),
    schema_field("association_type_id", "STRING", mode="REQUIRED"),
    schema_field("association_label", "STRING"),
    schema_field("raw_json", "JSON"),
    schema_field("first_seen_at", "TIMESTAMP"),
    schema_field("last_seen_at", "TIMESTAMP"),
    schema_field("last_run_id", "STRING"),
    schema_field("loaded_at", "TIMESTAMP"),
    schema_field("_dlt_synced_at", "TIMESTAMP"),
    schema_field("_dlt_deleted_at", "TIMESTAMP"),
]

ASSOCIATION_EXTRACT_SCHEMA = [
    schema_field("run_id", "STRING", mode="REQUIRED"),
    schema_field("attempt", "INT64", mode="REQUIRED"),
    schema_field("extracted_at", "TIMESTAMP", mode="REQUIRED"),
    *ASSOCIATION_CURRENT_SCHEMA,
    schema_field("gcs_uri", "STRING", mode="REQUIRED"),
]

WATERMARKS_SCHEMA = [
    schema_field("resource_type", "STRING", mode="REQUIRED"),
    schema_field("resource_name", "STRING", mode="REQUIRED"),
    schema_field("watermark_at", "TIMESTAMP"),
    schema_field("cursor_payload", "JSON"),
    schema_field("updated_at", "TIMESTAMP", mode="REQUIRED"),
    schema_field("run_id", "STRING", mode="REQUIRED"),
]

API_REQUESTS_SCHEMA = [
    schema_field("run_id", "STRING", mode="REQUIRED"),
    schema_field("request_id", "STRING", mode="REQUIRED"),
    schema_field("requested_at", "TIMESTAMP", mode="REQUIRED"),
    schema_field("resource_name", "STRING"),
    schema_field("path", "STRING", mode="REQUIRED"),
    schema_field("params_json", "JSON"),
    schema_field("status_code", "INT64"),
    schema_field("duration_ms", "INT64"),
    schema_field("retry_count", "INT64"),
    schema_field("page_cursor", "STRING"),
    schema_field("rows_returned", "INT64"),
    schema_field("failure_class", "STRING"),
    schema_field("error_message", "STRING"),
]

PIPELINE_RUNS_SCHEMA = [
    schema_field("run_id", "STRING", mode="REQUIRED"),
    schema_field("attempt", "INT64", mode="REQUIRED"),
    schema_field("started_at", "TIMESTAMP", mode="REQUIRED"),
    schema_field("finished_at", "TIMESTAMP"),
    schema_field("status", "STRING", mode="REQUIRED"),
    schema_field("mode", "STRING", mode="REQUIRED"),
    schema_field("object_filter", "STRING"),
    schema_field("resource_status_json", "JSON"),
    schema_field("error_message", "STRING"),
]


@dataclass(frozen=True)
class Config:
    project: str
    location: str
    dataset: str
    staging_dataset: str
    raw_bucket: str
    raw_prefix: str
    token_secret: str
    api_base_url: str
    start_at: datetime
    lookback_days: int
    page_size: int
    attempt: int
    mode: str
    object_filter: str | None
    dry_run: bool

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            project=os.environ.get("GCP_PROJECT", "wingtra-dwh"),
            location=os.environ.get("BQ_LOCATION", "europe-west1"),
            dataset=os.environ.get("HUBSPOT_BQ_DATASET", "dl_hubspot"),
            staging_dataset=os.environ.get("HUBSPOT_BQ_STAGING_DATASET", "dl_hubspot_staging"),
            raw_bucket=os.environ["HUBSPOT_RAW_BUCKET"],
            raw_prefix=os.environ.get("HUBSPOT_RAW_PREFIX", "hubspot"),
            token_secret=(
                os.environ.get("HUBSPOT_SERVICE_KEY_SECRET")
                or os.environ.get("HUBSPOT_ACCESS_TOKEN_SECRET")
                or os.environ.get("HUBSPOT_PRIVATE_APP_TOKEN_SECRET")
                or "hubspot-service-key"
            ),
            api_base_url=os.environ.get("HUBSPOT_API_BASE_URL", "https://api.hubapi.com").rstrip("/"),
            start_at=parse_hubspot_timestamp(
                os.environ.get("HUBSPOT_START_AT", "2026-01-01T00:00:00Z")
            )
            or datetime(2026, 1, 1, tzinfo=UTC),
            lookback_days=int(os.environ.get("HUBSPOT_LOOKBACK_DAYS", "14")),
            page_size=int(os.environ.get("HUBSPOT_PAGE_SIZE", "200")),
            attempt=int(os.environ.get("HUBSPOT_RUN_ATTEMPT", "1")),
            mode=os.environ.get("HUBSPOT_RUN_MODE", "incremental"),
            object_filter=os.environ.get("HUBSPOT_OBJECT_FILTER") or None,
            dry_run=os.environ.get("HUBSPOT_DRY_RUN", "").lower() in ("1", "true", "yes"),
        )


class RequestRecorder:
    def __init__(self, run_id: str):
        self.run_id = run_id
        self.rows: list[dict[str, Any]] = []

    def record(
        self,
        resource_name: str,
        path: str,
        params: dict[str, Any],
        status_code: int | None,
        duration_ms: int,
        rows_returned: int | None = None,
        page_cursor: str | None = None,
        failure_class: str | None = None,
        error_message: str | None = None,
    ) -> None:
        self.rows.append(
            {
                "run_id": self.run_id,
                "request_id": uuid.uuid4().hex,
                "requested_at": isoformat_utc(datetime.now(UTC)),
                "resource_name": resource_name,
                "path": path,
                "params_json": sanitized_params(params),
                "status_code": status_code,
                "duration_ms": duration_ms,
                "retry_count": None,
                "page_cursor": page_cursor,
                "rows_returned": rows_returned,
                "failure_class": failure_class,
                "error_message": error_message,
            }
        )


class HubSpotClient:
    def __init__(self, config: Config, token: str, recorder: RequestRecorder):
        self.config = config
        self.recorder = recorder
        self.session = requests.Session()
        retry = Retry(
            total=5,
            connect=5,
            read=5,
            status=5,
            backoff_factor=1.5,
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset(["GET", "POST"]),
            respect_retry_after_header=True,
        )
        self.session.mount("https://", HTTPAdapter(max_retries=retry))
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            }
        )

    def _request(
        self,
        resource: HubSpotResource,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        page_cursor: str | None = None,
    ) -> dict[str, Any]:
        url = f"{self.config.api_base_url}{path}"
        started = time.monotonic()
        try:
            response = self.session.request(
                method,
                url,
                params=params,
                json=body,
                timeout=60,
            )
            duration_ms = int((time.monotonic() - started) * 1000)
            response.raise_for_status()
            payload = response.json()
            self.recorder.record(
                resource.name,
                path,
                params or body or {},
                response.status_code,
                duration_ms,
                rows_returned=len(payload.get("results", [])) if isinstance(payload, dict) else None,
                page_cursor=page_cursor,
            )
            return payload
        except requests.HTTPError as exc:
            duration_ms = int((time.monotonic() - started) * 1000)
            status_code = exc.response.status_code if exc.response is not None else None
            self.recorder.record(
                resource.name,
                path,
                params or body or {},
                status_code,
                duration_ms,
                page_cursor=page_cursor,
                failure_class="hubspot_http_error",
                error_message=str(exc)[:1000],
            )
            raise
        except requests.RequestException as exc:
            duration_ms = int((time.monotonic() - started) * 1000)
            self.recorder.record(
                resource.name,
                path,
                params or body or {},
                None,
                duration_ms,
                page_cursor=page_cursor,
                failure_class="hubspot_request_error",
                error_message=str(exc)[:1000],
            )
            raise

    def search_objects(
        self,
        resource: HubSpotResource,
        start_at: datetime,
        end_at: datetime,
        include_archived: bool = False,
    ) -> list[dict[str, Any]]:
        return self._search_objects_window(
            resource,
            start_at,
            end_at,
            end_operator="LTE",
            include_archived=include_archived,
        )

    def _search_objects_window(
        self,
        resource: HubSpotResource,
        start_at: datetime,
        end_at: datetime,
        end_operator: str,
        include_archived: bool,
        depth: int = 0,
    ) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        after: str | None = None

        def request_page(page_cursor: str | None) -> dict[str, Any]:
            filters = [
                {
                    "propertyName": resource.cursor_field,
                    "operator": "GTE",
                    "value": isoformat_utc(start_at),
                },
                {
                    "propertyName": resource.cursor_field,
                    "operator": end_operator,
                    "value": isoformat_utc(end_at),
                },
            ]
            body: dict[str, Any] = {
                "filterGroups": [{"filters": filters}],
                "sorts": [{"propertyName": resource.cursor_field, "direction": "ASCENDING"}],
                "properties": list(resource.properties),
                "limit": self.config.page_size,
            }
            if page_cursor is not None:
                body["after"] = page_cursor
            if include_archived:
                body["archived"] = True
            return self._request(
                resource,
                "POST",
                resource.endpoint,
                body=body,
                page_cursor=page_cursor,
            )

        first_payload = request_page(None)
        total = first_payload.get("total")
        if isinstance(total, int) and total >= 10000:
            span = end_at - start_at
            if span <= timedelta(milliseconds=1):
                raise RuntimeError(
                    f"HubSpot search cap hit for {resource.name} in a sub-millisecond window"
                )
            midpoint = start_at + (span / 2)
            log.info(
                "Splitting HubSpot search window for %s at %s; total=%s",
                resource.name,
                isoformat_utc(midpoint),
                total,
            )
            return (
                self._search_objects_window(
                    resource,
                    start_at,
                    midpoint,
                    end_operator="LT",
                    include_archived=include_archived,
                    depth=depth + 1,
                )
                + self._search_objects_window(
                    resource,
                    midpoint,
                    end_at,
                    end_operator=end_operator,
                    include_archived=include_archived,
                    depth=depth + 1,
                )
            )

        first_page_rows = first_payload.get("results", [])
        for row in first_page_rows:
            row["_hubspot_page_number"] = 1
        rows.extend(first_page_rows)
        after = (first_payload.get("paging") or {}).get("next", {}).get("after")

        for page_number in range(1, resource.page_limit + 1):
            if not after:
                return rows
            payload = request_page(after)
            page_rows = payload.get("results", [])
            for row in page_rows:
                row["_hubspot_page_number"] = page_number + 1
            rows.extend(page_rows)
            after = (payload.get("paging") or {}).get("next", {}).get("after")
        raise RuntimeError(f"Page cap hit for {resource.name}: {resource.page_limit}")

    def fetch_metadata(self, resource: HubSpotResource) -> list[dict[str, Any]]:
        payload = self._request(resource, "GET", resource.endpoint)
        if isinstance(payload.get("results"), list):
            return payload["results"]
        if isinstance(payload.get("pipelines"), list):
            return payload["pipelines"]
        return [payload]

    def fetch_associations(
        self,
        resource: HubSpotResource,
        from_object_ids: list[str],
    ) -> list[dict[str, Any]]:
        if not resource.from_object_type or not resource.to_object_type:
            raise ValueError(f"Association resource {resource.name} is missing object types")
        rows: list[dict[str, Any]] = []
        batch_size = min(self.config.page_size, 200)
        batches = [
            from_object_ids[index : index + batch_size]
            for index in range(0, len(from_object_ids), batch_size)
        ]
        if len(batches) > resource.page_limit:
            raise RuntimeError(f"Association batch cap hit for {resource.name}: {len(batches)}")
        path = f"/crm/v4/associations/{resource.from_object_type}/{resource.to_object_type}/batch/read"
        for batch_number, batch in enumerate(batches, start=1):
            payload = self._request(
                resource,
                "POST",
                path,
                body={"inputs": [{"id": object_id} for object_id in batch]},
                page_cursor=str(batch_number),
            )
            for result in payload.get("results", []):
                from_object_id = str(
                    (result.get("from") or {}).get("id")
                    or result.get("fromObjectId")
                    or result.get("from", "")
                )
                for association in result.get("to") or result.get("associations") or []:
                    association["_from_object_id"] = from_object_id
                    rows.append(association)
        return rows


class BigQuerySink:
    def __init__(self, config: Config):
        self.config = config
        self.client = bigquery.Client(project=config.project, location=config.location)

    def table_id(self, dataset: str, table: str) -> str:
        return f"{self.config.project}.{dataset}.{table}"

    def ensure_dataset(self, dataset: str) -> None:
        dataset_id = f"{self.config.project}.{dataset}"
        try:
            self.client.get_dataset(dataset_id)
        except NotFound:
            ds = bigquery.Dataset(dataset_id)
            ds.location = self.config.location
            self.client.create_dataset(ds)

    def ensure_table(self, dataset: str, table: str, schema: list[bigquery.SchemaField]) -> None:
        self.ensure_dataset(dataset)
        table_id = self.table_id(dataset, table)
        try:
            self.client.get_table(table_id)
        except NotFound:
            self.client.create_table(bigquery.Table(table_id, schema=schema))

    def load_json_rows(
        self,
        dataset: str,
        table: str,
        schema: list[bigquery.SchemaField],
        rows: list[dict[str, Any]],
        write_disposition: str = "WRITE_APPEND",
    ) -> None:
        if not rows:
            return
        self.ensure_table(dataset, table, schema)
        job_config = bigquery.LoadJobConfig(
            schema=schema,
            write_disposition=write_disposition,
            source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        )
        job = self.client.load_table_from_json(rows, self.table_id(dataset, table), job_config=job_config)
        job.result()

    def get_watermark(self, resource: HubSpotResource) -> datetime | None:
        self.ensure_table(self.config.dataset, "_watermarks", WATERMARKS_SCHEMA)
        sql = f"""
            select watermark_at
            from `{self.table_id(self.config.dataset, "_watermarks")}`
            where resource_type = @resource_type
              and resource_name = @resource_name
            order by updated_at desc
            limit 1
        """
        job = self.client.query(
            sql,
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter("resource_type", "STRING", resource.mode),
                    bigquery.ScalarQueryParameter("resource_name", "STRING", resource.name),
                ]
            ),
            location=self.config.location,
        )
        rows = list(job.result())
        return rows[0].watermark_at if rows else None

    def update_watermark(self, resource: HubSpotResource, watermark_at: datetime, run_id: str) -> None:
        self.load_json_rows(
            self.config.dataset,
            "_watermarks",
            WATERMARKS_SCHEMA,
            [
                {
                    "resource_type": resource.mode,
                    "resource_name": resource.name,
                    "watermark_at": isoformat_utc(watermark_at),
                    "cursor_payload": {"cursor_field": resource.cursor_field},
                    "updated_at": isoformat_utc(datetime.now(UTC)),
                    "run_id": run_id,
                }
            ],
        )

    def merge_current_object(self, resource: HubSpotResource, staging_table: str) -> None:
        current_table = resource.name
        self.ensure_table(self.config.dataset, current_table, CURRENT_SCHEMA)
        target = self.table_id(self.config.dataset, current_table)
        source = self.table_id(self.config.staging_dataset, staging_table)
        sql = f"""
            merge `{target}` T
            using (
                select * except(row_number)
                from (
                    select
                        *,
                        row_number() over (
                            partition by object_id
                            order by updated_at desc nulls last, loaded_at desc
                        ) as row_number
                    from `{source}`
                )
                where row_number = 1
            ) S
            on T.object_id = S.object_id
            when matched then update set
                object_type = S.object_type,
                created_at = S.created_at,
                updated_at = S.updated_at,
                archived = S.archived,
                archived_at = S.archived_at,
                deletion_source = S.deletion_source,
                properties_json = S.properties_json,
                raw_json = S.raw_json,
                last_seen_at = current_timestamp(),
                last_run_id = S.last_run_id,
                last_gcs_uri = S.last_gcs_uri,
                loaded_at = S.loaded_at,
                _dlt_synced_at = current_timestamp(),
                _dlt_deleted_at = S._dlt_deleted_at
            when not matched then insert (
                object_type, object_id, created_at, updated_at, archived, archived_at,
                deletion_source, properties_json, raw_json, first_seen_at, last_seen_at,
                last_run_id, last_gcs_uri, loaded_at, _dlt_synced_at, _dlt_deleted_at
            )
            values (
                S.object_type, S.object_id, S.created_at, S.updated_at, S.archived, S.archived_at,
                S.deletion_source, S.properties_json, S.raw_json, current_timestamp(), current_timestamp(),
                S.last_run_id, S.last_gcs_uri, S.loaded_at, current_timestamp(), S._dlt_deleted_at
            )
        """
        self.client.query(sql, location=self.config.location).result()

    def active_object_ids(self, object_type: str) -> list[str]:
        self.ensure_table(self.config.dataset, object_type, CURRENT_SCHEMA)
        sql = f"""
            select object_id
            from `{self.table_id(self.config.dataset, object_type)}`
            where _dlt_deleted_at is null
        """
        return [str(row.object_id) for row in self.client.query(sql, location=self.config.location).result()]

    def merge_current_associations(self, staging_table: str) -> None:
        self.ensure_table(self.config.dataset, "association_edges", ASSOCIATION_CURRENT_SCHEMA)
        target = self.table_id(self.config.dataset, "association_edges")
        source = self.table_id(self.config.staging_dataset, staging_table)
        sql = f"""
            merge `{target}` T
            using (
                select * except(row_number)
                from (
                    select
                        *,
                        row_number() over (
                            partition by
                                from_object_type,
                                from_object_id,
                                to_object_type,
                                to_object_id,
                                association_category,
                                association_type_id
                            order by loaded_at desc
                        ) as row_number
                    from `{source}`
                )
                where row_number = 1
            ) S
            on T.from_object_type = S.from_object_type
               and T.from_object_id = S.from_object_id
               and T.to_object_type = S.to_object_type
               and T.to_object_id = S.to_object_id
               and T.association_category = S.association_category
               and T.association_type_id = S.association_type_id
            when matched then update set
                association_label = S.association_label,
                raw_json = S.raw_json,
                last_seen_at = current_timestamp(),
                last_run_id = S.last_run_id,
                loaded_at = S.loaded_at,
                _dlt_synced_at = current_timestamp(),
                _dlt_deleted_at = null
            when not matched then insert (
                from_object_type, from_object_id, to_object_type, to_object_id,
                association_category, association_type_id, association_label,
                raw_json, first_seen_at, last_seen_at, last_run_id, loaded_at,
                _dlt_synced_at, _dlt_deleted_at
            )
            values (
                S.from_object_type, S.from_object_id, S.to_object_type, S.to_object_id,
                S.association_category, S.association_type_id, S.association_label,
                S.raw_json, current_timestamp(), current_timestamp(), S.last_run_id, S.loaded_at,
                current_timestamp(), null
            )
        """
        self.client.query(sql, location=self.config.location).result()

    def append_api_requests(self, rows: list[dict[str, Any]]) -> None:
        if rows:
            self.load_json_rows(self.config.dataset, "_api_requests", API_REQUESTS_SCHEMA, rows)

    def upsert_run(self, row: dict[str, Any]) -> None:
        self.ensure_table(self.config.dataset, "_pipeline_runs", PIPELINE_RUNS_SCHEMA)
        staging_table = (
            f"_pipeline_runs__{str(row['run_id']).replace('-', '_')}__attempt_{row['attempt']}"
        )
        self.load_json_rows(
            self.config.staging_dataset,
            staging_table,
            PIPELINE_RUNS_SCHEMA,
            [row],
            write_disposition="WRITE_TRUNCATE",
        )
        target = self.table_id(self.config.dataset, "_pipeline_runs")
        source = self.table_id(self.config.staging_dataset, staging_table)
        sql = f"""
            merge `{target}` T
            using `{source}` S
            on T.run_id = S.run_id and T.attempt = S.attempt
            when matched then update set
                started_at = S.started_at,
                finished_at = S.finished_at,
                status = S.status,
                mode = S.mode,
                object_filter = S.object_filter,
                resource_status_json = S.resource_status_json,
                error_message = S.error_message
            when not matched then insert (
                run_id, attempt, started_at, finished_at, status, mode,
                object_filter, resource_status_json, error_message
            )
            values (
                S.run_id, S.attempt, S.started_at, S.finished_at, S.status, S.mode,
                S.object_filter, S.resource_status_json, S.error_message
            )
        """
        self.client.query(sql, location=self.config.location).result()


def access_secret(project: str, secret_name: str) -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project}/secrets/{secret_name}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("utf-8").strip()


def storage_client_upload(config: Config, object_name: str, rows: list[dict[str, Any]]) -> str:
    client = storage.Client(project=config.project)
    bucket = client.bucket(config.raw_bucket)
    blob = bucket.blob(object_name)
    blob.upload_from_string(
        jsonl(rows),
        content_type="application/jsonl",
        if_generation_match=0,
    )
    return f"gs://{config.raw_bucket}/{object_name}"


def normalize_object_rows(
    resource: HubSpotResource,
    hubspot_rows: list[dict[str, Any]],
    run_id: str,
    attempt: int,
    gcs_uri: str,
    extracted_at: datetime,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    current_rows: list[dict[str, Any]] = []
    extract_rows: list[dict[str, Any]] = []
    detected_at = datetime.now(UTC)
    for row in hubspot_rows:
        object_id = str(
            row.get("id")
            or row.get("objectTypeId")
            or row.get("name")
            or row.get("label")
            or ""
        )
        if not object_id:
            raise ValueError(f"HubSpot row for {resource.name} is missing id")
        properties = row.get("properties") or {}
        created_at = parse_hubspot_timestamp(row.get("createdAt") or properties.get("createdate"))
        updated_at = source_updated_at(row)
        archived_at = parse_hubspot_timestamp(row.get("archivedAt"))
        deleted_at, deletion_source = deletion_values(row, detected_at)
        base = {
            "object_type": resource.object_type,
            "object_id": object_id,
            "created_at": isoformat_utc(created_at),
            "updated_at": isoformat_utc(updated_at),
            "archived": bool(row.get("archived", False)),
            "archived_at": isoformat_utc(archived_at),
            "properties_json": properties,
            "raw_json": row,
        }
        extract_rows.append(
            {
                **base,
                "run_id": run_id,
                "attempt": attempt,
                "extracted_at": isoformat_utc(extracted_at),
                "gcs_uri": gcs_uri,
                "loaded_at": isoformat_utc(datetime.now(UTC)),
            }
        )
        current_rows.append(
            {
                **base,
                "deletion_source": deletion_source,
                "first_seen_at": None,
                "last_seen_at": isoformat_utc(datetime.now(UTC)),
                "last_run_id": run_id,
                "last_gcs_uri": gcs_uri,
                "loaded_at": isoformat_utc(datetime.now(UTC)),
                "_dlt_synced_at": isoformat_utc(datetime.now(UTC)),
                "_dlt_deleted_at": deleted_at,
            }
        )
    return dedupe_current_rows(current_rows), extract_rows


def normalize_association_rows(
    resource: HubSpotResource,
    hubspot_rows: list[dict[str, Any]],
    run_id: str,
    attempt: int,
    gcs_uri: str,
    extracted_at: datetime,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not resource.from_object_type or not resource.to_object_type:
        raise ValueError(f"Association resource {resource.name} is missing object types")
    current_rows: list[dict[str, Any]] = []
    extract_rows: list[dict[str, Any]] = []
    for row in hubspot_rows:
        from_object_id = str(row.get("_from_object_id") or "")
        to_object_id = str(row.get("toObjectId") or row.get("id") or "")
        if not from_object_id or not to_object_id:
            raise ValueError(f"Association row for {resource.name} is missing from/to IDs")
        association_types = row.get("associationTypes") or row.get("types") or [{}]
        for assoc_type in association_types:
            association_type_id = str(
                assoc_type.get("typeId")
                or assoc_type.get("associationTypeId")
                or assoc_type.get("id")
                or "unknown"
            )
            base = {
                "from_object_type": resource.from_object_type,
                "from_object_id": from_object_id,
                "to_object_type": resource.to_object_type,
                "to_object_id": to_object_id,
                "association_category": assoc_type.get("category") or assoc_type.get("associationCategory"),
                "association_type_id": association_type_id,
                "association_label": assoc_type.get("label"),
                "raw_json": row,
                "first_seen_at": None,
                "last_seen_at": isoformat_utc(datetime.now(UTC)),
                "last_run_id": run_id,
                "loaded_at": isoformat_utc(datetime.now(UTC)),
                "_dlt_synced_at": isoformat_utc(datetime.now(UTC)),
                "_dlt_deleted_at": None,
            }
            current_rows.append(base)
            extract_rows.append(
                {
                    **base,
                    "run_id": run_id,
                    "attempt": attempt,
                    "extracted_at": isoformat_utc(extracted_at),
                    "gcs_uri": gcs_uri,
                }
            )
    return current_rows, extract_rows


def selected_resources(config: Config) -> list[HubSpotResource]:
    if not config.object_filter:
        return [resource for resource in V1_RESOURCES if resource.enabled]
    manifest = manifest_by_name()
    names = [name.strip() for name in config.object_filter.split(",") if name.strip()]
    return [manifest[name] for name in names]


def run() -> None:
    config = Config.from_env()
    run_id = os.environ.get("HUBSPOT_RUN_ID", f"hubspot-{datetime.now(UTC).strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}")
    started_at = datetime.now(UTC)

    if config.dry_run:
        log.info("Dry run resources: %s", [resource.name for resource in selected_resources(config)])
        return

    token = access_secret(config.project, config.token_secret)
    recorder = RequestRecorder(run_id)
    client = HubSpotClient(config, token, recorder)
    sink = BigQuerySink(config)
    resource_status: dict[str, dict[str, Any]] = {}
    overall_status = "success"
    error_message: str | None = None

    sink.upsert_run(
        {
            "run_id": run_id,
            "attempt": config.attempt,
            "started_at": isoformat_utc(started_at),
            "finished_at": None,
            "status": "running",
            "mode": config.mode,
            "object_filter": config.object_filter,
            "resource_status_json": {},
            "error_message": None,
        }
    )

    try:
        for resource in selected_resources(config):
            log.info("Loading HubSpot resource %s", resource.name)
            if resource.mode == "metadata":
                hubspot_rows = client.fetch_metadata(resource)
                window_end = started_at
            elif resource.mode == "association":
                source_ids = sink.active_object_ids(resource.from_object_type or "")
                hubspot_rows = client.fetch_associations(resource, source_ids)
                window_end = started_at
            else:
                watermark = sink.get_watermark(resource)
                window_start, window_end = request_window(
                    watermark,
                    started_at,
                    config.lookback_days,
                    config.start_at,
                )
                hubspot_rows = client.search_objects(resource, window_start, window_end)

            page_name = raw_gcs_object_name(
                config.raw_prefix,
                resource.name,
                started_at,
                run_id,
                config.attempt,
                1,
            )
            gcs_uri = storage_client_upload(config, page_name, hubspot_rows)
            staging_table = f"{resource.name}__{run_id.replace('-', '_')}__attempt_{config.attempt}"
            if resource.mode == "association":
                current_rows, extract_rows = normalize_association_rows(
                    resource,
                    hubspot_rows,
                    run_id,
                    config.attempt,
                    gcs_uri,
                    datetime.now(UTC),
                )
                if current_rows:
                    sink.load_json_rows(
                        config.staging_dataset,
                        staging_table,
                        ASSOCIATION_CURRENT_SCHEMA,
                        current_rows,
                        write_disposition="WRITE_TRUNCATE",
                    )
                    sink.load_json_rows(
                        config.dataset,
                        "association_edges_extracts",
                        ASSOCIATION_EXTRACT_SCHEMA,
                        extract_rows,
                    )
                    sink.merge_current_associations(staging_table)
            else:
                current_rows, extract_rows = normalize_object_rows(
                    resource,
                    hubspot_rows,
                    run_id,
                    config.attempt,
                    gcs_uri,
                    datetime.now(UTC),
                )
                if current_rows:
                    sink.load_json_rows(
                        config.staging_dataset,
                        staging_table,
                        CURRENT_SCHEMA,
                        current_rows,
                        write_disposition="WRITE_TRUNCATE",
                    )
                    sink.load_json_rows(
                        config.dataset,
                        f"{resource.name}_extracts",
                        EXTRACT_SCHEMA,
                        extract_rows,
                    )
                    sink.merge_current_object(resource, staging_table)
            sink.update_watermark(resource, window_end, run_id)
            resource_status[resource.name] = {
                "status": "success",
                "rows": len(hubspot_rows),
                "watermark_at": isoformat_utc(window_end),
            }
    except Exception as exc:
        overall_status = "failed"
        error_message = str(exc)[:1000]
        log.exception("HubSpot load failed")
        raise
    finally:
        sink.append_api_requests(recorder.rows)
        sink.upsert_run(
            {
                "run_id": run_id,
                "attempt": config.attempt,
                "started_at": isoformat_utc(started_at),
                "finished_at": isoformat_utc(datetime.now(UTC)),
                "status": overall_status,
                "mode": config.mode,
                "object_filter": config.object_filter,
                "resource_status_json": resource_status,
                "error_message": error_message,
            }
        )


if __name__ == "__main__":
    run()
