with source as (
    select *
    from {{ source('hubspot', 'contacts') }}
    where _dlt_deleted_at is null
)

select
    object_id as contact_id,
    json_value(properties_json, '$.email') as email,
    json_value(properties_json, '$.firstname') as first_name,
    json_value(properties_json, '$.lastname') as last_name,
    json_value(properties_json, '$.company') as company_name,
    json_value(properties_json, '$.jobtitle') as job_title,
    json_value(properties_json, '$.lifecyclestage') as lifecycle_stage,
    json_value(properties_json, '$.hubspot_owner_id') as hubspot_owner_id,
    created_at,
    updated_at,
    archived,
    archived_at,
    last_seen_at,
    loaded_at
from source
