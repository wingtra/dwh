-- Composite uniqueness: (snapshot_week, root_product_id,
-- component_product_id) must be unique. Components are unique only within
-- one root and one weekly snapshot.

select snapshot_week, root_product_id, component_product_id, count(*) as n
from {{ ref('bom_material_costs') }}
group by snapshot_week, root_product_id, component_product_id
having count(*) > 1
