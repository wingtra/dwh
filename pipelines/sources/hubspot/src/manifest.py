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
    ],
    "tickets": [
        "subject",
        "content",
        "hs_pipeline",
        "hs_pipeline_stage",
        "hs_ticket_priority",
        "hubspot_owner_id",
        "createdate",
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
    return HubSpotResource(
        name=object_type,
        mode="object",
        object_type=object_type,
        endpoint=f"/crm/v3/objects/{object_type}/search",
        cursor_field=cursor_field,
        properties=tuple(DEFAULT_OBJECT_PROPERTIES[object_type]),
        required_scopes=(f"crm.objects.{object_type}.read",),
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
    # HubSpot service keys currently cannot access tickets; keep the manifest
    # entry for future OAuth/private-app fallback, but exclude it by default.
    _object_resource("tickets", "hs_lastmodifieddate", enabled=False),
    _object_resource("products", "hs_lastmodifieddate"),
    _object_resource("line_items", "hs_lastmodifieddate"),
    _object_resource("quotes", "hs_lastmodifieddate"),
)

V1_METADATA: tuple[HubSpotResource, ...] = (
    _metadata_resource("owners", "owners", "/crm/v3/owners"),
    _metadata_resource("pipelines_deals", "deals", "/crm/v3/pipelines/deals"),
    _metadata_resource(
        "pipelines_tickets",
        "tickets",
        "/crm/v3/pipelines/tickets",
        enabled=False,
    ),
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
    *V1_ASSOCIATIONS,
)


def manifest_by_name() -> dict[str, HubSpotResource]:
    return {resource.name: resource for resource in V1_RESOURCES}
