SELECT

    /*
        Stock locations define Odoo's inventory location hierarchy,
        including internal, supplier, customer, transit, and virtual locations.
    */

    /* IDS */
    id as location_id,
    location_id as parent_location_id,
    company_id,
    removal_strategy_id,
    storage_category_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,
    valuation_in_account_id,
    valuation_out_account_id,
    warehouse_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    last_inventory_date,
    next_inventory_date,

    /* DIMENSIONS */
    name as location_name,
    complete_name as location_full_path,
    active as is_active,
    usage as location_usage,
    comment,
    parent_path,
    scrap_location as is_scrap_location,
    barcode,
    allow_negative_stock as allows_negative_stock,
    exclude_from_quantity as is_excluded_from_quantity,
    auto_unpack as should_auto_unpack,
    replenish_location as is_replenish_location,
    is_subcontracting_location,

    /* METRICS */
    posx as position_x,
    posy as position_y,
    posz as position_z,
    cyclic_inventory_frequency

FROM {{ source('odoo', 'stock_location') }}
