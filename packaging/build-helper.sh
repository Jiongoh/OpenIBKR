#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PYTHON_BIN=${OPENIBKR_BUILD_PYTHON:-"$PROJECT_ROOT/.venv/bin/python"}

"$PYTHON_BIN" -m PyInstaller \
  --noconfirm \
  --clean \
  --onefile \
  --name openibkr-helper \
  --distpath "$PROJECT_ROOT/packaging/dist" \
  --workpath "$PROJECT_ROOT/packaging/build" \
  --specpath "$PROJECT_ROOT/packaging" \
  --hidden-import uvicorn.logging \
  --hidden-import uvicorn.loops.auto \
  --hidden-import uvicorn.protocols.http.auto \
  --hidden-import uvicorn.protocols.websockets.auto \
  --hidden-import uvicorn.lifespan.on \
  "$PROJECT_ROOT/packaging/helper_entry.py"

file "$PROJECT_ROOT/packaging/dist/openibkr-helper"
