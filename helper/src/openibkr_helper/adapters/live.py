"""Official TWS API adapter with fail-closed wire guard and reconnection."""

from __future__ import annotations

import asyncio
import logging
import threading
from decimal import Decimal, InvalidOperation
from typing import Any

from ibapi.contract import Contract, ContractDetails
from openibkr_spike.readonly_client import ReadOnlyIBKRClient, mask_identifier

from ..config import HelperSettings
from ..events import (
    AccountEvent,
    ConnectionEvent,
    MarketDataTypeEvent,
    PnLEvent,
    QuoteEvent,
)
from ..models import ContractQuery, GatewayState, Instrument, MarketDataKind
from .base import AdapterUnavailableError, ContractResolutionError, EventSink

logger = logging.getLogger("openibkr.ibkr")

ACCOUNT_SUMMARY_REQUEST_ID = 7201
PNL_REQUEST_ID = 7202
CONTRACT_REQUEST_ID_START = 8000
MARKET_REQUEST_ID_START = 10000


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
        self.market_requests: dict[int, int] = {}

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

    def marketDataType(self, reqId: int, marketDataType: int) -> None:  # noqa: N802
        super().marketDataType(reqId, marketDataType)
        con_id = self.market_requests.get(reqId)
        if con_id is not None:
            self._emit(MarketDataTypeEvent(con_id, MarketDataKind.from_ibkr(marketDataType)))

    def tickPrice(self, reqId: int, tickType: int, price: float, attrib: Any) -> None:  # noqa: N802
        super().tickPrice(reqId, tickType, price, attrib)
        con_id = self.market_requests.get(reqId)
        value = _decimal(price)
        if con_id is None or value is None or value < 0:
            return
        field = {
            1: "bid",
            2: "ask",
            4: "last",
            9: "close",
            66: "bid",
            67: "ask",
            68: "last",
            75: "close",
        }.get(int(tickType))
        if field is not None:
            self._emit(QuoteEvent(con_id, field, value))

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
        self._next_market_request = MARKET_REQUEST_ID_START
        self._instruments: dict[int, Instrument] = {}
        self._market_request_by_con_id: dict[int, int] = {}

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

    async def subscribe_quote(self, instrument: Instrument) -> None:
        self._instruments[instrument.con_id] = instrument
        if instrument.con_id in self._market_request_by_con_id:
            return
        client = self._client
        if client is None or not client.isConnected():
            # Keep the desired set in memory.  The reconnect cycle restores it
            # once the Gateway becomes available.
            return
        request_id = self._next_market_request
        self._next_market_request += 1
        contract = Contract()
        contract.conId = instrument.con_id
        contract.symbol = instrument.symbol
        contract.secType = instrument.sec_type
        contract.exchange = instrument.exchange
        contract.currency = instrument.currency
        contract.primaryExchange = instrument.primary_exchange or ""
        contract.localSymbol = instrument.local_symbol or ""
        client.market_requests[request_id] = instrument.con_id
        self._market_request_by_con_id[instrument.con_id] = request_id
        client.reqMktData(request_id, contract, "", False, False, [])

    async def unsubscribe_quote(self, con_id: int) -> None:
        self._instruments.pop(con_id, None)
        request_id = self._market_request_by_con_id.pop(con_id, None)
        client = self._client
        if request_id is None or client is None or not client.isConnected():
            return
        client.cancelMktData(request_id)
        client.market_requests.pop(request_id, None)

    def emit_from_thread(self, event: Any) -> None:
        loop, sink = self._loop, self._sink
        if loop is None or sink is None or loop.is_closed():
            return
        loop.call_soon_threadsafe(lambda: asyncio.create_task(sink(event)))

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
        client.reqMarketDataType(3)
        logger.info("gateway_connected server_version=%s", client.serverVersion())
        old_instruments = tuple(self._instruments.values())
        self._market_request_by_con_id.clear()
        for instrument in old_instruments:
            await self.subscribe_quote(instrument)

    async def _restore_after_data_loss(self) -> None:
        client = self._client
        if client is None or not client.isConnected() or client.selected_account is None:
            return
        logger.info("gateway_resubscribe_after_1101")
        client.reqAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID, "All", "Currency,NetLiquidation")
        client.reqPnL(PNL_REQUEST_ID, client.selected_account, "")
        client.reqMarketDataType(3)
        client.market_requests.clear()
        self._market_request_by_con_id.clear()
        for instrument in tuple(self._instruments.values()):
            await self.subscribe_quote(instrument)
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
            for request_id in tuple(self._market_request_by_con_id.values()):
                client.cancelMktData(request_id)
            client.cancelPnL(PNL_REQUEST_ID)
            client.cancelAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID)
            client.disconnect()
        self._market_request_by_con_id.clear()
        if reader_thread is not None:
            await asyncio.to_thread(reader_thread.join, 2.0)

    def _require_client(self) -> _HelperIBKRClient:
        if self._client is None or not self._client.isConnected():
            raise AdapterUnavailableError("IB Gateway is not connected")
        return self._client
