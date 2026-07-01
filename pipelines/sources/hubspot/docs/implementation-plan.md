# HubSpot to BigQuery Pipeline Implementation Plan

## Status

Planning only. This branch has not created cloud resources, secrets, datasets, buckets, schedulers, or HubSpot apps.

Claude adversarial review was requested, but the local approval reviewer blocked sending non-public repository and infrastructure context to the external Claude service. This document therefore includes an internal adversarial review. Run Claude only after explicit approval for the exact context that may be shared externally.

A local subagent adversarial review was completed after the first draft. Its verdict: the direction is right, but the first draft was not implementable safely because the HubSpot extraction contract, IAM baseline, current-state boundary, raw immutability, PII policy, scheduler runtime, and data-quality monitoring were too loose. This revision folds those blockers into mandatory acceptance gates.

## Goal

Build a daily HubSpot raw ingestion pipeline that is stable, safe, least-privilege, and compatible with the existing Wingtra `dwh` source-pipeline pattern:

- Source-isolated code under `pipelines/sources/hubspot/`
- Dedicated Cloud Run Job
- Dedicated Cloud Scheduler trigger
- HubSpot credentials in Secret Manager
- Raw API payloads landed to GCS as immutable JSONL
- Raw BigQuery dataset `dl_hubspot`
- Operational tables for runs, requests, cursors, and object manifests
- Downstream cleaning and reporting left to dbt after raw ingestion is proven

## Existing Repo Pattern To Follow

The HubSpot source should follow repo deployment conventions, but not blindly copy existing pipeline logic:

- `pipelines/sources/revolut/` is an independent API loader with `src/`, `infra/`, `docs/`, `Dockerfile`, `requirements.txt`, Cloud Run, Scheduler, Secret Manager, GCS raw landing, BigQuery DL tables, `_pipeline_runs`, `_api_requests`, and `_watermarks`.
- `pipelines/sources/odoo/` proves the stricter operational pattern for daily production ingestion: explicit setup/deploy/scheduler scripts, scoped IAM, run metadata, and live verification before calling the pipeline healthy.

Use those patterns for GCP setup, IAM, scheduling, deployment, run metadata, and verification. Design the actual load logic around HubSpot's CRM API shape: object-level modified timestamps, property metadata drift, association edges, archived records, rate limits, and the fact that business users usually need current CRM state while operators still need immutable raw extraction evidence.

## Proposed GCP Resources

| Resource | Proposed name | Purpose |
|---|---|---|
| Cloud Run Job | `hubspot-raw-loader` | Runs daily HubSpot extraction |
| Cloud Scheduler | `hubspot-raw-loader-daily` | Invokes the Cloud Run Job |
| BigQuery dataset | `dl_hubspot` | Raw HubSpot landing dataset |
| BigQuery dataset | `dl_hubspot_staging` | Per-run load staging before extract append and current MERGE |
| GCS bucket | `wingtra-dwh-hubspot-raw` | Immutable raw JSONL API page archive |
| Artifact Registry repo | Prefer existing source-pipeline repo if available, otherwise `crm-pipelines` | Docker image storage |
| Secret Manager secret | `hubspot-service-key` | HubSpot service key / bearer credential |
| Runtime service account | `hubspot-raw-loader@wingtra-dwh.iam.gserviceaccount.com` | Loader identity |
| Scheduler service account | `hubspot-scheduler@wingtra-dwh.iam.gserviceaccount.com` | Job invoker only |

No resource should be created until the final resource names, HubSpot scopes, and initial object list are approved.

## HubSpot Auth Approach

Use a HubSpot service key for v1 if the Wingtra HubSpot account has the beta service-key feature available. Fall back to a legacy private app token only if service keys are unavailable or Wingtra decides not to use beta auth yet.

Rationale:

- It is simpler than OAuth for an internal, single-tenant extraction job.
- Service keys are intended for simple server-to-server API access and can be scoped to only the objects required.
- Service keys use the same `Authorization: Bearer ...` request pattern as private app tokens, so the loader does not need auth-specific pipeline logic.
- OAuth is still the required direction for multi-customer, public, marketplace, webhook, or UI-extension integrations.
- HubSpot currently marks service keys as public beta, so the loader keeps the legacy private app token environment variable as a fallback.

Design constraints:

- Do not commit service keys, tokens, or generated `config.env`.
- Create the service key manually in HubSpot with the narrowest CRM read scopes needed.
- Store the service key only in Secret Manager.
- Read the secret at runtime.
- Treat service-key rotation as an operations task with a documented runbook.

Future change trigger:

- Move to OAuth if this ever becomes multi-portal, marketplace/distributed, needs webhooks/UI extensions, or if security policy rejects beta service keys.

Official docs checked while planning:

- HubSpot API usage guidelines and limits: https://developers.hubspot.com/docs/api/usage-details
- HubSpot service keys: https://developers.hubspot.com/docs/apps/developer-platform/build-apps/authentication/account-service-keys
- HubSpot legacy private app fallback: https://developers.hubspot.com/docs/apps/legacy-apps/private-apps/overview

## Initial Object Scope

V1 includes the full recommended CRM scope plus support and revenue-detail objects. Activity, marketing, and custom-object coverage stay out of v1 unless explicitly added later.

V1 objects:

- `contacts`
- `companies`
- `deals`
- `tickets`
- `owners`
- `pipelines`
- `pipeline stages`
- `products`
- `line_items`
- `quotes`
- CRM object schemas/properties metadata

Phase 2 candidates:

- `meetings`
- `calls`
- `emails`
- custom objects
- forms or marketing events, only if business reporting requires them and API feasibility is verified

V1 associations:

- contact-company
- contact-deal
- company-deal
- ticket-contact
- ticket-company
- ticket-deal
- deal-line item
- quote-deal
- quote-line item
- product-line item, if exposed by the selected API path

Each object must have a manifest entry:

- HubSpot object type
- API path and method
- ID field
- timestamp field used for incrementality
- cursor semantics and sort order
- requested property set
- required scopes
- archived/deleted extraction method
- association pairs to fetch
- enabled/disabled flag
- max pages per run
- per-run rate-limit budget
- expected smoke-test row count behavior

The manifest is a production contract, not a convenience config. Do not run broad backfills until `owners`, `pipelines`, and one core object pass a small smoke test with the checked-in manifest.

Minimum manifest shape:

| Field | Purpose |
|---|---|
| `object_type` | HubSpot object name used by the loader |
| `mode` | `object`, `metadata`, or `association` |
| `endpoint` | API path or endpoint template |
| `method` | HTTP method |
| `pagination_mode` | Cursor/page strategy |
| `cursor_field` | Source timestamp or cursor field |
| `sort_order` | Required API sort direction, if applicable |
| `properties` | Explicit property allowlist |
| `required_scopes` | Exact private-app scopes needed |
| `archived_strategy` | How archived/deleted records are captured |
| `page_limit` | Fail-closed maximum pages per run |
| `rate_limit_budget` | Request budget allocated to this object |
| `enabled` | Whether the object is active in production |

## HubSpot-Native Load Design

The loader should produce both immutable extraction evidence and raw current-state mirrors. This is neither pure Revolut-style append-only nor Odoo-style full-snapshot promotion.

Core principles:

- Raw evidence is append-only and immutable.
- Current-state raw mirrors are maintained by object-keyed MERGE from each successful incremental batch.
- Cleaning, casting, naming, and business logic remain in dbt CL/OL/BL.
- The loader owns source-system correctness: object identity, archive status, association edges, watermarks, retries, and reconciliation.
- dbt should not have to infer whether a raw row is the latest source state from extraction-log duplicates.

Recommended BigQuery table families:

| Table family | Example | Grain | Load behavior |
|---|---|---|---|
| Per-run staging | `dl_hubspot_staging.contacts__<run_id>` | One fetched object version in the current resource batch | Replace/create per object run, validate, then expire/drop |
| Raw extract log | `contacts_extracts` | One extracted object version per run/page | Append-only |
| Raw current mirror | `contacts` | One row per HubSpot object ID | MERGE by `object_id` |
| Association extract log | `association_edges_extracts` | One extracted edge per run/page | Append-only |
| Association current mirror | `association_edges` | One active edge per object pair/type | MERGE plus reconciliation |
| Metadata snapshots | `object_properties`, `object_schemas`, `owners`, `pipelines` | Source metadata entity | MERGE current plus optional snapshot log |
| Operations | `_pipeline_runs`, `_api_requests`, `_watermarks`, `_object_manifest` | Operational metadata | Append/update by run/resource |

This gives the warehouse a clean raw current-state source immediately while preserving auditability.

## Load Semantics Contract

Each run is a set of independently gated resource loads. A resource is one HubSpot object, metadata entity, or association pair.

Run modes:

- `incremental`: daily modified-window load using the object watermark and lookback.
- `backfill`: explicit object-scoped historical load. It may run in chunks and must be resumable.
- `reconciliation`: wider scan used to prove archive/delete state and association removals.
- `metadata`: owners, pipelines, object schemas, and object properties.

Per-resource sequence:

1. Create `run_id` and resource status row with `status = running`.
2. Read the resource manifest row and current watermark.
3. Calculate the request window: watermark minus lookback through run start time, or an explicit backfill/reconciliation range.
4. Fetch pages from HubSpot with retries, rate-limit backoff, and page-cap enforcement.
5. Write every raw page to immutable GCS using run-id/page-based object names.
6. Load normalized raw rows from the fetched pages into a per-run staging table in `dl_hubspot_staging`.
7. Validate staging: required IDs present, no duplicate current keys after dedupe, required timestamps parse, row count matches fetched-page counts, page cap not hit unless expected.
8. Append the deduped staged rows into the object extract-log table, preserving `run_id`, `extracted_at`, `gcs_uri`, and `raw_json`.
9. MERGE the deduped staged rows into the current mirror table.
10. Write `_api_requests`, resource status, row counts, and validation outcomes.
11. Advance the resource watermark only after staging validation, extract append, current MERGE, and operational writes all succeed.
12. Drop or expire the per-run staging table.

If any step fails after GCS writes, keep the raw GCS evidence and mark the resource attempt failed. Do not advance that resource watermark. The loader should retry the resource according to the retry policy below. If retries are exhausted, mark the resource failed, fail the Cloud Run execution, and notify. Other resources may continue only if the run mode explicitly allows partial success; the overall run must still report partial failure.

Current mirror MERGE rules for objects:

- Key by `object_id`.
- Dedupe staged rows by `object_id`, preferring the highest source `updated_at`, then latest `extracted_at`, then latest page/order as a deterministic tie-breaker.
- `when matched` update `properties_json`, `raw_json`, `updated_at`, `archived`, `last_seen_at`, `last_run_id`, `last_gcs_uri`, `loaded_at`, and `_dlt_synced_at`.
- `when matched` clear `_dlt_deleted_at` only when the staged row proves the object is active.
- `when not matched` insert with `first_seen_at = current_timestamp()`, `last_seen_at = current_timestamp()`, `_dlt_synced_at = current_timestamp()`, and `_dlt_deleted_at = null` unless the source explicitly says archived/deleted.
- Never use `when not matched by source` in ordinary incremental runs.

Current mirror MERGE rules for metadata:

- Owners, pipelines, pipeline stages, object properties, and object schemas are small enough to reload frequently.
- MERGE by source ID or stable metadata key.
- Preserve a metadata snapshot/log if schema drift investigation needs history.

Current mirror MERGE rules for associations:

- Key by `from_object_type`, `from_object_id`, `to_object_type`, `to_object_id`, `association_category`, and `association_type_id`.
- Append every extracted edge to `association_edges_extracts`.
- MERGE active edges into `association_edges` with `first_seen_at`, `last_seen_at`, `last_run_id`, and `_dlt_synced_at`.
- In ordinary incremental association fetches, do not delete edges merely because they are absent from the current batch.
- In association reconciliation mode, mark edges missing from a complete source-backed edge inventory with `_dlt_deleted_at = current_timestamp()`.

Idempotency:

- Re-running the same resource window with a new `run_id` may append duplicate evidence to extract logs, but the current mirror must converge to the same state.
- Re-running the same `run_id` should either resume safely or fail with a clear duplicate-run status; it must not overwrite GCS objects.
- Watermark advancement must be monotonic per resource and must never move past a failed resource window.
- Automatic retries must re-read the same prior watermark, not invent a later start time.
- GCS object names must include `attempt=<n>` or another deterministic retry-safe suffix if the same `run_id` is reused, so retries do not overwrite prior raw evidence.

Ordering:

- Metadata resources run first.
- Core objects run next: companies, contacts, deals, tickets, products, line items, quotes.
- Associations run after their endpoint object batches so referenced IDs and metadata are available.
- Reconciliation runs should be scheduled separately or explicitly marked, not hidden inside every daily incremental run.

## BigQuery DL Model

Create `dl_hubspot` as raw ingestion, not business logic.

Core current mirror table pattern per object:

| Column | Type | Notes |
|---|---|---|
| `object_type` | STRING | HubSpot object type |
| `object_id` | STRING | HubSpot object ID |
| `created_at` | TIMESTAMP | Source created timestamp, if present |
| `updated_at` | TIMESTAMP | Source modified timestamp, if present |
| `archived` | BOOL | Source archived flag, if exposed |
| `properties_json` | JSON | Properties block |
| `raw_json` | JSON | Full object payload |
| `first_seen_at` | TIMESTAMP | First successful loader observation |
| `last_seen_at` | TIMESTAMP | Most recent successful loader observation |
| `last_run_id` | STRING | Loader run that last updated this row |
| `last_gcs_uri` | STRING | Latest raw page archive |
| `loaded_at` | TIMESTAMP | BigQuery load time |
| `_dlt_synced_at` | TIMESTAMP | Compatibility timestamp for CL filters and repo conventions |
| `_dlt_deleted_at` | TIMESTAMP | Soft-delete marker; see deletion semantics below |

Core extract log table pattern per object:

| Column | Type | Notes |
|---|---|---|
| `run_id` | STRING | Loader run ID |
| `extracted_at` | TIMESTAMP | Page extraction time |
| `object_type` | STRING | HubSpot object type |
| `object_id` | STRING | HubSpot object ID |
| `updated_at` | TIMESTAMP | Source modified timestamp, if present |
| `archived` | BOOL | Source archived flag, if exposed |
| `properties_json` | JSON | Properties block |
| `raw_json` | JSON | Full object payload |
| `gcs_uri` | STRING | Raw page archive |
| `loaded_at` | TIMESTAMP | BigQuery load time |

Recommended tables:

- `contacts` and `contacts_extracts`
- `companies` and `companies_extracts`
- `deals` and `deals_extracts`
- `tickets` and `tickets_extracts`
- `products` and `products_extracts`
- `line_items` and `line_items_extracts`
- `quotes` and `quotes_extracts`
- `owners`
- `pipelines`
- `object_properties`
- `object_schemas`
- `association_edges` and `association_edges_extracts`
- `_pipeline_runs`
- `_api_requests`
- `_watermarks`
- `_object_manifest`

Do not flatten every HubSpot property into DL columns in v1. HubSpot property sets are portal-configurable and drift over time. Store JSON raw and let dbt CL models select stable, business-owned fields later.

HubSpot CRM data contains personal and potentially sensitive commercial fields. The loader must be allowlist-first for requested properties, must denylist known sensitive property names and patterns before writing audit/log rows, and must never write access tokens, headers, or authorization material into `_api_requests`, logs, or raw JSON metadata. Full object `raw_json` is acceptable only after the v1 property allowlist and sensitive-field handling are reviewed.

## Append-Only vs Current-State DL Decision

Recommendation for v1: hybrid raw extract logs plus current-state raw mirrors.

Why:

- HubSpot objects have frequent property/schema changes.
- Append-only evidence preserves extraction history and makes loader retries/audits easier.
- Current-state mirrors prevent raw consumers and dbt CL from repeatedly deduplicating extraction logs.
- HubSpot CRM reporting usually wants the latest object/association state.
- Incremental MERGE by HubSpot object ID is cheaper and more natural than daily full snapshots.

Counterargument:

- Current-state mirrors can hide historical changes if extract logs are not retained.
- MERGE bugs can corrupt the current mirror if watermarks advance before load validation.
- Archived/deleted records and association removals are harder than object upserts.

Resolution:

- Implement both extract logs and current raw mirrors in the loader.
- Advance watermarks only after extract log append, current MERGE, and operational writes all succeed for that object.
- Use periodic reconciliation to catch archive/delete and association drift.
- Let dbt CL focus on typed, business-stable models, not source-current-state reconstruction.

Production acceptance gate:

- Raw extract log tables exist and retain evidence.
- Raw current mirror tables exist for every v1 business object.
- Current mirror tables have uniqueness tests or validation queries on `object_id`.
- dbt CL models exist for typed business fields before business-facing BL/OL use.
- A README/runbook states which raw tables are extract logs and which are current mirrors.

## Soft Delete Semantics

Use the same column contract as Odoo and Revolut for downstream consistency:

- `_dlt_synced_at`
- `_dlt_deleted_at`

But do not copy Odoo's deletion trigger blindly.

Odoo loads a full production snapshot into staging, so a target row missing from the staged source is strong evidence that the source row is gone. HubSpot daily loads are incremental API windows, so a row missing from today's API response means only "not changed in this window", not "deleted".

HubSpot current mirror delete rules:

- Set `_dlt_deleted_at = null` when an object appears as active in a successful object batch.
- Set `_dlt_deleted_at = current_timestamp()` when HubSpot explicitly returns the object as archived/deleted or when a reconciliation run proves the source object is no longer active.
- Never set `_dlt_deleted_at` from ordinary incremental absence.
- For uncertain reconciliation results, keep `_dlt_deleted_at` unchanged and write a `reconciliation_status` / operational warning instead.
- For association edges, only mark deleted after an association-specific reconciliation proves the edge disappeared; do not infer edge deletion from unchanged parent objects.

This preserves the repo's clean-model convention of filtering `where _dlt_deleted_at is null`, while avoiding false deletes from partial HubSpot windows.

## Framework Choice: dlt vs Custom Loader

Recommendation: do not use the off-the-shelf `dlt` HubSpot verified source as the production loader without a proof-of-fit. Prefer a custom HubSpot API extraction layer plus explicit BigQuery MERGE SQL for v1, while optionally using `dlt` only if it can satisfy the manifest, delete, association, and observability contract.

Why not default to `dlt`:

- The official `dlt` HubSpot source exists and covers common objects, but its documented default resources include replace-style resources and broad custom-property behavior. This is useful for a quick load, but not automatically the best fit for a controlled CRM production mirror.
- We need first-class association edge mirrors, explicit archived/deleted semantics, object-specific reconciliation, immutable GCS raw page archives, scoped property allowlists, and detailed `_api_requests` audit rows.
- We need the loader's watermarks to advance only after raw archive, extract-log append, current MERGE, and operational metadata all succeed.
- The existing Odoo use of `dlt` works because the hard part is generic SQL database extraction from an ephemeral Postgres snapshot. HubSpot's hard part is API semantics and source correctness, not schema normalization.

Where `dlt` may still help:

- As a prototype to discover object shapes and compare row counts.
- For selected resources if we wrap them with our manifest, property allowlist, Secret Manager auth, and BigQuery post-load validation.
- For generic load mechanics if `write_disposition="merge"`, `primary_key`, dedup sorting, and hard-delete hints can be made to match the plan.

Production acceptance for using `dlt`:

- Prove it can load only approved properties.
- Prove it can produce or coexist with immutable raw GCS page archives.
- Prove current mirrors have deterministic MERGE behavior by `object_id`.
- Prove `_dlt_deleted_at` is driven only by explicit archive/delete or reconciliation evidence.
- Prove association edge current-state handling and deletion semantics.
- Prove request audit, rate-limit handling, retry behavior, and watermark gating are at least as good as the custom design.

If any of those fail, use a custom loader. The custom path is not much larger than forcing `dlt` into a shape it was not designed to own.

## Incremental Extraction Strategy

Use per-object cursoring with a conservative lookback, plus periodic reconciliation.

Initial backfill:

- Pull historical records per enabled object.
- Page until exhaustion.
- Cap pages per object and fail loudly if the cap is hit.
- Write all raw pages to GCS before loading to BigQuery.

Daily runs:

- Read `_watermarks` per object.
- Use `lastmodifieddate`, `hs_lastmodifieddate`, or the object-specific modified timestamp verified for that object.
- Apply a configurable lookback window, initially 14 days.
- Fetch archived records where supported, or schedule a periodic archived/deleted reconciliation if the API cannot expose deletions through the normal incremental path.
- Append extract-log rows first.
- MERGE the successful batch into the current mirror by `object_id`.
- Advance a watermark only after the extract append, current MERGE, and metadata writes succeed.
- Key watermarks by object and by association pair, not one global cursor.

Reconciliation runs:

- Run a wider object scan weekly or monthly, depending on portal size and API limits.
- Compare current mirror IDs to a fresh source ID inventory where feasible.
- Mark records as archived or missing only when the source API exposes enough evidence; otherwise record `reconciliation_status` and avoid destructive assumptions.
- Reconcile association edges separately because edge removals may not update object timestamps.

Metadata runs:

- Load owners, pipelines, object properties, and object schemas before business objects in every run or on a controlled cache interval.
- Snapshot the manifest and metadata version used for each object extraction.

Failure policy:

- Retry 429 and 5xx responses with exponential backoff.
- Honor `Retry-After` when present.
- Fail the run rather than silently truncating on max pages, malformed payloads, schema load failures, or missing required scopes.
- Record partial object status in `_pipeline_runs` and `_api_requests`.
- Support object-scoped reruns/backfills so one failed object does not require rerunning the full portal extraction.

Retry policy:

- In-process retry handles transient HubSpot/API failures: 429, 5xx, connection resets, and timeouts.
- BigQuery/GCS transient failures get bounded retry as well.
- Non-retryable failures fail immediately: missing required scopes, malformed manifest, schema-contract violation, duplicate current keys after deterministic dedupe, max page cap hit, or sensitive-field policy violation.
- After in-process retry exhaustion, the Cloud Run Job should fail so Cloud Run's job-level retry can rerun the same loader safely.
- Job-level retries must not advance watermarks unless the full resource sequence succeeds.
- After job-level retry exhaustion, send an alert with the failed resource, failure class, run ID, last successful watermark, and links/commands for logs and `_pipeline_runs`.

## Associations

Store associations as first-class edge rows, not nested-only payloads.

Proposed `association_edges` grain:

- Current mirror: one row per active association edge
- `from_object_type`
- `from_object_id`
- `to_object_type`
- `to_object_id`
- `association_category`
- `association_type_id`
- `association_label`
- `raw_json`
- `first_seen_at`
- `last_seen_at`
- `last_run_id`
- `loaded_at`

`association_edges_extracts` should keep one row per extracted edge per run/page with `run_id`, `extracted_at`, and `gcs_uri`.

Fetch strategy:

- Start with V1 pairs: contact-company, contact-deal, company-deal, ticket-contact, ticket-company, ticket-deal, deal-line item, quote-deal, quote-line item, and product-line item if exposed by the selected API path.
- Prefer batch association reads where volume warrants it.
- Keep edge extraction independently watermarked or tied to the source object run.

Risk:

- Associations can dominate runtime if fetched one object at a time. Implement batching before enabling broad association coverage.
- Association watermarks and page caps must be separate from object watermarks because association-only changes may not update the object timestamp used for daily object extraction.
- Association removals are the highest-risk silent data drift path. Do not rely only on incremental object modified timestamps to maintain association current state.

## Raw GCS Immutability

Raw JSONL is immutable only if the implementation enforces it.

Required path format:

```text
gs://wingtra-dwh-hubspot-raw/hubspot/object_type=<object_type>/run_date=<yyyy-mm-dd>/run_id=<run_id>/page=<page_number>.jsonl
```

Requirements:

- Upload with a generation-match precondition so retries cannot overwrite an existing object.
- Runtime service account gets `storage.objectCreator` only unless a concrete read/list need is approved.
- Raw retention/lifecycle policy must be decided before setup.
- Each BigQuery row stores the source `gcs_uri`.
- Failed partial pages stay in GCS for audit, but watermarks do not advance until BigQuery load and metadata writes succeed.

## Implementation Steps

1. Create source skeleton
   - `pipelines/sources/hubspot/README.md`
   - `pipelines/sources/hubspot/docs/pipeline-overview.md`
   - `pipelines/sources/hubspot/src/hubspot_raw_loader.py`
   - `pipelines/sources/hubspot/infra/config.env.example`
   - `pipelines/sources/hubspot/infra/setup.sh`
   - `pipelines/sources/hubspot/infra/deploy.sh`
   - `pipelines/sources/hubspot/infra/setup_scheduler.sh`
   - `pipelines/sources/hubspot/infra/setup_monitoring.sh`
   - `pipelines/sources/hubspot/Dockerfile`
   - `pipelines/sources/hubspot/requirements.txt`
   - `pipelines/sources/hubspot/cloudbuild.yaml`

2. Build loader core
   - Config and manifest loading
   - HubSpot HTTP client with retries, timeout, rate-limit handling, and request audit collection
   - Secret Manager token read
   - GCS JSONL writer
   - BigQuery dataset/table creation
   - BigQuery append loads
   - Per-object watermark read/write
   - Run status and error handling

3. Build object extraction
   - Owners and pipelines first because they are smaller and useful lookup tables
   - Contacts, companies, deals next
   - Tickets only after confirming scope and business need
   - Properties/schemas metadata on every run or daily with cheap caching

4. Build associations
   - Add selected edge pairs only after object extraction is stable
   - Use batch reads and page caps
   - Record association request counts separately

5. Add infrastructure
   - Idempotent setup script for APIs, dataset, bucket, artifact repo, service account, secret access, and dataset-level IAM
   - Deploy script for Cloud Build and Cloud Run Job
   - Scheduler setup using a separate invoker service account
   - Monitoring setup for failed Cloud Run Job executions
   - Read-only IAM baseline capture before any mutation
   - Explicit removal of accidental broad project-level runtime roles after scoped bindings are applied

6. Validate locally and in GCP
   - `python -m py_compile` with `PYTHONPYCACHEPREFIX=/tmp/...`
   - Shell syntax checks for infra scripts
   - Unit tests for pagination, timestamp parsing, JSONL conversion, watermark gating, and retry classification
   - Dry-run loader mode against a fake/small manifest
   - Manual Cloud Run smoke test with one small object
   - Verify GCS raw objects, BigQuery row counts, `_pipeline_runs`, `_api_requests`, and `_watermarks`
   - Verify scope failure mode with a deliberately missing optional object/scope in a non-production test manifest
- Verify current mirror uniqueness checks before any business-facing use
- Verify dbt CL typed-field tests before BL/OL models depend on HubSpot
- Verify `_dlt_deleted_at` behavior for active, explicitly archived, reappearing, and reconciliation-missing objects
- If evaluating `dlt`, run a proof-of-fit against one small object and one association pair before committing to it

7. Backfill and scheduler rollout
   - Run historical backfill object by object
   - Verify counts against HubSpot UI/API totals where possible
   - Enable daily scheduler only after one clean manual run
   - Confirm next scheduled run state
   - Add alerting

## Least-Privilege IAM

Runtime service account:

- Project-level `roles/bigquery.jobUser`
- Dataset-level editor/writer access on `dl_hubspot` and `dl_hubspot_staging` only
- `roles/storage.objectCreator` on the HubSpot raw bucket only
- `roles/secretmanager.secretAccessor` on `hubspot-service-key` only

Scheduler service account:

- `roles/run.invoker` on `hubspot-raw-loader` only

Do not grant broad project-level BigQuery data editor, Storage admin, or Secret Manager accessor roles.

Before mutating IAM:

- Capture current project IAM bindings for both proposed service accounts.
- Capture dataset IAM for `dl_hubspot` and `dl_hubspot_staging`, if either already exists.
- Capture bucket IAM for `wingtra-dwh-hubspot-raw`, if it already exists.
- Capture secret IAM for `hubspot-service-key`, if it already exists.
- Print the exact intended delta and wait for approval.

After scoped bindings:

- Remove accidental project-level runtime roles such as broad `roles/bigquery.dataEditor`, `roles/storage.admin`, `roles/storage.objectAdmin`, `roles/secretmanager.secretAccessor`, or project-level `roles/run.invoker`, if present and not explicitly approved.
- Keep deploy/build permissions separate from runtime permissions.

## Runtime And Scheduler Contract

Cloud Run Job configuration must be explicit in `infra/deploy.sh`:

- Task timeout
- Max retries
- CPU
- Memory
- Service account
- Environment variables
- Backfill/object filter mode

Scheduler configuration must be explicit in `infra/setup_scheduler.sh`:

- Cron
- Timezone
- Target Cloud Run Job URI
- OAuth service account
- Retry/deadline behavior
- Description naming the target dataset

Initial recommendation:

- Daily schedule: `30 5 * * *`
- Timezone: `Europe/Zurich`
- Cloud Run max retries: start with `2`, then tune after smoke tests
- Cloud Run timeout: start at 1800 seconds, revisit after smoke/backfill timings
- Scheduler identity: `hubspot-scheduler@wingtra-dwh.iam.gserviceaccount.com`
- Object-scoped backfill mode required before broad historical loads

Add overlap protection before production scheduling. At minimum, the loader should check for another in-progress successful-start run and fail closed or skip with an explicit status.

## Operational Table Requirements

`_pipeline_runs` must record:

- `run_id`
- `started_at`
- `finished_at`
- `status`
- `mode`
- `object_filter`
- object-level statuses
- rows/pages fetched and loaded
- request count
- retry count
- page-cap hits
- error class
- sanitized error message

`_api_requests` must record:

- `run_id`
- `request_id`
- `object_type`
- sanitized path
- sanitized params
- status code
- duration
- retry count
- page cursor
- rows returned
- failure class

`_watermarks` must record:

- `resource_type`
- `resource_name`
- `watermark_at`
- `cursor_payload`
- `updated_at`
- `run_id`

`_object_manifest` must snapshot the manifest used by each run so future investigations can reconstruct extraction behavior.

## Monitoring Requirements

Job-failure alerting is necessary but not sufficient.

Required alerts or equivalent checks:

- Cloud Run execution failed.
- Cloud Run execution failed after retry exhaustion.
- No successful run in 26 hours after scheduler enablement.
- Any v1 object has partial/failure status.
- Page cap hit.
- High 429 rate or repeated retry exhaustion.
- Watermark not advancing for enabled objects.
- Zero-row anomaly after prior nonzero daily runs, excluding approved quiet objects.
- Raw GCS writes happened but BigQuery load or watermark advance failed.

Alert payload should include:

- Pipeline/job name.
- Run ID and attempt number.
- Failed resource/object.
- Failure class.
- Last successful watermark for that resource.
- Whether Cloud Run will retry or retries are exhausted.
- BigQuery query for `_pipeline_runs` and a `gcloud logging read` command for the job.

## Operational Checks

Manual run:

```bash
gcloud run jobs execute hubspot-raw-loader \
  --region=europe-west1 \
  --project=wingtra-dwh \
  --wait
```

Recent runs:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot._pipeline_runs`
ORDER BY started_at DESC
LIMIT 10;
```

Watermarks:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot._watermarks`
ORDER BY updated_at DESC;
```

Request failures:

```sql
SELECT *
FROM `wingtra-dwh.dl_hubspot._api_requests`
WHERE status_code >= 400 OR error_message IS NOT NULL
ORDER BY requested_at DESC
LIMIT 50;
```

## Adversarial Review

| Claim | Critique | Decision |
|---|---|---|
| The first draft is implementable | It named the right components but left the actual HubSpot extraction contract undefined. | Require a checked-in manifest and smoke-test gate before broad backfill. |
| Service key is the best v1 auth path | HubSpot marks service keys as public beta, so there is a product-change risk. A leaked key may expose broad CRM data. | Prefer service key for internal server-to-server v1 because it is operationally cleaner; keep legacy private app token as fallback and verify scopes before creation. |
| Append-only DL is safest | It protects history but is awkward for latest-state analytics and can produce duplicate rows if queried directly. | Use append-only extract logs plus loader-maintained current raw mirrors. |
| Same `_dlt_deleted_at` logic as Odoo should work | Odoo has a full snapshot; HubSpot incrementals are partial windows. Missing from an incremental response is not deletion evidence. | Keep the `_dlt_deleted_at` column contract, but only set it from explicit archive/delete signals or reconciliation. |
| `dlt` should be used because the repo already uses it | Existing Odoo `dlt` solves SQL snapshot extraction. HubSpot's hardest problems are API semantics, associations, deletes, and auditability. | Custom loader by default; use `dlt` only after proof-of-fit against the production contract. |
| `lastmodifieddate` cursoring is straightforward | HubSpot timestamp fields differ by object, properties can be missing, and search APIs may have stricter limits than general object reads. | Require per-object manifest and smoke tests before broad backfill. |
| Daily 14-day lookback catches late updates | It may miss older corrections, archived records, or association-only changes. | Add periodic wider reconciliation and explicit association extraction. |
| Associations can be added after objects | Without associations, CRM facts may be hard to use. With associations, runtime and rate limits can blow up. | Start with selected high-value pairs using batch endpoints; do not enable all pairs. |
| Raw JSON is enough for schema drift | BigQuery JSON keeps flexibility but does not protect against unusable property names, missing business fields, or sensitive CRM data. | Persist object/property metadata, use property allowlists, redact logs, and defer stable business fields to dbt. |
| One daily job is simple | One object failure may block all objects and watermarks. | Track per-object status and watermarks; fail closed, but make reruns object-aware. |
| GCS `objectCreator` is sufficient | It prevents overwrite but can complicate retries with identical object names. | Use run-id/page-based immutable object names. |
| Setup scripts can create missing secrets | Silent secret creation is an approval risk. | Setup may create empty secret containers only after explicit approval; never add secret versions automatically. |
| Initial backfill can run through the same job | Large portals may exceed Cloud Run task timeout or HubSpot limits. | Add object/page caps, resumable watermarks, and optionally per-object backfill mode. |
| Monitoring failed job count is enough | The job can succeed while one object silently loads zero rows or stops advancing. | Add data-quality and freshness alerts, not only Cloud Run failure alerts. |

## Open Decisions Before Implementation

- Exact HubSpot portal and service-key scopes
- Final v1 property allowlists for contacts, companies, deals, tickets, products, line items, and quotes
- Checked-in manifest format and initial manifest rows
- Whether archived/deleted objects must be captured daily or via periodic reconciliation
- Lookback window default: 7, 14, or 31 days
- Raw GCS retention period
- Alert email or notification channel
- Whether to reuse an Artifact Registry repo or create `crm-pipelines`
- Whether Claude may receive a sanitized version of this plan for external critique

## Proposed Next Implementation Commit Scope

The first implementation commit should be narrow:

- Source skeleton and docs
- Loader config, manifest, and table schemas
- HubSpot client with mocked tests
- Current mirror MERGE skeleton and tests for the first core object
- dbt CL typed-field model skeleton for the first core object
- `_dlt_deleted_at` soft-delete tests for explicit archive and non-delete incremental absence
- `dlt` proof-of-fit note: accepted or rejected with evidence
- No cloud resource mutation
- No scheduler
- No real token usage

Only after review should the second commit add infrastructure scripts and the first controlled smoke-test path.
