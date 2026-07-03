/*
    RevOps ARR accrual rule reference. One row per product family.
    Source: Stephanie Lambert's guideline table (screenshot from Alex,
    2026-07-03) plus Alex's chat explanation. Documents which HubSpot object
    carries each product, what triggers commission, and how ARR accrues.
*/

{{
    config(
        materialized='view',
        tags=['daily', 'revops']
    )
}}

select
    /* DIMENSIONS */
    product,
    hubspot_object,
    commission_trigger,
    arr_accrual_rule,

    /* BOOLEANS */
    is_in_arr

from {{ ref('arr_accrual_rules_seed') }}
