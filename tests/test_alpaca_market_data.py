from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from openibkr_helper.alpaca import (
    ALLOWED_ALPACA_PATHS,
    AlpacaAuthenticationError,
    AlpacaEntitlementError,
    AlpacaHTTPTransport,
    AlpacaMarketDataError,
    AlpacaOvernightProvider,
    _record_trend,
    _snapshot_price,
    _trend_points,
    is_overnight_session,
)
from openibkr_helper.events import (
    MarketDataTypeEvent,
    QuoteEvent,
    QuoteTrendEvent,
)
from openibkr_helper.models import (
    AlpacaCredentials,
    Instrument,
    MarketDataKind,
    QuoteTrendPoint,
)


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

    def test_transport_distinguishes_invalid_credentials_from_feed_entitlement(self) -> None:
        credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )
        for status, error_type, message in (
            (401, AlpacaAuthenticationError, "invalid or have been revoked"),
            (403, AlpacaEntitlementError, "feed 'overnight' is not permitted"),
        ):
            with self.subTest(status=status):
                transport = AlpacaHTTPTransport()
                transport._opener = Mock()
                transport._opener.open.side_effect = HTTPError(
                    "https://data.alpaca.markets", status, "error", {}, None
                )
                with self.assertRaisesRegex(error_type, message):
                    transport._get_json(
                        "/v2/stocks/snapshots",
                        {"symbols": "AAPL", "feed": "overnight"},
                        credentials,
                    )

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


class _HistoryForbiddenTransport(_HistoryUnavailableTransport):
    async def get_json(self, path, query, credentials):  # noqa: ANN001, ANN201
        if path == "/v2/stocks/bars":
            raise AlpacaEntitlementError("BOATS is not permitted")
        return await super().get_json(path, query, credentials)


class AlpacaProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_configured_provider_is_not_active_until_data_arrives(self) -> None:
        provider = AlpacaOvernightProvider(_HistoryUnavailableTransport())
        provider._credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )
        overnight = datetime(2026, 8, 17, 1, 0, tzinfo=UTC)

        self.assertFalse(provider.status(overnight).active)

    async def test_configure_validates_before_returning_active_status(self) -> None:
        provider = AlpacaOvernightProvider(_HistoryUnavailableTransport())
        provider._instruments[1] = Instrument(
            con_id=1,
            symbol="AAPL",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
        )
        credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )

        with (
            patch("openibkr_helper.alpaca.is_overnight_session", return_value=True),
            patch(
                "openibkr_helper.alpaca.utc_now",
                return_value=datetime(2026, 8, 14, 3, 0, tzinfo=UTC),
            ),
        ):
            status = await provider.configure(credentials)
            self.assertTrue(status.active)
            self.assertIsNotNone(status.last_update_at)

        await provider.stop()

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

        with patch(
            "openibkr_helper.alpaca.utc_now",
            return_value=datetime(2026, 8, 14, 3, 0, tzinfo=UTC),
        ):
            await provider._refresh()

        last_events = [
            event for event in events if isinstance(event, QuoteEvent) and event.field == "last"
        ]
        self.assertEqual(last_events[-1].value, Decimal("100.20"))
        self.assertTrue(provider._has_fresh_data)

    async def test_boats_entitlement_failure_does_not_block_overnight_snapshot(self) -> None:
        provider = AlpacaOvernightProvider(_HistoryForbiddenTransport())
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

        with patch(
            "openibkr_helper.alpaca.utc_now",
            return_value=datetime(2026, 8, 14, 3, 0, tzinfo=UTC),
        ):
            await provider._refresh()

        self.assertTrue(provider._has_fresh_data)
        self.assertIsNone(provider._last_error)

    async def test_daytime_prefers_delayed_sip_for_a_basic_account(self) -> None:
        class DayFeedTransport:
            def __init__(self) -> None:
                self.feeds: list[str] = []

            async def get_json(self, path, query, credentials):  # noqa: ANN001, ANN201
                self.feeds.append(query["feed"])
                return {
                    "snapshots": {
                        "AAPL": {
                            "latestTrade": {
                                "t": "2026-08-17T14:59:58Z",
                                "p": 100.20,
                            }
                        }
                    }
                }

        transport = DayFeedTransport()
        provider = AlpacaOvernightProvider(transport)
        events = []

        async def collect(event):  # noqa: ANN001
            events.append(event)

        provider._sink = collect
        credentials = AlpacaCredentials(
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
        now = datetime(2026, 8, 17, 15, 0, tzinfo=UTC)

        self.assertTrue(await provider._refresh_snapshots(credentials, now))

        self.assertEqual(transport.feeds, ["delayed_sip"])
        self.assertEqual(
            [event.kind for event in events if isinstance(event, MarketDataTypeEvent)],
            [MarketDataKind.DELAYED],
        )
        last = next(
            event for event in events if isinstance(event, QuoteEvent) and event.field == "last"
        )
        self.assertEqual(last.observed_at, now)

    async def test_stale_overnight_symbol_falls_back_without_affecting_others(self) -> None:
        class MixedFeedTransport:
            def __init__(self) -> None:
                self.requests: list[tuple[str, str]] = []

            async def get_json(self, path, query, credentials):  # noqa: ANN001, ANN201
                self.requests.append((query["feed"], query["symbols"]))
                if query["feed"] == "overnight":
                    return {
                        "snapshots": {
                            "AAPL": {
                                "latestQuote": {
                                    "t": "2026-09-08T01:59:58Z",
                                    "bp": 100.10,
                                    "ap": 100.30,
                                }
                            },
                            "RAM": {
                                "latestQuote": {
                                    "t": "2026-08-31T08:00:00Z",
                                    "bp": 11.79,
                                    "ap": 12.49,
                                }
                            },
                        }
                    }
                return {
                    "snapshots": {
                        "RAM": {
                            "latestTrade": {
                                "t": "2026-09-05T00:00:06Z",
                                "p": 13.82,
                            }
                        }
                    }
                }

        transport = MixedFeedTransport()
        provider = AlpacaOvernightProvider(transport)
        events = []

        async def collect(event):  # noqa: ANN001
            events.append(event)

        provider._sink = collect
        provider._instruments[1] = Instrument(
            con_id=1,
            symbol="AAPL",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
        )
        provider._instruments[2] = Instrument(
            con_id=2,
            symbol="RAM",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
        )
        credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )

        self.assertTrue(
            await provider._refresh_snapshots(
                credentials,
                datetime(2026, 9, 8, 2, 0, tzinfo=UTC),
            )
        )

        self.assertEqual(
            transport.requests,
            [("overnight", "AAPL,RAM"), ("delayed_sip", "RAM")],
        )
        self.assertEqual(
            [event.kind for event in events if isinstance(event, MarketDataTypeEvent)],
            [MarketDataKind.OVERNIGHT_INDICATIVE, MarketDataKind.DELAYED],
        )
        last_by_con_id = {
            event.con_id: event.value
            for event in events
            if isinstance(event, QuoteEvent) and event.field == "last"
        }
        self.assertEqual(last_by_con_id, {1: Decimal("100.20"), 2: Decimal("13.82")})

    async def test_iex_is_used_only_when_delayed_sip_has_no_quote(self) -> None:
        class IEXFallbackTransport:
            def __init__(self) -> None:
                self.feeds: list[str] = []

            async def get_json(self, path, query, credentials):  # noqa: ANN001, ANN201
                self.feeds.append(query["feed"])
                if query["feed"] == "delayed_sip":
                    return {"snapshots": {}}
                return {
                    "snapshots": {
                        "AAPL": {
                            "latestTrade": {
                                "t": "2026-08-17T14:59:58Z",
                                "p": 100.20,
                            }
                        }
                    }
                }

        transport = IEXFallbackTransport()
        provider = AlpacaOvernightProvider(transport)
        events = []

        async def collect(event):  # noqa: ANN001
            events.append(event)

        provider._sink = collect
        provider._instruments[1] = Instrument(
            con_id=1,
            symbol="AAPL",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
        )
        credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )

        self.assertTrue(
            await provider._refresh_snapshots(
                credentials,
                datetime(2026, 8, 17, 15, 0, tzinfo=UTC),
            )
        )

        self.assertEqual(transport.feeds, ["delayed_sip", "iex"])
        self.assertEqual(
            [event.kind for event in events if isinstance(event, MarketDataTypeEvent)],
            [MarketDataKind.REAL_TIME],
        )

    async def test_fallback_quote_uses_matching_history_and_latest_trading_day(self) -> None:
        class FallbackHistoryTransport:
            def __init__(self) -> None:
                self.bar_requests: list[dict[str, str]] = []

            async def get_json(self, path, query, credentials):  # noqa: ANN001, ANN201
                if path == "/v2/stocks/snapshots":
                    if query["feed"] == "overnight":
                        return {
                            "snapshots": {
                                "RAM": {
                                    "latestTrade": {
                                        "t": "2026-08-31T08:00:00Z",
                                        "p": 12.14,
                                    }
                                }
                            }
                        }
                    return {
                        "snapshots": {
                            "RAM": {
                                "latestTrade": {
                                    "t": "2026-09-05T00:00:06Z",
                                    "p": 13.82,
                                }
                            }
                        }
                    }

                self.bar_requests.append(dict(query))
                start = datetime.fromisoformat(query["start"].replace("Z", "+00:00"))
                if start > datetime(2026, 9, 4, tzinfo=UTC):
                    return {"bars": {"RAM": []}}
                # Alpaca returns descending data because the provider requests the
                # latest bars first; parsing must restore chronological order.
                return {
                    "bars": {
                        "RAM": [
                            {"t": "2026-09-04T19:59:00Z", "c": 13.82},
                            {"t": "2026-09-04T19:58:00Z", "c": 13.75},
                            {"t": "2026-09-03T19:59:00Z", "c": 13.10},
                        ]
                    }
                }

        transport = FallbackHistoryTransport()
        provider = AlpacaOvernightProvider(transport)
        provider._credentials = AlpacaCredentials(
            key_id="PKTEST1234567890",
            secret_key="secret-value-that-must-never-be-logged",
        )
        provider._instruments[1] = Instrument(
            con_id=1,
            symbol="RAM",
            sec_type="STK",
            exchange="SMART",
            currency="USD",
        )
        now = datetime(2026, 9, 8, 2, 0, tzinfo=UTC)

        with patch("openibkr_helper.alpaca.utc_now", return_value=now):
            await provider._refresh()

        self.assertEqual(provider._snapshot_feeds[1], "delayed_sip")
        self.assertEqual([request["feed"] for request in transport.bar_requests], ["sip", "sip"])
        self.assertTrue(all(request["sort"] == "desc" for request in transport.bar_requests))
        self.assertGreaterEqual(len(provider._trends[1]), 2)
        self.assertEqual(
            {point.sampled_at.date() for point in provider._trends[1]},
            {datetime(2026, 9, 4, tzinfo=UTC).date()},
        )

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
