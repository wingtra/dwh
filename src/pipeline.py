"""Run dlt: in-container Postgres -> BigQuery."""
import logging

import dlt
import sqlalchemy as sa
from dlt.sources.sql_database import sql_database
from google.api_core.exceptions import NotFound
from google.cloud import bigquery
from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool

from src.config import (
    BQ_DATASET,
    BQ_LOCATION,
    BQ_STAGING_DATASET,
    GCP_PROJECT,
    PG_DATABASE,
    PG_SOCKET_DIR,
    PG_USER,
)


log = logging.getLogger(__name__)


# Drop TOAST-heavy columns (HTML/BINARY/TEXT) from the quality.* tables before
# dlt extracts them. The row metadata (~1 MB total per table) is needed for KPI
# work; the dropped columns hold embedded images and long-form text that bloated
# the dump to ~3 GB and caused OOM during dlt normalize.
TABLE_DROP_COLUMNS: dict[str, list[str]] = {
    "quality_alert": ["action_corrective", "action_preventive", "description"],
    "quality_check": [
        "picture",
        "worksheet_document",
        "failure_message",
        "note",
        "additional_note",
        "warning_message",
    ],
    "quality_point": [
        "worksheet_document",
        "failure_message",
        "note",
        "reason",
    ],
}


SENSITIVE_DROP_COLUMNS: dict[str, list[str]] = {
    "account_journal": ["access_token"],
    "account_move": ["access_token"],
    "delivery_carrier": [
        "fedex_developer_key",
        "fedex_developer_password",
        "fedex_rest_developer_key",
        "fedex_rest_developer_password",
        "fedex_rest_access_token",
    ],
    "documents_document": ["document_token"],
    "documents_redirect": ["access_token"],
    "hr_employee": [
        "private_street",
        "private_street2",
        "private_city",
        "private_state_id",
        "private_zip",
        "private_country_id",
        "private_phone",
        "private_email",
        "private_car_plate",
    ],
    "purchase_order": ["access_token"],
    "quality_reason": ["access_token"],
    "res_partner": ["ocn_token"],
    "res_users": ["password", "totp_secret", "oauth_access_token"],
    "sale_order": ["access_token"],
    "spreadsheet_dashboard_share": ["access_token"],
    "wt_product_expert": ["access_token"],
    "wt_product_revision": ["access_token"],
}


PROMOTION_METADATA_COLUMNS = {
    "_dlt_synced_at": bigquery.SchemaField("_dlt_synced_at", "TIMESTAMP"),
    "_dlt_row_hash": bigquery.SchemaField("_dlt_row_hash", "STRING"),
    "_dlt_deleted_at": bigquery.SchemaField("_dlt_deleted_at", "TIMESTAMP"),
}


def _pg_url() -> str:
    return f"postgresql+psycopg2://{PG_USER}@/{PG_DATABASE}?host={PG_SOCKET_DIR}"


def _type_adapter(sql_type):
    """Map Postgres numeric without explicit precision to Float to avoid BigQuery
    NUMERIC(38,9) precision errors. Columns with explicit precision are left as-is."""
    if isinstance(sql_type, (sa.Numeric, sa.DECIMAL)):
        if sql_type.precision is None:
            return sa.Float()
    return sql_type


def _table_adapter(table):
    """Drop pre-declared bloated columns before dlt reads them. SQLAlchemy
    Table.columns is a read-only view; mutate _columns directly (the same
    approach dlt's own docs recommend for this hook)."""
    drop = (
        TABLE_DROP_COLUMNS.get(table.name, [])
        + SENSITIVE_DROP_COLUMNS.get(table.name, [])
    )
    for col_name in drop:
        col = table.columns.get(col_name)
        if col is not None:
            table._columns.remove(col)
            log.info("Dropped %s.%s from extraction", table.name, col_name)


def _table_id(dataset_name: str, table_name: str) -> str:
    return f"{GCP_PROJECT}.{dataset_name}.{table_name}"


def _quote(name: str) -> str:
    return f"`{name.replace('`', '``')}`"


def _metadata_field_names(columns: list[str]) -> list[str]:
    names = ["_dlt_synced_at", "_dlt_deleted_at"]
    if _key_columns(columns) == ["_dlt_row_hash"]:
        names.append("_dlt_row_hash")
    return names


def _key_columns(columns: list[str]) -> list[str]:
    if "id" in columns:
        return ["id"]
    return ["_dlt_row_hash"]


def _hash_columns(columns: list[str]) -> list[str]:
    business_columns = [column for column in columns if not column.startswith("_dlt")]
    return business_columns or columns


def _row_hash_expression(columns: list[str]) -> str:
    fields = ", ".join(f"S.{_quote(column)}" for column in _hash_columns(columns))
    return f"to_hex(sha256(to_json_string(struct({fields}))))"


def _ensure_target_table(
    client: bigquery.Client,
    table_name: str,
    staging_schema: list[bigquery.SchemaField],
    key_columns: list[str],
) -> bigquery.Table:
    target_ref = _table_id(BQ_DATASET, table_name)
    metadata_fields = ["_dlt_synced_at", "_dlt_deleted_at"]
    if key_columns == ["_dlt_row_hash"]:
        metadata_fields.append("_dlt_row_hash")

    try:
        table = client.get_table(target_ref)
    except NotFound:
        schema = list(staging_schema) + [
            PROMOTION_METADATA_COLUMNS[name] for name in metadata_fields
        ]
        table = bigquery.Table(target_ref, schema=schema)
        created = client.create_table(table)
        log.info("Created target table %s", target_ref)
        return created

    existing = {field.name for field in table.schema}
    additions = [
        field
        for field in staging_schema
        if field.name not in existing
    ]
    additions.extend(
        PROMOTION_METADATA_COLUMNS[name]
        for name in metadata_fields
        if name not in existing
    )
    if additions:
        table.schema = list(table.schema) + additions
        table = client.update_table(table, ["schema"])
        log.info("Added %d columns to %s", len(additions), target_ref)
    return table


def _check_schema_compatible(
    client: bigquery.Client,
    table_name: str,
    staging_schema: list[bigquery.SchemaField],
) -> None:
    try:
        target_table = client.get_table(_table_id(BQ_DATASET, table_name))
    except NotFound:
        return

    target_fields = {field.name: field for field in target_table.schema}
    for staging_field in staging_schema:
        target_field = target_fields.get(staging_field.name)
        if target_field is None:
            continue
        if (
            target_field.field_type != staging_field.field_type
            or target_field.mode != staging_field.mode
        ):
            raise RuntimeError(
                "Schema drift for "
                f"{table_name}.{staging_field.name}: "
                f"target={target_field.field_type}/{target_field.mode}, "
                f"staging={staging_field.field_type}/{staging_field.mode}"
            )


def _staging_table_names(client: bigquery.Client) -> list[str]:
    return [
        table_item.table_id
        for table_item in client.list_tables(f"{GCP_PROJECT}.{BQ_STAGING_DATASET}")
        if not table_item.table_id.startswith("_dlt")
    ]


def _preflight_staging_dataset(client: bigquery.Client, table_names: list[str]) -> None:
    for table_name in table_names:
        staging_table = client.get_table(_table_id(BQ_STAGING_DATASET, table_name))
        _check_schema_compatible(client, table_name, list(staging_table.schema))
    log.info("Preflighted %d staging table schemas", len(table_names))


def _deduped_source_sql(
    staging_ref: str,
    source_columns: list[str],
    key_columns: list[str],
) -> str:
    select_columns = ", ".join(f"S.{_quote(column)}" for column in source_columns)
    if key_columns == ["_dlt_row_hash"]:
        row_hash = _row_hash_expression(source_columns)
        select_columns = f"{select_columns}, {row_hash} as `_dlt_row_hash`"
        partition_by = "`_dlt_row_hash`"
    else:
        partition_by = ", ".join(_quote(column) for column in key_columns)

    order_by = "`_dlt_load_id` desc" if "_dlt_load_id" in source_columns else "1"
    return f"""
        select * except(_rn)
        from (
            select
                prepared.*,
                row_number() over (
                    partition by {partition_by}
                    order by {order_by}
                ) as _rn
            from (
                select {select_columns}
                from `{staging_ref}` S
            ) prepared
        )
        where _rn = 1
    """


def _promote_table(client: bigquery.Client, table_name: str) -> int:
    staging_ref = _table_id(BQ_STAGING_DATASET, table_name)
    target_ref = _table_id(BQ_DATASET, table_name)
    staging_table = client.get_table(staging_ref)
    source_columns = [field.name for field in staging_table.schema]
    if not source_columns:
        log.warning("Skipping %s because staging table has no columns", table_name)
        return 0

    key_columns = _key_columns(source_columns)
    target_table = _ensure_target_table(
        client,
        table_name,
        list(staging_table.schema),
        key_columns,
    )
    target_columns = {field.name for field in target_table.schema}
    available_source_columns = [
        column for column in source_columns if column in target_columns
    ]
    metadata_columns = _metadata_field_names(available_source_columns)

    source_sql = _deduped_source_sql(
        staging_ref,
        available_source_columns,
        key_columns,
    )
    on_clause = " and ".join(
        f"T.{_quote(column)} = S.{_quote(column)}" for column in key_columns
    )
    update_columns = [
        column
        for column in available_source_columns
        if column not in key_columns and column in target_columns
    ]
    update_assignments = [
        f"{_quote(column)} = S.{_quote(column)}" for column in update_columns
    ]
    update_assignments.append("`_dlt_synced_at` = current_timestamp()")
    update_assignments.append("`_dlt_deleted_at` = null")

    insert_columns = available_source_columns + [
        column for column in metadata_columns if column not in available_source_columns
    ]
    insert_values = [
        f"S.{_quote(column)}" for column in available_source_columns
    ] + [
        (
            "current_timestamp()"
            if column == "_dlt_synced_at"
            else "null"
            if column == "_dlt_deleted_at"
            else f"S.{_quote(column)}"
        )
        for column in metadata_columns
        if column not in available_source_columns
    ]

    sql = f"""
        merge `{target_ref}` T
        using ({source_sql}) S
        on {on_clause}
        when matched then update set
            {", ".join(update_assignments)}
        when not matched then insert ({", ".join(_quote(column) for column in insert_columns)})
        values ({", ".join(insert_values)})
        when not matched by source and T.`_dlt_deleted_at` is null then update set
            `_dlt_synced_at` = current_timestamp(),
            `_dlt_deleted_at` = current_timestamp()
    """
    job = client.query(sql, location=BQ_LOCATION)
    job.result()
    affected = job.num_dml_affected_rows or 0
    log.info("Promoted %s (%d affected rows)", table_name, affected)
    return affected


def _promote_staging_dataset() -> dict[str, int]:
    client = bigquery.Client(project=GCP_PROJECT, location=BQ_LOCATION)
    promoted: dict[str, int] = {}
    table_names = _staging_table_names(client)
    _preflight_staging_dataset(client, table_names)
    for table_name in table_names:
        promoted[table_name] = _promote_table(client, table_name)
    return promoted


def run():
    engine = create_engine(_pg_url(), poolclass=NullPool)
    source = sql_database(
        credentials=engine,
        type_adapter_callback=_type_adapter,
        table_adapter_callback=_table_adapter,
    )
    source.max_table_nesting = 0

    pipeline = dlt.pipeline(
        pipeline_name="odoo_to_bq",
        destination="bigquery",
        dataset_name=BQ_STAGING_DATASET,
        progress="log",
    )
    info = pipeline.run(source, write_disposition="replace")
    log.info("dlt staging load info: %s", info)
    promoted = _promote_staging_dataset()
    log.info("Promoted %d staging tables into %s", len(promoted), BQ_DATASET)
    return info
