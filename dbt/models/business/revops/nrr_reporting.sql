/*
    Unified NRR reporting model (2026), quarterly.

    One row per year x quarter x product_type. Consolidates the three component
    BL models — drone_nrr, payload_nrr, license_nrr_rr — into a single reporting
    surface with a product_type dimension, so the "Monthly/Quarterly NRR vs. RR"
    report can be sliced by component from one table.

    Components keep their own (tested) source logic and remain the building
    blocks; this model is the thin union over them.

      product_type   nrr_usd source          rr_usd            units_sold
      Drone          drone_nrr_revenue       0                 drones_sold
      Payload        payload_nrr_revenue     0                 payloads_sold
      License        license_nrr             license_rr        NULL (n/a)

    Drone + Payload are all-NRR (rr_usd = 0). License carries both NRR and RR.
    units_sold is NULL for License (no unit count in the commission object at
    this grain). Tariff, Shipping and Cloud are separate components not yet in
    the commission-object model and are out of scope here.

    Grain: year x quarter x product_type — enforced by
    tests/assert_nrr_reporting_grain_unique.sql.
*/

with drone as (
    select
        year,
        quarter,
        'Drone' as product_type,
        drone_nrr_revenue         as nrr_usd,
        cast(0 as float64)        as rr_usd,
        drones_sold               as units_sold
    from {{ ref('drone_nrr') }}
),
payload as (
    select
        year,
        quarter,
        'Payload' as product_type,
        payload_nrr_revenue       as nrr_usd,
        cast(0 as float64)        as rr_usd,
        payloads_sold             as units_sold
    from {{ ref('payload_nrr') }}
),
license as (
    select
        year,
        quarter,
        'License' as product_type,
        license_nrr               as nrr_usd,
        license_rr                as rr_usd,
        cast(null as int64)       as units_sold
    from {{ ref('license_nrr_rr') }}
)

select * from drone
union all
select * from payload
union all
select * from license
order by year, quarter, product_type
