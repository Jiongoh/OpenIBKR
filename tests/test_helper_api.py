from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from openibkr_helper.adapters.fake import FakeIBKRAdapter
from openibkr_helper.api import create_app
from openibkr_helper.config import HelperSettings
from openibkr_helper.models import MarketDataStatus
from openibkr_helper.service import HelperService
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

TOKEN = "api-test-token-that-is-at-least-32-characters"


class StubMarketData:
    def __init__(self) -> None:
        self._status = MarketDataStatus()

    async def start(self, sink) -> None:  # noqa: ANN001
        self.sink = sink

    async def stop(self) -> None:
        pass

    async def subscribe(self, instrument) -> None:  # noqa: ANN001
        pass

    async def unsubscribe(self, con_id: int) -> None:
        pass

    def should_override_quotes(self) -> bool:
        return False

    def status(self) -> MarketDataStatus:
        return self._status

    async def configure(self, credentials) -> MarketDataStatus:  # noqa: ANN001
        self._status = MarketDataStatus(provider="alpaca_overnight", configured=True, active=True)
        return self._status

    async def clear(self) -> MarketDataStatus:
        self._status = MarketDataStatus()
        return self._status


class HelperAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        settings = HelperSettings(
            session_token=TOKEN,
            database_path=Path(self.temp.name) / "openibkr.sqlite3",
        )
        self.adapter = FakeIBKRAdapter(tick_interval=60.0)
        self.market_data = StubMarketData()
        self.service = HelperService(settings, self.adapter, market_data=self.market_data)
        self.client_context = TestClient(create_app(self.service))
        self.client = self.client_context.__enter__()
        self.headers = {"Authorization": f"Bearer {TOKEN}"}

    def tearDown(self) -> None:
        self.client_context.__exit__(None, None, None)
        self.temp.cleanup()

    def test_every_http_endpoint_requires_token(self) -> None:
        self.assertEqual(self.client.get("/v1/health").status_code, 401)
        self.assertEqual(self.client.get("/v1/snapshot").status_code, 401)
        self.assertEqual(self.client.get("/v1/watchlist").status_code, 401)
        self.assertEqual(self.client.get("/v1/market-data/status").status_code, 401)
        self.assertEqual(
            self.client.post(
                "/v1/market-data/alpaca/credentials",
                json={"key_id": "PKTEST123456", "secret_key": "secret-credential-value"},
            ).status_code,
            401,
        )
        self.assertEqual(
            self.client.post("/v1/contracts/search", json={"symbol": "AAPL"}).status_code,
            401,
        )
        self.assertEqual(
            self.client.post("/v1/watchlist", json={"symbol": "AAPL"}).status_code,
            401,
        )

    def test_health_snapshot_and_watchlist_crud(self) -> None:
        health = self.client.get("/v1/health", headers=self.headers)
        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["gateway_state"], "connected")
        snapshot = self.client.get("/v1/snapshot", headers=self.headers)
        self.assertEqual(snapshot.status_code, 200)
        self.assertEqual(snapshot.json()["protocol_version"], 1)

        created = self.client.post("/v1/watchlist", json={"symbol": "aapl"}, headers=self.headers)
        self.assertEqual(created.status_code, 201)
        con_id = created.json()["con_id"]
        duplicate = self.client.post("/v1/watchlist", json={"symbol": "AAPL"}, headers=self.headers)
        self.assertEqual(duplicate.status_code, 200)
        listed = self.client.get("/v1/watchlist", headers=self.headers)
        self.assertEqual(len(listed.json()), 1)
        deleted = self.client.delete(f"/v1/watchlist/{con_id}", headers=self.headers)
        self.assertEqual(deleted.status_code, 204)
        missing = self.client.delete(f"/v1/watchlist/{con_id}", headers=self.headers)
        self.assertEqual(missing.status_code, 404)

    def test_alpaca_credentials_are_memory_only_and_authenticated(self) -> None:
        configured = self.client.post(
            "/v1/market-data/alpaca/credentials",
            json={
                "key_id": "PKTEST123456",
                "secret_key": "secret-credential-value",
            },
            headers=self.headers,
        )
        self.assertEqual(configured.status_code, 200)
        self.assertTrue(configured.json()["configured"])
        status = self.client.get("/v1/market-data/status", headers=self.headers)
        self.assertEqual(status.json()["provider"], "alpaca_overnight")
        cleared = self.client.delete("/v1/market-data/alpaca/credentials", headers=self.headers)
        self.assertFalse(cleared.json()["configured"])

    def test_websocket_requires_header_and_starts_with_snapshot(self) -> None:
        with self.assertRaises(WebSocketDisconnect):
            with self.client.websocket_connect("/v1/stream"):
                pass
        with self.client.websocket_connect("/v1/stream", headers=self.headers) as websocket:
            initial = websocket.receive_json()
            self.assertEqual(initial["type"], "snapshot")
            self.assertEqual(initial["protocol_version"], 1)
            self.assertIn("snapshot", initial["payload"])

            created = self.client.post(
                "/v1/watchlist", json={"symbol": "AAPL"}, headers=self.headers
            )
            self.assertEqual(created.status_code, 201)
            previous_sequence = initial["sequence"]
            observed_kinds: set[str] = set()
            for _ in range(8):
                update = websocket.receive_json()
                self.assertEqual(update["type"], "update")
                self.assertGreater(update["sequence"], previous_sequence)
                previous_sequence = update["sequence"]
                observed_kinds.add(update["payload"]["kind"])
                if "quote" in observed_kinds:
                    break
            self.assertIn("watchlist_added", observed_kinds)
            self.assertIn("quote", observed_kinds)

    def test_ambiguous_contract_requires_candidate_selection(self) -> None:
        search = self.client.post(
            "/v1/contracts/search", json={"symbol": "AMBIG"}, headers=self.headers
        )
        self.assertEqual(search.status_code, 200)
        candidates = search.json()
        self.assertEqual(len(candidates), 2)

        direct = self.client.post("/v1/watchlist", json={"symbol": "AMBIG"}, headers=self.headers)
        self.assertEqual(direct.status_code, 422)

        selected = self.client.post(
            "/v1/watchlist/instrument", json=candidates[1], headers=self.headers
        )
        self.assertEqual(selected.status_code, 201)
        self.assertEqual(selected.json()["con_id"], candidates[1]["con_id"])

        forged = dict(candidates[0])
        forged["con_id"] += 999
        rejected = self.client.post("/v1/watchlist/instrument", json=forged, headers=self.headers)
        self.assertEqual(rejected.status_code, 422)

    def test_missing_and_invalid_symbols_return_actionable_results(self) -> None:
        missing = self.client.post(
            "/v1/contracts/search", json={"symbol": "MISSING"}, headers=self.headers
        )
        self.assertEqual(missing.status_code, 200)
        self.assertEqual(missing.json(), [])

        invalid = self.client.post(
            "/v1/contracts/search", json={"symbol": "AAPL;DROP"}, headers=self.headers
        )
        self.assertEqual(invalid.status_code, 422)
        self.assertIn("detail", invalid.json())


if __name__ == "__main__":
    unittest.main()
