#!/bin/zsh
# Regenerates the installer background, packaging/dmg/background.png (1x only: see render-background.swift).
set -euo pipefail
cd "$(dirname "$0")"
swift render-background.swift background.png
echo "Wrote packaging/dmg/background.png"
