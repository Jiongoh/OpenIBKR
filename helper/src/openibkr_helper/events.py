"""Internal adapter events; these are never accepted from the local API."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Literal

from .models import (
    GatewayState,
    Instrument,
    MarketDataKind,
    MarketDataStatus,
    QuoteTrendPoint,
)


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
    observed_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class QuoteTrendEvent:
    con_id: int
    points: tuple[QuoteTrendPoint, ...]


@dataclass(frozen=True, slots=True)
class QuoteResetEvent:
    """Clear cached prices immediately before starting a fresh subscription."""

    con_id: int


@dataclass(frozen=True, slots=True)
class MarketDataTypeEvent:
    con_id: int
    kind: MarketDataKind


@dataclass(frozen=True, slots=True)
class InstrumentResolvedEvent:
    instrument: Instrument


@dataclass(frozen=True, slots=True)
class MarketDataStatusEvent:
    status: MarketDataStatus


AdapterEvent = (
    ConnectionEvent
    | AccountEvent
    | PnLEvent
    | QuoteEvent
    | QuoteTrendEvent
    | QuoteResetEvent
    | MarketDataTypeEvent
    | InstrumentResolvedEvent
    | MarketDataStatusEvent
)
