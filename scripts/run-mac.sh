#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT/mac/build/Build/Products/Debug/AMUXMac.app"
BUILD_DIR="$ROOT/mac/build"

clean_build=false

usage() {
  cat <<'EOF'
Usage: ./scripts/run-mac.sh [--clean]

Options:
  --clean    Remove mac/build before rebuilding and restarting the app.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --clean)
      clean_build=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$ROOT"

if pgrep -x "AMUXMac" >/dev/null 2>&1; then
  pkill -x "AMUXMac" || true
  sleep 1
fi

if [ "$clean_build" = true ]; then
  rm -rf "$BUILD_DIR"
fi

xcodebuild \
  -project mac/AMUXMac.xcodeproj \
  -scheme AMUXMac \
  -configuration Debug \
  -derivedDataPath mac/build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

open -n "$APP_PATH"
