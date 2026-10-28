/* Overlap-shrink differential probe for M3b (provenance of the extra
   differential in stream-c-report.md §5; golden mode=cont only evaluates
   the shrink-branch guard there - the branch body fires solely in this
   probe's pass-2, C-differential-verified but not suite-pinned, ledger
   M7): 7 rolling LZ4_compress_fast_continue
   blocks in one buffer, then a pass-2 block 0 whose source overlaps the
   accumulated dict -> lz4.c L1744-52 dictEnd-overlap shrink branch (not
   golden-pinned; expected pass2 c=20106 xxh32=55883273, standalone decode
   against the 64KB window exact). RDG inputs must match gen_golden.c
   cont-geometry seeds (501/502/503, mp .50/.90/.50).
   M7 pass-3 (same provenance duty for lz4StreamOverlapShrinkTest): a
   fresh stream replays pass-1, then a 4-byte block at 262139 whose end
   lands 1 byte below dictEnd -> shrink computes dictSize=1 -> <4 discard
   arm (lz4.c L1749-50, expected c=5 all-literals, plain safe decode).
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs probes/probe_overlap.c \
          $HOME/lz4/tests/datagen.c $HOME/lz4/lib/lz4.c $HOME/lz4/lib/xxhash.c \
          -o probes/probe_overlap */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);
int main(void) {
    const size_t block = 40960, half = 3*block, tail = 16384;
    unsigned char* buf = (unsigned char*)malloc(2*half+tail);
    unsigned char* out = (unsigned char*)malloc(LZ4_compressBound((int)block)+16);
    RDG_genBuffer(buf, half, 0.50, 0.0, 501);
    RDG_genBuffer(buf+half, half, 0.90, 0.0, 502);
    RDG_genBuffer(buf+2*half, tail, 0.50, 0.0, 503);
    LZ4_stream_t* cs = LZ4_createStream();
    for (int k = 0; k < 7; k++) {
        size_t off0 = (k < 6) ? (size_t)k*block : 2*half;
        size_t n = (k < 6) ? block : tail;
        int c = LZ4_compress_fast_continue(cs, (const char*)(buf+off0), (char*)out, (int)n, LZ4_compressBound((int)block), 1);
        printf("pass1 k=%d c=%d xxh=%08x\n", k, c, XXH32(out, (size_t)c, 0));
    }
    /* pass-2 block 0: source at buf+0 overlaps the accumulated dict -> shrink branch */
    int c = LZ4_compress_fast_continue(cs, (const char*)buf, (char*)out, (int)block, LZ4_compressBound((int)block), 1);
    printf("pass2 k=0 c=%d xxh=%08x\n", c, XXH32(out, (size_t)c, 0));
    /* and decode standalone with the 64KB window for validity */
    unsigned char* d = (unsigned char*)malloc(block);
    unsigned char* win = (unsigned char*)malloc(65536);
    memcpy(win, buf+196608, 65536);
    int r = LZ4_decompress_safe_usingDict((const char*)out, (char*)d, c, (int)block, (const char*)win, 65536);
    printf("decode r=%d eq=%d\n", r, r==(int)block && !memcmp(d, buf, block));

    /* pass-3: fresh stream replays pass-1, then a 4-byte block whose end
       lands 1 byte below dictEnd -> shrink to 1 -> <4 discard to 0 */
    LZ4_stream_t* cs2 = LZ4_createStream();
    for (int k = 0; k < 7; k++) {
        size_t off0 = (k < 6) ? (size_t)k*block : 2*half;
        size_t n = (k < 6) ? block : tail;
        int c1 = LZ4_compress_fast_continue(cs2, (const char*)(buf+off0), (char*)out, (int)n, LZ4_compressBound((int)block), 1);
        if (c1 <= 0) return 1;
    }
    int c3 = LZ4_compress_fast_continue(cs2, (const char*)(buf+262139), (char*)out, 4, LZ4_compressBound((int)block), 1);
    printf("pass3 c=%d xxh=%08x\n", c3, XXH32(out, (size_t)c3, 0));
    unsigned char* d3 = (unsigned char*)malloc(4);
    int r3 = LZ4_decompress_safe((const char*)out, (char*)d3, c3, 4);
    printf("decode3 r=%d eq=%d\n", r3, r3==4 && !memcmp(d3, buf+262139, 4));
    return 0;
}
