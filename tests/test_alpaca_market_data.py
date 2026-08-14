from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta
from decimal import Decimal

from openibkr_helper.alpaca import (
    ALLOWED_ALPACA_PATHS,
    AlpacaHTTPTransport,
    AlpacaMarketDataError,
    AlpacaOvernightProvider,
    _record_trend,
    _snapshot_price,
    _trend_points,
    is_overnight_session,
)
from openibkr_helper.events import QuoteEvent, QuoteTrendEvent
from openibkr_helper.models import AlpacaCredentials, Instrument, QuoteTrendPoint


class AlpacaMarketDataTests(unittest.TestCase):
    def test_transport_is_pinned_to_get_only_market_data_paths(self) -> None:
        url = AlpacaHTTPTransport.build_url(
            "/v2/stocks/snapshots", {"symbols": "AAPL", "feed": "overnight"}
        )
        self.assertTrue(url.startswith("https://data.alpaca.markets/v2/stocks/snapshots?"))
        self.assertEqual(
            ALLOWED_ALPACA_PATHS,
            {"/v2/stocks/snapshots", "/v2/stocks/bars"},
        )
        for path in (
            "/v2/orders",
            "https://api.alpaca.markets/v2/orders",
            "//api.alpaca.markets/v2/orders",
            "/../v2/orders",
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                AlpacaHTTPTransport.build_url(path, {})

    def test_credentials_are_redacted_from_repr(self) -> None:
        credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )
        rendered = repr(credentials)
        self.assertNotIn(credentials.key_id, rendered)
        self.assertNotIn(credentials.secret_key, rendered)

    def test_overnight_session_uses_new_york_clock(self) -> None:
        self.assertTrue(is_overnight_session(datetime(2026, 8, 17, 1, 0, tzinfo=UTC)))
        self.assertTrue(is_overnight_session(datetime(2026, 8, 17, 7, 0, tzinfo=UTC)))
        self.assertFalse(is_overnight_session(datetime(2026, 8, 17, 9, 0, tzinfo=UTC)))
        self.assertFalse(is_overnight_session(datetime(2026, 8, 16, 9, 0, tzinfo=UTC)))

    def test_snapshot_prefers_realtime_indicative_midpoint(self) -> None:
        fallback = datetime(2026, 8, 14, 3, 0, tzinfo=UTC)
        price, observed_at, bid, ask = _snapshot_price(
            {
                "latestQuote": {
                    "t": "2026-08-14T02:59:58Z",
                    "bp": 100.10,
                    "ap": 100.30,
                },
                "latestTrade": {"t": "2026-08-14T02:45:00Z", "p": 99.75},
            },
            fallback,
        )
        self.assertEqual(price, Decimal("100.20"))
        self.assertEqual(bid, Decimal("100.1"))
        self.assertEqual(ask, Decimal("100.3"))
        self.assertEqual(observed_at, datetime(2026, 8, 14, 2, 59, 58, tzinfo=UTC))

    def test_history_and_current_quote_form_a_bounded_curve(self) -> None:
        end = datetime(2026, 8, 14, 3, 0, tzinfo=UTC)
        start = end - timedelta(hours=24)
        history = _trend_points(
            [
                {"t": "2026-08-14T02:00:00Z", "c": 99.5},
                {"t": "2026-08-14T02:01:00Z", "c": 99.5},
                {"t": "2026-08-14T02:02:00Z", "c": 100.0},
            ],
            start=start,
            end=end,
        )
        self.assertEqual([point.price for point in history], [Decimal("99.5"), Decimal("100.0")])
        updated = _record_trend(Decimal("100.25"), end, history)
        self.assertEqual(updated[-1], QuoteTrendPoint(sampled_at=end, price=Decimal("100.25")))


class _HistoryUnavailableTransport:
    async def get_json(self, path, query, credentials):  # noqa: ANN001, ANN201
        if path == "/v2/stocks/bars":
            raise AlpacaMarketDataError("history unavailable")
        return {
            "snapshots": {
                "AAPL": {
                    "latestQuote": {
                        "t": "2026-08-14T02:59:58Z",
                        "bp": 100.10,
                        "ap": 100.30,
                    },
                    "prevDailyBar": {"c": 99.00},
                }
            }
        }


class AlpacaProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_history_failure_does_not_block_current_overnight_quote(self) -> None:
        provider = AlpacaOvernightProvider(_HistoryUnavailableTransport())
        events = []

        async def collect(event):  # noqa: ANN001
            events.append(event)

        provider._sink = collect
        provider._credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )
        provider._instruments[1] = Instrument(
            con_id=1,
            symbol="AAPL",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
        )

        await provider._refresh()

        last_events = [
            event for event in events if isinstance(event, QuoteEvent) and event.field == "last"
        ]
        self.assertEqual(last_events[-1].value, Decimal("100.20"))
        self.assertTrue(provider._has_fresh_data)

    async def test_in_memory_trends_expire_without_a_new_quote(self) -> None:
        provider = AlpacaOvernightProvider(_HistoryUnavailableTransport())
        events = []

        async def collect(event):  # noqa: ANN001
            events.append(event)

        now = datetime(2026, 8, 14, 3, 0, tzinfo=UTC)
        provider._sink = collect
        provider._trends[1] = (
            QuoteTrendPoint(sampled_at=now - timedelta(hours=25), price=Decimal("99")),
            QuoteTrendPoint(sampled_at=now - timedelta(hours=1), price=Decimal("100")),
        )

        await provider._expire_trends(now)

        self.assertEqual([point.price for point in provider._trends[1]], [Decimal("100")])
        self.assertTrue(any(isinstance(event, QuoteTrendEvent) for event in events))


if __name__ == "__main__":
    unittest.main()
