/*
    Canonical email aliases used to normalize source-system email quirks.
    One row per source-system alternate email.
*/

{{
    config(
        materialized='view',
        tags=['weekly', 'finance']
    )
}}

select
    /* IDS */
    concat(
        lower(nullif(trim(source_system), '')),
        '|',
        lower(nullif(trim(alternate_email), ''))
    ) as source_system_alternate_email,
    lower(nullif(trim(source_system), '')) as source_system,
    lower(nullif(trim(alternate_email), '')) as alternate_email,
    lower(nullif(trim(canonical_email), '')) as canonical_email,

    /* DIMENSIONS */
    nullif(trim(canonical_person), '') as canonical_person,
    nullif(trim(mapping_reason), '') as mapping_reason

from {{ ref('employee_email_aliases_seed') }}
