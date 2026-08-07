"""Versioned public protocol models shared by the Helper and macOS app."""

from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from enum import StrEnum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import PROTOCOL_VERSION


def utc_now() -> datetime:
    return datetime.now(UTC)


class ProtocolModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class GatewayState(StrEnum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    RECOVERING = "recovering"
    STOPPED = "stopped"


class MarketDataKind(StrEnum):
    REAL_TIME = "real_time"
    FROZEN = "frozen"
    DELAYED = "delayed"
    DELAYED_FROZEN = "delayed_frozen"
    UNKNOWN = "unknown"

    @classmethod
    def from_ibkr(cls, value: int | None) -> MarketDataKind:
        return {
            1: cls.REAL_TIME,
            2: cls.FROZEN,
            3: cls.DELAYED,
            4: cls.DELAYED_FROZEN,
        }.get(value, cls.UNKNOWN)


class ConnectionStatus(ProtocolModel):
    state: GatewayState = GatewayState.DISCONNECTED
    changed_at: datetime = Field(default_factory=utc_now)
    last_error_code: int | None = None


class AccountSnapshot(ProtocolModel):
    account_masked: str | None = None
    currency: str | None = None
    net_liquidation: Decimal | None = None
    received_at: datetime | None = None
    stale: bool = True


class PnLSnapshot(ProtocolModel):
    daily: Decimal | None = None
    unrealized: Decimal | None = None
    realized: Decimal | None = None
    received_at: datetime | None = None
    stale: bool = True


class Instrument(ProtocolModel):
    con_id: int = Field(gt=0)
    symbol: str = Field(min_length=1, max_length=32)
    sec_type: str = Field(min_length=1, max_length=16)
    exchange: str = Field(min_length=1, max_length=32)
    currency: str = Field(min_length=3, max_length=3)
    primary_exchange: str | None = Field(default=None, max_length=32)
    local_symbol: str | None = Field(default=None, max_length=64)

    @field_validator("symbol", "sec_type", "exchange", "currency")
    @classmethod
    def uppercase_identifiers(cls, value: str) -> str:
        return value.strip().upper()


class ContractQuery(ProtocolModel):
    symbol: str = Field(min_length=1, max_length=12, pattern=r"^[A-Za-z0-9.\-]+$")
    sec_type: Literal["STK"] = "STK"
    exchange: str = Field(default="SMART", min_length=1, max_length=32)
    currency: str = Field(default="USD", min_length=3, max_length=3)

    @field_validator("symbol", "exchange", "currency")
    @classmethod
    def normalize_query(cls, value: str) -> str:
        return value.strip().upper()


class QuoteSnapshot(ProtocolModel):
    instrument: Instrument
    bid: Decimal | None = None
    ask: Decimal | None = None
    last: Decimal | None = None
    close: Decimal | None = None
    market_data_kind: MarketDataKind = MarketDataKind.UNKNOWN
    received_at: datetime | None = None
    stale: bool = True


class AppSnapshot(ProtocolModel):
    protocol_version: Literal[1] = PROTOCOL_VERSION
    sequence: int = Field(default=0, ge=0)
    generated_at: datetime = Field(default_factory=utc_now)
    connection: ConnectionStatus = Field(default_factory=ConnectionStatus)
    account: AccountSnapshot = Field(default_factory=AccountSnapshot)
    pnl: PnLSnapshot = Field(default_factory=PnLSnapshot)
    quotes: tuple[QuoteSnapshot, ...] = ()


class StreamEnvelope(ProtocolModel):
    type: Literal["snapshot", "update"]
    protocol_version: Literal[1] = PROTOCOL_VERSION
    sequence: int = Field(ge=0)
    sent_at: datetime = Field(default_factory=utc_now)
    payload: dict[str, Any]


class HealthResponse(ProtocolModel):
    status: Literal["ok"] = "ok"
    helper_version: str
    protocol_version: Literal[1] = PROTOCOL_VERSION
    gateway_state: GatewayState
    database_schema_version: int
    uptime_seconds: int = Field(ge=0)
