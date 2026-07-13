/*
    Business layer: Drone NRR by quarter (2026).
    Reproduces the "Monthly NRR vs. RR" sheet Drones block from the commission
    object. All drone revenue is Non-Recurring (NRR).

    Rule (confirmed with RevOps): a drone counts if it is a Confirmed drone
    commission with sku_revenue > 0 (is_counted). Drone NRR = SUM(sku_revenue).

    Reconciliation harness (2026-07-08 sync): Q1 1,839,215 / Q2 2,378,345.
    Grain: one row per (commission_year, commission_quarter).
*/

with commissions as (
    select * from {{ ref('commissions') }}
    where object_type = 'Drone'
      and is_counted
)

select
    commission_year  as year,
    commission_quarter as quarter,
    count(*)                       as drones_sold,
    round(sum(sku_revenue), 2)     as drone_nrr_revenue
from commissions
group by year, quarter
order by year, quarter
