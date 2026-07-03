-- Grain test: bl arr_by_month_license_type must have exactly one row per
-- month and license type.

select
    month_date,
    license_type_label,
    count(*) as row_count
from {{ ref('arr_by_month_license_type') }}
group by month_date, license_type_label
having count(*) > 1
