/*
    Cleaned Revolut Business accounts from dl_revolut.accounts.
    DL is append-only. This model selects the latest extracted source state per
    Revolut account, then type-normalizes and renames source fields.
*/

{{
    config(
        alias='accounts',
        materialized='view'
    )
}}

with source as (
    select *
    from {{ source('dl_revolut', 'accounts') }}
    where account_id is not null
),

latest as (
    select
        *,
        row_number() over (
            partition by account_id
            order by
                coalesce(updated_at, created_at, loaded_at) desc,
                loaded_at desc,
                coalesce(extracted_at, loaded_at) desc,
                coalesce(run_id, '') desc
        ) as row_num
    from source
)

select
    /* IDS */
    account_id,

    /* TIMESTAMPS */
    created_at,
    updated_at,
    loaded_at,
    extracted_at,
    run_id,
    gcs_uri,

    /* DIMENSIONS */
    nullif(trim(name), '') as account_name,
    upper(nullif(trim(currency), '')) as account_currency,
    upper(nullif(trim(state), '')) as account_state,

    /* BOOLEANS */
    is_public,

    /* MEASURES */
    safe_cast(coalesce(cast(balance_numeric as string), cast(balance as string)) as numeric) as balance_numeric,
    coalesce(safe_cast(balance_numeric as float64), balance) as balance,

    /* RAW */
    account_raw_json

from latest
where row_num = 1
