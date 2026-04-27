#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT/daemon"
ENV_FILE="$DAEMON_DIR/.env"

usage() {
  cat <<'EOF'
Usage: ./scripts/run-daemon.sh [amuxd args...]

Loads daemon/.env with auto-export, then runs the daemon via Cargo.
If no args are provided, defaults to: start

Examples:
  ./scripts/run-daemon.sh
  ./scripts/run-daemon.sh start
  ./scripts/run-daemon.sh init 'amux://invite?token=...'
  ./scripts/run-daemon.sh status
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

missing=()
[[ -z "${SUPABASE_URL:-}" ]] && missing+=("SUPABASE_URL")
[[ -z "${SUPABASE_ANON_KEY:-}" ]] && missing+=("SUPABASE_ANON_KEY")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: missing required compile-time env vars: ${missing[*]}" >&2
  echo "Add them to $ENV_FILE or export them before running this script." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  set -- start
fi

cd "$DAEMON_DIR"
cargo run -- "$@"
