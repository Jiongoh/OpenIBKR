from __future__ import annotations

import json
import unittest
from decimal import Decimal

from openibkr_helper.models import WealthAccessCredentials
from openibkr_helper.wealth import WealthLotsProvider, _origin


class WealthLotsProviderTests(unittest.TestCase):
    def test_origin_accepts_only_plain_https_origin(self) -> None:
        self.assertEqual(_origin("https://wealth.example.com"), (
            "https://wealth.example.com", "wealth.example.com"
        ))
        for value in (
            "http://wealth.example.com",
            "https://wealth.example.com/api",
            "https://user@wealth.example.com",
            "https://wealth.example.com?token=secret",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                _origin(value)

    def test_parses_only_lot_fields_and_requires_quantity_match(self) -> None:
        payload = json.dumps([
            {
                "report_date": "2026-08-26",
                "account_id": "must-not-be-retained",
                "conid": "9939",
                "quantity": "0.055",
                "cost_basis_price": "921.3385090910",
                "level_of_detail": "LOT",
                "open_datetime": "2026-06-05T12:18:27Z",
                "originating_transaction_id": "first",
            },
            {
                "report_date": "2026-08-26",
                "account_id": "must-not-be-retained",
                "conid": "9939",
                "quantity": "0.056",
                "cost_basis_price": "896.2348035710",
                "level_of_detail": "LOT",
                "open_datetime": "2026-06-05T14:15:41Z",
                "originating_transaction_id": "second",
            },
        ]).encode()

        grouped, report_date = WealthLotsProvider._parse(payload)
        provider = WealthLotsProvider()
        provider._lots_by_con_id = grouped

        slots = provider.slots_for_position(9939, Decimal("0.111"))
        self.assertEqual(report_date.isoformat(), "2026-08-26")
        self.assertEqual([slot.quantity for slot in slots], [Decimal("0.055"), Decimal("0.056")])
        self.assertEqual(
            [slot.price for slot in slots],
            [Decimal("921.3385090910"), Decimal("896.2348035710")],
        )
        self.assertTrue(all(slot.source == "wealth_lot" for slot in slots))
        self.assertEqual(provider.slots_for_position(9939, Decimal("0.112")), ())

    def test_credentials_hide_secret_fields_from_repr(self) -> None:
        credentials = WealthAccessCredentials(
            base_url="https://wealth.example.com",
            client_id="client-id-value",
            client_secret="client-secret-value",
        )
        rendered = repr(credentials)
        self.assertNotIn("client-id-value", rendered)
        self.assertNotIn("client-secret-value", rendered)


if __name__ == "__main__":
    unittest.main()
