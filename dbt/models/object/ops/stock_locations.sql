/*
    Stock-location dimension. One row per Odoo stock.location, including
    active and inactive. Internal, transit, supplier, customer, virtual
    (production / scrap / inventory adjustments) — all preserved because
    historical stock_move events reference the full set.
    Derived columns:
      is_wwh_internal — TRUE for Wingtra-Warehouse-AG internal locations
                        (`parent_path LIKE '1/7/%'` AND usage='internal').
                        This is the scope used by the CTB workflow and
                        Andrea's OH-Inventory tab.
*/

select

    /* IDS */
    sl.location_id,
    sl.parent_location_id,
    sl.warehouse_id,
    sl.storage_category_id,
    sl.company_id,

    /* DATES */
    sl.created_at,
    sl.updated_at,

    /* DIMENSIONS */
    sl.location_name,
    sl.location_full_path,
    sl.parent_path,
    sl.location_usage,

    /* BOOLEANS */
    sl.is_active,
    sl.is_scrap_location,
    (sl.location_usage = 'internal' and sl.parent_path like '1/7/%') as is_wwh_internal

from {{ ref('stock_location') }} sl
