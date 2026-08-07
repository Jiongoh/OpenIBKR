"""Authenticated loopback HTTP and WebSocket API."""

from __future__ import annotations

import hmac
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Response, WebSocket
from fastapi.websockets import WebSocketDisconnect

from . import HELPER_VERSION
from .adapters.base import AdapterUnavailableError, ContractResolutionError
from .database import SCHEMA_VERSION
from .models import AppSnapshot, ContractQuery, HealthResponse, Instrument
from .service import HelperService, WatchlistFullError


def _bearer_token(authorization: str | None) -> str | None:
    if authorization is None or not authorization.startswith("Bearer "):
        return None
    return authorization.removeprefix("Bearer ")


def create_app(service: HelperService) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        await service.start()
        try:
            yield
        finally:
            await service.stop()

    app = FastAPI(
        title="OpenIBKR Local Helper",
        version=HELPER_VERSION,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    expected_token = service.settings.session_token

    async def authorize(authorization: str | None = Header(default=None)) -> None:
        supplied = _bearer_token(authorization)
        if supplied is None or not hmac.compare_digest(supplied, expected_token):
            raise HTTPException(status_code=401, detail="unauthorized")

    @app.get("/v1/health", response_model=HealthResponse, dependencies=[Depends(authorize)])
    async def health() -> HealthResponse:
        snapshot = await service.snapshot()
        return HealthResponse(
            helper_version=HELPER_VERSION,
            gateway_state=snapshot.connection.state,
            database_schema_version=SCHEMA_VERSION,
            uptime_seconds=service.uptime_seconds,
        )

    @app.get("/v1/snapshot", response_model=AppSnapshot, dependencies=[Depends(authorize)])
    async def snapshot() -> AppSnapshot:
        return await service.snapshot()

    @app.get(
        "/v1/watchlist",
        response_model=list[Instrument],
        dependencies=[Depends(authorize)],
    )
    async def list_watchlist() -> list[Instrument]:
        return await service.list_watchlist()

    @app.post(
        "/v1/contracts/search",
        response_model=list[Instrument],
        dependencies=[Depends(authorize)],
    )
    async def search_contracts(query: ContractQuery) -> tuple[Instrument, ...]:
        try:
            return await service.search_contracts(query)
        except AdapterUnavailableError as exc:
            raise HTTPException(status_code=503, detail="IB Gateway unavailable") from exc

    @app.post(
        "/v1/watchlist/instrument",
        response_model=Instrument,
        status_code=201,
        dependencies=[Depends(authorize)],
    )
    async def add_watchlist_instrument(instrument: Instrument, response: Response) -> Instrument:
        before = {item.con_id for item in await service.list_watchlist()}
        try:
            selected = await service.add_watchlist_instrument(instrument)
        except WatchlistFullError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except ContractResolutionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        if selected.con_id in before:
            response.status_code = 200
        return selected

    @app.post(
        "/v1/watchlist",
        response_model=Instrument,
        status_code=201,
        dependencies=[Depends(authorize)],
    )
    async def add_watchlist(query: ContractQuery, response: Response) -> Instrument:
        before = {item.con_id for item in await service.list_watchlist()}
        try:
            instrument = await service.add_watchlist(query)
        except WatchlistFullError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except AdapterUnavailableError as exc:
            raise HTTPException(status_code=503, detail="IB Gateway unavailable") from exc
        except ContractResolutionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        if instrument.con_id in before:
            response.status_code = 200
        return instrument

    @app.delete(
        "/v1/watchlist/{con_id}",
        status_code=204,
        dependencies=[Depends(authorize)],
    )
    async def remove_watchlist(con_id: int) -> Response:
        removed = await service.remove_watchlist(con_id)
        if not removed:
            raise HTTPException(status_code=404, detail="instrument not found")
        return Response(status_code=204)

    @app.websocket("/v1/stream")
    async def stream(websocket: WebSocket) -> None:
        supplied = _bearer_token(websocket.headers.get("authorization"))
        if supplied is None or not hmac.compare_digest(supplied, expected_token):
            await websocket.close(code=4401, reason="unauthorized")
            return
        await websocket.accept()
        queue = await service.store.register()
        try:
            initial = await service.store.initial_envelope()
            await websocket.send_json(initial.model_dump(mode="json"))
            while True:
                envelope = await queue.get()
                await websocket.send_json(envelope.model_dump(mode="json"))
        except WebSocketDisconnect:
            pass
        finally:
            await service.store.unregister(queue)

    return app
