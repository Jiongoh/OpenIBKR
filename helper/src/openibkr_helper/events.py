"""Internal adapter events; these are never accepted from the local API."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

from .models import GatewayState, Instrument, MarketDataKind


@dataclass(frozen=True, slots=True)
class ConnectionEvent:
    state: GatewayState
    error_code: int | None = None


@dataclass(frozen=True, slots=True)
class AccountEvent:
    account_masked: str
    currency: str | None
    net_liquidation: Decimal | None


@dataclass(frozen=True, slots=True)
class PnLEvent:
    daily: Decimal
    unrealized: Decimal
    realized: Decimal


@dataclass(frozen=True, slots=True)
class QuoteEvent:
    con_id: int
    field: Literal["bid", "ask", "last", "close"]
    value: Decimal


@dataclass(frozen=True, slots=True)
class MarketDataTypeEvent:
    con_id: int
    kind: MarketDataKind


@dataclass(frozen=True, slots=True)
class InstrumentResolvedEvent:
    instrument: Instrument


AdapterEvent = (
    ConnectionEvent
    | AccountEvent
    | PnLEvent
    | QuoteEvent
    | MarketDataTypeEvent
    | InstrumentResolvedEvent
)
