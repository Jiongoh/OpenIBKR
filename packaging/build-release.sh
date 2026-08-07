#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DERIVED_DATA=${OPENIBKR_DERIVED_DATA:-/tmp/OpenIBKRReleaseDerivedData}

"$PROJECT_ROOT/packaging/build-helper.sh"
xcodebuild \
  -project "$PROJECT_ROOT/app/OpenIBKR.xcodeproj" \
  -scheme OpenIBKR \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "$DERIVED_DATA/Build/Products/Release/OpenIBKR.app"
