/*
    Guard against publishing a latest CTB snapshot where IMM planning data was
    accidentally disconnected. The test fails when the latest snapshot has
    rows but all rows have NULL take_rate or all statuses are the IMM-missing
    sentinel.
*/

with latest_snapshot as (
    select max(snapshot_date) as snapshot_date
    from {{ ref('consolidated_ctb_kpi') }}
),

latest_rows as (
    select *
    from {{ ref('consolidated_ctb_kpi') }}
    where snapshot_date = (select snapshot_date from latest_snapshot)
)

select
    (select snapshot_date from latest_snapshot) as snapshot_date,
    count(*) as row_count,
    countif(take_rate is not null) as nonnull_take_rate_count,
    countif(status_6wks_outlook != 'Take Rate is Missing in IMM') as non_missing_status_count
from latest_rows
having row_count > 0
   and (
        nonnull_take_rate_count = 0
        or non_missing_status_count = 0
   )
