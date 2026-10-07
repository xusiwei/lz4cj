#!/usr/bin/env bash
# e2e cross-validation of the lz4cj port against the upstream lz4 C library.
#
# Builds two CLI twins with identical contracts (-c/-d -i/-o, frame format):
#   e2e/cli-c    - C, CMake, compiles the upstream lz4 sources in-tree
#                  (baseline commit 0774d055, located like gen_golden.sh:
#                  -DLZ4_PATH / $LZ4CJ_UPSTREAM / ~/lz4)
#   e2e/cli-cj   - Cangjie executable module, path-depends on the repo root
#                  (SDKs resolved via scripts/cjenv.sh: LZ4CJ_SDK_105/120
#                  env vars, fallback ~/sdk/cangjie-<ver>)
#
# Usage: e2e/run_e2e.sh [lt|st|both]   (Cangjie toolchain selection, default both)
#
# Per toolchain and per test file it checks:
#   1. compressed outputs of C vs Cangjie are BYTE-IDENTICAL (frame fidelity)
#   2. C-compress  -> C-decompress  == original   (reference sanity)
#   3. CJ-compress -> CJ-decompress == original   (port sanity)
#   4. C-compress  -> CJ-decompress == original   (cross)
#   5. CJ-compress -> C-decompress  == original   (cross)
#   6. both tools REJECT: corrupted magic / truncated frame / trailing garbage
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E="$ROOT/e2e"
UPSTREAM="${LZ4CJ_UPSTREAM:-$HOME/lz4}"
MODE="${1:-both}"
. "$ROOT/scripts/cjenv.sh"

PASS=0
FAIL=0
TO=300    # per-invocation timeout (s); windows-x64 runtime livelock guard

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }

note() { echo "== $*"; }

# run a tool with timeout; rc 124 = timed out
run_t() {
    timeout "$TO" "$@" </dev/null
    return $?
}

expect_ok() {  # expect_ok <label> <cmd...>
    local label="$1"; shift
    if run_t "$@"; then ok; else bad "$label (rc=$?)"; fi
}
expect_fail() { # expect_fail <label> <cmd...>
    local label="$1"; shift
    local rc=0
    run_t "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then ok; else bad "$label (rc=$rc, want nonzero)"; fi
}
expect_same() { # expect_same <label> <a> <b>
    if [ ! -f "$2" ] || [ ! -f "$3" ]; then bad "$1 (missing file)"; return; fi
    if cmp -s "$2" "$3"; then ok; else bad "$1 (differ)"; fi
}

# ---------- 1. build the C reference tool ----------
note "building C tool (cmake, upstream=$UPSTREAM)"
if [ ! -f "$UPSTREAM/lib/lz4.c" ]; then
    echo "[error] upstream lz4 sources not found at $UPSTREAM (set LZ4CJ_UPSTREAM)" >&2
    exit 1
fi
GEN=()
command -v ninja >/dev/null 2>&1 && GEN=(-G Ninja)
LP="$UPSTREAM"
command -v cygpath >/dev/null 2>&1 && LP="$(cygpath -m "$UPSTREAM")"
cmake -S "$E2E/cli-c" -B "$E2E/cli-c/build" "${GEN[@]}" -DLZ4_PATH="$LP" >/dev/null \
    || { echo "[error] cmake configure failed" >&2; exit 1; }
cmake --build "$E2E/cli-c/build" >/dev/null \
    || { echo "[error] cmake build failed" >&2; exit 1; }
CTOOL="$E2E/cli-c/build/lz4cli"
[ -f "$CTOOL" ] || CTOOL="$E2E/cli-c/build/lz4cli.exe"
[ -f "$CTOOL" ] || { echo "[error] C tool binary not found" >&2; exit 1; }
echo "  C tool: $CTOOL"

# ---------- 2. generate test cases ----------
CASES="$E2E/tmp/cases"
WORK="$E2E/tmp/work"
rm -rf "$CASES" "$E2E/tmp"/work*
mkdir -p "$CASES" "$WORK"

note "generating test cases"
: > "$CASES/empty.bin"
printf 'A' > "$CASES/one.bin"
head -c 65536 /dev/zero > "$CASES/zeros.bin"
cat "$E2E/cli-c/lz4cli.c" "$E2E/cli-cj/src/main.cj" "$ROOT/README.md" > "$CASES/text.txt"
head -c 262144 /dev/urandom > "$CASES/random.bin"        # incompressible
{ head -c 524288 /dev/urandom | tr '\0' 'x'; head -c 524288 /dev/urandom; } > "$CASES/mixed.bin"
echo "  cases: $(ls "$CASES" | tr '\n' ' ')"

# ---------- 3. per-toolchain matrix ----------
run_matrix() {
    local tag="$1" setup="$2" cjtool="$3"
    local f name
    WORK="$E2E/tmp/work-$tag"     # per-toolchain artifacts (overwrite-safe)
    mkdir -p "$WORK"
    note "[$tag] matrix (cjtool=$cjtool)"
    for f in "$CASES"/*; do
        name="$(basename "$f")"
        local cf="$WORK/$name.c.fr" jf="$WORK/$name.cj.fr"
        expect_ok   "[$tag] $name C compress"    "$CTOOL" -c -i "$f" -o "$cf"
        expect_ok   "[$tag] $name CJ compress"   "$cjtool" -c -i "$f" -o "$jf"
        expect_same "[$tag] $name compressed bytes C==CJ" "$cf" "$jf"
        expect_ok   "[$tag] $name C->C"   "$CTOOL"  -d -i "$cf" -o "$WORK/$name.cc.out"
        expect_same "[$tag] $name C->C roundtrip"  "$f" "$WORK/$name.cc.out"
        expect_ok   "[$tag] $name CJ->CJ" "$cjtool" -d -i "$jf" -o "$WORK/$name.jj.out"
        expect_same "[$tag] $name CJ->CJ roundtrip" "$f" "$WORK/$name.jj.out"
        expect_ok   "[$tag] $name C->CJ cross"  "$cjtool" -d -i "$cf" -o "$WORK/$name.cj.out"
        expect_same "[$tag] $name C->CJ roundtrip" "$f" "$WORK/$name.cj.out"
        expect_ok   "[$tag] $name CJ->C cross"  "$CTOOL"  -d -i "$jf" -o "$WORK/$name.jc.out"
        expect_same "[$tag] $name CJ->C roundtrip" "$f" "$WORK/$name.jc.out"
    done

    # error handling on the text case's C-compressed frame
    local good="$WORK/text.txt.c.fr"
    local bad1="$WORK/corrupt-magic.fr" bad2="$WORK/truncated.fr" bad3="$WORK/trailing.fr"
    cp "$good" "$bad1"
    printf '\xde\xad\xbe\xef' | dd of="$bad1" bs=1 seek=0 conv=notrunc status=none
    head -c $(( $(wc -c < "$good") - 4 )) "$good" > "$bad2"
    cp "$good" "$bad3" && printf '\x00' >> "$bad3"
    expect_fail "[$tag] corrupt magic rejected by C"    "$CTOOL"  -d -i "$bad1" -o "$WORK/x.out"
    expect_fail "[$tag] corrupt magic rejected by CJ"   "$cjtool" -d -i "$bad1" -o "$WORK/x.out"
    expect_fail "[$tag] truncated rejected by C"        "$CTOOL"  -d -i "$bad2" -o "$WORK/x.out"
    expect_fail "[$tag] truncated rejected by CJ"       "$cjtool" -d -i "$bad2" -o "$WORK/x.out"
    expect_fail "[$tag] trailing rejected by C"         "$CTOOL"  -d -i "$bad3" -o "$WORK/x.out"
    expect_fail "[$tag] trailing rejected by CJ"        "$cjtool" -d -i "$bad3" -o "$WORK/x.out"
    expect_fail "[$tag] missing input rejected by C"    "$CTOOL"  -c -i "$WORK/nope" -o "$WORK/x.out"
    expect_fail "[$tag] missing input rejected by CJ"   "$cjtool" -c -i "$WORK/nope" -o "$WORK/x.out"
}

run_toolchain() {
    local tag="$1" ver="$2"
    local setup
    if ! setup="$(cjenv_setup "$ver")"; then
        bad "[$tag] SDK $ver not found (set LZ4CJ_SDK_105/LZ4CJ_SDK_120)"
        return 1
    fi
    note "[$tag] building Cangjie tool (cjpm)"
    # clean both the CLI module and the path-dependency repo target:
    # the two toolchains' incremental caches are mutually unreadable
    local buildlog="$E2E/tmp/build-$tag.log"
    if ! ( bash -c "source '$setup' && cd '$ROOT' && cjpm clean && \
                    cd '$E2E/cli-cj' && cjpm clean && cjpm build" ) >"$buildlog" 2>&1; then
        bad "[$tag] cjpm build failed (log: $buildlog, tail below)"
        tail -5 "$buildlog" | sed 's/^/    /'
        return 1
    fi
    local cjtool="$E2E/cli-cj/target/release/bin/main"
    [ -f "$cjtool" ] || cjtool="$E2E/cli-cj/target/release/bin/main.exe"
    [ -f "$cjtool" ] || { bad "[$tag] Cangjie binary not found"; return 1; }
    # source the SDK env so the Cangjie binary finds its runtime DLLs;
    # envsetup.sh is not set -u clean, so relax for the duration
    local old_path="$PATH"
    set +u
    . "$setup"
    set -u
    run_matrix "$tag" "$setup" "$cjtool"
    PATH="$old_path"
}

case "$MODE" in
    lt)   run_toolchain lt 1.0.5 ;;
    st)   run_toolchain st 1.2.0 ;;
    both) run_toolchain lt 1.0.5
          run_toolchain st 1.2.0 ;;
    *)    echo "usage: $0 [lt|st|both]"; exit 1 ;;
esac

echo "----------------------------------------"
echo "e2e result: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
