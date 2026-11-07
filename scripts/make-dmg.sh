#!/bin/zsh
# Builds the styled installer disk image: scripts/make-dmg.sh <path to Dashbar.app> <output.dmg>
# Needs dmgbuild (pip3 install dmgbuild). The layout lives in packaging/dmg/settings.py.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-}"; OUT="${2:-}"
[[ -d "$APP" && -n "$OUT" ]] || { echo "Usage: scripts/make-dmg.sh <Dashbar.app> <output.dmg>" >&2; exit 64; }
python3 -c "import dmgbuild" 2>/dev/null || { echo "dmgbuild is missing. Install it with: pip3 install dmgbuild" >&2; exit 1; }

rm -f "$OUT"
python3 -m dmgbuild -s packaging/dmg/settings.py -D app="$APP" -D root="$PWD" "Dashbar" "$OUT"
