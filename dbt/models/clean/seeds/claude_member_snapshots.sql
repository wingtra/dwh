/*
    Cleaned Anthropic Claude Team member snapshots from dated dbt seed exports.

    Add every new Anthropic members export here as an append-only snapshot.
    Downstream object models derive additions, seat-tier changes, status
    changes, and removals by comparing consecutive snapshot dates.
*/

with

source as (
    select * from {{ ref('claude_members_2026_06_18') }}
    union all
    select * from {{ ref('claude_members_2026_06_23') }}
    union all
    select * from {{ ref('claude_members_2026_07_02') }}
),

normalized as (
    select
        s.*,
        lower(nullif(trim(s.user_email), '')) as source_user_email
    from source s
)

select
    /* IDS */
    coalesce(a.canonical_email, n.source_user_email) as user_email,
    n.source_user_email,

    /* DATES */
    n.export_date as snapshot_date,

    /* DIMENSIONS */
    nullif(n.member_name, '') as source_member_name,
    coalesce(
        a.canonical_person,
        initcap(replace(split(n.source_user_email, '@')[offset(0)], '.', ' '))
    ) as member_display_name,
    n.member_role,
    n.member_status,
    lower(n.seat_tier) as seat_tier,
    lower(n.member_status) = 'active' as is_active_member

from normalized n
left join {{ ref('employee_email_aliases') }} a
    on a.source_system = 'anthropic_claude'
   and a.alternate_email = n.source_user_email
