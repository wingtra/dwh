from __future__ import annotations

import unittest

from src.manifest import COMMISSION_OBJECT_TYPE_ID, manifest_by_name


class HubSpotManifestTest(unittest.TestCase):
    def test_tickets_are_enabled_with_portal_scope(self) -> None:
        resources = manifest_by_name()

        self.assertTrue(resources["tickets"].enabled)
        self.assertEqual(resources["tickets"].required_scopes, ("tickets",))
        self.assertTrue(resources["properties_tickets"].enabled)
        self.assertTrue(resources["pipelines_tickets"].enabled)

    def test_commissions_custom_object_is_enabled_by_object_type_id(self) -> None:
        resources = manifest_by_name()
        commissions = resources["commissions"]

        self.assertTrue(commissions.enabled)
        self.assertEqual(
            commissions.endpoint,
            f"/crm/v3/objects/{COMMISSION_OBJECT_TYPE_ID}/search",
        )
        self.assertEqual(commissions.cursor_field, "hs_lastmodifieddate")
        self.assertIn("sku_revenue", commissions.properties)
        self.assertIn("properties_commissions", resources)

    def test_ticket_associations_remain_deferred(self) -> None:
        resources = manifest_by_name()

        self.assertFalse(resources["tickets__contacts"].enabled)
        self.assertFalse(resources["tickets__companies"].enabled)
        self.assertFalse(resources["tickets__deals"].enabled)


if __name__ == "__main__":
    unittest.main()
