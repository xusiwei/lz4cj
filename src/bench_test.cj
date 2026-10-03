// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// M7 Task 5: throughput rough-measure (design 6.3: NOT a regression gate,
// used to spot order-of-magnitude regressions and the fast-decompress
// literal-dense 0.85x re-evaluation, ledger item). C counterpart:
// scripts/bench_probe.c (same inputs/ops, best-of-3 MB/s).

package lz4

import std.unittest.*
import std.time.MonoTime
import std.env.getVariable

private func benchBest3(op: () -> Unit, bytes: Int64): Float64 {
    var bestNs: Int64 = -1
    for (i in 0..3) {
        let t0 = MonoTime.now()
        op()
        let dt = (MonoTime.now() - t0).toNanoseconds()
        if (bestNs < 0 || dt < bestNs) {
            bestNs = dt
        }
    }
    return Float64(bytes) / (Float64(bestNs) / 1e9) / (1024.0 * 1024.0)
}

@Test
func benchAllTest(): Unit {
    // opt-out hook (default: run; mirrors LZ4_SKIP_PERF convention)
    if (let Some(_) <- getVariable("LZ4_SKIP_BENCH")) {
        return
    }
    let n: Int64 = 4 * 1024 * 1024
    let bound = LZ4_compressBound(Int32(n))
    for (k in 0..4) {
        let mp: Float64 = if (k == 0) { 0.0 } else if (k == 1) { 0.5 }
            else if (k == 2) { 0.9 } else { 1.0 }
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, 4242u32 + UInt32(k))
        let comp = Array<UInt8>(Int64(bound) + 64, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), comp, bound)
        @Assert(c > 0)
        /* correctness gate before timing */
        let chk = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(comp, c, chk, Int32(n)) == Int32(n))
        var eq = true
        for (i in 0..n) {
            if (chk[i] != buf[i]) {
                eq = false
                break
            }
        }
        @Assert(eq)
        let mDef = benchBest3({ => LZ4_compress_default(buf, Int32(n), comp, bound)}, n)
        let mSafe = benchBest3({ => LZ4_decompress_safe(comp, c, chk, Int32(n))}, n)
        let mHc9 = benchBest3({ => LZ4_compress_HC(buf, Int32(n), comp, bound, 9)}, n)
        let mHc12 = benchBest3({ => LZ4_compress_HC(buf, Int32(n), comp, bound, 12)}, n)
        println("mp=${mp} c=${c}")
        println("  block compress default   ${mDef} MB/s")
        println("  block decompress safe    ${mSafe} MB/s")
        println("  hc lv9 compress          ${mHc9} MB/s")
        println("  hc lv12 compress         ${mHc12} MB/s")
    }
    /* frame(default prefs)mp=0.5 */
    let fbuf = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(fbuf, n, 0.5, 0.0, 5353u32)
    let fcap = LZ4F_compressFrameBound(n, Option<LZ4F_preferences_t>.None)
    let fcomp = Array<UInt8>(fcap, {_ => 0u8})
    let fc = LZ4F_compressFrame(fcomp, 0, fcap, fbuf, n, Option<LZ4F_preferences_t>.None)
    @Assert(!LZ4F_isError(fc))
    let fout = Array<UInt8>(n + 16, {_ => 0u8})
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (fr, fcc, fww) = LZ4F_decompress(dctx, fout, 0, n, fcomp, 0, fc,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(fr == 0 && fww == n)
    let mFc = benchBest3({ => LZ4F_compressFrame(fcomp, 0, fcap, fbuf, n,
        Option<LZ4F_preferences_t>.None)}, n)
    let mFd = benchBest3({ => LZ4F_decompress(dctx, fout, 0, n, fcomp, 0, fc,
        Option<LZ4F_decompressOptions_t>.None)}, n)
    println("frame bs4 mp=0.50 c=${fc}")
    println("  frame compress           ${mFc} MB/s")
    println("  frame decompress         ${mFd} MB/s")
    println("bench: done (LTS -O2; C counterpart scripts/bench_probe.c)")
}
