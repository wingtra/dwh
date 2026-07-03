/*
    Typed clean licences from the HubSpot current mirror.
    One row per non-deleted licence record.

    Property quirks handled here:
    - Dates arrive as strings inside properties_json; empty strings are
      NULLed before parsing.
    - The "Recurring Revenue Amount Net (USD)" property is in DEAL currency
      for EUR/CHF licences despite its label; exposed as
      recurring_revenue_amount_source with recurring_revenue_currency
      alongside. USD conversion happens downstream with meta FX rates.
    - The Type enum internal value "Blue Licence" is what the HubSpot UI and
      the RevOps reports label "WingtraPilot BLU"; both are exposed.
*/

with source as (
    select *
    from {{ source('hubspot', 'licences') }}
    where _dlt_deleted_at is null
)

select
    /* IDS */
    object_id as licence_id,
    json_value(properties_json, '$.associated_deal_id') as deal_id,
    json_value(properties_json, '$.associated_drone_id') as drone_id,
    json_value(properties_json, '$.hubspot_owner_id') as hubspot_owner_id,

    /* DATES / TIMESTAMPS */
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.warranty_service_start_date'), '')) as warranty_service_start_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.expiration_date'), '')) as warranty_service_expiration_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.blu_end_date'), '')) as blu_end_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.activation_date'), '')) as activation_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.first_drone_configuration_date'), '')) as first_drone_configuration_date,
    safe.parse_date('%Y-%m-%d', nullif(json_value(properties_json, '$.last_drone_configuration_date'), '')) as last_drone_configuration_date,
    created_at,
    updated_at,

    /* DIMENSIONS */
    json_value(properties_json, '$.type') as licence_type_raw,
    case json_value(properties_json, '$.type')
        when 'Blue Licence' then 'WingtraPilot BLU'
        else json_value(properties_json, '$.type')
    end as licence_type_label,
    json_value(properties_json, '$.license_type') as licence_type_detail,
    json_value(properties_json, '$.sku') as sku,
    nullif(json_value(properties_json, '$.associated_deal_currency'), '') as recurring_revenue_currency,
    json_value(properties_json, '$.associated_deal_name') as deal_name,
    json_value(properties_json, '$.company_from_activation') as company_from_activation,
    json_value(properties_json, '$.associated_company') as associated_company,
    json_value(properties_json, '$.country') as country,
    json_value(properties_json, '$.current_status') as current_status,
    json_value(properties_json, '$.billing_frequency') as billing_frequency,
    json_value(properties_json, '$.hs_pipeline_stage') as pipeline_stage_id,

    /* BOOLEANS */
    json_value(properties_json, '$.exclude_license_from_the_main_arr_workflow') is not null as is_excluded_from_arr_workflow,
    json_value(properties_json, '$.is_legacy_license') is not null as is_legacy_licence,

    /* MEASURES */
    safe_cast(json_value(properties_json, '$.recurring_revenue_amount_net__usd_') as float64) as recurring_revenue_amount_source,
    safe_cast(json_value(properties_json, '$.corrected_recurring_revenue_usd') as float64) as corrected_recurring_revenue_amount_source,
    safe_cast(json_value(properties_json, '$.number_of_billing_cycles') as float64) as number_of_billing_cycles,
    safe_cast(json_value(properties_json, '$.license_renewal_count') as float64) as licence_renewal_count,
    safe_cast(json_value(properties_json, '$.license_validity__years_') as float64) as licence_validity_years

from source
