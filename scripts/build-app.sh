#!/bin/zsh
# Builds dist/EdgeCompanion.app (release) and signs it.
#   scripts/build-app.sh            build + sign
#   scripts/build-app.sh --install  also copy to /Applications (or ~/Applications) and relaunch
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="EdgeCompanion"
BUNDLE_ID="${BUNDLE_ID:-pro.seol.EdgeCompanion}"
VERSION="0.1.0"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# Signing identity: $SIGN_ID, else the name in .signing-identity (gitignored, per machine),
# else the default created by scripts/make-cert.sh.
SIGN_ID="${SIGN_ID:-$(cat .signing-identity 2>/dev/null || echo "EdgeCompanion Local Signing")}"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Lets other apps' names resolve in the user's language (notification banners name their app). -->
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The calls-and-sound card finds the Sonos speaker over Bonjour and sets its volume on the local network. -->
  <key>NSLocalNetworkUsageDescription</key><string>Finds your Sonos speaker on the local network to show and change its volume on the Edge.</string>
  <key>NSBonjourServices</key><array><string>_sonos._tcp</string></array>
  <key>NSAppleEventsUsageDescription</key><string>Shows what Apple Music is playing on the Edge, with its artwork and playback controls.</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial companion app for the Corsair XENEON EDGE. MIT License.</string>
</dict>
</plist>
EOF

if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --options runtime --timestamp=none --entitlements Resources/EdgeCompanion.entitlements --sign "$SIGN_ID" "$APP"
  echo "Signed with '$SIGN_ID'."
else
  codesign --force --entitlements Resources/EdgeCompanion.entitlements --sign - "$APP"
  echo "Ad-hoc signed (run scripts/make-cert.sh once so permissions survive rebuilds)."
fi
codesign --verify --strict "$APP" && echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # /Applications when this account may write there (admins can, without sudo), else ~/Applications.
  # Local Network privacy looks the app up as whichever user macOS counts as the console user; with
  # another account logged in at the same time, that user may be unable to read this one's home
  # folder, and the app then never prompts nor appears under Privacy & Security → Local Network.
  if [[ -w /Applications ]]; then DIR=/Applications; else DIR="$HOME/Applications"; fi
  DEST="$DIR/$APP_NAME.app"
  mkdir -p "$DIR"
  pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  # One installed copy only, so LaunchServices and the privacy settings find this one.
  if [[ "$DIR" == /Applications && -d "$HOME/Applications/$APP_NAME.app" ]]; then
    rm -rf "$HOME/Applications/$APP_NAME.app"
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
