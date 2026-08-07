"""Sanitized live-Gateway smoke test; emits no financial values."""

from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import time
from pathlib import Path

from .adapters.live import LiveIBKRAdapter
from .config import HelperSettings
from .models import ContractQuery, GatewayState
from .service import HelperService


async def run_smoke(*, port: int = 4003, timeout_seconds: float = 20.0) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="openibkr-live-smoke-") as directory:
        settings = HelperSettings(
            adapter="ibkr",
            session_token="live-smoke-ephemeral-token-never-served-over-http",
            database_path=Path(directory) / "openibkr.sqlite3",
            gateway_port=port,
            gateway_client_id=72,
        )
        adapter = LiveIBKRAdapter(settings)
        service = HelperService(settings, adapter)
        failure: str | None = None
        try:
            await service.start()
            deadline = time.monotonic() + timeout_seconds
            while time.monotonic() < deadline:
                snapshot = await service.snapshot()
                if (
                    snapshot.connection.state == GatewayState.CONNECTED
                    and snapshot.account.account_masked
                    and snapshot.pnl.daily is not None
                ):
                    break
                await asyncio.sleep(0.1)
            else:
                raise TimeoutError("account/P&L callbacks were not ready")

            await service.add_watchlist(ContractQuery(symbol="IBKR"))
            while time.monotonic() < deadline:
                snapshot = await service.snapshot()
                if snapshot.quotes and snapshot.quotes[0].received_at is not None:
                    break
                await asyncio.sleep(0.1)
            else:
                raise TimeoutError("market data callback was not ready")

            client = adapter._client
            result: dict[str, object] = {
                "success": True,
                "connected": snapshot.connection.state == GatewayState.CONNECTED,
                "account_masked": bool(snapshot.account.account_masked),
                "net_liquidation_received": snapshot.account.net_liquidation is not None,
                "pnl_received": snapshot.pnl.daily is not None,
                "contract_resolved": bool(snapshot.quotes),
                "quote_received": bool(
                    snapshot.quotes and snapshot.quotes[0].received_at is not None
                ),
                "market_data_kind": (
                    snapshot.quotes[0].market_data_kind.value if snapshot.quotes else "unknown"
                ),
                "guard_violation": bool(client and client.guard_violation),
            }
        except (RuntimeError, TimeoutError, ValueError) as exc:
            failure = f"{type(exc).__name__}: {exc}"
            result = {
                "success": False,
                "failure": failure,
                "guard_violation": bool(adapter._client and adapter._client.guard_violation),
            }
        finally:
            await service.stop()
        return result


def main() -> None:
    result = asyncio.run(run_smoke())
    print(json.dumps(result, sort_keys=True))
    sys.exit(0 if result["success"] else 1)


if __name__ == "__main__":
    main()
