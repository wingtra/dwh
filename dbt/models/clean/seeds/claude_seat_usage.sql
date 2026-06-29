/*
    Cleaned Anthropic Claude per-seat usage from dbt seed exports.

    One row per (user, product, model, report period). Currently sourced from
    a single May 2026 seed; union additional monthly seed exports here when
    they are added.
*/

with

source as (
    select * from {{ ref('claude_seat_usage_2026_05') }}
),

normalized as (
    select
        s.*,
        lower(nullif(trim(s.user_email), '')) as source_user_email
    from source s
)

select
    /* IDS */
    n.user_id,
    coalesce(a.canonical_email, n.source_user_email) as user_email,
    n.source_user_email,
    n.account_uuid,

    /* DATES */
    n.report_period_start,
    n.report_period_end,

    /* DIMENSIONS */
    n.product,
    n.model,

    /* MEASURES */
    n.total_requests,
    n.total_prompt_tokens,
    n.total_completion_tokens,
    n.total_uncached_input_tokens,
    n.total_cache_read_tokens,
    n.total_cache_write_5m_tokens,
    n.total_cache_write_1h_tokens,
    n.total_web_search_count,
    n.total_net_spend_usd,
    n.total_gross_spend_usd

from normalized n
left join {{ ref('employee_email_aliases') }} a
    on a.source_system = 'anthropic_claude'
   and a.alternate_email = n.source_user_email
