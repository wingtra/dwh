/*
    Frozen validation baseline: the Accruals sheet's "ARR Import" tab (the
    raw HubSpot Licences report rows Alex pasted), exported read-only on
    2026-07-03. One row per licence in the sheet snapshot.
    Used to isolate formula correctness from data drift: applying the sheet's
    own accrual formula to these rows must reproduce the matrix baseline.
*/

{{
    config(
        materialized='view',
        tags=['daily', 'revops']
    )
}}

select
    /* IDS */
    cast(licence_id as string) as licence_id,

    /* DATES */
    warranty_service_start_date,
    warranty_service_expiration_date,
    date('2026-07-03') as snapshot_as_of_date,

    /* DIMENSIONS */
    license_type_label,
    nullif(deal_currency_code, '') as recurring_revenue_currency,
    license_type_detail,

    /* MEASURES */
    amount_source as recurring_revenue_amount_source

from {{ ref('arr_sheet_baseline_licences_2026_07_03') }}
