/* Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
//
// M3b Task 1 probe: search for (block0, block1) pairs where
// LZ4_compress_fast_extState_fastReset dirty-table reuse output differs
// from a fresh-state compression of block1 alone (both blocks byU16 =>
// n < 65547; reuse requires n1 < 4096 and offset0 + n1 < 0xFFFF and
// matching tableType).
//
// Finding (2026-09-29): 900/900 RDG combinations IDENTICAL. This is a
// theorem, not a data property: in fresh byU16 mode the only candidate an
// empty hash slot can yield is index 0, and the read32 test for it compares
// src[0..4] against src[ip..ip+4] — if those were equal, position 0's own
// first-byte insert (lz4.c L1018) would occupy that very slot, so the slot
// cannot be empty. Hence empty/zero-slot candidates never match in fresh
// mode, and dictSmall's rejection of stale+zero candidates in reuse mode is
// output-neutral: compressed output of fastReset is ALWAYS byte-equal to
// fresh-state compression (reset paths trivially so). What differs is the
// state evolution (currentOffset accumulates / table stays dirty), which is
// what the golden fastreset rows' off=/tt= fields pin instead.
//
// Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
//   probes/probe_fastreset_reuse.c $HOME/lz4/tests/datagen.c \
//   $HOME/lz4/lib/lz4.c $HOME/lz4/lib/xxhash.c -o /tmp/probe_reuse */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "xxhash.h"
#include "datagen.h"

static int one_case(size_t n0, double mp0, unsigned s0,
                    size_t n1, double mp1, unsigned s1) {
    unsigned char* b0 = malloc(n0 ? n0 : 1);
    unsigned char* b1 = malloc(n1 ? n1 : 1);
    RDG_genBuffer(b0, n0, mp0, 0.0, s0);
    RDG_genBuffer(b1, n1, mp1, 0.0, s1);
    int bound0 = LZ4_compressBound((int)n0);
    int bound1 = LZ4_compressBound((int)n1);
    unsigned char* o0 = malloc(bound0);
    unsigned char* o1 = malloc(bound1);
    unsigned char* of = malloc(bound1);
    LZ4_stream_t* st = LZ4_createStream();
    int c0 = LZ4_compress_fast_extState_fastReset(st, (char*)b0, (char*)o0, (int)n0, bound0, 1);
    int c1 = LZ4_compress_fast_extState_fastReset(st, (char*)b1, (char*)o1, (int)n1, bound1, 1);
    LZ4_freeStream(st);
    /* fresh reference for block1 */
    int cf = LZ4_compress_default((char*)b1, (char*)of, (int)n1, bound1);
    int diff = (c1 != cf) || memcmp(o1, of, c1) != 0;
    if (diff) {
        printf("DIFF n0=%zu mp0=%.2f s0=%u n1=%zu mp1=%.2f s1=%u c1=%d cf=%d "
               "reuse_xxh32=%08x fresh_xxh32=%08x in32=%08x\n",
               n0, mp0, s0, n1, mp1, s1, c1, cf,
               XXH32(o1, c1, 0), XXH32(of, cf, 0), XXH32(b1, n1, 0));
    }
    free(b0); free(b1); free(o0); free(o1); free(of);
    return diff;
}

int main(void) {
    size_t ns0[] = {200, 1024, 2048, 3000, 4000};
    size_t ns1[] = {200, 1024, 2048, 3000, 4000};
    double mps[] = {0.0, 0.3, 0.5, 0.7, 0.9, 1.0};
    int found = 0, tried = 0;
    for (unsigned i0 = 0; i0 < sizeof(ns0)/sizeof(ns0[0]); i0++)
    for (unsigned m0 = 0; m0 < 6; m0++)
    for (unsigned i1 = 0; i1 < sizeof(ns1)/sizeof(ns1[0]); i1++)
    for (unsigned m1 = 0; m1 < 6; m1++) {
        unsigned seed = 1000 + i0 * 100 + m0 * 10 + i1; /* deterministic spread */
        tried++;
        found += one_case(ns0[i0], mps[m0], seed, ns1[i1], mps[m1], seed + 7);
        if (found >= 12) { printf("tried=%d found=%d\n", tried, found); return 0; }
    }
    printf("tried=%d found=%d\n", tried, found);
    return 0;
}
