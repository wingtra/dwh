SELECT

    /*
        Partners cover customers, vendors, contacts, and internal user
        partners. supplier_rank / customer_rank > 0 flag vendors / customers.
        Note: name is a plain STRING column on res_partner (not JSON).
    */

    /* IDS */
    id as partner_id,
    parent_id as parent_partner_id,
    commercial_partner_id,
    company_id,
    user_id as salesperson_user_id,
    state_id,
    country_id,
    industry_id,
    title,
    buyer_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    name as partner_name,
    complete_name as partner_full_name,
    company_name,
    commercial_company_name,
    ref as partner_reference,
    is_company,
    employee as is_employee,
    active as is_active,
    partner_share as is_partner_share,
    type as address_type,
    function as job_position,
    lang,
    tz,
    vat,
    email,
    email_normalized,
    phone,
    phone_sanitized,
    mobile,
    website,
    street,
    street2,
    street3,
    zip,
    city,
    color,
    comment,

    /* METRICS */
    supplier_rank,
    customer_rank

FROM {{ source('odoo', 'res_partner') }}
