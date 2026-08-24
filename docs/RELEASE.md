# OpenIBKR release process

For this local-only installation, the build uses the free Apple Development
identity already present in the login Keychain. It embeds no provisioning
profile, so Personal Team's seven-day device profile lifetime does not apply.
A Developer ID identity and notarization are only needed for public distribution.

## Prerequisites

1. Keep a valid Apple Development identity and its private key in the login
   Keychain. Renew it with the same Personal Team when it expires so the Team
   ID remains stable.
2. Confirm `/usr/bin/codesign` can use the private key. By default the signing
   script selects the first valid Apple Development identity and requires the
   app and helper to contain the same nonempty Team ID.
3. Create a `notarytool` Keychain profile locally. Do not place Apple account
   credentials, app-specific passwords or API keys in this repository.
4. Keep IB Gateway credentials and the local SQLite database outside the build.

## Build

```sh
.venv/bin/python -m pip install -e '.[packaging]'
packaging/build-release.sh
```

The command builds and signs the Release `.app` with the persistent local
identity, then replaces `/Applications/OpenIBKR.app` directly. It does not
keep a backup unless you explicitly make one first. Confirm both the main App
and nested Helper are `arm64` before using it.

## Sign and verify

```sh
# Optional when more than one signing identity is installed:
export OPENIBKR_SIGNING_IDENTITY='Apple Development: Certificate Name (TEAM)'
# Optional additional Team ID pin:
export OPENIBKR_EXPECTED_TEAM_ID='XXXXXXXXXX'
packaging/sign-app.sh /tmp/OpenIBKRReleaseDerivedData/Build/Products/Release/OpenIBKR.app
```

The nested Helper is signed first, and the main App is signed last with the
same identity. The PyInstaller Helper is intentionally signed without Hardened
Runtime so its extracted Python framework can load; the native App remains
hardened. The local build intentionally has no notarization timestamp; set
`OPENIBKR_SIGNING_TIMESTAMP=1` only for a timestamp-capable Developer ID
identity. Do not use an ad-hoc signature for a public release.

The installer compares the new app's designated requirement with the existing
installation and refuses an accidental identity change. Set
`OPENIBKR_ALLOW_IDENTITY_CHANGE=1` only when deliberately migrating to another
certificate; that migration can require one final Keychain authorization.

OpenIBKR never queries or changes the legacy v1/v2 Alpaca items from its
background startup path. Those items retain per-build cdhash partitions that
can summon SecurityAgent even for a read. They are deliberately left untouched.
Re-enter and save the credentials once in Settings; current builds use the
isolated `com.openibkr.alpaca.marketdata.v3` service with the stable Apple
Development Team ID partition.

## Create, notarize and staple the DMG

```sh
packaging/create-dmg.sh \
  /tmp/OpenIBKRReleaseDerivedData/Build/Products/Release/OpenIBKR.app \
  /tmp/OpenIBKR.dmg

export OPENIBKR_NOTARY_PROFILE='openibkr-notary'
packaging/notarize-dmg.sh /tmp/OpenIBKR.dmg
```

## Clean-machine acceptance

- Test on an Apple Silicon account without the development Python environment.
- Confirm Gatekeeper accepts the DMG and App.
- Confirm the App starts its embedded Helper and shows a recoverable state when
  IB Gateway is not running.
- Configure Gateway Read-Only API and `127.0.0.1:4003`, then confirm masked
  account/P&L data without sending any trading request.
- Confirm App exit leaves no Helper process.
- Never include SQLite files, logs, session tokens, IBKR credentials, signing
  certificates or Notarization credentials in the release artifact.
