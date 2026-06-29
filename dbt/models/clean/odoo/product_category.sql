SELECT

    /*
        Product categories form the product hierarchy used for grouping,
        valuation settings, and stock-reporting classifications. Shared
        across all Odoo companies (no `company_id` column).
        Per-company accounting settings live in the `property_*` JSON
        columns, keyed by company id. After upstream CEE template filtering,
        any CEE-only category (e.g. ALL / Expenses, ALL / Deliveries) is
        orphaned but still present in this dimension.
    */

    /* IDS */
    id as product_category_id,
    parent_id as parent_product_category_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,
    removal_strategy_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DIMENSIONS */
    name as category_name,
    complete_name as category_full_path,
    parent_path,
    packaging_reserve_method,
    allow_negative_stock as allows_negative_stock,
    product_properties_definition as product_properties_definition_raw,
    property_stock_valuation_account_id as stock_valuation_account_property_raw,
    property_stock_account_output_categ_id as stock_account_output_category_property_raw,
    property_cost_method as cost_method_property_raw,
    safe_cast(json_value(property_cost_method, '$."1"') as string) as cost_method_ag,
    property_account_expense_categ_id as account_expense_category_property_raw,
    property_valuation as valuation_property_raw,
    safe_cast(json_value(property_valuation, '$."1"') as string) as valuation_ag,
    property_account_income_categ_id as account_income_category_property_raw,
    property_stock_account_input_categ_id as stock_account_input_category_property_raw,
    property_stock_journal as stock_journal_property_raw,
    property_stock_account_production_cost_id as stock_account_production_cost_property_raw,
    property_account_creditor_price_difference_categ as account_creditor_price_difference_category_property_raw,
    property_account_downpayment_categ_id as account_downpayment_category_property_raw,
    hs_code_id as hs_code_property_raw,
    restrict_global_discount as restricts_global_discount

FROM {{ source('odoo', 'product_category') }}
