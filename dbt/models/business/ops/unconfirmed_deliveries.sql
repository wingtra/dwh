/*
    Unconfirmed-delivery report. One row per outgoing delivery line item on
    a sale order that is commercially closed (per HubSpot) but still has an
    open Odoo delivery. Behind the ops dashboard that lists these for
    cleanup in Odoo. Scope: Wingtra AG only (company_id=1, excludes the
    Wingtra Corp. intercompany entity and the defunct CEE entity).

    Definitions (Marco Schicker's 2026-07-20 handover, "Unconfirmed
    Deliveries on Closed Orders"):
      - "Shipped or cancelled" order = HubSpot shipment status
        (`shipment_status_hubspot`), not Odoo's own status — the two can
        diverge and that divergence is the whole point of this report.
        Shipped: LIKE 'shipped%'. Cancelled: LIKE 'canceled%'
        ('Canceled (will not happen)').
      - "Unconfirmed" delivery = outgoing stock_picking in state `assigned`
        or `draft`. Odoo picking lifecycle: draft -> waiting -> confirmed
        -> assigned (ready) -> done -> cancel. `confirmed`/`waiting` are
        NOT counted as unconfirmed here even though colloquially
        "confirmed" sounds like the opposite.
      - Line quantity/amount uses the delivery's own move quantity
        (`stock_movements`, dest leg of `move_type = 'delivery'`), not the
        SO line's total ordered quantity — a line can span several partial
        deliveries/backorders.

    Known data-quality issue: some sale_order_line rows carry a discount
    far outside 0-100 (seen on duplicate "(copy)" products, e.g.
    RESEPI-PCMASTERPPK-1YREXPO LiDAR (license) (copy)), which combined with
    price_unit produces a wildly negative line amount even when price_unit
    itself is positive. `is_price_anomaly` flags any line where
    price_unit * (1 - discount/100) is negative, not just negative
    price_unit — the narrower price_unit-only check in the original
    handover SQL missed this case (order S08730, 2026-07-21). Anomalous
    lines are excluded from order-level totals in downstream aggregation,
    not from this model itself, so they stay visible.
*/

with target_orders as (
    select *
    from {{ ref('sale_orders') }}
    where company_id = 1
      and not is_intercompany_customer
      and (
        lower(shipment_status_hubspot) like 'shipped%'
        or lower(shipment_status_hubspot) like 'canceled%'
      )
),

open_deliveries as (
    select *
    from {{ ref('deliveries') }}
    where picking_type_code = 'outgoing'
      and is_assigned_or_draft
),

delivery_lines as (
    -- One row per delivered line: the dest leg is the qty that moved into
    -- the customer location, matching what the original picking's
    -- stock_move.product_uom_qty represented before the OL unpivot.
    select
        picking_id,
        sale_order_line_id,
        product_id,
        quantity_abs as qty_delivered
    from {{ ref('stock_movements') }}
    where leg_role = 'dest'
      and move_type = 'delivery'
)

select

    /* IDS */
    o.sale_order_id,
    o.customer_organization_id,
    d.picking_id,
    dl.sale_order_line_id,

    /* DATES */
    d.scheduled_date,

    /* DIMENSIONS */
    o.sale_order_name,
    o.shipment_status_hubspot,
    o.sale_order_state                                                            as odoo_sale_order_state,
    o.customer_name,
    d.picking_name                                                                as delivery_number,
    d.picking_state                                                               as delivery_state,
    coalesce(sol.product_name, concat('product_id ', cast(dl.product_id as string)))
                                                                                   as item,
    sol.product_code,
    sol.price_currency                                                            as currency,

    /* BOOLEANS */
    coalesce(sol.price_unit, 0) * (1 - coalesce(sol.discount_percent, 0) / 100) < 0
                                                                                   as is_price_anomaly,

    /* METRICS */
    dl.qty_delivered,
    sol.price_unit,
    sol.discount_percent,
    round(
        dl.qty_delivered * coalesce(sol.price_unit, 0)
        * (1 - coalesce(sol.discount_percent, 0) / 100), 2
    )                                                                              as amount_excl_tax

from target_orders                             o
join open_deliveries                           d      on d.sale_order_id        = o.sale_order_id
join delivery_lines                            dl     on dl.picking_id          = d.picking_id
left join {{ ref('sale_order_lines') }}        sol    on sol.sale_order_line_id = dl.sale_order_line_id
