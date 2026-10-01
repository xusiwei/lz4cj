// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
//
// M2 block-compression golden harness (ground truth for Cangjie Tasks 3/4)
// + M3 decompression extensions: manifest v2 input digests, dict rows and a
// partial probe. Emits corpus/block_golden_ref.txt plus corpus/block/<idx>.lz4
// artifacts.
// + M3 Task 4 streaming-decode extensions: mode=stream (rolling
// LZ4_decompress_safe_continue over K=8 consecutive blocks in one buffer),
// mode=ring (decoder-ring-buffer decode with wraparound), mode=setdict
// (LZ4_setStreamDecode external-dictionary scenarios) => rows 280..299.
//
// Matrix: sizes {0,1,255,4096,65535,65536,65537,131072} x mp {0.0,0.5,0.9,1.0}
//         x lp {0.0} x seeds {0,7}; modes default / fast1 / fast8 / dest
//         (dest target = n*3/4) => 64 inputs x 4 modes = 256 manifest rows,
//         plus 8 tight rows (seed=0, mp cycled, dstCapacity = c-1 => size=0),
//         plus 16 mode=dict rows (see the dict section below) => 280 rows,
//         plus 20 streaming rows (8 stream + 10 ring + 2 setdict) => 300 rows,
//         plus 10 mode=fastreset rows (5 same-stream 2-block scenarios via
//         LZ4_compress_fast_extState_fastReset; M3b Task 1) => 310 rows,
//         plus 46 M3b streaming-compression rows (8 cont + 6 savedict +
//         8 dictfast + 8 dictslow + 4 attach + 6 extdict + 6 destext;
//         M3b Tasks 2-4, see the section comments below) => 356 rows.
// + M4 Task 2 HC rows: mode=hc (LZ4_compress_HC, hash-chain levels 3-9:
//         A=RDG(65536,0.50,0) and B=RDG(65536,0.90,7) x lv 3..9, then lv=9
//         over C=(131072,0.90,0) D=(255,0.50,0) E=(13,0.50,0) F=(0,0.00,0)
//         G=(1,0.00,0) - empty/tiny inputs take the *dst=0 and all-literal
//         paths) => 19 rows, plus mode=hcdest (LZ4_compress_HC_destSize,
//         lv=9 x A, tg=n*3/4) => 1 row => 376 rows.
// + M4 Task 3 mid rows: mode=hc levels 1-2 (lz4mid strategy): A/B x lv 1..2
//         then lv=2 over C..G (same inputs as Task 2; E=13 passes the
//         >=minLength guard - main loop runs, no match, all literals) => 9
//         rows, plus mode=hcdest lv=2 x A (tg=n*3/4) => 1 row => 386 rows.
// + M4 Task 4 optimal rows: mode=hc levels 10-12 (lz4opt strategy,
//         LZ4HC_compress_optimal): lv 10/11/12 x A/B, then lv=12 over C..G
//         (same inputs as Tasks 2-3), plus favor rows fav=1 (fresh heap
//         stream, LZ4_favorDecompressionSpeed(ctx,1) then
//         LZ4_compress_HC_extStateHC_fastReset - the full-init extStateHC
//         variant would wipe the flag; the new fav=1 field marks the row)
//         over lv=10 x A, lv=12 x A, lv=12 x B => 14 rows, plus mode=hcdest
//         lv=10 and lv=12 x A (tg=n*3/4) => 2 rows => 402 rows.
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
// - artifact name = 3-digit sequential row index in manifest order (000..355)
// - a leading '#' comment line (not a data row) precedes the dict rows and
//   records the shared dictionary provenance (params + digests)
//
// Streaming rows (Task 4) extend the line format:
//   n=<n> mp=<mp> seed=<seed> mode=<stream|ring|setdict> seq=<k> [pos=<p> ]size=<c> ret=<r> [pre32=<h32> pre64=<h64> ]xxh32=... inxxh32=... [ file=...]
// - seq= is the 0-based block index within the scenario (directly after mode=)
// - pos= (mode=ring only) is the decode start offset within the ring buffer
//   (the wraparound schedule the Cangjie test must replicate exactly)
// - ret= is the LZ4_decompress_safe_continue return for that block
// - pre32=/pre64= (mode=stream and mode=setdict) digest the cumulative
//   decoded prefix dst[0..pos_after_block), seed 0 - the rolling-buffer
//   content check; ring rows are byte-compared against the regenerated
//   source slices instead (inxxh fields pin those slices)
// - mp/seed describe the RDG buffer the block was sliced from (one buffer per
//   scenario half; see the '#' provenance comments in the manifest)
//
// fastreset rows (M3b Task 1) extend the line format:
//   n=<n> mp=<mp> seed=<seed> mode=fastreset seq=<k> size=<c> xxh32=... inxxh32=...
//       off=<currentOffset> tt=<tableType> [file=...]
// - one LZ4_stream_t per scenario; seq= blocks are consecutive
//   LZ4_compress_fast_extState_fastReset calls over independently generated
//   RDG buffers (each row self-describing: own n/mp/seed, accel=1,
//   dstCapacity=compressBound => notLimited)
// - seq=0 runs on a fresh stream (prepareTable sees clearedTable) => output
//   byte-equal to LZ4_compress_default (regression anchor, hard-verified)
// - seq=1 runs on the dirty table: byU16 reuse (dictSmall candidate
//   rejection) or full reset per LZ4_prepareTable conditions
// - off=/tt= record the post-compress internal state (currentOffset /
//   tableType, read via internal_donotuse): the reuse/reset branch actually
//   taken by the C implementation. NOTE: for this API the compressed OUTPUT
//   is always identical to fresh-state compression (empty/zero hash slots
//   can never yield an accepted candidate in either mode, so dictSmall
//   rejection is output-neutral here); the state fields are what
//   discriminates reuse (off accumulates) from reset (off restarts)
// - blocks are self-contained (stale candidates rejected => offsets never
//   cross block boundaries), verified by standalone LZ4_decompress_safe
//
// M3b streaming-compression rows (Tasks 2-4) extend the line format:
//   n=<n> mp=<mp> seed=<seed> mode=<cont|cont0|savedict|dictfast|dictslow|
//   attach|extdict> [seq=<k> ]size=<c> xxh32=... inxxh32=... off=<currentOffset>
//   tt=<tableType> [file=...]   /   mode=destext tg=<target> size=<c>
//   consumed=<k> xxh32=... inxxh32=... [file=...]
// - seq= (multi-block sections) is the 0-based block index within the
//   scenario; mp/seed describe the RDG region the block was sliced from
// - off=/tt= record the post-call internal state (currentOffset /
//   tableType via internal_donotuse, fastreset pattern) so the Cangjie
//   state model can be pinned (dictSmall vs noDictIssue, table reuse)
// - mode=cont0: LZ4_compress_default(block 0) one-shot anchor. A
//   fresh-stream LZ4_compress_fast_continue compresses byU32 (lz4.c
//   L1721) while default uses byU16 below the 64 KB limit, so the two
//   outputs may legitimately differ; both are recorded as C produces
//   them and the comparison result is printed on stderr
// - mode=destext: LZ4_compress_destSize_extState (lz4.c L1506) with
//   tg= the targetDstSize; target >= compressBound delegates to the
//   extState fast path and leaves *srcSizePtr untouched (consumed = n),
//   target = n*3/4 exercises real fillOutput (consumed <= n)
//
// Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
//          scripts/gen_golden.c $HOME/lz4/tests/datagen.c $HOME/lz4/lib/lz4.c \
//          $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/xxhash.c -o scripts/gen_golden
/* expose the static-linking-only declarations used below
   (LZ4_compress_fast_extState_fastReset, LZ4_compress_destSize_extState) */
#define LZ4_STATIC_LINKING_ONLY
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "lz4hc.h"
#include "xxhash.h"
#include "datagen.h"

static const size_t kSizes[] = {0, 1, 255, 4096, 65535, 65536, 65537, 131072};
static const double kMps[] = {0.0, 0.5, 0.9, 1.0};
static const unsigned kSeeds[] = {0, 7};
static const char* kModes[] = {"default", "fast1", "fast8", "dest"};

/* Task 4 streaming sections: write corpus/block/<idx>.lz4 and (on success)
   print " file=block/<idx>.lz4". Mirrors the inline artifact code above. */
static void writeArtifact(const unsigned char* out, int c, int idx) {
    if (c >= 0 && c <= 65536) {
        char path[64];
        snprintf(path, sizeof(path), "corpus/block/%03d.lz4", idx);
        FILE* f = fopen(path, "wb");
        if (!f || fwrite(out, 1, (size_t)c, f) != (size_t)c) {
            fprintf(stderr, "write %s failed\n", path);
            exit(1);
        }
        fclose(f);
        printf(" file=block/%03d.lz4", idx);
    }
}

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
    /* streaming rows (M3 Task 4): three scenarios exercising
       LZ4_decompress_safe_continue state machine (lz4.c L2650-2720).
       Compression side is always a persistent LZ4_stream_t +
       LZ4_compress_fast_continue over consecutive slices of larger RDG
       buffers, so emitted offsets reference previous slices inside the 64KB
       window; the Cangjie side cannot produce such blocks yet (noDict-only
       compressor), hence golden artifacts.
       Scenario stream: 2 RDG buffers of 4*40960 bytes (mp=0.50 seed=101 /
       mp=0.90 seed=202), sliced into 8 blocks; decode rolls forward through
       one 327680-byte buffer (first call = plain safe; then rolling with
       small prefix (<64KB-1) graduating to withPrefix64k). */
    {
        const size_t kBlock = 40960;
        const unsigned kK = 8;
        const size_t kHalf = kBlock * 4;
        unsigned char* srcs[2];
        unsigned seeds[2] = {101, 202};
        double mps[2] = {0.50, 0.90};
        unsigned char* dst = (unsigned char*)malloc(kBlock * kK);
        if (!dst) { fprintf(stderr, "oom\n"); return 1; }
        for (unsigned h = 0; h < 2; h++) {
            srcs[h] = (unsigned char*)malloc(kHalf);
            if (!srcs[h]) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(srcs[h], kHalf, mps[h], 0.0, seeds[h]);
        }
        printf("# stream=2xRDG(n=163840 block=40960 mp=0.50/0.90 lp=0.00 seed=101/202) "
               "rolling LZ4_decompress_safe_continue into one 327680-byte buffer\n");
        LZ4_stream_t* cs = LZ4_createStream();
        LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
        if (!cs || !sd) { fprintf(stderr, "stream alloc failed\n"); return 1; }
        int bound = LZ4_compressBound((int)kBlock);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        if (!out) { fprintf(stderr, "oom\n"); return 1; }
        size_t pos = 0;
        for (unsigned k = 0; k < kK; k++) {
            const unsigned char* slice = srcs[k / 4] + (k % 4) * kBlock;
            int c = LZ4_compress_fast_continue(cs, (const char*)slice, (char*)out,
                                               (int)kBlock, bound, 1);
            if (c <= 0) { fprintf(stderr, "stream: compress failed k=%u\n", k); return 1; }
            int r = LZ4_decompress_safe_continue(sd, (const char*)out, (char*)(dst + pos),
                                                 c, (int)kBlock);
            if (r != (int)kBlock || memcmp(dst + pos, slice, kBlock) != 0) {
                fprintf(stderr, "stream: decode mismatch k=%u r=%d\n", k, r);
                return 1;
            }
            pos += (size_t)r;
            printf("n=%zu mp=%.2f seed=%u mode=stream seq=%u size=%d ret=%d "
                   "pre32=%08x pre64=%016llx xxh32=%08x xxh64=%016llx "
                   "inxxh32=%08x inxxh64=%016llx",
                   kBlock, mps[k / 4], seeds[k / 4], k, c, r,
                   XXH32(dst, pos, 0), (unsigned long long)XXH64(dst, pos, 0),
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(slice, kBlock, 0), (unsigned long long)XXH64(slice, kBlock, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
        }
        LZ4_freeStream(cs);
        LZ4_freeStreamDecode(sd);
        free(out); free(dst); free(srcs[0]); free(srcs[1]);
    }
    /* Scenario ring: decoder-ring-buffer decode (lz4.h LZ4_decoderRingBufferSize
       contract). One RDG buffer of 10*16384 bytes (mp=0.50 seed=303) sliced
       into 10 blocks; ring sized LZ4_decoderRingBufferSize(16384) = 81934.
       Lap layout: blocks 0-4 fill [0,81920) linearly; block 4 starts at pos
       65536 with prefix 65536 >= 64KB-1 (withPrefix64k); 14 bytes remain
       < 16384 -> block 5 wraps to 0 (prefix becomes extDict, forceExtDict
       instantiation), blocks 6-9 roll again (small prefix + extDict =
       doubleDict). pos= records the exact schedule. */
    {
        const size_t kBlock = 16384;
        const unsigned kK = 10;
        const size_t kTotal = kBlock * kK;
        int ringSize = LZ4_decoderRingBufferSize((int)kBlock);
        if (ringSize != 65536 + 14 + (int)kBlock) {
            fprintf(stderr, "ring: unexpected ring size %d\n", ringSize);
            return 1;
        }
        unsigned char* src = (unsigned char*)malloc(kTotal);
        unsigned char* ring = (unsigned char*)malloc((size_t)ringSize);
        if (!src || !ring) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(src, kTotal, 0.50, 0.0, 303);
        printf("# ring=RDG(n=163840 block=16384 mp=0.50 lp=0.00 seed=303) "
               "ring=%d=decoderRingBufferSize(16384) wrap decode\n", ringSize);
        LZ4_stream_t* cs = LZ4_createStream();
        LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
        if (!cs || !sd) { fprintf(stderr, "ring alloc failed\n"); return 1; }
        int bound = LZ4_compressBound((int)kBlock);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        if (!out) { fprintf(stderr, "oom\n"); return 1; }
        size_t pos = 0;
        for (unsigned k = 0; k < kK; k++) {
            if ((size_t)ringSize - pos < kBlock) { pos = 0; }
            const unsigned char* slice = src + k * kBlock;
            int c = LZ4_compress_fast_continue(cs, (const char*)slice, (char*)out,
                                               (int)kBlock, bound, 1);
            if (c <= 0) { fprintf(stderr, "ring: compress failed k=%u\n", k); return 1; }
            int r = LZ4_decompress_safe_continue(sd, (const char*)out, (char*)(ring + pos),
                                                 c, (int)kBlock);
            if (r != (int)kBlock || memcmp(ring + pos, slice, kBlock) != 0) {
                fprintf(stderr, "ring: decode mismatch k=%u pos=%zu r=%d\n", k, pos, r);
                return 1;
            }
            printf("n=%zu mp=0.50 seed=303 mode=ring seq=%u pos=%zu size=%d ret=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   kBlock, k, pos, c, r,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(slice, kBlock, 0), (unsigned long long)XXH64(slice, kBlock, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            pos += (size_t)r;
        }
        LZ4_freeStream(cs);
        LZ4_freeStreamDecode(sd);
        free(out); free(ring); free(src);
    }
    /* Scenario setdict: LZ4_setStreamDecode external dictionary (lz4.c L2608).
       dict = RDG(65536, mp=0.50, seed=77); source = RDG(81920, mp=0.90,
       seed=88) sliced into 2 blocks. Decode into a FRESH 81920-byte buffer:
       block 0 hits the "buffer switch" branch (prefixEnd=dict end != dest ->
       extDict swap -> forceExtDict); block 1 rolls at dstIdx=40960 with
       extDictSize!=0 and small prefix -> doubleDict. */
    {
        const size_t kDict = 65536;
        const size_t kBlock = 40960;
        const unsigned kK = 2;
        unsigned char* dict = (unsigned char*)malloc(kDict);
        unsigned char* src = (unsigned char*)malloc(kBlock * kK);
        unsigned char* dst = (unsigned char*)malloc(kBlock * kK);
        if (!dict || !src || !dst) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(dict, kDict, 0.50, 0.0, 77);
        RDG_genBuffer(src, kBlock * kK, 0.90, 0.0, 88);
        printf("# setdict=dict=RDG(n=65536 mp=0.50 lp=0.00 seed=77) xxh32=%08x xxh64=%016llx "
               "src=RDG(n=81920 block=40960 mp=0.90 lp=0.00 seed=88) fresh-buffer decode\n",
               XXH32(dict, kDict, 0), (unsigned long long)XXH64(dict, kDict, 0));
        LZ4_stream_t* cs = LZ4_createStream();
        if (!cs) { fprintf(stderr, "setdict alloc failed\n"); return 1; }
        if (LZ4_loadDict(cs, (const char*)dict, (int)kDict) != (int)kDict) {
            fprintf(stderr, "setdict: loadDict failed\n"); return 1;
        }
        LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
        if (!sd) { fprintf(stderr, "setdict alloc failed\n"); return 1; }
        if (!LZ4_setStreamDecode(sd, (const char*)dict, (int)kDict)) {
            fprintf(stderr, "setdict: setStreamDecode failed\n"); return 1;
        }
        int bound = LZ4_compressBound((int)kBlock);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        if (!out) { fprintf(stderr, "oom\n"); return 1; }
        size_t pos = 0;
        for (unsigned k = 0; k < kK; k++) {
            const unsigned char* slice = src + k * kBlock;
            int c = LZ4_compress_fast_continue(cs, (const char*)slice, (char*)out,
                                               (int)kBlock, bound, 1);
            if (c <= 0) { fprintf(stderr, "setdict: compress failed k=%u\n", k); return 1; }
            int r = LZ4_decompress_safe_continue(sd, (const char*)out, (char*)(dst + pos),
                                                 c, (int)kBlock);
            if (r != (int)kBlock || memcmp(dst + pos, slice, kBlock) != 0) {
                fprintf(stderr, "setdict: decode mismatch k=%u r=%d\n", k, r);
                return 1;
            }
            pos += (size_t)r;
            printf("n=%zu mp=0.90 seed=88 mode=setdict seq=%u size=%d ret=%d "
                   "pre32=%08x pre64=%016llx xxh32=%08x xxh64=%016llx "
                   "inxxh32=%08x inxxh64=%016llx",
                   kBlock, k, c, r,
                   XXH32(dst, pos, 0), (unsigned long long)XXH64(dst, pos, 0),
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(slice, kBlock, 0), (unsigned long long)XXH64(slice, kBlock, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
        }
        LZ4_freeStream(cs);
        LZ4_freeStreamDecode(sd);
        free(out); free(dst); free(src); free(dict);
    }
    /* fastreset rows (M3b Task 1): 5 same-stream 2-block scenarios via
       LZ4_compress_fast_extState_fastReset (lz4.c L1423-1459). Scenario
       design vs LZ4_prepareTable reset conditions (lz4.c L893-937):
         s0: 2048 + 2048  -> byU16 reuse (offset 2048 + 2048 < 0xFFFF,
                             both inputs < 4 KB => dirty table + dictSmall)
         s1: 200 + 3000   -> byU16 reuse (tiny first block, different sizes)
         s2: 1024 + 4096  -> byU16 reset via inputSize >= 4 KB
         s3: 40000+40000  -> byU16 reset via currentOffset+inputSize >= 0xFFFF
         s4: 65547+2048   -> byU32 block then byU16 block (tableType switch
                             resets; tableType-mismatch isolation is covered
                             by the Cangjie unit condition table instead)
       Hard invariants checked C-side per row: seq=0 output byte-equals
       LZ4_compress_default on a fresh stream, and every block decodes
       standalone (dictSmall rejects stale candidates => no cross-block
       offsets). */
    {
        static const struct { size_t n; double mp; unsigned seed; } kFastReset[5][2] = {
            {{2048, 0.5, 401}, {2048, 0.9, 402}},
            {{200, 1.0, 403}, {3000, 0.5, 404}},
            {{1024, 0.9, 405}, {4096, 0.0, 406}},
            {{40000, 0.9, 407}, {40000, 0.5, 408}},
            {{65547, 0.9, 409}, {2048, 0.5, 410}},
        };
        for (unsigned s = 0; s < 5; s++) {
            LZ4_stream_t* st = LZ4_createStream();
            if (!st) { fprintf(stderr, "fastreset: alloc failed\n"); return 1; }
            for (unsigned k = 0; k < 2; k++) {
                size_t n = kFastReset[s][k].n;
                unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
                int bound = LZ4_compressBound((int)n);
                unsigned char* out = (unsigned char*)malloc((size_t)bound);
                if (!buf || !out) { fprintf(stderr, "oom\n"); return 1; }
                RDG_genBuffer(buf, n, kFastReset[s][k].mp, 0.0, kFastReset[s][k].seed);
                int c = LZ4_compress_fast_extState_fastReset(st, (const char*)buf,
                                                             (char*)out, (int)n, bound, 1);
                if (c <= 0) {
                    fprintf(stderr, "fastreset: compress failed s=%u k=%u\n", s, k);
                    return 1;
                }
                if (k == 0) {
                    /* regression anchor: fresh-state fastReset == default */
                    unsigned char* ref = (unsigned char*)malloc((size_t)bound);
                    if (!ref) { fprintf(stderr, "oom\n"); return 1; }
                    int cref = LZ4_compress_default((const char*)buf, (char*)ref,
                                                    (int)n, bound);
                    if (cref != c || memcmp(out, ref, (size_t)c) != 0) {
                        fprintf(stderr, "fastreset: seq0 != default s=%u\n", s);
                        return 1;
                    }
                    free(ref);
                }
                /* self-containment: standalone decode must round-trip */
                unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
                if (!dec) { fprintf(stderr, "oom\n"); return 1; }
                int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
                if (r != (int)n || memcmp(dec, buf, n) != 0) {
                    fprintf(stderr, "fastreset: standalone decode failed s=%u k=%u\n", s, k);
                    return 1;
                }
                free(dec);
                printf("n=%zu mp=%.2f seed=%u mode=fastreset seq=%u size=%d "
                       "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx "
                       "off=%u tt=%u",
                       n, kFastReset[s][k].mp, kFastReset[s][k].seed, k, c,
                       XXH32(out, (size_t)c, 0),
                       (unsigned long long)XXH64(out, (size_t)c, 0),
                       XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0),
                       st->internal_donotuse.currentOffset,
                       st->internal_donotuse.tableType);
                writeArtifact(out, c, idx);
                printf("\n");
                idx++;
                free(buf);
                free(out);
            }
            LZ4_freeStream(st);
        }
    }
    /* cont rows (M3b Task 2): same-buffer rolling compression - the upstream
       pattern: one LZ4_stream_t on the stack via LZ4_initStream, then one
       LZ4_compress_fast_continue (accel=1) per block over consecutive slices
       of a single 262144-byte buffer, so every block after the first takes
       prefix mode (withPrefix64k) and dictSize accumulates naturally.
       Buffer geometry (Cangjie replay: regenerate each region in place):
         [0,122880)      RDG(mp=0.50 lp=0.00 seed=501) -> blocks 0-2 (40960)
         [122880,245760) RDG(mp=0.90 lp=0.00 seed=502) -> blocks 3-5 (40960)
         [245760,262144) RDG(mp=0.50 lp=0.00 seed=503) -> block 6 (16384,
                                                          size variation)
       cont0 anchor row: block 0 recompressed with LZ4_compress_default.
       A fresh-stream continue compresses byU32 while default uses byU16
       below the 64 KB limit, so the two outputs may legitimately differ;
       both are recorded as C produces them, comparison result on stderr.
       Hard check: every block rolling-decodes with
       LZ4_decompress_safe_continue at the same offset in a twin dst. */
    {
        const size_t kBlock = 40960;
        const size_t kHalf = 3 * kBlock;
        const size_t kTail = 16384;
        const size_t kBuf = 2 * kHalf + kTail;   /* 262144 */
        unsigned char* buf = (unsigned char*)malloc(kBuf);
        unsigned char* dst = (unsigned char*)malloc(kBuf);
        int bound = LZ4_compressBound((int)kBlock);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        unsigned char* ref = (unsigned char*)malloc((size_t)bound);
        unsigned char* first = (unsigned char*)malloc((size_t)bound);
        if (!buf || !dst || !out || !ref || !first) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(buf, kHalf, 0.50, 0.0, 501);
        RDG_genBuffer(buf + kHalf, kHalf, 0.90, 0.0, 502);
        RDG_genBuffer(buf + 2 * kHalf, kTail, 0.50, 0.0, 503);
        printf("# cont=one 262144-byte buffer: A=[0,122880) RDG(mp=0.50 lp=0.00 seed=501) blocks 0-2 (40960 each) "
               "B=[122880,245760) RDG(mp=0.90 lp=0.00 seed=502) blocks 3-5 (40960 each) "
               "T=[245760,262144) RDG(mp=0.50 lp=0.00 seed=503) block 6 (16384); "
               "stack stream (LZ4_initStream) + LZ4_compress_fast_continue(accel=1) per consecutive block; "
               "row cont0 = LZ4_compress_default(block 0) one-shot anchor\n");
        LZ4_stream_t streamBody;
        LZ4_stream_t* cs = LZ4_initStream(&streamBody, sizeof(streamBody));
        LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
        if (!cs || !sd) { fprintf(stderr, "cont: init failed\n"); return 1; }
        static const double kContMp[7] = {0.50, 0.50, 0.50, 0.90, 0.90, 0.90, 0.50};
        static const unsigned kContSeed[7] = {501, 501, 501, 502, 502, 502, 503};
        int cFirst = 0;
        for (unsigned k = 0; k < 7; k++) {
            size_t off0 = (k < 6) ? (size_t)k * kBlock : 2 * kHalf;
            size_t n = (k < 6) ? kBlock : kTail;
            const unsigned char* slice = buf + off0;
            int c = LZ4_compress_fast_continue(cs, (const char*)slice, (char*)out,
                                               (int)n, bound, 1);
            if (c <= 0) { fprintf(stderr, "cont: compress failed k=%u\n", k); return 1; }
            int r = LZ4_decompress_safe_continue(sd, (const char*)out, (char*)(dst + off0),
                                                 c, (int)n);
            if (r != (int)n || memcmp(dst + off0, slice, n) != 0) {
                fprintf(stderr, "cont: rolling decode mismatch k=%u r=%d\n", k, r);
                return 1;
            }
            if (k == 0) { memcpy(first, out, (size_t)c); cFirst = c; }
            printf("n=%zu mp=%.2f seed=%u mode=cont seq=%u size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx "
                   "off=%u tt=%u",
                   n, kContMp[k], kContSeed[k], k, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(slice, n, 0), (unsigned long long)XXH64(slice, n, 0),
                   cs->internal_donotuse.currentOffset,
                   cs->internal_donotuse.tableType);
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
        }
        /* cont0 anchor: one-shot byU16 default vs the recorded fresh-stream
           continue (byU32) output of block 0 */
        {
            int c0 = LZ4_compress_default((const char*)buf, (char*)ref, (int)kBlock, bound);
            if (c0 <= 0) { fprintf(stderr, "cont0: default compress failed\n"); return 1; }
            int r0 = LZ4_decompress_safe((const char*)ref, (char*)dst, c0, (int)kBlock);
            if (r0 != (int)kBlock || memcmp(dst, buf, kBlock) != 0) {
                fprintf(stderr, "cont0: decode check failed\n"); return 1;
            }
            int eq = (c0 == cFirst) && (memcmp(ref, first, (size_t)c0) == 0);
            fprintf(stderr, "cont0 anchor: fresh-continue(c=%d) vs default(c=%d): %s\n",
                    cFirst, c0, eq ? "equal" : "DIFFER (both recorded as C produces)");
            printf("n=%zu mp=0.50 seed=501 mode=cont0 size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   kBlock, c0,
                   XXH32(ref, (size_t)c0, 0), (unsigned long long)XXH64(ref, (size_t)c0, 0),
                   XXH32(buf, kBlock, 0), (unsigned long long)XXH64(buf, kBlock, 0));
            writeArtifact(ref, c0, idx);
            printf("\n");
            idx++;
        }
        LZ4_freeStreamDecode(sd);
        free(buf); free(dst); free(out); free(ref); free(first);
    }
    /* savedict rows (M3b Task 2): same-buffer rolling as in cont (stack
       stream, one RDG buffer of 6 x 40960 blocks, mp=0.90 seed=601), but
       LZ4_saveDict(stream, safeBuffer, 65536) is called after seq=0 and
       seq=3: the history is copied into safeBuffer and the stream state is
       re-pointed at it, so the following blocks take the extDict path with
       the relocated dictionary, or re-enter prefix mode when the next block
       is contiguous with the last compressed block. C branch schedule
       pinned by off=/tt= (traced against lz4.c L1716-1843):
         seq=0 fresh prefix; saveDict ret=40960 (history-limited)
         seq=1 extDict noDictIssue;  seq=2 prefix dictSmall
         seq=3 prefix noDictIssue (dictSize >= 64 KB); saveDict ret=65536
         seq=4 extDict noDictIssue (full 64 KB relocated dict)
         seq=5 prefix dictSmall
       The decoder never sees the relocation (identical content), so the
       rolling LZ4_decompress_safe_continue check works unchanged. */
    {
        const size_t kBlock = 40960;
        const unsigned kK = 6;
        const size_t kBuf = kBlock * kK;   /* 245760 */
        const size_t kSafe = 65536;
        unsigned char* buf = (unsigned char*)malloc(kBuf);
        unsigned char* safe = (unsigned char*)malloc(kSafe);
        unsigned char* dst = (unsigned char*)malloc(kBuf);
        int bound = LZ4_compressBound((int)kBlock);
        unsigned char* out = (unsigned char*)malloc((size_t)bound);
        if (!buf || !safe || !dst || !out) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(buf, kBuf, 0.90, 0.0, 601);
        printf("# savedict=RDG(n=245760 block=40960 mp=0.90 lp=0.00 seed=601) one buffer; "
               "LZ4_saveDict(safeBuffer,65536) after seq=0 (ret=40960 history-limited) and "
               "seq=3 (ret=65536 64KB-capped) relocates the dictionary; "
               "off=/tt= are post-block values (saveDict preserves them)\n");
        LZ4_stream_t streamBody;
        LZ4_stream_t* cs = LZ4_initStream(&streamBody, sizeof(streamBody));
        LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
        if (!cs || !sd) { fprintf(stderr, "savedict: init failed\n"); return 1; }
        for (unsigned k = 0; k < kK; k++) {
            const unsigned char* slice = buf + (size_t)k * kBlock;
            int c = LZ4_compress_fast_continue(cs, (const char*)slice, (char*)out,
                                               (int)kBlock, bound, 1);
            if (c <= 0) { fprintf(stderr, "savedict: compress failed k=%u\n", k); return 1; }
            int r = LZ4_decompress_safe_continue(sd, (const char*)out,
                                                 (char*)(dst + (size_t)k * kBlock),
                                                 c, (int)kBlock);
            if (r != (int)kBlock || memcmp(dst + (size_t)k * kBlock, slice, kBlock) != 0) {
                fprintf(stderr, "savedict: rolling decode mismatch k=%u r=%d\n", k, r);
                return 1;
            }
            printf("n=%zu mp=0.90 seed=601 mode=savedict seq=%u size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx "
                   "off=%u tt=%u",
                   kBlock, k, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(slice, kBlock, 0), (unsigned long long)XXH64(slice, kBlock, 0),
                   cs->internal_donotuse.currentOffset,
                   cs->internal_donotuse.tableType);
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            if (k == 0 || k == 3) {
                unsigned preDict = cs->internal_donotuse.dictSize;
                int expect = (preDict < kSafe) ? (int)preDict : (int)kSafe;
                int s = LZ4_saveDict(cs, (char*)safe, (int)kSafe);
                fprintf(stderr, "savedict: saveDict after seq=%u ret=%d (pre dictSize=%u)\n",
                        k, s, preDict);
                if (s != expect) {
                    fprintf(stderr, "savedict: ret %d != min(65536, dictSize) %d\n", s, expect);
                    return 1;
                }
            }
        }
        LZ4_freeStreamDecode(sd);
        free(buf); free(safe); free(dst); free(out);
    }
    /* dictfast / dictslow / attach rows (M3b Task 3): the M3 dict buffer
       (RDG 65536, mp=0.50, seed=99 - same provenance as the mode=dict
       rows) drives the loadDict family.
       dictfast/dictslow: per row a fresh stream + LZ4_loadDict vs
       LZ4_loadDictSlow (lz4.c L1596-1665: fast indexes every 3rd position,
       slow adds a second every-position pass favoring dictionary start),
       then LZ4_compress_fast_continue (accel=1): all rows take usingExtDict
       (byU32, noDictIssue, dictSize = 64 KB not < 64 KB), but the two table
       fills produce different tables. NOTE: with inputs generated
       independently of the dictionary (different seeds), real dict matches
       essentially never fire and fast/slow outputs come out identical (C
       truth, first observed generating this corpus) - so the extras include
       (4096,0.50,99): RDG is a streaming generator, hence this input IS the
       dictionary's own first 4096 bytes, real shared content at every
       alignment, where the two fills demonstrably pick different candidates.
       Inputs: 6 of the M3 dict matrix + extras (65537,0.5,3) and
       (4096,0.50,99); (65537,0.5,3) is also a mode=dict row (free
       cross-check: dictfast must equal dict on matching params).
       attach: per row a fresh dictionary stream A (LZ4_loadDict) + fresh
       working stream B + LZ4_attach_dictionary(B, A) (lz4.c L1667-1693:
       bumps B->currentOffset to 64 KB, hangs A as B->dictCtx), then
       continue on B: inputSize <= 4096 -> usingDictCtx (B's own table +
       dictCtx fallback), > 4096 -> the whole dict stream state is copied
       into B and usingExtDict runs (lz4.c L1771-1777). */
    {
        const size_t dictSize = 64 * 1024;
        unsigned char* dictBuf = (unsigned char*)malloc(dictSize);
        if (!dictBuf) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(dictBuf, dictSize, 0.5, 0.0, 99);
        static const struct { size_t n; double mp; unsigned seed; } kDD[] = {
            {255, 0.0, 0}, {255, 0.9, 7}, {4096, 0.0, 7}, {4096, 0.9, 0},
            {65536, 0.0, 0}, {65536, 0.9, 7}, {65537, 0.5, 3}, {4096, 0.5, 99},
        };
        for (unsigned slow = 0; slow < 2; slow++) {
            printf("# %s=dict=RDG(n=65536 mp=0.50 lp=0.00 seed=99) xxh32=%08x xxh64=%016llx "
                   "via LZ4_loadDict%s; per-row fresh stream + LZ4_compress_fast_continue(accel=1); "
                   "off=/tt= post-call state; input seed=99 rows share the dict's own prefix "
                   "(streaming RDG) so the table fills yield different candidates\n",
                   slow ? "dictslow" : "dictfast",
                   XXH32(dictBuf, dictSize, 0),
                   (unsigned long long)XXH64(dictBuf, dictSize, 0),
                   slow ? "Slow" : "");
            for (unsigned di = 0; di < sizeof(kDD) / sizeof(kDD[0]); di++) {
                size_t n = kDD[di].n;
                unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
                int bound = LZ4_compressBound((int)n);
                unsigned char* out = (unsigned char*)malloc((size_t)bound);
                unsigned char* dst = (unsigned char*)malloc(n ? n : 1);
                if (!buf || !out || !dst) { fprintf(stderr, "oom\n"); return 1; }
                RDG_genBuffer(buf, n, kDD[di].mp, 0.0, kDD[di].seed);
                LZ4_stream_t* st = LZ4_createStream();
                if (!st) { fprintf(stderr, "stream alloc failed\n"); return 1; }
                int ld = slow ? LZ4_loadDictSlow(st, (const char*)dictBuf, (int)dictSize)
                              : LZ4_loadDict(st, (const char*)dictBuf, (int)dictSize);
                if (ld != (int)dictSize) {
                    fprintf(stderr, "%s: loadDict returned %d\n", slow ? "dictslow" : "dictfast", ld);
                    return 1;
                }
                int c = LZ4_compress_fast_continue(st, (const char*)buf, (char*)out,
                                                   (int)n, bound, 1);
                if (c <= 0) {
                    fprintf(stderr, "%s: compress failed (n=%zu)\n",
                            slow ? "dictslow" : "dictfast", n);
                    return 1;
                }
                int r = LZ4_decompress_safe_usingDict((const char*)out, (char*)dst,
                                                      c, (int)n,
                                                      (const char*)dictBuf, (int)dictSize);
                if (r != (int)n || memcmp(dst, buf, n) != 0) {
                    fprintf(stderr, "%s: usingDict decode failed (n=%zu r=%d)\n",
                            slow ? "dictslow" : "dictfast", n, r);
                    return 1;
                }
                printf("n=%zu mp=%.2f seed=%u mode=%s size=%d "
                       "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx "
                       "off=%u tt=%u",
                       n, kDD[di].mp, kDD[di].seed, slow ? "dictslow" : "dictfast", c,
                       XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                       XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0),
                       st->internal_donotuse.currentOffset,
                       st->internal_donotuse.tableType);
                writeArtifact(out, c, idx);
                printf("\n");
                idx++;
                LZ4_freeStream(st);
                free(buf); free(out); free(dst);
            }
        }
        /* attach rows */
        printf("# attach=dict=RDG(n=65536 mp=0.50 lp=0.00 seed=99) xxh32=%08x xxh64=%016llx "
               "on dictionary stream A (LZ4_loadDict); per-row fresh working stream B, "
               "LZ4_attach_dictionary(B,A), LZ4_compress_fast_continue(accel=1) on B; "
               "inputSize<=4096 -> usingDictCtx, >4096 -> table-copy usingExtDict\n",
               XXH32(dictBuf, dictSize, 0),
               (unsigned long long)XXH64(dictBuf, dictSize, 0));
        static const struct { size_t n; double mp; unsigned seed; } kAt[] = {
            {255, 0.9, 0}, {4096, 0.0, 7}, {4097, 0.5, 3}, {65536, 0.0, 0},
        };
        for (unsigned di = 0; di < sizeof(kAt) / sizeof(kAt[0]); di++) {
            size_t n = kAt[di].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dst = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dst) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kAt[di].mp, 0.0, kAt[di].seed);
            LZ4_stream_t* dstream = LZ4_createStream();
            LZ4_stream_t* wstream = LZ4_createStream();
            if (!dstream || !wstream) { fprintf(stderr, "stream alloc failed\n"); return 1; }
            if (LZ4_loadDict(dstream, (const char*)dictBuf, (int)dictSize) != (int)dictSize) {
                fprintf(stderr, "attach: loadDict failed\n"); return 1;
            }
            LZ4_attach_dictionary(wstream, dstream);
            int c = LZ4_compress_fast_continue(wstream, (const char*)buf, (char*)out,
                                               (int)n, bound, 1);
            if (c <= 0) { fprintf(stderr, "attach: compress failed (n=%zu)\n", n); return 1; }
            int r = LZ4_decompress_safe_usingDict((const char*)out, (char*)dst,
                                                  c, (int)n,
                                                  (const char*)dictBuf, (int)dictSize);
            if (r != (int)n || memcmp(dst, buf, n) != 0) {
                fprintf(stderr, "attach: usingDict decode failed (n=%zu r=%d)\n", n, r);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=attach size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx "
                   "off=%u tt=%u",
                   n, kAt[di].mp, kAt[di].seed, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0),
                   wstream->internal_donotuse.currentOffset,
                   wstream->internal_donotuse.tableType);
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            LZ4_freeStream(dstream);
            LZ4_freeStream(wstream);
            free(buf); free(out); free(dst);
        }
        free(dictBuf);
    }
    /* extdict rows (M3b Task 3): cross-buffer references forced by twin
       allocations holding identical RDG content; the block source zig-zags
       A/B/A so every block after the first takes usingExtDict with the
       dictionary living in the other allocation (dictEnd never equals
       source). Scenario 0: RDG(122880, mp=0.90, seed=711), 3 blocks of
       40960 (seq 0-2; seq=2 hits dictSmall extDict: post-extDict dictSize
       40960 < currentOffset). Scenario 1: RDG(196608, mp=0.50, seed=712),
       3 blocks of 65536 (seq 3-5; full-64KB noDictIssue extDict).
       Decoder check: rolling LZ4_decompress_safe_continue through one dst
       laid out like the generation (twin content => same bytes). */
    {
        for (unsigned scen = 0; scen < 2; scen++) {
            const size_t kBlock = scen ? 65536 : 40960;
            const size_t kTotal = 3 * kBlock;
            const double mp = scen ? 0.50 : 0.90;
            const unsigned seed = scen ? 712 : 711;
            unsigned char* bufs[2];
            unsigned char* dst = (unsigned char*)malloc(kTotal);
            int bound = LZ4_compressBound((int)kBlock);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            if (!dst || !out) { fprintf(stderr, "oom\n"); return 1; }
            for (unsigned h = 0; h < 2; h++) {
                bufs[h] = (unsigned char*)malloc(kTotal);
                if (!bufs[h]) { fprintf(stderr, "oom\n"); return 1; }
                RDG_genBuffer(bufs[h], kTotal, mp, 0.0, seed);
            }
            if (scen == 0) {
                printf("# extdict=twin buffers with identical RDG content per scenario, "
                       "block source zig-zags A/B/A forcing usingExtDict cross-buffer references: "
                       "scen0=RDG(n=122880 block=40960 mp=0.90 lp=0.00 seed=711) seq=0-2, "
                       "scen1=RDG(n=196608 block=65536 mp=0.50 lp=0.00 seed=712) seq=3-5; "
                       "off=/tt= post-call state\n");
            }
            LZ4_stream_t* cs = LZ4_createStream();
            LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
            if (!cs || !sd) { fprintf(stderr, "extdict: alloc failed\n"); return 1; }
            for (unsigned k = 0; k < 3; k++) {
                const unsigned char* slice = bufs[k % 2] + (size_t)k * kBlock;
                int c = LZ4_compress_fast_continue(cs, (const char*)slice, (char*)out,
                                                   (int)kBlock, bound, 1);
                if (c <= 0) { fprintf(stderr, "extdict: compress failed scen=%u k=%u\n", scen, k); return 1; }
                int r = LZ4_decompress_safe_continue(sd, (const char*)out,
                                                     (char*)(dst + (size_t)k * kBlock),
                                                     c, (int)kBlock);
                if (r != (int)kBlock || memcmp(dst + (size_t)k * kBlock, slice, kBlock) != 0) {
                    fprintf(stderr, "extdict: rolling decode mismatch scen=%u k=%u r=%d\n",
                            scen, k, r);
                    return 1;
                }
                printf("n=%zu mp=%.2f seed=%u mode=extdict seq=%u size=%d "
                       "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx "
                       "off=%u tt=%u",
                       kBlock, mp, seed, scen * 3 + k, c,
                       XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                       XXH32(slice, kBlock, 0), (unsigned long long)XXH64(slice, kBlock, 0),
                       cs->internal_donotuse.currentOffset,
                       cs->internal_donotuse.tableType);
                writeArtifact(out, c, idx);
                printf("\n");
                idx++;
            }
            LZ4_freeStream(cs);
            LZ4_freeStreamDecode(sd);
            free(bufs[0]); free(bufs[1]); free(dst); free(out);
        }
    }
    /* destext rows (M3b Task 4): LZ4_compress_destSize_extState (public
       API, lz4.c L1506) with ONE stream state shared by all rows - the
       wrapper re-initializes the state on exit (L1510); note the internal
       entry initStream (L1492) re-cleans per call, so later-row outputs
       alone would NOT discriminate a skipped exit-clean - the real pin is
       the post-call state assert in the Cangjie test (currentOffset/
       tableType/dict all reset after every row). Per input, two rows:
         tg = n*3/2 >= LZ4_compressBound(n) => delegates to the extState
              fast path, *srcSizePtr is left untouched (consumed = n)
         tg = n*3/4 => real fillOutput (consumed <= n; if the whole input
              compresses below the target, all n bytes are consumed and
              c < tg - recorded as C produces it)
       Inputs (4096,0.00,801) / (65536,0.50,802) / (131072,0.00,803) cover
       byU16 and byU32 fillOutput plus target-reached and input-exhausted
       outcomes. Hard check: each row decodes standalone to exactly
       consumed bytes (fillOutput emits a complete block of the consumed
       prefix). */
    {
        static const struct { size_t n; double mp; unsigned seed; } kDE[] = {
            {4096, 0.00, 801}, {65536, 0.50, 802}, {131072, 0.00, 803},
        };
        printf("# destext=LZ4_compress_destSize_extState(accel=1) one shared stream state; "
               "per input: tg=n*3/2 (>=compressBound => extState delegation, srcSizePtr untouched) "
               "then tg=n*3/4 (fillOutput); consumed= pins *srcSizePtr\n");
        LZ4_stream_t* st = LZ4_createStream();
        if (!st) { fprintf(stderr, "destext: alloc failed\n"); return 1; }
        for (unsigned di = 0; di < sizeof(kDE) / sizeof(kDE[0]); di++) {
            size_t n = kDE[di].n;
            unsigned char* buf = (unsigned char*)malloc(n);
            unsigned char* dst = (unsigned char*)malloc(n);
            int bound = LZ4_compressBound((int)n);
            int tgHi = (int)(n * 3 / 2);
            int tgLo = (int)(n * 3 / 4);
            unsigned char* out = (unsigned char*)malloc((size_t)(tgHi > bound ? tgHi : bound) + 16);
            if (!buf || !dst || !out) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kDE[di].mp, 0.0, kDE[di].seed);
            for (unsigned half = 0; half < 2; half++) {
                int target = half ? tgLo : tgHi;
                int consumed = (int)n;
                int c = LZ4_compress_destSize_extState(st, (const char*)buf, (char*)out,
                                                       &consumed, target, 1);
                if (c <= 0) {
                    fprintf(stderr, "destext: compress failed (n=%zu tg=%d)\n", n, target);
                    return 1;
                }
                if (!half && consumed != (int)n) {
                    fprintf(stderr, "destext: delegation touched srcSizePtr (n=%zu consumed=%d)\n",
                            n, consumed);
                    return 1;
                }
                if (consumed < 0 || (size_t)consumed > n) {
                    fprintf(stderr, "destext: consumed out of range (n=%zu consumed=%d)\n",
                            n, consumed);
                    return 1;
                }
                int r = LZ4_decompress_safe((const char*)out, (char*)dst, c, consumed);
                if (r != consumed || (consumed && memcmp(dst, buf, (size_t)consumed) != 0)) {
                    fprintf(stderr, "destext: decode check failed (n=%zu tg=%d r=%d)\n",
                            n, target, r);
                    return 1;
                }
                printf("n=%zu mp=%.2f seed=%u mode=destext tg=%d size=%d consumed=%d "
                       "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                       n, kDE[di].mp, kDE[di].seed, target, c, consumed,
                       XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                       XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
                writeArtifact(out, c, idx);
                printf("\n");
                idx++;
            }
            free(buf); free(dst); free(out);
        }
        LZ4_freeStream(st);
    }
    /* hc rows (M4 Task 2): LZ4_compress_HC (lz4hc.c L1568) over the
       hash-chain levels 3-9 (levels 1-2 lz4mid / 10-12 optimal are later
       M4 tasks). A and B sweep all levels (nbSearches 4..256; lv=9 also
       flips patternAnalysis on, maxNbAttempts 256 > 128), then lv=9 over
        size-varied inputs C..G: C crosses the 64KB index regime, D/E stay
        below/around LZ4_minLength(13) boundaries (E=13 passes the
        inputSize >= LZ4_minLength guard, so the main loop runs and finds
        no match -> all literals; the all-literals goto fires only at
        n < 13),
        F=0 (empty: generic_internal writes *dst=0, size=1) and G=1 (1-byte
       all-literal block). dstCapacity = compressBound => notLimited.
       Hard check: every row standalone-decodes to the original input. */
    {
        static const struct { size_t n; double mp; unsigned seed; } kHCAB[2] = {
            {65536, 0.50, 0}, {65536, 0.90, 7},
        };
        printf("# hc=LZ4_compress_HC(notLimited) hash-chain levels 3-9: "
               "A=RDG(n=65536 mp=0.50 lp=0.00 seed=0) B=RDG(n=65536 mp=0.90 lp=0.00 seed=7) x lv=3..9; "
               "lv=9 x C=RDG(n=131072 mp=0.90 lp=0.00 seed=0) D=RDG(n=255 mp=0.50 lp=0.00 seed=0) "
               "E=RDG(n=13 mp=0.50 lp=0.00 seed=0) F=RDG(n=0 mp=0.00 lp=0.00 seed=0) "
               "G=RDG(n=1 mp=0.00 lp=0.00 seed=0); every row standalone-decodes\n");
        for (unsigned ab = 0; ab < 2; ab++)
        for (int lv = 3; lv <= 9; lv++) {
            size_t n = kHCAB[ab].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kHCAB[ab].mp, 0.0, kHCAB[ab].seed);
            int c = LZ4_compress_HC((const char*)buf, (char*)out, (int)n, bound, lv);
            if (c <= 0) {
                fprintf(stderr, "hc: compress failed (n=%zu lv=%d)\n", n, lv);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hc: decode check failed (n=%zu lv=%d)\n", n, lv);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=%d size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kHCAB[ab].mp, kHCAB[ab].seed, lv, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
        static const struct { size_t n; double mp; unsigned seed; } kHCE[5] = {
            {131072, 0.90, 0}, {255, 0.50, 0}, {13, 0.50, 0}, {0, 0.00, 0}, {1, 0.00, 0},
        };
        for (unsigned ei = 0; ei < 5; ei++) {
            size_t n = kHCE[ei].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kHCE[ei].mp, 0.0, kHCE[ei].seed);
            int c = LZ4_compress_HC((const char*)buf, (char*)out, (int)n, bound, 9);
            if (c <= 0) {
                fprintf(stderr, "hc: compress failed (n=%zu lv=9)\n", n);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hc: decode check failed (n=%zu lv=9)\n", n);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=9 size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kHCE[ei].mp, kHCE[ei].seed, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
    }
    /* hcdest row (M4 Task 2): LZ4_compress_HC_destSize (lz4hc.c L1587) with
       a heap state (LZ4_sizeofStateHC); lv=9 x A, target = n*3/4 exercises
       the hash-chain fillOutput path (oend hack, _dest_overflow adaptation).
       consumed= pins *srcSizePtr as written by the core. Hard checks:
       size <= tg, consumed in [0, n], and the output decodes to exactly the
       consumed prefix of the input. */
    {
        const size_t n = 65536;
        unsigned char* buf = (unsigned char*)malloc(n);
        int bound = LZ4_compressBound((int)n);
        int tg = (int)(n * 3 / 4);
        unsigned char* out = (unsigned char*)malloc((size_t)(tg > bound ? tg : bound));
        unsigned char* dec = (unsigned char*)malloc(n);
        void* hcState = malloc((size_t)LZ4_sizeofStateHC());
        if (!buf || !out || !dec || !hcState) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(buf, n, 0.50, 0.0, 0);
        int consumed = (int)n;
        int c = LZ4_compress_HC_destSize(hcState, (const char*)buf, (char*)out,
                                         &consumed, tg, 9);
        if (c <= 0 || c > tg || consumed < 0 || (size_t)consumed > n) {
            fprintf(stderr, "hcdest: out of contract (c=%d tg=%d consumed=%d)\n", c, tg, consumed);
            return 1;
        }
        int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, consumed);
        if (r != consumed || (consumed && memcmp(dec, buf, (size_t)consumed) != 0)) {
            fprintf(stderr, "hcdest: decode check failed (c=%d consumed=%d r=%d)\n", c, consumed, r);
            return 1;
        }
        printf("# hcdest=LZ4_compress_HC_destSize(heap state) lv=9 A=RDG(n=65536 mp=0.50 lp=0.00 seed=0) "
               "tg=n*3/4 fillOutput; consumed= pins *srcSizePtr; decode out == src[0..consumed)\n");
        printf("n=%zu mp=0.50 seed=0 mode=hcdest lv=9 tg=%d size=%d consumed=%d "
               "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
               n, tg, c, consumed,
               XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
               XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
        writeArtifact(out, c, idx);
        printf("\n");
        idx++;
        free(buf); free(out); free(dec); free(hcState);
    }
    /* hc mid rows (M4 Task 3): LZ4_compress_HC over the lz4mid levels 1-2
       (lz4hc.c L554-803). Appended after every Task 2 section so all
       existing artifact indices are preserved; the rows join the mode=hc /
       mode=hcdest sections (same inputs as Task 2, no new '#' comments):
       A/B x lv 1..2, then lv=2 over C..G (E=13 passes the >=minLength
       guard - the main loop runs and finds no match -> all literals; the
       all-literals goto fires only at n<13; F=0 via generic sanitization,
       G=1 is a 1-byte all-literal block). Hard check: every row
       standalone-decodes to the original input. */
    {
        static const struct { size_t n; double mp; unsigned seed; } kMidAB[2] = {
            {65536, 0.50, 0}, {65536, 0.90, 7},
        };
        for (unsigned ab = 0; ab < 2; ab++)
        for (int lv = 1; lv <= 2; lv++) {
            size_t n = kMidAB[ab].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kMidAB[ab].mp, 0.0, kMidAB[ab].seed);
            int c = LZ4_compress_HC((const char*)buf, (char*)out, (int)n, bound, lv);
            if (c <= 0) {
                fprintf(stderr, "hcmid: compress failed (n=%zu lv=%d)\n", n, lv);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hcmid: decode check failed (n=%zu lv=%d)\n", n, lv);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=%d size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kMidAB[ab].mp, kMidAB[ab].seed, lv, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
        static const struct { size_t n; double mp; unsigned seed; } kMidE[5] = {
            {131072, 0.90, 0}, {255, 0.50, 0}, {13, 0.50, 0}, {0, 0.00, 0}, {1, 0.00, 0},
        };
        for (unsigned ei = 0; ei < 5; ei++) {
            size_t n = kMidE[ei].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kMidE[ei].mp, 0.0, kMidE[ei].seed);
            int c = LZ4_compress_HC((const char*)buf, (char*)out, (int)n, bound, 2);
            if (c <= 0) {
                fprintf(stderr, "hcmid: compress failed (n=%zu lv=2)\n", n);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hcmid: decode check failed (n=%zu lv=2)\n", n);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=2 size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kMidE[ei].mp, kMidE[ei].seed, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
    }
    /* hcdest mid row (M4 Task 3): LZ4_compress_HC_destSize lv=2 x A,
       tg = n*3/4 - exercises the lz4mid fillOutput path (oend hack,
       _lz4mid_dest_overflow adaptation). consumed= pins *srcSizePtr.
       Hard checks: size <= tg, consumed in [0, n], decode == the consumed
       prefix of the input. */
    {
        const size_t n = 65536;
        unsigned char* buf = (unsigned char*)malloc(n);
        int bound = LZ4_compressBound((int)n);
        int tg = (int)(n * 3 / 4);
        unsigned char* out = (unsigned char*)malloc((size_t)(tg > bound ? tg : bound));
        unsigned char* dec = (unsigned char*)malloc(n);
        void* hcState = malloc((size_t)LZ4_sizeofStateHC());
        if (!buf || !out || !dec || !hcState) { fprintf(stderr, "oom\n"); return 1; }
        RDG_genBuffer(buf, n, 0.50, 0.0, 0);
        int consumed = (int)n;
        int c = LZ4_compress_HC_destSize(hcState, (const char*)buf, (char*)out,
                                         &consumed, tg, 2);
        if (c <= 0 || c > tg || consumed < 0 || (size_t)consumed > n) {
            fprintf(stderr, "hcdestmid: out of contract (c=%d tg=%d consumed=%d)\n", c, tg, consumed);
            return 1;
        }
        int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, consumed);
        if (r != consumed || (consumed && memcmp(dec, buf, (size_t)consumed) != 0)) {
            fprintf(stderr, "hcdestmid: decode check failed (c=%d consumed=%d r=%d)\n", c, consumed, r);
            return 1;
        }
        printf("n=%zu mp=0.50 seed=0 mode=hcdest lv=2 tg=%d size=%d consumed=%d "
               "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
               n, tg, c, consumed,
               XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
               XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
        writeArtifact(out, c, idx);
        printf("\n");
        idx++;
        free(buf); free(out); free(dec); free(hcState);
    }
    /* hc optimal rows (M4 Task 4): LZ4_compress_HC over the optimal-parser
       levels 10-12 (lz4hc.c L1879-2186). Appended after every Task 2/3
       section so all existing artifact indices are preserved; the rows join
       the mode=hc / mode=hcdest sections (no new '#' comments). lv=12 runs
       with fullUpdate=1 (cLevel >= LZ4HC_CLEVEL_MAX) and sufficient_len =
       4095 (targetLength 4096 clamped to LZ4_OPT_NUM-1); lv=10/11 run
       partial with 64/128. C..G pin the length regimes with the opt parser
       (E=13: main loop runs - no match, all literals; F=0 via generic
       sanitization; G=1 single-literal block). Hard check: every row
       standalone-decodes to the original input. */
    {
        static const struct { size_t n; double mp; unsigned seed; } kOptAB[2] = {
            {65536, 0.50, 0}, {65536, 0.90, 7},
        };
        for (int lv = 10; lv <= 12; lv++)
        for (unsigned ab = 0; ab < 2; ab++) {
            size_t n = kOptAB[ab].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kOptAB[ab].mp, 0.0, kOptAB[ab].seed);
            int c = LZ4_compress_HC((const char*)buf, (char*)out, (int)n, bound, lv);
            if (c <= 0) {
                fprintf(stderr, "hcopt: compress failed (n=%zu lv=%d)\n", n, lv);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hcopt: decode check failed (n=%zu lv=%d)\n", n, lv);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=%d size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kOptAB[ab].mp, kOptAB[ab].seed, lv, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
        static const struct { size_t n; double mp; unsigned seed; } kOptE[5] = {
            {131072, 0.90, 0}, {255, 0.50, 0}, {13, 0.50, 0}, {0, 0.00, 0}, {1, 0.00, 0},
        };
        for (unsigned ei = 0; ei < 5; ei++) {
            size_t n = kOptE[ei].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kOptE[ei].mp, 0.0, kOptE[ei].seed);
            int c = LZ4_compress_HC((const char*)buf, (char*)out, (int)n, bound, 12);
            if (c <= 0) {
                fprintf(stderr, "hcopt: compress failed (n=%zu lv=12)\n", n);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hcopt: decode check failed (n=%zu lv=12)\n", n);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=12 size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kOptE[ei].mp, kOptE[ei].seed, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
        /* favor rows (fav=1): fresh heap stream + LZ4_favorDecompressionSpeed
           (upstream L1668-1671) + LZ4_compress_HC_extStateHC_fastReset. The
           full LZ4_compress_HC / LZ4_compress_HC_extStateHC one-shots run
           LZ4_initStreamHC, which zeroes favorDecSpeed; fastReset on the
           clean fresh state preserves the flag. The flag biases match
           lengths (FindLongerMatch truncates len in (18,36] to 18) and the
           price write condition (price <= opt[pos].price - 1). */
        static const struct { size_t n; double mp; unsigned seed; int lv; } kOptFav[3] = {
            {65536, 0.50, 0, 10}, {65536, 0.50, 0, 12}, {65536, 0.90, 7, 12},
        };
        for (unsigned fi = 0; fi < 3; fi++) {
            size_t n = kOptFav[fi].n;
            unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)bound);
            unsigned char* dec = (unsigned char*)malloc(n ? n : 1);
            if (!buf || !out || !dec) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, kOptFav[fi].mp, 0.0, kOptFav[fi].seed);
            LZ4_streamHC_t* hcs = LZ4_createStreamHC();
            if (!hcs) { fprintf(stderr, "hcoptfav: alloc failed\n"); return 1; }
            LZ4_favorDecompressionSpeed(hcs, 1);
            int c = LZ4_compress_HC_extStateHC_fastReset((void*)hcs, (const char*)buf,
                                                         (char*)out, (int)n, bound,
                                                         kOptFav[fi].lv);
            LZ4_freeStreamHC(hcs);
            if (c <= 0) {
                fprintf(stderr, "hcoptfav: compress failed (n=%zu lv=%d)\n",
                        n, kOptFav[fi].lv);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, (int)n);
            if (r != (int)n || memcmp(dec, buf, n) != 0) {
                fprintf(stderr, "hcoptfav: decode check failed (n=%zu lv=%d)\n",
                        n, kOptFav[fi].lv);
                return 1;
            }
            printf("n=%zu mp=%.2f seed=%u mode=hc lv=%d fav=1 size=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kOptFav[fi].mp, kOptFav[fi].seed, kOptFav[fi].lv, c,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec);
        }
    }
    /* hcdest opt rows (M4 Task 4): LZ4_compress_HC_destSize with heap states
       over lv=10 and lv=12 x A, tg = n*3/4 - exercises the optimal-parser
       fillOutput path (oend hack, _dest_overflow adaptation with ovml/ovoff
       propagation from both encode sites). consumed= pins *srcSizePtr.
       Hard checks: size <= tg, consumed in [0, n], decode == the consumed
       prefix of the input. */
    {
        const size_t n = 65536;
        int tg = (int)(n * 3 / 4);
        static const int kOptDestLv[2] = { 10, 12 };
        for (unsigned li = 0; li < 2; li++) {
            unsigned char* buf = (unsigned char*)malloc(n);
            int bound = LZ4_compressBound((int)n);
            unsigned char* out = (unsigned char*)malloc((size_t)(tg > bound ? tg : bound));
            unsigned char* dec = (unsigned char*)malloc(n);
            void* hcState = malloc((size_t)LZ4_sizeofStateHC());
            if (!buf || !out || !dec || !hcState) { fprintf(stderr, "oom\n"); return 1; }
            RDG_genBuffer(buf, n, 0.50, 0.0, 0);
            int consumed = (int)n;
            int c = LZ4_compress_HC_destSize(hcState, (const char*)buf, (char*)out,
                                             &consumed, tg, kOptDestLv[li]);
            if (c <= 0 || c > tg || consumed < 0 || (size_t)consumed > n) {
                fprintf(stderr, "hcdestopt: out of contract (lv=%d c=%d tg=%d consumed=%d)\n",
                        kOptDestLv[li], c, tg, consumed);
                return 1;
            }
            int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, consumed);
            if (r != consumed || (consumed && memcmp(dec, buf, (size_t)consumed) != 0)) {
                fprintf(stderr, "hcdestopt: decode check failed (lv=%d c=%d consumed=%d r=%d)\n",
                        kOptDestLv[li], c, consumed, r);
                return 1;
            }
            printf("n=%zu mp=0.50 seed=0 mode=hcdest lv=%d tg=%d size=%d consumed=%d "
                   "xxh32=%08x xxh64=%016llx inxxh32=%08x inxxh64=%016llx",
                   n, kOptDestLv[li], tg, c, consumed,
                   XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0),
                   XXH32(buf, n, 0), (unsigned long long)XXH64(buf, n, 0));
            writeArtifact(out, c, idx);
            printf("\n");
            idx++;
            free(buf); free(out); free(dec); free(hcState);
        }
    }
    fprintf(stderr, "cases=%d\n", idx);
    return 0;
}
