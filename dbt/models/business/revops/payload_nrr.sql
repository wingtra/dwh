/*
    Business layer: Payload NRR by quarter (2026). All payload revenue is NRR.
    Same recipe as drone_nrr: Confirmed payload commission with sku_revenue > 0
    (is_counted). Payload NRR = SUM(sku_revenue).

    Validation (2026-07-15 sync): Q1 1,304,903 / Q2 1,933,734 vs sheet
    1,302,903 / 1,944,054 (99.85% / 99.5%). Grain: year x quarter.
*/

with payloads as (
    select * from {{ ref('commissions') }}
    where object_type = 'Payload'
      and is_counted
)

select
    commission_year    as year,
    commission_quarter as quarter,
    count(*)                    as payloads_sold,
    round(sum(sku_revenue), 2)  as payload_nrr_revenue
from payloads
group by year, quarter
order by year, quarter
