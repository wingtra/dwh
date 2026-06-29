SELECT

    /*
        Stock moves represent every planned or executed inventory movement
        between two locations, including purchase receipts, deliveries,
        manufacturing consumption/production, scraps, and internal transfers.
    */

    /* IDS */
    id as stock_move_id,
    product_id,
    product_uom as product_uom_id,
    company_id,
    location_id,
    location_dest_id,
    location_final_id,
    partner_id,
    picking_id,
    picking_type_id,
    warehouse_id,
    group_id,
    rule_id,
    purchase_line_id,
    sale_line_id,
    bom_line_id,
    workorder_id,
    operation_id,
    production_id,
    raw_material_production_id,
    created_production_id,
    unbuild_id,
    consume_unbuild_id,
    byproduct_id,
    scrap_id,
    repair_id,
    orderpoint_id,
    package_level_id,
    product_packaging_id,
    origin_returned_move_id,
    order_finished_lot_id,
    restrict_partner_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    date,
    date_deadline,
    date_done,
    delay_alert_date,
    reservation_date,

    /* DIMENSIONS */
    name as move_name,
    reference,
    origin,
    description_picking as picking_description,
    sequence,
    priority,
    state as move_state,
    procure_method,
    order_type,
    repair_line_type,
    scrapped as is_scrapped,
    is_inventory,
    is_done,
    is_subcontract,
    additional as is_additional,
    propagate_cancel as should_propagate_cancel,
    to_refund as should_refund,
    picked as is_picked,
    manual_consumption as is_manual_consumption,
    next_serial,

    /* METRICS */
    product_qty,
    product_uom_qty,
    quantity,
    price_unit,
    weight,
    unit_factor,
    cost_share,
    next_serial_count

FROM {{ source('odoo', 'stock_move') }}

-- Filter out CEE (company_id=8) per project policy.
WHERE _dlt_deleted_at IS NULL
  AND (company_id IS NULL OR company_id != 8)
