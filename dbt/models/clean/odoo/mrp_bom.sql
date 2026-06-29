SELECT

    /*
        Manufacturing Bill of Materials header. One row per BOM,
        linked to a product template (and optionally a specific variant).
        BOM type distinguishes normal manufacturing from kits / subcontracting.
    */

    /* IDS */
    id as bom_id,
    product_tmpl_id as product_template_id,
    product_id,
    product_uom_id,
    picking_type_id,
    company_id,
    revision_line_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    code as bom_code,
    type as bom_type,
    active as is_active,
    sequence,
    ready_to_produce,
    consumption,
    revised_product as is_revised_product,
    batch_manufacturing_in_workorders as uses_batch_manufacturing_in_workorders,
    allow_operation_dependencies as allows_operation_dependencies,

    /* METRICS */
    product_qty,
    produce_delay,
    days_to_prepare_mo

FROM {{ source('odoo', 'mrp_bom') }}
