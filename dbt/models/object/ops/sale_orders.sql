/*
    Sale order header. One row per sale order across all states (draft /
    sent / sale / cancel). Customer resolves to `ol.organizations` even when
    the raw SO `partner_id` points at a sub-record (delivery / invoice /
    contact) — we walk `parent_partner_id` to the company header.
    Salesperson name resolves via `il.users`.

    Line-contents classification (`has_physical_goods` /
    `is_software_or_service_only`) is derived from the order lines joined to
    `ol.products`: a line is a physical good when the product type is Goods
    and its category path is not a Licences or Service category (some
    software licences are Goods-typed but live in a Licences category, so
    category text must be checked, not just type).

    Shipment KPI math (lead times, 14-day targets, coverage) lives in BL,
    not here. CEE (company_id=8) is filtered in CL.
*/

with customer_resolution as (
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

line_classification as (
    -- Physical-goods vs software/service line counts per order.
    -- Display-only rows (line_section / line_note) and lines without a
    -- product are excluded.
    select
        sol.sale_order_id,
        countif(
            p.product_type = 'Goods'
            and lower(coalesce(p.category_path, '')) not like '%licen%'
            and lower(coalesce(p.category_path, '')) not like '%service%'
        )                                                                            as physical_goods_line_count,
        count(*)                                                                     as product_line_count
    from {{ ref('sale_order_line') }} sol
    left join {{ ref('products') }} p on p.product_id = sol.product_id
    where sol.product_id is not null
      and sol.display_type is null
    group by sol.sale_order_id
)

select

    /* IDS */
    so.sale_order_id,
    cr.organization_id                                                           as customer_organization_id,
    so.company_id,

    /* TIMESTAMPS */
    so.created_at,
    so.ordered_at,

    /* DATES */
    so.cleared_date,
    so.pickup_date,
    so.actual_arrival_date,
    so.expected_shipping_date,
    so.expected_delivery_date,

    /* DIMENSIONS */
    so.sale_order_name,
    so.sale_order_state,
    so.order_type,
    org.organization_name                                                        as customer_name,
    sp.user_name                                                                 as salesperson_name,
    so.shipment_status,
    so.delivery_status,
    so.invoice_status,
    so.destination,
    so.legacy_shipment_ids,
    cur.currency_code                                                            as amount_total_currency,

    /* BOOLEANS */
    so.sale_order_state = 'sale'                                                 as is_confirmed,
    so.sale_order_state = 'cancel'                                               as is_cancelled,
    coalesce(so.legacy_shipment_ids like '%,%', false)                           as is_merged_order,
    coalesce(lc.physical_goods_line_count, 0) > 0                                as has_physical_goods,
    coalesce(lc.product_line_count, 0) > 0
        and coalesce(lc.physical_goods_line_count, 0) = 0                        as is_software_or_service_only,
    coalesce(org.organization_name = 'Wingtra Corp.', false)                     as is_intercompany_customer,

    /* METRICS */
    case
        when so.legacy_shipment_ids is null then 0
        else array_length(split(so.legacy_shipment_ids, ','))
    end                                                                          as legacy_shipment_count,
    so.amount_untaxed,
    so.amount_tax,
    so.amount_total

from {{ ref('sale_order') }}            so
left join customer_resolution           cr     on cr.raw_partner_id       = so.customer_partner_id
left join {{ ref('organizations') }}    org    on org.organization_id     = cr.organization_id
left join {{ ref('users') }}            sp     on sp.user_id              = so.salesperson_user_id
left join {{ ref('res_currency') }}     cur    on cur.currency_id         = so.currency_id
left join line_classification           lc     on lc.sale_order_id        = so.sale_order_id
