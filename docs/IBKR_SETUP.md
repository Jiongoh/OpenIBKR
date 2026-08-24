# Local IBKR setup (no credentials)

## Expected components

- IB Gateway 10.49 for macOS/Apple Silicon
- Official TWS API 10.49.02 at `$HOME/IBJts` or another local path outside this
  repository
- Python 3.13.14 project environment at `.venv`
- `ibapi` 10.49.2 and Protobuf 5.29.5

The TWS API SDK is subject to IBKR's separate non-commercial/internal-use
license and must not be copied into or redistributed with this repository.

## Recommended Gateway profile

Use a dedicated IBKR username when the account configuration supports one.
Whether the deployment uses Paper or Live Gateway, API access must remain
read-only. No username, password, account identifier or 2FA material may be
stored in this repository.

- Login API type: IB API (not FIX CTCI)
- Socket port: `4003`
- Read-Only API: enabled
- Allow connections from localhost only: enabled
- Trusted IPs: `127.0.0.1` only
- OpenIBKR host: literal `127.0.0.1`
- OpenIBKR client ID: nonzero; client ID `0` is forbidden

Port `4003` is the example deployment value. A deployment may choose another
unused local port, provided Gateway and OpenIBKR use the same value.

## Operational rules

1. Log into IB Gateway manually and complete IB Key/2FA only in the official UI.
2. Confirm the three network/read-only settings above before starting OpenIBKR.
3. Keep the Gateway Read-Only API checkbox enabled at all times.
4. Never add account credentials to environment files, source code, logs or the
   macOS application bundle.
5. Treat market data entitlements as deployment-specific. Never assume that
   real-time data is available; display the market-data type returned by IBKR.
6. Do not enable regulatory snapshots; OpenIBKR hardcodes
   `regulatorySnapshot=false`.

## Safe verification

Run automated protection tests before every live integration check:

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Then launch OpenIBKR with Gateway already running and confirm that Settings
shows a connected, read-only IBKR source. Verify that account identifiers stay
masked and that unavailable or delayed market data is labelled accurately.

For reconnect verification, manually exit and reopen IB Gateway on the same
port. OpenIBKR should enter a recoverable disconnected state, reconnect, and
restore account/P&L and market-data subscriptions without restarting Gateway
itself.
