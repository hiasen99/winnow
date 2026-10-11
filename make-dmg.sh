#!/bin/bash
# Packs Winnow.app into Winnow.dmg (run build.sh first, or pass the app's path).
# With SIGN_ID set the disk image is signed; with NOTARY_PROFILE set (a profile saved by
# `xcrun notarytool store-credentials`) it is also notarized and stapled.
set -e
cd "$(dirname "$0")"
APP="${1:-Winnow.app}"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Winnow.app"
ln -s /Applications "$STAGE/Applications"
rm -f Winnow.dmg
hdiutil create -volname Winnow -srcfolder "$STAGE" -format UDZO -ov Winnow.dmg > /dev/null
rm -rf "$STAGE"
[ -n "$SIGN_ID" ] && codesign --force --timestamp -s "$SIGN_ID" Winnow.dmg
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit Winnow.dmg --keychain-profile "$NOTARY_PROFILE" --wait | tee /tmp/winnow-notary.log
  grep -q "status: Accepted" /tmp/winnow-notary.log || { echo "Notarization was not accepted"; exit 1; }
  xcrun stapler staple Winnow.dmg
fi
echo "Made Winnow.dmg"
