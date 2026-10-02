/* Frame-decode dictionary-prefix probe for the M6 final-review fix
   (provenance of lz4fDictPrefixedOutputTest / lz4fContentEqualSwitchTest /
   lz4fDifferingSwitchControlTest in src/lz4frame_test.cj): pin upstream
   (0774d055) return triples and digests for the three geometries that
   discriminate C's pointer-adjacency `dict + dictSize == dstPtr` from a
   content-window predicate:
   (a) dict-prefixed output: frame = Begin_usingDict(D=RDG(65536,.50,0)) +
       Update(A=RDG(131072,.50,1)) + End (linked, lv=0); B[0..65536)=copy of
       D, decode at B+65536 via decompress_usingDict(same D) — numerically
       adjacent + content-equal but DIFFERENT allocations; C returns 0 and
       byte-exact A (extDict on D for block 1, >=64KB-in-dst rebase for
       block 2); the retired content predicate extended dictSize on the
       foreign dict array and crashed with IndexOutOfBoundsException.
   (b) content-equal buffer switch under stableDst: 3-block linked frame
       (RDG(196608,.50,2)); call 1 decodes block 1 into buffer1, call 2
       decodes block 2 into buffer2 whose [0,65536) is a copy of buffer1's
       output (the documented stableDst pledge geometry, lz4frame.h:374);
       C keeps dict pointing at buffer1 (pointer compare false across
       allocations) -> extDict instantiation reads the OLD buffer.
   (c) differing-content switch control: 2-block linked frame
       (RDG(95536,.50,3)); buffer3[0,65536) filled with 0xA5 sentinel ->
       adjacency numeric but neither identity nor content match -> join
       branch (dict tail + dst merged into tmpOutBuffer), success.
   Buffer construction must match the Cangjie tests byte-for-byte (RDG via
   upstream tests/datagen.c). Expected values: see the pinned constants in
   the three tests above.
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs scripts/frame_decode_probe.c \
          $HOME/lz4/lib/lz4frame.c $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c \
          $HOME/lz4/lib/xxhash.c $HOME/lz4/tests/datagen.c -o scripts/frame_decode_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4frame.h"
#define XXH_STATIC_LINKING_ONLY
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

static unsigned char* rdg(size_t n, double mp, unsigned seed) {
    unsigned char* b = (unsigned char*)malloc(n ? n : 1);
    RDG_genBuffer(b, n, mp, 0.0, seed);
    return b;
}

static unsigned rdle32(const unsigned char* p) {
    return (unsigned)p[0] | ((unsigned)p[1] << 8) | ((unsigned)p[2] << 16) | ((unsigned)p[3] << 24);
}

int main(void) {
    /* ---- (a) dict-prefixed output ---- */
    size_t n = 131072, dd = 65536;
    unsigned char* A = rdg(n, 0.50, 1);
    unsigned char* D = rdg(dd, 0.50, 0);
    printf("a: xxh A=%08x xxh D=%08x\n", XXH32(A, n, 0), XXH32(D, dd, 0));
    LZ4F_preferences_t p;
    memset(&p, 0, sizeof(p));
    p.compressionLevel = 0;
    p.frameInfo.blockMode = LZ4F_blockLinked;
    size_t cap = LZ4F_compressFrameBound(n, &p);
    unsigned char* f = malloc(cap);
    LZ4F_cctx* cctx = NULL;
    size_t pos = 0, r;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx, LZ4F_VERSION))) return 1;
    r = LZ4F_compressBegin_usingDict(cctx, f, cap, D, dd, &p);
    if (LZ4F_isError(r)) return 2;
    pos += r;
    r = LZ4F_compressUpdate(cctx, f + pos, cap - pos, A, n, NULL);
    if (LZ4F_isError(r)) return 3;
    pos += r;
    r = LZ4F_compressEnd(cctx, f + pos, cap - pos, NULL);
    if (LZ4F_isError(r)) return 4;
    pos += r;
    LZ4F_freeCompressionContext(cctx);
    printf("a: frame size=%zu\n", pos);

    unsigned char* B = malloc(dd + n);
    memcpy(B, D, dd);
    LZ4F_dctx* dctx = NULL;
    if (LZ4F_isError(LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION))) return 5;
    size_t ssz = pos, dsz = n;
    r = LZ4F_decompress_usingDict(dctx, B + dd, &dsz, f, &ssz, D, dd, NULL);
    printf("a: prefixed r=%zd consumed=%zu/%zu written=%zu/%zu outxxh=%08x (expect 0, %zu, %zu, %08x)\n",
           (ssize_t)r, ssz, pos, dsz, n, XXH32(B + dd, n, 0), pos, n, XXH32(A, n, 0));
    if (r != 0 || ssz != pos || dsz != n) { printf("a: FAILED\n"); return 6; }
    if (memcmp(B + dd, A, n) != 0) { printf("a: BYTES DIFFER\n"); return 7; }
    LZ4F_freeDecompressionContext(dctx);
    printf("a: OK - dict-prefixed output decodes byte-exact\n");

    /* ---- (b) content-equal buffer switch under stableDst ---- */
    size_t n2 = 196608;
    unsigned char* A2 = rdg(n2, 0.50, 2);
    printf("b: xxh A2=%08x xxh A2tail=%08x\n", XXH32(A2, n2, 0), XXH32(A2 + 65536, 131072, 0));
    size_t cap2 = LZ4F_compressFrameBound(n2, &p);
    unsigned char* f2 = malloc(cap2);
    LZ4F_cctx* cctx2 = NULL;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx2, LZ4F_VERSION))) return 11;
    size_t pos2 = 0;
    r = LZ4F_compressBegin(cctx2, f2, cap2, &p);
    if (LZ4F_isError(r)) return 12;
    pos2 += r;
    r = LZ4F_compressUpdate(cctx2, f2 + pos2, cap2 - pos2, A2, n2, NULL);
    if (LZ4F_isError(r)) return 13;
    pos2 += r;
    r = LZ4F_compressEnd(cctx2, f2 + pos2, cap2 - pos2, NULL);
    if (LZ4F_isError(r)) return 14;
    pos2 += r;
    LZ4F_freeCompressionContext(cctx2);
    size_t cb1 = rdle32(f2 + 7) & 0x7FFFFFFFu;
    printf("b: frame size=%zu cb1=%zu\n", pos2, cb1);
    if (rdle32(f2 + 7) & 0x80000000u) { printf("b: block1 unexpectedly raw\n"); return 15; }

    LZ4F_decompressOptions_t opt;
    memset(&opt, 0, sizeof(opt));
    opt.stableDst = 1;
    unsigned char* buf1 = malloc(65536);
    LZ4F_dctx* dctx2 = NULL;
    if (LZ4F_isError(LZ4F_createDecompressionContext(&dctx2, LZ4F_VERSION))) return 16;
    size_t s1 = 11 + cb1, d1 = 65536;
    r = LZ4F_decompress(dctx2, buf1, &d1, f2, &s1, &opt);
    printf("b: call1 r=%zd consumed=%zu/%zu written=%zu/%zu buf1xxh=%08x\n",
           (ssize_t)r, s1, 11 + cb1, d1, (size_t)65536, XXH32(buf1, 65536, 0));
    if (LZ4F_isError(r) || s1 != 11 + cb1 || d1 != 65536 ||
        memcmp(buf1, A2, 65536) != 0) { printf("b: call1 FAILED\n"); return 17; }

    unsigned char* buf2 = malloc(65536 + 131072);
    memcpy(buf2, buf1, 65536);   /* pledge: last 64KB of decoded data right before dst */
    size_t cb2 = rdle32(f2 + 11 + cb1) & 0x7FFFFFFFu;
    size_t s2 = 4 + cb2, d2c = 65536;
    r = LZ4F_decompress(dctx2, buf2 + 65536, &d2c, f2 + 11 + cb1, &s2, &opt);
    printf("b: call2 r=%zd consumed=%zu/%zu written=%zu/%zu\n",
           (ssize_t)r, s2, 4 + cb2, d2c, (size_t)65536);
    if (LZ4F_isError(r) || s2 != 4 + cb2 || d2c != 65536) { printf("b: call2 FAILED\n"); return 18; }
    size_t s3 = pos2 - 11 - cb1 - 4 - cb2, d3 = 65536;
    r = LZ4F_decompress(dctx2, buf2 + 131072, &d3, f2 + 11 + cb1 + 4 + cb2, &s3, &opt);
    printf("b: call3 r=%zd consumed=%zu/%zu written=%zu/%zu outxxh=%08x (expect 0, %zu, 65536, %08x)\n",
           (ssize_t)r, s3, pos2 - 11 - cb1 - 4 - cb2, d3, (size_t)65536,
           XXH32(buf2 + 65536, 131072, 0), pos2 - 11 - cb1 - 4 - cb2, XXH32(A2 + 65536, 131072, 0));
    if (r != 0 || s3 != pos2 - 11 - cb1 - 4 - cb2 || d3 != 65536 ||
        memcmp(buf2 + 65536, A2 + 65536, 131072) != 0) { printf("b: FAILED\n"); return 19; }
    LZ4F_freeDecompressionContext(dctx2);
    printf("b: OK - content-equal switch reads OLD buffer, byte-exact\n");

    /* ---- (c) differing-content switch control ---- */
    size_t n3 = 95536;
    unsigned char* A3 = rdg(n3, 0.50, 3);
    printf("c: xxh A3=%08x xxh A3tail=%08x\n", XXH32(A3, n3, 0), XXH32(A3 + 65536, 30000, 0));
    size_t cap3 = LZ4F_compressFrameBound(n3, &p);
    unsigned char* f3 = malloc(cap3);
    LZ4F_cctx* cctx3 = NULL;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx3, LZ4F_VERSION))) return 21;
    size_t pos3 = 0;
    r = LZ4F_compressBegin(cctx3, f3, cap3, &p);
    if (LZ4F_isError(r)) return 22;
    pos3 += r;
    r = LZ4F_compressUpdate(cctx3, f3 + pos3, cap3 - pos3, A3, n3, NULL);
    if (LZ4F_isError(r)) return 23;
    pos3 += r;
    r = LZ4F_compressEnd(cctx3, f3 + pos3, cap3 - pos3, NULL);
    if (LZ4F_isError(r)) return 24;
    pos3 += r;
    LZ4F_freeCompressionContext(cctx3);
    size_t cb1c = rdle32(f3 + 7) & 0x7FFFFFFFu;
    size_t cb2c = rdle32(f3 + 11 + cb1c) & 0x7FFFFFFFu;
    printf("c: frame size=%zu cb1=%zu cb2=%zu\n", pos3, cb1c, cb2c);

    unsigned char* buf1c = malloc(65536);
    LZ4F_dctx* dctx3 = NULL;
    if (LZ4F_isError(LZ4F_createDecompressionContext(&dctx3, LZ4F_VERSION))) return 25;
    size_t sc1 = 11 + cb1c, dc1 = 65536;
    r = LZ4F_decompress(dctx3, buf1c, &dc1, f3, &sc1, &opt);
    printf("c: call1 r=%zd consumed=%zu/%zu written=%zu/%zu\n",
           (ssize_t)r, sc1, 11 + cb1c, dc1, (size_t)65536);
    if (LZ4F_isError(r) || sc1 != 11 + cb1c || dc1 != 65536 ||
        memcmp(buf1c, A3, 65536) != 0) { printf("c: call1 FAILED\n"); return 26; }

    unsigned char* buf3 = malloc(131072);
    memset(buf3, 0xA5, 65536);   /* differing content at the adjacent window */
    size_t sc2 = 4 + cb2c, dc2 = 65536;
    r = LZ4F_decompress(dctx3, buf3 + 65536, &dc2, f3 + 11 + cb1c, &sc2, &opt);
    printf("c: call2 r=%zd consumed=%zu/%zu written=%zu/%zu\n",
           (ssize_t)r, sc2, 4 + cb2c, dc2, (size_t)30000);
    if (LZ4F_isError(r) || sc2 != 4 + cb2c || dc2 != 30000) { printf("c: call2 FAILED\n"); return 27; }
    LZ4F_decompressOptions_t nopt;
    memset(&nopt, 0, sizeof(nopt));
    size_t sc3 = 4, dc3 = 35536;
    r = LZ4F_decompress(dctx3, buf3 + 95536, &dc3, f3 + 11 + cb1c + 4 + cb2c, &sc3, &nopt);
    printf("c: call3 r=%zd consumed=%zu/4 written=%zu/0 outxxh=%08x (expect 0, %08x)\n",
           (ssize_t)r, sc3, dc3, XXH32(buf3 + 65536, 30000, 0), XXH32(A3 + 65536, 30000, 0));
    if (r != 0 || sc3 != 4 || dc3 != 0 ||
        memcmp(buf3 + 65536, A3 + 65536, 30000) != 0) { printf("c: FAILED\n"); return 28; }
    for (size_t i = 0; i < 65536; i++) {
        if (buf3[i] != 0xA5) { printf("c: SENTINEL CLOBBERED at %zu\n", i); return 29; }
    }
    LZ4F_freeDecompressionContext(dctx3);
    printf("c: OK - differing-content switch joins into tmp, byte-exact\n");
    return 0;
}
