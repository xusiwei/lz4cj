#!/usr/bin/env bash
# Usage: scripts/build_and_test.sh [lt|st|both]  (default: both)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-both}"
mkdir -p "$ROOT/report"

run() {
    local tag="$1" setup="$2"
    echo "=== [$tag] cjpm build + test ==="
    local log; log="$ROOT/report/${tag}_$(date +%Y%m%d_%H%M%S).log"
    ( bash -c "source '$setup' && cd '$ROOT' && cjpm clean && cjpm build && cjpm test" ) 2>&1 | tee "$log"
    echo "[$tag] log -> $log"
}

case "$MODE" in
    lt)   run lt "$HOME/sdk/cangjie-1.0.5/envsetup.sh" ;;
    st)   run st "$HOME/sdk/cangjie-1.2.0/envsetup.sh" ;;
    both) run lt "$HOME/sdk/cangjie-1.0.5/envsetup.sh"
          run st "$HOME/sdk/cangjie-1.2.0/envsetup.sh" ;;
    *)    echo "usage: $0 [lt|st|both]"; exit 1 ;;
esac
