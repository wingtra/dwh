/*
    Ground-truth stock model at the natural Odoo stock.quant grain
    (product × location × lot × package × owner). One row per quant.

    Sum across lots/packages/owners to get on-hand per (product × location).
    Sum across locations to get on-hand per product, within whatever
    location scope the consumer chooses.

    Every location is included: internal, transit, supplier, customer,
    virtual (Quarantine, B-Grade, Production offset, Scrap, etc.). CL
    has already dropped CEE (company_id = 8); no further scope filter
    here. Report-specific scope (WWH-only for SC KPI CTB, broader
    internal for KPI-09 stock valuation) is applied at the consuming
    BL/OL model. See `feedback_ol_stock_scope_broad` and
    `project_stock_oh_scope_question` in memory.

    Caveats:
      - ~40 rows in cl.stock_quant have NULL quantity (Odoo data quality);
        they are dropped here.
      - reserved_quantity is only meaningful at internal locations. At
        non-internal usage it is 0 or NULL.
*/

select

    /* IDS */
    sq.product_id,
    sq.location_id,
    sq.lot_id,
    sq.package_id,
    sq.owner_id,
    sq.company_id,

    /* DATES */
    sq.in_date,
    sq.updated_at,

    /* DIMENSIONS */
    pp.product_code,
    pt.product_name,
    sl.location_full_path,
    sl.location_usage,

    /* BOOLEANS */
    sl.is_active                                          as location_is_active,
    sl.is_wwh_internal,

    /* MEASURES */
    sq.quantity,
    sq.reserved_quantity,
    sq.quantity - coalesce(sq.reserved_quantity, 0)       as available_quantity

from {{ ref('stock_quant') }} sq
left join {{ ref('product_product') }}  pp on pp.product_id          = sq.product_id
left join {{ ref('product_template') }} pt on pt.product_template_id = pp.product_template_id
left join {{ ref('stock_locations') }}  sl on sl.location_id         = sq.location_id
where sq.quantity is not null
