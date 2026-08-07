"""Runtime configuration with loopback-only and ephemeral-token invariants."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class HelperSettings(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    adapter: Literal["fake", "ibkr"] = "fake"
    bind_host: Literal["127.0.0.1"] = "127.0.0.1"
    bind_port: int = Field(default=0, ge=0, le=65535)
    gateway_host: Literal["127.0.0.1"] = "127.0.0.1"
    gateway_port: int = Field(default=4003, ge=1, le=65535)
    gateway_client_id: int = Field(default=72, ge=1, le=2_147_483_647)
    session_token: str = Field(min_length=32, max_length=512, repr=False)
    database_path: Path
    pnl_stale_seconds: float = Field(default=10.0, gt=0, le=3600)
    quote_stale_seconds: float = Field(default=30.0, gt=0, le=86400)
    max_watchlist: int = Field(default=30, ge=1, le=100)

    @field_validator("session_token")
    @classmethod
    def reject_whitespace_token(cls, value: str) -> str:
        if value.strip() != value or any(char.isspace() for char in value):
            raise ValueError("session token must not contain whitespace")
        return value

    @classmethod
    def from_environment(cls) -> HelperSettings:
        token = os.environ.get("OPENIBKR_SESSION_TOKEN")
        if token is None:
            raise RuntimeError("OPENIBKR_SESSION_TOKEN is required and is never generated on disk")
        default_db = (
            Path.home() / "Library" / "Application Support" / "OpenIBKR" / "openibkr.sqlite3"
        )
        return cls(
            adapter=os.environ.get("OPENIBKR_ADAPTER", "fake"),
            bind_port=int(os.environ.get("OPENIBKR_BIND_PORT", "0")),
            gateway_port=int(os.environ.get("OPENIBKR_GATEWAY_PORT", "4003")),
            gateway_client_id=int(os.environ.get("OPENIBKR_GATEWAY_CLIENT_ID", "72")),
            session_token=token,
            database_path=Path(os.environ.get("OPENIBKR_DATABASE_PATH", str(default_db))),
        )
