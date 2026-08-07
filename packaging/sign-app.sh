#!/bin/sh
set -eu

APP_PATH=${1:?usage: sign-app.sh /absolute/path/OpenIBKR.app}
SIGNING_IDENTITY=${OPENIBKR_SIGNING_IDENTITY:?set OPENIBKR_SIGNING_IDENTITY to a Developer ID Application identity}
HELPER_PATH="$APP_PATH/Contents/Helpers/openibkr-helper"

codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$HELPER_PATH"
codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
