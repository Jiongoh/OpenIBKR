from __future__ import annotations

import unittest

from ibapi.common import PROTOBUF_MSG_ID
from ibapi.message import OUT
from openibkr_spike.cli import build_parser, run
from openibkr_spike.readonly_client import (
    ALLOWED_OUTGOING,
    FORBIDDEN_TRADING_OUTGOING,
    ReadOnlyIBKRClient,
    TradingDisabledError,
    mask_identifier,
)


class ReadOnlyGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = ReadOnlyIBKRClient()

    def test_trading_messages_are_disjoint_from_allowlist(self) -> None:
        self.assertTrue(FORBIDDEN_TRADING_OUTGOING)
        self.assertTrue(FORBIDDEN_TRADING_OUTGOING.isdisjoint(ALLOWED_OUTGOING))

    def test_every_known_non_allowlisted_message_fails_closed(self) -> None:
        for outgoing in OUT:
            if outgoing in ALLOWED_OUTGOING:
                continue
            with self.subTest(outgoing=outgoing.name):
                with self.assertRaises(TradingDisabledError):
                    self.client._assert_allowed(outgoing, protobuf=False)

    def test_trading_messages_blocked_on_legacy_and_protobuf_paths(self) -> None:
        for outgoing in FORBIDDEN_TRADING_OUTGOING:
            with self.subTest(outgoing=outgoing.name, path="legacy"):
                with self.assertRaises(TradingDisabledError):
                    self.client._assert_allowed(outgoing, protobuf=False)
            with self.subTest(outgoing=outgoing.name, path="protobuf"):
                with self.assertRaises(TradingDisabledError):
                    self.client._assert_allowed(outgoing + PROTOBUF_MSG_ID, protobuf=True)

    def test_wire_send_entry_points_block_trading_before_socket_access(self) -> None:
        with self.assertRaises(TradingDisabledError):
            self.client.sendMsg(OUT.PLACE_ORDER, "payload-must-not-be-sent")
        with self.assertRaises(TradingDisabledError):
            self.client.sendMsgProtoBuf(
                OUT.PLACE_ORDER + PROTOBUF_MSG_ID, b"payload-must-not-be-sent"
            )

    def test_unknown_and_wrong_wire_format_messages_are_blocked(self) -> None:
        with self.assertRaises(TradingDisabledError):
            self.client._assert_allowed(199, protobuf=False)
        with self.assertRaises(TradingDisabledError):
            self.client._assert_allowed(OUT.REQ_MKT_DATA, protobuf=True)
        with self.assertRaises(TradingDisabledError):
            self.client._assert_allowed(OUT.REQ_MKT_DATA + PROTOBUF_MSG_ID, protobuf=False)

    def test_explicit_trading_entry_points_always_raise(self) -> None:
        entry_points = (
            "placeOrder",
            "cancelOrder",
            "reqGlobalCancel",
            "exerciseOptions",
            "reqIds",
            "reqOpenOrders",
            "reqAllOpenOrders",
            "reqAutoOpenOrders",
            "reqCompletedOrders",
            "reqExecutions",
        )
        for method_name in entry_points:
            with self.subTest(method=method_name):
                with self.assertRaises(TradingDisabledError):
                    getattr(self.client, method_name)()

    def test_only_literal_loopback_and_nonzero_client_id_are_allowed(self) -> None:
        ReadOnlyIBKRClient.validate_endpoint("127.0.0.1", 4003, 71)
        for host in ("localhost", "0.0.0.0", "192.168.1.2", "::1"):
            with self.subTest(host=host):
                with self.assertRaises(ValueError):
                    ReadOnlyIBKRClient.validate_endpoint(host, 4003, 71)
        with self.assertRaises(ValueError):
            ReadOnlyIBKRClient.validate_endpoint("127.0.0.1", 4003, 0)

    def test_snapshot_never_exposes_raw_account_ids_or_financial_values(self) -> None:
        self.client.snapshot.accounts = ["U00000000"]
        self.client.pnl(1, 123.45, -67.89, 0.0)
        public = self.client.snapshot.public_dict()
        rendered = repr(public)
        self.assertNotIn("U00000000", rendered)
        self.assertNotIn("123.45", rendered)
        self.assertNotIn("-67.89", rendered)
        self.assertEqual(public["accounts_masked"], ["*****0000"])

    def test_market_type_callback_is_not_mistaken_for_a_tick(self) -> None:
        self.client.marketDataType(1, 3)
        self.assertTrue(self.client.market_type_event.is_set())
        self.assertFalse(self.client.market_tick_event.is_set())
        self.assertFalse(self.client.market_error_event.is_set())

    def test_mask_identifier(self) -> None:
        self.assertEqual(mask_identifier("U00000000"), "*****0000")
        self.assertEqual(mask_identifier("1234"), "****")
        self.assertEqual(mask_identifier(""), "")

    def test_reconnect_probe_rejects_invalid_timeouts_without_connecting(self) -> None:
        args = build_parser().parse_args(
            ["reconnect", "--outage-timeout", "0", "--reconnect-timeout", "1"]
        )
        result = run(args)
        self.assertFalse(result["success"])
        self.assertIn("Reconnect timeouts must be positive", result["failure"])


if __name__ == "__main__":
    unittest.main()
