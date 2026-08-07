"""Idempotent dynamic quote subscription management."""

from __future__ import annotations

from .adapters.base import ReadOnlyDataAdapter
from .models import Instrument
from .state import SnapshotStore


class SubscriptionManager:
    def __init__(self, adapter: ReadOnlyDataAdapter, store: SnapshotStore) -> None:
        self._adapter = adapter
        self._store = store
        self._active: set[int] = set()

    @property
    def active(self) -> frozenset[int]:
        return frozenset(self._active)

    async def subscribe(self, instrument: Instrument) -> bool:
        await self._store.ensure_instrument(instrument)
        if instrument.con_id in self._active:
            return False
        await self._adapter.subscribe_quote(instrument)
        self._active.add(instrument.con_id)
        return True

    async def unsubscribe(self, con_id: int) -> bool:
        if con_id not in self._active:
            await self._store.remove_instrument(con_id)
            return False
        await self._adapter.unsubscribe_quote(con_id)
        self._active.remove(con_id)
        await self._store.remove_instrument(con_id)
        return True

    async def restore(self, instruments: list[Instrument]) -> None:
        for instrument in instruments:
            await self.subscribe(instrument)

    async def stop(self) -> None:
        for con_id in tuple(self._active):
            await self._adapter.unsubscribe_quote(con_id)
        self._active.clear()
