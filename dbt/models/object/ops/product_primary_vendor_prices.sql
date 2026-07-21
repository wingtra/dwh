/*
    Fixed primary-vendor purchase price per product variant, normalised to
    CHF per base unit. One row per product variant that has at least one
    supplierinfo line.

    Primary vendor rule (Jan Skret's BoM cost handover, 2026-07-15):
    vendor_priority = 1 wins, fallback lowest Odoo sequence. The pick is
    FIXED — it never switches to a cheaper non-primary vendor. Note this
    differs from product_dimensions' primary supplier, which ranks by
    sequence only (the two picks diverge on 14 templates as of
    2026-07-15); aligning product_dimensions is a separate decision.

    Price normalisation:
    - discount applied (net price),
    - pricelist prices are per PURCHASE UoM (product_template.purchase_uom_id,
      e.g. 'Roll of 500'), converted to the base UoM via uom factors:
      price * purchase_uom_factor / base_uom_factor,
    - converted to CHF at the LATEST company-1 rate. Odoo stores rates as
      foreign units per 1 CHF, so we divide. Prices with no rate row
      (already CHF) pass through unchanged.

    Supplierinfo lines can sit on the template (product_id NULL, applies
    to all variants) or on one variant; variant-specific lines only apply
    to that variant. Expired lines (date_end in the past) lose against
    valid ones at equal priority/sequence and are flagged, not dropped:
    an expired price is still more information than none.

    Public contract for "what do we pay our fixed vendor per unit"
    queries; bl.bom_material_costs prices BOM rollups with it.
    Grain: one row per product_id.
*/

with

latest_fx as (
    -- latest rate per currency for Wingtra AG (company 1, base CHF)
    select currency_id, rate
    from {{ ref('res_currency_rate') }}
    where company_id = 1
    qualify row_number() over (
        partition by currency_id
        order by rate_date desc
    ) = 1
),

uom_factors as (
    select
        pt.product_template_id,
        base_uom.factor                     as base_uom_factor,
        po_uom.factor                       as purchase_uom_factor,
        po_uom.uom_name_en_us               as purchase_uom_name
    from {{ ref('product_template') }} pt
    left join {{ ref('uom_uom') }} base_uom on base_uom.uom_id = pt.uom_id
    left join {{ ref('uom_uom') }} po_uom   on po_uom.uom_id   = pt.purchase_uom_id
),

primary_pick as (
    select
        coalesce(si.product_id, pp.product_id)              as product_id,
        si.partner_id                                       as vendor_partner_id,
        si.currency_id,
        si.price * (1 - ifnull(si.discount, 0) / 100)       as net_price_purchase_uom,
        si.date_end,
        uf.base_uom_factor,
        uf.purchase_uom_factor,
        uf.purchase_uom_name,
        (si.date_end is not null
            and si.date_end < current_date('Europe/Zurich')) as is_price_expired
    from {{ ref('product_supplierinfo') }} si
    left join {{ ref('product_product') }} pp
        on pp.product_template_id = si.product_template_id
       and pp.is_active
    left join uom_factors uf
        on uf.product_template_id = si.product_template_id
    where (si.product_id is null or si.product_id = pp.product_id)
    qualify row_number() over (
        partition by coalesce(si.product_id, pp.product_id)
        order by
            ifnull(safe_cast(si.vendor_priority as int64), 999),
            si.sequence,
            (si.date_end is not null
                and si.date_end < current_date('Europe/Zurich')),
            si.min_order_qty,
            si.product_supplierinfo_id
    ) = 1
)

select

    /* IDS */
    pk.product_id,
    pk.vendor_partner_id,
    pk.currency_id,

    /* DIMENSIONS */
    rp.partner_name                                          as vendor_name,
    cur.currency_code,
    pk.purchase_uom_name,

    /* BOOLEANS */
    pk.is_price_expired,

    /* METRICS */
    pk.net_price_purchase_uom,
    pk.net_price_purchase_uom
        * (ifnull(pk.purchase_uom_factor, 1)
            / ifnull(pk.base_uom_factor, 1))
        / ifnull(fx.rate, 1)                                 as net_price_base_unit_chf

from primary_pick pk
left join {{ ref('res_partner') }}  rp  on rp.partner_id   = pk.vendor_partner_id
left join {{ ref('res_currency') }} cur on cur.currency_id = pk.currency_id
left join latest_fx fx on fx.currency_id = pk.currency_id
where pk.product_id is not null
