/*
    Current cleaned Anthropic Claude Team members from the latest dated seed
    export.

    This is the authoritative seat list for Marco Schicker's Claude Team
    licence allocation. Use only active members for licence cost allocation;
    pending members remain visible for audit.
*/

with

source as (
    select * from {{ ref('claude_member_snapshots') }}
)

select
    /* IDS */
    user_email,
    source_user_email,

    /* DATES */
    snapshot_date as export_date,

    /* DIMENSIONS */
    source_member_name,
    member_display_name,
    member_role,
    member_status,
    seat_tier,
    is_active_member

from source
qualify snapshot_date = max(snapshot_date) over ()
