SELECT

    /*
        Stock pickings (a.k.a. transfers) are the delivery/receipt/internal-
        transfer header record that groups one or more stock_move lines.
        `picking_type_id` (joined via stock_picking_type) determines whether
        a picking is a receipt, delivery, or internal transfer.

        Note: the raw table also carries `shipment_status_hubspot`, but the
        canonical copy of that field lives on sale_order (that's the one
        HubSpot syncs authoritatively and the one ops uses for "shipped/
        cancelled" reporting) — not duplicated here to avoid two
        divergent sources of truth in OL/BL.
    */

    /* IDS */
    id as picking_id,
    backorder_id,
    group_id,
    location_id,
    location_dest_id,
    picking_type_id,
    partner_id,
    company_id,
    user_id as responsible_user_id,
    owner_id,
    sale_id as sale_order_id,
    carrier_id,
    return_id,
    batch_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    scheduled_date,
    date_deadline,
    date as move_date,
    date_done,

    /* DIMENSIONS */
    name as picking_name,
    origin,
    note,
    move_type,
    state as picking_state,
    priority,
    carrier_tracking_ref,
    tracking_number,
    shipment_id,
    order_type,
    batch_sequence,

    /* BOOLEANS */
    has_deadline_issue,
    printed as is_printed,
    is_locked,

    /* METRICS */
    carrier_price,
    weight

FROM {{ source('odoo', 'stock_picking') }}

-- Filter out CEE (company_id=8) per project policy.
WHERE _dlt_deleted_at IS NULL
  AND (company_id IS NULL OR company_id != 8)
