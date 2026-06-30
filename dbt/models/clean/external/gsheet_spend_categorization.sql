/*
    Cleaned Spend Categorization 2026 sheet, tab "SpendxComplexity".
    One row per BUY SKU with Kraljic strategic-sourcing class plus annualised
    spend, take-rate, and complexity score as maintained by the SC team.
    Filters out empty trailer rows and casts the federated table's all-STRING
    columns into typed values. Percent strings ('10.92%') and comma-formatted
    numerics ('66,729.06') are normalised before SAFE_CAST.

    Source sheet:
    https://docs.google.com/spreadsheets/d/15BrVj1Ht5SehrzaGY5VtcNZza4RW1690MgbiUsaDsL8/edit
*/

with

source as (
    select * from {{ source('external', 'gsheet_spend_categorization') }}
    where odoo_pn is not null
      and trim(odoo_pn) != ''
)

select
    /* IDS */
    trim(odoo_pn) as product_code,

    /* DIMENSIONS */
    product_name,
    product_type as sheet_product_type,
    supplier as supplier_name,
    currency as unit_price_currency,
    spend_abc,
    category_strategy as buy_sku_category,

    /* MEASURES */
    safe_cast(replace(consolidated_tr_text,         ',', '') as float64) as consolidated_take_rate,
    safe_cast(replace(unit_price_text,              ',', '') as float64) as unit_price,
    safe_cast(replace(unit_price_chf_text,          ',', '') as float64) as unit_price_chf,
    safe_cast(replace(annualised_spend_chf_text,    ',', '') as float64) as annualised_spend_chf,
    safe_cast(replace(replace(pct_of_total_text,            '%', ''), ',', '') as float64) / 100 as pct_of_total,
    safe_cast(replace(replace(cumulative_pct_of_total_text, '%', ''), ',', '') as float64) / 100 as cumulative_pct_of_total,
    safe_cast(replace(complexity_score_text,        ',', '') as float64) as complexity_score

from source
