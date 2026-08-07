#!/bin/sh
set -eu

DMG_PATH=${1:?usage: notarize-dmg.sh /absolute/path/OpenIBKR.dmg}
NOTARY_PROFILE=${OPENIBKR_NOTARY_PROFILE:?set OPENIBKR_NOTARY_PROFILE to a notarytool Keychain profile}

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
