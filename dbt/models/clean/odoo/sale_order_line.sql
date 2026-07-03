SELECT

    /*
        Sale order lines. One row per line, including display-only rows
        (display_type = line_section / line_note) which carry no product;
        downstream layers filter those out.
    */

    /* IDS */
    id as sale_order_line_id,
    order_id as sale_order_id,
    product_id,
    product_uom as uom_id,
    currency_id,
    company_id,
    order_partner_id as customer_partner_id,
    salesman_id as salesperson_user_id,
    warehouse_id,
    linked_line_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,
    date_order as ordered_at,

    /* DIMENSIONS */
    name as line_description,
    display_type,
    state as sale_order_line_state,
    invoice_status,
    qty_delivered_method,
    order_type,
    hs_code,

    /* BOOLEANS */
    is_expense,
    is_downpayment,
    is_delivery,

    /* METRICS */
    product_uom_qty as qty_ordered,
    qty_delivered,
    qty_invoiced,
    qty_to_invoice,
    price_unit,
    discount as discount_percent,
    price_subtotal,
    price_tax,
    price_total,
    untaxed_amount_invoiced,
    untaxed_amount_to_invoice

FROM {{ source('odoo', 'sale_order_line') }}

-- Filter out CEE (company_id=8) per project policy, matching sale_order.
WHERE _dlt_deleted_at IS NULL
  AND (company_id IS NULL OR company_id != 8)
