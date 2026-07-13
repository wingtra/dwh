-- Grain test: bl drone_nrr must have exactly one row per year and quarter.

select
    year,
    quarter,
    count(*) as row_count
from {{ ref('drone_nrr') }}
group by year, quarter
having count(*) > 1
