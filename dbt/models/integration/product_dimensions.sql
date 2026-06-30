/*
    Canonical product join. One row per product variant that is either
    currently active OR referenced by any historical fact (purchase order
    line, stock move, stock quant, BOM header, BOM line). Fully archived
    variants that no fact ever touched are dropped to avoid warehouse bloat.
    The is_active column on the row tells consumers whether the variant is
    still active today; downstream OL models expose it for filtering.
    Flat product master combining product_product + product_template +
    product_category + uom_uom + primary supplier (product_supplierinfo +
    res_partner) + responsible / SCM users (res_users + res_partner).
    Private to the warehouse — consumers should read ol_product,
    ol_purchase_order_line, ol_stock_position, or ol_material_balance.
*/

with

referenced_product_ids as (
    select product_id from {{ ref('purchase_order_line') }} where product_id is not null
    union distinct
    select product_id from {{ ref('stock_move') }}                  where product_id is not null
    union distinct
    select product_id from {{ ref('stock_quant') }}                 where product_id is not null
    union distinct
    select product_id from {{ ref('mrp_bom') }}                     where product_id is not null
    union distinct
    select product_id from {{ ref('mrp_bom_line') }}                where product_id is not null
),

-- Products that are the OUTPUT of any active BoM. A BoM with product_id set
-- is pinned to one variant; a BoM with product_id NULL applies to all variants
-- of its product_template_id, so we expand it via product_product.
bom_outputs as (
    select distinct product_id
    from {{ ref('mrp_bom') }}
    where is_active and product_id is not null
    union distinct
    select distinct pp.product_id
    from {{ ref('mrp_bom') }} mb
    join {{ ref('product_product') }} pp on pp.product_template_id = mb.product_template_id
    where mb.is_active and mb.product_id is null
),

-- Products that appear as a COMPONENT on any active BoM line.
bom_components as (
    select distinct mbl.product_id
    from {{ ref('mrp_bom_line') }} mbl
    join {{ ref('mrp_bom') }}      mb  on mb.bom_id = mbl.bom_id
    where mb.is_active and mbl.product_id is not null
),

supplier_ranked as (
    -- One row per (template, supplier) ranked by Odoo `sequence`. Does NOT exclude
    -- Wingtra AG self-supplier (partner_id=1); Odoo's product list view does. If the
    -- discrepancy matters, add `where psi.partner_id != 1`.
    select
        psi.product_template_id,
        psi.partner_id              as supplier_partner_id,
        rp.partner_name             as supplier_name,
        psi.price                   as supplier_price,
        psi.min_order_qty           as supplier_min_order_qty,
        psi.lead_time_days          as supplier_lead_time_days,
        psi.currency_id             as supplier_price_currency_id,
        psi.sequence                as supplier_sequence,
        psi.product_supplierinfo_id as supplier_info_id,
        row_number() over (
            partition by psi.product_template_id
            order by psi.sequence, psi.product_supplierinfo_id
        ) as rn
    from {{ ref('product_supplierinfo') }} psi
    left join {{ ref('res_partner') }} rp on rp.partner_id = psi.partner_id
    where psi.product_template_id is not null
),

primary_supplier as (
    select
        product_template_id,
        supplier_partner_id,
        supplier_name,
        supplier_price,
        supplier_min_order_qty,
        supplier_lead_time_days,
        supplier_price_currency_id
    from supplier_ranked
    where rn = 1
),

other_suppliers as (
    -- Non-primary suppliers (rn > 1), aggregated into an array per template
    -- ordered by Odoo `sequence` then product_supplierinfo_id (same tie-break
    -- as the primary pick). Mirrors primary_supplier's "don't exclude
    -- partner_id=1 self-supplier" caveat.
    select
        product_template_id,
        array_agg(supplier_partner_id order by supplier_sequence, supplier_info_id) as other_supplier_partner_ids
    from supplier_ranked
    where rn > 1
    group by product_template_id
)

select

    /* IDS */
    pp.product_id,
    pp.product_template_id,
    pt.product_category_id,
    pt.uom_id,
    ps.supplier_partner_id                                                       as primary_supplier_partner_id,
    coalesce(os.other_supplier_partner_ids, [])                                  as other_supplier_partner_ids,
    ps.supplier_price_currency_id                                                as primary_supplier_price_currency_id,
    pt.company_id,

    /* DATES */
    pp.created_at,
    pp.updated_at,

    /* DIMENSIONS */
    pp.product_code,
    pt.product_name,
    pc.category_full_path                                                        as category_path,
    bsc.buy_sku_category,
    uom.uom_name,
    case pt.product_type
        when 'consu'   then 'Goods'
        when 'service' then 'Service'
        else pt.product_type
    end                                                                          as product_type,
    case
        when pt.product_type = 'service'                  then 'Service'
        when pt.product_type = 'consu' and pt.is_storable then 'Storable Product'
        when pt.product_type = 'consu'                    then 'Consumable'
    end                                                                          as product_type_label,
    case
        when bo.product_id is not null and bc.product_id is not null then 'subassembly'
        when bo.product_id is not null                               then 'end_product'
        when bc.product_id is not null                               then 'component'
        else '999'
    end                                                                          as product_role,
    pt.hs_code,
    ps.supplier_name                                                             as primary_supplier_name,
    resp.user_name                                                               as responsible_name,
    scm.user_name                                                                as scm_responsible_name,
    expert.expert_name                                                           as expert_name,
    cast('CHF' as string)                                                        as standard_price_ag_currency,

    /* BOOLEANS */
    pp.is_active and pt.is_active                                                as is_active,
    pt.is_purchasable,
    pt.is_saleable,
    pt.is_storable,

    /* MEASURES */
    pt.list_price,
    pp.standard_price_ag,
    ps.supplier_price                                                            as primary_supplier_price,
    ps.supplier_min_order_qty                                                    as primary_supplier_min_order_qty,
    ps.supplier_lead_time_days                                                   as primary_supplier_lead_time_days,
    tr.take_rate,
    imm.odoo_max_qty

from {{ ref('product_product') }}        pp
join {{ ref('product_template') }}       pt   on pt.product_template_id = pp.product_template_id
join {{ ref('product_category') }}       pc   on pc.product_category_id = pt.product_category_id
left join {{ ref('uom_uom') }}           uom  on uom.uom_id             = pt.uom_id
left join primary_supplier                        ps   on ps.product_template_id = pt.product_template_id
left join other_suppliers                         os   on os.product_template_id = pt.product_template_id
left join {{ ref('users') }}                      resp   on resp.user_id   = safe_cast(json_value(pt.responsible_property_raw, '$."1"') as int64)
left join {{ ref('users') }}                      scm    on scm.user_id    = pt.scm_id
left join {{ ref('wt_product_expert') }}          expert on expert.expert_id = pt.expert_id
left join bom_outputs                             bo     on bo.product_id  = pp.product_id
left join bom_components                          bc     on bc.product_id  = pp.product_id
left join {{ ref('buy_sku_categories') }}         bsc    on bsc.product_code = pp.product_code
left join {{ ref('take_rates') }}                 tr     on tr.product_code  = pp.product_code
left join {{ ref('gsheet_inventory_master_ag') }} imm    on imm.product_code = pp.product_code
where pp.is_active or pp.product_id in (select product_id from referenced_product_ids)
