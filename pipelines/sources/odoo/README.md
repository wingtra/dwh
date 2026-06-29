# Odoo Source Pipeline

This folder is the independently deployable Odoo ingestion pipeline.

## Contents

- `src/` - backup fetch, filtered restore, dlt load, and BigQuery promotion
- `infra/` - setup, deploy, scheduler, monitoring, and IAM scripts
- `docker/` - container entrypoint for the in-container Postgres runtime
- `.dlt/` - dlt runtime configuration
- `docs/` - current runbook and archived implementation notes

## Common Commands

Run these from this folder unless noted otherwise:

```bash
infra/setup.sh
infra/deploy.sh
infra/setup_scheduler.sh
infra/setup_monitoring.sh data-team@example.com
```

Current behavior is documented in [docs/pipeline-overview.md](docs/pipeline-overview.md).
