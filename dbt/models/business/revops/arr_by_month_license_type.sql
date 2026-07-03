/*
    ARR per month and license type, three ways, built to make differences
    obvious:

    - monthly_rr_sheet_snapshot_usd: what the Accruals sheet's matrix showed
      in the frozen 2026-07-03 read-only snapshot (the numbers Alex reports).
    - monthly_rr_replica_usd: the sheet's own formula recomputed in the DWH
      on live HubSpot data. Replica minus snapshot = data drift only.
    - monthly_rr_day_prorated_usd: corrected day-prorated method on the same
      live data. Prorated minus replica = method effect only (boundary-month
      spreading; see the expiration-date convention issue).

    One row per month and license type. ARR = monthly recognized RR * 12.
*/

{{
    config(
        materialized='table'
    )
}}

with

recognized as (
    select
        month_date,
        licence_type_label as license_type_label,
        round(sum(monthly_rr_sheet_method_usd), 2) as monthly_rr_replica_usd,
        round(sum(monthly_rr_day_prorated_usd), 2) as monthly_rr_day_prorated_usd,
        count(distinct licence_id) as licence_count
    from {{ ref('arr_licence_months_recognized') }}
    group by month_date, license_type_label
),

snapshot as (
    select
        month_date,
        license_type_label,
        snapshot_as_of_date,
        monthly_recognized_rr_usd as monthly_rr_sheet_snapshot_usd
    from {{ ref('arr_sheet_baseline_matrix') }}
),

combined as (
    select
        coalesce(r.month_date, s.month_date) as month_date,
        coalesce(r.license_type_label, s.license_type_label) as license_type_label,
        s.snapshot_as_of_date,
        s.monthly_rr_sheet_snapshot_usd,
        r.monthly_rr_replica_usd,
        r.monthly_rr_day_prorated_usd,
        r.licence_count
    from recognized r
    full outer join snapshot s
        on r.month_date = s.month_date
        and r.license_type_label = s.license_type_label
)

select
    /* DATES */
    month_date,
    snapshot_as_of_date,

    /* DIMENSIONS */
    license_type_label,
    case
        when monthly_rr_sheet_snapshot_usd is null and coalesce(monthly_rr_replica_usd, 0) != 0
            then 'month or type not present in the 2026-07-03 sheet snapshot'
        when abs(coalesce(monthly_rr_replica_usd, 0) - coalesce(monthly_rr_sheet_snapshot_usd, 0)) <= 1
            then 'match (within $1 rounding)'
        else 'data drift: licences changed in HubSpot after the sheet snapshot was taken'
    end as replica_vs_snapshot_reason,

    /* MEASURES */
    monthly_rr_sheet_snapshot_usd,
    monthly_rr_replica_usd,
    monthly_rr_day_prorated_usd,
    round(coalesce(monthly_rr_replica_usd, 0) - coalesce(monthly_rr_sheet_snapshot_usd, 0), 2) as delta_replica_vs_snapshot_usd,
    round(coalesce(monthly_rr_day_prorated_usd, 0) - coalesce(monthly_rr_replica_usd, 0), 2) as delta_method_usd,
    round(monthly_rr_sheet_snapshot_usd * 12, 2) as arr_sheet_snapshot_usd,
    round(monthly_rr_replica_usd * 12, 2) as arr_replica_usd,
    round(monthly_rr_day_prorated_usd * 12, 2) as arr_day_prorated_usd,
    licence_count

from combined
