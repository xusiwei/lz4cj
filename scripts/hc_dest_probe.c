/* HC destSize fillOutput-regime probe (M4 Task 2 provenance, committed in
   Task 5 per ledger obligation): pins upstream (0774d055) outputs for
   LZ4_compress_HC_destSize over the construction described by
   HC_DEST_OVERFLOW_REF in src/lz4hc_test.cj: n=8192 = 4096 RDG noise bytes
   (mp=0.0 lp=0.0 seed=0) + 8-byte-period tail (a[i] = 0xAA ^ (i % 8)),
   lv=9, targets tg in {4100, 4123, 4200}:
     tg=4100: first-sequence literal check fails -> _dest_overflow skipped
              -> last-literals fill adaptation: c == tg, consumed < n
     tg=4123: overflow block writes, match clamped to maxMlSize -> c == tg
     tg=4200: sequence fits within the oend hack -> full consumption, bytes
              equal regular lv=9 LZ4_compress_HC output (creg pinned too)
   Build: cc -O2 -DLZ4_STATIC_LINKING_ONLY -I$HOME/lz4/lib -I$HOME/lz4/tests \
          -I$HOME/lz4/programs scripts/hc_dest_probe.c $HOME/lz4/tests/datagen.c \
          $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/xxhash.c \
          -o scripts/hc_dest_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4.h"
#include "lz4hc.h"
#include "xxhash.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

int main(void) {
    const size_t n = 8192;
    unsigned char* a = (unsigned char*)malloc(n);
    RDG_genBuffer(a, 4096, 0.0, 0.0, 0);
    for (size_t i = 4096; i < n; i++) {
        a[i] = (unsigned char)(0xAA ^ (int)(i % 8));
    }
    int bound = LZ4_compressBound((int)n);
    unsigned char* out = (unsigned char*)malloc((size_t)bound);
    unsigned char* dec = (unsigned char*)malloc(n);
    int creg = LZ4_compress_HC((const char*)a, (char*)out, (int)n, bound, 9);
    printf("hcdestprobe: creg=%d xxh32reg=%08x xxh64reg=%016llx\n",
           creg, XXH32(out, (size_t)creg, 0),
           (unsigned long long)XXH64(out, (size_t)creg, 0));
    static const int kTg[3] = { 4100, 4123, 4200 };
    void* hcState = malloc((size_t)LZ4_sizeofStateHC());
    for (int ti = 0; ti < 3; ti++) {
        int tg = kTg[ti];
        int consumed = (int)n;
        int c = LZ4_compress_HC_destSize(hcState, (const char*)a, (char*)out,
                                         &consumed, tg, 9);
        int r = LZ4_decompress_safe((const char*)out, (char*)dec, c, consumed);
        int ok = (r == consumed) && (memcmp(dec, a, (size_t)consumed) == 0);
        printf("hcdestprobe: tg=%d c=%d consumed=%d xxh32=%08x xxh64=%016llx decode-ok=%d\n",
               tg, c, consumed, XXH32(out, (size_t)c, 0),
               (unsigned long long)XXH64(out, (size_t)c, 0), ok);
    }
    free(hcState); free(a); free(out); free(dec);
    return 0;
}
