/*
    Per-SKU snapshot mirroring the CONSOLIDATED CTB KPI tab in
    SC KPI CTB.xlsx (1sZLfXHke1ZajukDuxRwLfFIfuTVNYuno). Columns A..AB
    follow the sheet; G..O (per-end-product BOM consumption) and AC/AD
    (SC owner, comment) are hand-typed in the source sheet and omitted.

    Scope rule (confirmed with Jan 2026-06-05 over Chat):
      - storable
      - active product + active template
      - AG company only (company_id NULL or 1)
      - not manufactured in-house (no active normal BOM where this
        product is the output)
      - Can be Purchased = YES (Odoo purchase_ok flag)
      - has at least one active supplier configured (no date_end, or
        date_end in the future)
      - if `part_number` starts with `/` (R&D obsolete revision marker)
        the SKU is only kept when on-hand > 0; once stock is consumed
        the SKU drops out automatically.

    IMM-missing handling: when `take_rate IS NULL` (the SKU has no IMM
    record), every IMM-dependent column displays the literal string
    "Take Rate is Missing in IMM" instead of a silent NULL/0. This
    forces the 7 numeric columns to STRING.

    R / S / T (IMM ODOO MIN / MAX / DAILY DEMAND) still read directly
    from `cl.gsheet_inventory_master_ag` pending verification that
    these are derivable from Odoo (stock.warehouse.orderpoint, sale
    forecast). See memory: project_imm_fields_odoo_derivation_check.
*/

{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by={'field': 'snapshot_date', 'data_type': 'date'},
    cluster_by=['product_reference'],
    on_schema_change='sync_all_columns',
    full_refresh=false
) }}

with

params as (
    /*
        CTB weekly reporting treats the Sunday evening refresh as the opening
        snapshot for the next ISO week. Daily runs on all other weekdays keep
        their calendar date.
    */
    select
        case
            when extract(dayofweek from current_date('Europe/Zurich')) = 1
                then date_add(current_date('Europe/Zurich'), interval 1 day)
            else current_date('Europe/Zurich')
        end as business_snapshot_date
),

manufactured_outputs as (
    -- products that are themselves the output of an active normal BOM
    select distinct product_template_id
    from {{ ref('mrp_bom') }}
    where is_active = true and bom_type = 'normal'
),

active_suppliers as (
    -- product has at least one supplier with no end date or end date in the future
    select distinct product_template_id
    from {{ ref('product_supplierinfo') }}
    where product_template_id is not null
      and (date_end is null or date_end >= (select business_snapshot_date from params))

    union distinct

    select distinct pp.product_template_id
    from {{ ref('product_supplierinfo') }} si
    join {{ ref('product_product') }}      pp on pp.product_id = si.product_id
    where si.product_id is not null
      and (si.date_end is null or si.date_end >= (select business_snapshot_date from params))
),

ctb_universe as (
    select
        p.product_id,
        p.product_template_id,
        p.product_code,
        p.product_name,
        p.product_type_label,
        p.buy_sku_category,
        p.category_path,
        p.primary_supplier_name,
        p.take_rate,
        pt.part_number
    from {{ ref('products') }} p
    left join {{ ref('product_template') }} pt on pt.product_template_id = p.product_template_id
    where p.is_active     = true
      and p.is_storable   = true
      and p.is_purchasable = true
      and (p.company_id is null or p.company_id = 1)
      and p.product_template_id not in (select product_template_id from manufactured_outputs)
      and p.product_template_id in     (select product_template_id from active_suppliers)
),

on_hand_wwh as (
    -- WWH-only on-hand (Jan's scope; matches the OH Inventory tab).
    select
        product_id,
        sum(quantity) as oh_quantity
    from {{ ref('stock_at_locations') }}
    where is_wwh_internal = true
      and company_id      = 1
    group by product_id
),

open_pos as (
    -- Single open PO line per product, closest to today by absolute
    -- distance — past and future PO lines compete on equal footing
    -- (Jan's rule, confirmed 2026-06-05). A past-due PO 5 days ago
    -- now wins over a future PO 200 days out.
    select
        product_id,
        qty_remaining                         as expected_arrival_qty,
        planned_date_local                    as expected_arrival_date
    from (
        select
            product_id,
            qty_remaining,
            date(line_planned_date, 'Europe/Zurich') as planned_date_local,
            row_number() over (
                partition by product_id
                order by
                    abs(date_diff(
                        date(line_planned_date, 'Europe/Zurich'),
                        (select business_snapshot_date from params),
                        day
                    )),
                    purchase_order_line_id
            ) as rn
        from {{ ref('purchase_order_lines') }}
        where is_open = true
    )
    where rn = 1
),

imm as (
    -- R / S / T read directly from IMM. See project_imm_fields_odoo_derivation_check.
    select
        product_code,
        odoo_min_qty,
        odoo_max_qty,
        demand_per_day
    from {{ ref('gsheet_inventory_master_ag') }}
    where product_code is not null
)

select

    /* Business snapshot date — Sunday evening runs are stamped as next Monday. */
    params.business_snapshot_date                                                        as snapshot_date,

    /* A  — PRODUCT REFERENCE */
    p.product_code                                                                       as product_reference,
    /* B  — Product Name */
    concat('[', p.product_code, '] ', p.product_name)                                    as product_name,
    /* C  — SUPPLIER */
    p.primary_supplier_name                                                              as primary_supplier,
    /* D  — PRODUCT TYPE */
    p.product_type_label                                                                 as product_type,
    /* E  — BUY SKU CATEGORY */
    p.buy_sku_category,
    /* F  — PROD CAT */
    p.category_path                                                                      as prod_cat,

    /* G..O (per-end-product BOM consumption columns) are hand-typed in the sheet and omitted. */

    /* P  — IMM take_rate (sheet header: "Consolidated BOM qty"; same value). */
    p.take_rate,

    /*
        IMM-dependent columns. When `take_rate IS NULL` the SKU has no
        usable IMM record, so every downstream computation shows the
        literal string "Take Rate is Missing in IMM" (Jan's ask
        2026-06-05). Columns become STRING; consumers should filter
        on take_rate being non-null before treating them as numeric.
    */

    /* Q  — WEEKLY QTY NEED (take_rate × 18) */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        else format('%g', round(p.take_rate * 18, 4))
    end                                                                                  as weekly_qty_need,

    /* R  — IMM ODOO MIN */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        when imm.odoo_min_qty is null then null
        else cast(imm.odoo_min_qty as string)
    end                                                                                  as imm_odoo_min,

    /* S  — IMM ODOO MAX */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        when imm.odoo_max_qty is null then null
        else cast(imm.odoo_max_qty as string)
    end                                                                                  as imm_odoo_max,

    /* T  — IMM DAILY DEMAND */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        when imm.demand_per_day is null then null
        else format('%g', round(imm.demand_per_day, 4))
    end                                                                                  as imm_daily_demand,

    /* U  — PLANNED TIME DEMAND (P × 108 = 6 weeks × 18 drones/week) */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        else format('%g', round(p.take_rate * 108, 4))
    end                                                                                  as planned_time_demand,

    /* V  — OH INV (WWH internal only) */
    coalesce(oh.oh_quantity, 0)                                                          as oh_inv,

    /* W  — BALANCE (V − U) */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        else format('%g', coalesce(oh.oh_quantity, 0) - round(p.take_rate * 108, 4))
    end                                                                                  as balance,

    /* X  — EXPECTED ARRIVAL QTY (qty of the closest-to-today open PO line) */
    coalesce(po.expected_arrival_qty, 0)                                                 as expected_arrival_qty,
    /* Y  — EXPECTED ARRIVAL DATE (planned date of the closest-to-today open PO line) */
    po.expected_arrival_date                                                             as expected_arrival_date,

    /*
        Z — STATUS 6 WKS OUTLOOK + reason.
        Same decision tree as before; "NO DEMAND DATA" renamed to
        "Take Rate is Missing in IMM" so the message is consistent
        across all IMM-dependent columns.
    */
    case
        when p.take_rate is null                                                                                                                             then 'Take Rate is Missing in IMM'
        when p.take_rate = 0                                                                                                                                 then 'OK'
        when coalesce(oh.oh_quantity, 0) - p.take_rate * 108 >= 0                                                                                            then 'OK'
        when coalesce(oh.oh_quantity, 0) >= coalesce(imm.odoo_min_qty, 0)                                                                                    then 'MONITOR'
        when po.expected_arrival_date is null                                                                                                       then 'ESCALATE'
        when po.expected_arrival_date <= params.business_snapshot_date                                                                              then 'ESCALATE'
        when coalesce(oh.oh_quantity, 0)
             < date_diff(po.expected_arrival_date, params.business_snapshot_date, day) * coalesce(imm.demand_per_day, 0)                            then 'ESCALATE'
        else 'MONITOR'
    end                                                                                  as status_6wks_outlook,
    case
        when p.take_rate is null                                                                                                                             then 'Take Rate is Missing in IMM'
        when p.take_rate = 0                                                                                                                                 then 'OK: take_rate is zero'
        when coalesce(oh.oh_quantity, 0) - p.take_rate * 108 >= 0                                                                                            then 'OK: balance >= 0 (6 weeks coverage)'
        when coalesce(oh.oh_quantity, 0) >= coalesce(imm.odoo_min_qty, 0)                                                                                    then 'MONITOR: on_hand >= imm_odoo_min'
        when po.expected_arrival_date is null                                                                                                       then 'ESCALATE: no open PO'
        when po.expected_arrival_date <= params.business_snapshot_date                                                                              then 'ESCALATE: closest open PO is past-due'
        when coalesce(oh.oh_quantity, 0)
             < date_diff(po.expected_arrival_date, params.business_snapshot_date, day) * coalesce(imm.demand_per_day, 0)                            then 'ESCALATE: runway < days_to_po * daily_demand'
        else 'MONITOR: open PO covers runway, but on_hand below imm_odoo_min'
    end                                                                                  as status_6wks_outlook_reason,

    /*
        AA — ESTIMATED STOCK RUNWAY (ISO week of stock-out).
        Mirrors `CONSOLIDATED CTB KPI!AA6`; the "No demand" sentinel is
        renamed to "Take Rate is Missing in IMM" so the message is
        consistent.
    */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        when p.take_rate * 18 <= 0 then 'No demand'
        else format_date('%V/%G',
            date_add(params.business_snapshot_date,
                     interval cast(round(safe_divide(coalesce(oh.oh_quantity, 0), p.take_rate * 18) * 7) as int64) day))
    end                                                                                  as estimated_stock_runway,

    /* AB — OHI WEEKS COVERAGE */
    case
        when p.take_rate is null then 'Take Rate is Missing in IMM'
        when p.take_rate * 18 = 0 then 'No demand'
        else format('%g', round(safe_divide(coalesce(oh.oh_quantity, 0), p.take_rate * 18), 0))
    end                                                                                  as ohi_weeks_coverage,

    /* part_number (R&D PDM reference; '/' prefix = obsolete revision per R&D convention) */
    p.part_number                                                                        as part_number

from ctb_universe p
cross join params
left join on_hand_wwh  oh  on oh.product_id    = p.product_id
left join open_pos     po  on po.product_id    = p.product_id
left join imm              on imm.product_code = p.product_code
where not (starts_with(coalesce(p.part_number, ''), '/')
           and coalesce(oh.oh_quantity, 0) = 0)
