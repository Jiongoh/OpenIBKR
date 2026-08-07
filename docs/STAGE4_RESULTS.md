# Stage 4 process ownership and reliability results

## Status

The Stage 4 implementation is complete. Automated and local operational tests
pass. A physical Mac sleep/wake cycle and enabling the persistent login item
remain manual acceptance checks because they alter the active desktop session.

## Implemented

- PyInstaller build for a self-contained Apple Silicon Helper executable.
- Xcode embeds the Helper at `OpenIBKR.app/Contents/Helpers/openibkr-helper`.
- The App generates a cryptographically random in-memory session token, starts
  the Helper, validates its bounded stdout handshake and connects to its random
  loopback port.
- A 30-second startup timeout, sanitized error display and at most three
  automatic restart attempts are implemented.
- PyInstaller's bootloader PID and service PID are both tracked. Normal App
  termination sends a bounded graceful termination and uses SIGKILL only after
  a three-second timeout, preventing orphan Helper processes.
- A private file lock prevents a second App instance from launching another
  Helper or competing for the SQLite database.
- Sleep marks visible data stale; wake reconnects the HTTP/WebSocket client.
- Settings cover IB Gateway/Fake source, Gateway port and macOS login startup.
- IBKR connectivity codes are explicit: 1101 re-subscribes after data loss,
  1102 keeps data and returns to connected, and 1300 enters disconnected
  recovery.
- SQLite schema v3 stores at most one P&L sample per minute and removes samples
  older than 30 days.

## Verification

- 35 Python unit/integration/security tests passed.
- Ruff lint and formatting passed; Python dependency validation passed.
- 3 native XCTest cases passed on Apple Silicon; the XCTest environment is
  explicitly prevented from starting a Helper or connecting to Live Gateway.
- The PyInstaller output and both executables in the final debug `.app` are
  single-architecture `arm64` Mach-O binaries.
- The bundled Helper ran without a virtual environment or system Python and
  served authenticated HTTP and WebSocket traffic.
- App-owned Fake Helper test passed with no caller-supplied port or token.
- Forced Helper termination moved the UI to recovery, automatically launched
  a replacement and returned to connected state.
- A second App process exited immediately while the first instance continued.
- Normal App exit was verified to leave no Helper listener or process.
- SQLite schema v3 and minute-snapshot insertion were verified without printing
  financial values.
- Final App-owned integration test connected to a read-only Gateway on the
  configured loopback endpoint and received masked account and P&L data.
  Account type, identifiers and entitlement details are intentionally omitted.
  No trading request exists in the adapter or local API, and no order-related
  request was sent.

## Remaining manual checks

- Put the Mac to sleep and wake it while Gateway remains logged in, then verify
  the UI returns to connected without restarting the App.
- Optionally enable “登录时启动 OpenIBKR”, log out/in and verify App startup.
- Stage 5 Developer ID signing, Notarization, DMG creation and clean-Mac install
  verification require the user's Apple signing identity and are not performed
  by Stage 4.
