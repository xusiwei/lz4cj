// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
//
// M2 block-compression golden harness (ground truth for Cangjie Tasks 3/4)
// + M3 decompression extensions: manifest v2 input digests, dict rows and a
// partial probe. Emits corpus/block_golden_ref.txt plus corpus/block/<idx>.lz4
// artifacts.
//
// Matrix: sizes {0,1,255,4096,65535,65536,65537,131072} x mp {0.0,0.5,0.9,1.0}
//         x lp {0.0} x seeds {0,7}; modes default / fast1 / fast8 / dest
//         (dest target = n*3/4) => 64 inputs x 4 modes = 256 manifest rows,
//         plus 8 tight rows (seed=0, mp cycled, dstCapacity = c-1 => size=0),
//         plus 16 mode=dict rows (see the dict section below) => 280 rows.
//
// Manifest line format (contract for M2 Tasks 3/4 and M3 - follow exactly):
//   n=<n> mp=<mp> seed=<seed> mode=<mode> size=<c> [consumed=<k> ]xxh32=<h32> xxh64=<h64> inxxh32=<h32> inxxh64=<h64>[ file=block/<idx>.lz4]
// - consumed= appears only on mode=dest rows, directly after size=
// - xxh32/xxh64 digest the compressed bytes (out, c), seed 0
// - inxxh32/inxxh64 (manifest v2) digest the ORIGINAL input bytes (buf, n),
//   seed 0; enables the M3 bidirectional digest closure (decompressed output
//   digests must equal the recorded input digests) for digest-only rows
// - file= is appended at end of line when the compressed output c <= 65536
//   (larger outputs are digest-only); manifest stays one line per case
// - artifact name = 3-digit sequential row index in manifest order (000..279)
// - a leading '#' comment line (not a data row) precedes the dict rows and
//   records the shared dictionary provenance (params + digests)
//
// Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
//          scripts/gen_golden.c $HOME/lz4/tests/datagen.c $HOME/lz4/lib/lz4.c \
//          $HOME/lz4/lib/xxhash.c -o scripts/gen_golden
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
        /* v2: digests of the original input, shared by all 4 mode rows */
        unsigned in32 = XXH32(buf, n, 0);
        unsigned long long in64 = XXH64(buf, n, 0);
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
            printf("xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   XXH32(out, (size_t)c, 0),
                   (unsigned long long)XXH64(out, (size_t)c, 0), in32, in64);
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
        printf("n=%zu mp=%.2f seed=0 mode=tight size=%d xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
               n, mp, t,
               XXH32(out, (size_t)t, 0),
               (unsigned long long)XXH64(out, (size_t)t, 0),
               XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
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
    /* dict rows (M3 Task 2): a 64KB RDG dictionary (independent of the row
       inputs: mp=0.5 lp=0.0 seed=99) loaded via LZ4_loadDict on a fresh
       stream; each row input is compressed with LZ4_compress_fast_continue
       (accel=1) so matches may reference the dictionary. Decompression side:
       LZ4_decompress_safe_usingDict against the identical regenerated dict.
       Matrix: sizes {255,4096,65536} x mp {0.0,0.9} x seeds {0,7} (12 rows)
       + extras {(65537,0.5,3),(131072,0.9,11),(1,1.0,5),(0,0.0,0)}. */
    {
        const size_t dictSize = 64 * 1024;
        unsigned char* dictBuf = (unsigned char*)malloc(dictSize);
        if (!dictBuf) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(dictBuf, dictSize, 0.5, 0.0, 99);
        /* provenance comment line (leading '#': not a data row) */
        printf("# dict=RDG(n=65536 mp=0.50 lp=0.00 seed=99) xxh32=%08x xxh64=%016llx\n",
               XXH32(dictBuf, dictSize, 0),
               (unsigned long long)XXH64(dictBuf, dictSize, 0));
        static const struct { size_t n; double mp; unsigned seed; } kDictRows[] = {
            {255, 0.0, 0}, {255, 0.0, 7}, {255, 0.9, 0}, {255, 0.9, 7},
            {4096, 0.0, 0}, {4096, 0.0, 7}, {4096, 0.9, 0}, {4096, 0.9, 7},
            {65536, 0.0, 0}, {65536, 0.0, 7}, {65536, 0.9, 0}, {65536, 0.9, 7},
            {65537, 0.5, 3}, {131072, 0.9, 11}, {1, 1.0, 5}, {0, 0.0, 0},
        };
        for (unsigned di = 0; di < sizeof(kDictRows) / sizeof(kDictRows[0]); di++) {
            size_t n = kDictRows[di].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            if (!buf || !out) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kDictRows[di].mp, 0.0, kDictRows[di].seed);
            LZ4_stream_t* stream = LZ4_createStream();
            if (!stream) { fprintf(stderr, "stream alloc failed\n"); return 1; }
            if (LZ4_loadDict(stream, (const char*)dictBuf, (int)dictSize) != (int)dictSize) {
                fprintf(stderr, "loadDict failed\n"); return 1;
            }
            int c = LZ4_compress_fast_continue(stream, (const char*)buf, (char*)out,
                                               (int)n, bound, 1);
            LZ4_freeStream(stream);
            if (c == 0) {
                fprintf(stderr, "dict row unexpectedly returned 0 (n=%zu)\n", n);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=dict size=%d xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kDictRows[di].mp, kDictRows[di].seed, c,
                   XXH32(out, (size_t)c, 0),
                   (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
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
            free(buf);
            free(out);
        }
        /* partial probe (M3 Task 2): C ground truth for the Cangjie partial
           tests, printed on stderr. Regenerates a spread of golden rows
           (3 plain + 1 dict) and reports LZ4_decompress_safe_partial /
           LZ4_decompress_safe_partial_usingDict returns for target in
           {0,1,n/2,n-1,n} with dstCapacity = n (so the effective capacity is
           purely target-driven). The probe also verifies that the decoded
           prefix matches the original input (hard failure otherwise).
           Format: "partial row=<idx> n=<n> target=<t> ret=<r>" /
           "partialdict row=<idx> n=<n> target=<t> ret=<r>" /
           "partialnodict row=<idx> n=<n> ret=<r>" (safe decode of a dict
           row without the dictionary: negative iff the block really
           references the dictionary). */
        static const struct { size_t n; double mp; unsigned seed; int isDict; } kProbeRows[] = {
            {255, 0.0, 0, 0},     /* idx 64:  matrix row (si=2,mi=0,di=0,mo=0) */
            {4096, 0.9, 0, 0},    /* idx 112: matrix row (si=3,mi=2,di=0,mo=0) */
            {131072, 1.0, 0, 0},  /* idx 248: matrix row (si=7,mi=3,di=0,mo=0) */
            {4096, 0.9, 0, 1},    /* dict idx 270: (4096,0.9,0) */
        };
        static const int probeIdx[4] = {64, 112, 248, 270};
        for (unsigned pi = 0; pi < 4; pi++) {
            size_t n = kProbeRows[pi].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dst = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dst) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kProbeRows[pi].mp, 0.0, kProbeRows[pi].seed);
            int c;
            if (kProbeRows[pi].isDict) {
                LZ4_stream_t* stream = LZ4_createStream();
                if (!stream) { fprintf(stderr, "stream alloc failed\n"); return 1; }
                if (LZ4_loadDict(stream, (const char*)dictBuf, (int)dictSize) != (int)dictSize) {
                    fprintf(stderr, "loadDict failed\n"); return 1;
                }
                c = LZ4_compress_fast_continue(stream, (const char*)buf, (char*)out,
                                               (int)n, bound, 1);
                LZ4_freeStream(stream);
            } else {
                c = LZ4_compress_default((const char*)buf, (char*)out, (int)n, bound);
            }
            if (c == 0) { fprintf(stderr, "probe: compress failed\n"); return 1; }
            int targets[5] = {0, 1, (int)(n / 2), (int)(n - 1), (int)n};
            for (unsigned ti = 0; ti < 5; ti++) {
                int t = targets[ti];
                memset(dst, 0, n ? n : 1);
                int r = kProbeRows[pi].isDict
                    ? LZ4_decompress_safe_partial_usingDict((const char*)out, (char*)dst,
                                                            c, t, (int)n,
                                                            (const char*)dictBuf, (int)dictSize)
                    : LZ4_decompress_safe_partial((const char*)out, (char*)dst,
                                                  c, t, (int)n);
                if (r > t || r > (int)n) {
                    fprintf(stderr, "probe: ret %d exceeds target %d\n", r, t);
                    return 1;
                }
                if (r > 0 && memcmp(dst, buf, (size_t)r) != 0) {
                    fprintf(stderr, "probe: prefix mismatch row=%d target=%d\n",
                            probeIdx[pi], t);
                    return 1;
                }
                fprintf(stderr, "%s row=%d n=%zu target=%d ret=%d\n",
                        kProbeRows[pi].isDict ? "partialdict" : "partial",
                        probeIdx[pi], n, t, r);
            }
            if (kProbeRows[pi].isDict) {
                memset(dst, 0, n ? n : 1);
                int r = LZ4_decompress_safe((const char*)out, (char*)dst, c, (int)n);
                fprintf(stderr, "partialnodict row=%d n=%zu ret=%d\n",
                        probeIdx[pi], n, r);
            }
            free(buf);
            free(out);
            free(dst);
        }
        free(dictBuf);
    }
    fprintf(stderr, "cases=%d\n", idx);
    return 0;
}
