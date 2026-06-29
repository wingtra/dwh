SELECT

    /*
        Wingtra custom expert master. One row per product expert (the people
        named in `product_template.expert_id`). Distinct from `res_users` —
        these are subject-matter experts attached to products, not Odoo users.
    */

    /* IDS */
    id as expert_id,

    /* TIMESTAMPS */
    date as created_at,

    /* DIMENSIONS */
    name as expert_name,
    active as is_active,
    access_token,

    /* METADATA */
    _dlt_load_id as dlt_load_id,
    _dlt_id as dlt_id

FROM {{ source('odoo', 'wt_product_expert') }}

WHERE _dlt_deleted_at IS NULL
