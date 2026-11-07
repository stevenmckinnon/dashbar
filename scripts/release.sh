#!/bin/zsh
# Builds a signed, notarised Dashbar DMG for distribution.
#
#   scripts/release.sh 1.0.0            full release: sign, build the DMG, notarise, staple
#                                       (needs release-notes/1.0.0.md: Markdown shown in Sparkle's update dialog)
#   scripts/release.sh 1.0.0 --dry-run  everything except notarisation (works with any signing identity)
#
# One-time setup, needs a paid Apple Developer membership:
#   1. Create a "Developer ID Application" certificate (Xcode → Settings → Accounts → Manage Certificates).
#   2. Updates use a Sparkle signing key kept in your login Keychain (made with Sparkle's generate_keys; the
#      public half is in Resources/sparkle-public-key.txt). Back it up with generate_keys -x; without it,
#      installed copies can never accept an update.
#   3. Create an app-specific password at account.apple.com, then store a notary profile:
#        xcrun notarytool store-credentials dashbar-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (use another profile name with NOTARY_PROFILE=name).
#   4. The installer window is built with dmgbuild: pip3 install dmgbuild. Its layout is in packaging/dmg/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ -n "$VERSION" && "$VERSION" != --* ]] || { echo "Usage: scripts/release.sh <version> [--dry-run]"; exit 64; }
DRY_RUN=0; [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
PROFILE="${NOTARY_PROFILE:-dashbar-notary}"

# Release notes: one Markdown file per version. Sparkle shows it in the update dialog, and the same file
# goes to `gh release create --notes-file`, so they are written once. Checked first so a forgotten file
# doesn't cost a notarisation round trip.
NOTES="release-notes/$VERSION.md"
if (( ! DRY_RUN )) && [[ ! -s "$NOTES" ]]; then
  echo "Write the release notes in $NOTES first (shown in Sparkle's update dialog and on the GitHub release)." >&2
  exit 64
fi

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
scripts/make-dmg.sh "$APP" "$DMG"   # the styled installer window (needs dmgbuild)
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "Built $DMG"

if (( DRY_RUN )); then
  echo "Dry run: skipped notarisation and stapling."
  exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "SHA-256: $SHA"

# The GitHub release body: the notes, then how to install and the checksum (the cask needs it too).
GITHUB_NOTES="build/github-release-$VERSION.md"
{
  echo "**What's new**"
  cat "$NOTES"
  printf '\n**Install:** open the DMG and drag Dashbar to Applications. Signed with a Developer ID and notarised by Apple. Requires macOS 14 or later.\n'
  printf '\nSHA-256: `%s`\n' "$SHA"
} > "$GITHUB_NOTES"

# Update feed: Sparkle signs the finished DMG with the key in the Keychain and adds an entry to appcast.xml.
# Run after stapling, since stapling changes the file. Commit appcast.xml once the GitHub release exists.
GENERATE_APPCAST=$(find .build -path "*Sparkle/bin/generate_appcast" -type f | head -1)
[[ -n "$GENERATE_APPCAST" ]] || { echo "generate_appcast not found; run swift build first" >&2; exit 1; }
FEED_STAGE=$(mktemp -d)
cp "$DMG" "$FEED_STAGE/"
cp "$NOTES" "$FEED_STAGE/Dashbar-$VERSION.md"   # generate_appcast matches notes to the archive by file name
[[ -f appcast.xml ]] && cp appcast.xml "$FEED_STAGE/"
"$GENERATE_APPCAST" --embed-release-notes --download-url-prefix "https://github.com/stevenmckinnon/dashbar/releases/download/v$VERSION/" "$FEED_STAGE"
cp "$FEED_STAGE/appcast.xml" appcast.xml
rm -rf "$FEED_STAGE"
echo "Updated appcast.xml"
echo "Ready to upload: $DMG (gh release create v$VERSION $DMG --title \"Dashbar $VERSION\" --notes-file $GITHUB_NOTES)"
