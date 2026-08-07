# OpenIBKR release process

Stage 5 requires a valid **Developer ID Application** identity and Apple
Notarization credentials. The current machine has no valid code-signing
identity, so signing and Notarization must not be represented as complete.

## Prerequisites

1. Install the Developer ID Application certificate and private key in the
   login Keychain.
2. Confirm it appears in `security find-identity -v -p codesigning`.
3. Create a `notarytool` Keychain profile locally. Do not place Apple account
   credentials, app-specific passwords or API keys in this repository.
4. Keep IB Gateway credentials and the local SQLite database outside the build.

## Build

```sh
.venv/bin/python -m pip install -e '.[packaging]'
packaging/build-release.sh
```

The command prints the unsigned Release `.app` path. Confirm both the main App
and nested Helper are `arm64` before signing.

## Sign and verify

```sh
export OPENIBKR_SIGNING_IDENTITY='Developer ID Application: …'
packaging/sign-app.sh /tmp/OpenIBKRReleaseDerivedData/Build/Products/Release/OpenIBKR.app
```

The nested Helper is signed first. The main App is signed last with Hardened
Runtime and a secure timestamp. Do not use an ad-hoc signature for a public
release.

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
