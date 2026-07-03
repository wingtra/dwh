-- Grain test: il arr_licence_months_recognized must have exactly one row per
-- licence and month.

select
    licence_id,
    month_date,
    count(*) as row_count
from {{ ref('arr_licence_months_recognized') }}
group by licence_id, month_date
having count(*) > 1
