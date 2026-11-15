#!/bin/bash
# Renders the app states the video uses, from Dashbar's invented demo data, into public/shots.
# Needs a local build first: ./build.sh from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="../build/Dashbar Local.app/Contents/MacOS/Dashbar Local"
[ -x "$BIN" ] || { echo "No local build. Run ./build.sh in the repo root first." >&2; exit 1; }
OUT=public/shots
mkdir -p "$OUT"
# The panel and the island at 4x, through the offline (vector) renderer, so they stay sharp when scaled up.
# It can't draw native controls (the search field shows a placeholder), so the video crops above the bottom bar.
export DASHBAR_SNAPSHOT_SCALE=4
"$BIN" --snapshot "$OUT/overview.png" --demo --dark
DASHBAR_TAB=servers "$BIN" --snapshot "$OUT/servers.png" --demo --dark
DASHBAR_TAB=cleanup "$BIN" --snapshot "$OUT/cleanup.png" --demo --dark
DASHBAR_DEMO_PERMISSION=1 "$BIN" --snapshot "$OUT/island-perm.png" --demo --island permission --dark
unset DASHBAR_SNAPSHOT_SCALE
"$BIN" --snapshot "$OUT/menubar.png" --demo --menubar all --dark
# The window is captured on screen: the offline --app render garbles the sidebar's SF Symbols (vibrancy).
LOG=$(mktemp)
(DASHBAR_APP_PAGE=history "$BIN" --snapshot x --demo --app --dark --onscreen > "$LOG" 2>&1 &)
for _ in $(seq 1 60); do N=$(awk '/^window/{print $2}' "$LOG"); [ -n "$N" ] && break; sleep 0.25; done
[ -n "${N:-}" ] || { echo "The window did not appear." >&2; exit 1; }
sleep 2
screencapture -o -l "$N" "$OUT/history.png"
sleep 7   # the window closes itself after 8 s
rm -f "$LOG"
cp ../docs/images/icon.png "$OUT/icon.png"
# A snapshot run writes the panel tab into the app's preferences; put it back.
defaults write fun.dashbar.app.local panelTab overview
echo "Shots in $OUT"
