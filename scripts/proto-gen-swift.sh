#!/bin/bash
set -euo pipefail
PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)/proto"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/ios/Packages/AMUXCore/Sources/AMUXCore/Proto"
mkdir -p "$OUT_DIR"
protoc \
  --swift_out="$OUT_DIR" \
  --swift_opt=Visibility=Public \
  --proto_path="$PROTO_DIR" \
  "$PROTO_DIR/amux.proto"
echo "✓ Swift proto generated in $OUT_DIR"
