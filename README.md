# OpenIBKR

OpenIBKR is a local-first, read-only IBKR dashboard for macOS. It keeps daily
P&L and watchlist quotes visible in a compact floating panel without adding any
trading capability.

> [!IMPORTANT]
> OpenIBKR is an independent project and is not affiliated with or endorsed by
> Interactive Brokers. It is currently intended for development and personal
> evaluation; no signed or notarized public binary is available yet.

## What it does

- Shows daily P&L, daily percentage change, unrealized P&L and realized P&L.
- Expands the P&L card on hover while keeping its top-left position stable.
- Displays a collapsible watchlist with price, absolute change and percentage
  change.
- Can optionally use Alpaca's official overnight market-data feed for indicative
  quotes and compact 24-hour trend lines.
- Uses compact inactive rows and expands individual quotes on hover.
- Adds and removes US stock symbols without restarting the app.
- Reports invalid or ambiguous symbols instead of creating zero-price rows.
- Distinguishes live, delayed, frozen and unavailable market data.
- Resizes the floating `NSPanel` to the currently visible modules, so invisible
  window space does not block other apps.
- Owns and restarts its bundled local Helper process and can launch at login.

The interface is built with SwiftUI and AppKit for Apple Silicon Macs. Account
and market data are supplied by a bundled Python Helper that communicates with
IB Gateway through the official TWS API.

## Read-only safety model

OpenIBKR does **not** implement trading.

- The official IBKR wire client uses a fail-closed outgoing-message allowlist.
- Order placement, cancellation, global cancellation, option exercise, order
  queries and execution queries are blocked at both method and wire layers.
- OpenIBKR and the Helper connect only through literal `127.0.0.1` endpoints.
- The Helper API uses a random local port and a one-time token that remains only
  in process memory.
- The full account ID, IBKR credentials and 2FA material are never persisted.
- Optional Alpaca Paper API credentials are stored only in the user's macOS
  Keychain and passed to the Helper over its authenticated loopback channel.
- Alpaca integration is hard-limited to two `GET` market-data routes on
  `data.alpaca.markets`; no trading, order, position or account route exists.
- Regulatory snapshots are disabled.

These application safeguards are defense in depth. IB Gateway's own
**Read-Only API** setting must remain enabled.

## Requirements

- Apple Silicon Mac running macOS 14 or later
- Xcode with the macOS SDK, when building from source
- Python 3.13
- IB Gateway 10.49
- Official TWS API 10.49.02 / `ibapi` 10.49.2
- An IBKR username permitted to view the intended account
- Appropriate IBKR market-data entitlements for real-time quotes, if required

The TWS API is separately licensed by Interactive Brokers. It is not included
in this repository and must not be copied into a fork or release artifact.

## IB Gateway configuration

Log in through the official IB Gateway application and use the following API
settings:

- API type: **IB API**
- Socket port: `4003` (the project default)
- **Read-Only API:** enabled
- **Allow connections from localhost only:** enabled
- Trusted IPs: `127.0.0.1` only

OpenIBKR never stores the Gateway username, password or second-factor material.
See [IBKR setup](docs/IBKR_SETUP.md) for the complete operating and verification
procedure.

## Build from source

Install the separately downloaded official TWS API first. The following example
assumes its Python client is located at `$HOME/IBJts/source/pythonclient`:

```sh
git clone https://github.com/Jiongoh/OpenIBKR.git
cd OpenIBKR

python3.13 -m venv .venv
.venv/bin/python -m pip install "$HOME/IBJts/source/pythonclient"
.venv/bin/python -m pip install -e '.[dev,packaging]'

packaging/build-release.sh
```

The build script prints the generated `OpenIBKR.app` path. This local build is
unsigned; public distribution requires Developer ID signing and Apple
notarization as described in the [release guide](docs/RELEASE.md).

OpenIBKR defaults to the read-only Gateway adapter on port `4003`. Its Settings
window also provides a deterministic Fake data source for UI development.

## Optional Alpaca overnight quotes

IBKR remains the source for account NAV and P&L. If an Alpaca Paper API key is
configured, OpenIBKR uses Alpaca only for watchlist quotes during the U.S.
overnight session (20:00–04:00 America/New_York, Sunday evening through Friday
morning):

1. Open the OpenIBKR menu-bar item and choose **Settings…**.
2. Under **Alpaca Overnight Market Data**, enter the Paper API Key ID and Secret
   Key, then choose **Save & Connect**.
3. Confirm that the status reads **Alpaca Overnight · Active** during the
   overnight session, or **Standby** outside it.

Never put API keys in project files, terminal commands, screenshots, issues or
Git commits. OpenIBKR stores them as device-local Keychain items and restores
the market-data connection when its local Helper restarts. The displayed
overnight price is an indicative bid/ask midpoint and may differ from an
executable broker quote.

OpenIBKR uses short-lived authenticated HTTPS `GET` requests for Alpaca data;
it does not open an Alpaca WebSocket or consume the Basic plan's 30-symbol
streaming subscription pool. The only WebSocket in the app is the authenticated
`127.0.0.1` channel between the native UI and its bundled local Helper.

## Development and tests

Run the Helper checks without connecting to IBKR:

```sh
.venv/bin/ruff check helper/src tests
.venv/bin/ruff format --check helper/src tests
.venv/bin/python -m unittest discover -s tests -v
```

Build and test the native app:

```sh
xcodebuild -project app/OpenIBKR.xcodeproj -scheme OpenIBKR \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/OpenIBKRDerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Normal automated tests use Fake data and do not require or access a live IBKR
account. Live smoke testing is a separate, explicit procedure.

## Market-data behavior

Market data is account- and exchange-specific. OpenIBKR does not purchase
subscriptions or request billable regulatory snapshots. Without the necessary
entitlements, IBKR may return delayed, frozen or unavailable quotes; the UI
preserves that classification rather than presenting unavailable values as a
real price.

When optional Alpaca credentials are configured, the overnight watchlist uses
Alpaca's overnight indicative snapshot and BOATS minute bars. Historical bars
may trail the current quote; OpenIBKR merges the newest indicative quote into
the line and continues showing current quotes if historical bars are
temporarily unavailable.

Trend points and minute P&L samples are retained for 24 hours. A wall-clock
cleanup runs every minute, including outside trading hours, and removed
watchlist symbols have their local trend history discarded immediately.

## Architecture

```text
OpenIBKR.app (SwiftUI + AppKit)
        |
        | token-authenticated HTTP/WebSocket on random 127.0.0.1 port
        v
Bundled OpenIBKR Helper (Python)
        |                                      |
        | allowlisted read-only TWS API        | allowlisted HTTPS GET only
        | on 127.0.0.1:4003                    | (optional overnight quotes)
        v                                      v
IB Gateway (Read-Only API enabled)     data.alpaca.markets
```

The Helper persists the watchlist and public latest snapshot in a local SQLite
database under the user's Application Support directory. Credentials, complete
account identifiers and session tokens are excluded from that database.

## Project status

- Read-only IBKR feasibility and safety spike: complete
- Local Helper and authenticated loopback protocol: implemented
- SwiftUI/AppKit floating dashboard: implemented
- Managed Helper lifecycle and reconnect handling: implemented
- Source build and release scripts: available
- Developer ID signing, notarization and public binary distribution: pending
- Physical sleep/wake acceptance: manual validation still required

## Documentation

- [Development guide](docs/DEVELOPMENT.md)
- [IBKR setup](docs/IBKR_SETUP.md)
- [Release process](docs/RELEASE.md)
- [Stage 1 results](docs/SPIKE_RESULTS.md)
- [Stage 2 results](docs/STAGE2_RESULTS.md)
- [Stage 3 results](docs/STAGE3_RESULTS.md)
- [Stage 4 results](docs/STAGE4_RESULTS.md)

## Disclaimer

OpenIBKR is informational software, not investment advice. Use it at your own
risk and verify all displayed information in an official IBKR application
before making financial decisions.
