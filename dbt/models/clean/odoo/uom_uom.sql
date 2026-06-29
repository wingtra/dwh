SELECT

    /*
        Units of measure define how product quantities are expressed,
        including unit names, conversion factors, rounding, and UoM type.
    */

    /* IDS */
    id as uom_id,
    category_id as uom_category_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    name as uom_name_raw,
    json_value(name, '$.en_GB') as uom_name,
    json_value(name, '$.en_US') as uom_name_en_us,
    active as is_active,
    uom_type,
    fedex_code,

    /* METRICS */
    factor,
    rounding
    
FROM {{ source('odoo', 'uom_uom') }}

WHERE _dlt_deleted_at IS NULL
