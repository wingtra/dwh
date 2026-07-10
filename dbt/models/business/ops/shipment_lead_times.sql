/*
    Shipment lead-time report (cleared -> pickup) behind the ops lead-time
    dashboard. One row per confirmed customer sale order with a pickup date
    (intercompany Wingtra Corp. orders excluded).

    KPI definition (from Janine Jampen's 2026-06-30 handover, updated in the
    2026-07-07 review): a shipment is on target when it is picked up within
    14 calendar days of customs clearance. The headline number is % of
    shipments within 14 days.

    Software/service-only orders (licences, cloud subscriptions, tariff
    surcharges, service-level packages) are EXCLUDED: they never physically
    ship, so they are not shipments (2026-07-07 review decision).

    Merged sale orders (several open shipments combined into one new SO
    during the 2025 migration; the originals were cancelled) usually lost
    their clearance date. We recover it from the cancelled source orders
    matched via `legacy_shipment_ids`: cleared_date = earliest source
    clearance, i.e. the lead time is driven by the goods that waited
    longest (2026-07-07 review decision, pending Janine's confirmation).
    `merged_source_sale_orders` lists the source SOs for traceability.

    Orders without a clearance date stay IN this model so dashboards can
    compute data coverage; `missing_clearance_reason` explains why the date
    is absent. Negative lead times (pickup before clearance, data errors)
    are kept but flagged — exclude them from averages and the on-target
    denominator via `has_valid_lead_time`.

    Bucket trends by pickup week/month, not clearance week: clearance dates
    lag pickups, so clearance-week bucketing makes recent weeks vanish.
*/

with merged_order_sources as (
    -- Resolve each merged order's legacy shipment ids to the original
    -- (cancelled) sale orders they came from. One legacy id can match
    -- several cancelled rows with identical dates (migration duplicates);
    -- MIN / distinct STRING_AGG absorb those.
    select
        merged.sale_order_id,
        min(src.cleared_date)                                                    as recovered_cleared_date,
        string_agg(distinct src.sale_order_name, ', ' order by src.sale_order_name)
                                                                                 as merged_source_sale_orders
    from {{ ref('sale_orders') }} merged
    cross join unnest(split(merged.legacy_shipment_ids, ',')) as legacy_id
    inner join {{ ref('sale_orders') }} src
        on  src.legacy_shipment_ids = trim(legacy_id)
        and src.sale_order_id      != merged.sale_order_id
        and src.is_cancelled
    where merged.is_merged_order
      and merged.is_confirmed
    group by merged.sale_order_id
),

shipments as (
    select
        so.*,
        mos.merged_source_sale_orders,
        coalesce(so.cleared_date, mos.recovered_cleared_date)                    as effective_cleared_date,
        so.cleared_date is null
            and mos.recovered_cleared_date is not null                           as is_cleared_date_recovered
    from {{ ref('sale_orders') }} so
    left join merged_order_sources mos on mos.sale_order_id = so.sale_order_id
    where so.is_confirmed
      and not so.is_intercompany_customer
      and not so.is_software_or_service_only
      and so.pickup_date is not null
)

select

    /* IDS */
    so.sale_order_id,
    so.customer_organization_id,
    so.company_id,

    /* DATES */
    so.effective_cleared_date                                                    as cleared_date,
    so.pickup_date,
    date_trunc(so.pickup_date, week(monday))                                     as pickup_week,
    date_trunc(so.pickup_date, month)                                            as pickup_month,
    extract(year from so.pickup_date)                                            as pickup_year,

    /* DIMENSIONS */
    so.sale_order_name,
    so.order_type,
    so.customer_name,
    case so.company_id
        when 1 then 'Wingtra AG'
        when 9 then 'Wingtra Corp.'
        else cast(so.company_id as string)
    end                                                                          as selling_entity,
    so.destination,
    so.legacy_shipment_ids,
    so.merged_source_sale_orders,
    case
        when so.effective_cleared_date is not null    then null
        when so.is_merged_order                       then 'merged order — sources not recoverable'
        else 'unexplained'
    end                                                                          as missing_clearance_reason,

    /* BOOLEANS */
    so.has_physical_goods,
    so.is_merged_order,
    so.is_cleared_date_recovered,
    so.effective_cleared_date is not null                                        as has_cleared_date,
    coalesce(date_diff(so.pickup_date, so.effective_cleared_date, day) >= 0,
             false)                                                              as has_valid_lead_time,
    coalesce(date_diff(so.pickup_date, so.effective_cleared_date, day) < 0,
             false)                                                              as is_negative_lead_time,
    coalesce(date_diff(so.pickup_date, so.effective_cleared_date, day)
             between 0 and 14, false)                                            as is_within_14_days,
    coalesce(date_diff(so.pickup_date, so.effective_cleared_date, day)
             between 0 and 7, false)                                             as is_within_7_days,

    /* METRICS */
    date_diff(so.pickup_date, so.effective_cleared_date, day)                    as lead_time_days

from shipments so
