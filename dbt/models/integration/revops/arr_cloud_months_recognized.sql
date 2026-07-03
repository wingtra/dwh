/*
    Cloud recognized recurring revenue per line item and calendar month,
    both methods (sheet + day-prorated), mirroring arr_licence_months_recognized
    but for the deal-based Cloud stream.

    Cloud is not a Licence custom object; it lives as deals + line items.
    Recognition window: start = deal cloud_license_start_date (stored); end =
    start + term_years (from SKU) minus 1 day (the sheet/report convention,
    e.g. 2024-06-01 -> 2025-05-31). Amount = line-item net amount in the line
    currency, converted to USD at the start-date FX rate.

    Inclusion mirrors the "[ACCRUALS] CLOUD" report: cloud SKU allowlist,
    deal stage in the report's stage set, and a non-null cloud start date
    (required to recognize). Free/zero-amount SKUs contribute nothing.
*/

{{
    config(
        materialized='view',
        tags=['daily', 'hubspot', 'revops']
    )
}}

with

deals as (
    select * from {{ ref('cl_hubspot__deals') }}
),

line_items as (
    select * from {{ ref('cl_hubspot__line_items') }}
),

edges as (
    select from_object_id as deal_id, to_object_id as line_item_id
    from {{ source('hubspot', 'association_edges') }}
    where from_object_type = 'deals' and to_object_type = 'line_items'
      and _dlt_deleted_at is null
),

cloud_skus as (
    select upper(sku) as sku_upper, term_years from {{ ref('arr_cloud_skus_seed') }}
),

cloud_stages as (
    select deal_stage_id from {{ ref('arr_cloud_deal_stages_seed') }}
),

fx as (
    select rate_date, valid_until_date, eur_to_usd, chf_to_usd
    from {{ ref('arr_fx_daily_rates') }}
),

qualifying as (
    select
        li.line_item_id,
        d.deal_id,
        li.sku,
        cs.term_years,
        d.cloud_license_start_date as start_date,
        date_sub(date_add(d.cloud_license_start_date, interval cs.term_years year), interval 1 day) as end_date,
        coalesce(li.line_item_currency_code, d.deal_currency_code) as currency,
        li.amount as amount_source
    from line_items li
    join edges e on e.line_item_id = li.line_item_id
    join deals d on d.deal_id = e.deal_id
    join cloud_skus cs on cs.sku_upper = upper(li.sku)
    join cloud_stages st on st.deal_stage_id = d.deal_stage_id
    where d.cloud_license_start_date is not null
      and li.amount is not null and li.amount > 0
),

converted as (
    select
        q.*,
        case
            when q.currency = 'USD' then 1.0
            when q.currency = 'EUR' then fx.eur_to_usd
            when q.currency = 'CHF' then fx.chf_to_usd
        end as fx_rate_to_usd,
        date_diff(q.end_date, q.start_date, day) as term_days,
        date_diff(q.end_date, q.start_date, month)
            - if(extract(day from q.end_date) < extract(day from q.start_date), 1, 0)
            + 1 as term_months_sheet
    from qualifying q
    left join fx
        on q.currency in ('EUR', 'CHF')
        and fx.rate_date <= q.start_date
        and (q.start_date < fx.valid_until_date or fx.valid_until_date is null)
    where q.end_date > q.start_date
),

amounts as (
    select
        *,
        amount_source * coalesce(fx_rate_to_usd, 1.0) as amount_usd
    from converted
),

month_spine as (
    select month_date
    from unnest(generate_date_array('2020-01-01', '2030-12-01', interval 1 month)) as month_date
)

select
    /* IDS */
    m.line_item_id,

    /* DATES */
    s.month_date,

    /* DIMENSIONS */
    'Cloud' as licence_type_label,

    /* MEASURES */
    m.amount_usd / nullif(m.term_months_sheet, 0) as monthly_rr_sheet_method_usd,
    if(
        s.month_date < m.end_date and date_add(s.month_date, interval 1 month) > m.start_date,
        m.amount_usd
            * date_diff(
                least(m.end_date, date_add(s.month_date, interval 1 month)),
                greatest(m.start_date, s.month_date),
                day
              )
            / nullif(m.term_days, 0),
        null
    ) as monthly_rr_day_prorated_usd

from amounts m
join month_spine s
    on s.month_date between date_trunc(m.start_date, month) and date_trunc(m.end_date, month)
