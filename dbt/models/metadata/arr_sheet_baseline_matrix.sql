/*
    Frozen validation baseline: the Accruals sheet's monthly recognized
    recurring revenue matrix, per month and license type, exported read-only
    on 2026-07-03. One row per month and license type.
    Used to (a) prove the DWH replica reproduces the sheet to the dollar and
    (b) show sheet-vs-DWH differences on the ARR dashboard.
    Refresh: manual re-export only, on explicit request (Drive is read-only).
*/

{{
    config(
        materialized='view',
        tags=['daily', 'revops']
    )
}}

select
    /* DATES */
    month_date,
    date('2026-07-03') as snapshot_as_of_date,

    /* DIMENSIONS */
    license_type_label,

    /* MEASURES */
    monthly_recognized_rr_usd

from {{ ref('arr_sheet_baseline_matrix_2026_07_03') }}
