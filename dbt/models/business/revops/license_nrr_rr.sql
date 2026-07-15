/*
    Business layer: License NRR + RR by quarter (2026), full set.
    Licenses are a mixed bucket (non-annual NRR, annual RR, LiDAR split, Cloud
    is a separate tool). sku_type is NULL on License records, so we classify by
    sku_revenue value via the seed sku_license_category.

    Seed invariant: nrr_amount + rr_amount = sku_revenue (LiDAR SPLIT rows carry
    the per-unit HW/SW split, e.g. 48700 -> 23200 NRR + 25500 RR).

    Buckets (validated read-only 2026-07-15):
      license_nrr = non-annual (ADP/PPK/SYW) + LiDAR HW
        Q1 359,870 (120,700 non-annual + 239,170 LiDAR) / Q2 739,295 (109,310 + 629,985)
      license_rr  = annual licenses + LiDAR SW/renewals/upgrades
        Q1 1,240,075 (935,095 annual + 304,980 LiDAR) / Q2 2,321,585 (1,395,965 + 925,620)

    Non-annual NRR reconciles EXACT to the sheet "NRR Licenses" row
    (120,700 / 109,310). LiDAR NRR ~sheet (Q1 239,170 vs 239,100). Annual +
    LiDAR RR feed the sheet RR total; residual there is Cloud (separate tool).

    Grain: year x quarter. If a Confirmed license value is missing from the
    seed it drops out — the singular test assert_license_values_mapped.sql
    guards that.
*/

with licences as (
    select * from {{ ref('commissions') }}
    where object_type = 'License'
      and is_counted
),
category as (
    select * from {{ ref('sku_license_category_seed') }}
)

select
    l.commission_year    as year,
    l.commission_quarter as quarter,
    round(sum(c.nrr_amount), 2) as license_nrr,
    round(sum(c.rr_amount), 2)  as license_rr
from licences l
join category c on l.sku_revenue = c.sku_revenue
group by year, quarter
order by year, quarter
