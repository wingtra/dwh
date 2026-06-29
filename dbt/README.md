# dbt

Warehouse modeling lives here, separate from source ingestion.

Use dbt for transformations that clean, conform, combine, test, and publish
landed raw data from Odoo, Revolut, HubSpot, and future sources. Do not put
source-specific extraction or deployment code here.

## Layers

The warehouse layers are:

```text
dl_*  source-owned raw landing datasets
cl_*  clean/source-conformed dbt models
ol_*  object-layer dbt models
bl_*  business-layer dbt models
```

`dl_*` is produced by source loaders under `pipelines/sources/<source>/`. dbt
reads DL datasets through `source()` definitions, but does not own DL loading.

dbt model folders map to the layers:

```text
models/clean/      -> cl_* datasets
models/object/     -> ol_* datasets
models/business/   -> bl_* datasets
models/metadata/   -> meta dataset
```

## Runner

The dbt runner is source-agnostic. Cloud Scheduler wakes up a single Cloud Run
Job, and dbt selectors decide which models are included in a given run.

Default runtime behavior:

```text
Cloud Scheduler -> Cloud Run Job dbt-runner -> dbt build --selector scheduled
```

Use model tags and `selectors.yml` for daily, weekly, and domain-specific
grouping. Source loaders should only write raw `dl_*` datasets; dbt owns CL,
OL, BL, tests, and documentation.

Local-only files such as `profiles.yml`, `target/`, `logs/`, and
`dbt_packages/` must stay out of Git.
