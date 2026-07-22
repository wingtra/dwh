SELECT

    /*
        Picking types classify a stock_picking as incoming (receipt),
        outgoing (delivery), or internal transfer via `code`.
    */

    /* IDS */
    id as picking_type_id,
    sequence_id,
    default_location_src_id,
    default_location_dest_id,
    return_picking_type_id,
    warehouse_id,
    company_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    coalesce(json_value(name, '$.en_GB'), json_value(name, '$.en_US')) as picking_type_name,
    code as picking_type_code,
    sequence,
    sequence_code,
    barcode,

    /* BOOLEANS */
    active as is_active

FROM {{ source('odoo', 'stock_picking_type') }}

-- Filter out CEE (company_id=8) per project policy.
WHERE _dlt_deleted_at IS NULL
  AND company_id != 8
