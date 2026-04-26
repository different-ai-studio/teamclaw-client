#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/ios/AMUX.xcodeproj"
SCHEME="AMUX"
BUILD_DIR="$ROOT/ios/build"
APP_PATH="$BUILD_DIR/Build/Products/Debug-iphonesimulator/AMUX.app"

# Default simulator — prefer a booted one, otherwise pick iPhone 17 Pro
SIMULATOR_NAME="iPhone 17 Pro"
clean_build=false

usage() {
  cat <<'EOF'
Usage: ./scripts/run-ios.sh [--clean] [--sim <simulator-name>]

Options:
  --clean              Remove ios/build before rebuilding.
  --sim <name>         Simulator name (default: "iPhone 17 Pro").
                       Run `xcrun simctl list devices available` to see options.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      clean_build=true
      shift
      ;;
    --sim)
      SIMULATOR_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Resolve simulator UDID
SIM_UDID=$(xcrun simctl list devices available --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
name = '$SIMULATOR_NAME'
for devices in data['devices'].values():
    for d in devices:
        if d['name'] == name:
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)

if [[ -z "$SIM_UDID" ]]; then
  echo "error: simulator '$SIMULATOR_NAME' not found." >&2
  echo "Available simulators:" >&2
  xcrun simctl list devices available | grep -E "iPhone|iPad" >&2
  exit 1
fi

echo "Simulator: $SIMULATOR_NAME ($SIM_UDID)"

# Boot simulator if needed
SIM_STATE=$(xcrun simctl list devices --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for devices in data['devices'].values():
    for d in devices:
        if d['udid'] == '$SIM_UDID':
            print(d['state'])
            sys.exit(0)
")

if [[ "$SIM_STATE" != "Booted" ]]; then
  echo "Booting simulator..."
  xcrun simctl boot "$SIM_UDID"
  # `simctl boot` returns before the simulator is ready for install/launch.
  # bootstatus blocks until the system is fully usable.
  echo "Waiting for simulator to finish booting..."
  xcrun simctl bootstatus "$SIM_UDID" -b
fi

open -a Simulator --args -CurrentDeviceUDID "$SIM_UDID"

if [[ "$clean_build" = true ]]; then
  rm -rf "$BUILD_DIR"
fi

echo "Building..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$SIM_UDID" \
  -derivedDataPath "$BUILD_DIR" \
  build 2>&1 | xcpretty 2>/dev/null || cat

echo "Installing..."
xcrun simctl install "$SIM_UDID" "$APP_PATH"

echo "Launching..."
xcrun simctl launch --console-pty "$SIM_UDID" tech.teamclaw.mobile
