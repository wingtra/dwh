/*
    Stock-movement fact, unpivoted to one row per move-LEG.
    Every Odoo stock_move produces exactly two rows: one for its src location
    with negative quantity, one for its dest location with positive quantity.
    Consequence: `SUM(quantity_signed) GROUP BY product_id, location_id WHERE move_state='done'`
    equals the on-hand Odoo's UI shows, at every internal location.

    Caveats:
      - Reconciliation holds for `is_storable = TRUE` products. Consumable
        templates aren't tracked by Odoo's stock_quant at all; their inbound
        moves accumulate without matching outbounds.
      - A handful of storable products (16 / 415) have small historical drift
        from inventory adjustments that touched stock_quant directly before
        Odoo 18 enforced backing moves. See docs/process-improvements.md.

    Filtering:
      - CEE rows (`company_id=8`) excluded per project policy.
      - All states included (`draft`, `waiting`, `confirmed`, `partially_available`,
        `assigned`, `done`, `cancel`). Consumers filter by `move_state` /
        `is_done` / `is_pending` as needed.
*/

with src_moves as (
    select * from {{ ref('stock_move') }}
    where (company_id is null or company_id != 8)
      and quantity is not null      -- skip ~40 corrupted source rows with NULL qty
      and is_done is not null
),

legs as (
    -- DEST leg: positive quantity at the destination location
    select
        sm.stock_move_id,
        sm.product_id,
        sm.location_dest_id                                                      as location_id,
        cast('dest' as string)                                                   as leg_role,
        sm.quantity                                                              as quantity_signed,
        sm.quantity                                                              as quantity_abs,
        sm.price_unit,
        sm.company_id,
        sm.partner_id,
        sm.picking_id,
        sm.purchase_line_id                                                      as purchase_order_line_id,
        sm.sale_line_id                                                          as sale_order_line_id,
        sm.production_id,
        sm.scrap_id,
        sm.bom_line_id,
        sm.origin_returned_move_id,
        sm.product_uom_id,
        sm.created_at,
        sm.updated_at,
        sm.date                                                                  as scheduled_date,
        sm.date_done,
        coalesce(sm.date_done, sm.date)                                          as move_date,
        sm.move_name,
        sm.reference,
        sm.origin,
        sm.move_state,
        sm.is_done,
        sm.is_scrapped,
        sm.is_inventory,
        sm.location_id                                                           as src_location_id,
        sm.location_dest_id                                                      as dest_location_id
    from src_moves sm

    union all

    -- SRC leg: negative quantity at the source location
    select
        sm.stock_move_id,
        sm.product_id,
        sm.location_id                                                           as location_id,
        cast('src' as string)                                                    as leg_role,
        -sm.quantity                                                             as quantity_signed,
        sm.quantity                                                              as quantity_abs,
        sm.price_unit,
        sm.company_id,
        sm.partner_id,
        sm.picking_id,
        sm.purchase_line_id                                                      as purchase_order_line_id,
        sm.sale_line_id                                                          as sale_order_line_id,
        sm.production_id,
        sm.scrap_id,
        sm.bom_line_id,
        sm.origin_returned_move_id,
        sm.product_uom_id,
        sm.created_at,
        sm.updated_at,
        sm.date                                                                  as scheduled_date,
        sm.date_done,
        coalesce(sm.date_done, sm.date)                                          as move_date,
        sm.move_name,
        sm.reference,
        sm.origin,
        sm.move_state,
        sm.is_done,
        sm.is_scrapped,
        sm.is_inventory,
        sm.location_id                                                           as src_location_id,
        sm.location_dest_id                                                      as dest_location_id
    from src_moves sm
)

select

    /* IDS */
    legs.stock_move_id,
    legs.product_id,
    legs.location_id,
    legs.src_location_id,
    legs.dest_location_id,
    legs.product_uom_id,
    legs.company_id,
    legs.partner_id,
    legs.picking_id,
    legs.purchase_order_line_id,
    legs.sale_order_line_id,
    legs.production_id,
    legs.scrap_id,
    legs.bom_line_id,
    legs.origin_returned_move_id,

    /* TIMESTAMPS */
    legs.created_at,
    legs.updated_at,

    /* DATES */
    legs.move_date,
    legs.scheduled_date,
    legs.date_done,

    /* DIMENSIONS */
    legs.move_name,
    legs.reference,
    legs.origin,
    legs.move_state,
    legs.leg_role,
    case
        when legs.scrap_id is not null or legs.is_scrapped
            then 'scrap'
        when legs.is_inventory
            then 'inventory_adjustment'
        when legs.origin_returned_move_id is not null
            then 'return'
        when src_loc.location_usage = 'supplier' and dest_loc.location_usage = 'internal'
            then 'receipt'
        when src_loc.location_usage = 'internal' and dest_loc.location_usage = 'customer'
            then 'delivery'
        when src_loc.location_usage = 'internal' and dest_loc.location_usage = 'production'
            then 'manufacturing_consumption'
        when src_loc.location_usage = 'production' and dest_loc.location_usage = 'internal'
            then 'manufacturing_output'
        when src_loc.location_usage = 'internal' and dest_loc.location_usage = 'internal'
            then 'internal_transfer'
        else 'other'
    end                                                                          as move_type,
    pp.product_code,
    pp.product_name,
    src_loc.location_full_path                                                   as src_location_full_path,
    dest_loc.location_full_path                                                  as dest_location_full_path,
    loc.location_full_path,
    loc.location_usage                                                           as leg_location_usage,
    loc.is_wwh_internal                                                          as is_at_wwh_internal,

    /* BOOLEANS */
    legs.is_done,
    legs.move_state in ('confirmed', 'waiting', 'partially_available', 'assigned') as is_pending,
    legs.move_state = 'cancel'                                                   as is_cancelled,
    legs.is_scrapped,
    legs.is_inventory,

    /* METRICS */
    legs.quantity_signed,
    legs.quantity_abs,
    legs.price_unit,
    legs.quantity_signed * coalesce(legs.price_unit, 0)                          as value_signed

from legs
left join {{ ref('products') }}        pp        on pp.product_id          = legs.product_id
left join {{ ref('stock_locations') }} loc       on loc.location_id        = legs.location_id
left join {{ ref('stock_locations') }} src_loc   on src_loc.location_id    = legs.src_location_id
left join {{ ref('stock_locations') }} dest_loc  on dest_loc.location_id   = legs.dest_location_id
