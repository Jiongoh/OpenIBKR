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


async def serve(settings: HelperSettings) -> None:
    service = build_service(settings)
    app = create_app(service)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((settings.bind_host, settings.bind_port))
    listener.listen(128)
    listener.setblocking(False)
    port = int(listener.getsockname()[1])
    # The handshake means the database and adapter have initialized, not merely
    # that a TCP socket was allocated.  FastAPI lifespan start is idempotent.
    await service.start()
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
    config = uvicorn.Config(
        app,
        host=settings.bind_host,
        port=port,
        log_level="warning",
        access_log=False,
    )
    server = uvicorn.Server(config)
    try:
        await server.serve(sockets=[listener])
    finally:
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
