-- Validation gate: applying the Accruals sheet's own accrual formula to the
-- FROZEN licence rows from the sheet (2026-07-03 snapshot) must reproduce
-- the sheet's matrix for the same snapshot within $1 per month and type.
-- This pins formula correctness independently of live-data drift. If this
-- test fails, the replica logic changed meaning — do not ship.
--
-- The formula is intentionally duplicated from il arr_licence_months_recognized
-- (applied to the frozen seed instead of live CL data); keep the two in sync.

with

baseline_licences as (
    select * from {{ ref('arr_sheet_baseline_licences') }}
    where recurring_revenue_amount_source is not null
      and warranty_service_start_date is not null
      and warranty_service_expiration_date is not null
      and warranty_service_expiration_date > warranty_service_start_date
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
        date_diff(l.warranty_service_expiration_date, l.warranty_service_start_date, day) as term_days,
        date_diff(l.warranty_service_expiration_date, l.warranty_service_start_date, month)
            - if(extract(day from l.warranty_service_expiration_date) < extract(day from l.warranty_service_start_date), 1, 0)
            + 1 as term_months_sheet
    from baseline_licences l
    left join fx
        on l.recurring_revenue_currency in ('EUR', 'CHF')
        and fx.rate_date <= l.warranty_service_start_date
        and (l.warranty_service_start_date < fx.valid_until_date or fx.valid_until_date is null)
),

monthly as (
    select
        *,
        case
            when recurring_revenue_currency in ('USD', 'EUR', 'CHF')
                then recurring_revenue_amount_source * coalesce(fx_rate_to_usd, 1.0) / nullif(term_months_sheet, 0)
            else recurring_revenue_amount_source / nullif(round(term_days / 30.44), 0)
        end as monthly_rr_usd
    from converted
),

replica as (
    select
        month_date,
        m.license_type_label,
        sum(m.monthly_rr_usd) as monthly_rr_replica_usd
    from monthly m
    join unnest(generate_date_array('2020-01-01', '2030-12-01', interval 1 month)) as month_date
        on month_date between date_trunc(m.warranty_service_start_date, month)
        and date_trunc(m.warranty_service_expiration_date, month)
    group by month_date, m.license_type_label
),

compared as (
    select
        b.month_date,
        b.license_type_label,
        b.monthly_recognized_rr_usd as sheet_value,
        coalesce(r.monthly_rr_replica_usd, 0) as replica_value
    from {{ ref('arr_sheet_baseline_matrix') }} b
    left join replica r
        on b.month_date = r.month_date
        and b.license_type_label = r.license_type_label
)

select *
from compared
where abs(replica_value - sheet_value) > 1
