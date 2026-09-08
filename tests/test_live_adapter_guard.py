from __future__ import annotations

import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import Mock

from ibapi.message import OUT
from openibkr_helper.adapters.live import (
    LiveIBKRAdapter,
    _ExecutionFill,
    _HelperIBKRClient,
    _rebuild_cost_slots,
)
from openibkr_helper.config import HelperSettings
from openibkr_helper.events import PositionPnLEvent
from openibkr_helper.readonly_client import ReadOnlyIBKRClient, TradingDisabledError


class LiveAdapterGuardTests(unittest.TestCase):
    def test_cost_slots_fall_back_to_one_honest_historical_base(self) -> None:
        slots = _rebuild_cost_slots(265598, Decimal("10"), Decimal("101.25"), ())

        self.assertEqual(len(slots), 1)
        self.assertEqual(slots[0].source, "historical_base")
        self.assertEqual(slots[0].quantity, Decimal("10"))
        self.assertEqual(slots[0].price, Decimal("101.25"))

    def test_cost_slots_keep_surviving_today_execution_groups(self) -> None:
        fills = (
            _ExecutionFill("a", 265598, "BOT", Decimal("10"), Decimal("100"), "1", "7"),
            _ExecutionFill("b", 265598, "SLD", Decimal("5"), Decimal("110"), "2", "8"),
        )

        slots = _rebuild_cost_slots(265598, Decimal("5"), Decimal("100"), fills)

        self.assertEqual(len(slots), 1)
        self.assertEqual(slots[0].source, "execution")
        self.assertEqual(slots[0].quantity, Decimal("5"))
        self.assertEqual(slots[0].price, Decimal("100"))

    def test_cost_slots_derive_pre_today_base_without_faking_execution_prices(self) -> None:
        fills = (_ExecutionFill("a", 265598, "BOT", Decimal("2"), Decimal("120"), "1", "9"),)

        slots = _rebuild_cost_slots(265598, Decimal("12"), Decimal("105"), fills)

        self.assertEqual([slot.source for slot in slots], ["historical_base", "execution"])
        self.assertEqual(slots[0].quantity, Decimal("10"))
        self.assertEqual(slots[0].price, Decimal("102"))
        self.assertEqual(slots[1].price, Decimal("120"))

    def test_live_client_inherits_fail_closed_wire_guard(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = HelperSettings(
                session_token="live-adapter-test-token-at-least-32-characters",
                database_path=Path(directory) / "db.sqlite3",
                adapter="ibkr",
            )
            adapter = LiveIBKRAdapter(settings)
            client = _HelperIBKRClient(adapter)
            self.assertIsInstance(client, ReadOnlyIBKRClient)
            with self.assertRaises(TradingDisabledError):
                client.sendMsg(OUT.PLACE_ORDER, "must-not-reach-socket")

    def test_adapter_exposes_no_order_capability(self) -> None:
        public_methods = {
            name
            for name in dir(LiveIBKRAdapter)
            if not name.startswith("_") and callable(getattr(LiveIBKRAdapter, name))
        }
        forbidden_words = ("order", "trade", "exercise", "execution")
        self.assertFalse(
            {
                name
                for name in public_methods
                if any(word in name.lower() for word in forbidden_words)
            }
        )

    def test_connectivity_codes_drive_fail_safe_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = HelperSettings(
                session_token="connectivity-code-test-token-at-least-32-characters",
                database_path=Path(directory) / "db.sqlite3",
                adapter="ibkr",
            )
            adapter = LiveIBKRAdapter(settings)
            adapter.emit_from_thread = Mock()
            adapter.resubscribe_from_thread = Mock()
            adapter.disconnected_from_thread = Mock()
            client = _HelperIBKRClient(adapter)

            client.error(-1, 0, 1101, "connectivity restored; data lost")
            adapter.resubscribe_from_thread.assert_called_once_with()

            client.error(-1, 0, 1102, "connectivity restored; data maintained")
            self.assertEqual(
                adapter.emit_from_thread.call_args.args[0].state.value,
                "connected",
            )

            client.error(-1, 0, 1300, "socket port reset")
            adapter.disconnected_from_thread.assert_called_once_with()
            self.assertEqual(
                adapter.emit_from_thread.call_args.args[0].state.value,
                "disconnected",
            )

    def test_contract_errors_finish_pending_search_without_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = HelperSettings(
                session_token="contract-error-test-token-at-least-32-characters",
                database_path=Path(directory) / "db.sqlite3",
                adapter="ibkr",
            )
            adapter = LiveIBKRAdapter(settings)
            adapter.complete_contract_from_thread = Mock()
            adapter.reject_contract_from_thread = Mock()
            client = _HelperIBKRClient(adapter)

            client.error(8000, 0, 200, "no security definition")
            adapter.complete_contract_from_thread.assert_called_once_with(8000, ())

            client.error(8001, 0, 321, "validation error")
            adapter.reject_contract_from_thread.assert_called_once_with(8001, 321)

    def test_ib_market_data_requests_are_not_exposed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = HelperSettings(
                session_token="price-filter-test-token-at-least-32-characters",
                database_path=Path(directory) / "db.sqlite3",
                adapter="ibkr",
            )
            adapter = LiveIBKRAdapter(settings)
            client = _HelperIBKRClient(adapter)
            self.assertNotIn("subscribe_quote", dir(adapter))
            self.assertNotIn("market_requests", vars(client))

    def test_single_position_pnl_is_mapped_without_account_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = HelperSettings(
                session_token="position-pnl-test-token-at-least-32-characters",
                database_path=Path(directory) / "db.sqlite3",
                adapter="ibkr",
            )
            adapter = LiveIBKRAdapter(settings)
            adapter.emit_from_thread = Mock()
            client = _HelperIBKRClient(adapter)
            client.position_pnl_requests[20000] = 265598

            client.pnlSingle(20000, 10, 12.5, 100.25, 2.25, 1250.0)

            adapter.emit_from_thread.assert_called_once_with(
                PositionPnLEvent(
                    con_id=265598,
                    quantity=Decimal("10"),
                    daily_pnl=Decimal("12.5"),
                    unrealized_pnl=Decimal("100.25"),
                    realized_pnl=Decimal("2.25"),
                    market_value=Decimal("1250.0"),
                )
            )


if __name__ == "__main__":
    unittest.main()
