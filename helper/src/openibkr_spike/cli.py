"""Command-line runner for staged, read-only live validation."""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from collections.abc import Sequence

from ibapi.contract import Contract

from .readonly_client import ReadOnlyIBKRClient, TradingDisabledError

ACCOUNT_SUMMARY_TAGS = "Currency,NetLiquidation"
ACCOUNT_SUMMARY_REQUEST_ID = 7101
PNL_REQUEST_ID = 7102
CONTRACT_REQUEST_ID = 7103
MARKET_REQUEST_ID = 7104


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail-closed, read-only IBKR TWS API feasibility check"
    )
    parser.add_argument(
        "mode",
        choices=("connection", "account", "market", "all", "reconnect"),
        help="validation stage; start with connection",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4003)
    parser.add_argument("--client-id", type=int, default=71)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument(
        "--observe-seconds",
        type=float,
        default=0.0,
        help="continue collecting callback timing/field metadata (0-60 seconds)",
    )
    parser.add_argument("--symbol", default="IBKR")
    parser.add_argument(
        "--outage-timeout",
        type=float,
        default=180.0,
        help="seconds to wait for a manual Gateway restart in reconnect mode",
    )
    parser.add_argument(
        "--reconnect-timeout",
        type=float,
        default=180.0,
        help="seconds to retry after the Gateway connection drops",
    )
    parser.add_argument(
        "--market-data-mode",
        choices=("live", "delayed"),
        default="delayed",
        help="live checks subscription entitlement; delayed checks fallback data",
    )
    return parser


def _wait(event: threading.Event, timeout: float, label: str) -> None:
    if not event.wait(timeout):
        raise TimeoutError(f"Timed out waiting for {label}")


def _request_accounts(client: ReadOnlyIBKRClient, timeout: float) -> None:
    client.reqManagedAccts()
    _wait(client.accounts_event, timeout, "managed accounts")
    if not client.snapshot.accounts:
        raise RuntimeError("Gateway returned no accessible accounts")


def _request_account_data(
    client: ReadOnlyIBKRClient, timeout: float, observe_seconds: float
) -> None:
    if len(client.snapshot.accounts) != 1:
        raise RuntimeError(
            "Account validation requires exactly one accessible account; refusing to auto-select"
        )
    account = client.snapshot.accounts[0]
    client.reqAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID, "All", ACCOUNT_SUMMARY_TAGS)
    client.reqPositions()
    client.reqPnL(PNL_REQUEST_ID, account, "")
    _wait(client.summary_event, timeout, "account summary")
    _wait(client.positions_event, timeout, "positions")
    _wait(client.pnl_event, timeout, "P&L")
    if observe_seconds:
        time.sleep(observe_seconds)


def _make_stock(symbol: str) -> Contract:
    if not symbol.isascii() or not symbol.isalnum() or not 1 <= len(symbol) <= 12:
        raise ValueError("Symbol must be 1-12 ASCII letters or digits")
    contract = Contract()
    contract.symbol = symbol.upper()
    contract.secType = "STK"
    contract.exchange = "SMART"
    contract.currency = "USD"
    return contract


def _request_market_data(
    client: ReadOnlyIBKRClient,
    timeout: float,
    symbol: str,
    market_data_mode: str,
    observe_seconds: float,
) -> None:
    client.reqContractDetails(CONTRACT_REQUEST_ID, _make_stock(symbol))
    _wait(client.contract_event, timeout, "contract details")
    contract = client.snapshot.resolved_contract
    if contract is None:
        raise RuntimeError("No unambiguous contract was resolved")

    # regulatorySnapshot=False prevents the fee-bearing US regulatory snapshot
    # product from being used.  Streaming requests do not auto-purchase a data
    # subscription; absent live entitlement, IBKR returns an error/fallback.
    requested_type = 1 if market_data_mode == "live" else 3
    client.market_tick_event.clear()
    client.market_error_event.clear()
    client.snapshot.market_request_error_received = False
    client.reqMarketDataType(requested_type)
    client.reqMktData(MARKET_REQUEST_ID, contract, "", False, False, [])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if client.market_tick_event.is_set():
            if observe_seconds:
                time.sleep(observe_seconds)
            return
        if client.market_error_event.is_set():
            request_error_codes = {
                int(item["code"])
                for item in client.snapshot.errors
                if item["req_id"] == MARKET_REQUEST_ID
            }
            # Code 10167 is the expected notice that delayed data can follow
            # when live entitlement is absent.  In delayed mode it is not a
            # terminal result: require a real tick before declaring success.
            if market_data_mode == "live" or request_error_codes - {10167}:
                return
            client.market_error_event.clear()
        time.sleep(0.05)
    raise TimeoutError("Timed out waiting for a market tick or entitlement response")


def _safe_cancel(client: ReadOnlyIBKRClient, mode: str) -> None:
    if not client.isConnected():
        return
    if mode in {"market", "all"}:
        client.cancelMktData(MARKET_REQUEST_ID)
    if mode in {"account", "all"}:
        client.cancelPnL(PNL_REQUEST_ID)
        client.cancelAccountSummary(ACCOUNT_SUMMARY_REQUEST_ID)
        client.cancelPositions()


def _start_validation_cycle(
    client: ReadOnlyIBKRClient, args: argparse.Namespace
) -> threading.Thread:
    client.connect_read_only(args.host, args.port, args.client_id)
    if not client.isConnected():
        raise ConnectionError("IB Gateway connection was not established")
    loop_thread = threading.Thread(target=client.run, name="ibkr-readonly-reader", daemon=True)
    loop_thread.start()
    _wait(client.ready_event, args.timeout, "API readiness")
    _request_accounts(client, args.timeout)
    _request_account_data(client, args.timeout, 0)
    _request_market_data(client, args.timeout, args.symbol, "delayed", 0)
    return loop_thread


def _run_reconnect_probe(args: argparse.Namespace) -> dict[str, object]:
    initial_client = ReadOnlyIBKRClient()
    active_client = initial_client
    active_thread: threading.Thread | None = None
    attempts = 0
    try:
        if args.outage_timeout <= 0 or args.reconnect_timeout <= 0:
            raise ValueError("Reconnect timeouts must be positive")
        active_thread = _start_validation_cycle(initial_client, args)
        print(
            json.dumps(
                {
                    "phase": "ready_for_manual_gateway_restart",
                    "account_count": len(initial_client.snapshot.accounts),
                    "guard_violation": False,
                },
                sort_keys=True,
            ),
            flush=True,
        )

        outage_deadline = time.monotonic() + args.outage_timeout
        while initial_client.isConnected() and time.monotonic() < outage_deadline:
            time.sleep(0.2)
        if initial_client.isConnected():
            raise TimeoutError("Gateway did not disconnect within outage timeout")
        if active_thread is not None:
            active_thread.join(timeout=2.0)

        reconnect_deadline = time.monotonic() + args.reconnect_timeout
        backoff = 1.0
        while time.monotonic() < reconnect_deadline:
            attempts += 1
            candidate = ReadOnlyIBKRClient()
            try:
                candidate_thread = _start_validation_cycle(candidate, args)
            except (ConnectionError, RuntimeError, TimeoutError):
                if candidate.isConnected():
                    candidate.disconnect()
                remaining = reconnect_deadline - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(backoff, remaining))
                backoff = min(backoff * 2, 8.0)
                continue

            active_client = candidate
            active_thread = candidate_thread
            result = candidate.snapshot.public_dict()
            result.update(
                {
                    "mode": "reconnect",
                    "success": True,
                    "reconnect_attempts": attempts,
                    "initial_connection_closed": initial_client.snapshot.connection_closed,
                    "account_subscription_restored": candidate.snapshot.summary_complete
                    and candidate.snapshot.positions_complete
                    and candidate.snapshot.pnl_callback_received,
                    "market_subscription_restored": bool(candidate.snapshot.tick_types_seen),
                    "guard_violation": candidate.guard_violation is not None,
                }
            )
            return result
        raise TimeoutError("Gateway did not recover within reconnect timeout")
    except (
        ConnectionError,
        RuntimeError,
        TimeoutError,
        ValueError,
        TradingDisabledError,
    ) as exc:
        result = active_client.snapshot.public_dict()
        result.update(
            {
                "mode": "reconnect",
                "success": False,
                "reconnect_attempts": attempts,
                "guard_violation": active_client.guard_violation is not None,
                "failure": f"{type(exc).__name__}: {exc}",
            }
        )
        return result
    finally:
        if active_client.isConnected():
            _safe_cancel(active_client, "all")
            time.sleep(0.1)
            active_client.disconnect()
        if active_thread is not None:
            active_thread.join(timeout=2.0)


def run(args: argparse.Namespace) -> dict[str, object]:
    if args.mode == "reconnect":
        return _run_reconnect_probe(args)

    client = ReadOnlyIBKRClient()
    loop_thread: threading.Thread | None = None
    failure: str | None = None
    try:
        if not 0 <= args.observe_seconds <= 60:
            raise ValueError("--observe-seconds must be between 0 and 60")
        client.connect_read_only(args.host, args.port, args.client_id)
        if not client.isConnected():
            raise ConnectionError("IB Gateway connection was not established")

        loop_thread = threading.Thread(target=client.run, name="ibkr-readonly-reader", daemon=True)
        loop_thread.start()
        _wait(client.ready_event, args.timeout, "API readiness")
        _request_accounts(client, args.timeout)

        if args.mode in {"account", "all"}:
            _request_account_data(client, args.timeout, args.observe_seconds)
        if args.mode in {"market", "all"}:
            _request_market_data(
                client,
                args.timeout,
                args.symbol,
                args.market_data_mode,
                args.observe_seconds,
            )

        if client.guard_violation_event.is_set():
            raise TradingDisabledError(client.guard_violation or "wire guard tripped")
    except (ConnectionError, RuntimeError, TimeoutError, ValueError, TradingDisabledError) as exc:
        failure = f"{type(exc).__name__}: {exc}"
    finally:
        try:
            _safe_cancel(client, args.mode)
            time.sleep(0.1)
        finally:
            if client.isConnected():
                client.disconnect()
            if loop_thread is not None:
                loop_thread.join(timeout=2.0)

    result = client.snapshot.public_dict()
    result["mode"] = args.mode
    if args.mode in {"market", "all"}:
        result["market_data_mode_requested"] = args.market_data_mode
    result["guard_violation"] = client.guard_violation is not None
    result["success"] = failure is None
    if failure is not None:
        result["failure"] = failure
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    result = run(args)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
