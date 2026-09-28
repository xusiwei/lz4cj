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
   "$HOME/lz4/lib/xxhash.c" -o "$ROOT/scripts/gen_golden"

mkdir -p "$ROOT/corpus/block"
rm -f "$ROOT"/corpus/block/*.lz4
cd "$ROOT"
scripts/gen_golden | tee corpus/block_golden_ref.txt

# sanity: 64 inputs x 4 modes = 256 rows
[ "$(wc -l < corpus/block_golden_ref.txt)" -eq 256 ] \
    || { echo "ERROR: expected 256 golden rows" >&2; exit 1; }
