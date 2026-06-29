/*
    Canonical product entity. One row per product variant (active or inactive).
    Public contract for SKU master queries. Wraps il_product_dimension.
*/

select

    /* IDS */
    product_id,
    product_template_id,
    product_category_id,
    uom_id,
    primary_supplier_partner_id,
    other_supplier_partner_ids,
    primary_supplier_price_currency_id,
    company_id,

    /* DATES */
    created_at,
    updated_at,

    /* DIMENSIONS */
    product_code,
    product_name,
    category_path,
    buy_sku_category,
    uom_name,
    product_type,
    product_type_label,
    product_role,
    hs_code,
    primary_supplier_name,
    responsible_name,
    scm_responsible_name,
    expert_name,
    standard_price_ag_currency,

    /* BOOLEANS */
    is_active,
    is_purchasable,
    is_saleable,
    is_storable,

    /* MEASURES */
    list_price,
    standard_price_ag,
    primary_supplier_price,
    primary_supplier_min_order_qty,
    primary_supplier_lead_time_days,
    take_rate,
    odoo_max_qty

from {{ ref('product_dimensions') }}
