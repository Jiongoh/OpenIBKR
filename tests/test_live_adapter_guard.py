from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from ibapi.message import OUT
from openibkr_helper.adapters.live import LiveIBKRAdapter, _HelperIBKRClient
from openibkr_helper.config import HelperSettings
from openibkr_spike.readonly_client import ReadOnlyIBKRClient, TradingDisabledError


class LiveAdapterGuardTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
