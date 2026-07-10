/*
    Business-layer report of AI spend.

    Grain:
    - one row per OL Revolut AI transaction leg, passed through unchanged
    - one synthetic row per active Claude Team seat per month

    Marco Schicker's Revolut payments to Anthropic are excluded from the
    passthrough rows. Claude licence cost is reported from the seat CSV instead
    at fixed CHF values, with no weighted allocation.
*/

{{
    config(
        materialized='table'
    )
}}

with

source_transactions as (
    select * from {{ ref('revolut_transactions') }}
),

claude_seat_versions as (
    select
        user_email as allocated_email,
        member_display_name as allocated_person,
        valid_from,
        valid_to,
        last_observed_snapshot_date,
        case
            when seat_tier = 'premium' then 'premium'
            else 'basic'
        end as subscription_tier
    from {{ ref('claude_seats') }}
    where is_active_member
      and is_present_in_snapshot
),

claude_snapshot_bounds as (
    select
        date_trunc(max(last_observed_snapshot_date), month) as latest_snapshot_month
    from {{ ref('claude_seats') }}
),

claude_licence_month_bounds as (
    select
        min(t.transaction_month) as first_licence_month,
        least(
            date_trunc(current_date(), month),
            greatest(
                case
                    when extract(day from current_date()) >= 16
                        then date_trunc(current_date(), month)
                    else date_sub(date_trunc(current_date(), month), interval 1 month)
                end,
                max(s.latest_snapshot_month)
            )
        ) as latest_licence_month,
        max(s.latest_snapshot_month) as latest_snapshot_month,
        max(t.source_created_at) as source_created_at,
        max(t.source_updated_at) as source_updated_at,
        max(t.source_loaded_at) as source_loaded_at
    from source_transactions t
    cross join claude_snapshot_bounds s
    where t.is_ai_spend
      and t.payer = 'Marco Schicker'
      and t.vendor = 'Anthropic'
      and t.ai_spend_type = 'subscription / seat inferred'
),

claude_licence_months as (
    select
        month_start as transaction_month,
        date_add(month_start, interval 15 day) as transaction_date,
        source_created_at,
        source_updated_at,
        source_loaded_at
    from claude_licence_month_bounds
    cross join unnest(generate_date_array(
        first_licence_month,
        latest_licence_month,
        interval 1 month
    )) as month_start
    where first_licence_month is not null
      and latest_licence_month >= first_licence_month
),

revolut_passthrough as (
    select
        transaction_leg_key,
        transaction_id,
        transaction_date,
        transaction_month,
        payer,
        payer as source_payer,
        team,
        vendor,
        ai_category,
        ai_product_family,
        ai_spend_type,
        ai_classification_confidence,
        ai_classification_evidence,
        subscription_kind,
        coalesce(subscription_kind, ai_spend_type) as subscription_type,
        cast(null as string) as subscription_tier,
        cast(null as float64) as subscription_price_chf,
        'revolut_transaction_passthrough' as allocation_rule,
        'original_revolut_transaction' as allocation_basis,
        coalesce(payer, 'Unknown') as allocated_person,
        cast(null as string) as allocated_email,
        team as allocated_team,
        1.0 as allocation_weight,
        total_amount_chf,
        total_amount_chf as allocated_amount_chf,
        source_created_at,
        source_updated_at,
        source_loaded_at
    from source_transactions
    where is_ai_spend
      and not (
        coalesce(payer, '') = 'Marco Schicker'
        and vendor = 'Anthropic'
    )
),

claude_licence_rows as (
    select
        concat(
            'claude_team_licence:',
            cast(m.transaction_month as string),
            ':',
            a.allocated_email
        ) as transaction_leg_key,
        concat('claude_team_licence:', cast(m.transaction_month as string)) as transaction_id,
        m.transaction_date,
        m.transaction_month,
        a.allocated_person as payer,
        cast(null as string) as source_payer,
        cast(null as string) as team,
        'Anthropic' as vendor,
        'LLM' as ai_category,
        'LLM' as ai_product_family,
        'subscription / seat licence estimate' as ai_spend_type,
        'high' as ai_classification_confidence,
        'Claude Team licence row generated from observed Claude seat history with fixed CHF tier prices; Marco Anthropic Revolut payments are excluded.' as ai_classification_evidence,
        'Claude Team licence' as subscription_kind,
        'Claude Team licence' as subscription_type,
        a.subscription_tier,
        case
            when a.subscription_tier = 'premium' then 125.0
            else 25.0
        end as subscription_price_chf,
        'claude_team_licence_fixed_chf' as allocation_rule,
        'ol_claude_seat_history_fixed_chf_price' as allocation_basis,
        a.allocated_person,
        a.allocated_email,
        cast(null as string) as allocated_team,
        1.0 as allocation_weight,
        cast(null as float64) as total_amount_chf,
        case
            when a.subscription_tier = 'premium' then 125.0
            else 25.0
        end as allocated_amount_chf,
        m.source_created_at,
        m.source_updated_at,
        m.source_loaded_at
    from claude_licence_months m
    join claude_seat_versions a
        on m.transaction_month >= date_trunc(a.valid_from, month)
       and (
           a.valid_to is null
           or m.transaction_month <= date_trunc(a.valid_to, month)
       )
    qualify row_number() over (
        partition by m.transaction_month, a.allocated_email
        order by a.valid_from desc
    ) = 1
),

report_rows as (
    select * from revolut_passthrough
    union all
    select * from claude_licence_rows
)

select
    /* IDS */
    to_hex(sha256(concat(
        transaction_leg_key,
        '|',
        allocation_rule,
        '|',
        coalesce(allocated_email, allocated_person)
    ))) as allocation_id,
    transaction_leg_key,
    transaction_id,

    /* DATES */
    transaction_date,
    transaction_month,

    /* REPORTING PERSON + ORIGINAL CLASSIFICATION */
    payer,
    source_payer,
    team,
    vendor,
    ai_category,
    ai_product_family,
    ai_spend_type,
    ai_classification_confidence,
    ai_classification_evidence,
    subscription_kind,
    subscription_type,
    subscription_tier,
    subscription_price_chf,

    /* BUSINESS REPORTING ATTRIBUTES */
    allocation_rule,
    allocation_basis,
    allocated_person,
    allocated_email,
    allocated_team,
    allocation_weight,

    /* MEASURES */
    total_amount_chf,
    allocated_amount_chf,

    /* PROVENANCE */
    source_created_at,
    source_updated_at,
    source_loaded_at
from report_rows
