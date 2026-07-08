# Wingtra DWH

This repository separates source ingestion from warehouse modeling.

## Layout

```text
pipelines/
  sources/
    odoo/          # independently deployed Odoo ingestion pipeline
    revolut/       # independently deployed Revolut ingestion pipeline
    hubspot/       # independently deployed HubSpot ingestion pipeline
  shared/          # shared pipeline helpers, added only when duplication is real
dbt/               # warehouse transformations across landed sources
```

Source pipelines own extraction, runtime, deployment, secrets, and runbooks.
The dbt project owns CL, OL, BL, tests, and business-facing warehouse outputs.

Agents working in this repo must follow [AGENTS.md](AGENTS.md). For dbt model
changes, also follow [dbt/AGENTS.md](dbt/AGENTS.md).

## Current Sources

- [Odoo pipeline overview](pipelines/sources/odoo/docs/pipeline-overview.md)
- [Revolut pipeline overview](pipelines/sources/revolut/docs/pipeline-overview.md)
- [HubSpot pipeline overview](pipelines/sources/hubspot/docs/pipeline-overview.md)
