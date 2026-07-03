/*
    Typed clean deals from the HubSpot current mirror. One row per
    non-deleted deal. Dates parsed from properties_json strings (empty
    strings NULLed). Amounts kept in deal currency.
*/

with source as (
    select *
    from {{ source('hubspot', 'deals') }}
    where _dlt_deleted_at is null
)

select
    /* IDS */
    object_id as deal_id,
    json_value(properties_json, '$.pipeline') as pipeline_id,
    json_value(properties_json, '$.dealstage') as deal_stage_id,
    json_value(properties_json, '$.hubspot_owner_id') as hubspot_owner_id,

    /* DATES */
    safe.parse_date('%Y-%m-%d', nullif(left(json_value(properties_json, '$.closedate'), 10), '')) as close_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.cloud_license_start_date'), '')) as cloud_license_start_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.license_expiration_date'), '')) as license_expiration_date,
    created_at,
    updated_at,

    /* DIMENSIONS */
    json_value(properties_json, '$.dealname') as deal_name,
    json_value(properties_json, '$.dealtype') as deal_type,
    nullif(json_value(properties_json, '$.deal_currency_code'), '') as deal_currency_code,

    /* MEASURES */
    safe_cast(json_value(properties_json, '$.amount') as float64) as amount,
    safe_cast(json_value(properties_json, '$.hs_exchange_rate') as float64) as hs_exchange_rate

from source
