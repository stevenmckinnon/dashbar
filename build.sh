#!/bin/zsh
# Builds the app into ./build. Usage: ./build.sh [--run] [--install]
# Release options (set by scripts/release.sh): DASHBAR_VERSION, DASHBAR_BUILD, DASHBAR_UNIVERSAL=1
# (arm64 + x86_64), DASHBAR_HARDENED=1 (hardened runtime and a secure timestamp, required to notarise).
# DASHBAR_HARDENED=1 makes the real "Dashbar.app". Anything else is a local build, "Dashbar Local.app", with its
# own bundle id, process name and settings, no updater, and "Local" markers in the UI, so it can sit in
# /Applications next to the installed release.
set -euo pipefail
cd "$(dirname "$0")"

# App icon: render the SVG with WebKit (keeps its glow and shadow filters), then build the .icns.
# Only re-renders when the SVG is newer than the icns, which is committed alongside it.
ICON_SVG=Resources/AppIcon.svg
ICON_ICNS=Resources/AppIcon.icns
if [[ ! -f "$ICON_ICNS" || "$ICON_SVG" -nt "$ICON_ICNS" ]]; then
  echo "Rendering app icon…"
  TMP=$(mktemp -d)
  swift scripts/render-svg.swift "$ICON_SVG" "$TMP/master.png" 1024
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for pt in 16 32 128 256 512; do
    sips -z $pt $pt "$TMP/master.png" --out "$ICONSET/icon_${pt}x${pt}.png" >/dev/null
    sips -z $((pt * 2)) $((pt * 2)) "$TMP/master.png" --out "$ICONSET/icon_${pt}x${pt}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
  rm -rf "$TMP"
fi

if [[ "${DASHBAR_HARDENED:-}" == "1" ]]; then LOCAL=0; else LOCAL=1; fi
if (( LOCAL )); then
  APP_NAME="Dashbar Local"
  BUNDLE_ID="fun.dashbar.app.local"
  # Like "0.4.0-3-gabc1234-dirty": the last release, commits since, and whether the tree has changes.
  VERSION="${DASHBAR_VERSION:-$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || true)}"
  VERSION="${VERSION:-0.1.0}"
  BUILD_NUMBER="${DASHBAR_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
else
  APP_NAME="Dashbar"
  BUNDLE_ID="fun.dashbar.app"
  VERSION="${DASHBAR_VERSION:-0.1.0}"
  BUILD_NUMBER="${DASHBAR_BUILD:-1}"
fi
if [[ "${DASHBAR_UNIVERSAL:-}" == "1" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
fi
swift build -c release "${ARCHS[@]}"
BINARY="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Dashbar"
APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# Sparkle (in-app updates) ships as a framework next to the binary: embed it and let the binary find it.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$(dirname "$BINARY")/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>__NAME__</string>
  <key>CFBundleDisplayName</key><string>__NAME__</string>
  <key>CFBundleIdentifier</key><string>__BUNDLE_ID__</string>
  <key>CFBundleExecutable</key><string>__NAME__</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__BUILD__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
__UPDATES__
</dict>
</plist>
PLIST
# Update feed and the public half of the signing key. Without a key file, the app builds with updates off.
# A local build has no feed (it would offer to replace itself with the release) and says it is local.
PUBLIC_KEY_FILE=Resources/sparkle-public-key.txt
if (( LOCAL )); then
  UPDATES="  <key>DashbarLocalBuild</key><true/>"
elif [[ -f "$PUBLIC_KEY_FILE" ]]; then
  UPDATES="  <key>SUFeedURL</key><string>https://raw.githubusercontent.com/stevenmckinnon/dashbar/main/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < "$PUBLIC_KEY_FILE")</string>"
else
  UPDATES=""
fi
python3 - "$APP/Contents/Info.plist" "$UPDATES" <<'PY'
import sys
path, updates = sys.argv[1], sys.argv[2]
s = open(path).read().replace("__UPDATES__", updates)
open(path, "w").write(s)
PY
sed -i '' -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  -e "s/__NAME__/$APP_NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists, so macOS recognises rebuilds as the same app
# (Keychain "Always Allow" and other permissions persist). Override with DASHBAR_SIGN_IDENTITY;
# falls back to ad-hoc signing, which macOS treats as a new app on every build.
IDENTITY="${DASHBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)".*/\1/')}"
# Nested code is signed first (inside out), then the app, so every signature covers what's inside it.
sign() {
  local flags=()
  if [[ "${DASHBAR_HARDENED:-}" == "1" ]]; then flags=(--options runtime --timestamp); else flags=(--timestamp=none); fi
  codesign --force --sign "${IDENTITY:--}" "${flags[@]}" "$@" >/dev/null
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE"/XPCServices/*.xpc; do sign --preserve-metadata=entitlements "$item"; done
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
if [[ -n "$IDENTITY" ]]; then echo "Signed with: $IDENTITY"; else echo "Signed ad-hoc (no signing identity found)"; fi
echo "Built $APP"

if [[ "${1:-}" == "--install" || "${2:-}" == "--install" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$APP_NAME.app"
  echo "Installed to $APP"
fi

if [[ "${1:-}" == "--run" || "${2:-}" == "--run" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
  open "$APP"
fi
