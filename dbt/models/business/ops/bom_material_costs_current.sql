/*
    Latest weekly snapshot of bom_material_costs, as a view. Dashboard
    convenience following the dash_*_current precedent: "current" cards
    point here and never have to solve MAX(snapshot_week) in Metabase;
    trend cards read the full snapshot table.

    Grain: one row per (root product, leaf component) at the latest
    snapshot_week.
*/

{{ config(materialized='view') }}

select *
from {{ ref('bom_material_costs') }}
where snapshot_week = (
    select max(snapshot_week) from {{ ref('bom_material_costs') }}
)
