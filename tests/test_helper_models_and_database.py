from __future__ import annotations

import os
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path

from openibkr_helper.config import HelperSettings
from openibkr_helper.database import SCHEMA_VERSION, Database
from openibkr_helper.models import (
    AccountSnapshot,
    AppSnapshot,
    ContractQuery,
    Instrument,
    MarketDataKind,
    PnLSnapshot,
)
from pydantic import ValidationError

TOKEN = "test-token-that-is-at-least-32-characters-long"


def settings_for(path: Path, **overrides: object) -> HelperSettings:
    values: dict[str, object] = {
        "session_token": TOKEN,
        "database_path": path,
    }
    values.update(overrides)
    return HelperSettings(**values)


class ModelAndConfigTests(unittest.TestCase):
    def test_protocol_serializes_decimal_as_string(self) -> None:
        snapshot = AppSnapshot(
            pnl=PnLSnapshot(
                daily=Decimal("12.34"),
                unrealized=Decimal("10.01"),
                realized=Decimal("2.33"),
                stale=False,
            )
        )
        payload = snapshot.model_dump(mode="json")
        self.assertEqual(payload["pnl"]["daily"], "12.34")
        self.assertEqual(payload["protocol_version"], 1)

    def test_protocol_rejects_unknown_fields_and_bad_query(self) -> None:
        with self.assertRaises(ValidationError):
            ContractQuery(symbol="AAPL", unexpected=True)
        with self.assertRaises(ValidationError):
            ContractQuery(symbol="AAPL;DROP")

    def test_market_data_type_mapping_is_explicit(self) -> None:
        self.assertEqual(MarketDataKind.from_ibkr(1), MarketDataKind.REAL_TIME)
        self.assertEqual(MarketDataKind.from_ibkr(3), MarketDataKind.DELAYED)
        self.assertEqual(MarketDataKind.from_ibkr(999), MarketDataKind.UNKNOWN)

    def test_settings_reject_non_loopback_and_weak_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "db.sqlite3"
            settings_for(path)
            with self.assertRaises(ValidationError):
                settings_for(path, bind_host="0.0.0.0")
            with self.assertRaises(ValidationError):
                settings_for(path, gateway_host="localhost")
            with self.assertRaises(ValidationError):
                settings_for(path, gateway_client_id=0)
            with self.assertRaises(ValidationError):
                settings_for(path, session_token="too-short")

    def test_settings_repr_does_not_contain_session_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = settings_for(Path(directory) / "db.sqlite3")
            self.assertNotIn(TOKEN, repr(settings))


class DatabaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "nested" / "openibkr.sqlite3"
        self.database = Database(self.path)
        self.instrument = Instrument(
            con_id=265598,
            symbol="AAPL",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
            primary_exchange="NASDAQ",
            local_symbol="AAPL",
        )

    def tearDown(self) -> None:
        self.database.close()
        self.temp.cleanup()

    def test_migration_is_idempotent_and_file_is_private(self) -> None:
        self.database.open()
        self.assertEqual(self.database.schema_version, SCHEMA_VERSION)
        self.database.close()
        self.database.open()
        self.assertEqual(self.database.schema_version, SCHEMA_VERSION)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_watchlist_crud_is_idempotent(self) -> None:
        self.database.open()
        self.assertTrue(self.database.add_to_watchlist(self.instrument))
        self.assertFalse(self.database.add_to_watchlist(self.instrument))
        self.assertEqual(self.database.watchlist_count(), 1)
        self.assertEqual(self.database.list_watchlist(), [self.instrument])
        self.assertTrue(self.database.remove_from_watchlist(self.instrument.con_id))
        self.assertFalse(self.database.remove_from_watchlist(self.instrument.con_id))

    def test_public_snapshot_round_trip(self) -> None:
        self.database.open()
        snapshot = AppSnapshot(
            sequence=42,
            account=AccountSnapshot(account_masked="*****TEST", stale=True),
            pnl=PnLSnapshot(daily=Decimal("12.34"), stale=True),
        )
        self.database.save_public_snapshot(snapshot)
        restored = self.database.load_public_snapshot()
        self.assertIsNotNone(restored)
        assert restored is not None
        self.assertEqual(restored.sequence, 42)
        self.assertEqual(restored.account.account_masked, "*****TEST")
        self.assertEqual(restored.pnl.daily, Decimal("12.34"))

    def test_pnl_minute_snapshot_is_deduplicated(self) -> None:
        self.database.open()
        snapshot = AppSnapshot(
            account=AccountSnapshot(currency="USD", stale=False),
            pnl=PnLSnapshot(
                daily=Decimal("12.34"),
                unrealized=Decimal("10.00"),
                realized=Decimal("2.34"),
                received_at=datetime(2026, 8, 7, 3, 30, 15, tzinfo=UTC),
                stale=False,
            ),
        )
        self.assertTrue(self.database.save_pnl_minute(snapshot))
        self.assertFalse(self.database.save_pnl_minute(snapshot))
        self.assertEqual(self.database.pnl_minute_count(), 1)

    def test_pnl_minute_samples_expire_after_twenty_four_hours(self) -> None:
        self.database.open()
        now = datetime(2026, 8, 14, 7, 0, tzinfo=UTC)
        old_snapshot = AppSnapshot(
            account=AccountSnapshot(currency="USD", stale=False),
            pnl=PnLSnapshot(
                daily=Decimal("1.00"),
                received_at=now - timedelta(hours=25),
                stale=False,
            ),
        )
        self.assertTrue(self.database.save_pnl_minute(old_snapshot))
        self.assertEqual(self.database.pnl_minute_count(), 1)

        self.assertEqual(self.database.prune_pnl_minute(now=now), 1)
        self.assertEqual(self.database.pnl_minute_count(), 0)


if __name__ == "__main__":
    unittest.main()
