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
//         LZ4_compress_fast_extState_fastReset; M3b Task 1) => 310 rows.
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
// - artifact name = 3-digit sequential row index in manifest order (000..299)
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
    fprintf(stderr, "cases=%d\n", idx);
    return 0;
}
