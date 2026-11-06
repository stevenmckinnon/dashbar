#!/bin/zsh
# Builds a signed, notarised Dashbar DMG for distribution.
#
#   scripts/release.sh 1.0.0            full release: sign, build the DMG, notarise, staple
#   scripts/release.sh 1.0.0 --dry-run  everything except notarisation (works with any signing identity)
#
# One-time setup, needs a paid Apple Developer membership:
#   1. Create a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates).
#   2. Create an app-specific password at account.apple.com, then store a notary profile:
#        xcrun notarytool store-credentials dashbar-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (use another profile name with NOTARY_PROFILE=name).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ -n "$VERSION" && "$VERSION" != --* ]] || { echo "Usage: scripts/release.sh <version> [--dry-run]"; exit 64; }
DRY_RUN=0; [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
PROFILE="${NOTARY_PROFILE:-dashbar-notary}"

IDENTITY="${DASHBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)}"
if [[ -z "$IDENTITY" ]]; then
  if (( DRY_RUN )); then
    IDENTITY=$(security find-identity -v -p codesigning | grep '"' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
    echo "No Developer ID Application certificate; dry run signs with: ${IDENTITY:-ad-hoc}"
  else
    echo "No 'Developer ID Application' certificate found. See the setup notes at the top of this script." >&2
    exit 1
  fi
fi

BUILD_NUMBER="${DASHBAR_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DASHBAR_VERSION="$VERSION" DASHBAR_BUILD="$BUILD_NUMBER" DASHBAR_UNIVERSAL=1 DASHBAR_HARDENED=1 \
  DASHBAR_SIGN_IDENTITY="${IDENTITY:--}" ./build.sh

APP=build/Dashbar.app
codesign --verify --deep --strict "$APP"
DETAILS=$(codesign -dv "$APP" 2>&1)
[[ "$DETAILS" == *"(runtime)"* ]] || { echo "Hardened runtime is missing" >&2; exit 1; }
lipo -archs "$APP/Contents/MacOS/Dashbar"

DMG="build/Dashbar-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Dashbar" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "Built $DMG"

if (( DRY_RUN )); then
  echo "Dry run: skipped notarisation and stapling."
  exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG"
echo "Ready to upload: $DMG"
