/* large_probe.c - M7 Task 4 provenance probe. Design 8.2 final matrix row:
   ">256KB inputs: runtime datagen, roundtrip + C-side hash comparison only,
   NOT persisted" - C pins size/consumed/XXH32/XXH64 of each compression so
   the Cangjie runtime test (src/large_test.cj) can assert byte-level
   fidelity without corpus artifacts.
   Inputs (RDG, same generator sequence as Cangjie datagen.cj):
     L_A = RDG(300000, 0.50, 0.0, 4242)
     L_B = RDG(1048576, 0.90, 0.0, 5353)
     L_C = RDG(327680, 0.00, 0.0, 6464)   (incompressible)
     L_D = RDG(1048576, 1.00, 0.0, 7575)  (ultra-compressible)
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
          probes/large_probe.c $HOME/lz4/tests/datagen.c \
          $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/lz4frame.c \
          $HOME/lz4/lib/xxhash.c -o probes/large_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "lz4hc.h"
#include "lz4frame.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

static unsigned char* mkbuf(size_t n, double mp, unsigned seed) {
    unsigned char* b = (unsigned char*)malloc(n);
    RDG_genBuffer(b, n, mp, 0.0, seed);
    return b;
}

static void pin1(const char* label, const unsigned char* src, size_t n) {
    size_t cap = (size_t)LZ4_compressBound((int)n) + 16;
    unsigned char* out = (unsigned char*)malloc(cap);
    int c = LZ4_compress_default((const char*)src, (char*)out, (int)n, (int)cap);
    printf("%s c=%d xxh32=%08x xxh64=%016llx\n", label, c,
           XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0));
    free(out);
}

static void pinFast(const char* label, const unsigned char* src, size_t n) {
    size_t cap = (size_t)LZ4_compressBound((int)n) + 16;
    unsigned char* out = (unsigned char*)malloc(cap);
    int c = LZ4_compress_fast((const char*)src, (char*)out, (int)n, (int)cap, 8);
    printf("%s c=%d xxh32=%08x xxh64=%016llx\n", label, c,
           XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0));
    free(out);
}

static void pinDest(const char* label, const unsigned char* src, size_t n, int tg) {
    unsigned char* out = (unsigned char*)malloc((size_t)tg);
    LZ4_streamHC_t* st = LZ4_createStreamHC();
    int srcSize = (int)n;
    int c = LZ4_compress_HC_destSize((void*)st, (const char*)src, (char*)out, &srcSize, tg, 9);
    printf("%s c=%d consumed=%d xxh32=%08x xxh64=%016llx\n", label, c, srcSize,
           XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0));
    LZ4_freeStreamHC(st); free(out);
}

static void pinHC(const char* label, const unsigned char* src, size_t n, int lv, int fav) {
    size_t cap = (size_t)LZ4_compressBound((int)n) + 16;
    unsigned char* out = (unsigned char*)malloc(cap);
    int c;
    if (fav) {
        LZ4_streamHC_t* st = LZ4_createStreamHC();
        LZ4_resetStreamHC(st, lv);
        LZ4_favorDecompressionSpeed(st, 1);
        c = LZ4_compress_HC_continue(st, (const char*)src, (char*)out, (int)n, (int)cap);
        LZ4_freeStreamHC(st);
    } else {
        c = LZ4_compress_HC((const char*)src, (char*)out, (int)n, (int)cap, lv);
    }
    printf("%s c=%d xxh32=%08x xxh64=%016llx\n", label, c,
           XXH32(out, (size_t)c, 0), (unsigned long long)XXH64(out, (size_t)c, 0));
    free(out);
}

static void pinHCcont(const char* label, const unsigned char* src, size_t n, size_t blk, int lv) {
    size_t cap = (size_t)LZ4_compressBound((int)blk) + 16;
    unsigned char* out = (unsigned char*)malloc(cap);
    LZ4_streamHC_t* st = LZ4_createStreamHC();
    LZ4_resetStreamHC(st, lv);
    size_t off = 0;
    XXH32_state_t* xs = XXH32_createState();
    XXH32_reset(xs, 0);
    while (off < n) {
        size_t k = (n - off < blk) ? n - off : blk;
        int c = LZ4_compress_HC_continue(st, (const char*)(src + off), (char*)out, (int)k, (int)cap);
        if (c <= 0) { printf("%s FAILED at off=%zu\n", label, off); return; }
        XXH32_update(xs, out, (size_t)c);
        off += k;
    }
    printf("%s blocks=%zu xxh32=%08x\n", label, (n + blk - 1) / blk,
           XXH32_digest(xs));
    XXH32_freeState(xs);
    free(out); LZ4_freeStreamHC(st);
}

static void pinFrame(const char* label, const unsigned char* src, size_t n,
                     int bs, int bm, int ccs, int bcs, int csz, int did, int lv, int af) {
    LZ4F_preferences_t prefs;
    memset(&prefs, 0, sizeof(prefs));
    prefs.frameInfo.blockSizeID = (LZ4F_blockSizeID_t)bs;
    prefs.frameInfo.blockMode = (LZ4F_blockMode_t)bm;
    prefs.frameInfo.contentChecksumFlag = (LZ4F_contentChecksum_t)ccs;
    prefs.frameInfo.blockChecksumFlag = (LZ4F_blockChecksum_t)bcs;
    if (csz) prefs.frameInfo.contentSize = n;
    prefs.frameInfo.dictID = (unsigned)did;
    prefs.compressionLevel = lv;
    prefs.autoFlush = (unsigned)af;
    size_t cap = LZ4F_compressFrameBound(n, &prefs);
    unsigned char* out = (unsigned char*)malloc(cap);
    LZ4F_cctx* cctx = NULL;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx, LZ4F_VERSION))) abort();
    size_t c = LZ4F_compressFrame_usingCDict(cctx, (char*)out, cap,
                (const char*)src, n, NULL, &prefs);
    LZ4F_freeCompressionContext(cctx);
    if (LZ4F_isError(c)) { printf("%s ERROR %s\n", label, LZ4F_getErrorName(c)); free(out); return; }
    printf("%s c=%zu xxh32=%08x xxh64=%016llx\n", label, c,
           XXH32(out, c, 0), (unsigned long long)XXH64(out, c, 0));
    free(out);
}

/* 流式 af=0 长链:Begin + Update(65536×15 + 16384,中途 flush 一次)+ End;
   覆盖 cctx localSaveDict 滞留迁移(tmpIn 越界,L1106-1112) */
static void pinFrameStream(const char* label, const unsigned char* src, size_t n) {
    LZ4F_preferences_t prefs;
    memset(&prefs, 0, sizeof(prefs));
    prefs.frameInfo.blockSizeID = LZ4F_max64KB;
    prefs.frameInfo.blockMode = LZ4F_blockLinked;
    prefs.autoFlush = 0;
    prefs.compressionLevel = 0;
    LZ4F_cctx* cctx;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx, LZ4F_VERSION))) abort();
    size_t cap = LZ4F_compressFrameBound(n, &prefs);
    unsigned char* out = (unsigned char*)malloc(cap);
    size_t pos = LZ4F_compressBegin(cctx, (char*)out, cap, &prefs);
    size_t off = 0;
    while (off < n) {
        size_t k = (n - off < 65536) ? n - off : 65536;
        size_t w = LZ4F_compressUpdate(cctx, (char*)(out + pos), cap - pos,
                                        (const char*)(src + off), k, NULL);
        if (LZ4F_isError(w)) abort();
        pos += w; off += k;
        if (off == 65536 * 8) {   /* mid flush */
            size_t wf = LZ4F_flush(cctx, (char*)(out + pos), cap - pos, NULL);
            if (LZ4F_isError(wf)) abort();
            pos += wf;
        }
    }
    pos += LZ4F_compressEnd(cctx, (char*)(out + pos), cap - pos, NULL);
    printf("%s c=%zu xxh32=%08x xxh64=%016llx\n", label, pos,
           XXH32(out, pos, 0), (unsigned long long)XXH64(out, pos, 0));
    free(out); LZ4F_freeCompressionContext(cctx);
}

int main(void) {
    setbuf(stdout, NULL);
    unsigned char *LA = mkbuf(300000, 0.50, 4242u);
    unsigned char *LB = mkbuf(1048576, 0.90, 5353u);
    unsigned char *LC = mkbuf(327680, 0.00, 6464u);
    unsigned char *LD = mkbuf(1048576, 1.00, 7575u);

    /* block */
    pin1("blk A default", LA, 300000);
    pinFast("blk A fast8", LA, 300000);
    pinDest("blk B dest tg=786432", LB, 1048576, 786432);
    pin1("blk D default", LD, 1048576);
    /* HC */
    pinHC("hc A lv2", LA, 300000, 2, 0);
    pinHC("hc A lv9", LA, 300000, 9, 0);
    pinHC("hc B lv12", LB, 1048576, 12, 0);
    pinHC("hc B lv12 fav", LB, 1048576, 12, 1);
    pinHC("hc D lv9", LD, 1048576, 9, 0);
    pinHCcont("hc B cont lv9 4x262144", LB, 1048576, 262144, 9);
    /* frame one-shot */
    pinFrame("fr A bs4bm0", LA, 300000, 4, 0, 0, 0, 0, 0, 0, 0);
    pinFrame("fr B bs6bm1ccs1bcs1csz", LB, 1048576, 6, 1, 1, 1, 1, 0, 0, 0);
    pinFrame("fr C bs4 lv0", LC, 327680, 4, 0, 0, 0, 0, 0, 0, 0);
    pinFrame("fr D bs7bm0af1", LD, 1048576, 7, 0, 0, 0, 0, 0, 0, 1);
    pinFrame("fr B lv12", LB, 1048576, 4, 0, 0, 0, 0, 0, 12, 0);
    pinFrame("fr A did42ccs1", LA, 300000, 4, 0, 1, 0, 0, 42, 0, 0);
    /* frame streaming long chain (af=0, >192KB -> localSaveDict migration) */
    pinFrameStream("frs B af0 16chunk", LB, 1048576);

    free(LA); free(LB); free(LC); free(LD);
    return 0;
}
