from __future__ import annotations

import asyncio
import tempfile
import unittest
from datetime import timedelta
from decimal import Decimal
from pathlib import Path

from openibkr_helper.adapters.fake import FakeIBKRAdapter
from openibkr_helper.config import HelperSettings
from openibkr_helper.events import (
    ConnectionEvent,
    QuoteEvent,
    QuoteResetEvent,
    QuoteTrendEvent,
)
from openibkr_helper.models import ContractQuery, GatewayState, QuoteTrendPoint, utc_now
from openibkr_helper.service import HelperService, WatchlistFullError

TOKEN = "service-test-token-that-is-at-least-32-characters"


class HelperServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        settings = HelperSettings(
            session_token=TOKEN,
            database_path=Path(self.temp.name) / "openibkr.sqlite3",
            pnl_stale_seconds=0.05,
            quote_stale_seconds=0.05,
            max_watchlist=2,
        )
        self.adapter = FakeIBKRAdapter(tick_interval=60.0)
        self.service = HelperService(settings, self.adapter)
        await self.service.start()

    async def asyncTearDown(self) -> None:
        await self.service.stop()
        self.temp.cleanup()

    async def test_start_populates_account_and_pnl(self) -> None:
        snapshot = await self.service.snapshot()
        self.assertEqual(snapshot.connection.state, GatewayState.CONNECTED)
        self.assertEqual(snapshot.account.account_masked, "*****FAKE")
        self.assertFalse(snapshot.pnl.stale)

    async def test_add_duplicate_remove_subscription(self) -> None:
        first = await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        duplicate = await self.service.add_watchlist(ContractQuery(symbol="aapl"))
        await asyncio.sleep(0)
        self.assertEqual(first, duplicate)
        self.assertEqual(self.adapter.subscribe_calls, [first.con_id])
        self.assertEqual(len((await self.service.snapshot()).quotes), 1)
        self.assertTrue(await self.service.remove_watchlist(first.con_id))
        self.assertEqual(self.adapter.unsubscribe_calls, [first.con_id])
        self.assertFalse(await self.service.remove_watchlist(first.con_id))

    async def test_watchlist_limit(self) -> None:
        await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        await self.service.add_watchlist(ContractQuery(symbol="MSFT"))
        with self.assertRaises(WatchlistFullError):
            await self.service.add_watchlist(ContractQuery(symbol="IBKR"))

    async def test_search_candidate_must_be_selected_from_latest_results(self) -> None:
        candidates = await self.service.search_contracts(ContractQuery(symbol="AMBIG"))
        self.assertEqual(len(candidates), 2)
        selected = await self.service.add_watchlist_instrument(candidates[1])
        self.assertEqual(selected, candidates[1])

        forged = candidates[0].model_copy(update={"con_id": candidates[0].con_id + 99})
        with self.assertRaisesRegex(RuntimeError, "latest contract search"):
            await self.service.add_watchlist_instrument(forged)

    async def test_disconnect_marks_all_values_stale(self) -> None:
        await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        await asyncio.sleep(0)
        await self.service.handle_adapter_event(ConnectionEvent(GatewayState.DISCONNECTED, 1100))
        snapshot = await self.service.snapshot()
        self.assertTrue(snapshot.account.stale)
        self.assertTrue(snapshot.pnl.stale)
        self.assertTrue(all(quote.stale for quote in snapshot.quotes))
        self.assertEqual(snapshot.connection.last_error_code, 1100)

    async def test_age_based_staleness(self) -> None:
        await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        await asyncio.sleep(0)
        changed = await self.service.store.refresh_staleness(
            pnl_seconds=1,
            quote_seconds=1,
            now=utc_now() + timedelta(seconds=2),
        )
        self.assertTrue(changed)
        snapshot = await self.service.snapshot()
        self.assertTrue(snapshot.pnl.stale)
        self.assertTrue(snapshot.quotes[0].stale)

    async def test_invalid_price_does_not_overwrite_last_valid_quote(self) -> None:
        instrument = await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        await asyncio.sleep(0)
        before = (await self.service.snapshot()).quotes[0]

        await self.service.handle_adapter_event(QuoteEvent(instrument.con_id, "last", Decimal("0")))
        after = (await self.service.snapshot()).quotes[0]

        self.assertEqual(after.last, before.last)
        self.assertEqual(after.received_at, before.received_at)

    async def test_fresh_subscription_resets_cached_quote(self) -> None:
        instrument = await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        await asyncio.sleep(0)

        await self.service.handle_adapter_event(QuoteResetEvent(instrument.con_id))
        quote = (await self.service.snapshot()).quotes[0]

        self.assertIsNone(quote.bid)
        self.assertIsNone(quote.ask)
        self.assertIsNone(quote.last)
        self.assertIsNone(quote.close)
        self.assertIsNone(quote.received_at)
        self.assertTrue(quote.stale)

    async def test_quote_trends_expire_against_wall_clock(self) -> None:
        instrument = await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        now = utc_now()
        await self.service.store.apply(
            QuoteTrendEvent(
                instrument.con_id,
                (
                    QuoteTrendPoint(sampled_at=now - timedelta(hours=25), price=Decimal("99")),
                    QuoteTrendPoint(sampled_at=now - timedelta(hours=1), price=Decimal("100")),
                ),
            )
        )

        self.assertTrue(await self.service.store.expire_quote_trends(now=now))
        trend = (await self.service.snapshot()).quotes[0].trend
        self.assertEqual([point.price for point in trend], [Decimal("100")])

    async def test_watchlist_restores_after_service_restart(self) -> None:
        instrument = await self.service.add_watchlist(ContractQuery(symbol="AAPL"))
        settings = self.service.settings
        await self.service.stop()

        replacement_adapter = FakeIBKRAdapter(tick_interval=60.0)
        replacement = HelperService(settings, replacement_adapter)
        await replacement.start()
        try:
            self.assertEqual(replacement_adapter.subscribe_calls, [instrument.con_id])
            self.assertEqual(len((await replacement.snapshot()).quotes), 1)
        finally:
            await replacement.stop()

        # Keep asyncTearDown idempotent after the explicit restart exercise.
        self.service = HelperService(settings, FakeIBKRAdapter(tick_interval=60.0))


if __name__ == "__main__":
    unittest.main()
