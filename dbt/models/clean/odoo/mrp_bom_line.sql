SELECT

    /*
        Manufacturing BOM lines: components consumed to produce one unit
        of the parent BOM's product. Linked to product variants, and
        optionally to a routing operation.
    */

    /* IDS */
    id as bom_line_id,
    bom_id,
    product_id,
    product_tmpl_id as product_template_id,
    product_uom_id,
    operation_id,
    company_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    sequence,
    manual_consumption as is_manual_consumption,

    /* METRICS */
    product_qty,
    cost_share

FROM {{ source('odoo', 'mrp_bom_line') }}

WHERE _dlt_deleted_at IS NULL
