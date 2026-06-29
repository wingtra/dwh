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

claude_active_members as (
    select
        user_email as allocated_email,
        member_display_name as allocated_person,
        case
            when seat_tier = 'premium' then 'premium'
            else 'basic'
        end as subscription_tier
    from {{ ref('claude_members') }}
    where is_active_member
),

claude_licence_month_bounds as (
    select
        min(transaction_month) as first_licence_month,
        case
            when extract(day from current_date()) >= 16
                then date_trunc(current_date(), month)
            else date_sub(date_trunc(current_date(), month), interval 1 month)
        end as latest_licence_month,
        max(source_created_at) as source_created_at,
        max(source_updated_at) as source_updated_at,
        max(source_loaded_at) as source_loaded_at
    from source_transactions
    where is_ai_spend
      and payer = 'Marco Schicker'
      and vendor = 'Anthropic'
      and ai_spend_type = 'subscription / seat inferred'
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
        'Claude Team licence row generated from the active Claude members seed with fixed CHF tier prices; Marco Anthropic Revolut payments are excluded.' as ai_classification_evidence,
        'Claude Team licence' as subscription_kind,
        'Claude Team licence' as subscription_type,
        a.subscription_tier,
        case
            when a.subscription_tier = 'premium' then 125.0
            else 25.0
        end as subscription_price_chf,
        'claude_team_licence_fixed_chf' as allocation_rule,
        'active_claude_members_seed_fixed_chf_price' as allocation_basis,
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
    cross join claude_active_members a
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
