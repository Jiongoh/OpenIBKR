# OpenIBKR

OpenIBKR is a local-first macOS floating dashboard for read-only IBKR account
P&L and watchlist quotes.  It does not implement trading.

## Current status

- Stage 1 IBKR feasibility spike: complete.
- Stage 2 Python Local Helper MVP: complete.
- Stage 3 SwiftUI/AppKit floating app: complete.
- Stage 4 Helper process ownership and reliability: implemented; physical
  sleep/wake acceptance remains manual.
- Stage 5 release scripts: prepared; signing/Notarization blocked until a valid
  Developer ID Application identity is installed.
- GitHub, CI, signing and distribution: intentionally deferred.

The Helper provides a token-authenticated HTTP/WebSocket API on a random
`127.0.0.1` port, persists its public latest snapshot and watchlist in SQLite,
and supports Fake and official read-only IBKR adapters.

## Safety invariants

- The official IBKR wire client uses a fail-closed outgoing message allowlist.
- Order placement, cancellation, global cancellation, option exercise, order
  queries and execution queries are blocked at both method and wire layers.
- Gateway and Helper networking is restricted to literal `127.0.0.1`.
- The full account ID, session token and IBKR credentials are never persisted.
- Regulatory snapshots are disabled. Market-data availability depends on the
  deployment's entitlements, and the UI must label the data type returned by
  IBKR.

## Development

```sh
python3.13 -m venv .venv
.venv/bin/python -m pip install "$HOME/IBJts/source/pythonclient"
.venv/bin/python -m pip install -e '.[dev]'
.venv/bin/ruff check helper/src tests
.venv/bin/ruff format --check helper/src tests
.venv/bin/python -m unittest discover -s tests -v
```

See [development instructions](docs/DEVELOPMENT.md),
[IBKR setup](docs/IBKR_SETUP.md), [Stage 1 results](docs/SPIKE_RESULTS.md),
[Stage 2 results](docs/STAGE2_RESULTS.md),
[Stage 3 results](docs/STAGE3_RESULTS.md), and
[Stage 4 results](docs/STAGE4_RESULTS.md). Release prerequisites and commands
are in [the release guide](docs/RELEASE.md).
