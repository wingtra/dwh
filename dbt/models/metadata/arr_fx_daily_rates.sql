/*
    FX rates used by the RevOps ARR accrual logic. One row per rate date.
    Source: read-only snapshot (2026-07-03) of the "Daily Rates" tab in the
    Accruals sheet, which Alex hand-pastes monthly from Endi's finance rates
    (CHF-based fixings). Cadence is irregular, not actually daily.
    The accrual logic picks the latest rate on or before a licence's
    warranty/service start date.
*/

{{
    config(
        materialized='view',
        tags=['daily', 'revops']
    )
}}

select
    /* DATES */
    rate_date,
    lead(rate_date) over (order by rate_date) as valid_until_date,

    /* MEASURES */
    eur_to_usd,
    chf_to_usd

from {{ ref('arr_fx_daily_rates_seed') }}
