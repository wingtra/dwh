/*
    Cleaned Revolut Business transaction legs from dl_revolut.transactions.
    DL is append-only. This model selects the latest extracted source state per
    transaction leg, parses source JSON, normalizes timestamps, and exposes
    source-conformed fields without business classification or reporting
    filters.
*/

{{
    config(
        alias='transactions',
        materialized='view'
    )
}}

with source as (
    select *
    from {{ source('dl_revolut', 'transactions') }}
    where _dlt_deleted_at is null
      and transaction_leg_key is not null
),

latest as (
    select
        *,
        row_number() over (
            partition by transaction_leg_key
            order by
                coalesce(updated_at, created_at) desc,
                created_at desc,
                loaded_at desc,
                coalesce(extracted_at, loaded_at) desc,
                coalesce(run_id, '') desc,
                row_index desc
        ) as row_num
    from source
)

select
    /* IDS */
    t.transaction_leg_key,
    t.transaction_id,
    t.leg_id,
    t.related_transaction_id,
    nullif(trim(coalesce(json_value(t.transaction_raw_json, '$.account_id'), t.account_id)), '') as account_id,
    nullif(trim(coalesce(json_value(t.leg_raw_json, '$.counterparty.account_id'), t.counterparty_account_id)), '') as counterparty_account_id,
    nullif(trim(coalesce(json_value(t.leg_raw_json, '$.counterparty.id'), t.counterparty_id)), '') as counterparty_id,

    /* TIMESTAMPS */
    t.created_at,
    t.completed_at,
    t.updated_at,
    t.loaded_at,
    t.extracted_at,
    t.request_from_created_at,
    t.request_to_created_at,
    t.page_number,
    t.row_index,
    t.run_id,
    t.gcs_uri,

    /* DATES */
    date(t.created_at) as started_date_utc,
    date(t.completed_at) as completed_date_utc,
    date(t.created_at, 'Europe/Zurich') as started_date_zurich,
    date(t.completed_at, 'Europe/Zurich') as completed_date_zurich,

    /* DIMENSIONS */
    upper(coalesce(json_value(t.transaction_raw_json, '$.type'), t.transaction_type)) as transaction_type,
    upper(coalesce(json_value(t.transaction_raw_json, '$.state'), t.transaction_state)) as transaction_state,
    nullif(trim(coalesce(json_value(t.transaction_raw_json, '$.merchant.name'), t.merchant_name)), '') as merchant_name,
    nullif(trim(json_value(t.leg_raw_json, '$.description')), '') as leg_description,
    nullif(trim(coalesce(json_value(t.leg_raw_json, '$.counterparty.description'), t.counterparty_description)), '') as counterparty_description,
    nullif(trim(coalesce(json_value(t.transaction_raw_json, '$.reference'), t.reference)), '') as transaction_reference,
    nullif(trim(json_value(t.transaction_raw_json, '$.description')), '') as transaction_description,
    nullif(trim(coalesce(json_value(t.transaction_raw_json, '$.card.first_name'), t.card_first_name)), '') as card_first_name,
    nullif(trim(coalesce(json_value(t.transaction_raw_json, '$.card.last_name'), t.card_last_name)), '') as card_last_name,
    nullif(
        trim(
            concat(
                coalesce(json_value(t.transaction_raw_json, '$.card.first_name'), t.card_first_name, ''),
                ' ',
                coalesce(json_value(t.transaction_raw_json, '$.card.last_name'), t.card_last_name, '')
            )
        ),
        ''
    ) as cardholder_name,
    nullif(trim(coalesce(json_value(t.transaction_raw_json, '$.merchant.category_code'), t.merchant_category_code)), '') as merchant_category_code,
    upper(nullif(trim(coalesce(json_value(t.leg_raw_json, '$.bill_currency'), json_value(t.transaction_raw_json, '$.currency'), t.bill_currency)), '')) as bill_currency,
    upper(nullif(trim(coalesce(json_value(t.leg_raw_json, '$.currency'), t.leg_currency)), '')) as leg_currency,
    upper(nullif(trim(coalesce(json_value(t.leg_raw_json, '$.counterparty.account_type'), t.counterparty_account_type)), '')) as counterparty_account_type,

    /* MEASURES */
    safe_cast(
        coalesce(
            cast(t.bill_amount_numeric as string),
            json_value(t.leg_raw_json, '$.bill_amount'),
            json_value(t.transaction_raw_json, '$.amount'),
            cast(t.bill_amount as string)
        ) as numeric
    ) as bill_amount_numeric,
    coalesce(
        safe_cast(json_value(t.leg_raw_json, '$.bill_amount') as float64),
        safe_cast(json_value(t.transaction_raw_json, '$.amount') as float64),
        safe_cast(t.bill_amount_numeric as float64),
        t.bill_amount
    ) as bill_amount,
    safe_cast(
        coalesce(
            cast(t.leg_amount_numeric as string),
            json_value(t.leg_raw_json, '$.amount'),
            cast(t.leg_amount as string)
        ) as numeric
    ) as leg_amount_numeric,
    coalesce(
        safe_cast(json_value(t.leg_raw_json, '$.amount') as float64),
        safe_cast(t.leg_amount_numeric as float64),
        t.leg_amount
    ) as leg_amount,
    safe_cast(
        coalesce(
            cast(t.leg_fee_numeric as string),
            json_value(t.leg_raw_json, '$.fee'),
            cast(t.leg_fee as string)
        ) as numeric
    ) as leg_fee_numeric,
    coalesce(
        safe_cast(json_value(t.leg_raw_json, '$.fee') as float64),
        safe_cast(t.leg_fee_numeric as float64),
        t.leg_fee
    ) as leg_fee,
    safe_cast(
        coalesce(
            cast(t.balance_numeric as string),
            json_value(t.leg_raw_json, '$.balance'),
            cast(t.balance as string)
        ) as numeric
    ) as balance_numeric,
    coalesce(
        safe_cast(json_value(t.leg_raw_json, '$.balance') as float64),
        safe_cast(t.balance_numeric as float64),
        t.balance
    ) as balance,

    /* RAW */
    t.transaction_raw_json,
    t.leg_raw_json

from latest t
where t.row_num = 1
