"""HubSpot CRM -> GCS raw pages -> BigQuery DL current and SCD tables.

Object resources are full-loaded, staged, compared by primary key/hash, merged
into current raw mirrors, and written to mechanical raw SCD2 tables named
``<resource>_scd``. The loader uses HubSpot property metadata loaded earlier in
the same run to request all known object properties where available.
"""

from __future__ import annotations

import logging
import os
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
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

from src.load_semantics import (  # noqa: E402
    dedupe_current_rows,
    deletion_values,
    isoformat_utc,
    jsonl,
    parse_hubspot_timestamp,
    raw_gcs_object_name,
    sanitized_params,
    source_updated_at,
)
from src.manifest import HubSpotResource, V1_RESOURCES, manifest_by_name  # noqa: E402


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

SCD_FIELDS = [
    schema_field("_scd_row_hash", "STRING"),
    schema_field("_scd_change_type", "STRING"),
    schema_field("_scd_valid_from", "TIMESTAMP"),
    schema_field("_scd_valid_to", "TIMESTAMP"),
    schema_field("_scd_is_current", "BOOL"),
    schema_field("_scd_run_id", "STRING"),
    schema_field("_scd_extracted_at", "TIMESTAMP"),
]

OBJECT_SCD_SCHEMA = [*CURRENT_SCHEMA, *SCD_FIELDS]
ASSOCIATION_SCD_SCHEMA = [*ASSOCIATION_CURRENT_SCHEMA, *SCD_FIELDS]

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

OBJECT_HASH_EXCLUDE_COLUMNS = {
    "first_seen_at",
    "last_seen_at",
    "last_run_id",
    "last_gcs_uri",
    "loaded_at",
    "_dlt_synced_at",
}
ASSOCIATION_HASH_EXCLUDE_COLUMNS = {
    "first_seen_at",
    "last_seen_at",
    "last_run_id",
    "loaded_at",
    "_dlt_synced_at",
}


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
            page_size=int(os.environ.get("HUBSPOT_PAGE_SIZE", "100")),
            attempt=int(os.environ.get("HUBSPOT_RUN_ATTEMPT", "1")),
            mode=os.environ.get("HUBSPOT_RUN_MODE", "full"),
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

    def fetch_metadata(self, resource: HubSpotResource) -> list[dict[str, Any]]:
        payload = self._request(resource, "GET", resource.endpoint)
        if isinstance(payload.get("results"), list):
            return payload["results"]
        if isinstance(payload.get("pipelines"), list):
            return payload["pipelines"]
        return [payload]

    def fetch_all_objects(
        self,
        resource: HubSpotResource,
        properties: tuple[str, ...] | list[str] | None = None,
    ) -> list[dict[str, Any]]:
        object_path = resource.endpoint.removesuffix("/search")
        requested_properties = tuple(properties if properties is not None else resource.properties)
        rows: list[dict[str, Any]] = []
        seen_ids: set[tuple[str, bool]] = set()
        for archived in (False, True):
            after: str | None = None
            for page_number in range(1, resource.page_limit + 1):
                params: dict[str, Any] = {
                    "limit": min(self.config.page_size, 100),
                    "archived": str(archived).lower(),
                }
                if requested_properties:
                    params["properties"] = ",".join(requested_properties)
                if after is not None:
                    params["after"] = after
                payload = self._request(
                    resource,
                    "GET",
                    object_path,
                    params=params,
                    page_cursor=after or str(page_number),
                )
                page_rows = payload.get("results", [])
                for row in page_rows:
                    object_id = str(row.get("id") or "")
                    key = (object_id, archived)
                    if key not in seen_ids:
                        row["_hubspot_page_number"] = page_number
                        rows.append(row)
                        seen_ids.add(key)
                after = (payload.get("paging") or {}).get("next", {}).get("after")
                if not after:
                    break
            else:
                raise RuntimeError(f"Page cap hit for full load {resource.name}: {resource.page_limit}")
        return rows

    def fetch_associations(self, resource: HubSpotResource, from_object_ids: list[str]) -> list[dict[str, Any]]:
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

    def ensure_table(self, dataset: str, table: str, schema: list[Any]) -> None:
        self.ensure_dataset(dataset)
        table_id = self.table_id(dataset, table)
        try:
            existing = self.client.get_table(table_id)
        except NotFound:
            self.client.create_table(bigquery.Table(table_id, schema=schema))
            return
        existing_names = {field.name for field in existing.schema}
        additions = [field for field in schema if field.name not in existing_names]
        if additions:
            existing.schema = [*existing.schema, *additions]
            self.client.update_table(existing, ["schema"])

    def load_json_rows(
        self,
        dataset: str,
        table: str,
        schema: list[Any],
        rows: list[dict[str, Any]],
        write_disposition: str = "WRITE_APPEND",
    ) -> None:
        self.ensure_table(dataset, table, schema)
        if not rows:
            return
        job_config = bigquery.LoadJobConfig(
            schema=schema,
            write_disposition=write_disposition,
            source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        )
        job = self.client.load_table_from_json(rows, self.table_id(dataset, table), job_config=job_config)
        job.result()

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
                    "cursor_payload": {"cursor_field": resource.cursor_field, "load_mode": "full"},
                    "updated_at": isoformat_utc(datetime.now(UTC)),
                    "run_id": run_id,
                }
            ],
        )

    @staticmethod
    def _quote(name: str) -> str:
        return f"`{name.replace('`', '``')}`"

    def _null_safe_key_match(self, key_columns: list[str]) -> str:
        return " and ".join(
            f"coalesce(cast(T.{self._quote(column)} as string), '__NULL__') = "
            f"coalesce(cast(S.{self._quote(column)} as string), '__NULL__')"
            for column in key_columns
        )

    def _scd_hash_expression(self, columns: list[str], excluded: set[str]) -> str:
        hash_columns = [column for column in columns if column not in excluded and not column.startswith("_scd")]
        fields = ", ".join(f"S.{self._quote(column)}" for column in hash_columns)
        return f"to_hex(sha256(to_json_string(struct({fields}))))"

    def _sync_scd_table(
        self,
        staging_table: str,
        scd_table: str,
        schema: list[Any],
        key_columns: list[str],
        hash_exclude_columns: set[str],
        run_id: str,
    ) -> int:
        self.ensure_table(self.config.dataset, scd_table, schema)
        staging = self.table_id(self.config.staging_dataset, staging_table)
        scd = self.table_id(self.config.dataset, scd_table)
        changes_table = f"_scd_changes__{scd_table}__{run_id.replace('-', '_')}"
        changes = self.table_id(self.config.staging_dataset, changes_table)
        source_columns = [field.name for field in schema if not field.name.startswith("_scd")]
        source_select = ", ".join(f"S.{self._quote(column)}" for column in source_columns)
        target_select = ", ".join(f"T.{self._quote(column)}" for column in source_columns)
        key_match = self._null_safe_key_match(key_columns)
        target_missing = f"T.{self._quote(key_columns[0])} is null"
        source_missing = f"S.{self._quote(key_columns[0])} is null"
        run_timestamp = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        run_ts = f"timestamp('{run_timestamp}')"
        hash_expr = self._scd_hash_expression(source_columns, hash_exclude_columns)

        create_changes_sql = f"""
            create or replace table `{changes}` as
            with source_hashed as (
                select
                    S.*,
                    {hash_expr} as `_scd_row_hash`
                from `{staging}` S
            ),
            current_open as (
                select *
                from `{scd}`
                where `_scd_is_current` = true
            )
            select
                {source_select},
                S.`_scd_row_hash`,
                case
                    when {target_missing} then 'insert'
                    when T.`_dlt_deleted_at` is not null then 'insert'
                    else 'update'
                end as `_scd_change_type`
            from source_hashed S
            left join current_open T
                on {key_match}
            where {target_missing}
               or T.`_dlt_deleted_at` is not null
               or coalesce(T.`_scd_row_hash`, '') != S.`_scd_row_hash`
            union all
            select
                {target_select},
                T.`_scd_row_hash`,
                'delete' as `_scd_change_type`
            from current_open T
            left join source_hashed S
                on {key_match}
            where {source_missing}
              and T.`_dlt_deleted_at` is null
        """
        self.client.query(create_changes_sql, location=self.config.location).result()

        close_sql = f"""
            merge `{scd}` T
            using `{changes}` S
            on {key_match} and T.`_scd_is_current` = true
            when matched then update set
                `_scd_valid_to` = {run_ts},
                `_scd_is_current` = false,
                `_dlt_synced_at` = {run_ts}
        """
        self.client.query(close_sql, location=self.config.location).result()

        insert_columns = source_columns + [field.name for field in SCD_FIELDS]
        insert_values = [f"S.{self._quote(column)}" for column in source_columns]
        insert_values[insert_columns.index("_dlt_deleted_at")] = (
            "case when S.`_scd_change_type` = 'delete' then "
            + run_ts
            + " else S.`_dlt_deleted_at` end"
        )
        insert_values.extend(
            [
                "S.`_scd_row_hash`",
                "S.`_scd_change_type`",
                run_ts,
                "null",
                "true",
                f"'{run_id}'",
                run_ts,
            ]
        )
        insert_sql = f"""
            insert into `{scd}` ({", ".join(self._quote(column) for column in insert_columns)})
            select {", ".join(insert_values)}
            from `{changes}` S
        """
        job = self.client.query(insert_sql, location=self.config.location)
        job.result()
        inserted = job.num_dml_affected_rows or 0
        log.info("Synced %s (%d inserted versions)", scd_table, inserted)
        return inserted

    def sync_object_scd(self, resource: HubSpotResource, staging_table: str, run_id: str) -> int:
        return self._sync_scd_table(
            staging_table,
            f"{resource.name}_scd",
            OBJECT_SCD_SCHEMA,
            ["object_id"],
            OBJECT_HASH_EXCLUDE_COLUMNS,
            run_id,
        )

    def sync_association_scd(self, staging_table: str, run_id: str) -> int:
        return self._sync_scd_table(
            staging_table,
            "association_edges_scd",
            ASSOCIATION_SCD_SCHEMA,
            [
                "from_object_type",
                "from_object_id",
                "to_object_type",
                "to_object_id",
                "association_category",
                "association_type_id",
            ],
            ASSOCIATION_HASH_EXCLUDE_COLUMNS,
            run_id,
        )

    def merge_current_object(self, resource: HubSpotResource, staging_table: str) -> None:
        self.ensure_table(self.config.dataset, resource.name, CURRENT_SCHEMA)
        target = self.table_id(self.config.dataset, resource.name)
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
            when not matched by source and T._dlt_deleted_at is null then update set
                deletion_source = 'full_load_missing',
                last_seen_at = current_timestamp(),
                loaded_at = current_timestamp(),
                _dlt_synced_at = current_timestamp(),
                _dlt_deleted_at = current_timestamp()
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
            on {self._null_safe_key_match([
                "from_object_type",
                "from_object_id",
                "to_object_type",
                "to_object_id",
                "association_category",
                "association_type_id",
            ])}
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
            when not matched by source and T._dlt_deleted_at is null then update set
                last_seen_at = current_timestamp(),
                loaded_at = current_timestamp(),
                _dlt_synced_at = current_timestamp(),
                _dlt_deleted_at = current_timestamp()
        """
        self.client.query(sql, location=self.config.location).result()

    def append_api_requests(self, rows: list[dict[str, Any]]) -> None:
        if rows:
            self.load_json_rows(self.config.dataset, "_api_requests", API_REQUESTS_SCHEMA, rows)

    def upsert_run(self, row: dict[str, Any]) -> None:
        self.ensure_table(self.config.dataset, "_pipeline_runs", PIPELINE_RUNS_SCHEMA)
        staging_table = f"_pipeline_runs__{str(row['run_id']).replace('-', '_')}__attempt_{row['attempt']}"
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
    blob.upload_from_string(jsonl(rows), content_type="application/jsonl", if_generation_match=0)
    return f"gs://{config.raw_bucket}/{object_name}"


def normalize_object_rows(
    resource: HubSpotResource,
    hubspot_rows: list[dict[str, Any]],
    run_id: str,
    gcs_uri: str,
    extracted_at: datetime,
) -> list[dict[str, Any]]:
    current_rows: list[dict[str, Any]] = []
    detected_at = datetime.now(UTC)
    for row in hubspot_rows:
        object_id = str(row.get("id") or row.get("objectTypeId") or row.get("name") or row.get("label") or "")
        if not object_id:
            raise ValueError(f"HubSpot row for {resource.name} is missing id")
        properties = row.get("properties") or {}
        created_at = parse_hubspot_timestamp(row.get("createdAt") or properties.get("createdate") or properties.get("hs_createdate"))
        updated_at = source_updated_at(row)
        archived_at = parse_hubspot_timestamp(row.get("archivedAt"))
        deleted_at, deletion_source = deletion_values(row, detected_at)
        current_rows.append(
            {
                "object_type": resource.object_type,
                "object_id": object_id,
                "created_at": isoformat_utc(created_at),
                "updated_at": isoformat_utc(updated_at),
                "archived": bool(row.get("archived", False)),
                "archived_at": isoformat_utc(archived_at),
                "deletion_source": deletion_source,
                "properties_json": properties,
                "raw_json": row,
                "first_seen_at": None,
                "last_seen_at": isoformat_utc(datetime.now(UTC)),
                "last_run_id": run_id,
                "last_gcs_uri": gcs_uri,
                "loaded_at": isoformat_utc(extracted_at),
                "_dlt_synced_at": isoformat_utc(datetime.now(UTC)),
                "_dlt_deleted_at": deleted_at,
            }
        )
    return dedupe_current_rows(current_rows)


def normalize_association_rows(
    resource: HubSpotResource,
    hubspot_rows: list[dict[str, Any]],
    run_id: str,
    extracted_at: datetime,
) -> list[dict[str, Any]]:
    if not resource.from_object_type or not resource.to_object_type:
        raise ValueError(f"Association resource {resource.name} is missing object types")
    current_rows: list[dict[str, Any]] = []
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
            current_rows.append(
                {
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
                    "loaded_at": isoformat_utc(extracted_at),
                    "_dlt_synced_at": isoformat_utc(datetime.now(UTC)),
                    "_dlt_deleted_at": None,
                }
            )
    return current_rows


def selected_resources(config: Config) -> list[HubSpotResource]:
    if not config.object_filter:
        return [resource for resource in V1_RESOURCES if resource.enabled]
    manifest = manifest_by_name()
    names = [name.strip() for name in config.object_filter.split(",") if name.strip()]
    return [manifest[name] for name in names]


def property_names_by_object(metadata_rows: list[dict[str, Any]]) -> tuple[str, ...]:
    return tuple(
        sorted(
            {
                str(row.get("name"))
                for row in metadata_rows
                if row.get("name") and not row.get("hidden", False)
            }
        )
    )


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
    property_names: dict[str, tuple[str, ...]] = {}
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
                if resource.name.startswith("properties_"):
                    property_names[resource.object_type] = property_names_by_object(hubspot_rows)
            elif resource.mode == "association":
                source_ids = sink.active_object_ids(resource.from_object_type or "")
                hubspot_rows = client.fetch_associations(resource, source_ids)
            else:
                requested_properties = property_names.get(resource.object_type, resource.properties)
                hubspot_rows = client.fetch_all_objects(resource, requested_properties)

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
                current_rows = normalize_association_rows(resource, hubspot_rows, run_id, datetime.now(UTC))
                sink.load_json_rows(
                    config.staging_dataset,
                    staging_table,
                    ASSOCIATION_CURRENT_SCHEMA,
                    current_rows,
                    write_disposition="WRITE_TRUNCATE",
                )
                sink.sync_association_scd(staging_table, run_id)
                sink.merge_current_associations(staging_table)
            else:
                current_rows = normalize_object_rows(resource, hubspot_rows, run_id, gcs_uri, datetime.now(UTC))
                sink.load_json_rows(
                    config.staging_dataset,
                    staging_table,
                    CURRENT_SCHEMA,
                    current_rows,
                    write_disposition="WRITE_TRUNCATE",
                )
                sink.sync_object_scd(resource, staging_table, run_id)
                sink.merge_current_object(resource, staging_table)
            sink.update_watermark(resource, started_at, run_id)
            resource_status[resource.name] = {
                "status": "success",
                "rows": len(hubspot_rows),
                "watermark_at": isoformat_utc(started_at),
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
