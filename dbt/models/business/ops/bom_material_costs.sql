/*
    Weekly snapshot of flattened (leaf-level) BOM material cost, one row
    per (snapshot_week, root product, leaf component). Consumption mart
    behind the "BoM Material Cost Monitor" Metabase dashboard (Jan Skret's
    2026-07-15 handover, reviewed against dl_odoo the same day — his
    baseline for the 9 monitored SKUs reproduced exactly).

    Two costings per component, both CHF per base unit:
    - AVCO: Odoo average cost (product_product.standard_price, company 1).
    - Primary vendor: the FIXED primary vendor's pricelist price
      (vendor_priority = 1, fallback lowest sequence — never the cheapest
      vendor), discount applied, converted from the purchase UoM to the
      base unit and to CHF at the latest company-1 rate.

    Scope: ALL products with an active BOM (167 roots, ~3k leaf rows per
    snapshot), not just the 9 SKUs Jan monitors — dashboards filter by
    root_product_code, and newly monitored SKUs get history for free.
    Filter root_product_role = 'end_product' for sellable goods only.

    Snapshot semantics: snapshot_week is the Monday of the current ISO
    week. The model runs daily (bl_ops default); each run overwrites the
    current week's partition, so the current week always reflects the
    latest Odoo state and past weeks are frozen at their last run
    (effectively Sunday night). Consumers wanting "current" filter to
    MAX(snapshot_week).

    Material cost only — no operations, labor, or cost_share overheads.
    Totals sit 0-3% below Odoo's stored parent cost (verified 2026-07-15
    on all 9 monitored SKUs). Subcontracted sub-assemblies (RAY propellers
    5975/5976) are exploded into raw materials; the subcontracting fee is
    NOT included on either cost side.

    price_flags marks suspicious rows (comma-separated, NULL = clean):
    missing_vendor_price, zero_vendor_price, missing_avco, zero_avco,
    expired_vendor_price, extreme_ratio (vendor/AVCO unit ratio > 20x
    either way — catches pack-price pricelist errors). Individual boolean
    columns exist for filtering; price_flags is for group-by dashboards.
*/

{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by={'field': 'snapshot_week', 'data_type': 'date'},
    cluster_by=['root_product_code'],
    on_schema_change='sync_all_columns',
    full_refresh=false
) }}

with

lines as (
    select
        date_trunc(current_date('Europe/Zurich'), week(monday))  as snapshot_week,
        blc.root_product_id,
        root.product_code                                         as root_product_code,
        root.product_name                                         as root_product_name,
        root.product_role                                         as root_product_role,
        blc.component_product_id,
        comp.product_code                                         as component_product_code,
        comp.product_name                                         as component_product_name,
        blc.qty_per_unit,
        comp.standard_price_ag                                    as avco_unit_cost_chf,
        vp.vendor_partner_id,
        vp.vendor_name,
        vp.currency_code                                          as vendor_currency_code,
        vp.purchase_uom_name,
        vp.net_price_purchase_uom                                 as vendor_price_purchase_uom,
        vp.net_price_base_unit_chf                                as vendor_unit_cost_chf,
        vp.product_id is null                                     as is_vendor_price_missing,
        ifnull(vp.net_price_base_unit_chf = 0, false)             as is_vendor_price_zero,
        ifnull(vp.is_price_expired, false)                        as is_vendor_price_expired,
        comp.standard_price_ag is null                            as is_avco_missing,
        ifnull(comp.standard_price_ag = 0, false)                 as is_avco_zero,
        ifnull(safe_divide(vp.net_price_base_unit_chf,
                           comp.standard_price_ag) > 20
            or safe_divide(comp.standard_price_ag,
                           vp.net_price_base_unit_chf) > 20,
               false)                                             as is_extreme_ratio
    from {{ ref('bom_leaf_components') }} blc
    join {{ ref('products') }} root
        on root.product_id = blc.root_product_id
    join {{ ref('products') }} comp
        on comp.product_id = blc.component_product_id
    left join {{ ref('product_primary_vendor_prices') }} vp
        on vp.product_id = blc.component_product_id
)

select

    /* IDS */
    snapshot_week,
    root_product_id,
    component_product_id,
    vendor_partner_id,

    /* DIMENSIONS */
    root_product_code,
    root_product_name,
    root_product_role,
    component_product_code,
    component_product_name,
    vendor_name,
    vendor_currency_code,
    purchase_uom_name,
    nullif(array_to_string([
        if(is_vendor_price_missing, 'missing_vendor_price', null),
        if(is_vendor_price_zero,    'zero_vendor_price',    null),
        if(is_avco_missing,         'missing_avco',         null),
        if(is_avco_zero,            'zero_avco',            null),
        if(is_vendor_price_expired, 'expired_vendor_price', null),
        if(is_extreme_ratio,        'extreme_ratio',        null)
    ], ','), '')                                                  as price_flags,

    /* BOOLEANS */
    is_vendor_price_missing,
    is_vendor_price_zero,
    is_vendor_price_expired,
    is_avco_missing,
    is_avco_zero,
    is_extreme_ratio,

    /* METRICS */
    qty_per_unit,
    avco_unit_cost_chf,
    vendor_price_purchase_uom,
    vendor_unit_cost_chf,
    qty_per_unit * avco_unit_cost_chf                             as avco_line_cost_chf,
    qty_per_unit * vendor_unit_cost_chf                           as vendor_line_cost_chf

from lines
