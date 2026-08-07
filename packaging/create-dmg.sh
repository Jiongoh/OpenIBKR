#!/bin/sh
set -eu

APP_PATH=${1:?usage: create-dmg.sh /absolute/path/OpenIBKR.app [output.dmg]}
OUTPUT_PATH=${2:-OpenIBKR.dmg}
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT INT TERM

cp -R "$APP_PATH" "$STAGING_DIR/OpenIBKR.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname OpenIBKR \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"
