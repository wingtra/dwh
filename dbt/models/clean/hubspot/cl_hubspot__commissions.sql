/*
    Typed clean commissions from the HubSpot current mirror.
    One row per non-deleted commission record (custom object 2-53702763).

    A commission record is one RevOps-reviewed commissionable item (one drone,
    one payload, or one license line) with a manual Confirmed/Declined/Pending
    status and the USD sku_revenue credited to it. It is the eligibility layer
    behind the "Monthly NRR vs. RR" sheet: only Confirmed items with
    sku_revenue > 0 count toward reported revenue.

    Property quirks handled here:
    - Properties arrive inside properties_json; extracted and typed here.
    - split_deal / no_match_in_sheet / no_associated_object arrive as string
      'true'/'false'; cast to BOOL.
    - sku_type is populated for Drone records only; NULL for License/Payload.

    PROJECT POLICY (documented, not a generic report filter): restricted to
    year = 2026. The commission object was backfilled from 2026-03 and the
    Confirmed/sku_revenue logic is only valid for 2026 forward; earlier years
    are out of scope until separately modeled. See AGENTS.md "Clean Layer".
*/

with source as (
    select *
    from {{ source('hubspot', 'commissions') }}
    where _dlt_deleted_at is null
      and json_value(properties_json, '$.year') = '2026'
)

select
    /* IDS */
    object_id as commission_id,
    json_value(properties_json, '$.associated_drone_id') as drone_id,
    json_value(properties_json, '$.sales_out_deal') as sales_out_deal_id,
    json_value(properties_json, '$.hubspot_owner_id') as hubspot_owner_id,

    /* TIMESTAMPS */
    created_at,
    updated_at,

    /* DIMENSIONS */
    json_value(properties_json, '$.object_type') as object_type,
    json_value(properties_json, '$.status') as status,
    json_value(properties_json, '$.sku_type') as sku_type,
    json_value(properties_json, '$.assigned_reseller') as assigned_reseller,
    json_value(properties_json, '$.year') as commission_year,
    json_value(properties_json, '$.quarter') as commission_quarter,
    json_value(properties_json, '$.revops_notes') as revops_notes,

    /* BOOLEANS */
    coalesce(json_value(properties_json, '$.split_deal') = 'true', false) as is_split_deal,
    coalesce(json_value(properties_json, '$.no_match_in_sheet') = 'true', false) as is_no_match_in_sheet,
    coalesce(json_value(properties_json, '$.no_associated_object') = 'true', false) as is_no_associated_object,

    /* MEASURES */
    safe_cast(json_value(properties_json, '$.sku_revenue') as float64) as sku_revenue

from source
