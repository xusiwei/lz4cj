/* HC streaming edge-semantics probe for M4 Task 5 tests (provenance of
   lz4hcStreamEdgeTest in src/lz4hc_test.cj): pin upstream (0774d055)
   return values, digests and post-state for LZ4_compress_HC_continue /
   LZ4_loadDictHC / LZ4_saveDictHC / LZ4_resetStreamHC_fast edge cases.
   Buffer construction must match the Cangjie test byte-for-byte (RDG via
   upstream tests/datagen.c). Expected values: see the per-case asserts in
   lz4hcStreamEdgeTest (tight-continue 0 + dirty + resetFast recovery ==
   fresh stream; level switch 9->2 mid-stream on the inherited hash-chain
   state; resetStreamHC_fast mid-stream dictLimit shift then continue ==
   fresh stream; overlap-shrink branch when the post-loadDict block lives
   inside the dictionary buffer).
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
          scripts/hc_probe.c $HOME/lz4/tests/datagen.c $HOME/lz4/lib/lz4.c \
          $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/xxhash.c -o scripts/hc_probe
   (LZ4_setCompressionLevel is declared LZ4LIB_STATIC_API under
   LZ4_STATIC_LINKING_ONLY (lz4hc.h ~L363); the lz4hc.h header always
   #define's LZ4_STATIC_LINKING_ONLY when the macro is not yet defined, so
   we forward-declare LZ4_setCompressionLevel explicitly here to avoid
   the header-redefinition warning while keeping the call site clean.) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "lz4hc.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);
/* LZ4_setCompressionLevel is declared LZ4LIB_STATIC_API under
   LZ4_STATIC_LINKING_ONLY (lz4hc.h ~L363); forward-declare it here so the
   call below compiles without dragging the static-linking-only header
   declarations into the global namespace. */
void LZ4_setCompressionLevel(LZ4_streamHC_t* LZ4_streamHCPtr, int compressionLevel);

static unsigned char* mkbuf(size_t n, double mp, unsigned seed) {
    unsigned char* b = (unsigned char*)malloc(n ? n : 1);
    RDG_genBuffer(b, n, mp, 0.0, seed);
    return b;
}

int main(void) {
    const int bound = LZ4_compressBound(16384);
    /* 1) continue with insufficient dstCapacity -> 0 + dirty; recovery via
        resetStreamHC_fast (dirty -> full re-init) == fresh stream output.
        T5 fix-round repair: the tight call gets its OWN output buffer (100
        bytes) — writing it into o0 clobbered c0's stream and made the probe
        fail its own decode check and exit(1) before cases 2-4 could print
        (the earlier xxh0 pins derived from that corrupted o0). Decode checks
        cover only the healthy outputs and are report-only: no exit before
        all four cases print. */
    {
        LZ4_streamHC_t* ctx = LZ4_createStreamHC();
        unsigned char* b0 = mkbuf(16384, 0.5, 901);
        unsigned char* b1 = mkbuf(16384, 0.5, 902);
        unsigned char* o0 = (unsigned char*)malloc(bound);
        unsigned char* o1 = (unsigned char*)malloc(bound);
        unsigned char* o2 = (unsigned char*)malloc(bound);
        unsigned char* oT = (unsigned char*)malloc(100);
        LZ4_resetStreamHC(ctx, 9);
        int c0 = LZ4_compress_HC_continue(ctx, (const char*)b0, (char*)o0, 16384, bound);
        int cT = LZ4_compress_HC_continue(ctx, (const char*)b1, (char*)oT, 16384, 100);
        int dirty = ctx->internal_donotuse.dirty;
        LZ4_resetStreamHC_fast(ctx, 9);
        int cR = LZ4_compress_HC_continue(ctx, (const char*)b1, (char*)o1, 16384, bound);
        LZ4_streamHC_t* fr = LZ4_createStreamHC();
        LZ4_resetStreamHC(fr, 9);
        int cF = LZ4_compress_HC_continue(fr, (const char*)b1, (char*)o2, 16384, bound);
        int eq = (cR == cF) && (memcmp(o1, o2, (size_t)cR) == 0);
        printf("hc-tight: c0=%d xxh0=%08x cTight=%d dirty=%d cRecover=%d xxhR=%08x cFresh=%d eq=%d\n",
               c0, XXH32(o0, (size_t)c0, 0), cT, dirty,
               cR, XXH32(o1, (size_t)cR, 0), cF, eq);
        /* also dump raw compressed bytes for cross-port validation */
        FILE* fp = fopen("/tmp/c_block0.lz4", "wb");
        if (fp) { fwrite(o0, 1, (size_t)c0, fp); fclose(fp); }
        /* decode roundtrip on the healthy outputs only (o0 holds c0's
           intact stream; o1 the recovery stream); report-only */
        unsigned char* dec = (unsigned char*)malloc(16384);
        int dOk = 0;
        int dr = LZ4_decompress_safe((const char*)o0, (char*)dec, c0, 16384);
        if (dr == 16384 && memcmp(dec, b0, 16384) == 0) {
            int dr1 = LZ4_decompress_safe((const char*)o1, (char*)dec, cR, 16384);
            dOk = (dr1 == 16384) && (memcmp(dec, b1, 16384) == 0);
        }
        fprintf(stderr, "hc-tight: decode-ok=%d dr=%d\n", dOk, dr);
        LZ4_freeStreamHC(ctx); LZ4_freeStreamHC(fr);
        free(b0); free(b1); free(o0); free(o1); free(o2); free(oT); free(dec);
    }
    /* 2) setCompressionLevel block switch lv=9 -> 2 mid-stream: the mid
       block continues the hash-chain stream state (contiguous block, no
       re-anchor; stale hc-hash entries act as valid mid candidates) */
    {
        unsigned char* buf = mkbuf(32768, 0.5, 903);
        unsigned char* o1 = (unsigned char*)malloc(bound);
        unsigned char* o2 = (unsigned char*)malloc(bound);
        unsigned char* dst = (unsigned char*)malloc(32768);
        LZ4_streamHC_t* ctx = LZ4_createStreamHC();
        LZ4_streamDecode_t* sd = LZ4_createStreamDecode();
        LZ4_resetStreamHC(ctx, 9);
        int c1 = LZ4_compress_HC_continue(ctx, (const char*)buf, (char*)o1, 16384, bound);
        LZ4_setCompressionLevel(ctx, 2);
        int c2 = LZ4_compress_HC_continue(ctx, (const char*)(buf + 16384), (char*)o2, 16384, bound);
        int r1 = LZ4_decompress_safe_continue(sd, (const char*)o1, (char*)dst, c1, 16384);
        int r2 = LZ4_decompress_safe_continue(sd, (const char*)o2, (char*)(dst + 16384), c2, 16384);
        int ok = (r1 == 16384) && (r2 == 16384) &&
                 memcmp(dst, buf, 32768) == 0;
        printf("hc-lvswitch: c9=%d xxh9=%08x c2=%d xxh2=%08x dl=%u decode-ok=%d\n",
               c1, XXH32(o1, (size_t)c1, 0), c2, XXH32(o2, (size_t)c2, 0),
               ctx->internal_donotuse.dictLimit, ok);
        LZ4_freeStreamHC(ctx); LZ4_freeStreamDecode(sd);
        free(buf); free(o1); free(o2); free(dst);
    }
    /* 3) resetStreamHC_fast mid-stream: dictLimit += prefixLen, tables
       kept; the next continue auto-inits at dictLimit + 64KB, stale chain
       entries fall below lowLimit -> output == fresh stream on block 2 */
    {
        unsigned char* buf = mkbuf(49152, 0.5, 904);
        unsigned char* o1 = (unsigned char*)malloc(bound);
        unsigned char* o2 = (unsigned char*)malloc(bound);
        unsigned char* o3 = (unsigned char*)malloc(bound);
        LZ4_streamHC_t* ctx = LZ4_createStreamHC();
        LZ4_resetStreamHC(ctx, 9);
        LZ4_compress_HC_continue(ctx, (const char*)buf, (char*)o1, 16384, bound);
        LZ4_compress_HC_continue(ctx, (const char*)(buf + 16384), (char*)o2, 16384, bound);
        unsigned dlPre = ctx->internal_donotuse.dictLimit;
        LZ4_resetStreamHC_fast(ctx, 9);
        unsigned dlPost = ctx->internal_donotuse.dictLimit;
        int c2 = LZ4_compress_HC_continue(ctx, (const char*)(buf + 32768), (char*)o3, 16384, bound);
        unsigned dlFinal = ctx->internal_donotuse.dictLimit;
        unsigned llFinal = ctx->internal_donotuse.lowLimit;
        LZ4_streamHC_t* fr = LZ4_createStreamHC();
        LZ4_resetStreamHC(fr, 9);
        unsigned char* o4 = (unsigned char*)malloc(bound);
        int cF = LZ4_compress_HC_continue(fr, (const char*)(buf + 32768), (char*)o4, 16384, bound);
        int eq = (c2 == cF) && (memcmp(o3, o4, (size_t)c2) == 0);
        printf("hc-resetfast: dlPre=%u dlPost=%u c2=%d xxh2=%08x fresh=%d eq=%d dlFinal=%u llFinal=%u\n",
               dlPre, dlPost, c2, XXH32(o3, (size_t)c2, 0), cF, eq, dlFinal, llFinal);
        LZ4_freeStreamHC(ctx); LZ4_freeStreamHC(fr);
        free(buf); free(o1); free(o2); free(o3); free(o4);
    }
    /* 4) overlap-shrink branch: loadDictHC then continue with the block
       INSIDE the dictionary buffer at offset 32768 - setExternalDict makes
       the dict the extDict, then the overlap check shrinks it to
       [49152, 65536) */
    {
        unsigned char* D = mkbuf(65536, 0.5, 905);
        unsigned char* out = (unsigned char*)malloc(bound);
        unsigned char* dst = (unsigned char*)malloc(16384);
        LZ4_streamHC_t* ctx = LZ4_createStreamHC();
        LZ4_resetStreamHC(ctx, 9);
        int ld = LZ4_loadDictHC(ctx, (const char*)D, 65536);
        int c = LZ4_compress_HC_continue(ctx, (const char*)(D + 32768), (char*)out, 16384, bound);
        int r = LZ4_decompress_safe_usingDict((const char*)out, (char*)dst, c, 16384,
                                              (const char*)D, 65536);
        int ok = (r == 16384) && (memcmp(dst, D + 32768, 16384) == 0);
        long long dictStartOff = (long long)(ctx->internal_donotuse.dictStart - D);
        printf("hc-overlap: ld=%d c=%d xxh32=%08x xxh64=%016llx lowLimit=%u dictLimit=%u dictStartOff=%lld decode-ok=%d\n",
               ld, c, XXH32(out, (size_t)c, 0),
               (unsigned long long)XXH64(out, (size_t)c, 0),
               ctx->internal_donotuse.lowLimit, ctx->internal_donotuse.dictLimit,
               dictStartOff, ok);
        LZ4_freeStreamHC(ctx);
        free(D); free(out); free(dst);
    }
    return 0;
}
