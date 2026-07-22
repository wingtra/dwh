/*
    Unified NRR reporting model (2026), quarterly — the single RevOps NRR/RR
    reporting surface. One row per year x quarter x product_type
    (Drone | License | Payload), built directly from the commission object
    (2-53702763) so the "Monthly/Quarterly NRR vs. RR" report can be sliced by
    component from one table. Replaces the former per-component BL models
    (drone_nrr / payload_nrr / license_nrr_rr), consolidated here per Lucille.

      product_type   nrr_usd                              rr_usd        units_sold
      Drone          SUM(sku_revenue), all NRR            0             count
      Payload        SUM(sku_revenue), all NRR            0             count
      License        seed NRR split + sheet-only manual   seed RR split NULL (n/a)

    Eligibility: is_counted (Confirmed AND sku_revenue > 0), from the object
    layer. License sku_type is NULL, so License is classified by sku_revenue
    value via seed sku_license_category_seed (nrr_amount + rr_amount =
    sku_revenue; LiDAR SPLIT rows carry the HW/SW split). Sheet-only NRR items
    with no commission object (Professional Services incl. Service to
    Armasuisse) come from nonannual_manual_nrr_seed and are added to License
    NRR — parallel to Cloud being sheet-only RR (Cloud, Tariff, Shipping are
    separate components not yet modeled and out of scope here).

    Reconciliation (2026): Drone Q1 1,839,215 / Q2 2,378,345; Payload
    1,304,903 / 1,933,734; License NRR 359,870 / 1,047,390 (Q2 non-annual ties
    the sheet exactly: 109,310 commissioned + 308,095 manual = 417,405).

    Grain: year x quarter x product_type — enforced by
    tests/assert_nrr_reporting_grain_unique.sql. License value coverage guarded
    by tests/assert_license_values_mapped.sql.
*/

with commissions as (
    select * from {{ ref('commissions') }}
    where is_counted
),
license_category as (
    select * from {{ ref('sku_license_category_seed') }}
),
manual_nrr as (
    select year, quarter, sum(nrr_usd) as manual_nrr
    from {{ ref('nonannual_manual_nrr_seed') }}
    group by year, quarter
),

drone as (
    select
        commission_year   as year,
        commission_quarter as quarter,
        'Drone'            as product_type,
        round(sum(sku_revenue), 2) as nrr_usd,
        cast(0 as float64)         as rr_usd,
        count(*)                   as units_sold
    from commissions
    where object_type = 'Drone'
    group by year, quarter
),
payload as (
    select
        commission_year   as year,
        commission_quarter as quarter,
        'Payload'          as product_type,
        round(sum(sku_revenue), 2) as nrr_usd,
        cast(0 as float64)         as rr_usd,
        count(*)                   as units_sold
    from commissions
    where object_type = 'Payload'
    group by year, quarter
),
license_commissioned as (
    select
        l.commission_year   as year,
        l.commission_quarter as quarter,
        sum(c.nrr_amount) as nrr_commissioned,
        sum(c.rr_amount)  as rr_commissioned
    from commissions l
    join license_category c on l.sku_revenue = c.sku_revenue
    where l.object_type = 'License'
    group by year, quarter
),
license as (
    select
        lc.year,
        lc.quarter,
        'License' as product_type,
        round(lc.nrr_commissioned + coalesce(m.manual_nrr, 0), 2) as nrr_usd,
        round(lc.rr_commissioned, 2)                              as rr_usd,
        cast(null as int64)                                       as units_sold
    from license_commissioned lc
    left join manual_nrr m
        on lc.year = cast(m.year as string) and lc.quarter = m.quarter
)

select * from drone
union all
select * from payload
union all
select * from license
order by year, quarter, product_type
