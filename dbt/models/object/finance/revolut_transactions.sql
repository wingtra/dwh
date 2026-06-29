/*
    Revolut transactions. One row per completed Revolut transaction leg from
    2026 onward. This layer owns reporting payer/description selection, AI
    classification, the is_ai_spend flag, and CHF reporting amounts.
*/

{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='transaction_leg_key',
        on_schema_change='sync_all_columns'
    )
}}

with

prepared as (
    select
        t.transaction_leg_key,
        t.transaction_id,
        t.completed_date_zurich as transaction_date,
        date_trunc(t.completed_date_zurich, month) as transaction_month,
        t.created_at as source_created_at,
        t.updated_at as source_updated_at,
        t.loaded_at as source_loaded_at,
        nullif(trim(t.cardholder_name), '') as payer,
        r.team,
        nullif(
            trim(
                coalesce(
                    t.merchant_name,
                    t.leg_description,
                    t.counterparty_description,
                    t.transaction_reference,
                    t.transaction_description
                )
            ),
            ''
        ) as description,
        a.account_name as account,
        a.account_currency,
        t.transaction_type,
        t.transaction_state,
        t.merchant_category_code as mcc,
        coalesce(t.bill_currency, t.leg_currency) as orig_currency,
        t.leg_currency as payment_currency,
        t.bill_amount as orig_amount,
        t.leg_amount as amount,
        coalesce(t.leg_amount, 0) + coalesce(t.leg_fee, 0) as total_amount,
        t.leg_fee as fee
    from {{ ref('cl_revolut__transactions') }} t
    left join {{ ref('cl_revolut__accounts') }} a
        on a.account_id = t.account_id
    left join {{ ref('revolut_cardholder_team_mapping') }} r
        on r.cardholder_name = nullif(trim(t.cardholder_name), '')
    where t.transaction_state = 'COMPLETED'
      and t.completed_date_zurich >= date('2026-01-01')
    {% if is_incremental() %}
      and t.created_at >= (
          select coalesce(
              timestamp_sub(max(source_created_at), interval 31 day),
              timestamp('2026-01-01 00:00:00+00')
          )
          from {{ this }}
      )
    {% endif %}
),

amounted as (
    select
        *,
        round(
            total_amount * case payment_currency
                when 'CHF' then 1.0
                when 'USD' then 0.84
                when 'EUR' then 0.94
                when 'GBP' then 1.10
                else null
            end,
            2
        ) as total_amount_chf_source_sign
    from prepared
),

classified as (
    select
        *,

        case
            when regexp_contains(lower(description), r'chatgpt writer') then 'ChatGPT Writer'
            when regexp_contains(lower(description), r'openai|chatgpt|gpt[- ]?[345]') then 'OpenAI'
            when regexp_contains(lower(description), r'^anthropic|^claude$|claude\.ai|claude by anth|claude team|anthropic ireland') then 'Anthropic'
            when regexp_contains(lower(description), r'perplexity') then 'Perplexity'
            when regexp_contains(lower(description), r'^cursor$|cursor,?\s*ai|cursor usage|refund from cursor') then 'Cursor'
            when regexp_contains(lower(description), r'hugging[ -]?face|huggingface') then 'Hugging Face'
            when regexp_contains(lower(description), r'^manus ai') then 'Manus AI'
            when regexp_contains(lower(description), r'cognition labs|devin') then 'Cognition Labs (Devin)'
            when regexp_contains(lower(description), r'^lovable') then 'Lovable.dev'
            when regexp_contains(lower(description), r'elevenlabs') then 'ElevenLabs'
            when regexp_contains(lower(description), r'midjourney') then 'Midjourney'
            when regexp_contains(lower(description), r'heygen') then 'HeyGen'
            when regexp_contains(lower(description), r'synthesia') then 'Synthesia'
            when regexp_contains(lower(description), r'otter\.ai|refund from otter') then 'Otter.ai'
            when regexp_contains(lower(description), r'^whisperai$|whisper\.ai') then 'WhisperAI'
            when regexp_contains(lower(description), r'invideo innovation') then 'InVideo'
            when regexp_contains(lower(description), r'beautiful\.ai') then 'Beautiful.ai'
            when regexp_contains(lower(description), r'^descript$') then 'Descript'
            when regexp_contains(lower(description), r'veed limited|veed\.io') then 'Veed.io'
            when regexp_contains(lower(description), r'dream studio|stability') then 'Stability AI (DreamStudio)'
            when regexp_contains(lower(description), r'transcribetotext\.ai') then 'Transcribetotext.ai'
            when regexp_contains(lower(description), r'www\.coursebox\.ai') then 'Coursebox AI'
            when regexp_contains(lower(description), r'gumshoe ai') then 'Gumshoe AI'
            else null
        end as vendor,

        case
            when regexp_contains(lower(description), r'chatgpt writer') then 'AI Tool'
            when regexp_contains(lower(description), r'openai|gpt[- ]?[345]') then 'LLM'
            when regexp_contains(lower(description), r'^anthropic|^claude$|claude\.ai|claude by anth|claude team|anthropic ireland') then 'LLM'
            when regexp_contains(lower(description), r'perplexity') then 'LLM'
            when regexp_contains(lower(description), r'^cursor$|cursor,?\s*ai|cursor usage|refund from cursor') then 'AI Tool'
            when regexp_contains(lower(description), r'hugging[ -]?face|huggingface') then 'AI Tool'
            when regexp_contains(lower(description), r'^manus ai') then 'AI Tool'
            when regexp_contains(lower(description), r'cognition labs|devin') then 'AI Tool'
            when regexp_contains(lower(description), r'^lovable') then 'AI Tool'
            when regexp_contains(lower(description), r'elevenlabs') then 'AI Tool'
            when regexp_contains(lower(description), r'midjourney') then 'AI Tool'
            when regexp_contains(lower(description), r'heygen') then 'AI Tool'
            when regexp_contains(lower(description), r'synthesia') then 'AI Tool'
            when regexp_contains(lower(description), r'otter\.ai|refund from otter') then 'AI Tool'
            when regexp_contains(lower(description), r'^whisperai$|whisper\.ai') then 'AI Tool'
            when regexp_contains(lower(description), r'invideo innovation') then 'AI Tool'
            when regexp_contains(lower(description), r'beautiful\.ai') then 'AI Tool'
            when regexp_contains(lower(description), r'^descript$') then 'AI Tool'
            when regexp_contains(lower(description), r'veed limited|veed\.io') then 'AI Tool'
            when regexp_contains(lower(description), r'dream studio|stability') then 'AI Tool'
            when regexp_contains(lower(description), r'transcribetotext\.ai') then 'AI Tool'
            when regexp_contains(lower(description), r'www\.coursebox\.ai') then 'AI Tool'
            when regexp_contains(lower(description), r'gumshoe ai') then 'AI Tool'
            else null
        end as ai_category,

        case
            when regexp_contains(lower(description), r'chatgpt writer') then 'AI Tool'
            when regexp_contains(lower(description), r'openai|gpt[- ]?[345]') then 'LLM'
            when regexp_contains(lower(description), r'^anthropic|^claude$|claude\.ai|claude by anth|claude team|anthropic ireland') then 'LLM'
            when regexp_contains(lower(description), r'perplexity') then 'LLM'
            when regexp_contains(lower(description), r'^cursor$|cursor,?\s*ai|cursor usage|refund from cursor') then 'AI Tool'
            when regexp_contains(lower(description), r'hugging[ -]?face|huggingface') then 'AI Tool'
            when regexp_contains(lower(description), r'^manus ai|cognition labs|devin|^lovable|elevenlabs|midjourney|heygen|synthesia|otter\.ai|refund from otter|^whisperai$|whisper\.ai|invideo innovation|beautiful\.ai|^descript$|veed limited|veed\.io|dream studio|stability|transcribetotext\.ai|www\.coursebox\.ai|gumshoe ai') then 'AI Tool'
            else null
        end as ai_product_family,

        case
            when (
                regexp_contains(lower(description), r'openai|chatgpt|gpt[- ]?[345]|^anthropic|^claude$|claude\.ai|perplexity|^cursor$|cursor,?\s*ai|cursor usage|refund from cursor|hugging[ -]?face|huggingface|^manus ai|cognition labs|devin|^lovable|elevenlabs|midjourney|heygen|synthesia|otter\.ai|refund from otter|^whisperai$|whisper\.ai|invideo innovation|beautiful\.ai|^descript$|veed limited|veed\.io|dream studio|stability|transcribetotext\.ai|www\.coursebox\.ai|gumshoe ai')
                and abs(total_amount) = 0
            ) then 'authorization'
            when regexp_contains(lower(description), r'^claude$|claude\.ai|perplexity') then 'subscription / seat'
            when regexp_contains(lower(description), r'^openai$') and round(abs(total_amount), 2) between 18 and 24 then 'subscription / seat inferred'
            when regexp_contains(lower(description), r'^openai$') then 'API / usage / credits inferred'
            when regexp_contains(lower(description), r'^anthropic$|^anthropic ireland$') and round(abs(total_amount), 2) between 18 and 24 then 'subscription / seat inferred'
            when regexp_contains(lower(description), r'^anthropic$|^anthropic ireland$') then 'API / usage / credits inferred'
            when regexp_contains(lower(description), r'hugging[ -]?face|huggingface') then 'compute / usage inferred'
            when regexp_contains(lower(description), r'^cursor$|cursor usage') and round(abs(total_amount), 2) in (2.63, 5.81, 10.00, 13.66) then 'usage / overage inferred'
            when regexp_contains(lower(description), r'dream studio|stability') then 'credits'
            when regexp_contains(lower(description), r'openai \*chatgpt subscr|google.*chatgpt|chatgpt writer|anthropic: claude team|google claude by anth|^cursor$|cursor,?\s*ai|^manus ai|cognition labs|devin|^lovable|elevenlabs|midjourney|heygen|synthesia|otter\.ai|^whisperai$|whisper\.ai|invideo innovation|beautiful\.ai|^descript$|veed limited|veed\.io|transcribetotext\.ai|www\.coursebox\.ai|gumshoe ai') then 'subscription / seat inferred'
            else null
        end as ai_spend_type,

        case
            when not regexp_contains(lower(description), r'openai|chatgpt|gpt[- ]?[345]|^anthropic|^claude$|claude\.ai|perplexity|^cursor$|cursor,?\s*ai|cursor usage|refund from cursor|hugging[ -]?face|huggingface|^manus ai|cognition labs|devin|^lovable|elevenlabs|midjourney|heygen|synthesia|otter\.ai|refund from otter|^whisperai$|whisper\.ai|invideo innovation|beautiful\.ai|^descript$|veed limited|veed\.io|dream studio|stability|transcribetotext\.ai|www\.coursebox\.ai|gumshoe ai') then null
            when regexp_contains(lower(description), r'^claude$|claude\.ai|perplexity|dream studio|stability') then 'high'
            when abs(total_amount) = 0 then 'high'
            when regexp_contains(lower(description), r'^openai$|^anthropic$|^anthropic ireland$|hugging[ -]?face|huggingface|^cursor$') then 'medium'
            when regexp_contains(lower(description), r'inferred') then 'medium'
            else 'high'
        end as ai_classification_confidence,

        case
            when not regexp_contains(lower(description), r'openai|chatgpt|gpt[- ]?[345]|^anthropic|^claude$|claude\.ai|perplexity|^cursor$|cursor,?\s*ai|cursor usage|refund from cursor|hugging[ -]?face|huggingface|^manus ai|cognition labs|devin|^lovable|elevenlabs|midjourney|heygen|synthesia|otter\.ai|refund from otter|^whisperai$|whisper\.ai|invideo innovation|beautiful\.ai|^descript$|veed limited|veed\.io|dream studio|stability|transcribetotext\.ai|www\.coursebox\.ai|gumshoe ai') then null
            when abs(total_amount) = 0 then 'merchant_description + zero_amount_authorization'
            when regexp_contains(lower(description), r'^openai$|^anthropic$|^anthropic ireland$|hugging[ -]?face|huggingface|^cursor$') then 'merchant_description + amount_pattern'
            else 'merchant_description'
        end as ai_classification_evidence,

        case
            when regexp_contains(lower(description), r'chatgpt writer') then 'ChatGPT Writer subscription'
            when regexp_contains(lower(description), r'openai|chatgpt')
                and round(abs(total_amount_chf_source_sign), 2) between 19 and 21
                then 'ChatGPT Plus'
            when regexp_contains(lower(description), r'openai \*chatgpt subscr') then 'ChatGPT Plus / Team subscription'
            when regexp_contains(lower(description), r'openai\* chatgpt credit') then 'ChatGPT credits top-up'
            when regexp_contains(lower(description), r'google.*chatgpt') then 'ChatGPT mobile (Google Play)'
            when regexp_contains(lower(description), r'^openai$') and round(abs(total_amount), 2) between 18 and 24 then 'ChatGPT subscription / seat inferred'
            when regexp_contains(lower(description), r'^openai$') then 'OpenAI API / usage credits inferred'
            when regexp_contains(lower(description), r'claude\.ai subscription') then 'Claude Pro (consumer)'
            when regexp_contains(lower(description), r'anthropic: claude team') then 'Claude Team plan'
            when regexp_contains(lower(description), r'google claude by anth') then 'Claude mobile (Google Play)'
            when regexp_contains(lower(description), r'^claude$|claude\.ai') then 'Claude subscription / seat'
            when regexp_contains(lower(description), r'^anthropic$|^anthropic ireland$') and round(abs(total_amount), 2) between 18 and 24 then 'Claude subscription / seat inferred'
            when regexp_contains(lower(description), r'^anthropic$|^anthropic ireland$') then 'Anthropic API / usage credits inferred'
            when regexp_contains(lower(description), r'perplexity') then 'Perplexity Pro'
            when regexp_contains(lower(description), r'^cursor$') and round(abs(total_amount), 2) in (2.63, 5.81, 10.00, 13.66) then 'Cursor metered usage overage'
            when regexp_contains(lower(description), r'^cursor$') then 'Cursor IDE seat (Pro/Business)'
            when regexp_contains(lower(description), r'cursor,?\s*ai powered ide') then 'Cursor IDE seat (Pro/Business)'
            when regexp_contains(lower(description), r'refund from cursor') then 'Cursor refund'
            when regexp_contains(lower(description), r'cursor usage') then 'Cursor metered usage overage'
            when regexp_contains(lower(description), r'hugging[ -]?face|huggingface') then 'Hugging Face compute / usage inferred'
            when regexp_contains(lower(description), r'^manus ai$') then 'Manus AI agent subscription'
            when regexp_contains(lower(description), r'cognition labs') then 'Devin (Cognition) subscription'
            when regexp_contains(lower(description), r'^lovable$') then 'Lovable.dev subscription'
            when regexp_contains(lower(description), r'elevenlabs\.io') then 'ElevenLabs voice subscription'
            when regexp_contains(lower(description), r'midjourney inc') then 'Midjourney subscription'
            when regexp_contains(lower(description), r'heygen technology inc') then 'HeyGen avatar subscription'
            when regexp_contains(lower(description), r'synthesia limited') then 'Synthesia subscription'
            when regexp_contains(lower(description), r'otter\.ai') then 'Otter.ai transcription subscription'
            when regexp_contains(lower(description), r'refund from otter') then 'Otter.ai refund'
            when regexp_contains(lower(description), r'^whisperai$|whisper\.ai') then 'WhisperAI transcription subscription'
            when regexp_contains(lower(description), r'invideo innovation') then 'InVideo AI subscription'
            when regexp_contains(lower(description), r'beautiful\.ai') then 'Beautiful.ai Pro'
            when regexp_contains(lower(description), r'^descript$') then 'Descript subscription'
            when regexp_contains(lower(description), r'veed limited|veed\.io') then 'Veed.io subscription'
            when regexp_contains(lower(description), r'dream studio|stability') then 'DreamStudio (Stability AI) credits'
            when regexp_contains(lower(description), r'transcribetotext\.ai') then 'Transcribetotext.ai subscription'
            when regexp_contains(lower(description), r'www\.coursebox\.ai') then 'Coursebox AI subscription'
            when regexp_contains(lower(description), r'gumshoe ai') then 'Gumshoe AI subscription'
            else null
        end as subscription_kind
    from amounted
)

select
    /* IDS */
    transaction_leg_key,
    transaction_id,

    /* DATES */
    transaction_date,
    transaction_month,

    /* DIMENSIONS */
    payer,
    team,
    description,
    account,
    account_currency,
    transaction_type,
    mcc,
    ai_category,
    ai_product_family,
    ai_spend_type,
    ai_classification_confidence,
    ai_classification_evidence,
    vendor,
    subscription_kind,

    /* BOOLEANS */
    vendor is not null as is_ai_spend,

    /* MEASURES - sign-flipped so spend is positive and refunds negative */
    orig_amount,
    orig_currency,
    amount,
    payment_currency,
    fee,
    round(-1 * total_amount_chf_source_sign, 2) as total_amount_chf,

    /* PROVENANCE */
    source_created_at,
    source_updated_at,
    source_loaded_at
from classified
