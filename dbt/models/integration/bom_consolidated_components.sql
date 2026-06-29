/*
    For every active BOM, walk all sub-BOMs (phantom AND normal) recursively
    and aggregate component quantities. Output answers: "if I produce one
    unit of <top_template>, how many of <component_product> do I consume in
    total — including everything inside sub-assemblies?"

    This is the planning-view rollup (matches what IMM `take_rate` is
    intended to capture). Normal sub-BOMs are inlined because for material
    planning we still need to procure the raw inputs even though the sub-
    assembly is its own MO.

    Recursion guard: depth <= 15. Wingtra's deepest BOM is well within that.
    Zero-qty BOM lines are dropped.

    Grain: one row per (top_template_id, component_product_id).
*/

{{ config(materialized='table') }}

with recursive bom_seed as (
    -- Depth 1: every active BOM's direct lines
    select
        b.product_template_id                   as top_template_id,
        bl.product_id                           as component_product_id,
        cast(bl.product_qty as float64)         as cumulative_qty,
        1                                       as depth,
        cast(b.bom_id as string)                as path
    from {{ ref('mrp_bom') }} b
    join {{ ref('mrp_bom_line') }} bl
        on bl.bom_id = b.bom_id
    where b.is_active
      and bl.product_qty > 0
      and bl.product_id is not null
),

bom_walk as (
    select * from bom_seed

    union all

    -- Recursive: when a component itself has an active BOM, expand
    select
        bw.top_template_id,
        child_line.product_id                       as component_product_id,
        bw.cumulative_qty * child_line.product_qty  as cumulative_qty,
        bw.depth + 1                                as depth,
        concat(bw.path, '/', cast(child_bom.bom_id as string)) as path
    from bom_walk bw
    join {{ ref('product_product') }} pp
        on pp.product_id = bw.component_product_id
    join {{ ref('mrp_bom') }} child_bom
        on child_bom.product_template_id = pp.product_template_id
       and child_bom.is_active
    join {{ ref('mrp_bom_line') }} child_line
        on child_line.bom_id = child_bom.bom_id
       and child_line.product_qty > 0
       and child_line.product_id is not null
    where bw.depth < 15
)

select

    /* IDS */
    top_template_id,
    component_product_id,

    /* METRICS */
    sum(cumulative_qty) as consolidated_qty,
    max(depth)          as depth_max,
    count(*)            as path_count

from bom_walk
group by 1, 2
