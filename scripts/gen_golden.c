// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
//
// M2 block-compression golden harness (ground truth for Cangjie Tasks 3/4).
// Emits corpus/block_golden_ref.txt plus corpus/block/<idx>.lz4 artifacts.
//
// Matrix: sizes {0,1,255,4096,65535,65536,65537,131072} x mp {0.0,0.5,0.9,1.0}
//         x lp {0.0} x seeds {0,7}; modes default / fast1 / fast8 / dest
//         (dest target = n*3/4) => 64 inputs x 4 modes = 256 manifest rows,
//         plus 8 tight rows (seed=0, mp cycled, dstCapacity = c-1 => size=0).
//
// Manifest line format (contract for M2 Tasks 3/4 - follow exactly):
//   n=<n> mp=<mp> seed=<seed> mode=<mode> size=<c> [consumed=<k> ]xxh32=<h32> xxh64=<h64>[ file=block/<idx>.lz4]
// - consumed= appears only on mode=dest rows, directly after size=
// - file= is appended at end of line when the compressed output c <= 65536
//   (larger outputs are digest-only); manifest stays one line per case
// - artifact name = 3-digit sequential row index in manifest order (000..255)
// - xxh32/xxh64 digest the compressed bytes (out, c), seed 0
//
// Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
//          scripts/gen_golden.c $HOME/lz4/tests/datagen.c $HOME/lz4/lib/lz4.c \
//          $HOME/lz4/lib/xxhash.c -o scripts/gen_golden
#include <stdio.h>
#include <stdlib.h>
#include "lz4.h"
#include "xxhash.h"
#include "datagen.h"

static const size_t kSizes[] = {0, 1, 255, 4096, 65535, 65536, 65537, 131072};
static const double kMps[] = {0.0, 0.5, 0.9, 1.0};
static const unsigned kSeeds[] = {0, 7};
static const char* kModes[] = {"default", "fast1", "fast8", "dest"};

int main(void) {
    int idx = 0;
    for (unsigned si = 0; si < sizeof(kSizes) / sizeof(kSizes[0]); si++)
    for (unsigned mi = 0; mi < sizeof(kMps) / sizeof(kMps[0]); mi++)
    for (unsigned di = 0; di < sizeof(kSeeds) / sizeof(kSeeds[0]); di++) {
        size_t n = kSizes[si];
        /* upstream RDG_genBlock writes buffPtr[0] even when buffSize==0;
           allocate >= 1 byte so the write lands */
        unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
        int bound = LZ4_compressBound((int)n);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        if (!buf || !out) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(buf, n, kMps[mi], 0.0, kSeeds[di]);
        for (unsigned mo = 0; mo < 4; mo++) {
            int consumed = (int)n;
            int c;
            if (mo == 0) {
                c = LZ4_compress_default((const char*)buf, (char*)out, (int)n, bound);
            } else if (mo == 1 || mo == 2) {
                c = LZ4_compress_fast((const char*)buf, (char*)out, (int)n, bound,
                                      mo == 1 ? 1 : 8);
            } else {
                c = LZ4_compress_destSize((const char*)buf, (char*)out, &consumed,
                                          (int)(n * 3 / 4));
            }
            /* default/fast cannot fail here: out is sized compressBound(n) */
            if (mo != 3 && c == 0) {
                fprintf(stderr, "mode=%s unexpectedly returned 0 (n=%zu)\n",
                        kModes[mo], n);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=%s size=%d ",
                   n, kMps[mi], kSeeds[di], kModes[mo], c);
            if (mo == 3) printf("consumed=%d ", consumed);
            printf("xxh32=%08x xxh64=%016llx",
                   XXH32(out, (size_t)c, 0),
                   (unsigned long long)XXH64(out, (size_t)c, 0));
            if (c >= 0 && c <= 65536) {
                char path[64];
                snprintf(path, sizeof(path), "corpus/block/%03d.lz4", idx);
                FILE* f = fopen(path, "wb");
                if (!f || fwrite(out, 1, (size_t)c, f) != (size_t)c) {
                    fprintf(stderr, "write %s failed\n", path);
                    return 1;
                }
                fclose(f);
                printf(" file=block/%03d.lz4", idx);
            }
            printf("\n");
            idx++;
        }
        free(buf);
        free(out);
    }
    /* tight-capacity rows (M3 Task 1 leftover): compress with the full bound,
       then re-encode with dstCapacity = c-1. The encode is deterministic, so
       the capacity-starved retry must hit the limitedOutput bail -> size=0.
       seed=0, mp cycles over the size matrix => 8 manifest rows. */
    for (unsigned ti = 0; ti < sizeof(kSizes) / sizeof(kSizes[0]); ti++) {
        size_t n = kSizes[ti];
        double mp = kMps[(ti + 1) % 4];
        unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
        int bound = LZ4_compressBound((int)n);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        if (!buf || !out) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(buf, n, mp, 0.0, 0);
        int c = LZ4_compress_default((const char*)buf, (char*)out, (int)n, bound);
        if (c == 0) {
            fprintf(stderr, "tight: base compress failed (n=%zu)\n", n);
            return 1;
        }
        int t = LZ4_compress_default((const char*)buf, (char*)out, (int)n, c - 1);
        if (t != 0) {
            fprintf(stderr, "tight: expected 0, got %d (n=%zu)\n", t, n);
            return 1;
        }
        printf("n=%zu mp=%.2f seed=0 mode=tight size=%d xxh32=%08x xxh64=%016llx",
               n, mp, t,
               XXH32(out, (size_t)t, 0),
               (unsigned long long)XXH64(out, (size_t)t, 0));
        if (t >= 0 && t <= 65536) {
            char path[64];
            snprintf(path, sizeof(path), "corpus/block/%03d.lz4", idx);
            FILE* f = fopen(path, "wb");
            if (!f || (t && fwrite(out, 1, (size_t)t, f) != (size_t)t)) {
                fprintf(stderr, "write %s failed\n", path);
                return 1;
            }
            fclose(f);
            printf(" file=block/%03d.lz4", idx);
        }
        printf("\n");
        idx++;
        free(buf);
        free(out);
    }
    fprintf(stderr, "cases=%d\n", idx);
    return 0;
}
