/*
    Purchase order line. One row per PO product line across all PO states.
    Display-only lines (line_section, line_note) are excluded — they carry
    no product and no procurement quantity. Vendor resolves to
    `ol.organizations` (walking parent_partner_id when the PO's raw
    partner_id points at a sub-record). Header info (PO name, state, order
    date) and product info (code, name) are denormalized so most line-level
    questions don't need a header or product join. `is_open` is per-line.
*/

with product_lines as (
    select *
    from {{ ref('purchase_order_line') }}
    where display_type is null  -- exclude line_section and line_note rows
),

vendor_resolution as (
    select
        rp.partner_id                                                                as raw_partner_id,
        case
            when rp.is_company                       then rp.partner_id
            when rp.parent_partner_id is not null    then rp.parent_partner_id
            else rp.partner_id
        end                                                                          as organization_id
    from {{ ref('res_partner') }} rp
)

select

    /* IDS */
    pol.purchase_order_line_id,
    pol.purchase_order_id,
    pol.product_id,
    vr.organization_id                                                           as vendor_organization_id,
    pol.company_id,

    /* DATES */
    pol.created_at,
    po.date_order                                                                as order_date,
    pol.date_planned                                                             as line_planned_date,

    /* DIMENSIONS */
    po.purchase_order_name,
    po.purchase_order_state,
    pol.purchase_order_line_state,
    po.delivery_status,
    org.organization_name                                                        as vendor_name,
    buyer.user_name                                                              as buyer_name,
    pp.product_code,
    pp.product_name,
    pol.line_description,
    cast('CHF' as string)                                                        as price_currency,

    /* BOOLEANS */
    /*
        is_open: per Jan 2026-06-08, only RFQ Sent (`sent`) and Purchase
        Order (`purchase`) states count toward expected-arrival figures.
        Excludes draft, to approve, done, cancel.
    */
    po.purchase_order_state in ('sent', 'purchase')
        and pol.product_qty > coalesce(pol.qty_received, 0)                      as is_open,

    /* METRICS */
    pol.product_qty,
    pol.qty_received,
    pol.product_qty - coalesce(pol.qty_received, 0)                              as qty_remaining,
    pol.price_unit,
    pol.price_total

from product_lines                      pol
join {{ ref('purchase_order') }}        po     on po.purchase_order_id    = pol.purchase_order_id
left join vendor_resolution             vr     on vr.raw_partner_id       = pol.vendor_partner_id
left join {{ ref('organizations') }}    org    on org.organization_id     = vr.organization_id
left join {{ ref('users') }}            buyer  on buyer.user_id           = po.buyer_user_id
left join {{ ref('products') }}         pp     on pp.product_id           = pol.product_id
