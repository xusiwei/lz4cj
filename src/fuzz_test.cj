// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

import std.unittest.*

/*-************************************
*  M3 Task 5: L4 fuzz suite (decompression robustness)
**************************************/
// Same LCG constants as the differential suite: every seed is deterministic
// and self-reproducing (seed -> full case derivation below).
private func fuzzLcgNext(x: UInt64): UInt64 {
    return x * 6364136223846793005u64 + 1442695040888963407u64
}

private let FUZZ_MPS: Array<Float64> = [0.0, 0.25, 0.5, 0.9, 1.0]

private let FUZZ_BS: Array<Int64> = [4096, 8192, 16384]

// Repro context surfaced on failure (contract: any escaping exception or
// contract violation = test failure; print seed + transform).
private class FuzzInfo {
    public var transform: Int64 = -1
}

private func fuzzTransformName(t: Int64): String {
    if (t == 0) { return "none" }
    if (t == 1) { return "bitflip1-8" }
    if (t == 2) { return "truncate1-16" }
    if (t == 3) { return "offset-tamper" }
    return "garbage"
}

/*-************************************
*  fuzzDecompressTest: block fuzz
**************************************/
// One case: LCG-derive (n in 0..4096, density, RDG seed) -> compress with
// LZ4_compress_default at bound capacity (guaranteed success) -> random
// transform -> decode via LZ4_decompress_safe and LZ4_decompress_safe_partial.
// Contract (upstream fuzz invariants):
//   - no exception escapes (caught by the caller = failure);
//   - safe: ret in {negative} or [0, n]; negative ret r satisfies
//     -r <= srcSize + 1 (the -(ip)-1 position encoding, ip <= iend);
//   - partial: ret in {negative} or [0, min(target, n)];
//   - transform none: safe ret == n byte-exact; partial ret <= target with
//     byte-exact prefix (only the none-transform guarantees content).
// Returns "" on pass, else a failure description.
private func fuzzDecompressCase(seed: Int64, info: FuzzInfo): String {
    var r: UInt64 = 0x9E3779B97F4A7C15u64 * (UInt64(seed) + 1u64)
    r = fuzzLcgNext(r)
    let n: Int64 = Int64(r % 4097u64)
    r = fuzzLcgNext(r)
    let mp = FUZZ_MPS[Int64(r % 5u64)]
    r = fuzzLcgNext(r)
    let dseed: UInt32 = UInt32(r % 4294967291u64)
    let src = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(src, n, mp, 0.0, dseed)
    let bound = Int64(LZ4_compressBound(Int32(n)))
    let comp = Array<UInt8>(bound, {_ => 0u8})
    let c: Int32 = LZ4_compress_default(src, Int32(n), comp, Int32(bound))
    if (c <= 0) { return "compress c=${c} at bound capacity" }
    let cc: Int64 = Int64(c)
    r = fuzzLcgNext(r)
    let transform: Int64 = Int64(r % 5u64)
    info.transform = transform
    let mod = Array<UInt8>(cc, {i => comp[i]})
    var mc: Int64 = cc
    if (transform == 1) {
        // 1-8 single-bit flips at random positions
        r = fuzzLcgNext(r)
        let flips = 1 + Int64(r % 8u64)
        for (_ in 0..flips) {
            r = fuzzLcgNext(r)
            let pos = Int64(r % UInt64(cc))
            r = fuzzLcgNext(r)
            mod[pos] = mod[pos] ^ UInt8(1 << Int64(r % 8u64))
        }
    } else if (transform == 2) {
        // truncation of 1-16 bytes (at least 1 byte kept): shorter srcSize,
        // the decoder never reads past it
        r = fuzzLcgNext(r)
        let cut = 1 + Int64(r % 16u64)
        mc = if (cc - cut >= 1) { cc - cut } else { 1 }
    } else if (transform == 3) {
        // offset-field tamper: 2-byte LE value at a random position
        if (cc >= 3) {
            r = fuzzLcgNext(r)
            let pos = Int64(r % UInt64(cc - 2))
            r = fuzzLcgNext(r)
            let off = 1 + Int64(r % 65535u64)
            mod[pos] = UInt8(off % 256)
            mod[pos + 1] = UInt8(off / 256)
        }
    } else if (transform == 4) {
        // random garbage over the whole or the first half of the stream
        r = fuzzLcgNext(r)
        let lim: Int64 = if ((r % 2u64) == 0u64) { cc } else { cc / 2 }
        for (i in 0..lim) {
            r = fuzzLcgNext(r)
            mod[i] = UInt8(r % 256u64)
        }
    }
    let out = Array<UInt8>(n, {_ => 0u8})
    let rs = LZ4_decompress_safe(mod, Int32(mc), out, Int32(n))
    if (rs > Int32(n)) { return "safe ret ${rs} > capacity ${n}" }
    if (rs < 0 && -Int64(rs) > mc + 1) { return "safe error ${rs} violates -(srcSize)-1 bound (mc=${mc})" }
    if (transform == 0) {
        if (rs != Int32(n)) { return "none: safe ret ${rs} want ${n}" }
        for (i in 0..n) {
            if (out[i] != src[i]) { return "none: safe bytes differ at ${i}" }
        }
    }
    r = fuzzLcgNext(r)
    let target: Int64 = Int64(r % UInt64(n + 1))
    let rp = LZ4_decompress_safe_partial(mod, Int32(mc), out, Int32(n), Int32(target))
    if (rp > Int32(target)) { return "partial ret ${rp} > target ${target}" }
    if (rp < 0 && -Int64(rp) > mc + 1) { return "partial error ${rp} violates -(srcSize)-1 bound (mc=${mc})" }
    if (transform == 0) {
        if (rp < 0) { return "none: partial ret ${rp} target=${target}" }
        for (i in 0..Int64(rp)) {
            if (out[i] != src[i]) { return "none: partial prefix differs at ${i}/${rp}" }
        }
    }
    return ""
}

@Test
func fuzzDecompressTest(): Unit {
    let info = FuzzInfo()
    var failures: Int64 = 0
    for (seed in 0..2000) {
        info.transform = -1
        var problem = ""
        try {
            problem = fuzzDecompressCase(seed, info)
        } catch (e: Exception) {
            problem = "EXCEPTION ${e}"
        }
        if (problem != "") {
            failures += 1
            println("FUZZ-DEC FAIL seed=${seed} transform=${fuzzTransformName(info.transform)}: ${problem}")
        }
    }
    @Assert(failures == 0)
    println("fuzz decompress: 2000 seeds x (safe + partial), 0 exceptions, 0 failures")
}

/*-************************************
*  fuzzContinueTest: streaming / ring-buffer fuzz
**************************************/
// Synthetic sequence encoder (differential-suite pattern): emits a valid
// block decoding to n bytes written into gold[base..base+n). Literals come
// from the LCG; match offsets are bounded by histLen + op so every source
// byte lands in already-written gold content (in-block or cross-block
// history). Returns (stream, size, advanced LCG state).
private func fuzzSynthStream(gold: Array<UInt8>, base: Int64, histLen: Int64, n: Int64,
        r0: UInt64): (Array<UInt8>, Int64, UInt64) {
    let bound = n + n / 255 + 64
    let comp = Array<UInt8>(bound, {_ => 0u8})
    var c: Int64 = 0
    var op: Int64 = 0
    var r = r0
    while (n - op > 40) {
        let litLen0 = Int64(r % 11u64)
        r = fuzzLcgNext(r)
        let ml = Int64(r % 12u64) + 4
        r = fuzzLcgNext(r)
        // a match needs in-segment history: the very first sequence of a
        // fresh segment must carry at least one literal
        let litLen: Int64 = if (histLen + op == 0 && litLen0 == 0) { 1 } else { litLen0 }
        comp[c] = UInt8((litLen << 4) | (ml - 4))
        c += 1
        var i: Int64 = 0
        while (i < litLen) {
            comp[c] = UInt8(r % 251u64)
            r = fuzzLcgNext(r)
            gold[base + op] = comp[c]
            c += 1
            op += 1
            i += 1
        }
        // offset bounded by the contiguous in-segment history (previous
        // blocks + this block's literals; capped at 65535 like a real
        // encoder's u16 field)
        let lim: Int64 = if (histLen + op > 65535) { 65535 } else { histLen + op }
        let off = Int64(r % UInt64(lim)) + 1
        r = fuzzLcgNext(r)
        comp[c] = UInt8(off % 256)
        comp[c + 1] = UInt8(off / 256)
        c += 2
        i = 0
        while (i < ml) {
            gold[base + op] = gold[base + op - off]
            op += 1
            i += 1
        }
    }
    // trailing literals run (loop guard leaves >= 16 bytes)
    let last = n - op
    if (last >= 15) {
        var len = last - 15
        comp[c] = 0xF0u8
        c += 1
        while (len >= 255) {
            comp[c] = 255u8
            c += 1
            len -= 255
        }
        comp[c] = UInt8(len)
        c += 1
    } else {
        comp[c] = UInt8(last << 4)
        c += 1
    }
    var i: Int64 = 0
    while (i < last) {
        comp[c] = UInt8(r % 251u64)
        r = fuzzLcgNext(r)
        gold[base + op] = comp[c]
        c += 1
        op += 1
        i += 1
    }
    return (comp, c, r)
}

// One continue-fuzz case: 3-6 blocks rolled through one buffer (linear or
// decoder-ring sized, wrap included); a mid-stream block is corrupted.
// Contract: clean blocks decode byte-exact vs the gold model (clean-prefix
// propagation); the corrupted block returns negative or <= blockSize; no
// exception escapes; the errored state is never reused (decode stops).
private func fuzzContinueCase(seed: Int64, info: FuzzInfo): String {
    var r: UInt64 = 0xD1B54A32D192ED03u64 * (UInt64(seed) + 1u64)
    r = fuzzLcgNext(r)
    let blocks: Int64 = 3 + Int64(r % 4u64)          // 3..6
    r = fuzzLcgNext(r)
    // layout 0: linear buffer (prefix grows past 64KB for late blocks);
    // layout 1: ring size, no wrap at this block count; layout 2: ring at
    // B=16384 with 6 blocks -> wraps at block 5 (extDict swap)
    let layout: Int64 = Int64(r % 3u64)
    let B: Int64 = if (layout == 2) { 16384 } else { FUZZ_BS[Int64(r % 3u64)] }
    r = fuzzLcgNext(r)
    let nBlocks: Int64 = if (layout == 2) { 6 } else { blocks }
    let bufSize: Int64 = if (layout == 0) { nBlocks * B } else { Int64(LZ4_decoderRingBufferSize(Int32(B))) }
    let gold = Array<UInt8>(bufSize, {_ => 0u8})
    let ring = Array<UInt8>(bufSize, {_ => 0u8})
    r = fuzzLcgNext(r)
    let corruptIdx: Int64 = 1 + Int64(r % UInt64(nBlocks - 1))   // 1..nBlocks-1
    r = fuzzLcgNext(r)
    let transform: Int64 = 1 + Int64(r % 4u64)                   // no "none" here
    info.transform = transform
    let sd = LZ4_createStreamDecode()
    var pos: Int64 = 0
    var contPrefix: Int64 = 0
    var i: Int64 = 0
    while (i <= corruptIdx) {
        if (bufSize - pos < B) {
            pos = 0
            contPrefix = 0
        }
        let (comp, c, r2) = fuzzSynthStream(gold, pos, contPrefix, B, r)
        r = r2
        if (i == corruptIdx) {
            let mod = Array<UInt8>(c, {k => comp[k]})
            var mc = c
            if (transform == 1) {
                r = fuzzLcgNext(r)
                let flips = 1 + Int64(r % 8u64)
                for (_ in 0..flips) {
                    r = fuzzLcgNext(r)
                    let p = Int64(r % UInt64(c))
                    r = fuzzLcgNext(r)
                    mod[p] = mod[p] ^ UInt8(1 << Int64(r % 8u64))
                }
            } else if (transform == 2) {
                r = fuzzLcgNext(r)
                let cut = 1 + Int64(r % 16u64)
                mc = if (c - cut >= 1) { c - cut } else { 1 }
            } else if (transform == 3) {
                if (c >= 3) {
                    r = fuzzLcgNext(r)
                    let p = Int64(r % UInt64(c - 2))
                    r = fuzzLcgNext(r)
                    let off = 1 + Int64(r % 65535u64)
                    mod[p] = UInt8(off % 256)
                    mod[p + 1] = UInt8(off / 256)
                }
            } else {
                r = fuzzLcgNext(r)
                let lim: Int64 = if ((r % 2u64) == 0u64) { c } else { c / 2 }
                for (k in 0..lim) {
                    r = fuzzLcgNext(r)
                    mod[k] = UInt8(r % 256u64)
                }
            }
            let rr = LZ4_decompress_safe_continue(sd, mod, Int32(mc), ring, pos, Int32(B))
            if (rr > Int32(B)) { return "corrupt block ${i} ret ${rr} > block size ${B}" }
            if (rr < 0 && -Int64(rr) > mc + 1) { return "corrupt block ${i} error ${rr} violates -(srcSize)-1 bound (mc=${mc})" }
            break
        }
        let rr = LZ4_decompress_safe_continue(sd, comp, Int32(c), ring, pos, Int32(B))
        if (rr != Int32(B)) { return "clean block ${i} ret ${rr} want ${B}" }
        for (j in 0..B) {
            if (ring[pos + j] != gold[pos + j]) { return "clean block ${i} bytes differ at ${j}" }
        }
        pos += B
        contPrefix += B
        i += 1
    }
    LZ4_freeStreamDecode(sd)
    return ""
}

@Test
func fuzzContinueTest(): Unit {
    let info = FuzzInfo()
    var failures: Int64 = 0
    for (seed in 0..200) {
        info.transform = -1
        var problem = ""
        try {
            problem = fuzzContinueCase(seed, info)
        } catch (e: Exception) {
            problem = "EXCEPTION ${e}"
        }
        if (problem != "") {
            failures += 1
            println("FUZZ-CONT FAIL seed=${seed} transform=${fuzzTransformName(info.transform)}: ${problem}")
        }
    }
    @Assert(failures == 0)
    println("fuzz continue: 200 seeds x (3-6 blocks, mid-stream corruption), 0 exceptions, 0 failures")
}

/*-************************************
*  fuzzHcTest: HC compression fuzz (M4 Task 6)
**************************************/
// Level stratification is deterministic: level = FUZZ_HC_LEVELS[seed % 12].
// 300 seeds / 12 slots = exactly 25 seeds per slot; the slot layout gives
// 4 slots per strategy class -> mid (lv 1-2) 100 seeds, hashChain (lv 3-9)
// 100, optimal (lv 10-12) 100 (>= 80 per class, cross-checked by the
// derived counters asserted at the end of fuzzHcTest). Slots, in order:
//   [1 2 1 2 | 3 5 8 9 | 10 11 12 10]
// Levels 4/6/7 are exercised by the golden suite's full 1-12 sampling
// instead; the fuzz strata prioritize strategy classes over level
// completeness, and level 10 (the cheapest opt level) is double-weighted
// to bound runtime.
private let FUZZ_HC_LEVELS: Array<Int32> = [1, 2, 1, 2, 3, 5, 8, 9, 10, 11, 12, 10]

// Runtime caps keeping the suite addition far below the 60s degradation
// threshold: the optimal parser is order(s) of magnitude slower per byte,
// so lv10-12 inputs cap at 64 KiB (one-shot and streaming alike) while
// mid/hashchain seeds keep the full n <= 200000 one-shot range of the
// brief and a <= 128 KiB streaming buffer. The streaming determinism
// replay runs on every 2nd seed, the destSize spot-check on every 10th.
private func fuzzHcCase(seed: Int64, stats: Array<Int64>): String {
    var r: UInt64 = 0xA0761D6478BD642Fu64 * (UInt64(seed) + 1u64)
    r = fuzzLcgNext(r)
    let level: Int32 = FUZZ_HC_LEVELS[Int64(seed % 12)]
    if (level <= 2) {
        stats[0] += 1
    } else if (level <= 9) {
        stats[1] += 1
    } else {
        stats[2] += 1
    }
    r = fuzzLcgNext(r)
    // favor from bit 8 (not the low bit: with M and C both odd the LCG's
    // bit0 is a fixed function of seed parity, which would lock favor to
    // seed parity and correlate it with the savedict variant)
    let favor: Int32 = Int32((r >> 8u64) & 1u64)
    r = fuzzLcgNext(r)
    // mp: even seeds draw from the discrete ladder (0.0/0.25/0.5/0.9/1.0,
    // reusing FUZZ_MPS), odd seeds a continuous value in [0,1]
    let mp: Float64 = if (seed % 2 == 0) {
        FUZZ_MPS[Int64(r % 5u64)]
    } else {
        Float64(r % 10001u64) / 10000.0
    }
    r = fuzzLcgNext(r)
    let dseed: UInt32 = UInt32(r % 4294967291u64)
    // ---- one-shot: bound-capacity roundtrip ----
    let capN: Int64 = if (level >= LZ4HC_CLEVEL_OPT_MIN) { 65536 } else { 200000 }
    r = fuzzLcgNext(r)
    let n: Int64 = Int64(r % UInt64(capN + 1))
    let src = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(src, n, mp, 0.0, dseed)
    let bound: Int64 = Int64(LZ4_compressBound(Int32(n)))
    let comp = Array<UInt8>(bound, {_ => 0u8})
    let c0: Int32 = LZ4_compress_HC(src, Int32(n), comp, Int32(bound), level)
    if (c0 <= 0) { return "one-shot c=${c0} at bound capacity n=${n}" }
    let out = Array<UInt8>(n, {_ => 0u8})
    if (LZ4_decompress_safe(comp, c0, out, Int32(n)) != Int32(n)) {
        return "one-shot decode ret != ${n} (n=${n})"
    }
    for (i in 0..n) {
        if (out[i] != src[i]) { return "one-shot bytes differ at ${i}/${n}" }
    }
    // fresh-state determinism: a second compression is byte-identical
    let comp2 = Array<UInt8>(bound, {_ => 0u8})
    let c1: Int32 = LZ4_compress_HC(src, Int32(n), comp2, Int32(bound), level)
    if (c1 != c0) { return "determinism size ${c1} != ${c0}" }
    for (i in 0..Int64(c0)) {
        if (comp[i] != comp2[i]) { return "determinism bytes differ at ${i}/${c0}" }
    }
    // c == 0 iff dstCapacity insufficient: capacity c0-1 must fail. (A
    // literal bound-1 construction only fails when c0 == bound exactly,
    // e.g. never for compressible inputs, so the guaranteed-insufficient
    // capacity is derived from the observed c0 itself.)
    let smallCap: Int64 = Int64(c0) - 1
    let small = Array<UInt8>(smallCap, {_ => 0u8})
    let ci: Int32 = LZ4_compress_HC(src, Int32(n), small, Int32(smallCap), level)
    if (ci != 0) { return "insufficient capacity ${smallCap} returned ${ci} (c0=${c0})" }
    // destSize spot-check (every 10th seed): size <= target, consumed <= n,
    // consumed-prefix roundtrip
    if (seed % 10 == 0 && n >= 64) {
        let dst = LZ4_createStreamHC()
        let target: Int32 = Int32(Int64(c0) / 2)
        let small2 = Array<UInt8>(Int64(target) + 16, {_ => 0u8})
        let (sz, consumed) = LZ4_compress_HC_destSize(dst, src, Int32(n), small2, target, level)
        if (sz < 0 || sz > target) { return "destSize size ${sz} target ${target}" }
        if (consumed < 0 || consumed > Int32(n)) { return "destSize consumed ${consumed} > n ${n}" }
        if (sz > 0) {
            let chk = Array<UInt8>(Int64(consumed), {_ => 0u8})
            if (LZ4_decompress_safe(small2, sz, chk, consumed) != consumed) {
                return "destSize decode ret != consumed ${consumed}"
            }
            for (i in 0..Int64(consumed)) {
                if (chk[i] != src[i]) { return "destSize prefix differs at ${i}" }
            }
        }
        LZ4_freeStreamHC(dst)
    }
    // ---- streaming: 2-4 blocks of one big buffer, random boundaries ----
    r = fuzzLcgNext(r)
    let capS: Int64 = if (level >= LZ4HC_CLEVEL_OPT_MIN) { 65536 } else { 131072 }
    let n2: Int64 = Int64(r % UInt64(capS + 1))
    if (n2 == 0) { return "" }
    r = fuzzLcgNext(r)
    var nb: Int64 = 2 + Int64(r % 3u64)                    // 2..4 blocks
    if (nb > n2) { nb = n2 }                               // keep >= 1 byte/block
    r = fuzzLcgNext(r)
    // bit 12, decoupled from favor's bit 8 and from the seed-parity-locked
    // bit 0 (see the favor comment above)
    let savedict: Bool = ((r >> 12u64) & 1u64) == 1u64           // migration variant
    r = fuzzLcgNext(r)
    let saveSize: Int64 = Int64(r % 65537u64)              // clamps inside saveDictHC
    r = fuzzLcgNext(r)
    let dseed2: UInt32 = UInt32(r % 4294967291u64)
    let big = Array<UInt8>(n2, {_ => 0u8})
    RDG_genBuffer(big, n2, mp, 0.0, dseed2)
    // random boundaries: every block >= 1 byte, interior blocks random
    var rem: Int64 = n2 - nb
    let sizes = Array<Int64>(nb, {_ => 1})
    for (k in 0..(nb - 1)) {
        if (rem > 0) {
            r = fuzzLcgNext(r)
            let add: Int64 = Int64(r % UInt64(rem + 1))
            sizes[k] += add
            rem -= add
        }
    }
    sizes[nb - 1] += rem
    var maxSize: Int64 = 1
    for (k in 0..nb) {
        if (sizes[k] > maxSize) { maxSize = sizes[k] }
    }
    let outS = Array<UInt8>(Int64(LZ4_compressBound(Int32(maxSize))), {_ => 0u8})
    let safe = Array<UInt8>(65536, {_ => 0u8})
    let gold = Array<UInt8>(n2, {_ => 0u8})
    let allComp = Array<UInt8>(Int64(LZ4_compressBound(Int32(n2))) + 64, {_ => 0u8})
    let cs = Array<Int32>(nb, {_ => 0})
    let st = LZ4_createStreamHC()
    LZ4_resetStreamHC(st, level)
    if (favor != 0 && level >= LZ4HC_CLEVEL_OPT_MIN) {
        LZ4_favorDecompressionSpeed(st, 1)
        stats[3] += 1
    }
    let sd = LZ4_createStreamDecode()
    var off: Int64 = 0
    var cum: Int64 = 0
    for (k in 0..nb) {
        let sz: Int64 = sizes[k]
        // variant A: contiguous slices of big (real streaming geometry);
        // variant B: per-block private buffers + LZ4_saveDictHC migration
        // between blocks (history relocated into safe, next block hits the
        // setExternalDict handover)
        let c: Int32 = if (savedict) {
                let base: Int64 = off
                let block = Array<UInt8>(sz, {i => big[base + i]})
                LZ4_compress_HC_continue(st, block, 0, Int32(sz), outS, Int32(outS.size))
            } else {
                LZ4_compress_HC_continue(st, big, off, Int32(sz), outS, Int32(outS.size))
            }
        if (c <= 0) { return "stream block ${k} c=${c} sz=${sz}" }
        cs[k] = c
        for (i in 0..Int64(c)) { allComp[cum + i] = outS[i] }
        cum += Int64(c)
        // rolling decode closure: each block lands at its cumulative offset
        let rd = LZ4_decompress_safe_continue(sd, outS, c, gold, off, Int32(sz))
        if (rd != Int32(sz)) { return "stream decode block ${k} ret ${rd} want ${sz}" }
        off += sz
        if (savedict && k < nb - 1) {
            let sv = LZ4_saveDictHC(st, safe, Int32(saveSize))
            if (sv < 0 || Int64(sv) > 65536) { return "saveDict ret ${sv}" }
        }
    }
    for (i in 0..n2) {
        if (gold[i] != big[i]) { return "stream gold differs at ${i}/${n2}" }
    }
    // streaming determinism replay (every 2nd seed): a fresh stream with
    // the same level/favor setup reproduces every block byte-identically.
    // (Every 2nd rather than every 4th seed: the LCG's low bit alternates
    // deterministically, so the savedict variant parity is fixed within a
    // seed mod 4 class — replaying seeds {0,4,8,...} would only ever see
    // one variant; {0,2,4,...} spans both.)
    if (seed % 2 == 0) {
        let st2 = LZ4_createStreamHC()
        LZ4_resetStreamHC(st2, level)
        if (favor != 0 && level >= LZ4HC_CLEVEL_OPT_MIN) {
            LZ4_favorDecompressionSpeed(st2, 1)
        }
        let safe2 = Array<UInt8>(65536, {_ => 0u8})
        let out2 = Array<UInt8>(outS.size, {_ => 0u8})
        var off2: Int64 = 0
        var cum2: Int64 = 0
        for (k in 0..nb) {
            let sz: Int64 = sizes[k]
            let c: Int32 = if (savedict) {
                    let base: Int64 = off2
                    let block = Array<UInt8>(sz, {i => big[base + i]})
                    LZ4_compress_HC_continue(st2, block, 0, Int32(sz), out2, Int32(out2.size))
                } else {
                    LZ4_compress_HC_continue(st2, big, off2, Int32(sz), out2, Int32(out2.size))
                }
            if (c != cs[k]) { return "replay block ${k} size ${c} != ${cs[k]}" }
            for (i in 0..Int64(c)) {
                if (out2[i] != allComp[cum2 + i]) { return "replay block ${k} bytes differ at ${i}" }
            }
            cum2 += Int64(c)
            off2 += sz
            if (savedict && k < nb - 1) {
                LZ4_saveDictHC(st2, safe2, Int32(saveSize))
            }
        }
        LZ4_freeStreamHC(st2)
    }
    LZ4_freeStreamDecode(sd)
    LZ4_freeStreamHC(st)
    return ""
}

@Test
func fuzzHcTest(): Unit {
    // stats: [0] mid seeds, [1] hashchain seeds, [2] optimal seeds,
    // [3] optimal streaming runs with favorDecompressionSpeed set
    let stats: Array<Int64> = [0, 0, 0, 0]
    var failures: Int64 = 0
    for (seed in 0..300) {
        var problem = ""
        try {
            problem = fuzzHcCase(seed, stats)
        } catch (e: Exception) {
            problem = "EXCEPTION ${e}"
        }
        if (problem != "") {
            failures += 1
            println("FUZZ-HC FAIL seed=${seed}: ${problem}")
        }
    }
    // derived stratification check (guards FUZZ_HC_LEVELS edits)
    @Assert(stats[0] >= 80 && stats[1] >= 80 && stats[2] >= 80)
    @Assert(stats[0] + stats[1] + stats[2] == 300)
    @Assert(stats[3] > 0)
    @Assert(failures == 0)
    println("fuzz hc: 300 seeds (mid ${stats[0]} / hashchain ${stats[1]} / optimal ${stats[2]}, favor-on-opt ${stats[3]}), one-shot roundtrip + determinism + insufficient-capacity + streaming(2-4 blocks, savedict variant, rolling decode), 0 exceptions, 0 failures")
}

/*-************************************
*  fuzzFrameTest: frame compression fuzz (M5 Task 4)
**************************************/
// One case: LCG-derive {n in 0..150000, mp, bs in 4..7, bm, ccs, bcs, af,
// lv in {-3,0,3,9,12}, ss, chunks in 1..6} (all choices derived BEFORE any
// API call, so the rerun replays the identical call sequence), then
//   scenario A: one-shot LZ4F_compressFrame;
//   scenario B: Begin + random-split Updates (bm=1: random
//   uncompressedUpdate insertions incl. mode switches) + one random mid
//   flush + End.
// Contract: no exception escapes; every call non-error at
// compressFrameBound capacity; total == sum of returned segments;
// endmark 4x00 at [total-4-ccs*4, total-4); ccs=1 -> trailing 4B ==
// XXH32(input) LE; bm=1 (or single-block linked) -> per-block
// LZ4_decompress_safe closure == input; same-seed rerun byte-deterministic
// (both scenarios).
// Capacity soundness: the exact emitted block count of the derived plan is
// simulated up front (fuzzFramePlanBlocks) and the worst-case frame
// 7 + (4+4*bcs)*blocks + n + 4 + 4*ccs must fit compressFrameBound; plans
// that exceed it (mode-switch flushes, af=1 per-chunk partial blocks and
// mid flushes all add blocks over ceil(n/bs)) degrade stepwise - drop
// flush, drop mixing, single chunk - so every call is guaranteed non-error
// at exactly compressFrameBound capacity. Standalone closure is only
// asserted for bm=1 frames or chains that emit exactly ONE block: af=1
// emits a partial block per Update call, so a linked multi-chunk chain is
// multi-block linked and not per-block decodable.
private let FUZZ_FRAME_LEVELS: Array<Int32> = [-3, 0, 3, 9, 12]

// Frame tail + independent-block closure verification. closureOk covers
// bm=1 rows and linked frames of at most one block (the first block of a
// linked frame has no prefix, hence is standalone-decodable).
private func fuzzFrameVerify(dst: Array<UInt8>, total: Int64, src: Array<UInt8>,
        n: Int64, ccs: Int32, bcs: Int32, closureOk: Bool): String {
    let tailStart: Int64 = total - 4 - Int64(ccs) * 4
    if (tailStart < 0) { return "tail position negative" }
    for (k in tailStart..(total - 4)) {
        if (dst[k] != 0u8) { return "endmark byte nonzero at ${k}" }
    }
    if (ccs == 1) {
        var got: UInt32 = 0u32
        for (k in 0..4) {
            got += UInt32(dst[total - 4 + k]) << (8 * k)
        }
        let want = XXH32(src, n, 0u32)
        if (got != want) { return "content checksum ${got} want ${want}" }
    }
    if (closureOk) {
        // 7-byte header (fuzz prefs never set csz/did)
        var p: Int64 = 7
        var cursor: Int64 = 0
        let out = Array<UInt8>(n, {_ => 0u8})
        let scratch = Array<UInt8>(n + 16, {_ => 0u8})
        while (true) {
            if (total - p < 4) { return "truncated block header at ${p}" }
            let sz: UInt32 = UInt32(dst[p]) | (UInt32(dst[p + 1]) << 8) |
                (UInt32(dst[p + 2]) << 16) | (UInt32(dst[p + 3]) << 24)
            if (sz == 0u32) {
                p += 4                           /* consume the endmark */
                break
            }
            p += 4
            let raw = (sz & 0x80000000u32) != 0u32
            let dataLen = Int64(sz & 0x7fffffffu32)
            if (dataLen == 0) { return "empty block at ${p - 4}" }
            if (raw) {
                if (cursor + dataLen > n) { return "raw block overruns input" }
                for (k in 0..dataLen) {
                    out[cursor + k] = dst[p + k]
                }
                cursor += dataLen
            } else {
                let pk = p
                let blk = Array<UInt8>(dataLen, {k => dst[pk + k]})
                let rd = LZ4_decompress_safe(blk, Int32(dataLen), scratch, Int32(n + 16))
                if (rd < 0) { return "block decode error ${rd} at ${p}" }
                if (cursor + Int64(rd) > n) { return "decoded overrun at ${p}" }
                for (k in 0..Int64(rd)) {
                    out[cursor + k] = scratch[k]
                }
                cursor += Int64(rd)
            }
            p += dataLen
            if (bcs == 1) {
                p += 4
            }
        }
        if (p != tailStart + 4) { return "block walk ended at ${p} want ${tailStart + 4}" }
        if (cursor != n) { return "closure size ${cursor} != ${n}" }
        for (k in 0..n) {
            if (out[k] != src[k]) { return "closure bytes differ at ${k}" }
        }
    }
    return ""
}

// Exact emitted-block-count simulation of the scenario-B chain (the count
// is deterministic given the pre-derived plan; block cost varies with
// content, worst case = 4 + 4*bcs + data per block). Covers every block
// source: af=0 buffering with mode-switch internal flushes (a mode change
// at Update entry flushes buffered data) and the explicit mid flush;
// af=1 per-chunk partial blocks; the End flush of the remainder.
private func fuzzFramePlanBlocks(af: Int32, bsz: Int64, sizes: Array<Int64>, nb: Int64,
        mixOn: Bool, rawCoin: Array<Bool>, flushAt: Int64, bm: Int32): Int64 {
    var blocks: Int64 = 0
    var tmp: Int64 = 0
    var mode: Int32 = 0    // a fresh cctx starts in COMPRESSED mode
    for (k in 0..nb) {
        let want: Int32 = if (mixOn && bm == 1 && rawCoin[k]) { 1 } else { 0 }
        if (af == 0) {
            if (want != mode && tmp > 0) {
                blocks += 1                           // mode-switch flush
                tmp = 0
            }
            mode = want
            let total = tmp + sizes[k]
            blocks += total / bsz
            tmp = total % bsz
            if (k == flushAt && tmp > 0) {
                blocks += 1                           // explicit mid flush
                tmp = 0
            }
        } else {
            blocks += sizes[k] / bsz
            if (sizes[k] % bsz != 0) {
                blocks += 1                           // autoFlush tail block
            }
        }
    }
    if (tmp > 0) {
        blocks += 1                                   // End flush
    }
    return blocks
}

// Executes the scenario-B chain (Begin + per-chunk Update[/uncompressedUpdate]
// + optional mid flush + End); returns the total (= accumulated segment
// returns by construction), or -1 when any call errors or the total
// exceeds cap. Used both as a selection probe and for the verified runs.
private func fuzzFrameRunChain(dst: Array<UInt8>, cap: Int64, src: Array<UInt8>,
        prefs: LZ4F_preferences_t, cOpt: LZ4F_compressOptions_t,
        sizes: Array<Int64>, nb: Int64, mixOn: Bool, rawCoin: Array<Bool>,
        flushAt: Int64): Int64 {
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos: Int64 = 0
    let rb = LZ4F_compressBegin(cctx, dst, pos, cap - pos, Some(prefs))
    if (LZ4F_isError(rb)) { return -1 }
    pos += rb
    var off: Int64 = 0
    for (k in 0..nb) {
        let sz = sizes[k]
        let ru = if (mixOn && rawCoin[k]) {
                LZ4F_uncompressedUpdate(cctx, dst, pos, cap - pos, src, off, sz, Some(cOpt))
            } else {
                LZ4F_compressUpdate(cctx, dst, pos, cap - pos, src, off, sz, Some(cOpt))
            }
        if (LZ4F_isError(ru)) { return -1 }
        pos += ru
        off += sz
        if (k == flushAt) {
            let rfl = LZ4F_flush(cctx, dst, pos, cap - pos, Some(cOpt))
            if (LZ4F_isError(rfl)) { return -1 }
            pos += rfl
        }
    }
    let re = LZ4F_compressEnd(cctx, dst, pos, cap - pos, Some(cOpt))
    if (LZ4F_isError(re)) { return -1 }
    pos += re
    if (pos > cap) { return -1 }
    return pos
}

private func fuzzFrameCase(seed: Int64): String {
    var r: UInt64 = 0x853C49E6748FEA9Bu64 * (UInt64(seed) + 1u64)
    r = fuzzLcgNext(r)
    let n: Int64 = Int64(r % 150001u64)
    r = fuzzLcgNext(r)
    let mp = FUZZ_MPS[Int64(r % 5u64)]
    r = fuzzLcgNext(r)
    let bs: Int32 = 4 + Int32(r % 4u64)
    r = fuzzLcgNext(r)
    let bm: Int32 = Int32(r % 2u64)
    r = fuzzLcgNext(r)
    let ccs: Int32 = Int32(r % 2u64)
    r = fuzzLcgNext(r)
    let bcs: Int32 = Int32(r % 2u64)
    r = fuzzLcgNext(r)
    let af: Int32 = Int32(r % 2u64)
    r = fuzzLcgNext(r)
    let lv = FUZZ_FRAME_LEVELS[Int64(r % 5u64)]
    r = fuzzLcgNext(r)
    let ss: Int32 = Int32(r % 2u64)
    r = fuzzLcgNext(r)
    var chunks: Int64 = 1 + Int64(r % 6u64)
    r = fuzzLcgNext(r)
    let dseed: UInt32 = UInt32(r % 4294967291u64)

    let src = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(src, n, mp, 0.0, dseed)

    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = bs
    prefs.frameInfo.blockMode = bm
    prefs.frameInfo.contentChecksumFlag = ccs
    prefs.frameInfo.blockChecksumFlag = bcs
    prefs.compressionLevel = lv
    prefs.autoFlush = UInt32(af)
    var cOpt = LZ4F_compressOptions_t()
    cOpt.stableSrc = UInt32(ss)

    let cap = LZ4F_compressFrameBound(n, Some(prefs))
    let bsz = LZ4F_getBlockSize(bs)
    // single-block linked frames are standalone-decodable (no prefix)
    let closureOk = (bm == 1) || (n <= bsz)

    // ---- derive the full scenario-B call plan before any API call ----
    var nb: Int64 = chunks
    if (nb > n) { nb = n }                    // >= 1 byte per update
    if (n == 0) { nb = 0 }
    let sizes = Array<Int64>(nb, {_ => 1})
    var rem: Int64 = n - nb
    for (k in 0..(nb - 1)) {
        if (rem > 0) {
            r = fuzzLcgNext(r)
            let add: Int64 = Int64(r % UInt64(rem + 1))
            sizes[k] += add
            rem -= add
        }
    }
    if (nb > 0) {
        sizes[nb - 1] += rem
    }
    // per-chunk uncompressed-mode coins (bm=1 only; a mode switch under
    // af=0 forces an internal flush of buffered data)
    let rawCoin = Array<Bool>(nb, {_ => false})
    for (k in 0..nb) {
        r = fuzzLcgNext(r)
        rawCoin[k] = (r % 2u64) == 1u64
    }
    // one mid flush at a random chunk boundary (50% of seeds)
    var flushDrawn: Int64 = -1
    if (nb > 0) {
        r = fuzzLcgNext(r)
        if ((r % 2u64) == 1u64) {
            r = fuzzLcgNext(r)
            flushDrawn = Int64(r % UInt64(nb))
        }
    }
    // Plan selection: keep the drawn plan (mixing + mid flush + full
    // chunking) when its worst-case frame 7 + (4+4*bcs)*blocks + n +
    // 4 + 4*ccs fits compressFrameBound; otherwise probe it once
    // (compressed blocks cost less than the raw worst case and library
    // determinism is itself an asserted invariant), and finally degrade
    // stepwise - drop flush, drop mixing, single chunk - with the same
    // worst-case/probe acceptance; the last rung provably fits.
    var mixOn = bm == 1
    var flushAfter = flushDrawn
    var useSizes = sizes
    var useNb = nb
    var settled = false
    let drawnBlocks = fuzzFramePlanBlocks(af, bsz, sizes, nb, bm == 1, rawCoin, flushDrawn, bm)
    if (7 + (4 + 4 * Int64(bcs)) * drawnBlocks + n + 4 + 4 * Int64(ccs) <= cap) {
        settled = true
    }
    if (!settled) {
        let probe = Array<UInt8>(cap, {_ => 0u8})
        let pp = fuzzFrameRunChain(probe, cap, src, prefs, cOpt, sizes, nb,
            bm == 1, rawCoin, flushDrawn)
        if (pp >= 0) {
            settled = true
        }
    }
    if (!settled) {
        let ladder: Array<(Bool, Int64, Bool)> = [
            (bm == 1, -1, false),
            (false, flushDrawn, false),
            (false, -1, false),
            (false, -1, true),
        ]
        for ((m, f, oc) in ladder) {
            if (settled) {
                break
            }
            let ss = if (oc && nb > 1) { Array<Int64>(1, {_ => n}) } else { sizes }
            let snb = if (oc && nb > 1) { 1 } else { nb }
            let blocks = fuzzFramePlanBlocks(af, bsz, ss, snb, m, rawCoin, f, bm)
            if (7 + (4 + 4 * Int64(bcs)) * blocks + n + 4 + 4 * Int64(ccs) <= cap) {
                mixOn = m
                flushAfter = f
                useSizes = ss
                useNb = snb
                settled = true
            } else {
                let probe = Array<UInt8>(cap, {_ => 0u8})
                let pp = fuzzFrameRunChain(probe, cap, src, prefs, cOpt, ss, snb,
                    m, rawCoin, f)
                if (pp >= 0) {
                    mixOn = m
                    flushAfter = f
                    useSizes = ss
                    useNb = snb
                    settled = true
                }
            }
        }
    }
    @Assert(settled)    // single-chunk pure chain always fits the budget
    // standalone closure precondition: bm=1, or exactly one emitted block
    // (a lone first linked block has no prefix history)
    let blocksB = fuzzFramePlanBlocks(af, bsz, useSizes, useNb, mixOn, rawCoin, flushAfter, bm)
    let closureB = (bm == 1) || (n == 0) || (blocksB == 1)

    // ---- scenario A: one-shot compressFrame (x2 determinism) ----
    let dstA = Array<UInt8>(cap, {_ => 0u8})
    let ra = LZ4F_compressFrame(dstA, 0, cap, src, n, Some(prefs))
    if (LZ4F_isError(ra)) { return "A: compressFrame ${ra}" }
    if (ra > cap) { return "A: size ${ra} > cap ${cap}" }
    var va = fuzzFrameVerify(dstA, ra, src, n, ccs, bcs, closureOk)
    if (va != "") { return "A: ${va}" }
    let dstA2 = Array<UInt8>(cap, {_ => 0u8})
    let ra2 = LZ4F_compressFrame(dstA2, 0, cap, src, n, Some(prefs))
    if (ra2 != ra) { return "A determinism size ${ra2} != ${ra}" }
    for (k in 0..ra) {
        if (dstA[k] != dstA2[k]) { return "A determinism bytes differ at ${k}" }
    }

    // ---- scenario B: streaming chain (x2 determinism) ----
    // every call is checked non-error inside fuzzFrameRunChain and the
    // total equals the accumulated segment returns by construction
    let dstB = Array<UInt8>(cap, {_ => 0u8})
    let pos1 = fuzzFrameRunChain(dstB, cap, src, prefs, cOpt, useSizes, useNb,
        mixOn, rawCoin, flushAfter)
    if (pos1 < 0) { return "B: verified chain run failed" }
    let vb = fuzzFrameVerify(dstB, pos1, src, n, ccs, bcs, closureB)
    if (vb != "") { return "B: ${vb}" }
    let dstB2 = Array<UInt8>(cap, {_ => 0u8})
    let pos2 = fuzzFrameRunChain(dstB2, cap, src, prefs, cOpt, useSizes, useNb,
        mixOn, rawCoin, flushAfter)
    if (pos2 != pos1) { return "B determinism size ${pos2} != ${pos1}" }
    for (k in 0..pos1) {
        if (dstB[k] != dstB2[k]) { return "B determinism bytes differ at ${k}" }
    }
    return ""
}

@Test
func fuzzFrameTest(): Unit {
    var failures: Int64 = 0
    for (seed in 0..120) {
        var problem = ""
        try {
            problem = fuzzFrameCase(seed)
        } catch (e: Exception) {
            problem = "EXCEPTION ${e}"
        }
        if (problem != "") {
            failures += 1
            println("FUZZ-FRAME FAIL seed=${seed}: ${problem}")
        }
    }
    @Assert(failures == 0)
    println("fuzz frame: 120 seeds x (one-shot + streaming chain, uncompressedUpdate inserts + mid flush) x2 determinism, 0 exceptions, 0 failures")
}

/*-************************************
*  fuzzFrameDecodeTest: frame decompression fuzz (M6 Task 4)
**************************************/
// One case: LCG-derive {n in 0..150000, mp, bs in 4..7, bm, ccs, bcs, af,
// lv in {-3,0,3,9,12}, framing one-shot|streaming, dseed} with every choice
// drawn BEFORE any API call (rerun replays the identical call sequence):
//   scenario A (random split): frame the input (compressFrame, or Begin +
//     random-split Update chain at a provably sufficient capacity - the
//     per-chunk worst case is one block overhead 4+4*bcs per switch/flush
//     plus raw data plus multi-block splitting n/bsz*(4+4*bcs) <= n/512*8,
//     so 7 + nb*(4+4*bcs) + 2n + 4 + 4*ccs always fits, unlike
//     fuzzFrameRunChain which probes/degrades against compressFrameBound),
//     then decode through LCG-random src chunks (1..997) with per-call dst
//     capacity drawn from {0, 1..40 (forces flushOut/storeCBlock staging),
//     exactly maxBlockSize, n}, all clamped to the remaining budget;
//   scenario B (concat): 2-4 segments, each ~1/3 skippable else a frame
//     with fresh random {n in 0..20000, bs, bm, ccs, bcs}, fed as ONE
//     concatenated stream through a single dctx (frame-complete auto-reset
//     continuation, fidelity point 17);
//   scenario C (corruption): 1-3 bit flips / truncation 1..64 / in-block
//     tamper (2-6 consecutive random bytes) of the scenario-A frame bytes,
//     decode loop until ret==0, isError, or the finite caller-side budget
//     ends (src exhausted -> positive hint is the legitimate truncated
//     valid-frame state, fdmp errtail row pins it; output buffer full -> a
//     corrupted payload can decode "successfully" to arbitrary output and
//     can also produce MORE than n decoded bytes, so the caller-side out
//     buffer of max(n, 4096) bytes ends the loop).
// Contract: no exception escapes; A/B every call non-error, final ret==0,
// sum(consumed)==frame size, sum(written)==n, output byte-exact == input
// (concatenated for B); C error triples exactly (code, 0, 0); every seed
// replays scenario A end-to-end (fresh dctx + fresh buffers, same LCG
// seed) with identical call count and byte-identical output.
// Byte-compare loops follow the ledger-#44 mitigation: full scan into a
// flag (no early exit) + tagged print before the assert.
private func fuzzFrameDecodeChain(dst: Array<UInt8>, cap: Int64, src: Array<UInt8>, n: Int64,
        prefs: LZ4F_preferences_t, sizes: Array<Int64>, nb: Int64,
        rawCoin: Array<Bool>): Int64 {
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos: Int64 = 0
    let rb = LZ4F_compressBegin(cctx, dst, pos, cap - pos, Some(prefs))
    if (LZ4F_isError(rb)) { return -1 }
    pos += rb
    var off: Int64 = 0
    for (k in 0..nb) {
        let sz = sizes[k]
        let ru = if (prefs.frameInfo.blockMode == LZ4F_blockIndependent && rawCoin[k]) {
                LZ4F_uncompressedUpdate(cctx, dst, pos, cap - pos, src, off, sz,
                    Option<LZ4F_compressOptions_t>.None)
            } else {
                LZ4F_compressUpdate(cctx, dst, pos, cap - pos, src, off, sz,
                    Option<LZ4F_compressOptions_t>.None)
            }
        if (LZ4F_isError(ru)) { return -1 }
        pos += ru
        off += sz
    }
    let re = LZ4F_compressEnd(cctx, dst, pos, cap - pos, Option<LZ4F_compressOptions_t>.None)
    if (LZ4F_isError(re)) { return -1 }
    pos += re
    return pos
}

// Split-decode kernel for valid streams (scenario A: one frame; scenario
// B: concatenated stream): random src chunks + random per-call capacity
// from the {0, small, maxBlockSize, n} ladder, loop while the frame wants
// more (r != 0) or src remains (concat boundary: r==0 mid-stream re-enters
// getFrameHeader). Returns the call count (determinism replay compares
// it). Progress guarantee: every call consumes >= 1 src or writes >= 1 dst
// (chunk >= 1 while off < size; capacity >= 1 while written < n drains a
// pending flushOut), so maxIters only guards true stalls.
private func fuzzFrameDecodeSplit(frame: Array<UInt8>, size: Int64, out: Array<UInt8>,
        n: Int64, dctx: LZ4F_dctx, mbs: Int64, lcg0: UInt64, seedTag: Int64,
        scen: Int64): Int64 {
    var rng = lcg0
    var off: Int64 = 0
    var written: Int64 = 0
    var r: Int64 = 1
    var calls: Int64 = 0
    let maxIters = 4 * size + 64
    while (r != 0 || off < size) {
        calls += 1
        if (calls > maxIters) {
            println("FD-SPLIT STALL scen=${scen} seed=${seedTag} off=${off}/${size} w=${written}/${n}")
        }
        @Assert(calls <= maxIters)
        rng = fuzzLcgNext(rng)
        var chunk = 1 + Int64(rng % 997u64)
        if (chunk > size - off) { chunk = size - off }
        rng = fuzzLcgNext(rng)
        let capSel = Int64(rng % 4u64)
        var cap: Int64 = 0
        if (capSel == 1) {
            rng = fuzzLcgNext(rng)
            cap = 1 + Int64(rng % 40u64)
        } else if (capSel == 2) {
            cap = mbs
        } else if (capSel == 3) {
            cap = n
        }
        if (cap > n - written) { cap = n - written }
        let (rr, cc, ww) = LZ4F_decompress(dctx, out, written, cap, frame, off, chunk,
            Option<LZ4F_decompressOptions_t>.None)
        if (LZ4F_isError(rr)) {
            println("FD-SPLIT ERR scen=${scen} seed=${seedTag} off=${off} chunk=${chunk} cap=${cap}: ret=${rr}")
        }
        @Assert(!LZ4F_isError(rr))
        off += cc
        written += ww
        r = rr
    }
    if (off != size || written != n) {
        println("FD-SPLIT SUM scen=${scen} seed=${seedTag}: off=${off}/${size} w=${written}/${n}")
    }
    @Assert(off == size)
    @Assert(written == n)
    return calls
}

// Ledger-#44 mitigation compare: full scan, tagged print, assert (T3
// lz4fFdmpSplitDecode pattern).
private func fuzzFrameDecodeCmp(out: Array<UInt8>, base: Int64, want: Array<UInt8>, n: Int64,
        seedTag: Int64, scen: Int64): Unit {
    var eq = true
    for (k in 0..n) {
        if (out[base + k] != want[k]) {
            eq = false
        }
    }
    if (!eq) {
        println("FD-BYTES scen=${scen} seed=${seedTag} n=${n}")
    }
    @Assert(eq)
}

// stats: [0] scenario-C "complete" stops, [1] error stops, [2] exhausted
// stops, [3] output-buffer-full stops, [4] scenario-A determinism replays
private func fuzzFrameDecodeCase(seed: Int64, stats: Array<Int64>): String {
    var r: UInt64 = 0xD6E8FEB86659FD93u64 * (UInt64(seed) + 1u64)
    r = fuzzLcgNext(r)
    let n: Int64 = Int64(r % 150001u64)
    r = fuzzLcgNext(r)
    let mp = FUZZ_MPS[Int64(r % 5u64)]
    r = fuzzLcgNext(r)
    let bs: Int32 = 4 + Int32(r % 4u64)
    // bit coins from ONE word's low nibble: with LCG M,C both odd the
    // parities of CONSECUTIVE outputs strictly alternate (fuzzHcCase
    // documents the same low-bit locking), so consecutive r%2 draws would
    // lock (bm,ccs,bcs,af) to two anti-correlated combos out of 16
    r = fuzzLcgNext(r)
    let nib: UInt64 = r % 16u64
    let bm: Int32 = Int32(nib & 1u64)
    let ccs: Int32 = Int32((nib >> 1u64) & 1u64)
    let bcs: Int32 = Int32((nib >> 2u64) & 1u64)
    let af: Int32 = Int32((nib >> 3u64) & 1u64)
    r = fuzzLcgNext(r)
    let lv = FUZZ_FRAME_LEVELS[Int64(r % 5u64)]
    // odd modulus escapes the parity alternation (power-of-2 phenomenon)
    r = fuzzLcgNext(r)
    let streaming: Bool = (r % 3u64) == 0u64
    r = fuzzLcgNext(r)
    let dseed: UInt32 = UInt32(r % 4294967291u64)

    let src = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(src, n, mp, 0.0, dseed)

    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = bs
    prefs.frameInfo.blockMode = bm
    prefs.frameInfo.contentChecksumFlag = ccs
    prefs.frameInfo.blockChecksumFlag = bcs
    prefs.compressionLevel = lv
    prefs.autoFlush = UInt32(af)
    let mbs = LZ4F_getBlockSize(bs)

    // ---- derive the full streaming plan before any API call ----
    var nb: Int64 = 0
    var sizes = Array<Int64>(0, {_ => 0})
    var rawCoin = Array<Bool>(0, {_ => false})
    if (streaming) {
        r = fuzzLcgNext(r)
        let chunks: Int64 = 1 + Int64(r % 6u64)
        nb = if (chunks > n) { n } else { chunks }
        if (n == 0) { nb = 0 }
        sizes = Array<Int64>(nb, {_ => 1})
        var rem: Int64 = n - nb
        for (k in 0..(nb - 1)) {
            if (rem > 0) {
                r = fuzzLcgNext(r)
                let add: Int64 = Int64(r % UInt64(rem + 1))
                sizes[k] += add
                rem -= add
            }
        }
        if (nb > 0) {
            sizes[nb - 1] += rem
        }
        rawCoin = Array<Bool>(nb, {_ => false})
        for (k in 0..nb) {
            r = fuzzLcgNext(r)
            rawCoin[k] = (r % 3u64) == 0u64    // odd modulus: no parity lock
        }
    }

    // ---- frame the input ----
    var frame: Array<UInt8>
    var size: Int64
    if (!streaming) {
        let cap = LZ4F_compressFrameBound(n, Some(prefs))
        frame = Array<UInt8>(cap, {_ => 0u8})
        size = LZ4F_compressFrame(frame, 0, cap, src, n, Some(prefs))
        if (LZ4F_isError(size)) { return "frame compressFrame ${size}" }
    } else {
        let cap = 7 + nb * (4 + 4 * Int64(bcs)) + 2 * n + 4 + 4 * Int64(ccs)
        frame = Array<UInt8>(cap, {_ => 0u8})
        size = fuzzFrameDecodeChain(frame, cap, src, n, prefs, sizes, nb, rawCoin)
        if (size < 0) { return "chain failed at cap ${cap}" }
        if (size > cap) { return "chain size ${size} > cap ${cap}" }
    }

    // ---- scenario A: random-split decode (+ x1 full determinism replay) ----
    let lcgA = r
    let dA = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out1 = Array<UInt8>(n, {_ => 0u8})
    let calls1 = fuzzFrameDecodeSplit(frame, size, out1, n, dA, mbs, lcgA, seed, 1)
    fuzzFrameDecodeCmp(out1, 0, src, n, seed, 1)
    let dA2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out2 = Array<UInt8>(n, {_ => 0u8})
    let calls2 = fuzzFrameDecodeSplit(frame, size, out2, n, dA2, mbs, lcgA, seed, 11)
    if (calls2 != calls1) { return "A determinism calls ${calls2} != ${calls1}" }
    var eqd = true
    for (k in 0..n) {
        if (out2[k] != out1[k]) {
            eqd = false
        }
    }
    if (!eqd) {
        println("FD-DET seed=${seed} n=${n}")
    }
    @Assert(eqd)
    stats[4] += 1

    // ---- scenario B: 2-4 segments (skippable mixed) on one dctx ----
    r = fuzzLcgNext(r)
    let segs: Int64 = 2 + Int64(r % 3u64)
    let segSkip = Array<Bool>(segs, {_ => false})
    let segN = Array<Int64>(segs, {_ => 0})
    let segBs = Array<Int32>(segs, {_ => 4})
    let segBm = Array<Int32>(segs, {_ => 0})
    let segCcs = Array<Int32>(segs, {_ => 0})
    let segBcs = Array<Int32>(segs, {_ => 0})
    let segSkipSize = Array<Int64>(segs, {_ => 0})
    let segMagic = Array<UInt8>(segs, {_ => 0x50u8})
    for (k in 0..segs) {
        r = fuzzLcgNext(r)
        segSkip[k] = (r % 3u64) == 0u64
        r = fuzzLcgNext(r)
        segN[k] = Int64(r % 20001u64)
        r = fuzzLcgNext(r)
        segBs[k] = 4 + Int32(r % 4u64)
        // bm/ccs/bcs/magic coins from one nibble (see the nib comment above)
        r = fuzzLcgNext(r)
        let nibB: UInt64 = r % 16u64
        segBm[k] = Int32(nibB & 1u64)
        segCcs[k] = Int32((nibB >> 1u64) & 1u64)
        segBcs[k] = Int32((nibB >> 2u64) & 1u64)
        segMagic[k] = if (((nibB >> 3u64) & 1u64) == 0u64) { 0x50u8 } else { 0x5Fu8 }
        r = fuzzLcgNext(r)
        segSkipSize[k] = Int64(r % 5001u64)
    }
    r = fuzzLcgNext(r)
    let dseedB: UInt32 = UInt32(r % 4294967291u64)
    var segBytes = Array<Array<UInt8>>(segs, {_ => Array<UInt8>(0, {_ => 0u8})})
    let segInputs = Array<Array<UInt8>>(segs, {_ => Array<UInt8>(0, {_ => 0u8})})
    var totalIn: Int64 = 0
    var totalFrame: Int64 = 0
    var mbsB: Int64 = 0
    for (k in 0..segs) {
        if (segSkip[k]) {
            let sz = segSkipSize[k]
            let sf = Array<UInt8>(8 + sz, {_ => 0u8})
            sf[0] = segMagic[k]
            sf[1] = 0x2Au8
            sf[2] = 0x4Du8
            sf[3] = 0x18u8
            sf[4] = UInt8(sz & 0xFF)
            sf[5] = UInt8((sz >> 8) & 0xFF)
            sf[6] = UInt8((sz >> 16) & 0xFF)
            sf[7] = UInt8((sz >> 24) & 0xFF)
            segBytes[k] = sf
            totalFrame += 8 + sz
        } else {
            let nB = segN[k]
            let inB = Array<UInt8>(nB, {_ => 0u8})
            RDG_genBuffer(inB, nB, mp, 0.0, dseedB + UInt32(k))
            var pB = LZ4F_preferences_t()
            pB.frameInfo.blockSizeID = segBs[k]
            pB.frameInfo.blockMode = segBm[k]
            pB.frameInfo.contentChecksumFlag = segCcs[k]
            pB.frameInfo.blockChecksumFlag = segBcs[k]
            let capB = LZ4F_compressFrameBound(nB, Some(pB))
            let fB = Array<UInt8>(capB, {_ => 0u8})
            let sB = LZ4F_compressFrame(fB, 0, capB, inB, nB, Some(pB))
            if (LZ4F_isError(sB)) { return "B seg ${k} compressFrame ${sB}" }
            let fBs = Array<UInt8>(sB, {_ => 0u8})
            var fi: Int64 = 0
            while (fi < sB) {
                fBs[fi] = fB[fi]
                fi += 1
            }
            segBytes[k] = fBs
            segInputs[k] = inB
            totalIn += nB
            totalFrame += sB
            let m = LZ4F_getBlockSize(segBs[k])
            if (m > mbsB) { mbsB = m }
        }
    }
    let cat = Array<UInt8>(totalFrame, {_ => 0u8})
    let expOut = Array<UInt8>(totalIn, {_ => 0u8})
    var cp: Int64 = 0
    var ep: Int64 = 0
    for (k in 0..segs) {
        let sb = segBytes[k]
        var i: Int64 = 0
        while (i < sb.size) {
            cat[cp] = sb[i]
            cp += 1
            i += 1
        }
        let si = segInputs[k]
        i = 0
        while (i < si.size) {
            expOut[ep] = si[i]
            ep += 1
            i += 1
        }
    }
    @Assert(cp == totalFrame)
    @Assert(ep == totalIn)
    let dB = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let outB = Array<UInt8>(totalIn, {_ => 0u8})
    let _ = fuzzFrameDecodeSplit(cat, totalFrame, outB, totalIn, dB,
        if (mbsB == 0) { 65536 } else { mbsB }, lcgA + 0x5DEECE66Du64, seed, 2)
    fuzzFrameDecodeCmp(outB, 0, expOut, totalIn, seed, 2)

    // ---- scenario C: corruption of the scenario-A frame bytes ----
    let mod = Array<UInt8>(size, {_ => 0u8})
    var ci: Int64 = 0
    while (ci < size) {
        mod[ci] = frame[ci]
        ci += 1
    }
    var mc = size
    r = fuzzLcgNext(r)
    let ct: Int64 = 1 + Int64(r % 3u64)
    if (ct == 1) {
        // 1-3 single-bit flips at random positions
        r = fuzzLcgNext(r)
        let flips: Int64 = 1 + Int64(r % 3u64)
        for (_ in 0..flips) {
            r = fuzzLcgNext(r)
            let pos = Int64(r % UInt64(mc))
            r = fuzzLcgNext(r)
            mod[pos] = mod[pos] ^ UInt8(1 << Int64(r % 8u64))
        }
    } else if (ct == 2) {
        // truncation of 1..64 bytes (>= 1 kept)
        r = fuzzLcgNext(r)
        let cut: Int64 = 1 + Int64(r % 64u64)
        mc = if (size - cut >= 1) { size - cut } else { 1 }
    } else {
        // in-block tamper: 2-6 consecutive random bytes mid-stream
        // (tiny frames fall back to a single XOR)
        r = fuzzLcgNext(r)
        let len: Int64 = 2 + Int64(r % 5u64)
        if (mc > 16) {
            r = fuzzLcgNext(r)
            let pos: Int64 = 8 + Int64(r % UInt64(mc - 16))
            for (k in 0..len) {
                if (pos + k < mc) {
                    r = fuzzLcgNext(r)
                    mod[pos + k] = UInt8(r % 256u64)
                }
            }
        } else {
            r = fuzzLcgNext(r)
            let pos = Int64(r % UInt64(mc))
            mod[pos] = mod[pos] ^ 0xFFu8
        }
    }
    let outCapC: Int64 = if (n < 4096) { 4096 } else { n }
    let dC = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let outC = Array<UInt8>(outCapC, {_ => 0u8})
    var offC: Int64 = 0
    var writtenC: Int64 = 0
    var rC: Int64 = 1
    var itersC: Int64 = 0
    let maxItersC = 4 * mc + 64
    // stop reason: 0 = ret==0 (corruption coincidentally valid), 1 = error,
    // 2 = src exhausted on a positive hint (truncated valid frame state),
    // 3 = caller-side output buffer full
    var stopped: Int64 = -1
    while (true) {
        if (rC == 0) { stopped = 0; break }
        if (LZ4F_isError(rC)) { stopped = 1; break }
        if (offC >= mc) { stopped = 2; break }
        if (writtenC >= outCapC) { stopped = 3; break }
        itersC += 1
        if (itersC > maxItersC) { return "C: stall off=${offC}/${mc} w=${writtenC}/${outCapC}" }
        r = fuzzLcgNext(r)
        var chunkC = 1 + Int64(r % 997u64)
        if (chunkC > mc - offC) { chunkC = mc - offC }
        let (rr, cc, ww) = LZ4F_decompress(dC, outC, writtenC, outCapC - writtenC,
            mod, offC, chunkC, Option<LZ4F_decompressOptions_t>.None)
        if (LZ4F_isError(rr) && (cc != 0 || ww != 0)) {
            return "C: error triple (${rr},${cc},${ww}) violates (code,0,0) at off=${offC}"
        }
        offC += cc
        writtenC += ww
        rC = rr
    }
    stats[stopped] += 1
    return ""
}

@Test
func fuzzFrameDecodeTest(): Unit {
    // stats: [0] C-complete [1] C-error [2] C-exhausted [3] C-out-full
    // [4] determinism replays
    let stats: Array<Int64> = [0, 0, 0, 0, 0]
    var failures: Int64 = 0
    for (seed in 0..150) {
        var problem = ""
        try {
            problem = fuzzFrameDecodeCase(seed, stats)
        } catch (e: Exception) {
            problem = "EXCEPTION ${e}"
        }
        if (problem != "") {
            failures += 1
            println("FUZZ-FDEC FAIL seed=${seed}: ${problem}")
        }
    }
    // every terminal class of scenario C occurs across the fixed 150-seed
    // set with wide margins (deterministic given the seed set; verified
    // 22/75/50/3) - guards future edits of the derivation chain
    println("fuzz frame decode stats: complete ${stats[0]} / error ${stats[1]} / exhausted ${stats[2]} / outfull ${stats[3]} / replays ${stats[4]}")
    @Assert(stats[0] > 0)
    @Assert(stats[1] > 0)
    @Assert(stats[2] > 0)
    @Assert(stats[3] > 0)
    @Assert(stats[4] == 150)
    @Assert(stats[0] + stats[1] + stats[2] + stats[3] == 150)
    @Assert(failures == 0)
    println("fuzz frame decode: 150 seeds x (random split w/ capacity ladder + concat w/ skippable + corruption) x2 determinism, 0 exceptions, 0 failures")
}
