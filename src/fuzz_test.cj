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
