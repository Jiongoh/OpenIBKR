"""Deterministic Fake adapter used for all regular development and CI tests."""

from __future__ import annotations

import asyncio
import hashlib
from decimal import Decimal

from ..events import (
    AccountEvent,
    ConnectionEvent,
    MarketDataTypeEvent,
    PnLEvent,
    QuoteEvent,
)
from ..models import ContractQuery, GatewayState, Instrument, MarketDataKind
from .base import ContractResolutionError, EventSink


class FakeIBKRAdapter:
    def __init__(self, *, tick_interval: float = 1.0) -> None:
        self._tick_interval = tick_interval
        self._sink: EventSink | None = None
        self._tasks: dict[int, asyncio.Task[None]] = {}
        self._started = False
        self.subscribe_calls: list[int] = []
        self.unsubscribe_calls: list[int] = []

    async def start(self, sink: EventSink) -> None:
        if self._started:
            return
        self._sink = sink
        self._started = True
        await sink(ConnectionEvent(GatewayState.CONNECTED))
        await sink(AccountEvent("*****FAKE", "USD", Decimal("100000.00")))
        await sink(PnLEvent(Decimal("125.50"), Decimal("100.25"), Decimal("25.25")))

    async def stop(self) -> None:
        tasks = list(self._tasks.values())
        self._tasks.clear()
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if self._started and self._sink is not None:
            await self._sink(ConnectionEvent(GatewayState.STOPPED))
        self._started = False
        self._sink = None

    async def resolve_contract(self, query: ContractQuery) -> Instrument:
        candidates = await self.search_contracts(query)
        if len(candidates) != 1:
            raise ContractResolutionError(
                f"contract query resolved to {len(candidates)} candidates; refusing ambiguity"
            )
        return candidates[0]

    async def search_contracts(self, query: ContractQuery) -> tuple[Instrument, ...]:
        if query.symbol == "MISSING":
            return ()
        digest = hashlib.sha256(
            f"{query.symbol}|{query.sec_type}|{query.exchange}|{query.currency}".encode()
        ).digest()
        con_id = int.from_bytes(digest[:4], "big") % 2_000_000_000 + 1
        instrument = Instrument(
            con_id=con_id,
            symbol=query.symbol,
            sec_type=query.sec_type,
            exchange=query.exchange,
            currency=query.currency,
            primary_exchange="NASDAQ",
            local_symbol=query.symbol,
        )
        if query.symbol != "AMBIG":
            return (instrument,)
        alternate = instrument.model_copy(
            update={
                "con_id": instrument.con_id + 1,
                "primary_exchange": "NYSE",
                "local_symbol": f"{query.symbol}.A",
            }
        )
        return (instrument, alternate)

    async def subscribe_quote(self, instrument: Instrument) -> None:
        if not self._started or self._sink is None:
            raise RuntimeError("Fake adapter is not started")
        if instrument.con_id in self._tasks:
            return
        self.subscribe_calls.append(instrument.con_id)
        await self._sink(MarketDataTypeEvent(instrument.con_id, MarketDataKind.DELAYED))
        task = asyncio.create_task(
            self._quote_loop(instrument), name=f"fake-quote-{instrument.con_id}"
        )
        self._tasks[instrument.con_id] = task

    async def unsubscribe_quote(self, con_id: int) -> None:
        task = self._tasks.pop(con_id, None)
        if task is None:
            return
        self.unsubscribe_calls.append(con_id)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    async def _quote_loop(self, instrument: Instrument) -> None:
        assert self._sink is not None
        base = Decimal(instrument.con_id % 10000) / Decimal("100") + Decimal("10")
        counter = 0
        while True:
            offset = Decimal(counter % 10) / Decimal("100")
            last = base + offset
            await self._sink(QuoteEvent(instrument.con_id, "bid", last - Decimal("0.01")))
            await self._sink(QuoteEvent(instrument.con_id, "ask", last + Decimal("0.01")))
            await self._sink(QuoteEvent(instrument.con_id, "last", last))
            await self._sink(QuoteEvent(instrument.con_id, "close", base - Decimal("0.20")))
            counter += 1
            await asyncio.sleep(self._tick_interval)
