// C-side reference: adversarial LZ4_compress_destSize probe for Cangjie
// cross-validation (provenance of DEST_REDUCTION_REF in src/lz4_test.cj).
// Constant / periodic / LCG buffers with small targets force the
// matchCode-reduction (lz4.c L1198-1216), which the n*3/4-target corpus
// rows of gen_golden.c never reach (mp=0.0 finds no matches; mp>=0.5
// compresses below target). The rewind hash-clearing sub-path inside it
// (L1204-1215, taken when the shortened match rewinds past filledIp) is
// NOT reached by these inputs; see CHANGELOG M2 coverage note.
// Buffer construction must match destProbeBuffer() in src/lz4_test.cj
// byte-for-byte. Emits Cangjie tuple rows (kind, n, target, size, consumed,
// xxh32, xxh64) and a stderr case count (expect 125).
// Build: cc -O2 -I$HOME/lz4/lib scripts/dest_probe.c $HOME/lz4/lib/lz4.c \
//        $HOME/lz4/lib/xxhash.c -o scripts/dest_probe
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "lz4.h"
#include "xxhash.h"

static unsigned char* makeBuffer(int kind, int n) {
    unsigned char* b = (unsigned char*)malloc((size_t)n);
    if (kind == 0) {                     /* constant 'A' */
        for (int i = 0; i < n; i++) b[i] = 65;
        return b;
    }
    if (kind == 1) {                     /* periodic */
        for (int i = 0; i < n; i++) b[i] = (unsigned char)(i % 7);
        return b;
    }
    if (kind == 2) {                     /* LCG seed 1 */
        uint32_t s = 1;
        for (int i = 0; i < n; i++) {
            s = s * 1103515245u + 12345u;
            b[i] = (unsigned char)(s >> 16);
        }
        return b;
    }
    uint32_t s = 42;                     /* LCG seed 42, 7/8 bias to 120 */
    for (int i = 0; i < n; i++) {
        s = s * 1103515245u + 12345u;
        b[i] = ((s >> 24) & 7) ? 120 : (unsigned char)(s >> 16);
    }
    return b;
}

int main(void) {
    /* (kind, n, target step, case count): target = 7 + step * i */
    const int kinds[]  = {0, 1, 2, 3};
    const int ns[]     = {4096, 1000, 300, 5000};
    const int steps[]  = {13, 7, 7, 7};
    const int counts[] = {23, 28, 17, 57};
    int cases = 0;
    for (unsigned k = 0; k < 4; k++) {
        unsigned char* buf = makeBuffer(kinds[k], ns[k]);
        unsigned char* out = (unsigned char*)malloc(8192);
        for (int i = 0; i < counts[k]; i++) {
            int target = 7 + steps[k] * i;
            int consumed = ns[k];        /* caller-preset, C failure contract */
            int c = LZ4_compress_destSize((const char*)buf, (char*)out,
                                          &consumed, target);
            printf("    (%d, %d, %d, %d, %d, 0x%08xu32, 0x%016llxu64),\n",
                   kinds[k], ns[k], target, c, consumed,
                   XXH32(out, (size_t)c, 0),
                   (unsigned long long)XXH64(out, (size_t)c, 0));
            cases++;
        }
        free(buf);
        free(out);
    }
    fprintf(stderr, "cases=%d\n", cases);
    return 0;
}
