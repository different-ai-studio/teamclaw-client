#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT/mac/build/Build/Products/Debug/AMUXMac.app"

cd "$ROOT"

xcodebuild \
  -project mac/AMUXMac.xcodeproj \
  -scheme AMUXMac \
  -configuration Debug \
  -derivedDataPath mac/build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

open "$APP_PATH"
