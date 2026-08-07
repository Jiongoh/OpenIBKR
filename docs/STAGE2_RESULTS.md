# Stage 2 Python Local Helper results

Status: MVP acceptance passed

## Implemented

- Versioned Pydantic protocol models with Decimal-as-string serialization.
- Capability-minimal Adapter protocol containing no trading methods.
- Deterministic Fake IBKR Adapter for normal development and tests.
- Official TWS API adapter inheriting the Stage 1 fail-closed wire guard.
- Gateway connection states, bounded exponential reconnect and read-subscription
  restoration.
- Account P&L, net liquidation, contract resolution and top-of-book quote events.
- Market data classification for real-time, frozen, delayed and delayed-frozen.
- Idempotent dynamic watchlist subscriptions with a default maximum of 30.
- SQLite schema v2 for contracts, watchlist, settings and latest public snapshot.
- Restored snapshots are always marked stale until fresh callbacks arrive.
- Authenticated loopback-only FastAPI HTTP and WebSocket endpoints.
- WebSocket full snapshot followed by strictly sequenced update envelopes.
- Private rotating logs with no access log, token, full account ID or values.
- Random-port startup handshake that contains only protocol version, port and PID.
- Clean Ctrl-C shutdown.

## Verification

- 31 unit/integration/security tests pass without connecting to IBKR.
- Ruff lint and format checks pass.
- Dependency consistency check passes.
- A real Fake Helper subprocess returned 401 without a token and served health,
  snapshot and watchlist endpoints with a valid token.
- Fake subprocess startup and Ctrl-C shutdown left no process or temporary files.
- Sanitized live adapter smoke test passed twice against `127.0.0.1:4003`:
  connection, masked account, net liquidation, P&L, contract resolution and
  delayed quote callbacks were all received.
- No live financial amount was printed by the smoke test.
- No wire-guard violation occurred.
- After each live run, only IB Gateway remained listening on port 4003.

## Deferred

- SwiftUI/AppKit client and process ownership (Stages 3-4).
- Minute P&L history and retention policy.
- Long-running sleep/wake and 30-symbol soak tests.
- Application signing, notarization, DMG and GitHub workflows.
