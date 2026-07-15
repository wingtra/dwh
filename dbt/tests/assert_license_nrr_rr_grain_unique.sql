-- Grain test: bl license_nrr_rr must have exactly one row per year and quarter.

select
    year,
    quarter,
    count(*) as row_count
from {{ ref('license_nrr_rr') }}
group by year, quarter
having count(*) > 1
