/* Edge-semantics probe for M3b tests (provenance of lz4StreamingEdgeTest in
   src/lz4_test.cj): pin upstream (0774d055) return values and post-state for
   LZ4_compress_fast_continue / LZ4_saveDict / LZ4_loadDict /
   LZ4_attach_dictionary / LZ4_compress_destSize_extState edge cases.
   Buffer construction must match the Cangjie test byte-for-byte (RDG via
   upstream tests/datagen.c). Expected values: see the per-case asserts in
   lz4StreamingEdgeTest (tight-continue 0; saveDict fresh/0/-1 -> 0;
   hist1000 -> 1000 + content; loadDict 7/0 -> 0 after 64KB bump, full reload
   65536; attach-empty dictCtx nil, off=65536, output == plain continue;
   destext state clean after delegation and fill).
   Build: cc -O2 -DLZ4_STATIC_LINKING_ONLY -I$HOME/lz4/lib -I$HOME/lz4/tests \
          -I$HOME/lz4/programs scripts/edge_probe.c $HOME/lz4/tests/datagen.c \
          $HOME/lz4/lib/lz4.c $HOME/lz4/lib/xxhash.c -o scripts/edge_probe
   (LZ4_compress_destSize_extState is declared in lz4.h's
   LZ4_STATIC_LINKING_ONLY section, hence the -D.) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

static unsigned char* mkbuf(size_t n, double mp, unsigned seed) {
    unsigned char* b = (unsigned char*)malloc(n ? n : 1);
    RDG_genBuffer(b, n, mp, 0.0, seed);
    return b;
}

int main(void) {
    /* 1) continue with srcSize=0 */
    {
        LZ4_stream_t* s = LZ4_createStream();
        unsigned char* buf = mkbuf(40960, 0.5, 501);
        int bound = LZ4_compressBound(40960);
        unsigned char* out = malloc(bound);
        int c0 = LZ4_compress_fast_continue(s, (char*)buf, (char*)out, 40960, bound, 1);
        int c1 = LZ4_compress_fast_continue(s, (char*)buf, (char*)out, 0, bound, 1);
        printf("empty-continue: c0=%d c1(empty)=%d off=%u tt=%u dictSize=%u\n",
               c0, c1, s->internal_donotuse.currentOffset,
               s->internal_donotuse.tableType, s->internal_donotuse.dictSize);
        LZ4_freeStream(s); free(buf); free(out);
    }
    /* 2) continue with insufficient dstCapacity */
    {
        LZ4_stream_t* s = LZ4_createStream();
        unsigned char* buf = mkbuf(40960, 0.5, 501);
        unsigned char out[64];
        int c = LZ4_compress_fast_continue(s, (char*)buf, (char*)out, 40960, 64, 1);
        printf("tight-continue: c=%d off=%u tt=%u dictSize=%u\n", c,
               s->internal_donotuse.currentOffset, s->internal_donotuse.tableType,
               s->internal_donotuse.dictSize);
        /* then a good compress on the same stream still works? */
        int bound = LZ4_compressBound(40960);
        unsigned char* out2 = malloc(bound);
        int c2 = LZ4_compress_fast_continue(s, (char*)buf, (char*)out2, 40960, bound, 1);
        printf("after-fail: c2=%d\n", c2);
        LZ4_freeStream(s); free(buf); free(out2);
    }
    /* 3) saveDict edges */
    {
        LZ4_stream_t* s = LZ4_createStream();
        unsigned char safe[65536];
        int r0 = LZ4_saveDict(s, (char*)safe, 65536);          /* fresh stream */
        printf("saveDict fresh: ret=%d dictSize=%u off=%u\n", r0,
               s->internal_donotuse.dictSize, s->internal_donotuse.currentOffset);
        int r1 = LZ4_saveDict(s, (char*)safe, 0);
        printf("saveDict size0: ret=%d dictSize=%u\n", r1, s->internal_donotuse.dictSize);
        int r2 = LZ4_saveDict(s, (char*)safe, -1);
        printf("saveDict size-1: ret=%d dictSize=%u\n", r2, s->internal_donotuse.dictSize);
        LZ4_freeStream(s);
    }
    {
        /* small history: 1000 bytes -> request 65536 returns 1000 */
        LZ4_stream_t* s = LZ4_createStream();
        unsigned char* buf = mkbuf(1000, 0.5, 9);
        int bound = LZ4_compressBound(1000);
        unsigned char* out = malloc(bound);
        unsigned char safe[65536];
        LZ4_compress_fast_continue(s, (char*)buf, (char*)out, 1000, bound, 1);
        int r = LZ4_saveDict(s, (char*)safe, 65536);
        int eq = memcmp(safe, buf, 1000) == 0;
        printf("saveDict hist1000: ret=%d content-eq=%d\n", r, eq);
        LZ4_freeStream(s); free(buf); free(out);
    }
    /* 4) loadDict small/zero */
    {
        LZ4_stream_t* s = LZ4_createStream();
        unsigned char* d = mkbuf(65536, 0.5, 99);
        int r0 = LZ4_loadDict(s, (const char*)d, 7);
        int r1 = LZ4_loadDict(s, (const char*)d, 0);
        printf("loadDict small: ret7=%d ret0=%d off=%u dictSize=%u\n", r0, r1,
               s->internal_donotuse.currentOffset, s->internal_donotuse.dictSize);
        int r2 = LZ4_loadDict(s, (const char*)d, 65536);
        printf("loadDict full after small: ret=%d off=%u\n", r2,
               s->internal_donotuse.currentOffset);
        LZ4_freeStream(s); free(d);
    }
    /* 5) attach empty dict stream -> dictCtx NULL, output == plain continue? */
    {
        unsigned char* buf = mkbuf(255, 0.9, 0);
        int bound = LZ4_compressBound(255);
        unsigned char* o1 = malloc(bound);
        unsigned char* o2 = malloc(bound);
        LZ4_stream_t* a = LZ4_createStream();   /* never loadDict'ed */
        LZ4_stream_t* b = LZ4_createStream();
        LZ4_attach_dictionary(b, a);
        printf("attach-empty: b.off=%u b.dictCtx=%p\n",
               b->internal_donotuse.currentOffset, (void*)b->internal_donotuse.dictCtx);
        int c1 = LZ4_compress_fast_continue(b, (char*)buf, (char*)o1, 255, bound, 1);
        LZ4_stream_t* p = LZ4_createStream();
        int c2 = LZ4_compress_fast_continue(p, (char*)buf, (char*)o2, 255, bound, 1);
        int eq = (c1 == c2) && (memcmp(o1, o2, c1) == 0);
        printf("attach-empty: c1=%d plain=%d eq=%d\n", c1, c2, eq);
        LZ4_freeStream(a); LZ4_freeStream(b); LZ4_freeStream(p);
        free(buf); free(o1); free(o2);
    }
    /* 6) destSize_extState leaves state clean (off=0) after delegation+fill */
    {
        LZ4_stream_t* s = LZ4_createStream();
        unsigned char* buf = mkbuf(4096, 0.0, 801);
        unsigned char* out = malloc(7000);
        int consumed = 4096;
        int c = LZ4_compress_destSize_extState(s, (const char*)buf, (char*)out, &consumed, 6144, 1);
        printf("destext-after: c=%d consumed=%d off=%u tt=%u dictSize=%u\n",
               c, consumed, s->internal_donotuse.currentOffset,
               s->internal_donotuse.tableType, s->internal_donotuse.dictSize);
        consumed = 4096;
        c = LZ4_compress_destSize_extState(s, (const char*)buf, (char*)out, &consumed, 3072, 1);
        printf("destext-after2: c=%d consumed=%d off=%u tt=%u\n",
               c, consumed, s->internal_donotuse.currentOffset,
               s->internal_donotuse.tableType);
        LZ4_freeStream(s); free(buf); free(out);
    }
    return 0;
}
