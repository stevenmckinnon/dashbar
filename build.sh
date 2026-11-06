#!/bin/zsh
# Builds Dashbar.app into ./build. Usage: ./build.sh [--run] [--install]
# Release options (set by scripts/release.sh): DASHBAR_VERSION, DASHBAR_BUILD, DASHBAR_UNIVERSAL=1
# (arm64 + x86_64), DASHBAR_HARDENED=1 (hardened runtime and a secure timestamp, required to notarise).
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

VERSION="${DASHBAR_VERSION:-0.1.0}"
BUILD_NUMBER="${DASHBAR_BUILD:-1}"
if [[ "${DASHBAR_UNIVERSAL:-}" == "1" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
fi
swift build -c release "${ARCHS[@]}"
BINARY="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Dashbar"
APP=build/Dashbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Dashbar"
cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dashbar</string>
  <key>CFBundleDisplayName</key><string>Dashbar</string>
  <key>CFBundleIdentifier</key><string>fun.dashbar.app</string>
  <key>CFBundleExecutable</key><string>Dashbar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__BUILD__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
sed -i '' -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists, so macOS recognises rebuilds as the same app
# (Keychain "Always Allow" and other permissions persist). Override with DASHBAR_SIGN_IDENTITY;
# falls back to ad-hoc signing, which macOS treats as a new app on every build.
IDENTITY="${DASHBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)".*/\1/')}"
if [[ -n "$IDENTITY" ]]; then
  if [[ "${DASHBAR_HARDENED:-}" == "1" ]]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP" >/dev/null
  else
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
  fi
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (no signing identity found)"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" || "${2:-}" == "--install" ]]; then
  pkill -x Dashbar 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Dashbar.app
  cp -R "$APP" /Applications/
  APP=/Applications/Dashbar.app
  echo "Installed to $APP"
fi

if [[ "${1:-}" == "--run" || "${2:-}" == "--run" ]]; then
  pkill -x Dashbar 2>/dev/null && sleep 1 || true
  open "$APP"
fi
