/*
    Canonical Cloud subscription entity: one row per qualifying Cloud line
    item (deal-based recurring revenue, not a Licence custom object).
    Everything we know about a sold Cloud subscription: deal, SKU, term,
    recognition window, and USD amount (start-date FX). Parallel to
    ol_revops.licences for the deal-based Cloud stream. Fees are not yet
    modelled (recognition dates not stored in HubSpot).
*/

{{
    config(
        materialized='table'
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
    select deal_stage_id, stage_label, pipeline_label from {{ ref('arr_cloud_deal_stages_seed') }}
),

fx as (
    select rate_date, valid_until_date, eur_to_usd, chf_to_usd
    from {{ ref('arr_fx_daily_rates') }}
)

select
    /* IDS */
    li.line_item_id as cloud_subscription_id,
    d.deal_id,
    d.hubspot_owner_id,

    /* DATES */
    d.cloud_license_start_date as recognition_start_date,
    date_sub(date_add(d.cloud_license_start_date, interval cs.term_years year), interval 1 day) as recognition_end_date,
    d.close_date,
    d.created_at,

    /* DIMENSIONS */
    li.sku,
    cs.term_years,
    d.deal_name,
    st.stage_label as deal_stage_label,
    st.pipeline_label,
    coalesce(li.line_item_currency_code, d.deal_currency_code) as currency,

    /* BOOLEANS */
    li.amount is not null and li.amount > 0 as is_revenue_bearing,
    d.cloud_license_start_date is not null as has_recognition_start,

    /* MEASURES */
    li.quantity,
    li.amount as amount_source,
    case
        when coalesce(li.line_item_currency_code, d.deal_currency_code) = 'USD' then li.amount
        when coalesce(li.line_item_currency_code, d.deal_currency_code) = 'EUR' then li.amount * fx.eur_to_usd
        when coalesce(li.line_item_currency_code, d.deal_currency_code) = 'CHF' then li.amount * fx.chf_to_usd
    end as amount_usd

from line_items li
join edges e on e.line_item_id = li.line_item_id
join deals d on d.deal_id = e.deal_id
join cloud_skus cs on cs.sku_upper = upper(li.sku)
join cloud_stages st on st.deal_stage_id = d.deal_stage_id
left join fx
    on coalesce(li.line_item_currency_code, d.deal_currency_code) in ('EUR', 'CHF')
    and fx.rate_date <= d.cloud_license_start_date
    and (d.cloud_license_start_date < fx.valid_until_date or fx.valid_until_date is null)
where d.cloud_license_start_date is not null
