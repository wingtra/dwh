/*
    Organization master. One row per external company we interact with —
    vendors, customers, both, or unflagged (companies we've transacted with
    but Odoo never set a rank flag on).

    Universe:
      - All `res_partner` companies (`is_company = TRUE`).
      - Plus the small set of standalone individuals (`is_company = FALSE
        AND parent_id IS NULL`) that have at least one PO or SO in history
        AND are NOT an internal user — these are sole-trader vendors /
        customers that should be reportable as organizations.

    Role flags (`is_vendor`, `is_customer`) prefer Odoo's rank columns but
    fall back to PO/SO history when rank is unset (the rank-hygiene gap;
    see docs/process-improvements.md).

    Excluded from OL on purpose:
      - Delivery / invoice addresses (`type IN ('delivery','invoice','other')`).
      - Individual contacts at a parent company (those live in `ol.contacts`).
      - Internal-user partner records (those live in `il.users`).
*/

with internal_user_partners as (
    select partner_id from {{ ref('res_users') }} where partner_id is not null
),

po_partners as (
    select distinct vendor_partner_id as partner_id
    from {{ ref('purchase_order') }}
    where vendor_partner_id is not null
),

so_partners as (
    -- Walk parent_id once so a sub-record's parent counts as a customer too.
    select distinct coalesce(rp.parent_partner_id, so.partner_id) as partner_id
    from {{ source('odoo', 'sale_order') }} so
    join {{ ref('res_partner') }} rp on rp.partner_id = so.partner_id
    where so.partner_id is not null
),

candidates as (
    select rp.partner_id
    from {{ ref('res_partner') }} rp
    where rp.is_company = true
       or (
            rp.is_company = false
            and rp.parent_partner_id is null
            and rp.partner_id not in (select partner_id from internal_user_partners)
            and (
                rp.partner_id in (select partner_id from po_partners)
                or rp.partner_id in (select partner_id from so_partners)
            )
       )
)

select

    /* IDS */
    rp.partner_id                                                                as organization_id,
    rp.country_id,

    /* DATES */
    rp.created_at,
    rp.updated_at,

    /* DIMENSIONS */
    rp.partner_name                                                              as organization_name,
    rp.vat,

    /* BOOLEANS */
    rp.is_active,
    rp.is_company,
    coalesce(rp.supplier_rank > 0, false)
        or rp.partner_id in (select partner_id from po_partners)                 as is_vendor,
    coalesce(rp.customer_rank > 0, false)
        or rp.partner_id in (select partner_id from so_partners)                 as is_customer

from {{ ref('res_partner') }} rp
join candidates c on c.partner_id = rp.partner_id
