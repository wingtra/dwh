/*
    Leaf-level BOM explosion for costing. For every product that is the
    output of an active BOM, walk the BOM tree and keep ONLY leaf
    components (components without an own active BOM). Output answers:
    "one unit of <root product> ultimately consists of how many of
    <leaf component>?"

    Differs from bom_consolidated_components on purpose:
    - ONE active BOM per template (lowest sequence, then id — the same
      order Odoo's _bom_find uses). bom_consolidated_components expands
      every active BOM of a template, which double-counts templates that
      carry two active BOMs (e.g. SUB-CAMBEAM as of 2026-07-15).
    - Leaf components only, so line costs can be summed per root without
      double-counting sub-assemblies.
    - Quantities are divided by the BOM header's product_qty (batch
      BOMs). All current BOMs produce qty 1, so this is future-proofing,
      not a difference in output today.

    Subcontracted BOMs (type = 'subcontract') are expanded like normal
    ones: the roll-up covers their raw materials but NOT the
    subcontracting fee paid to the vendor. Consumers must not read the
    roll-up of a subcontracted assembly as its full cost.

    Recursion guard: depth <= 15 (deepest tree today is 5).
    Zero-qty BOM lines are dropped.

    Grain: one row per (root_product_id, component_product_id).
*/

{{ config(materialized='table') }}

with recursive

single_bom as (
    -- one active BOM per template, matching Odoo's selection order
    select bom_id, product_template_id, bom_type, product_qty
    from {{ ref('mrp_bom') }}
    where is_active
    qualify row_number() over (
        partition by product_template_id
        order by sequence, bom_id
    ) = 1
),

bom_line as (
    select bom_id, product_id, product_qty
    from {{ ref('mrp_bom_line') }}
    where product_qty > 0
      and product_id is not null
),

bom_walk as (
    -- Depth 1: direct lines of every root product that has an active BOM
    select
        pp.product_id                                       as root_product_id,
        bl.product_id                                       as component_product_id,
        bl.product_qty / nullif(b.product_qty, 0)           as qty_per_unit,
        1                                                   as depth
    from {{ ref('product_product') }} pp
    join single_bom b
        on b.product_template_id = pp.product_template_id
    join bom_line bl
        on bl.bom_id = b.bom_id
    where pp.is_active

    union all

    -- Recursive: when a component itself has an active BOM, expand
    select
        bw.root_product_id,
        child_line.product_id                               as component_product_id,
        bw.qty_per_unit * child_line.product_qty
            / nullif(child_bom.product_qty, 0)              as qty_per_unit,
        bw.depth + 1                                        as depth
    from bom_walk bw
    join {{ ref('product_product') }} cp
        on cp.product_id = bw.component_product_id
    join single_bom child_bom
        on child_bom.product_template_id = cp.product_template_id
    join bom_line child_line
        on child_line.bom_id = child_bom.bom_id
    where bw.depth < 15
)

select

    /* IDS */
    bw.root_product_id,
    bw.component_product_id,

    /* METRICS */
    sum(bw.qty_per_unit) as qty_per_unit,
    max(bw.depth)        as depth_max

from bom_walk bw
join {{ ref('product_product') }} cp
    on cp.product_id = bw.component_product_id
left join single_bom cb
    on cb.product_template_id = cp.product_template_id
where cb.bom_id is null  -- leaves only
group by 1, 2
