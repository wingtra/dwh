{{ config(enabled=false) }}

/*
    Per-SKU consolidated BOM quantity (a.k.a. take rate). One row per
    product_code where IMM has a non-null take_rate. Used by
    `product_dimensions` to surface `take_rate` on `ol.products`, which
    in turn lets `bl.ctb_weekly_report` drop its direct join to the
    federated IMM sheet.

    Source: {{ ref('gsheet_inventory_master_ag') }} (the cleaned
    AG Wingtra INVENTORY MASTER sheet). Take rate is emitted "whenever
    it is available in IMM" — rows where `take_rate IS NULL` are dropped
    so the model never asserts a value for SKUs that aren't planned in
    IMM. `product_code` is already trimmed at the CL layer; no further
    normalisation needed here.

    Precedence rules (IMM is the primary source; the ~12 EOL products
    that the original CTB sheet falls back to via column P are NOT
    covered here — federation of that fallback is deferred): see
    docs/sc_kpi_ctb/recreation-summary.md.
*/

select
    product_code,
    take_rate
from {{ ref('gsheet_inventory_master_ag') }}
where take_rate is not null
