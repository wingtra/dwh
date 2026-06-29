-- Composite uniqueness: (snapshot_date, product_reference) must be unique.
-- product_reference is unique only within a single snapshot (the table
-- appends a new snapshot per dbt run).

select snapshot_date, product_reference, count(*) as n
from {{ ref('consolidated_ctb_kpi') }}
group by snapshot_date, product_reference
having count(*) > 1
