/* lz4file probe for M9: pin upstream (0774d055) lz4file.c behavior as the
   ground truth for src/lz4file_test.cj parity tests:
   (1) write variants: RDG(200000,.50,42) compressed via LZ4F_writeOpen/
       write/writeClose with 4 prefs variants, written in 3 odd chunks
       (100000+65537+34463); prints file size + XXH32(file bytes) per
       variant. Cangjie LZ4F_write* must produce byte-identical files
       (same Begin + blockSize-chunked Update + End sequence).
   (2) read-back: each file re-read via LZ4F_readOpen/read(997-chunks)/
       readClose; prints size + XXH32(content).
    (3) error pins: 10-byte file readOpen -> io_read; 0xDEADBEEF magic ->
        propagated code; invalid writeOpen blockSizeID=2 -> upstream C
        UNEXPECTEDLY SUCCEEDS (measured e badbs: 0): getBlockSize(2) =
        (size_t)-2 wraps past the ==0 guard, compressBound wraps to a
        small capacity, file gets an invalid BD=0x20 frame header
        (04 22 4d 18 40 20 ad). Cangjie deviation #5: blockSize <= 0
        early exit -> -LZ4F_ERROR_maxBlockSize_invalid (-2), rejecting
        the size_t-wrap-dependent config, stricter than upstream.
   (4) truncated-frame partial read: keep first 65549 bytes of variant-0
       frame; read -> partial byte count (EOF break).
   (5) skippable-prefixed frame: 8B skippable header (size 4) + 4 filler
       bytes + variant-0 frame at offset 12; readOpen OK, full content
       read back (dctx recycles to next frame).
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
          probes/lz4file_probe.c $HOME/lz4/lib/lz4frame.c $HOME/lz4/lib/lz4file.c \
          $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/xxhash.c \
          $HOME/lz4/tests/datagen.c -o probes/lz4file_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4frame.h"
#include "lz4file.h"
#define XXH_STATIC_LINKING_ONLY
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

#define N 200000

static unsigned char* rdg(size_t n, double mp, unsigned seed) {
    unsigned char* b = (unsigned char*)malloc(n ? n : 1);
    RDG_genBuffer(b, n, mp, 0.0, seed);
    return b;
}

static void wr(FILE* f, const void* p, size_t n) {
    if (fwrite(p, 1, n, f) != n) { fprintf(stderr, "short write\n"); exit(1); }
}

static void pinWriteVariant(const char* tag, const unsigned char* in,
                            const LZ4F_preferences_t* prefs) {
    char name[64];
    snprintf(name, sizeof(name), "/tmp/lz4file_probe_%s.lz4", tag);
    FILE* f = fopen(name, "wb");
    LZ4_writeFile_t* w = NULL;
    size_t r = LZ4F_writeOpen(&w, f, prefs);
    if (LZ4F_isError(r)) { fprintf(stderr, "%s writeOpen err\n", tag); exit(1); }
    /* 3 odd chunks: 100000 + 65537 + 34463 = 200000 */
    if (LZ4F_write(w, in, 100000) != 100000) { fprintf(stderr, "w1\n"); exit(1); }
    if (LZ4F_write(w, in + 100000, 65537) != 65537) { fprintf(stderr, "w2\n"); exit(1); }
    if (LZ4F_write(w, in + 165537, 34463) != 34463) { fprintf(stderr, "w3\n"); exit(1); }
    r = LZ4F_writeClose(w);
    if (LZ4F_isError(r)) { fprintf(stderr, "%s close err\n", tag); exit(1); }
    fclose(f);
    /* file digest */
    FILE* g = fopen(name, "rb");
    static unsigned char buf[1 << 21];
    size_t fsz = fread(buf, 1, sizeof(buf), g);
    fclose(g);
    printf("w %s: size=%zu xxh=%08x\n", tag, fsz, XXH32(buf, fsz, 0));
    /* read-back */
    FILE* h = fopen(name, "rb");
    LZ4_readFile_t* rd = NULL;
    r = LZ4F_readOpen(&rd, h);
    if (LZ4F_isError(r)) { fprintf(stderr, "%s readOpen err\n", tag); exit(1); }
    static unsigned char out[N];
    size_t got = 0, c;
    while (got < N && (c = LZ4F_read(rd, out + got, 997)) > 0) got += c;
    printf("r %s: got=%zu xxh=%08x\n", tag, got, XXH32(out, got, 0));
    LZ4F_readClose(rd);
    fclose(h);
}

int main(void) {
    unsigned char* in = rdg(N, 0.50, 42);

    LZ4F_preferences_t p0; memset(&p0, 0, sizeof(p0));                 /* default */
    pinWriteVariant("def", in, NULL);
    pinWriteVariant("p0", in, &p0);

    LZ4F_preferences_t p1; memset(&p1, 0, sizeof(p1));
    p1.frameInfo.blockSizeID = LZ4F_max4MB;
    p1.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled;
    pinWriteVariant("4mb", in, &p1);

    LZ4F_preferences_t p2; memset(&p2, 0, sizeof(p2));
    p2.frameInfo.blockSizeID = LZ4F_max1MB;
    p2.frameInfo.blockChecksumFlag = LZ4F_blockChecksumEnabled;
    p2.compressionLevel = 3;
    pinWriteVariant("1mb", in, &p2);

    LZ4F_preferences_t p3; memset(&p3, 0, sizeof(p3));
    p3.frameInfo.blockSizeID = LZ4F_max256KB;
    p3.frameInfo.blockMode = LZ4F_blockIndependent;
    p3.compressionLevel = 9;
    pinWriteVariant("bi9", in, &p3);

    /* (3) error pins */
    { FILE* f = fopen("/tmp/lz4file_probe_short.bin", "wb");
      static unsigned char ten[10] = {0};
      wr(f, ten, 10); fclose(f);
      FILE* g = fopen("/tmp/lz4file_probe_short.bin", "rb");
      LZ4_readFile_t* rd = NULL;
      printf("e short: %lld\n", (long long)LZ4F_readOpen(&rd, g));
      fclose(g); }
    { FILE* f = fopen("/tmp/lz4file_probe_magic.bin", "wb");
      static unsigned char eleven[11] = {0xDE,0xAD,0xBE,0xEF};
      wr(f, eleven, 11); fclose(f);
      FILE* g = fopen("/tmp/lz4file_probe_magic.bin", "rb");
      LZ4_readFile_t* rd = NULL;
      printf("e magic: %lld\n", (long long)LZ4F_readOpen(&rd, g));
      fclose(g); }
    { FILE* f = fopen("/tmp/lz4file_probe_badbs.lz4", "wb");
      LZ4F_preferences_t bad; memset(&bad, 0, sizeof(bad));
      bad.frameInfo.blockSizeID = (LZ4F_blockSizeID_t)2;
      LZ4_writeFile_t* w = NULL;
      printf("e badbs: %lld\n", (long long)LZ4F_writeOpen(&w, f, &bad));
      fclose(f); }

    /* (4) truncated partial read */
    { static unsigned char frame[1 << 21];
      FILE* f = fopen("/tmp/lz4file_probe_def.lz4", "rb");
      size_t fsz = fread(frame, 1, sizeof(frame), f);
      fclose(f);
      const size_t cut = 7 + 4 + 65536 + 2;
      FILE* t = fopen("/tmp/lz4file_probe_trunc.lz4", "wb");
      wr(t, frame, cut); fclose(t);
      FILE* g = fopen("/tmp/lz4file_probe_trunc.lz4", "rb");
      LZ4_readFile_t* rd = NULL;
      size_t r = LZ4F_readOpen(&rd, g);
      if (LZ4F_isError(r)) { fprintf(stderr, "trunc open err\n"); exit(1); }
      static unsigned char out[N];
      size_t got = LZ4F_read(rd, out, N);
      printf("e trunc: got=%zu xxh=%08x\n", got, XXH32(out, got, 0));
      LZ4F_readClose(rd);
      fclose(g); }

    /* (5) skippable-prefixed */
    { static unsigned char frame[1 << 21];
      FILE* f = fopen("/tmp/lz4file_probe_def.lz4", "rb");
      size_t fsz = fread(frame, 1, sizeof(frame), f);
      fclose(f);
      static unsigned char all[1 << 21];
      unsigned char skip[12] = {0x50, 0x2A, 0x4D, 0x18, 4, 0, 0, 0, 0, 0, 0, 0};
      memcpy(all, skip, 12);
      memcpy(all + 12, frame, fsz);
      FILE* t = fopen("/tmp/lz4file_probe_skip.lz4", "wb");
      wr(t, all, 12 + fsz); fclose(t);
      FILE* g = fopen("/tmp/lz4file_probe_skip.lz4", "rb");
      LZ4_readFile_t* rd = NULL;
      size_t r = LZ4F_readOpen(&rd, g);
      printf("e skipopen: %lld\n", (long long)r);
      static unsigned char out[N];
      size_t got = 0, c;
      while (got < N && (c = LZ4F_read(rd, out + got, 997)) > 0) got += c;
      printf("e skipread: got=%zu xxh=%08x\n", got, XXH32(out, got, 0));
      LZ4F_readClose(rd);
      fclose(g); }

    printf("input: xxh=%08x\n", XXH32(in, N, 0));
    free(in);
    return 0;
}
