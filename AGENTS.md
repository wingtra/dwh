# Repository Guidelines for Agents

This repository separates source ingestion from warehouse modeling. Keep that
boundary intact.

## Scope

- `pipelines/sources/<source>/` owns extraction, source runtime, deployment,
  secrets, and runbooks.
- `dbt/` owns warehouse transformations, CL/OL/BL models, tests,
  documentation, and business-facing outputs.
- Source loaders write raw `dl_*` datasets only. Do not add business logic or
  conformed warehouse models to pipeline code.
- dbt reads landed data through `source()` definitions and publishes modeled
  datasets.

## dbt Modeling

Follow `dbt/AGENTS.md` before editing anything under `dbt/`. When a change
touches dbt models, keep tests and YAML documentation in scope, not as a later
cleanup.

## Change Discipline

- Preserve unrelated local changes. This checkout may contain work in progress.
- Keep changes scoped to the source, model layer, or business domain requested.
- Prefer existing naming, layer, tag, and selector conventions over inventing
  new ones.
- Run the smallest useful validation for the change, at minimum `dbt parse` for
  dbt changes when credentials are not available.
