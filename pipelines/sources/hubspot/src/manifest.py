"""HubSpot v1 extraction manifest.

The manifest is deliberately explicit. HubSpot objects do not all behave the
same way, so each resource owns its endpoint, cursor field, properties, scopes,
and page limits.
"""

from __future__ import annotations

from dataclasses import dataclass


DEFAULT_OBJECT_PROPERTIES = {
    "contacts": [
        "email",
        "firstname",
        "lastname",
        "company",
        "jobtitle",
        "phone",
        "lifecyclestage",
        "hubspot_owner_id",
        "createdate",
        "lastmodifieddate",
    ],
    "companies": [
        "name",
        "domain",
        "industry",
        "city",
        "country",
        "hubspot_owner_id",
        "createdate",
        "hs_lastmodifieddate",
    ],
    "deals": [
        "dealname",
        "dealstage",
        "pipeline",
        "amount",
        "closedate",
        "dealtype",
        "hubspot_owner_id",
        "createdate",
        "hs_lastmodifieddate",
        # ARR/accruals rebuild: currency, FX, and license-window properties
        # used by the RevOps Accruals reports (see dbt dl_hubspot docs).
        "deal_currency_code",
        "hs_exchange_rate",
        "hs_arr",
        "currency_from_the_license__arr_",
        "license_expiration_date",
        "cloud_license_start_date",
        "tmp_start_date",
    ],
    "tickets": [
        "subject",
        "content",
        "hs_pipeline",
        "hs_pipeline_stage",
        "hs_ticket_category",
        "hs_ticket_id",
        "hs_ticket_priority",
        "hubspot_owner_id",
        "createdate",
        "closed_date",
        "hs_lastmodifieddate",
    ],
    "products": [
        "name",
        "description",
        "price",
        "hs_sku",
        "createdate",
        "hs_lastmodifieddate",
    ],
    "line_items": [
        "name",
        "quantity",
        "price",
        "amount",
        "hs_product_id",
        "createdate",
        "hs_lastmodifieddate",
        # ARR/accruals rebuild: SKU snapshot, currency, and recurring-billing
        # attributes used by the RevOps Accruals reports.
        "hs_sku",
        "hs_line_item_currency_code",
        "recurringbillingfrequency",
        "hs_recurring_billing_period",
        "hs_recurring_billing_start_date",
        "hs_recurring_billing_end_date",
        "discount",
        "hs_discount_percentage",
    ],
    # Custom object "Licence" (objectTypeId 2-1022441): one record per license,
    # the source of the "[Accruals] ARR: Raw Data" report. Carries the revenue
    # recognition window and the USD-converted recurring revenue amount.
    "licences": [
        "type",
        "license_type",
        "sku",
        "recurring_revenue_amount_net__usd_",
        "corrected_recurring_revenue_usd",
        "billing_frequency",
        "number_of_billing_cycles",
        "warranty_service_start_date",
        "expiration_date",
        "activation_date",
        "first_drone_configuration_date",
        "last_drone_configuration_date",
        "associated_deal_id",
        "associated_deal_name",
        "associated_deal_currency",
        "associated_drone_id",
        "company_from_activation",
        "associated_company",
        "country",
        "current_status",
        "arr_subscription",
        "trigger_for_recurring_revenue",
        "exclude_license_from_the_main_arr_workflow",
        "is_legacy_license",
        "license_renewal_count",
        "license_validity__years_",
        "sales_out_accounted_quarter",
        "hs_pipeline",
        "hs_pipeline_stage",
        "hubspot_owner_id",
        "hs_createdate",
        "hs_lastmodifieddate",
    ],
    # Custom object "Commission" (objectTypeId 2-53702763): RevOps commission
    # records. The portal schema exposes no object associations, so the object
    # is loaded as standalone custom-object data.
    "commissions": [
        "assigned_reseller",
        "associated_drone_id",
        "link_to_item",
        "no_associated_object",
        "no_match_in_sheet",
        "object_type",
        "quarter",
        "revops_notes",
        "sales_out_deal",
        "sku_revenue",
        "sku_type",
        "split_deal",
        "status",
        "year",
        "hubspot_owner_id",
        "hubspot_team_id",
        "hs_createdate",
        "hs_lastmodifieddate",
    ],
    "quotes": [
        "hs_title",
        "hs_status",
        "hs_expiration_date",
        "hs_language",
        "createdate",
        "hs_lastmodifieddate",
    ],
}


@dataclass(frozen=True)
class HubSpotResource:
    name: str
    mode: str
    object_type: str
    endpoint: str
    method: str = "POST"
    pagination_mode: str = "after"
    cursor_field: str | None = None
    properties: tuple[str, ...] = ()
    required_scopes: tuple[str, ...] = ()
    archived_strategy: str = "include_archived_on_reconciliation"
    page_limit: int = 1000
    rate_limit_budget: int = 10000
    enabled: bool = True
    from_object_type: str | None = None
    to_object_type: str | None = None


def _object_resource(
    object_type: str,
    cursor_field: str,
    enabled: bool = True,
) -> HubSpotResource:
    required_scope = (
        "tickets"
        if object_type == "tickets"
        else f"crm.objects.{object_type}.read"
    )
    return HubSpotResource(
        name=object_type,
        mode="object",
        object_type=object_type,
        endpoint=f"/crm/v3/objects/{object_type}/search",
        cursor_field=cursor_field,
        properties=tuple(DEFAULT_OBJECT_PROPERTIES[object_type]),
        required_scopes=(required_scope,),
        enabled=enabled,
    )


def _metadata_resource(
    name: str,
    object_type: str,
    endpoint: str,
    enabled: bool = True,
) -> HubSpotResource:
    return HubSpotResource(
        name=name,
        mode="metadata",
        object_type=object_type,
        endpoint=endpoint,
        method="GET",
        cursor_field=None,
        archived_strategy="not_applicable",
        page_limit=50,
        rate_limit_budget=1000,
        enabled=enabled,
    )


def _association_resource(
    from_object_type: str,
    to_object_type: str,
    enabled: bool = True,
) -> HubSpotResource:
    name = f"{from_object_type}__{to_object_type}"
    return HubSpotResource(
        name=name,
        mode="association",
        object_type=name,
        endpoint=(
            f"/crm/v4/objects/{from_object_type}/"
            "{from_object_id}"
            f"/associations/{to_object_type}"
        ),
        method="GET",
        cursor_field=None,
        required_scopes=(
            f"crm.objects.{from_object_type}.read",
            f"crm.objects.{to_object_type}.read",
        ),
        archived_strategy="association_reconciliation",
        page_limit=1000,
        rate_limit_budget=20000,
        enabled=enabled,
        from_object_type=from_object_type,
        to_object_type=to_object_type,
    )


V1_OBJECTS: tuple[HubSpotResource, ...] = (
    _object_resource("companies", "hs_lastmodifieddate"),
    _object_resource("contacts", "lastmodifieddate"),
    _object_resource("deals", "hs_lastmodifieddate"),
    _object_resource("tickets", "hs_lastmodifieddate"),
    _object_resource("products", "hs_lastmodifieddate"),
    _object_resource("line_items", "hs_lastmodifieddate"),
    _object_resource("quotes", "hs_lastmodifieddate"),
)

# Portal-specific custom object type IDs (HubSpot assigns these per portal).
LICENCE_OBJECT_TYPE_ID = "2-1022441"
COMMISSION_OBJECT_TYPE_ID = "2-53702763"

V1_CUSTOM_OBJECTS: tuple[HubSpotResource, ...] = (
    # Custom object "Licence": search endpoint and properties endpoint must use
    # the objectTypeId, not the name. Requires the crm.objects.custom.read
    # scope on the service key.
    HubSpotResource(
        name="licences",
        mode="object",
        object_type="licences",
        endpoint=f"/crm/v3/objects/{LICENCE_OBJECT_TYPE_ID}/search",
        cursor_field="hs_lastmodifieddate",
        properties=tuple(DEFAULT_OBJECT_PROPERTIES["licences"]),
        required_scopes=("crm.objects.custom.read",),
    ),
    HubSpotResource(
        name="commissions",
        mode="object",
        object_type="commissions",
        endpoint=f"/crm/v3/objects/{COMMISSION_OBJECT_TYPE_ID}/search",
        cursor_field="hs_lastmodifieddate",
        properties=tuple(DEFAULT_OBJECT_PROPERTIES["commissions"]),
        required_scopes=("crm.objects.custom.read",),
    ),
)

V1_METADATA: tuple[HubSpotResource, ...] = (
    _metadata_resource("owners", "owners", "/crm/v3/owners"),
    _metadata_resource("pipelines_deals", "deals", "/crm/v3/pipelines/deals"),
    _metadata_resource("pipelines_tickets", "tickets", "/crm/v3/pipelines/tickets"),
    _metadata_resource("object_schemas", "schemas", "/crm/v3/schemas"),
    *(
        _metadata_resource(
            f"properties_{resource.object_type}",
            resource.object_type,
            f"/crm/v3/properties/{resource.object_type}",
            enabled=resource.enabled,
        )
        for resource in V1_OBJECTS
    ),
    _metadata_resource(
        "properties_licences",
        "licences",
        f"/crm/v3/properties/{LICENCE_OBJECT_TYPE_ID}",
    ),
    _metadata_resource(
        "properties_commissions",
        "commissions",
        f"/crm/v3/properties/{COMMISSION_OBJECT_TYPE_ID}",
    ),
)

V1_ASSOCIATIONS: tuple[HubSpotResource, ...] = (
    _association_resource("contacts", "companies"),
    _association_resource("contacts", "deals"),
    _association_resource("companies", "deals"),
    _association_resource("tickets", "contacts", enabled=False),
    _association_resource("tickets", "companies", enabled=False),
    _association_resource("tickets", "deals", enabled=False),
    _association_resource("deals", "line_items"),
    _association_resource("quotes", "deals"),
    _association_resource("quotes", "line_items"),
    _association_resource("products", "line_items"),
)

V1_RESOURCES: tuple[HubSpotResource, ...] = (
    *V1_METADATA,
    *V1_OBJECTS,
    *V1_CUSTOM_OBJECTS,
    *V1_ASSOCIATIONS,
)


def manifest_by_name() -> dict[str, HubSpotResource]:
    return {resource.name: resource for resource in V1_RESOURCES}
