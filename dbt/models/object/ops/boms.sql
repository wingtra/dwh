/*
    Bill of Materials headers. One row per `mrp_bom`, including inactive
    revisions (historical references). Each BOM describes how to produce
    `product_qty` units of `product_template_id` (and optionally a variant
    via `product_id` for variant-specific BOMs).

    `bom_type` distinguishes:
      - `normal`    — standard manufacturing; produces via its own MO.
      - `phantom`   — kit / virtual assembly; transparently inlined at
                      parent consumption time, no MO.
      - `subcontract` — produced externally by a subcontractor.

    Denormalises product code/name for direct browsing without joining to
    `ol.products`.
*/

select

    /* IDS */
    b.bom_id,
    b.product_template_id,
    b.product_id,
    b.product_uom_id,

    /* DATES */
    b.created_at,
    b.updated_at,

    /* DIMENSIONS */
    b.bom_code,
    b.bom_type,
    pp.product_code,
    pp.product_name,

    /* BOOLEANS */
    b.is_active,
    b.bom_type = 'phantom'                              as is_phantom,
    b.bom_type = 'subcontract'                          as is_subcontract,

    /* METRICS */
    b.product_qty                                       as output_qty,
    b.produce_delay                                     as produce_delay_days

from {{ ref('mrp_bom') }} b
left join {{ ref('products') }} pp
    on pp.product_template_id = b.product_template_id
