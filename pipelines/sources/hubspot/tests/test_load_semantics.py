from __future__ import annotations

import unittest
from datetime import UTC, datetime

from src.load_semantics import (
    dedupe_current_rows,
    deletion_values,
    raw_gcs_object_name,
    request_window,
)


class HubSpotLoadSemanticsTest(unittest.TestCase):
    def test_request_window_uses_watermark_minus_lookback(self) -> None:
        start, end = request_window(
            watermark=datetime(2026, 6, 29, 5, 30, tzinfo=UTC),
            run_started_at=datetime(2026, 6, 30, 5, 30, tzinfo=UTC),
            lookback_days=14,
            default_start=datetime(2026, 1, 1, tzinfo=UTC),
        )

        self.assertEqual(start, datetime(2026, 6, 15, 5, 30, tzinfo=UTC))
        self.assertEqual(end, datetime(2026, 6, 30, 5, 30, tzinfo=UTC))

    def test_raw_gcs_object_name_is_attempt_safe(self) -> None:
        first = raw_gcs_object_name(
            "hubspot",
            "deals",
            datetime(2026, 6, 30, 5, 30, tzinfo=UTC),
            "run-1",
            1,
            7,
        )
        second = raw_gcs_object_name(
            "hubspot",
            "deals",
            datetime(2026, 6, 30, 5, 30, tzinfo=UTC),
            "run-1",
            2,
            7,
        )

        self.assertIn("attempt=1", first)
        self.assertIn("attempt=2", second)
        self.assertNotEqual(first, second)

    def test_dedupe_current_rows_keeps_latest_source_update(self) -> None:
        rows = [
            {
                "object_id": "123",
                "updated_at": "2026-06-29T10:00:00Z",
                "extracted_at": "2026-06-30T05:30:00Z",
                "value": "old",
            },
            {
                "object_id": "123",
                "updated_at": "2026-06-30T09:00:00Z",
                "extracted_at": "2026-06-30T05:31:00Z",
                "value": "new",
            },
            {
                "object_id": "456",
                "updated_at": "2026-06-30T08:00:00Z",
                "extracted_at": "2026-06-30T05:32:00Z",
                "value": "other",
            },
        ]

        deduped = {row["object_id"]: row for row in dedupe_current_rows(rows)}

        self.assertEqual(deduped["123"]["value"], "new")
        self.assertEqual(deduped["456"]["value"], "other")

    def test_archive_sets_soft_delete_timestamp_from_hubspot(self) -> None:
        deleted_at, source = deletion_values(
            {
                "archived": True,
                "archivedAt": "2026-06-30T11:00:00Z",
            },
            detected_at=datetime(2026, 7, 1, tzinfo=UTC),
        )

        self.assertEqual(deleted_at, "2026-06-30T11:00:00Z")
        self.assertEqual(source, "hubspot_archived")

    def test_active_row_does_not_set_soft_delete(self) -> None:
        deleted_at, source = deletion_values(
            {"archived": False},
            detected_at=datetime(2026, 7, 1, tzinfo=UTC),
        )

        self.assertIsNone(deleted_at)
        self.assertIsNone(source)


if __name__ == "__main__":
    unittest.main()
