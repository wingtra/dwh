{{ config(enabled=false) }}

/*
    Kraljic strategic-sourcing classification per BUY SKU. One row per
    product_code with a legitimate Kraljic class — rows where either
    annualised_spend_chf or complexity_score is missing are dropped (so the
    "Check Inputs" bucket from the source sheet is never emitted).

    Source: {{ ref('gsheet_spend_categorization') }} (Spend Categorization 2026,
    tab "SpendxComplexity"). Spend and complexity thresholds are the values
    typed in cells SpendxComplexity!L4 and SpendxComplexity!M4 of the sheet:

        spend_threshold_chf  = 66,729.06   (SpendxComplexity!L4)
        complexity_threshold = 7           (SpendxComplexity!M4)

    Precedence mirrors the sheet's IFS — first match wins, and edge cases
    AT exactly the threshold land in the HIGHER-TIER bucket (i.e. high spend
    + threshold complexity is Strategic Alliance, threshold spend + high
    complexity is Bottleneck, etc.). This matches the `>=` comparisons in
    the sheet's IFS clauses.

    See:
      - docs/sc_kpi_ctb/recreation-summary.md
      - https://docs.google.com/spreadsheets/d/15BrVj1Ht5SehrzaGY5VtcNZza4RW1690MgbiUsaDsL8/edit
*/

{% set spend_threshold_chf = 66729.06 %}
{% set complexity_threshold = 7 %}

select
    product_code,
    case
        when annualised_spend_chf >= {{ spend_threshold_chf }} and complexity_score >= {{ complexity_threshold }} then 'Strategic Alliance'
        when annualised_spend_chf >= {{ spend_threshold_chf }} and complexity_score <= {{ complexity_threshold }} then 'Leverage Opportunity'
        when annualised_spend_chf <= {{ spend_threshold_chf }} and complexity_score >= {{ complexity_threshold }} then 'Bottleneck'
        when annualised_spend_chf <= {{ spend_threshold_chf }} and complexity_score <= {{ complexity_threshold }} then 'Just Buy It'
    end as buy_sku_category
from {{ ref('gsheet_spend_categorization') }}
where annualised_spend_chf is not null
  and complexity_score    is not null
