#!/bin/bash
# Build / run helper for the ElmLean iOS app on the iPhone 17 simulator.
# Every path is quoted: the project root contains spaces.
#
# Usage: framework/viewer-ios/scripts/sim.sh [generate|build|install|launch|relaunch|screenshot <name>|test|all]
#   all = generate → build → install → launch → screenshot (default)
set -euo pipefail

UDID="${UDID:-5D294A04-6A7E-42E7-BCA2-8FFCD7E5A685}"   # iPhone 17 (iOS 26.4); never use "booted"
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$IOS_DIR/ElmLeanApp.xcodeproj"
DERIVED="$IOS_DIR/build"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/ElmLeanApp.app"
BUNDLE_ID="art.fralex.elmlean"
SHOTS="$DERIVED/shots"
DEST="platform=iOS Simulator,id=$UDID"

generate() {
  (cd "$IOS_DIR" && /opt/homebrew/bin/xcodegen generate)
}

build() {
  xcodebuild -project "$PROJECT" -scheme ElmLeanApp -configuration Debug \
    -destination "$DEST" -derivedDataPath "$DERIVED" build 2>&1 | tail -5
}

install() {
  xcrun simctl install "$UDID" "$APP"
}

launch() {
  xcrun simctl launch "$UDID" "$BUNDLE_ID"
}

relaunch() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  sleep 1
  launch
}

screenshot() {
  local name="${1:-shot}"
  mkdir -p "$SHOTS"
  xcrun simctl io "$UDID" screenshot "$SHOTS/$name.png" >/dev/null
  echo "$SHOTS/$name.png"
}

run_tests() {
  xcodebuild test -project "$PROJECT" -scheme ElmLeanApp \
    -destination "$DEST" -derivedDataPath "$DERIVED" 2>&1 | tail -15
}

cmd="${1:-all}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  generate)   generate ;;
  build)      build ;;
  install)    install ;;
  launch)     launch ;;
  relaunch)   relaunch ;;
  screenshot) screenshot "${1:-shot}" ;;
  test)       run_tests ;;
  all)        generate; build; install; launch; sleep 3; screenshot "01-initial" ;;
  *) echo "usage: $0 [generate|build|install|launch|relaunch|screenshot <name>|test|all]" >&2; exit 2 ;;
esac
