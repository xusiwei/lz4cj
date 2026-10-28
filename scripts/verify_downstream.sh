#!/usr/bin/env bash
# Usage: scripts/verify_downstream.sh [lt|st|both]  (default: both)
# M8 验收(设计 §10):双制品可被下游 cjpm 依赖引用成功。
# 机制:临时下游 executable 工程,path 依赖引用本仓库,跑 examples/downstream_smoke
# 冒烟(块/HC/frame 三路往返 + 钉值;M9 追加 lz4file 第四路文件往返 lf=532);
# 每工具链各建各跑各清理。
# SDK 路径经 scripts/cjenv.sh 解析:优先 LZ4CJ_SDK_105 / LZ4CJ_SDK_120
# 环境变量,回退 ~/sdk/cangjie-<ver>,与平台无关。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/cjenv.sh"
MODE="${1:-both}"
EXPECT="DOWNSTREAM_SMOKE_OK c=517 hc=517 fc=532 lf=532"

run_one() {
    local tag="$1" setup="$2" tmp out dep_path
    tmp="$(mktemp -d /tmp/lz4_ds_smoke.XXXXXX)"
    mkdir -p "$tmp/src"
    # cjpm.exe reads cjpm.toml natively: emit a Windows-style path (E:/...)
    # when running under MSYS/Git Bash, since /e/... is meaningless to it.
    dep_path="$ROOT"
    command -v cygpath >/dev/null 2>&1 && dep_path="$(cygpath -m "$ROOT")"
    cat > "$tmp/cjpm.toml" <<EOF
[package]
  cjc-version = "1.0.5"
  name = "downstream_smoke"
  description = "lz4cj downstream dependency smoke (generated)"
  version = "0.1.0"
  output-type = "executable"

[dependencies]
  lz4 = { path = "$dep_path" }
EOF
    cp "$ROOT/examples/downstream_smoke/src/main.cj" "$tmp/src/main.cj"
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
    lt)   run_one lt "$(cjenv_setup 1.0.5)" ;;
    st)   run_one st "$(cjenv_setup 1.2.0)" ;;
    both) run_one lt "$(cjenv_setup 1.0.5)"
          run_one st "$(cjenv_setup 1.2.0)" ;;
    *)    echo "usage: $0 [lt|st|both]"; exit 1 ;;
esac
