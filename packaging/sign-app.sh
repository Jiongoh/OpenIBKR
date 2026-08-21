#!/bin/sh
set -eu

APP_PATH=${1:?usage: sign-app.sh /absolute/path/OpenIBKR.app}
SIGNING_IDENTITY=${OPENIBKR_SIGNING_IDENTITY:-OpenIBKR Local}
HELPER_PATH="$APP_PATH/Contents/Helpers/openibkr-helper"

if [ "$SIGNING_IDENTITY" = "OpenIBKR Local" ]; then
  IDENTITY_SHA1=$(
    security find-identity -v -p codesigning \
      | awk '/"OpenIBKR Local"/ { print tolower($2); exit }'
  )
  if [ -z "$IDENTITY_SHA1" ]; then
    echo "OpenIBKR Local is not a valid code-signing identity in the login Keychain." >&2
    exit 1
  fi
fi

# The local self-signed identity is intentionally used without a notarization
# timestamp. Set OPENIBKR_SIGNING_TIMESTAMP=1 when using a timestamp-capable
# Developer ID identity for a distributable build.
#
# PyInstaller's one-file helper extracts its embedded Python.framework at
# launch. A helper signed with the hardened runtime asks macOS to enforce
# library validation against that extracted framework. That fails for the
# local self-signed identity because it has no Team ID. The helper is a child
# process, so it does not need the app's hardened runtime; keep the runtime on
# the native app and deliberately omit it from the helper.
TIMESTAMP_FLAG=
if [ "${OPENIBKR_SIGNING_TIMESTAMP:-0}" = 1 ]; then
  TIMESTAMP_FLAG=--timestamp
fi

# Sign nested code first, without hardened runtime, so the bundled Python
# runtime can load when the local OpenIBKR certificate is used.
codesign --force $TIMESTAMP_FLAG --sign "$SIGNING_IDENTITY" "$HELPER_PATH"
# The native app itself remains hardened and is signed last so its resource
# seal includes the already-signed helper.
codesign --force $TIMESTAMP_FLAG --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [ "$SIGNING_IDENTITY" = "OpenIBKR Local" ]; then
  SIGNED_REQUIREMENT=$(codesign -d -r- "$APP_PATH" 2>&1)
  case "$SIGNED_REQUIREMENT" in
    *"certificate leaf = H\"$IDENTITY_SHA1\""*) ;;
    *)
      echo "Signed app does not use the persistent OpenIBKR Local certificate requirement." >&2
      exit 1
      ;;
  esac
fi
