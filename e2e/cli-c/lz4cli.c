/* lz4cli.c - reference side of the lz4cj e2e suite.
 * Minimal file-to-file LZ4 frame compressor/decompressor built against the
 * upstream lz4 C library (dev-0774d055, same baseline as the port).
 *
 * Usage: lz4cli -c|-d -i <input> -o <output>
 *   -c  compress   (LZ4F_writeOpen/write/writeClose, default preferences)
 *   -d  decompress (streaming LZ4F_decompress, growing output buffer)
 * Exit codes: 0 ok, 1 runtime error (I/O, corrupt/truncated frame), 2 usage.
 * Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause (library).
 * CLI part: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lz4frame.h"
#include "lz4file.h"

static const char* g_prog = "lz4cli";

static void usage(void)
{
    fprintf(stderr, "usage: %s -c|-d -i <input> -o <output>\n", g_prog);
    exit(2);
}

static void fatal(const char* msg, const char* arg)
{
    fprintf(stderr, "%s: %s%s%s\n", g_prog, msg, arg ? ": " : "", arg ? arg : "");
    exit(1);
}

static unsigned char* read_file(const char* path, size_t* sizep)
{
    FILE* f = fopen(path, "rb");
    if (!f) fatal("cannot open input", path);
    if (fseek(f, 0, SEEK_END) != 0) fatal("seek failed", path);
    long sz = ftell(f);
    if (sz < 0) fatal("tell failed", path);
    if (fseek(f, 0, SEEK_SET) != 0) fatal("seek failed", path);
    unsigned char* buf = (unsigned char*)malloc(sz > 0 ? (size_t)sz : 1);
    if (!buf) fatal("out of memory", NULL);
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz)
        fatal("short read", path);
    fclose(f);
    *sizep = (size_t)sz;
    return buf;
}

static void write_file(const char* path, const unsigned char* buf, size_t size)
{
    FILE* f = fopen(path, "wb");
    if (!f) fatal("cannot open output", path);
    if (size > 0 && fwrite(buf, 1, size, f) != size) fatal("short write", path);
    if (fclose(f) != 0) fatal("close failed", path);
}

static int do_compress(const char* in, const char* out)
{
    size_t srcSize;
    unsigned char* src = read_file(in, &srcSize);
    FILE* f = fopen(out, "wb");
    if (!f) fatal("cannot open output", out);

    /* Mirror LZ4F_compressFrame(NULL)'s automatic preference adjustments
     * (lz4frame.c L443-453), which lz4file's LZ4F_writeOpen does NOT apply:
     * default blockSizeID resolves to max64KB, and an input that fits a
     * single block switches to blockIndependent. Both e2e twins must walk
     * the same API path: compressFrame (stableSrc=1, prefix mode) and
     * lz4file write (stableSrc=0, extDict mode) legitimately pick
     * different matches across block boundaries, so byte-identity between
     * the twins only holds when both compress via lz4file. */
    LZ4F_preferences_t prefs;
    memset(&prefs, 0, sizeof(prefs));
    prefs.frameInfo.blockSizeID = LZ4F_max64KB;
    prefs.autoFlush = 1;
    if (srcSize <= LZ4F_getBlockSize(LZ4F_max64KB))
        prefs.frameInfo.blockMode = LZ4F_blockIndependent;

    LZ4_writeFile_t* wf = NULL;
    if (LZ4F_isError(LZ4F_writeOpen(&wf, f, &prefs)))
        fatal("writeOpen failed", NULL);
    if (LZ4F_isError(LZ4F_write(wf, src, srcSize)))
        fatal("compress failed", NULL);
    if (LZ4F_isError(LZ4F_writeClose(wf)))
        fatal("writeClose failed", NULL);
    if (fclose(f) != 0) fatal("close failed", out);
    free(src);
    return 0;
}

static int do_decompress(const char* in, const char* out)
{
    size_t srcSize;
    unsigned char* src = read_file(in, &srcSize);
    size_t cap = srcSize < 4096 ? 4096 : srcSize * 4;
    unsigned char* dst = (unsigned char*)malloc(cap);
    if (!dst) fatal("out of memory", NULL);
    LZ4F_dctx* dctx;
    if (LZ4F_isError(LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION)))
        fatal("dctx alloc failed", NULL);
    size_t read = 0, written = 0;
    for (;;) {
        size_t dstRoom = cap - written;
        size_t chunk = srcSize - read;
        size_t ret = LZ4F_decompress(dctx, dst + written, &dstRoom,
                                     src + read, &chunk, NULL);
        if (LZ4F_isError(ret))
            fatal("decompress failed", LZ4F_getErrorName(ret));
        read += chunk;
        written += dstRoom;
        if (ret == 0) break;               /* frame complete */
        if (read == srcSize) fatal("truncated frame", in);
        if (written == cap) {              /* needs more room: grow */
            cap *= 2;
            dst = (unsigned char*)realloc(dst, cap);
            if (!dst) fatal("out of memory", NULL);
        }
    }
    if (read != srcSize) fatal("trailing garbage after frame", in);
    write_file(out, dst, written);
    LZ4F_freeDecompressionContext(dctx);
    free(dst);
    free(src);
    return 0;
}

int main(int argc, char** argv)
{
    const char* in = NULL;
    const char* out = NULL;
    int comp = 0, dec = 0;
    if (argc > 0) g_prog = argv[0];
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) comp = 1;
        else if (strcmp(argv[i], "-d") == 0) dec = 1;
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) in = argv[++i];
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) out = argv[++i];
        else usage();
    }
    if (comp == dec) usage();              /* exactly one of -c/-d */
    if (!in || !out) usage();
    return comp ? do_compress(in, out) : do_decompress(in, out);
}
