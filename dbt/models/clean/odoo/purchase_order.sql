SELECT

    /*
        Purchase order headers, covering both RFQ-stage drafts and
        confirmed POs. State and date fields drive PO+RFQ tracking
        and on-time delivery reporting.
    */

    /* IDS */
    id as purchase_order_id,
    partner_id as vendor_partner_id,
    dest_address_id,
    currency_id,
    fiscal_position_id,
    payment_term_id,
    incoterm_id,
    user_id as buyer_user_id,
    company_id,
    picking_type_id,
    group_id,
    requisition_id,
    purchase_group_id,
    auto_sale_order_id,
    create_uid as created_by_user_id,
    write_uid as updated_by_user_id,

    /* TIMESTAMPS */
    create_date as created_at,
    write_date as updated_at,

    /* DATES */
    date_order,
    date_approve,
    date_planned,
    date_calendar_start,
    date_planned_mps,
    effective_date,

    /* DIMENSIONS */
    name as purchase_order_name,
    priority,
    origin,
    partner_ref as vendor_reference,
    state as purchase_order_state,
    invoice_status,
    delivery_status,
    receipt_status,
    incoterm_location,
    notes,
    auto_generated as is_auto_generated,
    mail_reminder_confirmed as is_mail_reminder_confirmed,
    mail_reception_confirmed as is_mail_reception_confirmed,
    mail_reception_declined as is_mail_reception_declined,

    /* METRICS */
    invoice_count,
    amount_untaxed,
    amount_tax,
    amount_total,
    amount_total_cc,
    currency_rate

FROM {{ source('odoo', 'purchase_order') }}

-- Filter out CEE (company_id=8) per project policy.
WHERE _dlt_deleted_at IS NULL
  AND (company_id IS NULL OR company_id != 8)
