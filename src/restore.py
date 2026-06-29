"""Restore a filtered Odoo backup into the in-container Postgres."""
import gzip
import logging
import subprocess

from src.config import PG_DATABASE, PG_USER, PG_SOCKET_DIR
from src.dump_filter import filter_stream
from src.tables import EXCLUDE_TABLES


log = logging.getLogger(__name__)


def restore(local_dump_path: str) -> None:
    """Stream the .sql.gz through the filter into psql."""
    # Drop/recreate target DB
    log.info("Recreating database %s", PG_DATABASE)
    subprocess.run(
        ["dropdb", "-h", PG_SOCKET_DIR, "-U", PG_USER, "--if-exists", PG_DATABASE],
        check=True,
    )
    subprocess.run(
        ["createdb", "-h", PG_SOCKET_DIR, "-U", PG_USER, PG_DATABASE],
        check=True,
    )

    log.info("Restoring (filtered) from %s into %s", local_dump_path, PG_DATABASE)

    psql = subprocess.Popen(
        [
            "psql",
            "-h",
            PG_SOCKET_DIR,
            "-U",
            PG_USER,
            "-d",
            PG_DATABASE,
            "--quiet",
            "-v",
            "ON_ERROR_STOP=1",
        ],
        stdin=subprocess.PIPE, text=True,
    )

    with gzip.open(local_dump_path, "rt", encoding="utf-8", errors="replace") as f:
        skipped = filter_stream(f, psql.stdin, EXCLUDE_TABLES)
    psql.stdin.close()
    rc = psql.wait()
    if rc != 0:
        raise RuntimeError(f"psql restore failed with exit code {rc}")

    for table, count in sorted(skipped.items(), key=lambda kv: -kv[1])[:10]:
        log.info("  skipped %s: %d rows", table, count)
    log.info("Restore complete.")
