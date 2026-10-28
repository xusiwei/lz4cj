/* Context-type swap probe for M7 Task 1 (provenance of
   lz4fCtxTypeSwapTest in src/lz4frame_test.cj): one LZ4F_cctx reused
   across eight alternating frames, walking every cctx-Management reuse
   path of upstream lz4frame.c L722-752 @ 0774d055:
   - swap 1 Begin(lv=0): lz4CtxAlloc 0->1 (malloc LZ4_stream_t)
   - swap 2 Begin(lv=9): lz4CtxAlloc 1->2 (free fast, malloc HC)
   - swap 3 Begin(lv=0): in-place type switch, memory reinterpreted
     as LZ4_stream_t + LZ4_initStream (L746)
   - swap 4 Begin(lv=9): in-place switch back, LZ4_initStreamHC +
     setCompressionLevel (L749); swaps 5-8 repeat the steady
     alternation (the Cangjie port exercises its model-only Some/None
     arms on 3/4/5/6/8, see lz4frame.cj L468-494 deviation note).
   A = RDG(65536,0.50,0), one Update(A,65536) + End per frame, prefs
   linked / bs=4 / raw / af=0. Each reused frame is compared against
   a fresh-cctx same-prefs frame byte-for-byte (state reuse output
   equivalence). Prints size + XXH32 + XXH64 per frame + fresh memcmp.
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs probes/ctx_swap_probe.c \
          $HOME/lz4/lib/lz4frame.c $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c \
          $HOME/lz4/lib/xxhash.c $HOME/lz4/tests/datagen.c -o probes/ctx_swap_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4frame.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

int main(void) {
    size_t n = 65536;
    unsigned char* A = (unsigned char*)malloc(n);
    RDG_genBuffer(A, n, 0.50, 0.0, 0);
    printf("A xxh32=%08x\n", XXH32(A, n, 0));
    size_t cap = LZ4F_compressFrameBound(n, NULL);
    unsigned char* f = (unsigned char*)malloc(cap);       /* reused frames */
    unsigned char* g = (unsigned char*)malloc(cap);       /* fresh frames */
    LZ4F_cctx* cctx = NULL;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx, LZ4F_VERSION))) return 1;
    const int levels[8] = {0, 9, 0, 9, 0, 9, 0, 9};
    for (int k = 0; k < 8; k++) {
        LZ4F_preferences_t p;
        memset(&p, 0, sizeof(p));
        p.compressionLevel = levels[k];
        p.frameInfo.blockMode = LZ4F_blockLinked;
        p.frameInfo.blockSizeID = LZ4F_max64KB;
        size_t pos = 0, r;
        r = LZ4F_compressBegin(cctx, f, cap, &p);
        if (LZ4F_isError(r)) return 2;
        pos += r;
        r = LZ4F_compressUpdate(cctx, f + pos, cap - pos, A, n, NULL);
        if (LZ4F_isError(r)) return 3;
        pos += r;
        r = LZ4F_compressEnd(cctx, f + pos, cap - pos, NULL);
        if (LZ4F_isError(r)) return 4;
        pos += r;
        /* fresh-cctx same-geometry reference frame */
        LZ4F_cctx* fc = NULL;
        if (LZ4F_isError(LZ4F_createCompressionContext(&fc, LZ4F_VERSION))) return 5;
        size_t fpos = 0;
        r = LZ4F_compressBegin(fc, g, cap, &p);
        if (LZ4F_isError(r)) return 6;
        fpos += r;
        r = LZ4F_compressUpdate(fc, g + fpos, cap - fpos, A, n, NULL);
        if (LZ4F_isError(r)) return 7;
        fpos += r;
        r = LZ4F_compressEnd(fc, g + fpos, cap - fpos, NULL);
        if (LZ4F_isError(r)) return 8;
        fpos += r;
        LZ4F_freeCompressionContext(fc);
        printf("swap k=%d lv=%d size=%zu xxh32=%08x xxh64=%016llx fresh=%zu eq=%d\n",
               k, levels[k], pos, XXH32(f, pos, 0),
               (unsigned long long)XXH64(f, pos, 0), fpos,
               (pos == fpos && memcmp(f, g, pos) == 0));
    }
    LZ4F_freeCompressionContext(cctx);
    return 0;
}
