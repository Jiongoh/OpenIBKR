#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DERIVED_DATA=${OPENIBKR_DERIVED_DATA:-/tmp/OpenIBKRReleaseDerivedData}
INSTALL_PATH=/Applications/OpenIBKR.app
# Persistent identity created specifically for OpenIBKR. Override this only
# when intentionally making a different local or Developer ID build.
OPENIBKR_SIGNING_IDENTITY=${OPENIBKR_SIGNING_IDENTITY:-OpenIBKR Local}
export OPENIBKR_SIGNING_IDENTITY

PREVIOUS_REQUIREMENT=
if [ -d "$INSTALL_PATH" ] && codesign --verify --deep --strict "$INSTALL_PATH" 2>/dev/null; then
  PREVIOUS_REQUIREMENT=$(
    codesign -d -r- "$INSTALL_PATH" 2>&1 \
      | awk '/^designated =>/ { print; exit }'
  )
fi

"$PROJECT_ROOT/packaging/build-helper.sh"
xcodebuild \
  -project "$PROJECT_ROOT/app/OpenIBKR.xcodeproj" \
  -scheme OpenIBKR \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/OpenIBKR.app"
"$PROJECT_ROOT/packaging/sign-app.sh" "$APP_PATH"
NEW_REQUIREMENT=$(
  codesign -d -r- "$APP_PATH" 2>&1 \
    | awk '/^designated =>/ { print; exit }'
)

# Keychain application ACLs follow the designated requirement. Refuse an
# accidental identity change, which would make macOS ask for access again.
if [ -n "$PREVIOUS_REQUIREMENT" ] \
  && [ "$PREVIOUS_REQUIREMENT" != "$NEW_REQUIREMENT" ] \
  && [ "${OPENIBKR_ALLOW_IDENTITY_CHANGE:-0}" != 1 ]; then
  echo "Refusing to install a Release whose designated requirement changed." >&2
  echo "Set OPENIBKR_ALLOW_IDENTITY_CHANGE=1 only for an intentional certificate migration." >&2
  exit 1
fi

/usr/bin/osascript -e 'tell application id "com.openibkr.OpenIBKR" to quit' 2>/dev/null || true
QUIT_ATTEMPTS=0
while pgrep -x OpenIBKR >/dev/null 2>&1 && [ "$QUIT_ATTEMPTS" -lt 50 ]; do
  sleep 0.1
  QUIT_ATTEMPTS=$((QUIT_ATTEMPTS + 1))
done
if pgrep -x OpenIBKR >/dev/null 2>&1; then
  echo "OpenIBKR did not quit; the existing installation was left untouched." >&2
  exit 1
fi
if [ -e "$INSTALL_PATH" ]; then
  rm -rf -- "$INSTALL_PATH"
fi
ditto "$APP_PATH" "$INSTALL_PATH"
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"

echo "$INSTALL_PATH"
