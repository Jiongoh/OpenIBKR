"""Executable entry point for the local Helper process."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import socket

import uvicorn

from . import PROTOCOL_VERSION
from .adapters.fake import FakeIBKRAdapter
from .adapters.live import LiveIBKRAdapter
from .api import create_app
from .config import HelperSettings
from .logging_config import configure_logging
from .service import HelperService

logger = logging.getLogger("openibkr.main")


def build_service(settings: HelperSettings) -> HelperService:
    adapter = FakeIBKRAdapter() if settings.adapter == "fake" else LiveIBKRAdapter(settings)
    return HelperService(settings, adapter)


def _configured_parent_pid() -> int | None:
    raw = os.environ.get("OPENIBKR_PARENT_PID")
    if raw is None:
        return None
    try:
        parent_pid = int(raw)
    except ValueError as exc:
        raise RuntimeError("OPENIBKR_PARENT_PID must be an integer") from exc
    if parent_pid <= 1:
        raise RuntimeError("OPENIBKR_PARENT_PID must identify a user process")
    return parent_pid


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


async def _watch_parent(server: uvicorn.Server, parent_pid: int | None) -> None:
    if parent_pid is None:
        return
    while True:
        await asyncio.sleep(2.0)
        if _process_exists(parent_pid):
            continue
        logger.info("helper_parent_gone exiting=true")
        server.should_exit = True
        return


async def serve(settings: HelperSettings) -> None:
    service = build_service(settings)
    app = create_app(service)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((settings.bind_host, settings.bind_port))
    listener.listen(128)
    listener.setblocking(False)
    port = int(listener.getsockname()[1])
    config = uvicorn.Config(
        app,
        host=settings.bind_host,
        port=port,
        log_level="warning",
        access_log=False,
    )
    server = uvicorn.Server(config)
    parent_watchdog = asyncio.create_task(
        _watch_parent(server, _configured_parent_pid()),
        name="openibkr-parent-watchdog",
    )
    # The handshake means the database and adapter have initialized, not merely
    # that a TCP socket was allocated.  FastAPI lifespan start is idempotent.
    try:
        await service.start()
        if server.should_exit:
            return
        logger.info("helper_ready host=127.0.0.1 port=%d protocol=%d", port, PROTOCOL_VERSION)
        print(
            json.dumps(
                {
                    "type": "ready",
                    "protocol_version": PROTOCOL_VERSION,
                    "port": port,
                    "pid": os.getpid(),
                },
                sort_keys=True,
            ),
            flush=True,
        )
        await server.serve(sockets=[listener])
    finally:
        parent_watchdog.cancel()
        await asyncio.gather(parent_watchdog, return_exceptions=True)
        await service.stop()


def main() -> None:
    settings = HelperSettings.from_environment()
    configure_logging(settings.database_path)
    try:
        asyncio.run(serve(settings))
    except KeyboardInterrupt:
        # Uvicorn and the service lifespan have already performed cleanup.
        pass


if __name__ == "__main__":
    main()
