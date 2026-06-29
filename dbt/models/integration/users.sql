/*
    Canonical user resolution. One row per Odoo internal user.
    Joins res_users (login, active) with res_partner (display name, email)
    so consumers can get a user_name in a single join. The display name
    lives on res_partner via res_users.partner_id; res_users itself has
    no name column.
    Private to the warehouse — referenced by other IL/OL models that need
    to surface a user name (responsible, scm, buyer, sales rep, etc.).
*/

select

    /* IDS */
    ru.user_id,
    ru.partner_id,

    /* DIMENSIONS */
    rp.partner_name as user_name,
    ru.login,

    /* BOOLEANS */
    ru.is_active

from {{ ref('res_users') }} ru
left join {{ ref('res_partner') }} rp on rp.partner_id = ru.partner_id
