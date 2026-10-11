#!/bin/bash
# Builds Winnow.app from this folder.
# Needs an Apple-silicon Mac on macOS 26 with Xcode 26 (or its command line tools).
# Optional: SIGN_ID="Developer ID Application: Your Name (TEAMID)" signs it for sharing
# (hardened runtime). Without it the app is signed ad-hoc, which is fine on your own Mac.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="Winnow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clips2 "$APP/Contents/MacOS/Clips2"
sed "s/BUILDNUM/$(date +%Y%m%d%H%M)/" Resources/Info.plist > "$APP/Contents/Info.plist"
# icon + green accent colour (asset catalog needs Xcode's actool; plain .icns otherwise)
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist /tmp/winnow-assets.plist > /dev/null 2>&1 || true
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || iconutil -c icns Resources/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
else
  codesign --force -s - "$APP"
fi
echo "Built $APP"
