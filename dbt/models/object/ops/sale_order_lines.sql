/*
    Sale order line. One row per SO product line across all SO states.
    Display-only lines (line_section, line_note) are excluded — they carry
    no product and no quantity. Customer resolves to `ol.organizations`
    (walking parent_partner_id when the SO's raw partner_id points at a
    sub-record). Header info (SO name, state, order date, order type) and
    product info (code, name, category path) are denormalized so most
    line-level questions don't need a header or product join.

    `is_physical_good` marks lines that physically ship: product type Goods
    and category path not Licences/Service (some software licences are
    Goods-typed but live in a Licences category).
*/

with product_lines as (
    select *
    from {{ ref('sale_order_line') }}
    where display_type is null  -- exclude line_section and line_note rows
),

customer_resolution as (
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
    sol.sale_order_line_id,
    sol.sale_order_id,
    sol.product_id,
    cr.organization_id                                                           as customer_organization_id,
    sol.company_id,

    /* TIMESTAMPS */
    sol.created_at,
    sol.ordered_at,

    /* DIMENSIONS */
    so.sale_order_name,
    so.sale_order_state,
    so.order_type,
    org.organization_name                                                        as customer_name,
    p.product_code,
    p.product_name,
    p.category_path                                                              as product_category_path,
    sol.line_description,
    cur.currency_code                                                            as price_currency,

    /* BOOLEANS */
    coalesce(sol.is_downpayment, false)                                          as is_downpayment,
    coalesce(sol.is_delivery, false)                                             as is_delivery,
    coalesce(
        p.product_type = 'Goods'
        and lower(coalesce(p.category_path, '')) not like '%licen%'
        and lower(coalesce(p.category_path, '')) not like '%service%',
        false
    )                                                                            as is_physical_good,

    /* METRICS */
    sol.qty_ordered,
    sol.qty_delivered,
    sol.qty_invoiced,
    sol.price_unit,
    sol.discount_percent,
    sol.price_subtotal,
    sol.price_total

from product_lines                      sol
join {{ ref('sale_order') }}            so     on so.sale_order_id        = sol.sale_order_id
left join customer_resolution           cr     on cr.raw_partner_id       = sol.customer_partner_id
left join {{ ref('organizations') }}    org    on org.organization_id     = cr.organization_id
left join {{ ref('products') }}         p      on p.product_id            = sol.product_id
left join {{ ref('res_currency') }}     cur    on cur.currency_id         = sol.currency_id
