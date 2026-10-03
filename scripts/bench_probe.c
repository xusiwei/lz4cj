/* bench_probe.c - M7 Task 5 C counterpart of src/bench_test.cj. Same RDG
   inputs, same ops, best-of-3 MB/s; used for the Cangjie-vs-C throughput
   ratio table (fast-decompress 0.85x re-evaluation, ledger item). LZ4_decompress_fast
   is C-only and serves as the upstream baseline for the wildCopy loop.
   Build: cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
          scripts/bench_probe.c $HOME/lz4/tests/datagen.c \
          $HOME/lz4/lib/lz4.c $HOME/lz4/lib/lz4hc.c $HOME/lz4/lib/lz4frame.c \
          $HOME/lz4/lib/xxhash.c -o scripts/bench_probe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "lz4.h"
#include "lz4hc.h"
#include "lz4frame.h"
extern void RDG_genBuffer(void* buffer, size_t size, double matchProba, double litProba, unsigned seed);

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static double best3(void (*fn)(void*), void* ctx, size_t bytes) {
    double best = 1e30;
    for (int i = 0; i < 3; i++) {
        double t0 = now_sec();
        fn(ctx);
        double dt = now_sec() - t0;
        if (dt < best) best = dt;
    }
    return (double)bytes / best / (1024.0 * 1024.0);
}

typedef struct { unsigned char* src; unsigned char* comp; unsigned char* dec; int n, c; } BCtx;

static void op_compress_default(void* v) { BCtx* x = v; LZ4_compress_default((const char*)x->src, (char*)x->comp, x->n, x->c); }
static void op_decompress_safe(void* v)  { BCtx* x = v; if (LZ4_decompress_safe((const char*)x->comp, (char*)x->dec, x->c, x->n) != x->n) abort(); }

typedef struct { unsigned char* src; unsigned char* comp; int n; size_t cap, c; int lv; } HCtx;
static void op_hc(void* v) { HCtx* x = v; int r = LZ4_compress_HC((const char*)x->src, (char*)x->comp, x->n, (int)x->cap, x->lv); if (r <= 0) abort(); }

typedef struct { unsigned char* src; unsigned char* comp; unsigned char* dec; size_t n, cap, c; } FCtx;
static void op_frame_c(void* v) {
    FCtx* x = v;
    LZ4F_preferences_t prefs; memset(&prefs, 0, sizeof(prefs));
    x->c = LZ4F_compressFrame((char*)x->comp, x->cap, (const char*)x->src, x->n, &prefs);
}
static void op_frame_d(void* v) {
    FCtx* x = v;
    LZ4F_dctx* d = NULL;
    if (LZ4F_isError(LZ4F_createDecompressionContext(&d, LZ4F_VERSION))) abort();
    size_t dstSz = x->n, srcSz = x->c;
    size_t r = LZ4F_decompress(d, (char*)x->dec, &dstSz, (const char*)x->comp, &srcSz, NULL);
    if (LZ4F_isError(r)) abort();
    LZ4F_freeDecompressionContext(d);
}

int main(void) {
    setbuf(stdout, NULL);
    const size_t n = 4u * 1024 * 1024;
    const double mps[4] = {0.0, 0.5, 0.9, 1.0};
    unsigned char* src = (unsigned char*)malloc(n);
    unsigned char* comp = (unsigned char*)malloc((size_t)LZ4_compressBound((int)n) + 64);
    unsigned char* dec = (unsigned char*)malloc(n);

    for (int k = 0; k < 4; k++) {
        RDG_genBuffer(src, n, mps[k], 0.0, 4242u + (unsigned)k);
        int c = LZ4_compress_default((const char*)src, (char*)comp, (int)n, LZ4_compressBound((int)n));
        printf("mp=%.2f c=%d\n", mps[k], c);
        BCtx bc = { src, comp, dec, (int)n, c };
        printf("  block compress default   %8.1f MB/s\n", best3(op_compress_default, &bc, n));
        printf("  block decompress safe    %8.1f MB/s\n", best3(op_decompress_safe, &bc, n));
        HCtx h9 = { src, comp, (int)n, (size_t)LZ4_compressBound((int)n), 0, 9 };
        printf("  hc lv9 compress          %8.1f MB/s\n", best3(op_hc, &h9, n));
        HCtx h12 = { src, comp, (int)n, (size_t)LZ4_compressBound((int)n), 0, 12 };
        printf("  hc lv12 compress         %8.1f MB/s\n", best3(op_hc, &h12, n));
    }
    /* frame (default prefs, bs4-linked) on mp=0.5 */
    RDG_genBuffer(src, n, 0.5, 0.0, 5353u);
    FCtx fc = { src, comp, dec, n, (size_t)LZ4F_compressFrameBound(n, NULL), 0 };
    op_frame_c(&fc);
    printf("frame bs4 mp=0.50 c=%zu\n", fc.c);
    printf("  frame compress           %8.1f MB/s\n", best3(op_frame_c, &fc, n));
    printf("  frame decompress         %8.1f MB/s\n", best3(op_frame_d, &fc, n));
    free(src); free(comp); free(dec);
    return 0;
}
