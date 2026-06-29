/*
    Object-layer history of Anthropic Claude Team seats.

    Grain: one row per member seat-state version. A new version starts when a
    member first appears, when role/status/tier changes, or when a member is
    absent from a later snapshot and is therefore observed as removed.
*/

{{
    config(
        materialized='table'
    )
}}

with

snapshots as (
    select * from {{ ref('claude_member_snapshots') }}
),

snapshot_dates as (
    select distinct snapshot_date
    from snapshots
),

members as (
    select
        user_email,
        min(snapshot_date) as first_seen_export_date,
        max(snapshot_date) as last_seen_export_date
    from snapshots
    group by user_email
),

member_snapshot_grid as (
    select
        m.user_email,
        d.snapshot_date,
        m.first_seen_export_date,
        m.last_seen_export_date
    from members m
    join snapshot_dates d
        on d.snapshot_date >= m.first_seen_export_date
),

observed_states as (
    select
        g.user_email,
        g.snapshot_date,
        g.first_seen_export_date,
        g.last_seen_export_date,
        s.source_user_email,
        s.source_member_name,
        s.member_display_name,
        s.member_role,
        case
            when s.user_email is null then 'removed'
            else lower(s.member_status)
        end as member_status,
        case
            when s.user_email is null then cast(null as string)
            else s.seat_tier
        end as seat_tier,
        coalesce(s.is_active_member, false) as is_active_member,
        s.user_email is not null as is_present_in_snapshot
    from member_snapshot_grid g
    left join snapshots s
        on s.user_email = g.user_email
       and s.snapshot_date = g.snapshot_date
),

filled_states as (
    select
        user_email,
        snapshot_date,
        first_seen_export_date,
        last_seen_export_date,
        last_value(source_user_email ignore nulls) over member_window as source_user_email,
        last_value(source_member_name ignore nulls) over member_window as source_member_name,
        last_value(member_display_name ignore nulls) over member_window as member_display_name,
        member_role,
        member_status,
        seat_tier,
        is_active_member,
        is_present_in_snapshot
    from observed_states
    window member_window as (
        partition by user_email
        order by snapshot_date
        rows between unbounded preceding and current row
    )
),

state_keys as (
    select
        *,
        to_hex(sha256(concat(
            coalesce(member_role, ''),
            '|',
            coalesce(member_status, ''),
            '|',
            coalesce(seat_tier, ''),
            '|',
            cast(is_present_in_snapshot as string)
        ))) as state_key
    from filled_states
),

version_starts as (
    select
        *,
        case
            when lag(state_key) over member_order is null then 1
            when state_key != lag(state_key) over member_order then 1
            else 0
        end as is_new_version
    from state_keys
    window member_order as (
        partition by user_email
        order by snapshot_date
    )
),

versioned as (
    select
        *,
        sum(is_new_version) over (
            partition by user_email
            order by snapshot_date
            rows between unbounded preceding and current row
        ) as seat_version_number
    from version_starts
),

collapsed as (
    select
        user_email,
        seat_version_number,
        min(snapshot_date) as valid_from,
        max(snapshot_date) as last_observed_snapshot_date,
        any_value(first_seen_export_date) as first_seen_export_date,
        any_value(last_seen_export_date) as last_seen_export_date,
        any_value(source_user_email) as source_user_email,
        any_value(source_member_name) as source_member_name,
        any_value(member_display_name) as member_display_name,
        any_value(member_role) as member_role,
        any_value(member_status) as member_status,
        any_value(seat_tier) as seat_tier,
        any_value(is_active_member) as is_active_member,
        any_value(is_present_in_snapshot) as is_present_in_snapshot
    from versioned
    group by user_email, seat_version_number
),

with_next_version as (
    select
        *,
        lead(valid_from) over (
            partition by user_email
            order by seat_version_number
        ) as next_valid_from
    from collapsed
),

with_previous_version as (
    select
        *,
        lag(member_role) over member_version_order as previous_member_role,
        lag(member_status) over member_version_order as previous_member_status,
        lag(seat_tier) over member_version_order as previous_seat_tier,
        lag(is_present_in_snapshot) over member_version_order as was_present_in_previous_version
    from with_next_version
    window member_version_order as (
        partition by user_email
        order by seat_version_number
    )
)

select
    /* IDS */
    to_hex(sha256(concat(
        user_email,
        '|',
        cast(seat_version_number as string),
        '|',
        cast(valid_from as string)
    ))) as claude_seat_version_id,
    user_email,
    source_user_email,

    /* DATES */
    valid_from,
    case
        when next_valid_from is null then cast(null as date)
        else date_sub(next_valid_from, interval 1 day)
    end as valid_to,
    next_valid_from is null as is_current,
    first_seen_export_date,
    last_seen_export_date,
    last_observed_snapshot_date,

    /* DIMENSIONS */
    member_display_name,
    source_member_name,
    member_role,
    member_status,
    seat_tier,
    is_active_member,
    is_present_in_snapshot,
    case
        when not is_present_in_snapshot then 'removed'
        when seat_version_number = 1 then 'added'
        when coalesce(seat_tier, '') != coalesce(previous_seat_tier, '') then 'seat_tier_changed'
        when coalesce(member_status, '') != coalesce(previous_member_status, '') then 'status_changed'
        when coalesce(member_role, '') != coalesce(previous_member_role, '') then 'role_changed'
        else 'unchanged'
    end as seat_change_type,
    previous_member_role,
    previous_member_status,
    previous_seat_tier,
    was_present_in_previous_version,

    /* MEASURES */
    case
        when not is_active_member then 0.0
        when seat_tier = 'premium' then 125.0
        when seat_tier = 'standard' then 25.0
        else 0.0
    end as monthly_licence_price_chf

from with_previous_version
