/*
    Month-by-month recognized recurring revenue per licence, computed two
    ways side by side:

    1. monthly_rr_sheet_method_usd — bug-for-bug replica of the Accruals
       sheet ('Combined Output' cols P/Q + matrix SUMPRODUCT):
       amount / (DATEDIF(start, end, "m") + 1), recognized in every calendar
       month from start month through expiration month INCLUSIVE, EUR/CHF
       converted at the latest FX rate on or before the start date, unknown
       currency falls back to amount / ROUND(days / 30.44) UNCONVERTED.
       Known flaw: licences whose expiration falls on the start-date
       anniversary day spread 12 months of money over 13 calendar months and
       double-count the boundary month with their renewal.

    2. monthly_rr_day_prorated_usd — corrected method: the same USD amount
       spread by actual active days per calendar month over the half-open
       window [start, expiration). Convention-independent, no boundary
       double-count. Unknown-currency amounts stay unconverted (same
       limitation as the sheet, kept for comparability).

    Both methods use the raw report amount (not the "corrected" HubSpot
    property) so method deltas are attributable to the formula alone.
*/

{{
    config(
        materialized='view',
        tags=['daily', 'revops']
    )
}}

with

licences as (
    select
        licence_id,
        licence_type_label,
        warranty_service_start_date as start_date,
        coalesce(warranty_service_expiration_date, blu_end_date) as end_date,
        recurring_revenue_currency,
        recurring_revenue_amount_source
    from {{ ref('cl_hubspot__licences') }}
    where licence_type_label in (
        'Drone Operating System & Apps', 'LIDAR', 'Total Maintenance Plan',
        'WingtraCare', 'WingtraCare BLU', 'WingtraPilot BLU'
    )
      and not is_excluded_from_arr_workflow
      and recurring_revenue_amount_source is not null
      and warranty_service_start_date is not null
),

fx as (
    select rate_date, valid_until_date, eur_to_usd, chf_to_usd
    from {{ ref('arr_fx_daily_rates') }}
),

converted as (
    select
        l.*,
        case
            when l.recurring_revenue_currency = 'USD' then 1.0
            when l.recurring_revenue_currency = 'EUR' then fx.eur_to_usd
            when l.recurring_revenue_currency = 'CHF' then fx.chf_to_usd
        end as fx_rate_to_usd,
        date_diff(l.end_date, l.start_date, day) as term_days,
        -- Excel DATEDIF(...,"m") + 1: complete months, minus one when the
        -- end day-of-month has not been reached, plus one boundary month.
        date_diff(l.end_date, l.start_date, month)
            - if(extract(day from l.end_date) < extract(day from l.start_date), 1, 0)
            + 1 as term_months_sheet
    from licences l
    left join fx
        on l.recurring_revenue_currency in ('EUR', 'CHF')
        and fx.rate_date <= l.start_date
        and (l.start_date < fx.valid_until_date or fx.valid_until_date is null)
    where l.end_date is not null
      and l.end_date > l.start_date
),

monthly_amounts as (
    select
        *,
        case
            when recurring_revenue_currency in ('USD', 'EUR', 'CHF')
                then recurring_revenue_amount_source * coalesce(fx_rate_to_usd, 1.0) / nullif(term_months_sheet, 0)
            -- Sheet fallback for unknown currency: col T = amount / ROUND(days/30.44), unconverted.
            else recurring_revenue_amount_source / nullif(round(term_days / 30.44), 0)
        end as monthly_rr_sheet_method_usd,
        case
            when recurring_revenue_currency in ('USD', 'EUR', 'CHF')
                then recurring_revenue_amount_source * coalesce(fx_rate_to_usd, 1.0)
            else recurring_revenue_amount_source
        end as amount_usd_for_proration
    from converted
),

month_spine as (
    select month_date
    from unnest(generate_date_array('2020-01-01', '2030-12-01', interval 1 month)) as month_date
)

select
    /* IDS */
    m.licence_id,

    /* DATES */
    s.month_date,

    /* DIMENSIONS */
    m.licence_type_label,

    /* MEASURES */
    if(
        s.month_date between date_trunc(m.start_date, month) and date_trunc(m.end_date, month),
        m.monthly_rr_sheet_method_usd,
        null
    ) as monthly_rr_sheet_method_usd,
    if(
        s.month_date < m.end_date and date_add(s.month_date, interval 1 month) > m.start_date,
        m.amount_usd_for_proration
            * date_diff(
                least(m.end_date, date_add(s.month_date, interval 1 month)),
                greatest(m.start_date, s.month_date),
                day
              )
            / nullif(m.term_days, 0),
        null
    ) as monthly_rr_day_prorated_usd

from monthly_amounts m
join month_spine s
    on s.month_date between date_trunc(m.start_date, month) and date_trunc(m.end_date, month)
