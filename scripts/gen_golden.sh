#!/usr/bin/env bash
# Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
# Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
# Usage: scripts/gen_golden.sh - generate M2 block-compression golden
# reference: corpus/block_golden_ref.txt
# (one line per case, see probes/gen_golden.c header for the line format)
# plus corpus/block/<idx>.lz4 artifacts for outputs <= 65536 bytes.
# Path-independent: upstream lz4 C sources are located via $LZ4CJ_UPSTREAM
# (must be the dev-0774d055 checkout, see CHANGELOG M3), default ~/lz4;
# C compiler via $CC, default cc then gcc then clang.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${LZ4CJ_UPSTREAM:-$HOME/lz4}"
CC="${CC:-$(command -v cc || command -v gcc || command -v clang || true)}"
[ -n "$CC" ] || { echo "[error] no C compiler found (set CC=...)" >&2; exit 1; }
[ -f "$UPSTREAM/lib/lz4.c" ] || {
    echo "[error] upstream lz4 sources not found at $UPSTREAM" >&2
    echo "[error] set LZ4CJ_UPSTREAM=<lz4 checkout> or clone upstream:" >&2
    echo "[error]   git clone https://github.com/lz4/lz4 \$HOME/lz4 && git -C \$HOME/lz4 checkout 0774d055" >&2
    exit 1
}

# MinGW/MSYS: route printf through MinGW's C99 stdio (msvcrt chokes on
# %zu and would also CR-translate text-mode stdout).
EXTRA_CFLAGS=""
case "${OSTYPE:-}/$(uname -s 2>/dev/null)" in
    msys/*|MINGW*|*MSYS*|*MINGW*) EXTRA_CFLAGS="-D__USE_MINGW_ANSI_STDIO=1" ;;
esac

"$CC" -O2 $EXTRA_CFLAGS -I"$UPSTREAM/lib" -I"$UPSTREAM/tests" -I"$UPSTREAM/programs" \
   "$ROOT/probes/gen_golden.c" "$UPSTREAM/tests/datagen.c" "$UPSTREAM/lib/lz4.c" \
   "$UPSTREAM/lib/lz4hc.c" "$UPSTREAM/lib/lz4frame.c" "$UPSTREAM/lib/xxhash.c" \
   -o "$ROOT/probes/gen_golden"

mkdir -p "$ROOT/corpus/block"
rm -f "$ROOT"/corpus/block/*.lz4
cd "$ROOT"
probes/gen_golden | tee corpus/block_golden_ref.txt
# MinGW text-mode stdout may emit CRLF; strip a trailing CR per line (no-op
# on Linux where the generator emits pure LF).
if grep -q $'\r' corpus/block_golden_ref.txt; then
    sed -i 's/\r$//' corpus/block_golden_ref.txt
    echo "[fix] stripped CR from block_golden_ref.txt (MinGW stdout)"
fi

# sanity: 64 inputs x 4 modes = 256 rows + 8 tight rows + 16 dict rows
#         + 8 stream rows + 10 ring rows + 2 setdict rows
#         + 10 fastreset rows (M3b Task 1)
#         + 8 cont rows (M3b Task 2: 7 rolling + 1 cont0 anchor)
#         + 6 savedict rows (M3b Task 2)
#         + 8 dictfast + 8 dictslow rows (M3b Task 3)
#         + 4 attach rows (M3b Task 3)
#         + 6 extdict rows (M3b Task 3)
#         + 6 destext rows (M3b Task 4)
#         + 19 hc rows (M4 Task 2: A/B x lv3-9 + lv9 x C..G) + 1 hcdest row
#         + 9 hc mid rows (M4 Task 3: A/B x lv1-2 + lv2 x C..G) + 1 hcdest
#           mid row (M4 Task 3: lv=2 x A)
#         + 14 hc optimal rows (M4 Task 4: lv10-12 x A/B + lv12 x C..G +
#           3 fav=1 rows) + 2 hcdest opt rows (M4 Task 4: lv=10/12 x A)
#         + 12 hccont rows (M4 Task 5: 4 contiguous blocks x lv {2,9,12})
#         + 3 hcsavedict rows (M4 Task 5: 3 blocks with saveDictHC between)
#         + 4 hcdict rows (M4 Task 5: loadDictHC at lv {2,9,12} + dd=131072 clamp)
#         + 3 hcattach rows (M4 Task 5: 8192/lv9 copy + 4096/lv9 consult +
#           8192 lv9-dict vs lv2-work incompatible consult)
#         + 2 hcdestcont rows (M4 Task 5: lv9 2 contiguous blocks via
#           LZ4_compress_HC_continue_destSize tg=12288)
#         + 10 frhdr rows (M5 Task 2: LZ4F_compressBegin header encoding,
#           fresh cctx per row, header bytes = artifact)
#         + 27 frame rows (M5 Task 3: full streaming frames via Begin +
#           Update[/uncompressedUpdate/flush]* + End; A variants rows 1-7 +
#           27 did=42, C variants 8-20 + flushmid/umix/chunks5 scenarios
#           21-23, D/G/F edge inputs 24-26, F with ccs=1)
#         + 8 f1s rows (M5 Task 4: LZ4F_compressFrame one-shot; A NULL-prefs,
#           B lv=3/9/12, C lv=9 multi-block linked, A csz=1, A did+ccs=1,
#           A lv=-3)
#         + 2 fcd rows (M5 Task 4: LZ4F_compressFrame_usingCDict; A lv=0
#           single block, C bm=1 lv=9 per-block attach, dict seed=99)
#         + 2 fdt rows (M5 Task 4: LZ4F_compressBegin_usingDict frames;
#           A dd=65536 dseed=99 lv=0 bm=0 linked, C dd=64 dseed=77 lv=9
#           bm=1 blockIndependent dict-discard quirk: frame == no-dict frame)
#         + 14 fdmp rows (M6 Task 3: LZ4F decompression probes - getFrameInfo
#           fresh-dctx pins x2, mid-frame getFrameInfo branches x3, fragmented
#           resumption sequences seq1/seq2, skippable seq3/seq4, 3-segment
#           concat, dict dseed=0 with-dict triple + no-dict -16 double pin,
#           corrupted-frame codes errhdr/errblk/errtail; no artifacts)
# = 489 data rows, plus 23 '#' provenance comments
#   (dict / stream / ring / setdict + cont / savedict / dictfast /
#    dictslow / attach / extdict / destext + hc / hcdest +
#    hccont / hcsavedict / hcdict / hcattach / hcdestcont + frhdr + frame
#    + f1s / fcd / fdt + fdmp sections)
[ "$(wc -l < corpus/block_golden_ref.txt)" -eq 512 ] \
    || { echo "ERROR: expected 512 golden lines (489 rows + 23 comments)" >&2; exit 1; }
[ "$(grep -c '^#' corpus/block_golden_ref.txt)" -eq 23 ] \
    || { echo "ERROR: expected exactly 23 comment lines" >&2; exit 1; }
[ "$(grep -c 'mode=fdmp' corpus/block_golden_ref.txt)" -eq 14 ] \
    || { echo "ERROR: expected 14 fdmp rows" >&2; exit 1; }
[ "$(grep -c 'mode=f1s ' corpus/block_golden_ref.txt)" -eq 8 ] \
    || { echo "ERROR: expected 8 f1s rows" >&2; exit 1; }
[ "$(grep -c 'mode=fcd ' corpus/block_golden_ref.txt)" -eq 2 ] \
    || { echo "ERROR: expected 2 fcd rows" >&2; exit 1; }
[ "$(grep -c 'mode=fdt ' corpus/block_golden_ref.txt)" -eq 2 ] \
    || { echo "ERROR: expected 2 fdt rows" >&2; exit 1; }
[ "$(grep -c 'mode=frame ' corpus/block_golden_ref.txt)" -eq 27 ] \
    || { echo "ERROR: expected 27 frame rows" >&2; exit 1; }
[ "$(grep -c 'mode=frhdr' corpus/block_golden_ref.txt)" -eq 10 ] \
    || { echo "ERROR: expected 10 frhdr rows" >&2; exit 1; }
[ "$(grep -c 'mode=fastreset' corpus/block_golden_ref.txt)" -eq 10 ] \
    || { echo "ERROR: expected 10 fastreset rows" >&2; exit 1; }
[ "$(grep -c 'mode=cont seq=' corpus/block_golden_ref.txt)" -eq 7 ] \
    || { echo "ERROR: expected 7 cont rows" >&2; exit 1; }
[ "$(grep -c 'mode=cont0' corpus/block_golden_ref.txt)" -eq 1 ] \
    || { echo "ERROR: expected 1 cont0 row" >&2; exit 1; }
[ "$(grep -c 'mode=savedict' corpus/block_golden_ref.txt)" -eq 6 ] \
    || { echo "ERROR: expected 6 savedict rows" >&2; exit 1; }
[ "$(grep -c 'mode=dictfast' corpus/block_golden_ref.txt)" -eq 8 ] \
    || { echo "ERROR: expected 8 dictfast rows" >&2; exit 1; }
[ "$(grep -c 'mode=dictslow' corpus/block_golden_ref.txt)" -eq 8 ] \
    || { echo "ERROR: expected 8 dictslow rows" >&2; exit 1; }
[ "$(grep -c 'mode=attach' corpus/block_golden_ref.txt)" -eq 4 ] \
    || { echo "ERROR: expected 4 attach rows" >&2; exit 1; }
[ "$(grep -c 'mode=extdict' corpus/block_golden_ref.txt)" -eq 6 ] \
    || { echo "ERROR: expected 6 extdict rows" >&2; exit 1; }
[ "$(grep -c 'mode=destext' corpus/block_golden_ref.txt)" -eq 6 ] \
    || { echo "ERROR: expected 6 destext rows" >&2; exit 1; }
[ "$(grep -c 'mode=hc ' corpus/block_golden_ref.txt)" -eq 42 ] \
    || { echo "ERROR: expected 42 hc rows" >&2; exit 1; }
[ "$(grep -cE 'mode=hcdest[^a-z]' corpus/block_golden_ref.txt)" -eq 4 ] \
    || { echo "ERROR: expected 4 hcdest rows" >&2; exit 1; }
[ "$(grep -c 'mode=hccont seq=' corpus/block_golden_ref.txt)" -eq 12 ] \
    || { echo "ERROR: expected 12 hccont rows" >&2; exit 1; }
[ "$(grep -c 'mode=hcsavedict seq=' corpus/block_golden_ref.txt)" -eq 3 ] \
    || { echo "ERROR: expected 3 hcsavedict rows" >&2; exit 1; }
[ "$(grep -c 'mode=hcdict lv=' corpus/block_golden_ref.txt)" -eq 4 ] \
    || { echo "ERROR: expected 4 hcdict rows" >&2; exit 1; }
[ "$(grep -c 'mode=hcattach lv=' corpus/block_golden_ref.txt)" -eq 3 ] \
    || { echo "ERROR: expected 3 hcattach rows" >&2; exit 1; }
[ "$(grep -c 'mode=hcdestcont seq=' corpus/block_golden_ref.txt)" -eq 2 ] \
    || { echo "ERROR: expected 2 hcdestcont rows" >&2; exit 1; }
[ "$(du -sk corpus | cut -f1)" -le 8192 ] \
    || { echo "ERROR: corpus exceeds 8MB budget" >&2; exit 1; }
