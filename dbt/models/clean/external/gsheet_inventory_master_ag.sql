/*
    Cleaned AG Wingtra Inventory Master sheet. One row per SKU as maintained
    by the SC team in the Inventory Management Master Google Sheet (tab
    "AG Wingtra INVENTORY MASTER"). Filters out empty trailer rows and
    casts the federated table's all-STRING columns into typed values. Cells
    containing sheet artifacts like "#DIV/0!" become NULL via SAFE_CAST.

    Source sheet:
    https://docs.google.com/spreadsheets/d/1NvxoWynZt7p4BSRjN21ewwTAjA1y1tIhDyoEeWqIIWE/edit
*/

with

source as (
    select * from {{ source('external', 'gsheet_inventory_master_ag') }}
    where sku is not null
      and trim(sku) != ''
)

select
    /* IDS */
    sku as product_code,

    /* DIMENSIONS */
    product_name,
    pipo_type,
    product_type as sheet_product_type,
    can_be_purchased_flag,
    owner as planning_owner,

    /* BOOLEANS */
    lower(trim(can_be_purchased_flag)) = 'y' as is_buy_sku,

    /* MEASURES */
    safe_cast(lead_time_days_text               as int64)   as lead_time_days,
    safe_cast(lead_time_deviation_days_text     as int64)   as lead_time_deviation_days,
    safe_cast(take_rate_text                    as float64) as take_rate,
    safe_cast(additional_ltp_rampup_demand_text as float64) as additional_ltp_rampup_demand,
    safe_cast(demand_per_day_text               as float64) as demand_per_day,
    safe_cast(safety_stock_text                 as int64)   as safety_stock,
    safe_cast(z_value_text                      as float64) as z_value,
    safe_cast(stock_max_ideal_pcs_text          as float64) as stock_max_ideal_pcs,
    safe_cast(stock_max_reach_weeks_text        as float64) as stock_max_reach_weeks,
    safe_cast(avg_stock_calculated_pcs_text     as float64) as avg_stock_calculated_pcs,
    safe_cast(inventory_turnover_text           as float64) as inventory_turnover,
    safe_cast(moq_text                          as int64)   as moq,
    safe_cast(batch_size_pcs_text               as int64)   as batch_size_pcs,
    safe_cast(odoo_multiplier_text              as float64) as odoo_multiplier,
    safe_cast(odoo_min_qty_text                 as int64)   as odoo_min_qty,
    safe_cast(odoo_max_qty_text                 as int64)   as odoo_max_qty

from source
