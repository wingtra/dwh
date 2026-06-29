SELECT

    /*
        Purchase order lines: one row per product on a PO/RFQ. Holds the
        ordered quantity, received/invoiced progress, planned date, and
        pricing used to drive material security and PO-progress KPIs.
    */

    /* IDS */
    id as purchase_order_line_id,
    order_id as purchase_order_id,
    product_id,
    product_uom as product_uom_id,
    product_packaging_id,
    partner_id as vendor_partner_id,
    currency_id,
    company_id,
    location_dest_id,
    location_final_id,
    picking_type_id,
    sale_order_id,
    sale_line_id,
    orderpoint_id,
    group_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    date_planned,

    /* DIMENSIONS */
    name as line_description,
    sequence,
    state as purchase_order_line_state,
    display_type,
    qty_received_method,
    product_description_variants,
    propagate_cancel as should_propagate_cancel,
    is_downpayment,
    analytic_distribution as analytic_distribution_raw,

    /* METRICS */
    product_qty,
    product_uom_qty,
    qty_received,
    qty_received_manual,
    qty_invoiced,
    qty_to_invoice,
    product_packaging_qty,
    price_unit,
    price_subtotal,
    price_tax,
    price_total,
    price_total_cc,
    discount

FROM {{ source('odoo', 'purchase_order_line') }}

-- Filter out CEE (company_id=8) per project policy.
WHERE _dlt_deleted_at IS NULL
  AND (company_id IS NULL OR company_id != 8)
