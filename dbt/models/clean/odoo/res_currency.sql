SELECT

    /*
        Currencies referenced by orders and pricelists. `name` holds the
        ISO 4217 code (e.g. CHF, EUR, USD), renamed to currency_code.
    */

    /* IDS */
    id as currency_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    name as currency_code,
    full_name as currency_name,
    symbol as currency_symbol,
    iso_numeric as iso_numeric_code,
    decimal_places,
    active as is_active

FROM {{ source('odoo', 'res_currency') }}

WHERE _dlt_deleted_at IS NULL
