/*
    Object layer: commissions.
    One row per commissionable item (drone / payload / license line), the
    business's reusable view of the RevOps commission-eligibility layer.

    Exposes stable keys, the manual review status, and reusable flags. No
    report-specific scope here (grain stays per item; aggregation lives in BL).

    is_counted = the reusable rule for "counts toward reported revenue":
    Confirmed AND sku_revenue > 0. Confirmed-but-$0 rows (housekeeping /
    no-match records) are excluded by the > 0 test.
*/

with commissions as (
    select * from {{ ref('cl_hubspot__commissions') }}
)

select
    commission_id,
    drone_id,
    sales_out_deal_id,
    hubspot_owner_id,

    object_type,          -- Drone | License | Payload
    status,               -- Confirmed | Declined | Pending
    sku_type,             -- populated for Drone; NULL for License/Payload
    commission_year,
    commission_quarter,
    assigned_reseller,

    is_split_deal,
    is_no_match_in_sheet,

    sku_revenue,

    /* reusable eligibility flag */
    (status = 'Confirmed' and coalesce(sku_revenue, 0) > 0) as is_counted,

    created_at,
    updated_at
from commissions
