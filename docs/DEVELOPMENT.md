# OpenIBKR development

## Current scope

Stages 1–3 are complete and Stage 4 process ownership is implemented. Physical
sleep/wake acceptance, signing and distribution remain intentionally deferred.

## Environment

- macOS 26.6, arm64
- Xcode 26.6
- Python 3.13.14
- IB Gateway 10.49 on `127.0.0.1:4003`
- Official `ibapi` 10.49.2

Install the separately licensed official SDK first, then the Helper:

```sh
python3.13 -m venv .venv
.venv/bin/python -m pip install "$HOME/IBJts/source/pythonclient"
.venv/bin/python -m pip install -e '.[dev]' --no-deps
```

Run all regular tests without connecting to IBKR:

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Build and test the native app:

```sh
xcodebuild -project app/OpenIBKR.xcodeproj -scheme OpenIBKR \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/OpenIBKRDerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Build the self-contained Apple Silicon Helper before building the App:

```sh
.venv/bin/python -m pip install -e '.[packaging]'
packaging/build-helper.sh
```

The Xcode target embeds the resulting ignored build artifact into
`OpenIBKR.app/Contents/Helpers`. Normal App startup then owns the Helper; the
manual port/token environment shown below remains a development override.

During Stage 3, launch the app executable with the random port printed by a
manually started Helper and the same ephemeral token:

```sh
OPENIBKR_HELPER_PORT='<ready-port>' \
OPENIBKR_SESSION_TOKEN='<same-ephemeral-token>' \
/tmp/OpenIBKRDerivedData/Build/Products/Debug/OpenIBKR.app/Contents/MacOS/OpenIBKR
```

## Manual Fake Helper

Use an ephemeral token and a disposable database path:

```sh
OPENIBKR_SESSION_TOKEN='<at-least-32-random-characters>' \
OPENIBKR_ADAPTER=fake \
OPENIBKR_DATABASE_PATH=/tmp/openibkr-development.sqlite3 \
.venv/bin/openibkr-helper
```

The first stdout line contains only protocol version, random loopback port and
PID.  It never contains the token.

## Read-only IBKR mode

IBKR mode must use a manually authenticated Gateway profile with Read-Only API
enabled and a dedicated positive client ID. Account identifiers and login
credentials must remain outside this repository. This mode must not be used by
normal unit tests:

```sh
OPENIBKR_SESSION_TOKEN='<at-least-32-random-characters>' \
OPENIBKR_ADAPTER=ibkr \
OPENIBKR_GATEWAY_PORT=4003 \
.venv/bin/openibkr-helper
```

The TWS wire allowlist and explicit trading-method guards from Stage 1 remain
active in this mode.  Market requests use delayed data and
`regulatorySnapshot=false`.

The sanitized integration smoke command uses a temporary database and prints
only callback-presence booleans and market-data classification:

```sh
.venv/bin/openibkr-helper-live-smoke
```
