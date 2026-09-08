"""Official TWS API adapter with fail-closed wire guard and reconnection."""

from __future__ import annotations

import asyncio
import logging
import threading
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any

from ibapi.contract import Contract, ContractDetails
from ibapi.execution import ExecutionFilter

from openibkr_helper.readonly_client import ReadOnlyIBKRClient, mask_identifier

from ..config import HelperSettings
from ..events import (
    AccountEvent,
    ConnectionEvent,
    PnLEvent,
    PositionCostSlotsEvent,
    PositionEvent,
    PositionPnLEvent,
    PositionRemovedEvent,
)
from ..models import (
    ContractQuery,
    GatewayState,
    Instrument,
    PositionCostSlot,
)
from .base import AdapterUnavailableError, ContractResolutionError, EventSink

logger = logging.getLogger("openibkr.ibkr")

ACCOUNT_SUMMARY_REQUEST_ID = 7201
PNL_REQUEST_ID = 7202
CONTRACT_REQUEST_ID_START = 8000
POSITION_PNL_REQUEST_ID_START = 20000
EXECUTION_REQUEST_ID = 7203


@dataclass(frozen=True, slots=True)
class _ExecutionFill:
    exec_id: str
    con_id: int
    side: str
    quantity: Decimal
    price: Decimal
    occurred_at: str
    group_id: str


@dataclass(slots=True)
class _WorkingLot:
    quantity: Decimal
    price: Decimal | None
    identifier: str
    source: str


def _rebuild_cost_slots(
    con_id: int,
    quantity: Decimal,
    average_cost: Decimal,
    fills: tuple[_ExecutionFill, ...],
) -> tuple[PositionCostSlot, ...]:
    """Rebuild today's surviving lots and one honest pre-today aggregate lot.

    IB Gateway exposes only today's executions.  The position that existed at
    midnight is therefore represented as one historical-base lot.  Executions
    are matched FIFO so reductions do not leave already-closed slots behind.
    """

    if quantity == 0:
        return ()
    relevant = sorted(
        (fill for fill in fills if fill.con_id == con_id),
        key=lambda fill: (fill.occurred_at, fill.exec_id),
    )
    signed_fills = [
        (
            fill.quantity if fill.side in {"BOT", "BUY"} else -fill.quantity,
            fill,
        )
        for fill in relevant
    ]
    initial_quantity = quantity - sum((amount for amount, _ in signed_fills), Decimal(0))
    lots: list[_WorkingLot] = []
    if initial_quantity != 0:
        lots.append(
            _WorkingLot(
                quantity=initial_quantity,
                price=None,
                identifier=f"{con_id}:base",
                source="historical_base",
            )
        )

    for signed_quantity, fill in signed_fills:
        remaining = signed_quantity
        while remaining != 0 and lots and (lots[0].quantity > 0) != (remaining > 0):
            oldest = lots[0]
            closed = min(abs(oldest.quantity), abs(remaining))
            oldest.quantity += closed if oldest.quantity < 0 else -closed
            remaining += closed if remaining < 0 else -closed
            if oldest.quantity == 0:
                lots.pop(0)
        if remaining != 0:
            lots.append(
                _WorkingLot(
                    quantity=remaining,
                    price=fill.price,
                    identifier=f"{con_id}:exec:{fill.group_id}",
                    source="execution",
                )
            )

    direction_is_long = quantity > 0
    lots = [lot for lot in lots if (lot.quantity > 0) == direction_is_long]
    grouped: list[_WorkingLot] = []
    for lot in lots:
        magnitude = abs(lot.quantity)
        if magnitude == 0:
            continue
        match = next((item for item in grouped if item.identifier == lot.identifier), None)
        if match is None:
            grouped.append(_WorkingLot(magnitude, lot.price, lot.identifier, lot.source))
        else:
            combined = match.quantity + magnitude
            if match.price is not None and lot.price is not None:
                match.price = (match.price * match.quantity + lot.price * magnitude) / combined
            match.quantity = combined

    known_cost = sum(
        (lot.quantity * lot.price for lot in grouped if lot.price is not None),
        Decimal(0),
    )
    base_quantity = sum((lot.quantity for lot in grouped if lot.price is None), Decimal(0))
    if base_quantity > 0:
        derived = (abs(quantity) * abs(average_cost) - known_cost) / base_quantity
        base_price = derived if derived > 0 else abs(average_cost)
        for lot in grouped:
            if lot.price is None:
                lot.price = base_price

    return tuple(
        PositionCostSlot(
            id=lot.identifier,
            quantity=lot.quantity,
            price=lot.price,
            source=lot.source,
        )
        for lot in grouped
        if lot.price is not None and lot.price > 0
    )


def _decimal(value: Any) -> Decimal | None:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    if not result.is_finite():
        return None
    if abs(result) > Decimal("1e100"):
        return None
    return result


def _instrument_from_contract(contract: Contract) -> Instrument:
    return Instrument(
        con_id=int(contract.conId),
        symbol=contract.symbol,
        sec_type=contract.secType,
        exchange=contract.exchange or "SMART",
        currency=contract.currency,
        primary_exchange=contract.primaryExchange or None,
        local_symbol=contract.localSymbol or None,
    )


class _HelperIBKRClient(ReadOnlyIBKRClient):
    def __init__(self, adapter: LiveIBKRAdapter) -> None:
        super().__init__()
        self._adapter = adapter
        self.selected_account: str | None = None
        self.contract_results: dict[int, list[Instrument]] = {}
        self.position_cache: dict[int, tuple[Decimal, Decimal]] = {}
        self.position_pnl_requests: dict[int, int] = {}
        self.execution_fills: dict[str, _ExecutionFill] = {}

    def _emit(self, event: Any) -> None:
        self._adapter.emit_from_thread(event)

    def nextValidId(self, orderId: int) -> None:  # noqa: N802
        super().nextValidId(orderId)
        self._emit(ConnectionEvent(GatewayState.CONNECTED))

    def accountSummary(self, reqId: int, account: str, tag: str, value: str, currency: str) -> None:  # noqa: N802
        super().accountSummary(reqId, account, tag, value, currency)
        if tag != "NetLiquidation":
            return
        amount = _decimal(value)
        if amount is None:
            return
        self._emit(AccountEvent(mask_identifier(account), currency or None, amount))

    def pnl(
        self,
        reqId: int,
        dailyPnL: float,
        unrealizedPnL: float,
        realizedPnL: float,
    ) -> None:
        super().pnl(reqId, dailyPnL, unrealizedPnL, realizedPnL)
        values = tuple(_decimal(item) for item in (dailyPnL, unrealizedPnL, realizedPnL))
        if any(item is None for item in values):
            return
        daily, unrealized, realized = values
        assert daily is not None and unrealized is not None and realized is not None
        self._emit(PnLEvent(daily, unrealized, realized))

    def position(self, account: str, contract: Contract, position: Any, avgCost: float) -> None:  # noqa: N802
        super().position(account, contract, position, avgCost)
        con_id = int(contract.conId)
        quantity = _decimal(position)
        average_cost = _decimal(avgCost)
        if con_id <= 0 or quantity is None or average_cost is None:
            return
        if quantity == 0:
            self.position_cache.pop(con_id, None)
        else:
            self.position_cache[con_id] = (quantity, average_cost)
        self._adapter.position_from_thread(con_id, quantity, average_cost)

    def pnlSingle(
        self,
        reqId: int,
        pos: Any,
        dailyPnL: float,
        unrealizedPnL: float,
        realizedPnL: float,
        value: float,
    ) -> None:  # noqa: N802
        con_id = self.position_pnl_requests.get(reqId)
        quantity = _decimal(pos)
        if con_id is None or quantity is None:
            return
        self._emit(
            PositionPnLEvent(
                con_id=con_id,
                quantity=quantity,
                daily_pnl=_decimal(dailyPnL),
                unrealized_pnl=_decimal(unrealizedPnL),
                realized_pnl=_decimal(realizedPnL),
                market_value=_decimal(value),
            )
        )

    def execDetails(self, reqId: int, contract: Contract, execution: Any) -> None:  # noqa: N802
        super().execDetails(reqId, contract, execution)
        if reqId != EXECUTION_REQUEST_ID:
            return
        con_id = int(contract.conId)
        quantity = _decimal(execution.shares)
        price = _decimal(execution.price)
        side = str(execution.side).upper()
        exec_id = str(execution.execId).strip()
        if (
            con_id <= 0
            or quantity is None
            or quantity <= 0
            or price is None
            or price <= 0
            or side not in {"BOT", "BUY", "SLD", "SELL"}
            or not exec_id
        ):
            return
        perm_id = int(getattr(execution, "permId", 0) or 0)
        order_id = int(getattr(execution, "orderId", 0) or 0)
        group_id = str(perm_id or order_id) if (perm_id or order_id) else exec_id
        self.execution_fills[exec_id] = _ExecutionFill(
            exec_id=exec_id,
            con_id=con_id,
            side=side,
            quantity=quantity,
            price=price,
            occurred_at=str(execution.time),
            group_id=group_id,
        )

    def execDetailsEnd(self, reqId: int) -> None:  # noqa: N802
        super().execDetailsEnd(reqId)
        if reqId == EXECUTION_REQUEST_ID:
            self._adapter._executions_complete_from_thread(tuple(self.execution_fills.values()))

    def contractDetails(self, reqId: int, contractDetails: ContractDetails) -> None:  # noqa: N802
        super().contractDetails(reqId, contractDetails)
        try:
            instrument = _instrument_from_contract(contractDetails.contract)
        except ValueError:
            return
        self.contract_results.setdefault(reqId, []).append(instrument)

    def contractDetailsEnd(self, reqId: int) -> None:  # noqa: N802
        super().contractDetailsEnd(reqId)
        self._adapter.complete_contract_from_thread(
            reqId, tuple(self.contract_results.pop(reqId, []))
        )

    def error(
        self,
        reqId: int,
        errorTime: int,
        errorCode: int,
        errorString: str,
        advancedOrderRejectJson: str = "",
    ) -> None:
        super().error(
            reqId,
            errorTime,
            errorCode,
            errorString,
            advancedOrderRejectJson,
        )
        if errorCode == 1100:
            self._emit(ConnectionEvent(GatewayState.DISCONNECTED, errorCode))
        elif errorCode == 1101:
            self._emit(ConnectionEvent(GatewayState.RECOVERING, errorCode))
            self._adapter.resubscribe_from_thread()
        elif errorCode == 1102:
            self._emit(ConnectionEvent(GatewayState.CONNECTED, errorCode))
        elif errorCode == 1300:
            self._emit(ConnectionEvent(GatewayState.DISCONNECTED, errorCode))
            self._adapter.disconnected_from_thread()
        elif errorCode == 200:
            # IBKR uses error 200 when no security definition matches a
            # contract query. Resolve the pending search immediately as an
            # empty result instead of leaving the UI waiting for its timeout.
            self._adapter.complete_contract_from_thread(reqId, ())
        elif errorCode in {320, 321, 322}:
            self._adapter.reject_contract_from_thread(reqId, errorCode)

    def connectionClosed(self) -> None:  # noqa: N802
        super().connectionClosed()
        self._emit(ConnectionEvent(GatewayState.DISCONNECTED))
        self._adapter.disconnected_from_thread()


class LiveIBKRAdapter:
    """Read-only data adapter.  Its underlying client rejects all order messages."""

    def __init__(self, settings: HelperSettings) -> None:
        self._settings = settings
        self._sink: EventSink | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._client: _HelperIBKRClient | None = None
        self._reader_thread: threading.Thread | None = None
        self._monitor_task: asyncio.Task[None] | None = None
        self._disconnected = asyncio.Event()
        self._stopping = False
        self._contract_futures: dict[int, asyncio.Future[tuple[Instrument, ...]]] = {}
        self._next_contract_request = CONTRACT_REQUEST_ID_START
        self._next_position_pnl_request = POSITION_PNL_REQUEST_ID_START
        self._instruments: dict[int, Instrument] = {}
        self._position_pnl_request_by_con_id: dict[int, int] = {}
        self._execution_fills: tuple[_ExecutionFill, ...] = ()
        self._execution_snapshot_complete = False

    async def start(self, sink: EventSink) -> None:
        if self._sink is not None:
            return
        self._sink = sink
        self._loop = asyncio.get_running_loop()
        self._stopping = False
        await sink(ConnectionEvent(GatewayState.CONNECTING))
        try:
            await self._connect_once()
        except (ConnectionError, RuntimeError, TimeoutError):
            await sink(ConnectionEvent(GatewayState.DISCONNECTED))
            self._disconnected.set()
        self._monitor_task = asyncio.create_task(
            self._monitor_reconnect(), name="ibkr-reconnect-monitor"
        )

    async def stop(self) -> None:
        self._stopping = True
        if self._monitor_task is not None:
            self._monitor_task.cancel()
            await asyncio.gather(self._monitor_task, return_exceptions=True)
            self._monitor_task = None
        await self._close_client()
        if self._sink is not None:
            await self._sink(ConnectionEvent(GatewayState.STOPPED))
        self._sink = None
        self._loop = None

    async def resolve_contract(self, query: ContractQuery) -> Instrument:
        candidates = await self.search_contracts(query)
        if len(candidates) != 1:
            raise ContractResolutionError(
                f"contract query resolved to {len(candidates)} candidates; refusing ambiguity"
            )
        return candidates[0]

    async def search_contracts(self, query: ContractQuery) -> tuple[Instrument, ...]:
        client = self._require_client()
        request_id = self._next_contract_request
        self._next_contract_request += 1
        assert self._loop is not None
        future: asyncio.Future[tuple[Instrument, ...]] = self._loop.create_future()
        self._contract_futures[request_id] = future
        contract = Contract()
        contract.symbol = query.symbol
        contract.secType = query.sec_type
        contract.exchange = query.exchange
        contract.currency = query.currency
        client.reqContractDetails(request_id, contract)
        try:
            candidates = await asyncio.wait_for(future, timeout=15.0)
        finally:
            self._contract_futures.pop(request_id, None)
        unique = {candidate.con_id: candidate for candidate in candidates}
        return tuple(unique[key] for key in sorted(unique))

    async def subscribe_watchlist(self, instrument: Instrument) -> None:
        """Track portfolio data for a symbol without requesting an IB quote."""
        self._instruments[instrument.con_id] = instrument
        await self._sync_position_subscription(instrument.con_id)

    async def unsubscribe_watchlist(self, con_id: int) -> None:
        self._instruments.pop(con_id, None)
        await self._cancel_position_subscription(con_id)

    def position_from_thread(self, con_id: int, quantity: Decimal, average_cost: Decimal) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return
        loop.call_soon_threadsafe(
            lambda: asyncio.create_task(
                self._handle_position_update(con_id, quantity, average_cost)
            )
        )

    async def _handle_position_update(
        self, con_id: int, quantity: Decimal, average_cost: Decimal
    ) -> None:
        if con_id not in self._instruments:
            return
        if quantity == 0:
            await self._cancel_position_subscription(con_id)
            if self._sink is not None:
                await self._sink(PositionRemovedEvent(con_id))
            return
        if self._sink is not None:
            await self._sink(PositionEvent(con_id, quantity, average_cost))
            if self._execution_snapshot_complete:
                await self._sink(
                    PositionCostSlotsEvent(
                        con_id,
                        _rebuild_cost_slots(con_id, quantity, average_cost, self._execution_fills),
                    )
                )
        await self._sync_position_subscription(con_id)

    async def _sync_position_subscription(self, con_id: int) -> None:
        client = self._client
        if client is None or not client.isConnected() or client.selected_account is None:
            return
        cached = client.position_cache.get(con_id)
        if cached is None:
            return
        quantity, average_cost = cached
        if self._sink is not None:
            await self._sink(PositionEvent(con_id, quantity, average_cost))
        if con_id in self._position_pnl_request_by_con_id:
            return
        request_id = self._next_position_pnl_request
        self._next_position_pnl_request += 1
        self._position_pnl_request_by_con_id[con_id] = request_id
        client.position_pnl_requests[request_id] = con_id
        client.reqPnLSingle(request_id, client.selected_account, "", con_id)

    async def _cancel_position_subscription(self, con_id: int) -> None:
        request_id = self._position_pnl_request_by_con_id.pop(con_id, None)
        client = self._client
        if request_id is None or client is None:
            return
        if client.isConnected():
            client.cancelPnLSingle(request_id)
        client.position_pnl_requests.pop(request_id, None)

    def emit_from_thread(self, event: Any) -> None:
        loop, sink = self._loop, self._sink
        if loop is None or sink is None or loop.is_closed():
            return
        loop.call_soon_threadsafe(lambda: asyncio.create_task(sink(event)))

    def _executions_complete_from_thread(self, fills: tuple[_ExecutionFill, ...]) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return
        loop.call_soon_threadsafe(
            lambda: asyncio.create_task(self._apply_execution_snapshot(fills))
        )

    async def _apply_execution_snapshot(self, fills: tuple[_ExecutionFill, ...]) -> None:
        self._execution_fills = fills
        self._execution_snapshot_complete = True
        client, sink = self._client, self._sink
        if client is None or sink is None:
            return
        for con_id, (quantity, average_cost) in client.position_cache.items():
            if con_id not in self._instruments or quantity == 0:
                continue
            await sink(
                PositionCostSlotsEvent(
                    con_id,
                    _rebuild_cost_slots(con_id, quantity, average_cost, fills),
                )
            )

    def disconnected_from_thread(self) -> None:
        loop = self._loop
        if loop is not None and not loop.is_closed():
            loop.call_soon_threadsafe(self._disconnected.set)

    def resubscribe_from_thread(self) -> None:
        loop = self._loop
        if loop is not None and not loop.is_closed():
            loop.call_soon_threadsafe(lambda: asyncio.create_task(self._restore_after_data_loss()))

    def complete_contract_from_thread(
        self, request_id: int, candidates: tuple[Instrument, ...]
    ) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return

        def complete() -> None:
            future = self._contract_futures.get(request_id)
            if future is not None and not future.done():
                future.set_result(candidates)

        loop.call_soon_threadsafe(complete)

    def reject_contract_from_thread(self, request_id: int, error_code: int) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return

        def reject() -> None:
            future = self._contract_futures.get(request_id)
            if future is not None and not future.done():
                future.set_exception(
                    ContractResolutionError(
                        f"IB Gateway rejected the contract query (code {error_code})"
                    )
                )

        loop.call_soon_threadsafe(reject)

    async def _connect_once(self) -> None:
        self._disconnected.clear()
        logger.info(
            "gateway_connect host=127.0.0.1 port=%d client_id=%d",
            self._settings.gateway_port,
            self._settings.gateway_client_id,
        )
        client = _HelperIBKRClient(self)
        await asyncio.to_thread(
            client.connect_read_only,
            self._settings.gateway_host,
            self._settings.gateway_port,
            self._settings.gateway_client_id,
        )
        if not client.isConnected():
            raise ConnectionError("IB Gateway connection failed")
        reader_thread = threading.Thread(target=client.run, name="ibkr-api-reader", daemon=True)
        reader_thread.start()
        ready = await asyncio.to_thread(client.ready_event.wait, 15.0)
        if not ready:
            client.disconnect()
            await asyncio.to_thread(reader_thread.join, 2.0)
            raise TimeoutError("IBKR API readiness timeout")
        client.reqManagedAccts()
        accounts_ready = await asyncio.to_thread(client.accounts_event.wait, 15.0)
        if not accounts_ready or len(client.snapshot.accounts) != 1:
            client.disconnect()
            await asyncio.to_thread(reader_thread.join, 2.0)
            raise RuntimeError("exactly one accessible account is required")
        client.selected_account = client.snapshot.accounts[0]
        self._client = client
        self._reader_thread = reader_thread
        client.reqAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID, "All", "Currency,NetLiquidation")
        client.reqPnL(PNL_REQUEST_ID, client.selected_account, "")
        client.reqPositions()
        self._execution_snapshot_complete = False
        execution_filter = ExecutionFilter()
        execution_filter.acctCode = client.selected_account
        client.reqExecutions(EXECUTION_REQUEST_ID, execution_filter)
        logger.info("gateway_connected server_version=%s", client.serverVersion())
        old_instruments = tuple(self._instruments.values())
        self._position_pnl_request_by_con_id.clear()
        for instrument in old_instruments:
            await self.subscribe_watchlist(instrument)

    async def _restore_after_data_loss(self) -> None:
        client = self._client
        if client is None or not client.isConnected() or client.selected_account is None:
            return
        logger.info("gateway_resubscribe_after_1101")
        client.reqAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID, "All", "Currency,NetLiquidation")
        client.reqPnL(PNL_REQUEST_ID, client.selected_account, "")
        client.reqPositions()
        self._execution_snapshot_complete = False
        client.execution_fills.clear()
        execution_filter = ExecutionFilter()
        execution_filter.acctCode = client.selected_account
        client.reqExecutions(EXECUTION_REQUEST_ID, execution_filter)
        self._position_pnl_request_by_con_id.clear()
        for instrument in tuple(self._instruments.values()):
            await self.subscribe_watchlist(instrument)
        if self._sink is not None:
            await self._sink(ConnectionEvent(GatewayState.CONNECTED, 1101))

    async def _monitor_reconnect(self) -> None:
        while not self._stopping:
            await self._disconnected.wait()
            if self._stopping:
                return
            if self._sink is not None:
                await self._sink(ConnectionEvent(GatewayState.RECOVERING))
            logger.info("gateway_recovering")
            await self._close_client()
            backoff = 1.0
            while not self._stopping:
                await asyncio.sleep(backoff)
                try:
                    await self._connect_once()
                except (ConnectionError, RuntimeError, TimeoutError):
                    logger.info("gateway_reconnect_retry backoff_seconds=%.1f", backoff)
                    backoff = min(backoff * 2, 30.0)
                    continue
                break

    async def _close_client(self) -> None:
        client = self._client
        reader_thread = self._reader_thread
        self._client = None
        self._reader_thread = None
        if client is not None and client.isConnected():
            for request_id in tuple(self._position_pnl_request_by_con_id.values()):
                client.cancelPnLSingle(request_id)
            client.cancelPositions()
            client.cancelPnL(PNL_REQUEST_ID)
            client.cancelAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID)
            client.disconnect()
        self._position_pnl_request_by_con_id.clear()
        if reader_thread is not None:
            await asyncio.to_thread(reader_thread.join, 2.0)

    def _require_client(self) -> _HelperIBKRClient:
        if self._client is None or not self._client.isConnected():
            raise AdapterUnavailableError("IB Gateway is not connected")
        return self._client
