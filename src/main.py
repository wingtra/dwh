"""Cloud Run Job entrypoint."""
import logging
import os
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
        local_path = os.environ.get("LOCAL_DUMP_PATH") or fetch()
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
