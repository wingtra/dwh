SELECT

    /*
        Product supplier info maps products to their vendors (partners),
        with the vendor-specific reference, MOQ, price, and lead time used
        for purchase planning and primary-supplier lookups.
    */

    /* IDS */
    id as product_supplierinfo_id,
    product_tmpl_id as product_template_id,
    product_id,
    partner_id,
    company_id,
    currency_id,
    purchase_requisition_line_id,
    origin_country_id,
    pref_origin_country_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    date_start,
    date_end,

    /* DIMENSIONS */
    sequence,
    product_code as supplier_product_code,
    product_name as supplier_product_name,
    treaty,
    vendor_product_url,
    pref_origin_type,
    preferential_origin as is_preferential_origin,
    vendor_priority,

    /* METRICS */
    min_qty as min_order_qty,
    price,
    discount,
    delay as lead_time_days

FROM {{ source('odoo', 'product_supplierinfo') }}

WHERE _dlt_deleted_at IS NULL
