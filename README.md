# Wingtra DWH

This repository separates source ingestion from warehouse modeling.

## Layout

```text
pipelines/
  sources/
    odoo/          # independently deployed Odoo ingestion pipeline
  shared/          # shared pipeline helpers, added only when duplication is real
dbt/               # warehouse transformations across landed sources
```

Source pipelines own extraction, runtime, deployment, secrets, and runbooks.
The dbt project owns cross-source modeling, tests, and business-facing marts.

## Current Sources

- [Odoo pipeline overview](pipelines/sources/odoo/docs/pipeline-overview.md)
