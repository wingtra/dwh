/*
    Delivery/transfer object. One row per Odoo stock_picking, enriched with
    its picking-type classification (receipt / delivery / internal transfer
    / dropship / repair). Includes all picking states and all picking
    types — this is the general-purpose picking header; consumers filter
    to `picking_type_code = 'outgoing'` for deliveries specifically, and to
    whichever states matter for their use case (e.g. BL's "unconfirmed
    delivery" definition filters to assigned/draft).
*/

select

    /* IDS */
    sp.picking_id,
    sp.sale_order_id,
    sp.partner_id,
    sp.company_id,
    sp.location_id,
    sp.location_dest_id,
    sp.picking_type_id,
    sp.responsible_user_id,
    sp.carrier_id,
    sp.backorder_id,

    /* TIMESTAMPS */
    sp.created_at,
    sp.updated_at,

    /* DATES */
    sp.scheduled_date,
    sp.date_deadline,
    sp.date_done,

    /* DIMENSIONS */
    sp.picking_name,
    sp.picking_state,
    sp.origin,
    sp.move_type,
    pt.picking_type_code,
    pt.picking_type_name,
    sp.tracking_number,
    sp.carrier_tracking_ref,

    /* BOOLEANS */
    sp.is_locked,
    sp.picking_state = 'done'                                     as is_completed,
    sp.picking_state = 'cancel'                                    as is_cancelled,
    sp.picking_state in ('assigned', 'draft')                      as is_assigned_or_draft,

    /* METRICS */
    sp.carrier_price,
    sp.weight

from {{ ref('stock_picking') }}      sp
left join {{ ref('stock_picking_type') }} pt on pt.picking_type_id = sp.picking_type_id
