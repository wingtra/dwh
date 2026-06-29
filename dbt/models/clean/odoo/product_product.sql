SELECT

    /*
        Product variants contain the sellable/stockable SKU-level records,
        including internal references, barcodes, and company-specific costs.
        Wingtra carries one variant per template (1-1), so this layer keeps
        all variants. CEE (company_id=8) scoping happens on product_template,
        and the OL product object joins template+variant, so CEE rows drop
        out downstream without filtering here.
    */

    /* IDS */
    id as product_id,
    product_tmpl_id as product_template_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,
    intrastat_code_id,
    intrastat_origin_country_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    default_code as product_code,
    active as is_active,
    barcode,
    combination_indices,
    can_image_variant_1024_be_zoomed as can_variant_image_be_zoomed,
    lot_properties_definition as lot_properties_definition_raw,
    standard_price as standard_price_raw,

    /* METRICS */
    volume,
    weight,
    intrastat_supplementary_unit_amount,
    safe_cast(json_value(standard_price, '$."1"') as float64) as standard_price_ag

FROM {{ source('odoo', 'product_product') }}

WHERE _dlt_deleted_at IS NULL
