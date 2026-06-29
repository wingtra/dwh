{{ config(enabled=false) }}

/*
    Per-SKU planning summary joining the Inventory Master sheet to the Odoo
    product dimension. One row per active BUY SKU that is present in BOTH
    Odoo (active, purchasable) AND the master sheet (is_buy_sku) AND has
    a positive demand_per_day. Carries lead time, take rate, weekly and
    6-week horizon demand. Feeds ol_material_balance.
*/

{% set horizon_weeks = 6 %}

select

    /* IDS */
    pd.product_id,

    /* DATES */
    date_trunc(current_date('Europe/Zurich'), isoweek)                          as horizon_start_date,
    date_add(date_trunc(current_date('Europe/Zurich'), isoweek),
             interval {{ horizon_weeks * 7 }} day)                              as horizon_end_date,

    /* DIMENSIONS */
    pd.product_code,
    m.product_name                                                              as master_product_name,
    m.planning_owner,

    /* MEASURES */
    m.lead_time_days,
    m.take_rate,
    m.demand_per_day,
    m.demand_per_day * 7                                                        as weekly_demand_qty,
    m.demand_per_day * 7 * {{ horizon_weeks }}                                  as horizon_demand_qty,
    m.moq,
    m.safety_stock,
    m.odoo_min_qty,
    m.odoo_max_qty
from {{ ref('gsheet_inventory_master_ag') }} m
join {{ ref('product_dimensions') }}          pd on pd.product_code = m.product_code
where pd.is_active     = true
  and pd.is_purchasable = true
  and m.is_buy_sku     = true
  and m.demand_per_day is not null
  and m.demand_per_day > 0
