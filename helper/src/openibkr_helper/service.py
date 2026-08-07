"""Application service coordinating adapter, SQLite and latest-state fan-out."""

from __future__ import annotations

import asyncio
import logging
import time

from .adapters.base import ContractResolutionError, ReadOnlyDataAdapter
from .config import HelperSettings
from .database import Database
from .events import AdapterEvent, ConnectionEvent
from .models import AppSnapshot, ContractQuery, Instrument
from .state import SnapshotStore
from .subscriptions import SubscriptionManager

logger = logging.getLogger("openibkr.service")


class WatchlistFullError(RuntimeError):
    pass


class HelperService:
    def __init__(
        self,
        settings: HelperSettings,
        adapter: ReadOnlyDataAdapter,
        database: Database | None = None,
    ) -> None:
        self.settings = settings
        self.adapter = adapter
        self.database = database or Database(settings.database_path)
        self.store = SnapshotStore()
        self.subscriptions = SubscriptionManager(adapter, self.store)
        self.started_monotonic = time.monotonic()
        self._stale_task: asyncio.Task[None] | None = None
        self._persistence_task: asyncio.Task[None] | None = None
        self._started = False
        self._contract_candidates: dict[int, Instrument] = {}
        self._last_pnl_minute: str | None = None

    @property
    def uptime_seconds(self) -> int:
        return max(0, int(time.monotonic() - self.started_monotonic))

    async def start(self) -> None:
        if self._started:
            return
        self.database.open()
        logger.info(
            "service_start adapter=%s schema=%d",
            type(self.adapter).__name__,
            self.database.schema_version,
        )
        restored = self.database.load_public_snapshot()
        if restored is not None:
            await self.store.restore(restored)
        await self.adapter.start(self.handle_adapter_event)
        await self.subscriptions.restore(self.database.list_watchlist())
        self._stale_task = asyncio.create_task(self._staleness_loop(), name="openibkr-staleness")
        self._persistence_task = asyncio.create_task(
            self._persistence_loop(), name="openibkr-persistence"
        )
        self._started = True

    async def stop(self) -> None:
        if not self._started:
            self.database.close()
            return
        if self._stale_task is not None:
            self._stale_task.cancel()
            await asyncio.gather(self._stale_task, return_exceptions=True)
            self._stale_task = None
        if self._persistence_task is not None:
            self._persistence_task.cancel()
            await asyncio.gather(self._persistence_task, return_exceptions=True)
            self._persistence_task = None
        await self.subscriptions.stop()
        await self.adapter.stop()
        self.database.save_public_snapshot(await self.store.snapshot())
        self.database.close()
        self._started = False
        logger.info("service_stop")

    async def handle_adapter_event(self, event: AdapterEvent) -> None:
        if isinstance(event, ConnectionEvent):
            logger.info(
                "gateway_state state=%s error_code=%s",
                getattr(event, "state", "unknown"),
                getattr(event, "error_code", None),
            )
        await self.store.apply(event)

    async def snapshot(self) -> AppSnapshot:
        return await self.store.snapshot()

    async def list_watchlist(self) -> list[Instrument]:
        return self.database.list_watchlist()

    async def add_watchlist(self, query: ContractQuery) -> Instrument:
        instrument = await self.adapter.resolve_contract(query)
        return await self.add_watchlist_instrument(instrument, require_search=False)

    async def search_contracts(self, query: ContractQuery) -> tuple[Instrument, ...]:
        candidates = await self.adapter.search_contracts(query)
        self._contract_candidates = {item.con_id: item for item in candidates[:100]}
        return candidates

    async def add_watchlist_instrument(
        self, instrument: Instrument, *, require_search: bool = True
    ) -> Instrument:
        if require_search and self._contract_candidates.get(instrument.con_id) != instrument:
            raise ContractResolutionError("instrument is not from the latest contract search")
        existing = {item.con_id for item in self.database.list_watchlist()}
        if instrument.con_id not in existing and len(existing) >= self.settings.max_watchlist:
            raise WatchlistFullError(f"watchlist limit of {self.settings.max_watchlist} reached")
        self.database.add_to_watchlist(instrument)
        await self.subscriptions.subscribe(instrument)
        logger.info("watchlist_add con_id=%d", instrument.con_id)
        return instrument

    async def remove_watchlist(self, con_id: int) -> bool:
        removed = self.database.remove_from_watchlist(con_id)
        await self.subscriptions.unsubscribe(con_id)
        logger.info("watchlist_remove con_id=%d removed=%s", con_id, removed)
        return removed

    async def _staleness_loop(self) -> None:
        while True:
            await asyncio.sleep(1.0)
            await self.store.refresh_staleness(
                pnl_seconds=self.settings.pnl_stale_seconds,
                quote_seconds=self.settings.quote_stale_seconds,
            )

    async def _persistence_loop(self) -> None:
        while True:
            await asyncio.sleep(1.0)
            snapshot = await self.store.snapshot()
            self.database.save_public_snapshot(snapshot)
            if snapshot.pnl.received_at is None:
                continue
            minute = snapshot.pnl.received_at.replace(second=0, microsecond=0).isoformat()
            if minute != self._last_pnl_minute and self.database.save_pnl_minute(snapshot):
                self._last_pnl_minute = minute
