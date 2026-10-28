// C-side reference: generate datagen corpus digests for Cangjie cross-validation.
// Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
//        probes/datagen_ref.c $HOME/lz4/tests/datagen.c $HOME/lz4/lib/xxhash.c \
//        -o probes/datagen_ref
#include <stdio.h>
#include <stdlib.h>
#include "xxhash.h"
#include "datagen.h"

int main(void) {
    const size_t sizes[] = {0, 1, 255, 4096, 65536, 1 << 20};
    const double mps[] = {0.0, 0.5, 0.9, 1.0};
    const double lps[] = {0.0, 0.1};
    const unsigned seeds[] = {0, 1, 7, 63104};
    for (unsigned si = 0; si < sizeof(sizes)/sizeof(sizes[0]); si++)
    for (unsigned mi = 0; mi < 4; mi++)
    for (unsigned li = 0; li < 2; li++)
    for (unsigned di = 0; di < 4; di++) {
        size_t n = sizes[si];
        /* upstream RDG_genBlock writes buffPtr[0] even when buffSize==0;
           allocate >=1 byte so the write lands; XXH over 0 bytes ignores it */
        unsigned char* buf = (unsigned char*)malloc(n ? n : 1);
        RDG_genBuffer(buf, n, mps[mi], lps[li], seeds[di]);
        printf("n=%zu mp=%.2f lp=%.2f seed=%u xxh32=%08x xxh64=%016llx\n",
               n, mps[mi], lps[li], seeds[di],
               XXH32(buf, n, 0),
               (unsigned long long)XXH64(buf, n, 0));
        free(buf);
    }
    return 0;
}
