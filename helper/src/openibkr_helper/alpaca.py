"""Read-only Alpaca overnight market-data client.

This module deliberately exposes only two fixed market-data endpoints.  It has
no account, position, order, or trading capability.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Awaitable, Callable, Mapping
from datetime import UTC, datetime, timedelta
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

MarketEventSink = Callable[
    [MarketDataStatusEvent | MarketDataTypeEvent | QuoteEvent | QuoteTrendEvent],
    Awaitable[None],
]


class AlpacaMarketDataError(RuntimeError):
    pass


class AlpacaAuthenticationError(AlpacaMarketDataError):
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
            if exc.code in {401, 403}:
                raise AlpacaAuthenticationError(
                    "Alpaca market-data credentials were rejected"
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
    """Polls official overnight snapshots and delayed BOATS minute bars."""

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

    @property
    def configured(self) -> bool:
        return self._credentials is not None

    def should_override_quotes(self, now: datetime | None = None) -> bool:
        return self.configured and self._has_fresh_data and is_overnight_session(now)

    def status(self, now: datetime | None = None) -> MarketDataStatus:
        configured = self.configured
        return MarketDataStatus(
            provider="alpaca_overnight" if configured else "ibkr",
            configured=configured,
            active=configured and is_overnight_session(now),
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

    async def configure(self, credentials: AlpacaCredentials) -> MarketDataStatus:
        self._credentials = credentials
        self._last_error = None
        self._has_fresh_data = False
        self._last_history_refresh = None
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._run(), name="openibkr-alpaca-overnight")
        self._wake.set()
        await self._publish_status(force=True)
        return self.status()

    async def clear(self) -> MarketDataStatus:
        self._credentials = None
        self._has_fresh_data = False
        self._last_error = None
        self._last_update_at = None
        self._trends.clear()
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
        self._last_history_refresh = None
        self._wake.set()

    async def _run(self) -> None:
        while True:
            try:
                await self._expire_trends(utc_now())
                if self._credentials is None or not self._instruments:
                    await self._wait(30.0)
                    continue
                if not is_overnight_session():
                    self._has_fresh_data = False
                    await self._publish_status()
                    await self._wait(30.0)
                    continue
                await self._refresh()
                await self._wait(self.poll_seconds)
            except asyncio.CancelledError:
                raise
            except AlpacaMarketDataError as exc:
                self._last_error = str(exc)
                await self._publish_status(force=True)
                await self._wait(self.poll_seconds)
            except Exception:
                self._last_error = "Alpaca market-data update failed"
                await self._publish_status(force=True)
                await self._wait(self.poll_seconds)

    async def _expire_trends(self, now: datetime) -> None:
        cutoff = now - timedelta(hours=24)
        for con_id, points in list(self._trends.items()):
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
        if (
            self._last_history_refresh is None
            or (now - self._last_history_refresh).total_seconds() >= self.history_refresh_seconds
        ):
            try:
                await self._refresh_history(credentials, now)
            except AlpacaAuthenticationError:
                raise
            except AlpacaMarketDataError:
                # A missing or temporarily unavailable history entitlement must not
                # prevent the current indicative overnight quote from updating.
                pass
            self._last_history_refresh = now
        updated = await self._refresh_snapshots(credentials, now)
        if updated:
            self._has_fresh_data = True
            self._last_update_at = now
            self._last_error = None
            await self._publish_status(force=True)

    async def _refresh_history(self, credentials: AlpacaCredentials, now: datetime) -> None:
        symbols = self._symbol_list()
        if not symbols:
            return
        end = now - timedelta(minutes=15)
        start = now - timedelta(hours=24)
        for con_id, instrument in self._instruments.items():
            try:
                payload = await self._transport.get_json(
                    "/v2/stocks/bars",
                    {
                        "symbols": instrument.symbol,
                        "timeframe": "1Min",
                        "start": _api_time(start),
                        "end": _api_time(end),
                        "feed": "boats",
                        "adjustment": "raw",
                        "limit": "10000",
                        "sort": "asc",
                    },
                    credentials,
                )
            except AlpacaAuthenticationError:
                raise
            except AlpacaMarketDataError:
                continue
            bars_by_symbol = payload.get("bars", {}) if isinstance(payload, dict) else {}
            raw_bars = bars_by_symbol.get(instrument.symbol, [])
            points = _trend_points(raw_bars, start=start, end=end)
            if points:
                self._trends[con_id] = points
                await self._emit(QuoteTrendEvent(con_id, points))

    async def _refresh_snapshots(
        self,
        credentials: AlpacaCredentials,
        now: datetime,
    ) -> bool:
        symbols = self._symbol_list()
        if not symbols:
            return False
        payload = await self._transport.get_json(
            "/v2/stocks/snapshots",
            {"symbols": ",".join(symbols), "feed": "overnight"},
            credentials,
        )
        if not isinstance(payload, dict):
            return False
        snapshots = payload.get("snapshots", payload)
        if not isinstance(snapshots, dict):
            return False
        updated = False
        for con_id, instrument in self._instruments.items():
            raw = snapshots.get(instrument.symbol)
            if not isinstance(raw, dict):
                continue
            price, observed_at, bid, ask = _snapshot_price(raw, now)
            if price is None:
                continue
            await self._emit(MarketDataTypeEvent(con_id, MarketDataKind.OVERNIGHT_INDICATIVE))
            if bid is not None:
                await self._emit(QuoteEvent(con_id, "bid", bid, observed_at))
            if ask is not None:
                await self._emit(QuoteEvent(con_id, "ask", ask, observed_at))
            await self._emit(QuoteEvent(con_id, "last", price, observed_at))
            close = _decimal_from_mapping(raw.get("prevDailyBar"), "c")
            if close is not None:
                await self._emit(QuoteEvent(con_id, "close", close, observed_at))
            trend = _record_trend(price, observed_at, self._trends.get(con_id, ()))
            self._trends[con_id] = trend
            await self._emit(QuoteTrendEvent(con_id, trend))
            updated = True
        return updated

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


def _trend_points(
    bars: Any,
    *,
    start: datetime,
    end: datetime,
) -> tuple[QuoteTrendPoint, ...]:
    if not isinstance(bars, list):
        return ()
    points: list[QuoteTrendPoint] = []
    for bar in bars:
        if not isinstance(bar, Mapping):
            continue
        price = _decimal(bar.get("c"))
        sampled_at = _parse_time(bar.get("t"), end)
        if price is None or sampled_at < start or sampled_at > end:
            continue
        point = QuoteTrendPoint(sampled_at=sampled_at, price=price)
        if points and points[-1].sampled_at == point.sampled_at:
            points[-1] = point
        elif not points or points[-1].price != point.price:
            points.append(point)
    return tuple(points[-1440:])


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
