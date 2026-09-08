"""Read-only Alpaca all-session market-data client.

This module deliberately exposes only two fixed market-data endpoints.  It has
no account, position, order, or trading capability.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Callable, Mapping
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal, InvalidOperation
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zoneinfo import ZoneInfo

from .events import MarketDataStatusEvent, MarketDataTypeEvent, QuoteEvent, QuoteTrendEvent
from .models import (
    AlpacaCredentials,
    Instrument,
    MarketDataKind,
    MarketDataStatus,
    QuoteTrendPoint,
    utc_now,
)

ALPACA_DATA_ORIGIN = "https://data.alpaca.markets"
ALLOWED_ALPACA_PATHS = frozenset({"/v2/stocks/snapshots", "/v2/stocks/bars"})
OVERNIGHT_TIME_ZONE = ZoneInfo("America/New_York")
# Free-plan overnight trades can themselves be delayed by 15 minutes.  Allow a
# small margin beyond that, while still rejecting snapshots stranded on a prior
# session (for example, a symbol carrying Alpaca's ``overnight_halted`` flag).
OVERNIGHT_SNAPSHOT_MAX_AGE = timedelta(minutes=20)
STANDARD_HISTORY_WINDOW = timedelta(hours=24)
EXPANDED_HISTORY_WINDOWS = (timedelta(days=7), timedelta(days=31))

MarketEventSink = Callable[
    [MarketDataStatusEvent | MarketDataTypeEvent | QuoteEvent | QuoteTrendEvent],
    Awaitable[None],
]


class AlpacaMarketDataError(RuntimeError):
    pass


class AlpacaAuthenticationError(AlpacaMarketDataError):
    pass


class AlpacaEntitlementError(AlpacaMarketDataError):
    pass


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001, ANN201
        raise AlpacaMarketDataError("Alpaca market-data redirect was rejected")


class AlpacaTransport(Protocol):
    async def get_json(
        self,
        path: str,
        query: Mapping[str, str],
        credentials: AlpacaCredentials,
    ) -> Any: ...


class AlpacaHTTPTransport:
    """GET-only transport pinned to Alpaca's market-data origin."""

    def __init__(self, *, timeout: float = 15.0) -> None:
        self._timeout = timeout
        self._opener = build_opener(_RejectRedirects())

    @staticmethod
    def build_url(path: str, query: Mapping[str, str]) -> str:
        if path not in ALLOWED_ALPACA_PATHS:
            raise ValueError("Alpaca path is outside the read-only market-data allowlist")
        url = f"{ALPACA_DATA_ORIGIN}{path}?{urlencode(query)}"
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "data.alpaca.markets":
            raise ValueError("Alpaca market-data origin invariant failed")
        return url

    async def get_json(
        self,
        path: str,
        query: Mapping[str, str],
        credentials: AlpacaCredentials,
    ) -> Any:
        return await asyncio.to_thread(self._get_json, path, query, credentials)

    def _get_json(
        self,
        path: str,
        query: Mapping[str, str],
        credentials: AlpacaCredentials,
    ) -> Any:
        request = Request(
            self.build_url(path, query),
            method="GET",
            headers={
                "APCA-API-KEY-ID": credentials.key_id,
                "APCA-API-SECRET-KEY": credentials.secret_key,
                "Accept": "application/json",
                "User-Agent": "OpenIBKR/0.1 market-data-only",
            },
        )
        try:
            with self._opener.open(request, timeout=self._timeout) as response:
                if response.status != 200:
                    raise AlpacaMarketDataError("Alpaca market-data request failed")
                return json.loads(response.read(8 * 1024 * 1024))
        except HTTPError as exc:
            if exc.code == 401:
                raise AlpacaAuthenticationError(
                    "Alpaca market-data credentials are invalid or have been revoked"
                ) from exc
            if exc.code == 403:
                feed = query.get("feed", "requested")
                raise AlpacaEntitlementError(
                    f"Alpaca market-data feed '{feed}' is not permitted for this account"
                ) from exc
            if exc.code == 429:
                raise AlpacaMarketDataError("Alpaca market-data rate limit reached") from exc
            raise AlpacaMarketDataError("Alpaca market-data service returned an error") from exc
        except (URLError, TimeoutError) as exc:
            raise AlpacaMarketDataError("Alpaca market-data service is unreachable") from exc
        except (json.JSONDecodeError, ValueError) as exc:
            raise AlpacaMarketDataError("Alpaca market-data response was invalid") from exc


def is_overnight_session(now: datetime | None = None) -> bool:
    eastern = (now or utc_now()).astimezone(OVERNIGHT_TIME_ZONE)
    weekday = eastern.weekday()  # Monday = 0, Sunday = 6
    minutes = eastern.hour * 60 + eastern.minute
    evening = weekday in {6, 0, 1, 2, 3} and minutes >= 20 * 60
    morning = weekday in {0, 1, 2, 3, 4} and minutes < 4 * 60
    return evening or morning


class AlpacaOvernightProvider:
    """Polls Alpaca snapshots all day, using the dedicated overnight feed at night."""

    poll_seconds = 15.0
    history_refresh_seconds = 60.0

    def __init__(self, transport: AlpacaTransport | None = None) -> None:
        self._transport = transport or AlpacaHTTPTransport()
        self._sink: MarketEventSink | None = None
        self._credentials: AlpacaCredentials | None = None
        self._instruments: dict[int, Instrument] = {}
        self._task: asyncio.Task[None] | None = None
        self._wake = asyncio.Event()
        self._last_history_refresh: datetime | None = None
        self._last_update_at: datetime | None = None
        self._last_error: str | None = None
        self._last_status: MarketDataStatus | None = None
        self._has_fresh_data = False
        self._trends: dict[int, tuple[QuoteTrendPoint, ...]] = {}
        self._snapshot_feeds: dict[int, str] = {}

    @property
    def configured(self) -> bool:
        return self._credentials is not None

    def status(self, now: datetime | None = None) -> MarketDataStatus:
        configured = self.configured
        return MarketDataStatus(
            provider="alpaca",
            configured=configured,
            active=(configured and self._has_fresh_data and self._last_error is None),
            last_update_at=self._last_update_at,
            error=self._last_error,
        )

    async def start(self, sink: MarketEventSink) -> None:
        self._sink = sink
        await self._publish_status(force=True)

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        self._credentials = None
        self._has_fresh_data = False
        self._snapshot_feeds.clear()

    async def configure(self, credentials: AlpacaCredentials) -> MarketDataStatus:
        self._credentials = credentials
        self._last_error = None
        self._has_fresh_data = False
        self._last_history_refresh = None
        self._last_update_at = None
        self._snapshot_feeds.clear()
        if self._instruments:
            try:
                await self._refresh()
            except AlpacaMarketDataError as exc:
                self._last_error = str(exc)
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._run(), name="openibkr-alpaca-market-data")
        self._wake.set()
        await self._publish_status(force=True)
        return self.status()

    async def clear(self) -> MarketDataStatus:
        self._credentials = None
        self._last_error = None
        self._last_update_at = None
        self._trends.clear()
        self._snapshot_feeds.clear()
        self._has_fresh_data = False
        self._wake.set()
        await self._publish_status(force=True)
        return self.status()

    async def subscribe(self, instrument: Instrument) -> None:
        self._instruments[instrument.con_id] = instrument
        self._last_history_refresh = None
        self._wake.set()

    async def unsubscribe(self, con_id: int) -> None:
        self._instruments.pop(con_id, None)
        self._trends.pop(con_id, None)
        self._snapshot_feeds.pop(con_id, None)
        self._last_history_refresh = None
        self._wake.set()

    async def _run(self) -> None:
        while True:
            try:
                await self._expire_trends(utc_now())
                if self._credentials is None or not self._instruments:
                    await self._wait(30.0)
                    continue
                await self._refresh()
                await self._wait(self.poll_seconds)
            except asyncio.CancelledError:
                raise
            except AlpacaMarketDataError as exc:
                self._last_error = str(exc)
                self._has_fresh_data = False
                await self._publish_status(force=True)
                await self._wait(self.poll_seconds)
            except Exception:
                self._last_error = "Alpaca market-data update failed"
                self._has_fresh_data = False
                await self._publish_status(force=True)
                await self._wait(self.poll_seconds)

    async def _expire_trends(self, now: datetime) -> None:
        for con_id, points in list(self._trends.items()):
            retention = (
                EXPANDED_HISTORY_WINDOWS[-1]
                if self._snapshot_feeds.get(con_id) in {"delayed_sip", "iex"}
                else STANDARD_HISTORY_WINDOW
            )
            cutoff = now - retention
            retained = tuple(point for point in points if cutoff <= point.sampled_at <= now)
            if retained == points:
                continue
            self._trends[con_id] = retained
            await self._emit(QuoteTrendEvent(con_id, retained))

    async def _wait(self, duration: float) -> None:
        try:
            async with asyncio.timeout(duration):
                await self._wake.wait()
        except TimeoutError:
            pass
        self._wake.clear()

    async def _refresh(self) -> None:
        credentials = self._credentials
        if credentials is None:
            return
        now = utc_now()
        updated = await self._refresh_snapshots(credentials, now)
        self._has_fresh_data = updated
        self._last_error = None
        if updated:
            self._last_update_at = now
        if (
            self._last_history_refresh is None
            or (now - self._last_history_refresh).total_seconds() >= self.history_refresh_seconds
        ):
            try:
                await self._refresh_history(credentials, now)
            except (AlpacaAuthenticationError, AlpacaEntitlementError):
                # Historical feed access varies by subscription. It is optional:
                # a rejected history request must not block the current snapshot.
                pass
            except AlpacaMarketDataError:
                # Missing or temporarily unavailable history must not prevent the
                # current quote from updating.
                pass
            self._last_history_refresh = now
        await self._publish_status(force=updated)

    async def _refresh_history(self, credentials: AlpacaCredentials, now: datetime) -> None:
        for con_id, instrument in self._instruments.items():
            snapshot_feed = self._snapshot_feeds.get(con_id)
            if snapshot_feed is None:
                snapshot_feed = "overnight" if is_overnight_session(now) else "delayed_sip"
            history_feed = {
                "overnight": "boats",
                "delayed_sip": "sip",
                "iex": "iex",
            }[snapshot_feed]
            points = await self._history_points_for_instrument(
                credentials,
                instrument,
                history_feed=history_feed,
                expand=snapshot_feed != "overnight",
                now=now,
            )
            if points:
                merged = _merge_trend_points(points, self._trends.get(con_id, ()))
                self._trends[con_id] = merged
                await self._emit(QuoteTrendEvent(con_id, merged))

    async def _history_points_for_instrument(
        self,
        credentials: AlpacaCredentials,
        instrument: Instrument,
        *,
        history_feed: str,
        expand: bool,
        now: datetime,
    ) -> tuple[QuoteTrendPoint, ...]:
        end = now if history_feed == "iex" else now - timedelta(minutes=15)
        windows = (STANDARD_HISTORY_WINDOW,)
        if expand:
            windows += EXPANDED_HISTORY_WINDOWS

        latest_points: tuple[QuoteTrendPoint, ...] = ()
        for window in windows:
            start = end - window
            try:
                payload = await self._transport.get_json(
                    "/v2/stocks/bars",
                    {
                        "symbols": instrument.symbol,
                        "timeframe": "1Min",
                        "start": _api_time(start),
                        "end": _api_time(end),
                        "feed": history_feed,
                        "adjustment": "raw",
                        "limit": "10000",
                        "sort": "desc",
                    },
                    credentials,
                )
            except (AlpacaAuthenticationError, AlpacaEntitlementError):
                return ()
            except AlpacaMarketDataError:
                return latest_points

            bars_by_symbol = payload.get("bars", {}) if isinstance(payload, dict) else {}
            raw_bars = bars_by_symbol.get(instrument.symbol, [])
            points = _trend_points(raw_bars, start=start, end=end)
            if len(points) >= 2:
                return points if window == STANDARD_HISTORY_WINDOW else _latest_trading_day(points)
            if points:
                latest_points = points
        return latest_points

    async def _refresh_snapshots(
        self,
        credentials: AlpacaCredentials,
        now: datetime,
    ) -> bool:
        symbols = self._symbol_list()
        if not symbols:
            return False
        overnight = is_overnight_session(now)
        # Basic accounts have full-market delayed SIP data throughout the regular
        # and extended sessions.  At night, keep Alpaca's indicative feed for
        # eligible symbols, but resolve missing/stale symbols independently so one
        # overnight halt cannot blank the entire watchlist.
        feed_order = ("overnight", "delayed_sip", "iex") if overnight else ("delayed_sip", "iex")
        unresolved = set(symbols)
        selected: dict[str, tuple[Mapping[str, Any], str]] = {}
        errors: list[AlpacaMarketDataError] = []

        for feed in feed_order:
            if not unresolved:
                break
            requested = tuple(sorted(unresolved))
            try:
                snapshots = await self._fetch_snapshots(
                    credentials,
                    requested,
                    feed,
                )
            except AlpacaAuthenticationError:
                raise
            except AlpacaMarketDataError as exc:
                errors.append(exc)
                continue

            for symbol in requested:
                raw = snapshots.get(symbol)
                if not isinstance(raw, Mapping):
                    continue
                price, _observed_at, _bid, _ask = _snapshot_price(raw, now)
                if price is None:
                    continue
                if feed == "overnight" and not _snapshot_is_recent_overnight(raw, now):
                    continue
                selected[symbol] = (raw, feed)
                unresolved.discard(symbol)

        if not selected:
            # Preserve a useful transport/entitlement error when every attempted
            # fallback failed. A wholly successful empty response is a valid
            # no-data poll, but a partial outage should remain visible.
            if errors:
                raise errors[-1]
            return False

        self._last_error = None
        updated = False
        for con_id, instrument in self._instruments.items():
            resolved = selected.get(instrument.symbol)
            if resolved is None:
                continue
            raw, feed = resolved
            self._snapshot_feeds[con_id] = feed
            price, observed_at, bid, ask = _snapshot_price(raw, now)
            if price is None:
                continue
            kind = (
                MarketDataKind.OVERNIGHT_INDICATIVE
                if feed == "overnight"
                else MarketDataKind.DELAYED
                if feed == "delayed_sip"
                else MarketDataKind.REAL_TIME
            )
            await self._emit(MarketDataTypeEvent(con_id, kind))
            # QuoteSnapshot.received_at drives connection freshness.  The actual
            # exchange timestamp remains attached to the trend point below.
            if bid is not None:
                await self._emit(QuoteEvent(con_id, "bid", bid, now))
            if ask is not None:
                await self._emit(QuoteEvent(con_id, "ask", ask, now))
            await self._emit(QuoteEvent(con_id, "last", price, now))
            close = _decimal_from_mapping(raw.get("prevDailyBar"), "c")
            if close is not None:
                await self._emit(QuoteEvent(con_id, "close", close, now))
            trend = _record_trend(price, observed_at, self._trends.get(con_id, ()))
            self._trends[con_id] = trend
            await self._emit(QuoteTrendEvent(con_id, trend))
            updated = True
        return updated

    async def _fetch_snapshots(
        self,
        credentials: AlpacaCredentials,
        symbols: tuple[str, ...],
        feed: str,
    ) -> Mapping[str, Any]:
        payload = await self._transport.get_json(
            "/v2/stocks/snapshots",
            {"symbols": ",".join(symbols), "feed": feed},
            credentials,
        )
        if not isinstance(payload, Mapping):
            return {}
        snapshots = payload.get("snapshots", payload)
        return snapshots if isinstance(snapshots, Mapping) else {}

    def _symbol_list(self) -> tuple[str, ...]:
        return tuple(sorted({item.symbol for item in self._instruments.values()}))

    async def _emit(
        self,
        event: MarketDataStatusEvent | MarketDataTypeEvent | QuoteEvent | QuoteTrendEvent,
    ) -> None:
        if self._sink is not None:
            await self._sink(event)

    async def _publish_status(self, *, force: bool = False) -> None:
        status = self.status()
        if force or status != self._last_status:
            self._last_status = status
            await self._emit(MarketDataStatusEvent(status))


def _api_time(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _parse_time(value: Any, fallback: datetime) -> datetime:
    if not isinstance(value, str):
        return fallback
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(UTC)
    except ValueError:
        return fallback


def _decimal(value: Any) -> Decimal | None:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None
    return result if result > 0 and result.is_finite() else None


def _decimal_from_mapping(value: Any, key: str) -> Decimal | None:
    return _decimal(value.get(key)) if isinstance(value, Mapping) else None


def _snapshot_price(
    snapshot: Mapping[str, Any],
    fallback_time: datetime,
) -> tuple[Decimal | None, datetime, Decimal | None, Decimal | None]:
    quote = snapshot.get("latestQuote")
    bid = _decimal_from_mapping(quote, "bp")
    ask = _decimal_from_mapping(quote, "ap")
    if bid is not None and ask is not None:
        return (bid + ask) / Decimal(2), _parse_time(quote.get("t"), fallback_time), bid, ask
    trade = snapshot.get("latestTrade")
    trade_price = _decimal_from_mapping(trade, "p")
    if trade_price is not None:
        return trade_price, _parse_time(trade.get("t"), fallback_time), bid, ask
    bar = snapshot.get("minuteBar")
    bar_price = _decimal_from_mapping(bar, "c")
    if bar_price is not None:
        return bar_price, _parse_time(bar.get("t"), fallback_time), bid, ask
    return None, fallback_time, bid, ask


def _snapshot_is_recent_overnight(
    snapshot: Mapping[str, Any],
    now: datetime,
) -> bool:
    """Return whether the price chosen from an overnight snapshot is current."""

    quote = snapshot.get("latestQuote")
    if (
        _decimal_from_mapping(quote, "bp") is not None
        and _decimal_from_mapping(quote, "ap") is not None
    ):
        timestamp = quote.get("t") if isinstance(quote, Mapping) else None
    else:
        trade = snapshot.get("latestTrade")
        if _decimal_from_mapping(trade, "p") is not None:
            timestamp = trade.get("t") if isinstance(trade, Mapping) else None
        else:
            bar = snapshot.get("minuteBar")
            timestamp = bar.get("t") if isinstance(bar, Mapping) else None

    if not isinstance(timestamp, str):
        return False
    observed_at = _parse_time(timestamp, now - OVERNIGHT_SNAPSHOT_MAX_AGE * 2)
    age = now.astimezone(UTC) - observed_at
    return -timedelta(minutes=1) <= age <= OVERNIGHT_SNAPSHOT_MAX_AGE


def _trend_points(
    bars: Any,
    *,
    start: datetime,
    end: datetime,
) -> tuple[QuoteTrendPoint, ...]:
    if not isinstance(bars, list):
        return ()
    parsed_points: list[QuoteTrendPoint] = []
    for bar in bars:
        if not isinstance(bar, Mapping):
            continue
        price = _decimal(bar.get("c"))
        sampled_at = _parse_time(bar.get("t"), end)
        if price is None or sampled_at < start or sampled_at > end:
            continue
        parsed_points.append(QuoteTrendPoint(sampled_at=sampled_at, price=price))
    return _normalized_trend_points(parsed_points)


def _normalized_trend_points(
    points: list[QuoteTrendPoint] | tuple[QuoteTrendPoint, ...],
) -> tuple[QuoteTrendPoint, ...]:
    by_time = {point.sampled_at: point for point in points}
    ordered = sorted(by_time.values(), key=lambda point: point.sampled_at)
    compressed: list[QuoteTrendPoint] = []
    for point in ordered:
        if not compressed or compressed[-1].price != point.price:
            compressed.append(point)
    # A completely flat but actively traded session still needs two endpoints
    # for Swift Charts to draw its horizontal line.
    if len(compressed) == 1 and len(ordered) >= 2:
        compressed.append(ordered[-1])
    return tuple(compressed[-1440:])


def _latest_trading_day(
    points: tuple[QuoteTrendPoint, ...],
) -> tuple[QuoteTrendPoint, ...]:
    by_day: dict[date, list[QuoteTrendPoint]] = {}
    for point in points:
        trading_day = point.sampled_at.astimezone(OVERNIGHT_TIME_ZONE).date()
        by_day.setdefault(trading_day, []).append(point)
    for trading_day in sorted(by_day, reverse=True):
        day_points = _normalized_trend_points(by_day[trading_day])
        if len(day_points) >= 2:
            return day_points
    return _normalized_trend_points(points)


def _merge_trend_points(
    history: tuple[QuoteTrendPoint, ...],
    current: tuple[QuoteTrendPoint, ...],
) -> tuple[QuoteTrendPoint, ...]:
    if not history:
        return current
    earliest = history[0].sampled_at
    relevant_current = tuple(point for point in current if point.sampled_at >= earliest)
    return _normalized_trend_points(history + relevant_current)


def _record_trend(
    price: Decimal,
    sampled_at: datetime,
    points: tuple[QuoteTrendPoint, ...],
) -> tuple[QuoteTrendPoint, ...]:
    cutoff = sampled_at - timedelta(hours=24)
    result = [point for point in points if cutoff <= point.sampled_at <= sampled_at]
    bucket = sampled_at.replace(second=0, microsecond=0)
    point = QuoteTrendPoint(sampled_at=bucket, price=price)
    if result and result[-1].sampled_at == bucket:
        result[-1] = point
    elif not result or result[-1].price != point.price:
        result.append(point)
    return tuple(result[-1440:])
