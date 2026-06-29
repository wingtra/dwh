SELECT

    /* 
        Stock quants represent the current on-hand inventory quantity
        for a product at a specific location, lot, package, and owner.
    */

    /* IDS */
    id as stock_quant_id,
    product_id,
    company_id,
    location_id,
    lot_id,
    package_id,
    owner_id,
    user_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,
    revision_id,
    storage_category_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    in_date,
    inventory_date,
    accounting_date,

    /* DIMENSIONS */
    inventory_quantity_set as is_inventory_quantity_set,

    /* METRICS */
    quantity,
    reserved_quantity,
    inventory_quantity,
    inventory_diff_quantity

FROM {{ source('odoo', 'stock_quant') }}

-- Filter out CEE (company_id=8) per project policy.
WHERE company_id IS NULL OR company_id != 8
