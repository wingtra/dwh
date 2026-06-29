/*
    Bill of Materials lines. One row per `mrp_bom_line` — a component
    consumed by its parent BOM. Each row says: "to produce `output_qty` of
    the parent BOM's product, consume `component_qty` of `component_product_id`".

    Denormalises both the component's product info and the parent BOM's
    header info so a single SELECT against this table answers "what are
    Wingtra's BOM lines" without joins.
*/

select

    /* IDS */
    bl.bom_line_id,
    bl.bom_id,
    bl.product_id                                       as component_product_id,
    bl.product_uom_id                                   as component_uom_id,

    /* DATES */
    bl.created_at,
    bl.updated_at,

    /* DIMENSIONS */
    comp.product_code                                   as component_product_code,
    comp.product_name                                   as component_product_name,
    b.bom_code                                          as parent_bom_code,
    b.bom_type                                          as parent_bom_type,
    parent_prod.product_code                            as parent_product_code,
    parent_prod.product_name                            as parent_product_name,

    /* BOOLEANS */
    b.is_active                                         as parent_bom_is_active,

    /* METRICS */
    bl.product_qty                                      as component_qty,
    bl.cost_share

from {{ ref('mrp_bom_line') }} bl
join {{ ref('boms') }} b              on b.bom_id = bl.bom_id
left join {{ ref('products') }} comp   on comp.product_id = bl.product_id
left join {{ ref('products') }} parent_prod on parent_prod.product_template_id = b.product_template_id
