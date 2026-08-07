# Stage 3 SwiftUI/AppKit MVP results

## Status

Stage 3 is complete for local development. The app is an Apple Silicon-only
menu-bar application with an AppKit floating panel and a SwiftUI dashboard.
It connects to a manually started Helper during this stage; Helper process
ownership remains Stage 4 work.

## Implemented

- Native `arm64` macOS 14+ application and XCTest target.
- Token-authenticated HTTP and WebSocket client restricted to `127.0.0.1`.
- Protocol v1 decoding with decimal-string handling and fail-closed rejection
  of unsupported protocol versions.
- Account P&L, masked account, connection, stale-data and explicit market-data
  classification display.
- Watchlist quotes with latest price, daily change and daily percentage.
- Contract search and explicit candidate selection for ambiguous symbols.
- Dynamic watchlist add/remove without application restart.
- AppKit `NSPanel` that floats across Spaces, remains visible when another app
  activates, can be resized and dragged, and restores its saved frame.
- Compact/expanded modes, menu-bar show/hide and reconnect controls.
- Basic accessibility labels and keyboard shortcuts.

## Verification

- 33 Python unit/integration/security tests passed.
- Ruff lint and formatting checks passed.
- 3 native XCTest cases passed on macOS 26.6, Apple Silicon.
- The built executable is a single `arm64` Mach-O binary.
- A real GUI smoke test with the Fake Helper verified:
  - authenticated HTTP snapshot and WebSocket updates;
  - connected state, P&L presentation and delayed-data labeling;
  - AAPL add and live quote updates;
  - price change and percentage rendering;
  - compact/expanded panel behavior;
  - ambiguous candidate selection followed by quote subscription.
- The GUI smoke exposed a missing production WebSocket dependency. The
  `websockets` runtime package is now declared and the smoke passes.

The previously completed sanitized read-only Gateway smoke remains green on
the locally configured loopback endpoint. It confirms P&L, contract resolution
and market-data callbacks without printing amounts or account identifiers.
No order, cancellation, execution or trading request was sent.

## Deferred to Stage 4

- Bundle the Python Helper as a self-contained Apple Silicon executable.
- Let the app generate the session token, launch the Helper, parse its startup
  handshake, supervise failures and stop it on exit.
- Sleep/wake recovery, duplicate-instance handling and long-running failure
  tests.
- Full settings for Gateway mode/port and login-at-startup behavior.
