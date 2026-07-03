/*
    Typed clean line items from the HubSpot current mirror. One row per
    non-deleted line item. Amounts kept in line-item currency.
*/

with source as (
    select *
    from {{ source('hubspot', 'line_items') }}
    where _dlt_deleted_at is null
)

select
    /* IDS */
    object_id as line_item_id,
    json_value(properties_json, '$.hs_product_id') as product_id,

    /* DATES */
    created_at,
    updated_at,

    /* DIMENSIONS */
    json_value(properties_json, '$.name') as line_item_name,
    json_value(properties_json, '$.hs_sku') as sku,
    nullif(json_value(properties_json, '$.hs_line_item_currency_code'), '') as line_item_currency_code,
    json_value(properties_json, '$.recurringbillingfrequency') as recurring_billing_frequency,

    /* MEASURES */
    safe_cast(json_value(properties_json, '$.quantity') as float64) as quantity,
    safe_cast(json_value(properties_json, '$.price') as float64) as price,
    safe_cast(json_value(properties_json, '$.amount') as float64) as amount,
    safe_cast(json_value(properties_json, '$.discount') as float64) as discount

from source
