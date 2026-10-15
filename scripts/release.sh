#!/bin/bash
# Distributable build: build/release/Mailmule-<version>.dmg, signed with Developer ID, hardened runtime,
# notarized by Apple and stapled, so it opens on any Mac without warnings.
#
#   ./scripts/release.sh 0.2.0          release (the version is written to project.yml)
#   ./scripts/release.sh --dev          trial without Developer ID: hardened runtime + DMG, not notarized
#
# Once before the first release (paid Apple Developer Program):
#   1. Xcode → Settings → Accounts → Manage Certificates → + → "Developer ID Application"
#   2. An app-specific password from appleid.apple.com, stored for notarization:
#      xcrun notarytool store-credentials mailmule-notary --apple-id <apple id> --team-id <team> --password <password>
# The Apple team comes from MAILMULE_TEAM or scripts/team.local.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Apple team for signing: MAILMULE_TEAM, or the ID saved in scripts/team.local (not in git).
MAILMULE_TEAM="${MAILMULE_TEAM:-$(cat "$ROOT/scripts/team.local" 2>/dev/null || true)}"

DEV=0
if [[ "${1:-}" == "--dev" ]]; then DEV=1; shift; fi
VERSION="${1:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
TEAM="$MAILMULE_TEAM"
[[ -n "$TEAM" ]] || { echo "Set your Apple team: echo <team id> > scripts/team.local"; exit 1; }
PROFILE="mailmule-notary"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/xcode-release"

if [[ $DEV == 0 ]]; then
  IDENTITY="Developer ID Application"
  if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "No \"Developer ID Application\" certificate (see the top of this script)."
    echo "To try without it: ./scripts/release.sh --dev"
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarization credentials (profile $PROFILE, see the top of this script)."
    exit 1
  fi
  if [[ -n "${1:-}" ]]; then
    sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
  fi
else
  IDENTITY="Apple Development"
fi

echo "Mailmule $VERSION ($BUILD_NUMBER), signing: $IDENTITY"
xcodegen generate -q
xcodebuild -project Mailmule.xcodeproj -scheme Mailmule -configuration Release \
  -derivedDataPath "$DERIVED" -skipMacroValidation -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" PROVISIONING_PROFILE_SPECIFIER="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

APP="$DERIVED/Build/Products/Release/Mailmule.app"
# Only the installed copy should handle mailmule:// and mailto: links.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "personal-information.calendars" || { echo "Entitlements missing"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT/dmg"
cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
DMG="$OUT/Mailmule-$VERSION.dmg"
hdiutil create -volname "Mailmule $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO -quiet "$DMG"
rm -rf "$OUT/dmg"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $DEV == 1 ]]; then
  echo "Done (not notarized, opens only on this Mac): $DMG"
  exit 0
fi

echo "Notarizing (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Done: $DMG"
