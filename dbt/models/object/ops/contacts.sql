/*
    People attached to an organization — the buyer at a customer, the sales
    rep at a vendor, the engineer we email. One row per individual contact.
    FK back to `ol.organizations` so "who do I contact at customer X" is a
    single join.

    Universe: `res_partner` rows where `is_company = FALSE`, `parent_partner_id`
    is set, and `address_type = 'contact'`. Delivery / invoice / other
    address rows are excluded — those aren't contacts, they're routing.
*/

select

    /* IDS */
    rp.partner_id                           as contact_id,
    rp.parent_partner_id                    as organization_id,

    /* DATES */
    rp.created_at,
    rp.updated_at,

    /* DIMENSIONS */
    rp.partner_name                         as contact_name,
    rp.job_position,
    rp.email,
    rp.phone,
    rp.mobile,

    /* BOOLEANS */
    rp.is_active

from {{ ref('res_partner') }} rp
join {{ ref('organizations') }} o on o.organization_id = rp.parent_partner_id
where rp.is_company = false
  and rp.address_type = 'contact'
