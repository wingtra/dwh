# dbt

Warehouse modeling lives here, separate from source ingestion.

Use dbt for transformations that combine, clean, test, and publish landed raw
data from Odoo, Revolut, HubSpot, and future sources. Do not put source-specific
extraction or deployment code here.

## Runner

The dbt runner is source-agnostic. Cloud Scheduler wakes up a single Cloud Run
Job, and dbt selectors decide which models are included in a given run.

Default runtime behavior:

```text
Cloud Scheduler -> Cloud Run Job dbt-runner -> dbt build --selector scheduled
```

Use model tags and `selectors.yml` for daily, weekly, and domain-specific
grouping. Source loaders should only write raw `dl_*` datasets; dbt owns
cleaning, conformance, business models, marts, tests, and documentation.

Local-only files such as `profiles.yml`, `target/`, `logs/`, and
`dbt_packages/` must stay out of Git.
