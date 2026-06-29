/*
    Purchase order header. One row per PO across all states (draft / sent /
    to approve / purchase / done / cancel). Vendor resolves to `ol.organizations`
    even when the raw PO `partner_id` points at a sub-record (delivery /
    invoice / contact) — we walk `parent_partner_id` to the company header.
    Buyer name resolves via `il.users`.
    `is_open` is derived from line-level receipt progress.
*/

with vendor_resolution as (
    -- Map every res_partner.id to its organization_id (company-header).
    -- Companies map to themselves; sub-records map to their parent.
    select
        rp.partner_id                                                                as raw_partner_id,
        case
            when rp.is_company                       then rp.partner_id
            when rp.parent_partner_id is not null    then rp.parent_partner_id
            else rp.partner_id
        end                                                                          as organization_id
    from {{ ref('res_partner') }} rp
),

po_has_open_line as (
    select
        purchase_order_id,
        countif(product_qty > coalesce(qty_received, 0)) > 0 as has_open_line
    from {{ ref('purchase_order_line') }}
    group by purchase_order_id
)

select

    /* IDS */
    po.purchase_order_id,
    vr.organization_id                                                           as vendor_organization_id,
    po.company_id,

    /* DATES */
    po.created_at,
    po.date_order                                                                as order_date,
    po.date_approve                                                              as approve_date,
    po.date_planned                                                              as planned_date,
    po.effective_date,

    /* DIMENSIONS */
    po.purchase_order_name,
    po.purchase_order_state,
    po.delivery_status,
    po.receipt_status,
    po.invoice_status,
    org.organization_name                                                        as vendor_name,
    buyer.user_name                                                              as buyer_name,
    cast('CHF' as string)                                                        as amount_total_currency,

    /* BOOLEANS */
    coalesce(plo.has_open_line, false)
        and po.purchase_order_state in ('purchase', 'done')                      as is_open,
    po.purchase_order_state = 'cancel'                                           as is_cancelled,

    /* METRICS */
    po.amount_untaxed,
    po.amount_tax,
    po.amount_total,
    po.invoice_count

from {{ ref('purchase_order') }}        po
left join vendor_resolution             vr     on vr.raw_partner_id       = po.vendor_partner_id
left join {{ ref('organizations') }}    org    on org.organization_id     = vr.organization_id
left join {{ ref('users') }}            buyer  on buyer.user_id           = po.buyer_user_id
left join po_has_open_line              plo    on plo.purchase_order_id   = po.purchase_order_id
