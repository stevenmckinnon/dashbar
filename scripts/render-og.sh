#!/bin/zsh
# Regenerates the share image, docs/images/og.png, from scripts/og/og.html with headless Chrome.
# Run it after the panel's look changes and docs/images/overview-dark.png has been re-rendered.
# Needs `npm install` in site/ (for the font) and Google Chrome.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }
[[ -f site/node_modules/@fontsource-variable/instrument-sans/files/instrument-sans-latin-wght-normal.woff2 ]] \
  || { echo "Run npm install in site/ first (the font lives in node_modules)." >&2; exit 1; }
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --virtual-time-budget=5000 \
  --window-size=1200,630 --screenshot=docs/images/og.png "file://$PWD/scripts/og/og.html" >/dev/null 2>&1
sips -g pixelWidth -g pixelHeight docs/images/og.png | awk '/pixel/{printf $2" "}'; echo
