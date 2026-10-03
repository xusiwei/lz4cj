#!/usr/bin/env bash
# Usage: scripts/verify_downstream.sh [lt|st|both]  (default: both)
# M8 验收(设计 §10):双制品可被下游 cjpm 依赖引用成功。
# 机制:临时下游 executable 工程,path 依赖引用本仓库,跑 scripts/downstream_smoke.cj
# 冒烟(块/HC/frame 三路往返 + 钉值);每工具链各建各跑各清理。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-both}"
EXPECT="DOWNSTREAM_SMOKE_OK c=517 hc=517 fc=532"

run_one() {
    local tag="$1" setup="$2" tmp out
    tmp="$(mktemp -d /tmp/lz4_ds_smoke.XXXXXX)"
    mkdir -p "$tmp/src"
    cat > "$tmp/cjpm.toml" <<EOF
[package]
  cjc-version = "1.0.5"
  name = "lz4_ds_smoke"
  description = "lz4cj downstream dependency smoke (generated)"
  version = "0.1.0"
  output-type = "executable"

[dependencies]
  lz4 = { path = "$ROOT" }
EOF
    cp "$ROOT/scripts/downstream_smoke.cj" "$tmp/src/main.cj"
    echo "=== [$tag] downstream dependency smoke ==="
    if ! out="$(bash -c "source '$setup' && cd '$tmp' && cjpm run" 2>&1)"; then
        printf '%s\n' "$out"
        echo "[$tag] FAILED: cjpm run error"
        rm -rf "$tmp"
        exit 1
    fi
    printf '%s\n' "$out" | tail -3
    if ! printf '%s\n' "$out" | grep -qF "$EXPECT"; then
        echo "[$tag] FAILED: expected \"$EXPECT\""
        rm -rf "$tmp"
        exit 1
    fi
    echo "[$tag] PASS"
    rm -rf "$tmp"
}

case "$MODE" in
    lt)   run_one lt "$HOME/sdk/cangjie-1.0.5/envsetup.sh" ;;
    st)   run_one st "$HOME/sdk/cangjie-1.2.0/envsetup.sh" ;;
    both) run_one lt "$HOME/sdk/cangjie-1.0.5/envsetup.sh"
          run_one st "$HOME/sdk/cangjie-1.2.0/envsetup.sh" ;;
    *)    echo "usage: $0 [lt|st|both]"; exit 1 ;;
esac
