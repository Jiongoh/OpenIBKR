# OpenIBKR

OpenIBKR is a local-first, read-only IBKR dashboard for macOS. It keeps daily
P&L and watchlist quotes visible in a compact floating panel without adding any
trading capability.

> [!IMPORTANT]
> OpenIBKR is an independent project and is not affiliated with or endorsed by
> Interactive Brokers. It is currently intended for development and personal
> evaluation; no signed or notarized public binary is available yet.

## Demo

![OpenIBKR floating dashboard demo](https://github.com/Jiongoh/OpenIBKR/releases/download/demo-assets/openibkr-demo.gif)

The preview plays automatically and shows the OpenIBKR floating dashboard
expanding, collapsing and switching between watchlist symbols. The sanitized
demo is hosted as a GitHub Release asset and is not included in source checkouts.

## What it does

- Shows daily P&L, daily percentage change, unrealized P&L and realized P&L.
- Expands the P&L card on hover while keeping its top-left position stable.
- Displays a collapsible watchlist with price, absolute change and percentage
  change.
- Uses Alpaca for all-session prices and compact 24-hour trend lines.
- Uses compact inactive rows and expands individual quotes on hover.
- Adds and removes US stock symbols without restarting the app.
- Reports invalid or ambiguous symbols instead of creating zero-price rows.
- Distinguishes live, delayed, frozen and unavailable market data.
- Resizes the floating `NSPanel` to the currently visible modules, so invisible
  window space does not block other apps.
- Owns and restarts its bundled local Helper process and can launch at login.

The interface is built with SwiftUI and AppKit for Apple Silicon Macs. A bundled
Python Helper reads portfolio data from IB Gateway and market prices from Alpaca.

## Read-only safety model

OpenIBKR does **not** implement trading.

- The official IBKR wire client uses a fail-closed outgoing-message allowlist.
- Order placement, cancellation, global cancellation, option exercise and order
  queries are blocked at both method and wire layers. The sole execution-history
  request is read-only and is used only to reconstruct today's surviving cost slots.
- OpenIBKR and the Helper connect only through literal `127.0.0.1` endpoints.
- The Helper API uses a random local port and a one-time token that remains only
  in process memory.
- The full account ID, IBKR credentials and 2FA material are never persisted.
- Alpaca Paper API credentials are stored only in the user's macOS
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
- Alpaca market-data access for watchlist prices

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

The build script prints the installed `OpenIBKR.app` path. The local build is
signed with the configured Apple Development identity and embeds no provisioning
profile. Public distribution still requires Developer ID signing and Apple
notarization as described in the [release guide](docs/RELEASE.md).

OpenIBKR defaults to the read-only Gateway adapter on port `4003`. Its Settings
window also provides a deterministic Fake data source for UI development.

## Alpaca market data

IB Gateway is used only for account, positions, costs, and P&L. OpenIBKR uses
Alpaca for every watchlist price and chart throughout the day:

1. Open the OpenIBKR menu-bar item and choose **Settings…**.
2. Under **Alpaca Market Data**, enter the Paper API Key ID and Secret
   Key, then choose **Save & Connect**.
3. Confirm that the status reads **Alpaca · Active**.

Never put API keys in project files, terminal commands, screenshots, issues or
Git commits. OpenIBKR stores them as device-local Keychain items and restores
the market-data connection when its local Helper restarts. During the U.S.
overnight session, the displayed price is an indicative bid/ask midpoint and
may differ from an executable broker quote.

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

Automated tests use Fake data and do not require or access a live IBKR account.

## Market-data behavior

Alpaca is the exclusive watchlist-price source. OpenIBKR uses the Alpaca
overnight snapshot and BOATS bars from 20:00–04:00 ET. If an overnight quote is
missing or belongs to an older session, that symbol independently falls back to
Alpaca delayed SIP, then IEX. At other times delayed SIP is preferred, with IEX
as a final fallback. It never falls back to an IB Gateway quote. Historical bars
may trail the current snapshot; OpenIBKR merges the newest Alpaca price into the
line and continues showing current prices if history is unavailable.

Normal trend points and minute P&L samples are retained for 24 hours. When a
symbol falls back to delayed SIP or IEX and the 24-hour bar window is empty,
OpenIBKR expands the search to 7 days and then 31 days, selects the latest actual
trading day, and preserves that session for the fallback chart. A wall-clock
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
        | allowlisted portfolio-only TWS API   | allowlisted HTTPS GET only
        | on 127.0.0.1:4003                    | (all watchlist prices)
        v                                      v
IB Gateway (Read-Only API enabled)     data.alpaca.markets
```

The Helper persists the watchlist and public latest snapshot in a local SQLite
database under the user's Application Support directory. Credentials, complete
account identifiers and session tokens are excluded from that database.

## Current limitations

- No signed or notarized public binary is currently distributed.
- Market-data availability depends on the user's Alpaca entitlements.
- Physical sleep/wake and IB Gateway restart behavior should be verified on the
  target Mac before relying on the dashboard for extended unattended use.

## Documentation

- [IBKR setup](docs/IBKR_SETUP.md)
- [Release process](docs/RELEASE.md)
- [Local Helper protocol](protocol/README.md)

## Disclaimer

OpenIBKR is informational software, not investment advice. Use it at your own
risk and verify all displayed information in an official IBKR application
before making financial decisions.
