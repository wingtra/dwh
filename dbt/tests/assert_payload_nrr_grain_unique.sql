-- Grain test: bl payload_nrr must have exactly one row per year and quarter.

select
    year,
    quarter,
    count(*) as row_count
from {{ ref('payload_nrr') }}
group by year, quarter
having count(*) > 1
