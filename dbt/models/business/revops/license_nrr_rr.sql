/*
    Business layer: License NRR + RR by quarter (2026), full set.
    Licenses are a mixed bucket (non-annual NRR, annual RR, LiDAR split, Cloud
    is a separate tool). sku_type is NULL on License records, so we classify by
    sku_revenue value via the seed sku_license_category.

    Seed invariant: nrr_amount + rr_amount = sku_revenue (LiDAR SPLIT rows carry
    the per-unit HW/SW split, e.g. 48700 -> 23200 NRR + 25500 RR).

    Buckets (validated read-only 2026-07-15):
      license_nrr = non-annual (ADP/PPK/SYW) + LiDAR HW + sheet-only manual NRR
        Q1 359,870 (120,700 non-annual + 239,170 LiDAR)
        Q2 1,047,390 (109,310 + 629,985 + 308,095 manual Professional Services)
      license_rr  = annual licenses + LiDAR SW/renewals/upgrades
        Q1 1,240,075 (935,095 annual + 304,980 LiDAR) / Q2 2,321,585 (1,395,965 + 925,620)

    Commissioned non-annual NRR reconciles EXACT to the sheet "NRR Licenses"
    row (120,700 / 109,310). Adding the sheet-only manual line (Professional
    Services incl. Armasuisse, 308,095 in Q2) makes the Q2 non-annual match the
    sheet exactly (109,310 + 308,095 = 417,405). LiDAR NRR ~sheet (Q1 239,170
    vs 239,100). Annual + LiDAR RR feed the sheet RR total; residual is Cloud.

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
),
commissioned as (
    select
        l.commission_year    as year,
        l.commission_quarter as quarter,
        sum(c.nrr_amount) as license_nrr,
        sum(c.rr_amount)  as license_rr
    from licences l
    join category c on l.sku_revenue = c.sku_revenue
    group by year, quarter
),
/*
    Sheet-only NRR items with no commission object (like Cloud, which is
    sheet-only RR). Professional Services incl. Service to Armasuisse is a
    manual sheet line, assumed 100% NRR. Reconciles the sheet's Q2 non-annual
    "SUM of SKU rev" exactly: sheet 417,405 = commissioned non-annual 109,310
    + manual 308,095. Source: nonannual_manual_nrr_seed.
*/
manual_nrr as (
    select year, quarter, sum(nrr_usd) as manual_nrr
    from {{ ref('nonannual_manual_nrr_seed') }}
    group by year, quarter
)

select
    c.year,
    c.quarter,
    round(c.license_nrr + coalesce(m.manual_nrr, 0), 2) as license_nrr,
    round(c.license_rr, 2)                              as license_rr
from commissioned c
left join manual_nrr m on c.year = cast(m.year as string) and c.quarter = m.quarter
order by year, quarter
