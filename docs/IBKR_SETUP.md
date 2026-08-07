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
- Spike host: literal `127.0.0.1`
- Spike client ID: `71`; client ID `0` is forbidden

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
6. Do not enable regulatory snapshots in development; the spike hardcodes
   `regulatorySnapshot=false`.

## Safe verification

Run automated protection tests before every live integration check:

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Then validate in stages, never starting with the combined mode:

```sh
.venv/bin/openibkr-readonly-spike connection --port 4003
.venv/bin/openibkr-readonly-spike account --port 4003 --observe-seconds 5
.venv/bin/openibkr-readonly-spike market --port 4003 --market-data-mode delayed --observe-seconds 3
```

The real-time entitlement probe is optional and does not purchase a
subscription:

```sh
.venv/bin/openibkr-readonly-spike market --port 4003 --market-data-mode live
```

For the final reconnect test, start the reconnect probe, wait until it prints
`ready_for_manual_gateway_restart`, then manually exit and reopen IB Gateway on
the same port.  The probe retries with exponential backoff and verifies that
account/P&L and market-data subscriptions are restored.  The probe never
stops or starts Gateway itself.
