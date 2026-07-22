SELECT

    /*
        Daily currency rates per company. Odoo stores the rate as foreign
        currency units per 1 unit of the company currency (company 1 =
        Wingtra AG = CHF), so converting a foreign amount to CHF means
        DIVIDING by the rate. One row per (currency, company, rate_date).
    */

    /* IDS */
    id as currency_rate_id,
    currency_id,
    company_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    name as rate_date,

    /* METRICS */
    rate

FROM {{ source('odoo', 'res_currency_rate') }}

WHERE _dlt_deleted_at IS NULL
