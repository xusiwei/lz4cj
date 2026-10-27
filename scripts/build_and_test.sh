#!/usr/bin/env bash
# Usage: scripts/build_and_test.sh [lt|st|both] [test-only]  (default: both)
#   second arg "test-only" skips `cjpm bench` (CI PR gate; bench stays nightly)
# SDK locations are resolved path-independently via scripts/cjenv.sh:
# honor LZ4CJ_SDK_105 / LZ4CJ_SDK_120 env vars first, then ~/.local/
# cangjie-<lts|sts>-<ver> (download_sdk.sh), then ~/sdk/cangjie-<ver>.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/cjenv.sh"
MODE="${1:-both}"
BENCH="${2:-bench}"
mkdir -p "$ROOT/report"

run() {
    local tag="$1" setup="$2" bench_cmd=""
    [ "$BENCH" != "test-only" ] && bench_cmd=" && cjpm bench"
    echo "=== [$tag] cjpm build + test${bench_cmd:+ + bench} ==="
    local log; log="$ROOT/report/${tag}_$(date +%Y%m%d_%H%M%S).log"
    ( bash -c "source '$setup' && cd '$ROOT' && cjpm clean && cjpm build && cjpm test$bench_cmd" ) 2>&1 | tee "$log"
    echo "[$tag] log -> $log"
}

case "$MODE" in
    lt)   run lt "$(cjenv_setup 1.0.5)" ;;
    st)   run st "$(cjenv_setup 1.2.0)" ;;
    both) run lt "$(cjenv_setup 1.0.5)"
          run st "$(cjenv_setup 1.2.0)" ;;
    *)    echo "usage: $0 [lt|st|both]"; exit 1 ;;
esac
