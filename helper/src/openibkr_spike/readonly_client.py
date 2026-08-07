"""A deliberately tiny, fail-closed IBKR client for feasibility checks.

This module is not a trading client.  It permits only the outgoing TWS message
types needed to read account/P&L/position and top-of-book market data.  Every
other outgoing message ID is rejected before it reaches the socket.
"""

from __future__ import annotations

import math
import statistics
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Final, NoReturn

from ibapi.client import EClient
from ibapi.common import PROTOBUF_MSG_ID
from ibapi.contract import Contract, ContractDetails
from ibapi.message import OUT
from ibapi.ticktype import TickTypeEnum
from ibapi.wrapper import EWrapper


class TradingDisabledError(RuntimeError):
    """Raised whenever code attempts an order-related or unapproved request."""


# This is the complete wire-level capability set of this spike.  New SDK
# messages remain blocked until a human explicitly adds one here and tests it.
ALLOWED_OUTGOING: Final[frozenset[OUT]] = frozenset(
    {
        OUT.START_API,
        OUT.REQ_MANAGED_ACCTS,
        OUT.REQ_ACCOUNT_SUMMARY,
        OUT.CANCEL_ACCOUNT_SUMMARY,
        OUT.REQ_POSITIONS,
        OUT.CANCEL_POSITIONS,
        OUT.REQ_PNL,
        OUT.CANCEL_PNL,
        OUT.REQ_CONTRACT_DATA,
        OUT.CANCEL_CONTRACT_DATA,
        OUT.REQ_MARKET_DATA_TYPE,
        OUT.REQ_MKT_DATA,
        OUT.CANCEL_MKT_DATA,
    }
)


# Explicitly documented forbidden capabilities.  The wire allowlist above is
# authoritative and also blocks every unknown/future outgoing message.
FORBIDDEN_TRADING_OUTGOING: Final[frozenset[OUT]] = frozenset(
    {
        OUT.PLACE_ORDER,
        OUT.CANCEL_ORDER,
        OUT.REQ_GLOBAL_CANCEL,
        OUT.EXERCISE_OPTIONS,
        OUT.REQ_IDS,
        OUT.REQ_OPEN_ORDERS,
        OUT.REQ_ALL_OPEN_ORDERS,
        OUT.REQ_AUTO_OPEN_ORDERS,
        OUT.REQ_COMPLETED_ORDERS,
        OUT.REQ_EXECUTIONS,
    }
)


def mask_identifier(value: str) -> str:
    """Mask an account-like identifier while retaining a useful suffix."""

    clean = value.strip()
    if not clean:
        return ""
    if len(clean) <= 4:
        return "*" * len(clean)
    return "*" * (len(clean) - 4) + clean[-4:]


@dataclass
class ReadOnlySnapshot:
    """Only non-financial validation metadata; no balances or P&L amounts."""

    connected: bool = False
    connection_closed: bool = False
    server_version: int | None = None
    accounts: list[str] = field(default_factory=list, repr=False)
    summary_tags: set[str] = field(default_factory=set)
    summary_complete: bool = False
    positions_seen: int = 0
    positions_complete: bool = False
    pnl_callback_received: bool = False
    pnl_fields_finite: dict[str, bool] = field(default_factory=dict)
    pnl_callback_times: list[float] = field(default_factory=list, repr=False)
    contract_resolved: bool = False
    resolved_contract: Contract | None = field(default=None, repr=False)
    market_data_type: int | None = None
    tick_types_seen: set[int] = field(default_factory=set)
    market_request_error_received: bool = False
    errors: list[dict[str, int | str]] = field(default_factory=list)

    def public_dict(self) -> dict[str, Any]:
        pnl_intervals = [
            later - earlier
            for earlier, later in zip(
                self.pnl_callback_times, self.pnl_callback_times[1:], strict=False
            )
        ]
        pnl_cadence = (
            {
                "samples": len(pnl_intervals),
                "min_seconds": round(min(pnl_intervals), 3),
                "median_seconds": round(statistics.median(pnl_intervals), 3),
                "max_seconds": round(max(pnl_intervals), 3),
            }
            if pnl_intervals
            else {"samples": 0}
        )
        return {
            "connected": self.connected,
            "connection_closed": self.connection_closed,
            "server_version": self.server_version,
            "account_count": len(self.accounts),
            "accounts_masked": [mask_identifier(item) for item in self.accounts],
            "summary_tags_received": sorted(self.summary_tags),
            "summary_complete": self.summary_complete,
            "positions_callback_count": self.positions_seen,
            "positions_complete": self.positions_complete,
            "pnl_callback_received": self.pnl_callback_received,
            "pnl_callback_count": len(self.pnl_callback_times),
            "pnl_cadence": pnl_cadence,
            "pnl_fields_finite": dict(sorted(self.pnl_fields_finite.items())),
            "contract_resolved": self.contract_resolved,
            "market_data_type": self.market_data_type,
            "tick_types_seen": sorted(self.tick_types_seen),
            "tick_type_names_seen": [
                TickTypeEnum.toStr(item) for item in sorted(self.tick_types_seen)
            ],
            "market_request_error_received": self.market_request_error_received,
            "errors": list(self.errors),
        }


class ReadOnlyIBKRClient(EWrapper, EClient):
    """IBKR API client whose socket writes are restricted by message ID."""

    def __init__(self) -> None:
        EWrapper.__init__(self)
        EClient.__init__(self, wrapper=self)
        self.snapshot = ReadOnlySnapshot()
        self.ready_event = threading.Event()
        self.accounts_event = threading.Event()
        self.summary_event = threading.Event()
        self.positions_event = threading.Event()
        self.pnl_event = threading.Event()
        self.contract_event = threading.Event()
        self.market_type_event = threading.Event()
        self.market_tick_event = threading.Event()
        self.market_error_event = threading.Event()
        self.guard_violation_event = threading.Event()
        self.guard_violation: str | None = None

    @staticmethod
    def validate_endpoint(host: str, port: int, client_id: int) -> None:
        if host != "127.0.0.1":
            raise ValueError("Only the literal loopback address 127.0.0.1 is allowed")
        if not 1 <= port <= 65535:
            raise ValueError("Port must be between 1 and 65535")
        if not 1 <= client_id <= 2_147_483_647:
            raise ValueError("clientId 0 is forbidden; use a dedicated positive clientId")

    def connect_read_only(self, host: str, port: int, client_id: int) -> None:
        self.validate_endpoint(host, port, client_id)
        self.connect(host, port, client_id)

    def _trip_guard(self, message_id: int, reason: str) -> NoReturn:
        self.guard_violation = f"outgoing message {message_id} blocked: {reason}"
        self.guard_violation_event.set()
        if self.isConnected():
            self.disconnect()
        raise TradingDisabledError(self.guard_violation)

    def _assert_allowed(self, message_id: int, *, protobuf: bool) -> OUT:
        raw_id = int(message_id)
        if protobuf:
            if raw_id <= PROTOBUF_MSG_ID:
                self._trip_guard(raw_id, "invalid protobuf message ID")
            base_id = raw_id - PROTOBUF_MSG_ID
        else:
            if raw_id > PROTOBUF_MSG_ID:
                self._trip_guard(raw_id, "protobuf ID sent through legacy path")
            base_id = raw_id

        try:
            outgoing = OUT(base_id)
        except ValueError:
            self._trip_guard(raw_id, "unknown message ID")

        if outgoing not in ALLOWED_OUTGOING:
            self._trip_guard(raw_id, outgoing.name)
        return outgoing

    def sendMsg(self, msgId: int, msg: str) -> None:  # noqa: N802 - IB API name
        self._assert_allowed(msgId, protobuf=False)
        super().sendMsg(msgId, msg)

    def sendMsgProtoBuf(self, msgId: int, msg: bytes) -> None:  # noqa: N802
        self._assert_allowed(msgId, protobuf=True)
        super().sendMsgProtoBuf(msgId, msg)

    @staticmethod
    def _deny(operation: str) -> None:
        raise TradingDisabledError(f"{operation} is permanently disabled")

    # Entry-point guards provide an immediate, readable failure.  The wire
    # allowlist remains the final barrier even if another EClient method is used.
    def placeOrder(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("placeOrder")

    def cancelOrder(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("cancelOrder")

    def reqGlobalCancel(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqGlobalCancel")

    def exerciseOptions(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("exerciseOptions")

    def reqIds(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqIds")

    def reqOpenOrders(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqOpenOrders")

    def reqAllOpenOrders(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqAllOpenOrders")

    def reqAutoOpenOrders(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqAutoOpenOrders")

    def reqCompletedOrders(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqCompletedOrders")

    def reqExecutions(self, *_args: Any, **_kwargs: Any) -> None:  # noqa: N802
        self._deny("reqExecutions")

    # IB callbacks below collect validation metadata only.  Financial values,
    # account IDs, symbols and raw error messages are never emitted or persisted.
    def connectAck(self) -> None:  # noqa: N802
        self.snapshot.connected = True
        self.snapshot.server_version = self.serverVersion()

    def nextValidId(self, _orderId: int) -> None:  # noqa: N802
        # This callback is part of API startup; the order ID is intentionally
        # ignored and no order-related request is made.
        self.snapshot.connected = True
        self.snapshot.server_version = self.serverVersion()
        self.ready_event.set()

    def managedAccounts(self, accountsList: str) -> None:  # noqa: N802
        self.snapshot.accounts = [item.strip() for item in accountsList.split(",") if item.strip()]
        self.accounts_event.set()

    def accountSummary(
        self, _reqId: int, _account: str, tag: str, _value: str, _currency: str
    ) -> None:  # noqa: N802
        self.snapshot.summary_tags.add(tag)

    def accountSummaryEnd(self, _reqId: int) -> None:  # noqa: N802
        self.snapshot.summary_complete = True
        self.summary_event.set()

    def position(self, _account: str, _contract: Contract, _position: Any, _avgCost: float) -> None:
        self.snapshot.positions_seen += 1

    def positionEnd(self) -> None:  # noqa: N802
        self.snapshot.positions_complete = True
        self.positions_event.set()

    def pnl(
        self,
        _reqId: int,
        dailyPnL: float,
        unrealizedPnL: float,
        realizedPnL: float,
    ) -> None:
        self.snapshot.pnl_callback_received = True
        self.snapshot.pnl_callback_times.append(time.monotonic())
        self.snapshot.pnl_fields_finite = {
            "daily": math.isfinite(dailyPnL),
            "unrealized": math.isfinite(unrealizedPnL),
            "realized": math.isfinite(realizedPnL),
        }
        self.pnl_event.set()

    def contractDetails(self, _reqId: int, contractDetails: ContractDetails) -> None:  # noqa: N802
        if self.snapshot.resolved_contract is None:
            self.snapshot.resolved_contract = contractDetails.contract
            self.snapshot.contract_resolved = True

    def contractDetailsEnd(self, _reqId: int) -> None:  # noqa: N802
        self.contract_event.set()

    def marketDataType(self, _reqId: int, marketDataType: int) -> None:  # noqa: N802
        self.snapshot.market_data_type = marketDataType
        self.market_type_event.set()

    def tickPrice(self, _reqId: int, tickType: int, _price: float, _attrib: Any) -> None:  # noqa: N802
        self.snapshot.tick_types_seen.add(int(tickType))
        self.market_tick_event.set()

    def tickSize(self, _reqId: int, tickType: int, _size: Any) -> None:  # noqa: N802
        self.snapshot.tick_types_seen.add(int(tickType))
        self.market_tick_event.set()

    def error(
        self,
        reqId: int,
        _errorTime: int,
        errorCode: int,
        _errorString: str,
        _advancedOrderRejectJson: str = "",
    ) -> None:
        categories = {
            1100: "connectivity_lost",
            1101: "connectivity_restored_data_lost",
            1102: "connectivity_restored_data_maintained",
            2104: "market_data_farm_ok",
            2106: "historical_data_farm_ok",
            2158: "security_definition_farm_ok",
            326: "client_id_in_use",
            300: "request_not_found_during_cleanup",
            502: "connection_failed",
            504: "not_connected",
            10089: "market_data_subscription_required",
            10167: "delayed_market_data_available",
        }
        self.snapshot.errors.append(
            {
                "req_id": int(reqId),
                "code": int(errorCode),
                "category": categories.get(errorCode, "ibkr_notice_or_error"),
            }
        )
        # Positive request IDs are used only for contract/account/market reads
        # in this spike.  A request-scoped error after market subscription is a
        # valid entitlement result and must not be confused with a tick.
        if reqId >= 0:
            self.snapshot.market_request_error_received = True
            self.market_error_event.set()

    def connectionClosed(self) -> None:  # noqa: N802
        self.snapshot.connection_closed = True
