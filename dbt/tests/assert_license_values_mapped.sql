-- Coverage test: every counted License commission value must exist in the
-- sku_license_category_seed. A hit here = an unmapped license value silently
-- dropped from license_nrr_rr; add it to the seed.

select
    l.sku_revenue,
    count(*) as row_count
from {{ ref('commissions') }} l
left join {{ ref('sku_license_category_seed') }} c
    on l.sku_revenue = c.sku_revenue
where l.object_type = 'License'
  and l.is_counted
  and c.sku_revenue is null
group by l.sku_revenue
