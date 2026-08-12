"""In-memory latest-state store and bounded WebSocket fan-out."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import Any

from .events import (
    AccountEvent,
    AdapterEvent,
    ConnectionEvent,
    InstrumentResolvedEvent,
    MarketDataTypeEvent,
    PnLEvent,
    QuoteEvent,
    QuoteResetEvent,
)
from .models import (
    AccountSnapshot,
    AppSnapshot,
    ConnectionStatus,
    GatewayState,
    Instrument,
    PnLSnapshot,
    QuoteSnapshot,
    StreamEnvelope,
    utc_now,
)


class SnapshotStore:
    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._sequence = 0
        self._connection = ConnectionStatus()
        self._account = AccountSnapshot()
        self._pnl = PnLSnapshot()
        self._quotes: dict[int, QuoteSnapshot] = {}
        self._subscribers: set[asyncio.Queue[StreamEnvelope]] = set()

    async def snapshot(self) -> AppSnapshot:
        async with self._lock:
            return self._snapshot_unlocked()

    async def restore(self, snapshot: AppSnapshot) -> None:
        """Restore only the public snapshot, always marked stale/disconnected."""

        async with self._lock:
            self._sequence = snapshot.sequence
            self._connection = ConnectionStatus(state=GatewayState.DISCONNECTED)
            self._account = snapshot.account.model_copy(update={"stale": True})
            self._pnl = snapshot.pnl.model_copy(update={"stale": True})
            self._quotes = {
                quote.instrument.con_id: quote.model_copy(update={"stale": True})
                for quote in snapshot.quotes
            }

    async def ensure_instrument(self, instrument: Instrument) -> None:
        async with self._lock:
            if instrument.con_id in self._quotes:
                return
            self._quotes[instrument.con_id] = QuoteSnapshot(instrument=instrument)
            await self._publish_unlocked("watchlist_added", self._quotes[instrument.con_id])

    async def remove_instrument(self, con_id: int) -> None:
        async with self._lock:
            quote = self._quotes.pop(con_id, None)
            if quote is not None:
                await self._publish_unlocked("watchlist_removed", {"con_id": con_id})

    async def apply(self, event: AdapterEvent) -> None:
        async with self._lock:
            now = utc_now()
            kind: str
            data: Any
            if isinstance(event, ConnectionEvent):
                self._connection = ConnectionStatus(
                    state=event.state,
                    changed_at=now,
                    last_error_code=event.error_code,
                )
                if event.state != GatewayState.CONNECTED:
                    self._account = self._account.model_copy(update={"stale": True})
                    self._pnl = self._pnl.model_copy(update={"stale": True})
                    self._quotes = {
                        con_id: quote.model_copy(update={"stale": True})
                        for con_id, quote in self._quotes.items()
                    }
                kind, data = "connection", self._connection
            elif isinstance(event, AccountEvent):
                self._account = AccountSnapshot(
                    account_masked=event.account_masked,
                    currency=event.currency,
                    net_liquidation=event.net_liquidation,
                    received_at=now,
                    stale=False,
                )
                kind, data = "account", self._account
            elif isinstance(event, PnLEvent):
                self._pnl = PnLSnapshot(
                    daily=event.daily,
                    unrealized=event.unrealized,
                    realized=event.realized,
                    received_at=now,
                    stale=False,
                )
                kind, data = "pnl", self._pnl
            elif isinstance(event, InstrumentResolvedEvent):
                if event.instrument.con_id not in self._quotes:
                    self._quotes[event.instrument.con_id] = QuoteSnapshot(
                        instrument=event.instrument
                    )
                kind, data = "instrument", event.instrument
            elif isinstance(event, MarketDataTypeEvent):
                quote = self._quotes.get(event.con_id)
                if quote is None:
                    return
                quote = quote.model_copy(update={"market_data_kind": event.kind})
                self._quotes[event.con_id] = quote
                kind, data = "market_data_type", quote
            elif isinstance(event, QuoteEvent):
                quote = self._quotes.get(event.con_id)
                if quote is None or event.value <= 0:
                    return
                quote = quote.model_copy(
                    update={event.field: event.value, "received_at": now, "stale": False}
                )
                self._quotes[event.con_id] = quote
                kind, data = "quote", quote
            elif isinstance(event, QuoteResetEvent):
                quote = self._quotes.get(event.con_id)
                if quote is None:
                    return
                quote = quote.model_copy(
                    update={
                        "bid": None,
                        "ask": None,
                        "last": None,
                        "close": None,
                        "received_at": None,
                        "stale": True,
                    }
                )
                self._quotes[event.con_id] = quote
                kind, data = "quote_reset", quote
            else:
                raise TypeError(f"Unsupported adapter event: {type(event)!r}")
            await self._publish_unlocked(kind, data)

    async def refresh_staleness(
        self, *, pnl_seconds: float, quote_seconds: float, now: datetime | None = None
    ) -> bool:
        current = now or datetime.now(UTC)
        async with self._lock:
            changed = False
            if self._pnl.received_at is not None:
                should_stale = (current - self._pnl.received_at).total_seconds() > pnl_seconds
                if should_stale != self._pnl.stale:
                    self._pnl = self._pnl.model_copy(update={"stale": should_stale})
                    changed = True
            for con_id, quote in list(self._quotes.items()):
                if quote.received_at is None:
                    continue
                should_stale = (current - quote.received_at).total_seconds() > quote_seconds
                if should_stale != quote.stale:
                    self._quotes[con_id] = quote.model_copy(update={"stale": should_stale})
                    changed = True
            if changed:
                await self._publish_unlocked("staleness", self._snapshot_unlocked())
            return changed

    async def register(self) -> asyncio.Queue[StreamEnvelope]:
        queue: asyncio.Queue[StreamEnvelope] = asyncio.Queue(maxsize=64)
        async with self._lock:
            self._subscribers.add(queue)
        return queue

    async def unregister(self, queue: asyncio.Queue[StreamEnvelope]) -> None:
        async with self._lock:
            self._subscribers.discard(queue)

    async def initial_envelope(self) -> StreamEnvelope:
        snapshot = await self.snapshot()
        return StreamEnvelope(
            type="snapshot",
            sequence=snapshot.sequence,
            payload={"snapshot": snapshot.model_dump(mode="json")},
        )

    def _snapshot_unlocked(self) -> AppSnapshot:
        return AppSnapshot(
            sequence=self._sequence,
            connection=self._connection,
            account=self._account,
            pnl=self._pnl,
            quotes=tuple(self._quotes[key] for key in sorted(self._quotes)),
        )

    async def _publish_unlocked(self, kind: str, data: Any) -> None:
        self._sequence += 1
        if hasattr(data, "model_dump"):
            serialized = data.model_dump(mode="json")
        else:
            serialized = data
        envelope = StreamEnvelope(
            type="update",
            sequence=self._sequence,
            payload={"kind": kind, "data": serialized},
        )
        for queue in tuple(self._subscribers):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(envelope)
