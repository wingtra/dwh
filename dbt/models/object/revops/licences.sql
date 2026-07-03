/*
    Canonical licence entity: everything we know about each licence sold or
    activated. One row per licence.

    Includes the USD-converted recurring revenue (start-date FX, matching the
    Accruals sheet), the recognition window, and data-quality flags — most
    importantly the expiration-date convention: HubSpot workflows disagree on
    whether a licence expires on the anniversary day (leaky: 13 recognized
    months for a 12-month term, boundary double-count with the renewal) or
    the day before (clean). See arr_accrual_rules for the business rules.
*/

{{
    config(
        materialized='table'
    )
}}

with

licences as (
    select * from {{ ref('cl_hubspot__licences') }}
),

fx as (
    select rate_date, valid_until_date, eur_to_usd, chf_to_usd
    from {{ ref('arr_fx_daily_rates') }}
),

enriched as (
    select
        l.*,
        coalesce(l.warranty_service_expiration_date, l.blu_end_date) as effective_expiration_date,
        case
            when l.recurring_revenue_currency = 'USD' then 1.0
            when l.recurring_revenue_currency = 'EUR' then fx.eur_to_usd
            when l.recurring_revenue_currency = 'CHF' then fx.chf_to_usd
        end as fx_rate_to_usd
    from licences l
    left join fx
        on l.recurring_revenue_currency in ('EUR', 'CHF')
        and fx.rate_date <= l.warranty_service_start_date
        and (l.warranty_service_start_date < fx.valid_until_date or fx.valid_until_date is null)
)

select
    /* IDS */
    licence_id,
    deal_id,
    drone_id,
    hubspot_owner_id,

    /* DATES / TIMESTAMPS */
    warranty_service_start_date,
    effective_expiration_date as warranty_service_expiration_date,
    activation_date,
    first_drone_configuration_date,
    last_drone_configuration_date,
    created_at,
    updated_at,

    /* DIMENSIONS */
    licence_type_raw,
    licence_type_label,
    licence_type_detail,
    sku,
    deal_name,
    company_from_activation,
    associated_company,
    country,
    current_status,
    billing_frequency,
    recurring_revenue_currency,
    case
        when warranty_service_start_date is null or effective_expiration_date is null then 'missing_dates'
        when extract(day from effective_expiration_date) = extract(day from warranty_service_start_date)
            then 'anniversary_day'
        when extract(day from date_add(effective_expiration_date, interval 1 day)) = extract(day from warranty_service_start_date)
            then 'anniversary_minus_1_day'
        else 'other'
    end as expiration_date_convention,

    /* BOOLEANS */
    licence_type_label in (
        'Drone Operating System & Apps', 'LIDAR', 'Total Maintenance Plan',
        'WingtraCare', 'WingtraCare BLU', 'WingtraPilot BLU'
    ) and not is_excluded_from_arr_workflow as is_in_arr_scope,
    is_excluded_from_arr_workflow,
    is_legacy_licence,
    warranty_service_start_date is not null
        and effective_expiration_date is not null
        and current_date() between warranty_service_start_date and effective_expiration_date
        as is_recognizing_today,

    /* MEASURES */
    recurring_revenue_amount_source,
    corrected_recurring_revenue_amount_source,
    fx_rate_to_usd,
    case
        when recurring_revenue_currency in ('USD', 'EUR', 'CHF')
            then recurring_revenue_amount_source * fx_rate_to_usd
    end as recurring_revenue_amount_usd,
    date_diff(effective_expiration_date, warranty_service_start_date, day) as term_days,
    date_diff(effective_expiration_date, warranty_service_start_date, month)
        - if(extract(day from effective_expiration_date) < extract(day from warranty_service_start_date), 1, 0)
        + 1 as term_months_sheet_method,
    number_of_billing_cycles,
    licence_renewal_count,
    licence_validity_years

from enriched
