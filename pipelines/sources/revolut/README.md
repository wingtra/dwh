# Revolut Source Pipeline

This folder is the independently deployable Revolut Business raw ingestion
pipeline.

## Contents

- `src/` - Revolut API extraction, raw GCS landing, BigQuery append loads, and watermarks
- `infra/` - setup, deploy, and direct scheduler scripts
- `docs/` - current runbook and operational notes
- `cloudbuild.yaml` - Cloud Build image build/push definition

## Common Commands

Run these from this folder unless noted otherwise:

```bash
infra/setup.sh
infra/deploy.sh
infra/setup_scheduler.sh
```

Current behavior is documented in [docs/pipeline-overview.md](docs/pipeline-overview.md).
