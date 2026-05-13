"""Run dlt: in-container Postgres -> BigQuery."""
import logging
import os

import dlt
import sqlalchemy as sa
from dlt.sources.sql_database import sql_database
from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool

from src.config import PG_DATABASE, PG_USER, PG_SOCKET_DIR, BQ_DATASET


log = logging.getLogger(__name__)


def _pg_url() -> str:
    return f"postgresql+psycopg2://{PG_USER}@/{PG_DATABASE}?host={PG_SOCKET_DIR}"


def _type_adapter(sql_type):
    """Map Postgres numeric without explicit precision to Float to avoid BigQuery
    NUMERIC(38,9) precision errors. Columns with explicit precision are left as-is."""
    if isinstance(sql_type, (sa.Numeric, sa.DECIMAL)):
        if sql_type.precision is None:
            return sa.Float()
    return sql_type


def run():
    engine = create_engine(_pg_url(), poolclass=NullPool)
    source = sql_database(
        credentials=engine,
        type_adapter_callback=_type_adapter,
    )
    source.max_table_nesting = 0

    pipeline = dlt.pipeline(
        pipeline_name="odoo_to_bq",
        destination="bigquery",
        dataset_name=BQ_DATASET,
        progress="log",
    )
    info = pipeline.run(source, write_disposition="replace")
    log.info("dlt load info: %s", info)
    return info
