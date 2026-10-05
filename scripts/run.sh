#!/usr/bin/env bash
# Build then launch the Jaca .app.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
[ -d Jaca.xcodeproj ] || xcodegen generate
APP_PATH="$(xcodebuild \
  -project Jaca.xcodeproj \
  -scheme Jaca \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')"
./scripts/build.sh "$CONFIG"

# `open` on an app that's already running only brings that instance forward — it does not launch
# the binary just built, so without this a rebuild silently keeps running the old code. Quit it
# first, gracefully: Jaca reverts device proxies and adb tunnels in applicationWillTerminate, and a
# force-kill would skip that and can leave a device with no internet.
BUNDLE_ID="dev.srsouza.Jaca"
is_running() { [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" = "true" ]; }
if is_running; then
  echo "Quitting the running Jaca so the new build launches…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do is_running || break; sleep 0.5; done
  if is_running; then
    echo "error: Jaca didn't quit within 15s (a dialog may be open). Quit it, then re-run." >&2
    exit 1
  fi
fi

echo "Launching $APP_PATH"
open "$APP_PATH"
