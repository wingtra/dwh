-- Grain test: nrr_reporting must have exactly one row per year, quarter, product_type.

select
    year,
    quarter,
    product_type,
    count(*) as row_count
from {{ ref('nrr_reporting') }}
group by year, quarter, product_type
having count(*) > 1
