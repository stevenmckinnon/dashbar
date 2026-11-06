#!/bin/zsh
# Builds Dashbar.app into ./build. Usage: ./build.sh [--run] [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Dashbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dashbar "$APP/Contents/MacOS/Dashbar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dashbar</string>
  <key>CFBundleDisplayName</key><string>Dashbar</string>
  <key>CFBundleIdentifier</key><string>fun.dashbar.app</string>
  <key>CFBundleExecutable</key><string>Dashbar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
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
