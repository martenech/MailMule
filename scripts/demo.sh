#!/bin/bash
# Runs Mailmule with made-up accounts and mail, for screenshots. Nothing of the real setup is used:
# the copy has its own bundle identifier (own settings) and its own mail folder in a temporary
# directory, and it never connects to a server.
#
#   ./scripts/demo.sh [screen] [defaults...]   start with fresh demo data
#       screen: home (default), inbox, thread, compose, search, settings
#       defaults, e.g. a theme: -theme.preset everforest -theme.appearance dark
#   ./scripts/demo.sh --stop                   quit it and remove the copy
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_DIR="${TMPDIR:-/tmp}/mailmule-demo"
APP="$DEMO_DIR/Mailmule Demo.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

stop() {
  pkill -f "Mailmule Demo.app/Contents/MacOS/Mailmule" 2>/dev/null || true
  sleep 1
  [ -d "$APP" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
  defaults delete app.mailmule.Mailmule.demo 2>/dev/null || true
  rm -rf "$DEMO_DIR" ~/Library/WebKit/app.mailmule.Mailmule.demo ~/Library/Caches/app.mailmule.Mailmule.demo \
    ~/Library/HTTPStorages/app.mailmule.Mailmule.demo "${TMPDIR:-/tmp}"/app.mailmule.Mailmule.demo*
}

if [[ "${1:-}" == "--stop" ]]; then stop; exit 0; fi
SCREEN="home"
if [[ $# -gt 0 && "$1" != -* ]]; then SCREEN="$1"; shift; fi

[ -d "$ROOT/build/Mailmule.app" ] || { echo "Build first: ./scripts/build-app.sh"; exit 1; }
stop
mkdir -p "$DEMO_DIR/Mail"
cp -R "$ROOT/build/Mailmule.app" "$APP"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.mailmule.Mailmule.demo" "$PLIST"
# No mailto:/mailmule: handling and no Services for the copy.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :NSServices" "$PLIST" 2>/dev/null || true
IDENTITY="$(codesign -dvv "$ROOT/build/Mailmule.app" 2>&1 | awk -F= '/^Authority=/ && !found {print $2; found=1}')"
codesign --force --deep --options runtime --sign "${IDENTITY:--}" --entitlements "$ROOT/App/Mailmule.entitlements" "$APP" 2>/dev/null
"$LSREGISTER" -u "$APP" 2>/dev/null || true

# Through Launch Services: WebKit's helper processes do not start for a binary run directly.
open -n -g "$APP" --args -MailmuleDemo YES -MailmuleDemoVault "$DEMO_DIR/Mail" -MailmuleDemoScreen "$SCREEN" \
  -ApplePersistenceIgnoreState YES "$@"
echo "Mailmule Demo is running (stop with: ./scripts/demo.sh --stop)"
