#!/bin/bash
# Builds build/Mailmule.app with xcodebuild (MLX needs Xcode to compile its Metal shaders).
# One-time setup: `xcodebuild -downloadComponent MetalToolchain`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Mailmule.app"
PRODUCT="$ROOT/build/xcode/Build/Products/Release/Mailmule.app"

cd "$ROOT"
# Apple team for signing: MAILMULE_TEAM, or the ID saved in scripts/team.local (not in git).
MAILMULE_TEAM="${MAILMULE_TEAM:-$(cat "$ROOT/scripts/team.local" 2>/dev/null || true)}"
xcodegen generate -q
xcodebuild -project Mailmule.xcodeproj -scheme Mailmule -configuration Release \
  -derivedDataPath "$ROOT/build/xcode" -skipMacroValidation -quiet \
  ${MAILMULE_TEAM:+DEVELOPMENT_TEAM="$MAILMULE_TEAM"} build

rm -rf "$APP"
cp -R "$PRODUCT" "$APP"
# Only build/Mailmule.app may handle mailmule:// and mailto: links, not the intermediate product.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PRODUCT" 2>/dev/null || true
# Signed by Xcode with the Apple Development certificate (team in project.yml), so macOS keeps
# Keychain permissions across builds.
codesign --verify "$APP"
echo "Signed by team: $(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/ {print $2}')"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Done: $APP"
