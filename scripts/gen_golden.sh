#!/usr/bin/env bash
# Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
# Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
# Usage: scripts/gen_golden.sh - generate M2 block-compression golden
# reference: corpus/block_golden_ref.txt
# (one line per case, see scripts/gen_golden.c header for the line format)
# plus corpus/block/<idx>.lz4 artifacts for outputs <= 65536 bytes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cc -O2 -I"$HOME/lz4/lib" -I"$HOME/lz4/tests" -I"$HOME/lz4/programs" \
   "$ROOT/scripts/gen_golden.c" "$HOME/lz4/tests/datagen.c" "$HOME/lz4/lib/lz4.c" \
   "$HOME/lz4/lib/lz4hc.c" "$HOME/lz4/lib/xxhash.c" -o "$ROOT/scripts/gen_golden"

mkdir -p "$ROOT/corpus/block"
rm -f "$ROOT"/corpus/block/*.lz4
cd "$ROOT"
scripts/gen_golden | tee corpus/block_golden_ref.txt

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
# = 376 data rows, plus 13 '#' provenance comments
#   (dict / stream / ring / setdict + cont / savedict / dictfast /
#    dictslow / attach / extdict / destext + hc / hcdest sections)
[ "$(wc -l < corpus/block_golden_ref.txt)" -eq 389 ] \
    || { echo "ERROR: expected 389 golden lines (376 rows + 13 comments)" >&2; exit 1; }
[ "$(grep -c '^#' corpus/block_golden_ref.txt)" -eq 13 ] \
    || { echo "ERROR: expected exactly 13 comment lines" >&2; exit 1; }
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
[ "$(grep -c 'mode=hc ' corpus/block_golden_ref.txt)" -eq 19 ] \
    || { echo "ERROR: expected 19 hc rows" >&2; exit 1; }
[ "$(grep -c 'mode=hcdest' corpus/block_golden_ref.txt)" -eq 1 ] \
    || { echo "ERROR: expected 1 hcdest row" >&2; exit 1; }
