"""Sanitized rotating file logging; financial values and tokens are excluded."""

from __future__ import annotations

import logging
import os
from logging.handlers import RotatingFileHandler
from pathlib import Path


def configure_logging(database_path: Path) -> Path:
    log_directory = database_path.parent / "logs"
    log_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(log_directory, 0o700)
    except PermissionError:
        pass
    log_path = log_directory / "openibkr.log"
    handler = RotatingFileHandler(
        log_path,
        maxBytes=5 * 1024 * 1024,
        backupCount=5,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            "%(asctime)s %(levelname)s %(name)s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S%z",
        )
    )
    root = logging.getLogger("openibkr")
    root.setLevel(logging.INFO)
    root.handlers.clear()
    root.addHandler(handler)
    root.propagate = False
    try:
        os.chmod(log_path, 0o600)
    except PermissionError:
        pass
    return log_path
