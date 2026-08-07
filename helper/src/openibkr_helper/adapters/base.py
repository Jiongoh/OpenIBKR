"""Capability-minimal adapter protocol.  There are deliberately no orders."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Protocol

from ..events import AdapterEvent
from ..models import ContractQuery, Instrument

EventSink = Callable[[AdapterEvent], Awaitable[None]]


class AdapterUnavailableError(RuntimeError):
    pass


class ContractResolutionError(RuntimeError):
    pass


class ReadOnlyDataAdapter(Protocol):
    async def start(self, sink: EventSink) -> None: ...

    async def stop(self) -> None: ...

    async def resolve_contract(self, query: ContractQuery) -> Instrument: ...

    async def search_contracts(self, query: ContractQuery) -> tuple[Instrument, ...]: ...

    async def subscribe_quote(self, instrument: Instrument) -> None: ...

    async def unsubscribe_quote(self, con_id: int) -> None: ...
