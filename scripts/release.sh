#!/bin/zsh
# Builds a signed, notarized Timber.dmg in dist/.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX [NOTARY_ISSUER=…] \
#   scripts/release.sh
#
# Without NOTARY_* it still builds and signs, but skips notarization.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(grep -m1 MARKETING_VERSION project.yml | sed -E 's/.*"(.*)".*/\1/')
SIGN_IDENTITY=${SIGN_IDENTITY:-"Developer ID Application"}
DMG="dist/Timber-$VERSION.dmg"
echo "▸ Timber $VERSION"

xcodegen generate >/dev/null
xcodebuild -project Timber.xcodeproj -scheme Timber -configuration Release -derivedDataPath build/release \
  clean build CODE_SIGN_IDENTITY="$SIGN_IDENTITY" -quiet
APP=build/release/Build/Products/Release/Timber.app

echo "▸ Verifying signatures"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -dv "$APP/Contents/Helpers/timber-mcp" 2>&1 | grep -E "^(Authority=Developer|flags)" || true

echo "▸ Packing $DMG"
mkdir -p dist; rm -f "$DMG"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"
create-dmg --volname "Timber" --background scripts/dmg-background.tiff --window-size 560 380 \
  --icon-size 112 --icon "Timber.app" 150 190 --hide-extension "Timber.app" --app-drop-link 410 190 \
  --no-internet-enable "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" ]]; then
  echo "▸ Notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" ${NOTARY_ISSUER:+--issuer "$NOTARY_ISSUER"} --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
else
  echo "▸ Skipping notarization (set NOTARY_KEY and NOTARY_KEY_ID)"
fi
shasum -a 256 "$DMG"
echo "✓ $DMG"
