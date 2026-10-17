#!/usr/bin/env bash
# Builds a Developer-ID-signed, notarized and stapled DMG:
#   build/release/SonosBar-<version>.dmg
#
# Needs an App Store Connect API key for notarytool:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_<id>.p8)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" "${ASC_KEY_PATH:?set ASC_KEY_PATH}"

VERSION=$(awk '/MARKETING_VERSION/ {gsub(/"/, "", $2); print $2}' project.yml)
OUT=build/release
APP="$OUT/export/SonosBar.app"
DMG="$OUT/SonosBar-$VERSION.dmg"

xcodegen generate
rm -rf "$OUT" && mkdir -p "$OUT/stage"

echo "▸ Archive"
xcodebuild archive -project SonosBar.xcodeproj -scheme SonosBar -configuration Release \
  -archivePath "$OUT/SonosBar.xcarchive" -allowProvisioningUpdates -quiet

echo "▸ Export (Developer ID)"
xcodebuild -exportArchive -archivePath "$OUT/SonosBar.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates -quiet

echo "▸ DMG"
cp -R "$APP" "$OUT/stage/"
make_dmg() {
  create-dmg --volname "SonosBar $VERSION" --window-size 540 360 --icon-size 110 \
    --icon SonosBar.app 140 160 --app-drop-link 400 160 --hide-extension SonosBar.app \
    --no-internet-enable "$DMG" "$OUT/stage" >/dev/null
}
# create-dmg's Finder layout step fails now and then and leaves its rw image mounted – clean up, retry once.
if ! make_dmg; then
  hdiutil info | awk -v img="$PWD/$OUT/rw." 'index($0, img) {f=1} f && /^\/dev\// {print $1; exit}' | xargs -r hdiutil detach -quiet || true
  rm -f "$OUT"/rw.*.dmg
  make_dmg
fi
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▸ Notarize"
xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

echo "▸ Verify"
spctl -a -t open --context context:primary-signature -v "$DMG"
spctl -a -t exec -v "$APP"
echo "✓ $DMG"
