/*
    Cleaned Revolut Business expenses from dl_revolut.expenses.
    DL is append-only. The Expenses API has no update timestamp, so the latest
    extraction is the current source snapshot for each expense. This model
    normalizes source fields and retains the source JSON; it does not join or
    reshape the transaction fact.

    Materialized as a table (unlike the sibling views): every loader run
    re-appends the full expense history, so the DL log grows with each run and
    a view would re-run the dedup window over the whole log on every query.
*/

{{
    config(
        alias='expenses',
        materialized='table'
    )
}}

with source as (
    select *
    from {{ source('dl_revolut', 'expenses') }}
    where _dlt_deleted_at is null
      and expense_id is not null
),

latest as (
    select
        *,
        row_number() over (
            partition by expense_id
            order by
                loaded_at desc,
                extracted_at desc,
                coalesce(run_id, '') desc,
                page_number desc,
                row_index desc
        ) as row_num
    from source
)

select
    /* IDS */
    e.expense_id,
    e.transaction_id,

    /* TIMESTAMPS */
    e.expense_date,
    e.submitted_at,
    e.completed_at,
    e.loaded_at,
    e.extracted_at,
    e.request_from_expense_date,
    e.request_to_expense_date,
    e.run_id,
    e.gcs_uri,
    e.page_number,
    e.row_index,

    /* DATES */
    date(e.expense_date) as expense_date_utc,
    date(e.expense_date, 'Europe/Zurich') as expense_date_zurich,
    date(e.submitted_at, 'Europe/Zurich') as submitted_date_zurich,
    date(e.completed_at, 'Europe/Zurich') as completed_date_zurich,

    /* DIMENSIONS */
    lower(nullif(trim(coalesce(json_value(e.expense_raw_json, '$.state'), e.expense_state)), '')) as expense_state,
    lower(nullif(trim(coalesce(json_value(e.expense_raw_json, '$.transaction_type'), e.transaction_type)), '')) as transaction_type,
    nullif(trim(coalesce(json_value(e.expense_raw_json, '$.description'), e.description)), '') as description,
    nullif(trim(coalesce(json_value(e.expense_raw_json, '$.payer'), e.payer)), '') as payer,
    nullif(trim(coalesce(json_value(e.expense_raw_json, '$.merchant'), e.merchant)), '') as merchant,
    upper(nullif(trim(coalesce(json_value(e.expense_raw_json, '$.spent_amount.currency'), e.spent_currency)), '')) as spent_currency,

    /* MEASURES */
    safe_cast(
        coalesce(
            cast(e.spent_amount_numeric as string),
            json_value(e.expense_raw_json, '$.spent_amount.amount'),
            cast(e.spent_amount as string)
        ) as numeric
    ) as spent_amount_numeric,
    coalesce(
        safe_cast(json_value(e.expense_raw_json, '$.spent_amount.amount') as float64),
        safe_cast(e.spent_amount_numeric as float64),
        e.spent_amount
    ) as spent_amount,

    /* SOURCE-STRUCTURED FIELDS */
    e.labels,
    e.splits,
    e.receipt_ids,

    /* RAW */
    e.expense_raw_json

from latest e
where e.row_num = 1
