# dbt Modeling Guidelines for Agents

Use these rules for every dbt change in this project.

## Layer Boundaries

The warehouse layers are fixed:

- `dl_*`: raw landing datasets owned by source loaders. dbt reads these with
  `source()` and does not own loading.
- `cl_*`: clean/source-conformed models in `models/clean/`.
- `ol_*`: reusable object-layer models in `models/object/`.
- `bl_*`: business/reporting models in `models/business/`.
- `meta`: stable metadata and mapping models in `models/metadata/`.

Do not skip layers for convenience. Put logic at the lowest layer where it is
reusable and semantically correct.

## Naming and Grain

- Keep model names aligned with the layer and folder: `cl_<source>__...`,
  object/business names in OL/BL, and metadata names in `meta`.
- Every model should document its grain in YAML under `meta.grain`.
- Primary keys and natural grains must have tests. Use `not_null`, `unique`,
  `relationships`, and singular SQL tests where dbt built-ins are not enough.
- If a model is append-only or snapshot-like, document how consumers select the
  current slice.

## Clean Layer

- CL models should type, rename, normalize, and lightly clean source data.
- Keep source-specific quirks and raw audit fields visible when they matter
  downstream.
- Avoid business-report filters in CL unless they are explicit project policy
  for that source and documented in the model YAML.

## Object Layer

- OL models represent reusable business objects such as products, orders,
  transactions, seats, licences, organizations, contacts, stock movements, and
  stock locations.
- OL should expose stable keys, foreign keys, statuses, and reusable flags.
- Do not bake report-specific scope into OL models. Put report-specific cuts in
  BL.

## Business Layer

- BL models are consumer-facing outputs and should encode the reporting logic
  that the dashboard, sheet, or business process expects.
- Make business-rule branches explainable with explicit flags, reason fields,
  or descriptions when the logic is not obvious.
- Add accepted-value tests for enumerated outcomes and singular SQL tests for
  report grain or reconciliation rules.

## YAML, Tests, and Selectors

- Update the adjacent `_...__models.yml` file with descriptions, `meta.layer`,
  `meta.grain`, useful synonyms, and column tests.
- Tests are part of the model change. Do not add models without corresponding
  tests for keys, grain, and important enums.
- Keep model tags/selectors aligned with `selectors.yml`; scheduled production
  runs depend on selectors.
- If credentials are unavailable, still run `dbt parse` to validate structure
  and graph shape.
