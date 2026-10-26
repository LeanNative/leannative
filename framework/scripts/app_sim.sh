#!/bin/bash
# Build / run helper for an app's GENERATED native iOS app on the iPhone 17 simulator.
# Every path is quoted: the project root may contain spaces.
#
# Usage: framework/scripts/app_sim.sh <ios dir> <scheme> <bundle id> [generate|build|install|launch|relaunch|screenshot <name>|test|all]
#   <ios dir> holds the app's xcodegen project.yml (e.g. examples/todo/ios); all = generate → build →
#   install → launch → screenshot (default). UDID overrides the simulator.
set -euo pipefail

UDID="${UDID:-5D294A04-6A7E-42E7-BCA2-8FFCD7E5A685}"   # iPhone 17 (iOS 26.4); never use "booted"
if [ $# -lt 3 ]; then
  echo "usage: $0 <ios dir> <scheme> <bundle id> [generate|build|install|launch|relaunch|screenshot <name>|test|all]" >&2
  exit 2
fi
IOS_DIR="$(cd "$1" && pwd)"
SCHEME="$2"
BUNDLE_ID="$3"
shift 3
PROJECT="$IOS_DIR/$SCHEME.xcodeproj"
DERIVED="$IOS_DIR/build"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"
SHOTS="$DERIVED/shots"
DEST="platform=iOS Simulator,id=$UDID"

generate() {
  (cd "$IOS_DIR" && /opt/homebrew/bin/xcodegen generate)
}

build() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
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
  xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
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
  *) echo "usage: $0 <ios dir> <scheme> <bundle id> [generate|build|install|launch|relaunch|screenshot <name>|test|all]" >&2; exit 2 ;;
esac
