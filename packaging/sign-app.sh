#!/bin/sh
set -eu

APP_PATH=${1:?usage: sign-app.sh /absolute/path/OpenIBKR.app}
SIGNING_IDENTITY=${OPENIBKR_SIGNING_IDENTITY:-}
EXPECTED_TEAM_ID=${OPENIBKR_EXPECTED_TEAM_ID:-}
HELPER_PATH="$APP_PATH/Contents/Helpers/openibkr-helper"

IDENTITIES=$(security find-identity -v -p codesigning)
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY=$(
    printf '%s\n' "$IDENTITIES" \
      | sed -n 's/^[[:space:]]*[0-9][0-9]*) [A-F0-9]* "\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )
fi
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "No valid Apple Development signing identity was found." >&2
  echo "Set OPENIBKR_SIGNING_IDENTITY to select another code-signing identity." >&2
  exit 1
fi

IDENTITY_SHA1=$(
  printf '%s\n' "$IDENTITIES" \
    | awk -v name="$SIGNING_IDENTITY" 'index($0, "\"" name "\"") { print $2; exit }'
)
if [ -z "$IDENTITY_SHA1" ]; then
  echo "$SIGNING_IDENTITY is not a valid code-signing identity in the login Keychain." >&2
  exit 1
fi

# Local development builds intentionally omit a notarization timestamp. Set
# OPENIBKR_SIGNING_TIMESTAMP=1 only for a timestamp-capable Developer ID build.
#
# PyInstaller's one-file helper extracts its embedded Python.framework at
# launch. A helper signed with the hardened runtime asks macOS to enforce
# library validation against that extracted framework. That fails for the
# development identity when its extracted libraries do not carry matching
# signatures. The helper is a child process, so it does not need the app's
# hardened runtime; keep the runtime on the native app and omit it here.
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

SIGNED_TEAM_ID=
for SIGNED_COMPONENT in "$APP_PATH" "$HELPER_PATH"; do
  TEAM_ID=$(
    codesign -d --verbose=4 "$SIGNED_COMPONENT" 2>&1 \
      | awk -F= '/^TeamIdentifier=/ { print $2; exit }'
  )
  if [ -z "$TEAM_ID" ]; then
    echo "$SIGNED_COMPONENT does not contain a Team ID." >&2
    exit 1
  fi
  if [ -z "$SIGNED_TEAM_ID" ]; then
    SIGNED_TEAM_ID=$TEAM_ID
  elif [ "$TEAM_ID" != "$SIGNED_TEAM_ID" ]; then
    echo "$SIGNED_COMPONENT has Team ID '$TEAM_ID'; expected '$SIGNED_TEAM_ID'." >&2
    exit 1
  fi
  if [ -n "$EXPECTED_TEAM_ID" ] && [ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
    echo "$SIGNED_COMPONENT has Team ID '$TEAM_ID'; expected '$EXPECTED_TEAM_ID'." >&2
    exit 1
  fi
done
