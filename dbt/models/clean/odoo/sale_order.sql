SELECT

    /*
        Sale order headers across all states (draft / sent / sale / cancel).
        Carries Wingtra's custom shipment tracking fields: date_cleared
        (customs clearance), pickup_date, actual_arrival_date, order_type,
        and legacy_wingtra (comma-separated legacy shipment ids; multiple
        ids mean the SO was merged during the 2025 migration).

        `shipment_status` is Odoo's own field; `shipment_status_hubspot` is
        synced from HubSpot and can diverge from it (e.g. HubSpot says
        Shipped/Canceled while Odoo's delivery is still open) — ops
        reporting on order closure uses the HubSpot field deliberately, not
        Odoo's, so keep both distinct downstream.
    */

    /* IDS */
    id as sale_order_id,
    partner_id as customer_partner_id,
    partner_invoice_id as invoice_partner_id,
    partner_shipping_id as shipping_partner_id,
    user_id as salesperson_user_id,
    company_id,
    currency_id,
    pricelist_id,
    payment_term_id,
    team_id as sales_team_id,
    warehouse_id,
    incoterm as incoterm_id,
    opportunity_id,
    campaign_id,
    auto_purchase_order_id,
    shipper_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,
    date_order as ordered_at,
    commitment_date as promised_delivery_at,
    effective_date as first_delivery_at,
    signed_on as signed_at,

    /* DATES */
    validity_date as quote_validity_date,
    expected_shipping_date,
    expected_delivery_date,
    date_cleared as cleared_date,
    pickup_date,
    actual_arrival_date,

    /* DIMENSIONS */
    name as sale_order_name,
    state as sale_order_state,
    order_type,
    invoice_status,
    delivery_status,
    shipment_status,
    shipment_status_hubspot,
    origin as source_document,
    client_order_ref as customer_order_reference,
    destination,
    tracking_number,
    shipment_ref as shipment_reference,
    incoterm_location,
    picking_policy,
    legacy_wingtra as legacy_shipment_ids,
    deal_hubspot as hubspot_deal_reference,
    deal_owner as hubspot_deal_owner,

    /* BOOLEANS */
    locked as is_locked,
    auto_generated as is_auto_generated,
    all_qty_delivered as is_fully_delivered,
    non_commercial_invoice as is_non_commercial_invoice,

    /* METRICS */
    amount_untaxed,
    amount_tax,
    amount_total,
    currency_rate,
    prepayment_percent,
    total_discount,
    shipping_weight

FROM {{ source('odoo', 'sale_order') }}

-- Filter out CEE (company_id=8) per project policy: CEE is the outdated
-- Wingtra - CEE entity. No CEE order has a 2026 pickup.
WHERE _dlt_deleted_at IS NULL
  AND (company_id IS NULL OR company_id != 8)
