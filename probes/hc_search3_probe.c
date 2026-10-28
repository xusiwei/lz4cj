/* hc_search3_probe.c - M7 Task 2 provenance probe. Pins C (upstream
   0774d055) outputs for the hard-to-reach HC geometries the suite pins:
   (a) three representative _Search3 sweep combos (hashChain lv=9, the only
   level with patternAnalysis since nbAttempts must be > 128),
   (b) fillOutput clamp combos (giant match + tiny target),
   (c) overlap-shrink pair on one 64B buffer (in-place dict -> shrink
   discard <4; separate-allocation dict control -> dict kept),
   (d) optimal-parser literal repricing families.
   All inputs are built by deterministic LCG/pattern arithmetic shared
   verbatim with src/lz4hc_test.cj (hcSweepBuild/hcRepriceBuild) except
   (e) which uses RDG_genBuffer.
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
          probes/hc_search3_probe.c $HOME/lz4/tests/datagen.c \
          $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/xxhash.c \
          -o probes/hc_search3_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "lz4hc.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

static unsigned lcgByte(unsigned long long* x) {
    *x = (*x * 1103515245ULL + 12345ULL) & 0xFFFFFFFFULL;
    return (unsigned)((*x >> 16) & 0xFF);
}
static unsigned pat(unsigned j, unsigned m, unsigned c) { return (j * m + c) & 0xFF; }

#define N 65536

/* sweep family kinds 0..8 (shared with hcSweepBuild in lz4hc_test.cj) */
static void buildSweep(unsigned char* b, int kind) {
    unsigned long long x;
    int i;
    switch (kind) {
    case 0: case 1: case 2: case 3: {           /* F1(p): period + sparse mutation */
        int p = (kind == 0) ? 5 : (kind == 1) ? 17 : (kind == 2) ? 63 : 255;
        for (i = 0; i < N; i++) {
            b[i] = (unsigned char)pat(i % p, 113, 29);
            if (i % 97 == 13) b[i] = (unsigned char)pat(i / 97, 151, 7);
        }
        break;
    }
    case 4:                                      /* F2: dual-period 512B segments */
        for (i = 0; i < N; i++)
            b[i] = (unsigned char)(((i >> 9) % 2 == 0) ? pat(i % 13, 61, 11)
                                                       : pat(i % 29, 181, 77));
        break;
    case 5: case 6: case 7: {                    /* F3(L,p): leading literals + period */
        int L = (kind == 5) ? 1 : (kind == 6) ? 5 : 33;
        x = 777ULL;
        for (i = 0; i < N; i++) {
            if (i < L) b[i] = (unsigned char)lcgByte(&x);
            else b[i] = (unsigned char)pat(i % 17, 113, 29);
        }
        break;
    }
    default: {                                   /* F4: three-tier */
        x = 888ULL;
        for (i = 0; i < 64; i++) b[i] = (unsigned char)lcgByte(&x);
        x = 889ULL;
        for (i = 64; i < 128; i++) b[i] = (unsigned char)lcgByte(&x);
        memcpy(b + 128, b, 64);
        memcpy(b + 192, b + 64, 64);
        for (i = 256; i < N; i++) b[i] = (unsigned char)pat((i - 256) % 7, 197, 3);
        break;
    }
    }
}

/* repricing families 0..2 (shared with hcRepriceBuild) */
static void buildReprice(unsigned char* b, int kind) {
    int i;
    unsigned long long x;
    if (kind == 0) {                             /* rand | period11 | rand | period11+3 */
        x = 1001ULL;
        for (i = 0; i < 64; i++) b[i] = (unsigned char)lcgByte(&x);
        for (i = 64; i < 32768; i++) b[i] = (unsigned char)pat(i % 11, 113, 29);
        x = 1002ULL;
        for (i = 32768; i < 32968; i++) b[i] = (unsigned char)lcgByte(&x);
        for (i = 32968; i < N; i++) b[i] = (unsigned char)pat((i + 3) % 11, 113, 29);
    } else if (kind == 1) {                      /* literal runs 1..7 + short matches (256B head) */
        int pos = 256, seg = 0;
        x = 1500ULL;
        for (i = 0; i < 256; i++) b[i] = (unsigned char)lcgByte(&x);
        while (pos < N) {
            int k = (seg % 7) + 1;
            x = 1003ULL + (unsigned long long)seg;
            for (i = 0; i < k && pos < N; i++, pos++) b[pos] = (unsigned char)lcgByte(&x);
            if (pos >= N) break;
            {   int ml = 5 + (seg % 3);
                int srcBack = 64 + (seg % 32);
                for (i = 0; i < ml && pos < N; i++, pos++)
                    b[pos] = b[pos - srcBack];
            }
            seg++;
        }
    } else if (kind == 3) {                      /* runs 1..40 + fixed 8B matches (256B head) */
        int pos = 256, seg = 0;
        x = 1500ULL;
        for (i = 0; i < 256; i++) b[i] = (unsigned char)lcgByte(&x);
        while (pos < N) {
            int L = 1 + (seg % 40);
            x = 2000ULL + (unsigned long long)seg;
            for (i = 0; i < L && pos < N; i++, pos++) b[pos] = (unsigned char)lcgByte(&x);
            if (pos >= N) break;
            for (i = 0; i < 8 && pos < N; i++, pos++)
                b[pos] = b[pos - (64 + (seg % 16))];
            seg++;
        }
    } else {                                     /* RDG(65536, 0.85, 0, 777) */
        RDG_genBuffer(b, N, 0.85, 0.0, 777u);
    }
}

static void pinDest(const char* label, const unsigned char* b, int n, int lv, int tg) {
    unsigned char* out = (unsigned char*)malloc((size_t)tg);
    LZ4_streamHC_t* st = LZ4_createStreamHC();
    int srcSize = n;   /* in/out: consumed */
    int c = LZ4_compress_HC_destSize((void*)st, (const char*)b, (char*)out,
                                     &srcSize, tg, lv);
    printf("%s c=%d consumed=%d xxh32=%08x\n", label, c, srcSize,
           XXH32(out, (size_t)c, 0));
    free(out); LZ4_freeStreamHC(st);
}

int main(void) {
    unsigned char* b = (unsigned char*)malloc(N);
    unsigned char* out = (unsigned char*)malloc(N + 1024);
    int i;

    /* (a) sweep combos: kind / lv=9 / tg = fraction of c0 */
    {   int kinds[3] = {1, 4, 8}; int frac[3] = {4, 2, 4}; int mult[3] = {1, 1, 3};
        for (i = 0; i < 3; i++) {
            int c0;
            char label[64];
            buildSweep(b, kinds[i]);
            c0 = LZ4_compress_HC((const char*)b, (char*)out, N, N + 1024, 9);
            snprintf(label, sizeof label, "sweep kind=%d c0=%d", kinds[i], c0);
            printf("%s\n", label);
            pinDest("  combo", b, N, 9, c0 * mult[i] / frac[i]);
        }
    }

    /* (b) clamps */
    {   unsigned char* big = (unsigned char*)malloc(131072);
        memset(big, 0, 131072);
        pinDest("clamp zeros lv=2 tg=100", big, 131072, 2, 100);
        pinDest("clamp zeros lv=4 tg=100", big, 131072, 4, 100);
        pinDest("clamp zeros lv=9 tg=100", big, 131072, 9, 100);
        for (i = 0; i < 131072; i++) big[i] = (unsigned char)pat(i % 4, 113, 29);
        pinDest("clamp per4 lv=4 tg=128", big, 131072, 4, 128);
        free(big);
    }

    /* (c) overlap-shrink pair on one 64B buffer */
    {   unsigned char sbuf[64];
        unsigned char dict8[8];
        unsigned char src2[64];
        unsigned long long x = 999ULL;
        LZ4_streamHC_t* s;
        int c;
        for (i = 0; i < 64; i++) sbuf[i] = (unsigned char)lcgByte(&x);
        memcpy(dict8, sbuf, 8);
        memcpy(src2, sbuf, 64);

        s = LZ4_createStreamHC();
        LZ4_resetStreamHC(s, 9);
        LZ4_loadDictHC(s, (const char*)sbuf, 8);
        c = LZ4_compress_HC_continue(s, (const char*)(sbuf + 6), (char*)out, 50, 1024);
        printf("overlap inplace c=%d xxh32=%08x\n", c, XXH32(out, (size_t)c, 0));

        s = LZ4_createStreamHC();
        LZ4_resetStreamHC(s, 9);
        LZ4_loadDictHC(s, (const char*)dict8, 8);
        c = LZ4_compress_HC_continue(s, (const char*)(src2 + 6), (char*)out, 50, 1024);
        printf("overlap sepdst c=%d xxh32=%08x\n", c, XXH32(out, (size_t)c, 0));
    }

    /* (d) repricing families at opt levels */
    for (i = 0; i < 3; i++) {
        int lv;
        char label[48];
        buildReprice(b, i);
        for (lv = 10; lv <= 12; lv++) {
            int c = LZ4_compress_HC((const char*)b, (char*)out, N, N + 1024, lv);
            snprintf(label, sizeof label, "reprice kind=%d lv=%d", i, lv);
            printf("%s c=%d xxh32=%08x\n", label, c, XXH32(out, (size_t)c, 0));
        }
    }

    free(b); free(out);
    return 0;
}
