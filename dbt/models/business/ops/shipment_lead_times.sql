/*
    Shipment lead-time report (cleared -> pickup) behind the ops lead-time
    dashboard. One row per confirmed customer sale order with a pickup date
    (intercompany Wingtra Corp. orders excluded).

    KPI definition (from Janine Jampen's 2026-06-30 handover): a shipment is
    on target when it is picked up within 14 calendar days of customs
    clearance. The headline number is % of shipments within 14 days.

    Orders without a clearance date stay IN this model so dashboards can
    compute data coverage; `missing_clearance_reason` explains why the date
    is absent. Negative lead times (pickup before clearance, data errors)
    are kept but flagged — exclude them from averages and the on-target
    denominator via `has_valid_lead_time`.

    Bucket trends by pickup week/month, not clearance week: clearance dates
    lag pickups, so clearance-week bucketing makes recent weeks vanish.
*/

select

    /* IDS */
    so.sale_order_id,
    so.customer_organization_id,
    so.company_id,

    /* DATES */
    so.cleared_date,
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
    case
        when so.cleared_date is not null       then null
        when so.is_software_or_service_only    then 'software/service only'
        when so.is_merged_order                then 'merged order (2025 migration)'
        else 'unexplained'
    end                                                                          as missing_clearance_reason,

    /* BOOLEANS */
    so.has_physical_goods,
    so.is_software_or_service_only,
    so.is_merged_order,
    so.cleared_date is not null                                                  as has_cleared_date,
    coalesce(date_diff(so.pickup_date, so.cleared_date, day) >= 0, false)        as has_valid_lead_time,
    coalesce(date_diff(so.pickup_date, so.cleared_date, day) < 0, false)         as is_negative_lead_time,
    coalesce(date_diff(so.pickup_date, so.cleared_date, day) between 0 and 14,
             false)                                                              as is_within_14_days,
    coalesce(date_diff(so.pickup_date, so.cleared_date, day) between 0 and 7,
             false)                                                              as is_within_7_days,

    /* METRICS */
    date_diff(so.pickup_date, so.cleared_date, day)                              as lead_time_days

from {{ ref('sale_orders') }} so
where so.is_confirmed
  and not so.is_intercompany_customer
  and so.pickup_date is not null
