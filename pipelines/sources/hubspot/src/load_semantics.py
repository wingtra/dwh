"""Pure helpers for HubSpot load semantics.

Keep this module free of cloud SDK imports so it can be tested locally without
HubSpot or GCP credentials.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any


def parse_hubspot_timestamp(value: Any) -> datetime | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value / 1000, tz=UTC)
    if isinstance(value, str):
        normalized = value.replace("Z", "+00:00")
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC)
    return None


def isoformat_utc(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def request_window(
    watermark: datetime | None,
    run_started_at: datetime,
    lookback_days: int,
    default_start: datetime,
) -> tuple[datetime, datetime]:
    window_start = watermark - timedelta(days=lookback_days) if watermark else default_start
    if window_start < default_start:
        window_start = default_start
    return window_start.astimezone(UTC), run_started_at.astimezone(UTC)


def raw_gcs_object_name(
    prefix: str,
    object_type: str,
    run_started_at: datetime,
    run_id: str,
    attempt: int,
    page_number: int,
) -> str:
    date_part = run_started_at.astimezone(UTC).date().isoformat()
    clean_prefix = prefix.strip("/")
    return (
        f"{clean_prefix}/object_type={object_type}/run_date={date_part}/"
        f"run_id={run_id}/attempt={attempt}/page={page_number:05d}.jsonl"
    )


def jsonl(rows: list[dict[str, Any]]) -> str:
    return "".join(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n" for row in rows)


def source_updated_at(row: dict[str, Any]) -> datetime | None:
    direct = parse_hubspot_timestamp(row.get("updatedAt"))
    if direct is not None:
        return direct
    props = row.get("properties") or {}
    for field in ("hs_lastmodifieddate", "lastmodifieddate"):
        parsed = parse_hubspot_timestamp(props.get(field))
        if parsed is not None:
            return parsed
    return None


def dedupe_current_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Keep the deterministic latest row per HubSpot object ID."""
    selected: dict[str, tuple[tuple[datetime, datetime, int], dict[str, Any]]] = {}
    min_dt = datetime.min.replace(tzinfo=UTC)
    for index, row in enumerate(rows):
        object_id = str(row["object_id"])
        updated_at = parse_hubspot_timestamp(row.get("updated_at")) or min_dt
        extracted_at = parse_hubspot_timestamp(row.get("extracted_at")) or min_dt
        rank = (updated_at, extracted_at, index)
        existing = selected.get(object_id)
        if existing is None or rank > existing[0]:
            selected[object_id] = (rank, row)
    return [value[1] for value in selected.values()]


def deletion_values(row: dict[str, Any], detected_at: datetime) -> tuple[str | None, str | None]:
    """Return warehouse soft-delete timestamp and deletion source.

    Missing from an incremental response is intentionally not represented here;
    callers should invoke this only for a staged source row or a reconciliation
    proof.
    """
    archived = bool(row.get("archived"))
    archived_at = parse_hubspot_timestamp(row.get("archived_at") or row.get("archivedAt"))
    if archived:
        return isoformat_utc(archived_at or detected_at), "hubspot_archived"
    if row.get("reconciliation_missing"):
        return isoformat_utc(detected_at), "reconciliation_missing"
    return None, None


def sanitized_params(params: dict[str, Any]) -> dict[str, Any]:
    blocked = {"authorization", "hapikey", "access_token", "token"}
    return {key: ("<redacted>" if key.lower() in blocked else value) for key, value in params.items()}
