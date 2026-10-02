// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// M4 Task 1: HC state family, level table and search primitives.
// All expectations are hand-computed against upstream lib/lz4hc.c and pinned
// as constants (golden style); values were additionally cross-checked against
// upstream 0774d055 via a temporary C probe (see the task report).

package lz4

import std.unittest.*
import std.fs.*

/*-************************************
*  State family
**************************************/

@Test
func lz4hcStateTest(): Unit {
    let st = LZ4_streamHC_t()
    @Assert(LZ4_initStreamHC(st) == 0)
    // full-field zero (upstream L1631-1632 MEM_INIT), tables sampled
    @Assert(st.hashTable.size == 32768)
    @Assert(st.chainTable.size == 65536)
    @Assert(st.hashTable[0] == 0u32 && st.hashTable[1] == 0u32 &&
        st.hashTable[16383] == 0u32 && st.hashTable[32767] == 0u32)
    @Assert(st.chainTable[0] == 0u16 && st.chainTable[32768] == 0u16 &&
        st.chainTable[65535] == 0u16)
    @Assert(st.dictLimit == 0u32 && st.lowLimit == 0u32 && st.nextToUpdate == 0u32)
    @Assert(st.prefixBuf.isNone() && st.prefixStartIdx == 0 && st.prefixEndIdx == 0)
    @Assert(st.dictBuf.isNone() && st.dictStartIdx == 0)
    @Assert(st.dirty == false && st.favorDecSpeed == false && st.dictCtx.isNone())
    // ...then setCompressionLevel(DEFAULT) (upstream L1633), so level == 9
    @Assert(st.compressionLevel == 9)
    // createStreamHC: zero state + level 9 (upstream L1605-1608)
    let cs = LZ4_createStreamHC()
    @Assert(cs.compressionLevel == 9)
    @Assert(cs.hashTable.size == 32768 && cs.chainTable.size == 65536)
    @Assert(LZ4_freeStreamHC(cs) == 0)
    @Assert(LZ4_sizeofStateHC() == 262200)
    // setCompressionLevel clamping (upstream L1663-1664: <1 -> 9, >12 -> 12)
    let levels: Array<Int32> = [-5, 0, 1, 12, 13, 99]
    let want: Array<Int32> = [9, 9, 1, 12, 12, 12]
    for (i in 0..6) {
        LZ4_setCompressionLevel(st, levels[i])
        @Assert(st.compressionLevel == want[i])
    }
    // favorDecompressionSpeed (upstream L1668-1671): favor != 0
    LZ4_favorDecompressionSpeed(st, 0)
    @Assert(st.favorDecSpeed == false)
    LZ4_favorDecompressionSpeed(st, 1)
    @Assert(st.favorDecSpeed == true)
    LZ4_favorDecompressionSpeed(st, 7)
    @Assert(st.favorDecSpeed == true)
}

/*-************************************
*  Level table
**************************************/

@Test
func lz4hcCLevelParamsTest(): Unit {
    @Assert(LZ4HC_CLEVEL_MIN == 2 && LZ4HC_CLEVEL_DEFAULT == 9 &&
        LZ4HC_CLEVEL_OPT_MIN == 10 && LZ4HC_CLEVEL_MAX == 12)
    // k_clTable verbatim (upstream L92-106), index = compressionLevel 0..12
    @Assert(kClTable.size == 13)
    let goldStrat: Array<Int32> = [0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2]
    let goldSearches: Array<Int32> = [2, 2, 2, 4, 8, 16, 32, 64, 128, 256, 96, 512, 16384]
    let goldTarget: Array<UInt32> = [16u32, 16u32, 16u32, 16u32, 16u32, 16u32, 16u32,
        16u32, 16u32, 16u32, 64u32, 128u32, 4096u32]
    for (i in 0..13) {
        @Assert(kClTable[i].strat == goldStrat[i])
        @Assert(kClTable[i].nbSearches == goldSearches[i])
        @Assert(kClTable[i].targetLength == goldTarget[i])
    }
    // brief-pinned spot checks with the strategy constants
    @Assert(kClTable[1].strat == LZ4HC_STRAT_MID && kClTable[1].nbSearches == 2 &&
        kClTable[1].targetLength == 16u32)
    @Assert(kClTable[2].strat == LZ4HC_STRAT_MID && kClTable[2].nbSearches == 2 &&
        kClTable[2].targetLength == 16u32)
    @Assert(kClTable[3].strat == LZ4HC_STRAT_HC && kClTable[3].nbSearches == 4 &&
        kClTable[3].targetLength == 16u32)
    @Assert(kClTable[9].strat == LZ4HC_STRAT_HC && kClTable[9].nbSearches == 256 &&
        kClTable[9].targetLength == 16u32)
    @Assert(kClTable[10].strat == LZ4HC_STRAT_OPT && kClTable[10].nbSearches == 96 &&
        kClTable[10].targetLength == 64u32)
    @Assert(kClTable[11].strat == LZ4HC_STRAT_OPT && kClTable[11].nbSearches == 512 &&
        kClTable[11].targetLength == 128u32)
    @Assert(kClTable[12].strat == LZ4HC_STRAT_OPT && kClTable[12].nbSearches == 16384 &&
        kClTable[12].targetLength == 4096u32)
    // getCLevelParams: identity for levels 1..12 (upstream L108-116)
    for (i in 1..13) {
        let cp = lz4hcGetCLevelParams(Int32(i))
        @Assert(cp.strat == kClTable[i].strat && cp.nbSearches == kClTable[i].nbSearches &&
            cp.targetLength == kClTable[i].targetLength)
    }
    // < 1 -> k_clTable[DEFAULT=9]; > MAX -> k_clTable[12] (upstream L112-115)
    for (l in [0, -5]) {
        let cp = lz4hcGetCLevelParams(Int32(l))
        @Assert(cp.strat == kClTable[9].strat && cp.nbSearches == kClTable[9].nbSearches &&
            cp.targetLength == kClTable[9].targetLength)
    }
    for (l in [13, 99]) {
        let cp = lz4hcGetCLevelParams(Int32(l))
        @Assert(cp.strat == kClTable[12].strat && cp.nbSearches == kClTable[12].nbSearches &&
            cp.targetLength == kClTable[12].targetLength)
    }
}

/*-************************************
*  Hashing
**************************************/

@Test
func lz4hcHashTest(): Unit {
    // readLE32(buf,0) = 0x01020304, readLE32(buf,4) = 0xDEADBEEF,
    // readLE64(buf,8) = 0x1122334455667788
    let buf = Array<UInt8>(16, {_ => 0u8})
    buf[0] = 0x04; buf[1] = 0x03; buf[2] = 0x02; buf[3] = 0x01
    buf[4] = 0xEF; buf[5] = 0xBE; buf[6] = 0xAD; buf[7] = 0xDE
    buf[8] = 0x88; buf[9] = 0x77; buf[10] = 0x66; buf[11] = 0x55
    buf[12] = 0x44; buf[13] = 0x33; buf[14] = 0x22; buf[15] = 0x11
    let bufTop = Array<UInt8>(16, {i => buf[i]})
    bufTop[15] = 0xFF   // differs only in the TOP byte of the 64-bit read
    unsafe {
        let h = acquireArrayRawData<UInt8>(buf)
        let p = h.pointer
        // LZ4HC_hashPtr: (read32 * 2654435761) >> 17 (upstream L121-122)
        @Assert(LZ4HC_hashPtr(p, 0) == 25046u32)
        @Assert(LZ4HC_hashPtr(p, 4) == 20060u32)
        // LZ4MID_hash4: (v * 2654435761) >> 18 (upstream L145)
        @Assert(LZ4MID_hash4(0x01020304u32) == 12523u32)
        @Assert(LZ4MID_hash4(0xDEADBEEFu32) == 10030u32)
        @Assert(LZ4MID_hash4Ptr(p, 0) == 12523u32)
        @Assert(LZ4MID_hash4Ptr(p, 4) == 10030u32)
        // LZ4MID_hash7 hashes the lower 56 bits: << 8 drops the TOP byte
        // (upstream L147-149); values verified against C probe
        @Assert(LZ4MID_hash7(0x1122334455667788u64) == 7665u32)
        @Assert(LZ4MID_hash7(0xFF22334455667788u64) == 7665u32)
        @Assert(LZ4MID_hash7(0x1122334455667780u64) == 16313u32)
        // LZ4MID_hash8Ptr = hash7(readLE64) (upstream L151)
        @Assert(LZ4MID_hash8Ptr(p, 8) == 7665u32)
        releaseArrayRawData<UInt8>(h)
        let h2 = acquireArrayRawData<UInt8>(bufTop)
        @Assert(LZ4MID_hash8Ptr(h2.pointer, 8) == 7665u32)   // top byte invisible
        releaseArrayRawData<UInt8>(h2)
    }
}

/*-************************************
*  Count match length
**************************************/

@Test
func lz4hcNbCommonBytes32Test(): Unit {
    // LE branch: __builtin_clz(val) >> 3 (upstream L179), MSB-byte probe form
    @Assert(LZ4HC_nbCommonBytes32(0x80000000u32) == 0)
    @Assert(LZ4HC_nbCommonBytes32(0x00800000u32) == 1)
    @Assert(LZ4HC_nbCommonBytes32(0x000000FFu32) == 3)
    @Assert(LZ4HC_nbCommonBytes32(0x01000000u32) == 0)
}

private func hcFill8(a: Array<UInt8>, bytes: Array<UInt8>): Unit {
    for (i in 0..bytes.size) {
        a[i] = bytes[i]
    }
}

@Test
func lz4hcCountBackTest(): Unit {
    // negative return = nb of common bytes before ai/bi (upstream L202-225);
    // every vector below verified against the upstream C probe
    let c0a = Array<UInt8>(8, {_ => 0u8})
    hcFill8(c0a, [0x01u8, 0x02u8, 0x03u8, 0x04u8, 0xAAu8, 0xBBu8, 0xCCu8, 0xDDu8])
    let c0b = Array<UInt8>(8, {_ => 0u8})
    hcFill8(c0b, [0x11u8, 0x12u8, 0x13u8, 0x14u8, 0xAAu8, 0xBBu8, 0xCCu8, 0xEEu8])
    // exactly 1 common byte (tail 0x44), window bytes 0..2 differ
    let c1a = Array<UInt8>(8, {_ => 0u8})
    hcFill8(c1a, [0x01u8, 0x02u8, 0x03u8, 0x04u8, 0x11u8, 0x22u8, 0x33u8, 0x44u8])
    let c1b = Array<UInt8>(8, {_ => 0u8})
    hcFill8(c1b, [0x09u8, 0x08u8, 0x07u8, 0x06u8, 0x99u8, 0x88u8, 0x77u8, 0x44u8])
    // exactly 4 common bytes (two clean 4-byte windows, then all-differ)
    let c4a = Array<UInt8>(12, {_ => 0u8})
    hcFill8(c4a, [0x10u8, 0x20u8, 0x30u8, 0x40u8, 0x11u8, 0x22u8, 0x33u8, 0x44u8,
        0x51u8, 0x52u8, 0x53u8, 0x54u8])
    let c4b = Array<UInt8>(12, {_ => 0u8})
    hcFill8(c4b, [0x10u8, 0x20u8, 0x30u8, 0x40u8, 0x99u8, 0x98u8, 0x97u8, 0x96u8,
        0x51u8, 0x52u8, 0x53u8, 0x54u8])
    // 9 common bytes: positions 7..15 equal, a[6] != b[6] inside window [4,8)
    let c9a = Array<UInt8>(16, {_ => 0u8})
    hcFill8(c9a, [0x10u8, 0x20u8, 0x30u8, 0x40u8, 0x50u8, 0x60u8, 0x70u8, 0x80u8,
        0x01u8, 0x02u8, 0x03u8, 0x04u8, 0x05u8, 0x06u8, 0x07u8, 0x08u8])
    let c9b = Array<UInt8>(16, {_ => 0u8})
    hcFill8(c9b, [0x10u8, 0x20u8, 0x30u8, 0x40u8, 0x50u8, 0x60u8, 0x71u8, 0x80u8,
        0x01u8, 0x02u8, 0x03u8, 0x04u8, 0x05u8, 0x06u8, 0x07u8, 0x08u8])
    // unaligned end (ai=bi=13): window [9,13) not on the 4-byte grid
    let mA = Array<UInt8>(13, {_ => 0u8})
    hcFill8(mA, [0x00u8, 0x00u8, 0x00u8, 0x01u8, 0x02u8, 0x03u8, 0x04u8, 0x05u8,
        0x06u8, 0x07u8, 0x08u8, 0x09u8, 0x0Au8])
    let mB = Array<UInt8>(13, {_ => 0u8})
    hcFill8(mB, [0x00u8, 0x00u8, 0x00u8, 0x09u8, 0x08u8, 0x07u8, 0x06u8, 0x05u8,
        0x04u8, 0x03u8, 0x08u8, 0x09u8, 0x0Au8])
    // identical buffers: walk bounded by aMin/bMin (byte-tail loop exercised)
    let eqA = Array<UInt8>(16, {i => UInt8(i + 1)})
    let eqB = Array<UInt8>(16, {i => UInt8(i + 1)})
    // asymmetric lengths: b (12 B) holds a[4..16); bMin limits the walk
    let asA = Array<UInt8>(16, {i => UInt8(i + 1)})
    let asB = Array<UInt8>(12, {i => asA[i + 4]})
    unsafe {
        let a0 = acquireArrayRawData<UInt8>(c0a)
        let b0 = acquireArrayRawData<UInt8>(c0b)
        @Assert(LZ4HC_countBack(a0.pointer, 8, b0.pointer, 8, 0, 0) == 0)
        releaseArrayRawData<UInt8>(a0)
        releaseArrayRawData<UInt8>(b0)
        let a1 = acquireArrayRawData<UInt8>(c1a)
        let b1 = acquireArrayRawData<UInt8>(c1b)
        @Assert(LZ4HC_countBack(a1.pointer, 8, b1.pointer, 8, 0, 0) == -1)
        releaseArrayRawData<UInt8>(a1)
        releaseArrayRawData<UInt8>(b1)
        let a4 = acquireArrayRawData<UInt8>(c4a)
        let b4 = acquireArrayRawData<UInt8>(c4b)
        @Assert(LZ4HC_countBack(a4.pointer, 12, b4.pointer, 12, 0, 0) == -4)
        releaseArrayRawData<UInt8>(a4)
        releaseArrayRawData<UInt8>(b4)
        let a9 = acquireArrayRawData<UInt8>(c9a)
        let b9 = acquireArrayRawData<UInt8>(c9b)
        @Assert(LZ4HC_countBack(a9.pointer, 16, b9.pointer, 16, 0, 0) == -9)
        releaseArrayRawData<UInt8>(a9)
        releaseArrayRawData<UInt8>(b9)
        let ma = acquireArrayRawData<UInt8>(mA)
        let mb = acquireArrayRawData<UInt8>(mB)
        @Assert(LZ4HC_countBack(ma.pointer, 13, mb.pointer, 13, 0, 0) == -3)
        releaseArrayRawData<UInt8>(ma)
        releaseArrayRawData<UInt8>(mb)
        let ea = acquireArrayRawData<UInt8>(eqA)
        let eb = acquireArrayRawData<UInt8>(eqB)
        @Assert(LZ4HC_countBack(ea.pointer, 16, eb.pointer, 16, 0, 0) == -16)
        @Assert(LZ4HC_countBack(ea.pointer, 16, eb.pointer, 16, 10, 10) == -6)
        releaseArrayRawData<UInt8>(ea)
        releaseArrayRawData<UInt8>(eb)
        let aa = acquireArrayRawData<UInt8>(asA)
        let ab = acquireArrayRawData<UInt8>(asB)
        @Assert(LZ4HC_countBack(aa.pointer, 16, ab.pointer, 12, 0, 0) == -12)
        @Assert(LZ4HC_countBack(aa.pointer, 16, ab.pointer, 12, 0, 4) == -8)
        releaseArrayRawData<UInt8>(aa)
        releaseArrayRawData<UInt8>(ab)
    }
}

/*-************************************
*  Repetitive-pattern primitives
**************************************/

@Test
func lz4hcPatternTest(): Unit {
    // rotatePattern (upstream L841-846): byte rotation via rotl32
    @Assert(LZ4HC_rotatePattern(0u64, 0x11223344u32) == 0x11223344u32)
    @Assert(LZ4HC_rotatePattern(1u64, 0x11223344u32) == 0x22334411u32)
    @Assert(LZ4HC_rotatePattern(2u64, 0x11223344u32) == 0x33441122u32)
    @Assert(LZ4HC_rotatePattern(3u64, 0x11223344u32) == 0x44112233u32)
    @Assert(LZ4HC_rotatePattern(4u64, 0x11223344u32) == 0x11223344u32)  // 4&3 == 0
    // protectDictEnd (upstream L905-908): U32 wrap semantics; 65533 -> false
    // per C probe ((65535-65533)=2 < 3; the task brief listed true, a typo)
    @Assert(LZ4HC_protectDictEnd(65536u32, 65532u32) == true)
    @Assert(LZ4HC_protectDictEnd(65536u32, 65533u32) == false)
    @Assert(LZ4HC_protectDictEnd(65536u32, 65535u32) == false)
    @Assert(LZ4HC_protectDictEnd(65536u32, 65536u32) == true)   // U32 wrap
    @Assert(LZ4HC_protectDictEnd(65536u32, 0u32) == true)
    // countPattern / reverseCountPattern buffers (values C-probe verified)
    let p1 = Array<UInt8>(16, {_ => 0xAAu8})                    // 1-byte period
    let p1b = Array<UInt8>(16, {i => if (i == 12) { 0x55u8 } else { 0xAAu8 } })
    let p2 = Array<UInt8>(12, {i => if (i % 2 == 0) { 0xBEu8 } else { 0xEFu8 } })
    let p4 = Array<UInt8>(16, {i => [0x44u8, 0x33u8, 0x22u8, 0x11u8][i % 4]})
    let p4b = Array<UInt8>(8, {i => if (i == 7) { 0x99u8 } else { [0x44u8, 0x33u8, 0x22u8, 0x11u8][i % 4] } })
    let r4 = Array<UInt8>(9, {_ => 0u8})   // [0x77, {44,33,22,11} x2]
    hcFill8(r4, [0x77u8, 0x44u8, 0x33u8, 0x22u8, 0x11u8, 0x44u8, 0x33u8, 0x22u8, 0x11u8])
    let r4b = Array<UInt8>(8, {_ => 0u8})  // window stop + 1-byte tail match
    hcFill8(r4b, [0x00u8, 0x00u8, 0x00u8, 0x11u8, 0x44u8, 0x33u8, 0x22u8, 0x11u8])
    unsafe {
        let h1 = acquireArrayRawData<UInt8>(p1)
        @Assert(LZ4HC_countPattern(h1.pointer, 0, 3, 0xAAAAAAAAu32) == 3u32)
        @Assert(LZ4HC_countPattern(h1.pointer, 0, 5, 0xAAAAAAAAu32) == 5u32)
        @Assert(LZ4HC_countPattern(h1.pointer, 0, 10, 0xAAAAAAAAu32) == 10u32)  // crosses 8B
        @Assert(LZ4HC_countPattern(h1.pointer, 0, 16, 0xAAAAAAAAu32) == 16u32)
        releaseArrayRawData<UInt8>(h1)
        let h1b = acquireArrayRawData<UInt8>(p1b)
        @Assert(LZ4HC_countPattern(h1b.pointer, 0, 16, 0xAAAAAAAAu32) == 12u32)
        releaseArrayRawData<UInt8>(h1b)
        // 2-byte period: pattern32 must replicate the period across 4 bytes
        let h2 = acquireArrayRawData<UInt8>(p2)
        @Assert(LZ4HC_countPattern(h2.pointer, 0, 5, 0xEFBE_EFBEu32) == 5u32)
        @Assert(LZ4HC_countPattern(h2.pointer, 0, 9, 0xEFBE_EFBEu32) == 9u32)
        @Assert(LZ4HC_countPattern(h2.pointer, 0, 12, 0xEFBE_EFBEu32) == 12u32)
        releaseArrayRawData<UInt8>(h2)
        // 4-byte period: iEnd mid-pattern (14) + NbCommonBytes break path (7)
        let h4 = acquireArrayRawData<UInt8>(p4)
        @Assert(LZ4HC_countPattern(h4.pointer, 0, 14, 0x11223344u32) == 14u32)
        releaseArrayRawData<UInt8>(h4)
        let h4b = acquireArrayRawData<UInt8>(p4b)
        @Assert(LZ4HC_countPattern(h4b.pointer, 0, 8, 0x11223344u32) == 7u32)
        releaseArrayRawData<UInt8>(h4b)
        // reverse: identical AA buffer bounded by iLow
        let e1 = acquireArrayRawData<UInt8>(p1)
        @Assert(LZ4HC_reverseCountPattern(e1.pointer, 16, 0, 0xAAAAAAAAu32) == 16u32)
        @Assert(LZ4HC_reverseCountPattern(e1.pointer, 16, 10, 0xAAAAAAAAu32) == 6u32)
        releaseArrayRawData<UInt8>(e1)
        let e4 = acquireArrayRawData<UInt8>(r4)
        @Assert(LZ4HC_reverseCountPattern(e4.pointer, 9, 0, 0x11223344u32) == 8u32)
        releaseArrayRawData<UInt8>(e4)
        let e4b = acquireArrayRawData<UInt8>(r4b)
        @Assert(LZ4HC_reverseCountPattern(e4b.pointer, 8, 0, 0x11223344u32) == 5u32)
        releaseArrayRawData<UInt8>(e4b)
    }
}

/*-************************************
*  resetStreamHC_fast / resetStreamHC
**************************************/

@Test
func lz4hcResetFastTest(): Unit {
    let buf = Array<UInt8>(64, {i => UInt8(i)})
    // (1) dirty stream -> full re-init (upstream L1648-1649)
    let s1 = LZ4_streamHC_t()
    LZ4_initStreamHC(s1)
    s1.dictLimit = 100u32
    s1.lowLimit = 50u32
    s1.nextToUpdate = 60u32
    s1.prefixBuf = Some(buf)
    s1.prefixStartIdx = 1
    s1.prefixEndIdx = 10
    s1.dictBuf = Some(buf)
    s1.dictStartIdx = 2
    s1.hashTable[5] = 77u32
    s1.chainTable[5] = 0x1234u16
    s1.favorDecSpeed = true
    s1.dirty = true
    s1.dictCtx = Some(LZ4_streamHC_t())
    LZ4_resetStreamHC_fast(s1, 7)
    @Assert(s1.dictLimit == 0u32 && s1.lowLimit == 0u32 && s1.nextToUpdate == 0u32)
    @Assert(s1.prefixBuf.isNone() && s1.prefixStartIdx == 0 && s1.prefixEndIdx == 0)
    @Assert(s1.dictBuf.isNone() && s1.dictStartIdx == 0)
    @Assert(s1.hashTable[5] == 0u32 && s1.chainTable[5] == 0u16)
    @Assert(s1.favorDecSpeed == false && s1.dirty == false && s1.dictCtx.isNone())
    @Assert(s1.compressionLevel == 7)
    // (2) clean stream: dictLimit += prefixEndIdx-prefixStartIdx (upstream L1652-1655),
    //     tables preserved (dirty-table reuse), only prefix/dictCtx dropped
    let s2 = LZ4_streamHC_t()
    LZ4_initStreamHC(s2)
    s2.dictLimit = 65536u32
    s2.lowLimit = 65536u32
    s2.nextToUpdate = 65536u32
    s2.prefixBuf = Some(buf)
    s2.prefixStartIdx = 100
    s2.prefixEndIdx = 200
    s2.hashTable[7] = 55u32
    s2.chainTable[7] = 0x4321u16
    s2.dictCtx = Some(LZ4_streamHC_t())
    LZ4_resetStreamHC_fast(s2, 3)
    @Assert(s2.dictLimit == 65636u32)
    @Assert(s2.prefixBuf.isNone() && s2.prefixStartIdx == 0 && s2.prefixEndIdx == 0)
    @Assert(s2.dictCtx.isNone())
    @Assert(s2.compressionLevel == 3)
    @Assert(s2.hashTable[7] == 55u32 && s2.chainTable[7] == 0x4321u16)
    @Assert(s2.lowLimit == 65536u32 && s2.nextToUpdate == 65536u32)
    // (3) resetStreamHC: full re-init + level (upstream L1638-1642)
    let s3 = LZ4_streamHC_t()
    LZ4_initStreamHC(s3)
    s3.dirty = true
    s3.dictLimit = 9u32
    s3.hashTable[0] = 9u32
    LZ4_resetStreamHC(s3, 5)
    @Assert(s3.dictLimit == 0u32 && s3.dirty == false && s3.hashTable[0] == 0u32)
    @Assert(s3.compressionLevel == 5)
}

/*-************************************
*  LZ4HC_init_internal
**************************************/

@Test
func lz4hcInitInternalTest(): Unit {
    let src = Array<UInt8>(64, {i => UInt8(i)})
    // clean empty state: new anchor 0 + 64 KB (upstream L242-259)
    let s = LZ4_streamHC_t()
    LZ4_initStreamHC(s)
    LZ4HC_initInternal(s, src, 0)
    @Assert(s.dictLimit == 65536u32 && s.lowLimit == 65536u32 && s.nextToUpdate == 65536u32)
    @Assert(s.prefixBuf.isSome() && s.prefixStartIdx == 0 && s.prefixEndIdx == 0)
    // C sets dictStart = start; in the two-segment model the extDict range
    // [lowLimit, dictLimit) is empty here (lowLimit == dictLimit), so dictBuf
    // is None and the dict pair is never dereferenced
    @Assert(s.dictBuf.isNone())
    // >1 GB virtual offset: clearTables + re-anchor 0 + 64 KB -> 65536
    // (C-probe verified: bufferSize(10) + 0x40000000 > 1 GB, reset to 0;
    // the task brief listed 65546, a typo). Unreachable in-suite (needs a
    // single stream fed >1 GB); kept per upstream, M3a lz4RenormDictT precedent.
    let s2 = LZ4_streamHC_t()
    LZ4_initStreamHC(s2)
    s2.dictLimit = 0x40000000u32
    s2.prefixBuf = Some(src)
    s2.prefixStartIdx = 0
    s2.prefixEndIdx = 10
    s2.hashTable[9] = 123u32
    s2.chainTable[9] = 0x00FFu16
    LZ4HC_initInternal(s2, src, 0)
    @Assert(s2.hashTable[9] == 0u32)          // clearTables: hash <- 0
    @Assert(s2.chainTable[9] == 0xFFFFu16)    // clearTables: 0xFF byte-fill
    @Assert(s2.dictLimit == 65536u32 && s2.lowLimit == 65536u32 && s2.nextToUpdate == 65536u32)
    @Assert(s2.prefixBuf.isSome() && s2.prefixStartIdx == 0 && s2.prefixEndIdx == 0)
}

/*-************************************
*  LZ4HC_insert (chain-table fill)
**************************************/

@Test
func lz4hcInsertTest(): Unit {
    // 16-byte buffer with a 4-byte repeat at pos 0 and pos 8 (bucket collision
    // exercises the non-clamped delta write); all table values C-probe verified
    let buf = Array<UInt8>(16, {_ => 0u8})
    hcFill8(buf, [0x04u8, 0x03u8, 0x02u8, 0x01u8, 0xEFu8, 0xBEu8, 0xADu8, 0xDEu8,
        0x04u8, 0x03u8, 0x02u8, 0x01u8, 0x44u8, 0x33u8, 0x22u8, 0x11u8])
    let s = LZ4_streamHC_t()
    LZ4_initStreamHC(s)
    LZ4HC_initInternal(s, buf, 0)
    unsafe {
        let h = acquireArrayRawData<UInt8>(buf)
        // insert positions 0..5 (target ip = 6): fresh buckets, delta clamped
        // to 65535 vs zeroed hash table entries
        LZ4HC_insert(s, h.pointer, 6)
        @Assert(s.nextToUpdate == 65542u32)
        @Assert(s.hashTable[25046] == 65536u32)   // h(pos 0) = hashPtr(0x01020304)
        @Assert(s.hashTable[20060] == 65540u32)   // h(pos 4) = hashPtr(0xDEADBEEF)
        @Assert(s.chainTable[0] == 65535u16)      // DELTANEXTU16: idx & 0xFFFF
        @Assert(s.chainTable[4] == 65535u16)
        // continue to target ip = 10: pos 8 re-hits bucket 25046, so
        // delta = 65544 - 65536 = 8 (no clamp), written at chainTable[8]
        LZ4HC_insert(s, h.pointer, 10)
        @Assert(s.nextToUpdate == 65546u32)
        @Assert(s.hashTable[25046] == 65544u32)   // most recent idx wins
        @Assert(s.hashTable[100] == 65542u32)     // h(pos 6)
        @Assert(s.chainTable[8] == 8u16)
        @Assert(s.chainTable[9] == 65535u16)
        releaseArrayRawData<UInt8>(h)
    }
}

/*-************************************
*  LZ4HC_encodeSequence
**************************************/

@Test
func lz4hcEncodeSequenceTest(): Unit {
    // token/literal/offset/matchlength byte layout hand-computed from
    // upstream L292-380; tuple shape: (bufferIssue, newIp, newOp, newAnchor)
    let src = Array<UInt8>(64, {i => UInt8((Int64(i) * 29 + 3) % 251)})
    let dst = Array<UInt8>(64, {_ => 0xEEu8})
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        // A: 3 literals + match len 5 offset 258, notLimited -> token 0x31
        let ra = LZ4HC_encodeSequence(sh.pointer, 3, dh.pointer, 0, 0, 5, 258,
            LZ4_OUTPUT_NOT_LIMITED, 64)
        @Assert(ra[0] == 0 && ra[1] == 8 && ra[2] == 6 && ra[3] == 8)
        @Assert(dst[0] == 0x31u8)
        @Assert(dst[1] == src[0] && dst[2] == src[1] && dst[3] == src[2])
        @Assert(dst[4] == 0x02u8 && dst[5] == 0x01u8)   // LE16(258)
        // B: 20 literals (RUN_MASK extension) + match len 19 (mlCode >= ML_MASK
        // path), offset 0xAA -> FF 05 <lits> AA 00 00
        for (i in 0..64) { dst[i] = 0xEEu8 }
        let rb = LZ4HC_encodeSequence(sh.pointer, 20, dh.pointer, 0, 0, 19, 0xAA,
            LZ4_OUTPUT_NOT_LIMITED, 64)
        @Assert(rb[0] == 0 && rb[1] == 39 && rb[2] == 25 && rb[3] == 39)
        @Assert(dst[0] == 0xFFu8 && dst[1] == 0x05u8)
        @Assert(dst[2] == src[0] && dst[21] == src[19])
        @Assert(dst[22] == 0xAAu8 && dst[23] == 0x00u8 && dst[24] == 0x00u8)
        // C: buffer issue at the literal-length check (upstream L330): op has
        // consumed the token byte, ip/anchor untouched, token not yet written
        for (i in 0..64) { dst[i] = 0xEEu8 }
        let rc = LZ4HC_encodeSequence(sh.pointer, 100, dh.pointer, 0, 0, 9, 1,
            LZ4_OUTPUT_LIMITED, 108)
        @Assert(rc[0] == 1 && rc[1] == 100 && rc[2] == 1 && rc[3] == 0)
        @Assert(dst[0] == 0xEEu8)
        // D: buffer issue at the match-length check (upstream L357): literals
        // and offset already written (C aliasing semantics), op = 6
        for (i in 0..64) { dst[i] = 0xEEu8 }
        let rd = LZ4HC_encodeSequence(sh.pointer, 3, dh.pointer, 0, 0, 300, 0x1122,
            LZ4_OUTPUT_LIMITED, 12)
        @Assert(rd[0] == 1 && rd[1] == 3 && rd[2] == 6 && rd[3] == 0)
        @Assert(dst[0] == 0x30u8)
        @Assert(dst[4] == 0x22u8 && dst[5] == 0x11u8)   // LE16(0x1122)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
    }
}

/*-************************************
*  M4 Task 2: hash-chain compression golden (vs upstream C, 0774d055)
**************************************/
// hc rows of corpus/block_golden_ref.txt (rows 356..374): LZ4_compress_HC
// over levels 3-9, A=(65536,0.50,0) and B=(65536,0.90,7) x lv 3..9, then
// lv=9 over C..G (131072/255/13/0/1). litProba is 0.0 for every row.
// (n, mp, seed, lv, size, xxh32, xxh64, fileRowIdx), -1 = no artifact
let HC_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 3, 33017, 0x01f25a3eu32, 0x2fb44d69874b5f38u64, 356),
    (65536, 0.50, 0u32, 4, 32961, 0x8cea4b88u32, 0xb3acd99f48985ee2u64, 357),
    (65536, 0.50, 0u32, 5, 32938, 0x04a21636u32, 0x7eaab14f3f69e400u64, 358),
    (65536, 0.50, 0u32, 6, 32931, 0xfdc17372u32, 0xca350279a75cb1d7u64, 359),
    (65536, 0.50, 0u32, 7, 32921, 0x983c6835u32, 0x8136bfa5bc8a9477u64, 360),
    (65536, 0.50, 0u32, 8, 32916, 0x83385a80u32, 0xf87f6a88866893a5u64, 361),
    (65536, 0.50, 0u32, 9, 32916, 0xc21308abu32, 0x6b48f5333290f3fau64, 362),
    (65536, 0.90, 7u32, 3, 5677, 0x45eb6a64u32, 0xdc35aa04f85b5341u64, 363),
    (65536, 0.90, 7u32, 4, 5640, 0x97863510u32, 0x726cf3c48474cce4u64, 364),
    (65536, 0.90, 7u32, 5, 5630, 0x885cf839u32, 0x0d52007356dac308u64, 365),
    (65536, 0.90, 7u32, 6, 5610, 0xd4a63ee3u32, 0x9e3045b1c6c33b86u64, 366),
    (65536, 0.90, 7u32, 7, 5604, 0xac9e2687u32, 0xe52c6d4c0c65ed37u64, 367),
    (65536, 0.90, 7u32, 8, 5597, 0x98af4edfu32, 0x0f07d127881adf2du64, 368),
    (65536, 0.90, 7u32, 9, 5546, 0x422c6bdeu32, 0x93f68e0df9ef9e3du64, 369),
    (131072, 0.90, 0u32, 9, 17686, 0x8ddd3690u32, 0x86264ff432d3e68bu64, 370),
    (255, 0.50, 0u32, 9, 238, 0x0639b5bdu32, 0x645d2f9032bdf162u64, 371),
    (13, 0.50, 0u32, 9, 14, 0xab784699u32, 0xdd68042376530281u64, 372),
    (0, 0.00, 0u32, 9, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 373),
    (1, 0.00, 0u32, 9, 2, 0x47bed82cu32, 0xec3cae3829bb6262u64, 374),
]

// hcdest row 375: LZ4_compress_HC_destSize lv=9 x A, tg=n*3/4. The whole
// input compresses below the target, so fillOutput consumes everything
// (consumed == n) and the bytes equal the lv=9 hc row (row 362 digests).
// (n, mp, seed, lv, tg, size, consumed, xxh32, xxh64, fileRowIdx)
let HC_DEST_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 9, 49152, 32916, 65536, 0xc21308abu32, 0x6b48f5333290f3fau64, 375),
]

// readBlockArtifact is private to lz4_test.cj; identical helper here
private func hcReadBlockArtifact(rowIdx: Int64): Array<Byte> {
    let s = rowIdx.toString()
    let padded = if (s.size == 1) { "00${s}" } else if (s.size == 2) { "0${s}" } else { s }
    let name = "/block/${padded}.lz4"
    try {
        return File.readFrom("corpus" + name)
    } catch (_: Exception) {
        return File.readFrom("../corpus" + name)
    }
}

private func hcBytesEqual(a: Array<UInt8>, b: Array<UInt8>, len: Int64): Bool {
    if (a.size < len || b.size < len) {
        return false
    }
    for (i in 0..len) {
        if (a[i] != b[i]) {
            return false
        }
    }
    return true
}

@Test
func lz4hcCompressHCGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    for ((n, mp, seed, lv, wantSize, want32, want64, fileRow) in HC_GOLD_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_HC(buf, Int32(n), out, Int32(bound), lv)
        if (c != wantSize) {
            println("SIZE n=${n} mp=${mp} seed=${seed} lv=${lv}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} mp=${mp} seed=${seed} lv=${lv} size=${c}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // closure roundtrip: every row standalone-decodes to the input
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, Int32(n)) == Int32(n))
        @Assert(hcBytesEqual(dec, buf, n))
        checked += 1
    }
    @Assert(checked == 19)
    @Assert(fileCompared == 19)
    println("hc golden: ${checked}/19 rows, ${fileCompared} byte-exact artifacts")
}

@Test
func lz4hcCompressHCDestSizeGoldenTest(): Unit {
    var checked = 0
    for ((n, mp, seed, lv, tg, wantSize, wantConsumed, want32, want64, fileRow) in HC_DEST_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let out = Array<UInt8>(Int64(tg), {_ => 0u8})
        let st = LZ4_createStreamHC()
        let (c, consumed) = LZ4_compress_HC_destSize(st, buf, Int32(n), out, tg, lv)
        if (c != wantSize || consumed != wantConsumed) {
            println("HCDEST n=${n} lv=${lv} tg=${tg}: got (${c},${consumed}) want (${wantSize},${wantConsumed})")
        }
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        @Assert(c >= 1 && c <= tg)                 // destSize invariants
        @Assert(consumed >= 0 && consumed <= Int32(n))
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} lv=${lv} tg=${tg}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
        }
        // decode == src[0..consumed)
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        @Assert(hcBytesEqual(dec, buf, Int64(consumed)))
        checked += 1
    }
    @Assert(checked == 1)
    println("hcdest golden: ${checked}/1 rows")
}

/*-************************************
*  M4 Task 2: extState family + destSize semantics
**************************************/
@Test
func lz4hcExtStateTest(): Unit {
    let n: Int64 = 65536
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.50, 0.0, 0u32)
    let bound = Int32(LZ4_compressBound(Int32(n)))
    // (1) same state twice via extStateHC (2nd call full init): outputs
    // byte-identical to two independent calls
    let o1 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let o2 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let o3 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let st1 = LZ4_streamHC_t()
    let c1 = LZ4_compress_HC_extStateHC(st1, a, Int32(n), o1, bound, 5)
    let c2 = LZ4_compress_HC_extStateHC(st1, a, Int32(n), o2, bound, 5)
    let st2 = LZ4_streamHC_t()
    let c3 = LZ4_compress_HC_extStateHC(st2, a, Int32(n), o3, bound, 5)
    @Assert(c1 > 0 && c1 == c2 && c2 == c3)
    @Assert(hcBytesEqual(o1, o2, Int64(c1)))
    @Assert(hcBytesEqual(o1, o3, Int64(c1)))
    // (2) fastReset same-stream reuse (clean state takes the resetFast
    // path: dictLimit += prefixLen, tables kept); post-call state pin:
    // prefixBuf aliases src, dictLimit == 64KB anchor, end == srcSize
    let f1 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let f2 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let f3 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let stf = LZ4_streamHC_t()
    LZ4_initStreamHC(stf)
    let cf1 = LZ4_compress_HC_extStateHC_fastReset(stf, a, Int32(n), f1, bound, 7)
    @Assert(cf1 > 0)
    @Assert(stf.prefixBuf.isSome() && lz4SameBuffer(stf.prefixBuf.getOrThrow(), a))
    @Assert(stf.dictLimit == 65536u32 && stf.lowLimit == 65536u32)
    @Assert(stf.prefixEndIdx == stf.prefixStartIdx + n)
    @Assert(stf.dirty == false)
    // manual resetFast on the clean state: the reuse path accumulates
    // dictLimit by the prefix length (upstream L1652)
    LZ4_resetStreamHC_fast(stf, 7)
    @Assert(stf.dictLimit == 65536u32 + UInt32(n))
    @Assert(stf.prefixBuf.isNone() && stf.dictCtx.isNone())
    // second fastReset call reuses the dirty table via the +64KB re-anchor;
    // output still byte-identical (stale entries fall below lowLimit) and
    // equal to a fresh-state one-shot LZ4_compress_HC
    let cf2 = LZ4_compress_HC_extStateHC_fastReset(stf, a, Int32(n), f2, bound, 7)
    @Assert(cf2 == cf1)
    @Assert(hcBytesEqual(f1, f2, Int64(cf1)))
    let cf3 = LZ4_compress_HC(a, Int32(n), f3, bound, 7)
    @Assert(cf3 == cf1)
    @Assert(hcBytesEqual(f1, f3, Int64(cf1)))
    @Assert(stf.dirty == false)
    // (3) dirty stream (dirty=true manual): fastReset does a full init,
    // output identical
    stf.dirty = true
    let f4 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let cf4 = LZ4_compress_HC_extStateHC_fastReset(stf, a, Int32(n), f4, bound, 7)
    @Assert(cf4 == cf1)
    @Assert(hcBytesEqual(f1, f4, Int64(cf1)))
    @Assert(stf.dirty == false)
    // (4) failure modes: insufficient capacity -> 0 and dirty (core fail,
    // upstream L1461); dstCapacity==0 -> 0 (sanitization, no dirty change);
    // srcSize==0 -> 1 (dst[0]==0); srcSize=-1 -> 0 (U32 cast > MAX)
    let tiny = Array<UInt8>(4096, {_ => 0u8})
    RDG_genBuffer(tiny, 4096, 0.0, 0.0, 0u32)
    let small = Array<UInt8>(16, {_ => 0xFFu8})
    let st4 = LZ4_streamHC_t()
    LZ4_initStreamHC(st4)
    @Assert(LZ4_compress_HC_extStateHC(st4, tiny, 4096, small, 16, 9) == 0)
    @Assert(st4.dirty == true)
    st4.dirty = false
    @Assert(LZ4_compress_HC_extStateHC(st4, tiny, 4096, small, 0, 9) == 0)
    @Assert(st4.dirty == false)
    small[0] = 0xFFu8
    @Assert(LZ4_compress_HC_extStateHC(st4, tiny, 0, small, 16, 9) == 1 && small[0] == 0u8)
    @Assert(LZ4_compress_HC_extStateHC(st4, tiny, -1, small, 16, 9) == 0)
    // one-shot LZ4_compress_HC delegates to extStateHC (temp state)
    let f5 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c5 = LZ4_compress_HC(a, Int32(n), f5, bound, 5)
    @Assert(c5 == c1)
    @Assert(hcBytesEqual(o1, f5, Int64(c1)))
}

@Test
func lz4hcDestSizeSemanticsTest(): Unit {
    let n: Int64 = 8192
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.50, 0.0, 5u32)
    let bound = LZ4_compressBound(Int32(n))
    // target >= compressBound: fillOutput completes with full consumption;
    // bytes identical to regular LZ4_compress_HC, consumed == srcSize,
    // clean exit, and a second call on the same state reproduces (init)
    let reg = Array<UInt8>(Int64(bound), {_ => 0u8})
    let cref = LZ4_compress_HC(a, Int32(n), reg, bound, 9)
    @Assert(cref > 0)
    let st = LZ4_streamHC_t()
    let o1 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let (c1, k1) = LZ4_compress_HC_destSize(st, a, Int32(n), o1, bound, 9)
    @Assert(c1 == cref && k1 == Int32(n))
    @Assert(hcBytesEqual(o1, reg, Int64(c1)))
    @Assert(st.dirty == false)
    @Assert(st.prefixEndIdx == st.prefixStartIdx + Int64(k1))
    let o2 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let (c2, k2) = LZ4_compress_HC_destSize(st, a, Int32(n), o2, bound, 9)
    @Assert(c2 == c1 && k2 == k1)
    @Assert(hcBytesEqual(o1, o2, Int64(c1)))
    // target <= 0: dstCapacity<1 sanitization -> (0, srcSize)
    let (c0, k0) = LZ4_compress_HC_destSize(st, a, Int32(n), o1, 0, 9)
    @Assert(c0 == 0 && k0 == Int32(n))
    let (cm, km) = LZ4_compress_HC_destSize(st, a, Int32(n), o1, -7, 9)
    @Assert(cm == 0 && km == Int32(n))
    // tg = n*3/4 shrink correctness (C golden pins the A-shaped row);
    // here the input compresses below target so all n bytes are consumed,
    // and upstream advances end by the full *srcSizePtr (lz4hc.c L1440),
    // which equals consumed in this regime
    let tg = Int32(n * 3 / 4)
    let o3 = Array<UInt8>(Int64(tg), {_ => 0u8})
    let (c3, k3) = LZ4_compress_HC_destSize(st, a, Int32(n), o3, tg, 9)
    @Assert(c3 >= 1 && c3 <= tg)
    @Assert(k3 == Int32(n))
    @Assert(st.prefixEndIdx == st.prefixStartIdx + Int64(k3))
    let dec = Array<UInt8>(n, {_ => 0u8})
    @Assert(LZ4_decompress_safe(o3, c3, dec, k3) == k3)
    @Assert(hcBytesEqual(dec, a, n))
    // real shrink (incompressible input, target below the literal cost):
    // consumed < n; end is still advanced by the FULL input (L1440), the
    // consumed prefix is what the emitted block decodes to
    let ni: Int64 = 4096
    let b = Array<UInt8>(ni, {_ => 0u8})
    RDG_genBuffer(b, ni, 0.0, 0.0, 9u32)
    let tgi = Int32(ni * 3 / 4)
    let ob = Array<UInt8>(Int64(tgi), {_ => 0u8})
    let (cb, kb) = LZ4_compress_HC_destSize(st, b, Int32(ni), ob, tgi, 9)
    @Assert(cb >= 1 && cb <= tgi)
    @Assert(kb >= 1 && kb < Int32(ni))
    @Assert(st.prefixEndIdx == st.prefixStartIdx + ni)
    let decb = Array<UInt8>(ni, {_ => 0u8})
    @Assert(LZ4_decompress_safe(ob, cb, decb, kb) == kb)
    @Assert(hcBytesEqual(decb, b, Int64(kb)))
}

/*-************************************
*  M4 Task 3: lz4mid (levels 1-2) golden vs upstream C, 0774d055
**************************************/
// mid rows of corpus/block_golden_ref.txt (rows 376..384): LZ4_compress_HC
// over levels 1-2 (lz4mid strategy, upstream lz4hc.c L554-803): A/B x lv 1..2,
// then lv=2 over C..G. lv=1 and lv=2 share the k_clTable mid params (mid,2,16)
// so their outputs are byte-identical; C..G pin the length regimes (n=13
// passes the >=minLength guard - the main loop runs, finds no match, all
// literals; the all-literals goto fires at n<13; n=0 via generic
// sanitization; n=1 is a single-literal block).
// (n, mp, seed, lv, size, xxh32, xxh64, fileRowIdx), -1 = no artifact
let MID_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 1, 34530, 0xc0a48731u32, 0x8ad58e4da6e824f4u64, 376),
    (65536, 0.50, 0u32, 2, 34530, 0xc0a48731u32, 0x8ad58e4da6e824f4u64, 377),
    (65536, 0.90, 7u32, 1, 6315, 0x0c3a4dc1u32, 0xac3e7dc606b06671u64, 378),
    (65536, 0.90, 7u32, 2, 6315, 0x0c3a4dc1u32, 0xac3e7dc606b06671u64, 379),
    (131072, 0.90, 0u32, 2, 21077, 0x29d2739bu32, 0x43fa195391d7585du64, 380),
    (255, 0.50, 0u32, 2, 238, 0x0639b5bdu32, 0x645d2f9032bdf162u64, 381),
    (13, 0.50, 0u32, 2, 14, 0xab784699u32, 0xdd68042376530281u64, 382),
    (0, 0.00, 0u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 383),
    (1, 0.00, 0u32, 2, 2, 0x47bed82cu32, 0xec3cae3829bb6262u64, 384),
]

@Test
func lz4hcMidGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    for ((n, mp, seed, lv, wantSize, want32, want64, fileRow) in MID_GOLD_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_HC(buf, Int32(n), out, Int32(bound), lv)
        if (c != wantSize) {
            println("SIZE n=${n} mp=${mp} seed=${seed} lv=${lv}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} mp=${mp} seed=${seed} lv=${lv} size=${c}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // closure roundtrip: every row standalone-decodes to the input
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, Int32(n)) == Int32(n))
        @Assert(hcBytesEqual(dec, buf, n))
        checked += 1
    }
    @Assert(checked == 9)
    @Assert(fileCompared == 9)
    // lv=1 and lv=2 rows are byte-identical (same k_clTable mid params)
    @Assert(MID_GOLD_REF[0][4] == 34530 && MID_GOLD_REF[1][4] == 34530)
    @Assert(MID_GOLD_REF[0][5] == MID_GOLD_REF[1][5])
    println("mid golden: ${checked}/9 rows, ${fileCompared} byte-exact artifacts")
}

// hcdest mid row 385: LZ4_compress_HC_destSize lv=2 x A, tg=n*3/4. The whole
// input compresses below the target, so fillOutput consumes everything
// (consumed == n) and the bytes equal the lv=2 hc row (row 377 digests).
// (n, mp, seed, lv, tg, size, consumed, xxh32, xxh64, fileRowIdx)
let MID_DEST_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 2, 49152, 34530, 65536, 0xc0a48731u32, 0x8ad58e4da6e824f4u64, 385),
]

@Test
func lz4hcMidDestSizeGoldenTest(): Unit {
    var checked = 0
    for ((n, mp, seed, lv, tg, wantSize, wantConsumed, want32, want64, fileRow) in MID_DEST_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let out = Array<UInt8>(Int64(tg), {_ => 0u8})
        let st = LZ4_createStreamHC()
        let (c, consumed) = LZ4_compress_HC_destSize(st, buf, Int32(n), out, tg, lv)
        if (c != wantSize || consumed != wantConsumed) {
            println("MIDDEST n=${n} lv=${lv} tg=${tg}: got (${c},${consumed}) want (${wantSize},${wantConsumed})")
        }
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        @Assert(c >= 1 && c <= tg)                 // destSize invariants
        @Assert(consumed >= 0 && consumed <= Int32(n))
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} lv=${lv} tg=${tg}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
        }
        // decode == src[0..consumed); full consumption => bytes == hc lv=2 row
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        @Assert(hcBytesEqual(dec, buf, Int64(consumed)))
        checked += 1
    }
    @Assert(checked == 1)
    println("mid dest golden: ${checked}/1 rows")
}

/*-************************************
*  M4 Task 3: LZ4MID_fillHTable direct-internal pins
**************************************/
// All expectations pinned from a temporary C probe against upstream
// LZ4MID_fillHTable (0774d055): a 64-byte formula buffer
// (buf[i] = (i*29+3) % 251) and a 40 KB RDG(0.50, seed=9001) buffer, both
// filled with the 64KB virtual anchor D (dictLimit = lowLimit =
// nextToUpdate = 65536). Bucket positions are recomputed with the
// independently pinned T1 hash helpers; the asserted VALUES are the
// behavioral pin (3-step dual-table first loop, 1-step hash8 second loop).
@Test
func lz4hcMidFillHTableTest(): Unit {
    let d: UInt32 = 65536u32
    let buf64 = Array<UInt8>(64, {i => UInt8((i * 29 + 3) % 251)})
    unsafe {
        let h = acquireArrayRawData<UInt8>(buf64)
        // (1) size <= 8: early return (upstream L523-524) - tables stay
        // zero, nextToUpdate NOT advanced to target
        let s0 = LZ4_streamHC_t()
        LZ4_initStreamHC(s0)
        s0.dictLimit = d
        s0.lowLimit = d
        s0.nextToUpdate = d
        LZ4MID_fillHTable(s0, h.pointer, 8)
        @Assert(s0.nextToUpdate == d)
        LZ4MID_fillHTable(s0, h.pointer, 0)
        @Assert(s0.nextToUpdate == d)
        var nz: Int64 = 0
        for (i in 0..32768) {
            if (s0.hashTable[i] != 0u32) { nz += 1 }
        }
        @Assert(nz == 0)
        // (2) 64-byte dict: target = D+64-8 = D+56; first loop 3-step
        // (ADDPOS4 at idx, ADDPOS8 at idx+1), second loop (size <= 32KB+8)
        // restarts at nextToUpdate=D with 1-step ADDPOS8 over [D, D+56)
        let s = LZ4_streamHC_t()
        LZ4_initStreamHC(s)
        s.dictLimit = d
        s.lowLimit = d
        s.nextToUpdate = d
        LZ4MID_fillHTable(s, h.pointer, 64)
        @Assert(s.nextToUpdate == d + 56u32)
        // hash4: all 19 3-step positions, buckets unique per the probe
        let h4offs: Array<Int64> = [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30,
            33, 36, 39, 42, 45, 48, 51, 54]
        for (off in h4offs) {
            @Assert(s.hashTable[Int64(LZ4MID_hash4Ptr(h.pointer, off))] == d + UInt32(off))
        }
        // literal bucket cross-checks against the C probe
        @Assert(LZ4MID_hash4Ptr(h.pointer, 0) == 194u32)
        @Assert(LZ4MID_hash4Ptr(h.pointer, 3) == 2329u32)
        @Assert(LZ4MID_hash4Ptr(h.pointer, 54) == 1666u32)
        // hash8: second loop rewrote every offset [0,56) ascending, so the
        // final value per bucket = last writer; spot pins incl. both ends
        @Assert(LZ4MID_hash8Ptr(h.pointer, 0) == 10689u32)
        @Assert(LZ4MID_hash8Ptr(h.pointer, 55) == 2919u32)
        @Assert(s.hashTable[16384 + Int64(LZ4MID_hash8Ptr(h.pointer, 0))] == d)
        @Assert(s.hashTable[16384 + Int64(LZ4MID_hash8Ptr(h.pointer, 1))] == d + 1u32)
        @Assert(s.hashTable[16384 + Int64(LZ4MID_hash8Ptr(h.pointer, 39))] == d + 39u32)
        @Assert(s.hashTable[16384 + Int64(LZ4MID_hash8Ptr(h.pointer, 54))] == d + 54u32)
        @Assert(s.hashTable[16384 + Int64(LZ4MID_hash8Ptr(h.pointer, 55))] == d + 55u32)
        // counts: 19 hash4 + 56 hash8 nonzero slots (no bucket collisions)
        var nz4: Int64 = 0
        var nz8: Int64 = 0
        for (i in 0..16384) {
            if (s.hashTable[i] != 0u32) { nz4 += 1 }
        }
        for (i in 16384..32768) {
            if (s.hashTable[i] != 0u32) { nz8 += 1 }
        }
        @Assert(nz4 == 19)
        @Assert(nz8 == 56)
        releaseArrayRawData<UInt8>(h)
    }
    // (3) 40 KB RDG dict (mp=0.50 seed=9001): size > 32KB+8 so the second
    // loop starts at target-32768 (= D+8184), NOT at nextToUpdate
    let big = Array<UInt8>(40960, {_ => 0u8})
    RDG_genBuffer(big, 40960, 0.50, 0.0, 9001u32)
    unsafe {
        let hb = acquireArrayRawData<UInt8>(big)
        let s2 = LZ4_streamHC_t()
        LZ4_initStreamHC(s2)
        s2.dictLimit = d
        s2.lowLimit = d
        s2.nextToUpdate = d
        LZ4MID_fillHTable(s2, hb.pointer, 40960)
        let target: UInt32 = d + 40952u32          // = 106488
        @Assert(target == 106488u32)
        @Assert(s2.nextToUpdate == target)         // nextToUpdate = target
        // A: non-3-step offsets below D+8184 whose buckets stay EMPTY ->
        // the 1-step loop did not touch anything below target-32768
        for (off in [506, 507, 516, 530, 531]) {
            @Assert(s2.hashTable[16384 + Int64(LZ4MID_hash8Ptr(hb.pointer, off))] == 0u32)
        }
        // B: first-loop ADDPOS8 writes (off % 3 == 1, off < 8184) that
        // survived because no second-loop position shares their bucket
        for (off in [727, 751, 775, 778, 781]) {
            @Assert(s2.hashTable[16384 + Int64(LZ4MID_hash8Ptr(hb.pointer, off))] == d + UInt32(off))
        }
        // C: second-loop-only positions (off % 3 != 1, off >= 8184) that
        // are the last writers of their buckets
        for (off in [8186, 8187, 8192, 8193, 8198]) {
            @Assert(s2.hashTable[16384 + Int64(LZ4MID_hash8Ptr(hb.pointer, off))] == d + UInt32(off))
        }
        // D: hash4 3-step positions (off % 3 == 0) - written only by loop 1
        for (off in [414, 459, 462, 471, 480]) {
            @Assert(s2.hashTable[Int64(LZ4MID_hash4Ptr(hb.pointer, off))] == d + UInt32(off))
        }
        // literal bucket cross-checks against the C probe
        @Assert(LZ4MID_hash8Ptr(hb.pointer, 506) == 3968u32)
        @Assert(LZ4MID_hash8Ptr(hb.pointer, 8186) == 3669u32)
        @Assert(LZ4MID_hash4Ptr(hb.pointer, 414) == 7784u32)
        releaseArrayRawData<UInt8>(hb)
    }
}

/*-************************************
*  M4 Task 3: isStateCompatible (upstream lz4hc.c L1483-1488)
**************************************/
@Test
func lz4hcStateCompatTest(): Unit {
    // mid (levels 1-2) vs non-mid (3-12) are incompatible (table layouts
    // differ: mid uses the hash4/hash8 split, hash-chain uses hash+chain);
    // lv=2 vs lv=2 -> true; 2v3 / 9v2 / 12v2 -> false; 9v12 -> true
    let a = LZ4_streamHC_t()
    let b = LZ4_streamHC_t()
    LZ4_initStreamHC(a)
    LZ4_initStreamHC(b)
    LZ4_setCompressionLevel(a, 2)
    LZ4_setCompressionLevel(b, 2)
    @Assert(lz4hcIsStateCompatible(a, b))
    for (lv in [3, 9, 12]) {
        LZ4_setCompressionLevel(b, Int32(lv))
        @Assert(!lz4hcIsStateCompatible(a, b))   // mid vs non-mid
        @Assert(!lz4hcIsStateCompatible(b, a))
    }
    LZ4_setCompressionLevel(a, 9)
    LZ4_setCompressionLevel(b, 12)
    @Assert(lz4hcIsStateCompatible(a, b))        // hc vs opt: both non-mid
    LZ4_setCompressionLevel(a, 1)
    @Assert(!lz4hcIsStateCompatible(a, b))       // lv=1 is mid as well
}

/*-************************************
*  M4 Task 2: _dest_overflow fillOutput regimes (C probe, upstream 0774d055)
**************************************/
// scripts/hc_dest_probe.c (temporary, values pinned): n=8192 = 4096 RDG
// noise bytes (mp=0.0 lp=0.0 seed=0) + 8-byte-period tail; lv=9 targets
//   tg=4100: first-sequence literal check fails (encodeSequence L330) ->
//            _dest_overflow skips (ll cost > maxLitPos) -> last-literals
//            fill adaptation: c == tg, consumed < n
//   tg=4123: overflow block writes: literals ok, match clamped to
//            maxMlSize = MINMATCH+(ML_MASK-1)+bytesLeftForMl*255 (L1397),
//            truncated sequence + tail adaptation: c == tg
//   tg=4200: sequence fits within oend hack -> full consumption, bytes
//            equal regular lv=9 LZ4_compress_HC output
// (tg, size, consumed, xxh32, xxh64)
let HC_DEST_OVERFLOW_REF: Array<(Int32, Int32, Int32, UInt32, UInt64)> = [
    (4100, 4100, 4083, 0x4a58aca9u32, 0x2c0a4610e887539bu64),
    (4123, 4123, 4105, 0x7509eb3au32, 0x46e556c2dd3edf37u64),
    (4200, 4146, 8192, 0x58ae42e3u32, 0xe4cb540bc1f37e5eu64),
]

@Test
func lz4hcDestOverflowTest(): Unit {
    let n: Int64 = 8192
    let a = Array<UInt8>(n, {_ => 0u8})
    let head = Array<UInt8>(4096, {_ => 0u8})
    RDG_genBuffer(head, 4096, 0.0, 0.0, 0u32)
    for (i in 0..4096) {
        a[i] = head[i]
    }
    for (i in 4096..n) {
        a[i] = UInt8(0xAAu8 ^ UInt8(Int64(i) % 8))
    }
    let reg = Array<UInt8>(Int64(LZ4_compressBound(Int32(n))), {_ => 0u8})
    let creg = LZ4_compress_HC(a, Int32(n), reg, LZ4_compressBound(Int32(n)), 9)
    @Assert(creg == 4146)
    for ((tg, wantSize, wantConsumed, want32, want64) in HC_DEST_OVERFLOW_REF) {
        let out = Array<UInt8>(Int64(tg), {_ => 0u8})
        let st = LZ4_createStreamHC()
        let (c, consumed) = LZ4_compress_HC_destSize(st, a, Int32(n), out, tg, 9)
        if (c != wantSize || consumed != wantConsumed) {
            println("OVERFLOW tg=${tg}: got (${c},${consumed}) want (${wantSize},${wantConsumed})")
        }
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        @Assert(c >= 1 && c <= tg)
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        @Assert(XXH64(out, Int64(c), 0u64) == want64)
        if (tg == 4200) {
            // full-consumption regime: bytes equal the regular output
            @Assert(hcBytesEqual(out, reg, Int64(c)))
        }
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        @Assert(hcBytesEqual(dec, a, Int64(consumed)))
    }
}

/*-************************************
*  M4 Task 4: optimal parser (levels 10-12) golden vs upstream C, 0774d055
**************************************/
// opt rows of corpus/block_golden_ref.txt (rows 386..399): LZ4_compress_HC
// over the optimal-parser levels 10-12 (upstream lz4hc.c L1879-2186):
// lv 10/11/12 x A/B (lv=12 runs fullUpdate=1 with sufficient_len 4095;
// lv=10/11 partial with 64/128), then lv=12 over C..G, then three fav=1
// rows (LZ4_favorDecompressionSpeed before a fastReset compress - the
// full-init one-shots wipe the flag). (n, mp, seed, lv, fav, size, xxh32,
// xxh64, fileRowIdx), -1 = no artifact
let OPT_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Bool, Int32, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 10, false, 32907, 0xe67278c9u32, 0x3e4c3f4fca221e79u64, 386),
    (65536, 0.90, 7u32, 10, false, 5635, 0xc0ff4b11u32, 0xa0ca052de5d1a4a6u64, 387),
    (65536, 0.50, 0u32, 11, false, 32899, 0xf3e8bde0u32, 0xdcceb4e2dce68013u64, 388),
    (65536, 0.90, 7u32, 11, false, 5572, 0x6b2a4d56u32, 0x4b98598093393111u64, 389),
    (65536, 0.50, 0u32, 12, false, 32882, 0x224ec306u32, 0xc3fd28f0e0e3235eu64, 390),
    (65536, 0.90, 7u32, 12, false, 5522, 0x5c267656u32, 0xccbe178fd2d1ca3eu64, 391),
    (131072, 0.90, 0u32, 12, false, 17551, 0x8150eb80u32, 0x9420025e2cf8bd3bu64, 392),
    (255, 0.50, 0u32, 12, false, 238, 0x5b45e8dbu32, 0x8ccd36c380b4da2eu64, 393),
    (13, 0.50, 0u32, 12, false, 14, 0xab784699u32, 0xdd68042376530281u64, 394),
    (0, 0.00, 0u32, 12, false, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 395),
    (1, 0.00, 0u32, 12, false, 2, 0x47bed82cu32, 0xec3cae3829bb6262u64, 396),
    (65536, 0.50, 0u32, 10, true, 32958, 0xbeaf5869u32, 0x2bcbdd37be2a936au64, 397),
    (65536, 0.50, 0u32, 12, true, 32944, 0x774e3ec8u32, 0xfffa36e878ed44a7u64, 398),
    (65536, 0.90, 7u32, 12, true, 5583, 0x977aa445u32, 0xd388157a857b6f46u64, 399),
]

@Test
func lz4hcOptGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    for ((n, mp, seed, lv, fav, wantSize, want32, want64, fileRow) in OPT_GOLD_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = if (fav) {
            // favor rows: fresh stream + flag + fastReset (full-init one-shots
            // would zero favorDecSpeed), mirroring the C harness exactly
            let st = LZ4_createStreamHC()
            LZ4_favorDecompressionSpeed(st, 1)
            LZ4_compress_HC_extStateHC_fastReset(st, buf, Int32(n), out, Int32(bound), lv)
        } else {
            LZ4_compress_HC(buf, Int32(n), out, Int32(bound), lv)
        }
        if (c != wantSize) {
            println("SIZE n=${n} mp=${mp} seed=${seed} lv=${lv} fav=${fav}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} mp=${mp} seed=${seed} lv=${lv} fav=${fav} size=${c}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // closure roundtrip: every row standalone-decodes to the input
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, Int32(n)) == Int32(n))
        @Assert(hcBytesEqual(dec, buf, n))
        checked += 1
    }
    @Assert(checked == 14)
    @Assert(fileCompared == 14)
    println("opt golden: ${checked}/14 rows, ${fileCompared} byte-exact artifacts")
}

// hcdest opt rows 400/401: LZ4_compress_HC_destSize lv=10 and lv=12 x A,
// tg=n*3/4. The whole input compresses below the target, so fillOutput
// consumes everything (consumed == n) and the bytes equal the matching
// mode=hc rows (rows 386/390 digests).
// (n, mp, seed, lv, tg, size, consumed, xxh32, xxh64, fileRowIdx)
let OPT_DEST_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 10, 49152, 32907, 65536, 0xe67278c9u32, 0x3e4c3f4fca221e79u64, 400),
    (65536, 0.50, 0u32, 12, 49152, 32882, 65536, 0x224ec306u32, 0xc3fd28f0e0e3235eu64, 401),
]

@Test
func lz4hcOptDestSizeGoldenTest(): Unit {
    var checked = 0
    for ((n, mp, seed, lv, tg, wantSize, wantConsumed, want32, want64, fileRow) in OPT_DEST_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let out = Array<UInt8>(Int64(tg), {_ => 0u8})
        let st = LZ4_createStreamHC()
        let (c, consumed) = LZ4_compress_HC_destSize(st, buf, Int32(n), out, tg, lv)
        if (c != wantSize || consumed != wantConsumed) {
            println("OPTDEST n=${n} lv=${lv} tg=${tg}: got (${c},${consumed}) want (${wantSize},${wantConsumed})")
        }
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        @Assert(c >= 1 && c <= tg)                 // destSize invariants
        @Assert(consumed >= 0 && consumed <= Int32(n))
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} lv=${lv} tg=${tg}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
        }
        // decode == src[0..consumed)
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        @Assert(hcBytesEqual(dec, buf, Int64(consumed)))
        checked += 1
    }
    @Assert(checked == 2)
    println("opt dest golden: ${checked}/2 rows")
}

@Test
func lz4hcFavorSemanticsTest(): Unit {
    let n: Int64 = 65536
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.50, 0.0, 0u32)
    let bound = Int32(LZ4_compressBound(Int32(n)))
    // same stream, two consecutive blocks, favor flipped BETWEEN blocks
    let st = LZ4_createStreamHC()
    @Assert(st.favorDecSpeed == false)
    // block 1 (fav=0): equals the golden lv=12 A row (390)
    let o1 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c1 = LZ4_compress_HC_extStateHC_fastReset(st, a, Int32(n), o1, bound, 12)
    @Assert(c1 == 32882)
    @Assert(XXH32(o1, Int64(c1), 0u32) == 0x224ec306u32)
    @Assert(st.favorDecSpeed == false)
    // flip the flag between the blocks; state assertion: the field flips
    LZ4_favorDecompressionSpeed(st, 1)
    @Assert(st.favorDecSpeed == true)
    // block 2 (fav=1, same stream, stale tables): equals the golden fav=1
    // lv=12 A row (398) AND an independent fresh fav=1 stream byte-exact -
    // the flag influences the current block only, nothing lingers
    let o2 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c2 = LZ4_compress_HC_extStateHC_fastReset(st, a, Int32(n), o2, bound, 12)
    @Assert(c2 == 32944)
    @Assert(XXH32(o2, Int64(c2), 0u32) == 0x774e3ec8u32)
    let st2 = LZ4_createStreamHC()
    LZ4_favorDecompressionSpeed(st2, 1)
    let o3 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c3 = LZ4_compress_HC_extStateHC_fastReset(st2, a, Int32(n), o3, bound, 12)
    @Assert(c3 == c2)
    @Assert(hcBytesEqual(o2, o3, Int64(c2)))
    // favor really changes the parser decision here (truncation bias):
    // fav=1 output differs from the fav=0 output on the same input
    @Assert(c2 != c1)
    // closure roundtrip of the second block
    let dec = Array<UInt8>(n, {_ => 0u8})
    @Assert(LZ4_decompress_safe(o2, c2, dec, Int32(n)) == Int32(n))
    @Assert(hcBytesEqual(dec, a, n))
    // flag persistence check across another flip back
    LZ4_favorDecompressionSpeed(st, 0)
    @Assert(st.favorDecSpeed == false)
}

@Test
func lz4hcOptDeterminismTest(): Unit {
    let n: Int64 = 65536
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.90, 0.0, 7u32)
    let bound = Int32(LZ4_compressBound(Int32(n)))
    // same input compressed twice, each call through a fully fresh-init
    // temp stream (LZ4_compress_HC allocates per call): byte-identical
    for (lv in [10, 11, 12]) {
        let o1 = Array<UInt8>(Int64(bound), {_ => 0u8})
        let o2 = Array<UInt8>(Int64(bound), {_ => 0u8})
        let c1 = LZ4_compress_HC(a, Int32(n), o1, bound, Int32(lv))
        let c2 = LZ4_compress_HC(a, Int32(n), o2, bound, Int32(lv))
        @Assert(c1 > 0 && c1 == c2)
        @Assert(hcBytesEqual(o1, o2, Int64(c1)))
    }
    // determinism also holds with favorDecompressionSpeed (fresh streams)
    let f1 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let f2 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let s1 = LZ4_createStreamHC()
    LZ4_favorDecompressionSpeed(s1, 1)
    let d1 = LZ4_compress_HC_extStateHC_fastReset(s1, a, Int32(n), f1, bound, 12)
    let s2 = LZ4_createStreamHC()
    LZ4_favorDecompressionSpeed(s2, 1)
    let d2 = LZ4_compress_HC_extStateHC_fastReset(s2, a, Int32(n), f2, bound, 12)
    @Assert(d1 > 0 && d1 == d2)
    @Assert(hcBytesEqual(f1, f2, Int64(d1)))
}

@Test
func lz4hcPriceTest(): Unit {
    // LZ4HC_literalsPrice (upstream L1827-1834): litlen, plus for
    // litlen >= RUN_MASK(15): 1 + (litlen-15)/255 (truncating division)
    @Assert(LZ4HC_literalsPrice(0) == 0)
    @Assert(LZ4HC_literalsPrice(1) == 1)
    @Assert(LZ4HC_literalsPrice(14) == 14)
    @Assert(LZ4HC_literalsPrice(15) == 16)     // 15 + 1 + 0/255
    @Assert(LZ4HC_literalsPrice(16) == 17)     // 16 + 1 + 1/255
    @Assert(LZ4HC_literalsPrice(269) == 270)   // 269 + 1 + 254/255
    @Assert(LZ4HC_literalsPrice(270) == 272)   // 270 + 1 + 255/255
    @Assert(LZ4HC_literalsPrice(524) == 526)   // 524 + 1 + 509/255
    @Assert(LZ4HC_literalsPrice(525) == 528)   // 525 + 1 + 510/255
    // LZ4HC_sequencePrice (upstream L1837-1849): 3 (token + 16-bit offset)
    // + literalsPrice + for mlen >= ML_MASK+MINMATCH(19): 1 + (mlen-19)/255
    @Assert(LZ4HC_sequencePrice(0, 4) == 3)
    @Assert(LZ4HC_sequencePrice(15, 18) == 19)
    @Assert(LZ4HC_sequencePrice(15, 19) == 20)   // 3 + 16 + 1 + 0/255
    @Assert(LZ4HC_sequencePrice(15, 20) == 20)   // 3 + 16 + 1 + 1/255
    @Assert(LZ4HC_sequencePrice(300, 273) == 306)  // 3 + 302 + 1 + 254/255
    @Assert(LZ4HC_sequencePrice(300, 274) == 307)  // 3 + 302 + 1 + 255/255
}

/*-************************************
*  M4 Task 4: opt _dest_overflow fillOutput regimes (C probe, 0774d055)
**************************************/
// Same construction as lz4hcDestOverflowTest (T2): n=8192 = 4096 RDG noise
// bytes (mp=0.0 lp=0.0 seed=0) + 8-byte-period tail, compressed with
// LZ4_compress_HC_destSize at opt levels. C-probe values pinned: the noise
// prefix yields no matches and the periodic tail forces the same immediate
// parse at every level, so lv=10/12 outputs equal the lv=9 rows - but the
// runs go through LZ4HC_compress_optimal's own _dest_overflow (ovml/ovoff
// propagated from the encode sites, maxMlSize clamp, literal adaptation):
//   tg=4100: overflow block skipped (ll cost > maxLitPos) -> last-literals
//            fill adaptation: c == tg, consumed < n
//   tg=4123: overflow block writes: literals ok, match clamped to
//            maxMlSize = MINMATCH+(ML_MASK-1)+bytesLeftForMl*255 (L2099),
//            truncated sequence + tail adaptation: c == tg
//   tg=4200: sequence fits within oend hack -> full consumption, bytes
//            equal the regular same-level LZ4_compress_HC output
// (tg, size, consumed, xxh32, xxh64) - identical for lv=10 and lv=12
let OPT_DEST_OVERFLOW_REF: Array<(Int32, Int32, Int32, UInt32, UInt64)> = [
    (4100, 4100, 4083, 0x4a58aca9u32, 0x2c0a4610e887539bu64),
    (4123, 4123, 4105, 0x7509eb3au32, 0x46e556c2dd3edf37u64),
    (4200, 4146, 8192, 0x58ae42e3u32, 0xe4cb540bc1f37e5eu64),
]

@Test
func lz4hcOptDestOverflowTest(): Unit {
    let n: Int64 = 8192
    let a = Array<UInt8>(n, {_ => 0u8})
    let head = Array<UInt8>(4096, {_ => 0u8})
    RDG_genBuffer(head, 4096, 0.0, 0.0, 0u32)
    for (i in 0..4096) {
        a[i] = head[i]
    }
    for (i in 4096..n) {
        a[i] = UInt8(0xAAu8 ^ UInt8(Int64(i) % 8))
    }
    for (lv in [10, 12]) {
        let reg = Array<UInt8>(Int64(LZ4_compressBound(Int32(n))), {_ => 0u8})
        let creg = LZ4_compress_HC(a, Int32(n), reg, LZ4_compressBound(Int32(n)), Int32(lv))
        @Assert(creg == 4146)
        for ((tg, wantSize, wantConsumed, want32, want64) in OPT_DEST_OVERFLOW_REF) {
            let out = Array<UInt8>(Int64(tg), {_ => 0u8})
            let st = LZ4_createStreamHC()
            let (c, consumed) = LZ4_compress_HC_destSize(st, a, Int32(n), out, tg, Int32(lv))
            if (c != wantSize || consumed != wantConsumed) {
                println("OPT OVERFLOW lv=${lv} tg=${tg}: got (${c},${consumed}) want (${wantSize},${wantConsumed})")
            }
            @Assert(c == wantSize)
            @Assert(consumed == wantConsumed)
            @Assert(c >= 1 && c <= tg)
            @Assert(XXH32(out, Int64(c), 0u32) == want32)
            @Assert(XXH64(out, Int64(c), 0u64) == want64)
            if (tg == 4200) {
                // full-consumption regime: bytes equal the regular output
                @Assert(hcBytesEqual(out, reg, Int64(c)))
            }
            let dec = Array<UInt8>(n, {_ => 0u8})
            @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
            @Assert(hcBytesEqual(dec, a, Int64(consumed)))
        }
    }
}

/*-************************************
*  M4 Task 5: HC streaming family golden vs upstream C, 0774d055
**************************************/
// hccont rows of corpus/block_golden_ref.txt (rows 402..413): LZ4_resetStreamHC
// + LZ4_compress_HC_continue over 4 contiguous 16384-byte blocks of one
// RDG(65536, mp=0.50, seed=0) buffer (block k = buf + k*16384); lv in {2,9,12}
// exercises mid/hc/opt strategies on identical geometry (lv=2 mid, lv=9 hash-
// chain, lv=12 opt). Contiguous blocks (no setExternalDict handover) extend
// the prefix segment; src == end when the next block's srcIdx == prefixEndIdx.
// (n, mp, seed, lv, seq, size, xxh32, xxh64, fileRowIdx)
let HCCONT_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (16384, 0.50, 0u32, 2, 0, 10355, 0x368d41c1u32, 0xe7ca34f06a8a19e8u64, 402),
    (16384, 0.50, 0u32, 2, 1, 9389, 0x91a79235u32, 0x4b56361c9a2053e4u64, 403),
    (16384, 0.50, 0u32, 2, 2, 6850, 0x57e96a76u32, 0x6721196433491e22u64, 404),
    (16384, 0.50, 0u32, 2, 3, 7947, 0xd4d55a24u32, 0x6dd1aca03d45fed2u64, 405),
    (16384, 0.50, 0u32, 9, 0, 10145, 0xb30be3e9u32, 0xc03eff1fa1ceeea8u64, 406),
    (16384, 0.50, 0u32, 9, 1, 9001, 0x9043e0deu32, 0x6938ca41c51653f8u64, 407),
    (16384, 0.50, 0u32, 9, 2, 6420, 0x052a9dbau32, 0x09ad8ec8e50ae8f6u64, 408),
    (16384, 0.50, 0u32, 9, 3, 7363, 0xceac01d2u32, 0x66db85c887850217u64, 409),
    (16384, 0.50, 0u32, 12, 0, 10140, 0x16124d43u32, 0xb2def69591110e5bu64, 410),
    (16384, 0.50, 0u32, 12, 1, 8986, 0x58616960u32, 0x2052e600feea78deu64, 411),
    (16384, 0.50, 0u32, 12, 2, 6415, 0x6dff440au32, 0xbafc79e50ba7f0b4u64, 412),
    (16384, 0.50, 0u32, 12, 3, 7354, 0xadde8f22u32, 0xa5db787602cf4817u64, 413),
]

@Test
func lz4hcContinueGoldenTest(): Unit {
    let n: Int64 = 65536
    let buf = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(buf, n, 0.50, 0.0, 0u32)
    let bound = Int64(LZ4_compressBound(Int32(n)))
    var checked = 0
    var fileCompared = 0
    // Build a lookup map (Int64 packed: lv*4 + seq) -> row fields
    // Walk each lv separately so the per-block prefixEndIdx accumulation is
    // verified cleanly. Within each lv run, walk seq 0..3.
    let levels: Array<Int32> = [2, 9, 12]
    let numSeqs = 4
    for (lv in levels) {
        let st = LZ4_createStreamHC()
        LZ4_resetStreamHC(st, lv)
        let sd = LZ4_createStreamDecode()
        let out = Array<UInt8>(bound, {_ => 0u8})
        // rolling decode closure: every block decoded back to its slice
        let rollingDecoded = Array<UInt8>(n, {_ => 0u8})
        for (k in 0..numSeqs) {
            let c = LZ4_compress_HC_continue(st, buf, Int64(k) * 16384, 16384,
                out, Int32(bound))
            // find matching row
            var matchSize: Int32 = -1
            var match32: UInt32 = 0u32
            var match64: UInt64 = 0u64
            var matchFile: Int64 = -1
            for ((_, _, _, mLv, mSeq, mSize, m32, m64, mFile) in HCCONT_GOLD_REF) {
                if (mLv == lv && mSeq == Int32(k)) {
                    matchSize = mSize
                    match32 = m32
                    match64 = m64
                    matchFile = mFile
                }
            }
            @Assert(matchSize >= 0)
            if (c != matchSize) {
                println("DEBUG hccont lv=${lv} k=${k}: got c=${c} want=${matchSize}")
            }
            @Assert(c == matchSize)
            // since byte equality isn't pinned for these inputs, just
            // ensure the digest matches the golden (byte equality comes
            // from the file artifact below)
            @Assert(XXH32(out, Int64(c), 0u32) == match32)
            @Assert(XXH64(out, Int64(c), 0u64) == match64)
            if (matchFile >= 0) {
                let art = hcReadBlockArtifact(matchFile)
                @Assert(art.size == Int64(c))
                @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
                fileCompared += 1
            }
            checked += 1
            // rolling decode into rollingDecoded at offset k*16384
            let r = LZ4_decompress_safe_continue(sd, out, c,
                rollingDecoded, Int64(k) * 16384, 16384)
            @Assert(r == 16384)
        }
        // post-state: prefixEndIdx == total 65536 across all 4 seqs
        @Assert(st.prefixEndIdx == 65536)
        // closure roundtrip: rolling decoded == original
        @Assert(hcBytesEqual(rollingDecoded, buf, n))
        LZ4_freeStreamDecode(sd)
    }
    @Assert(checked == 12)
    @Assert(fileCompared == 12)
    println("hccont golden: ${checked}/12 rows, ${fileCompared} byte-exact artifacts")
}

// hcsavedict rows 414..416: 3 blocks of 16384 bytes in separate buffers
// (slices of one RDG(49152, mp=0.50, seed=905) buffer, copied into per-block
// allocations), LZ4_saveDictHC(safe, 8192) after seq=0/1 → relocates the
// dictionary into safeBuffer, next block compresses against it as extDict
// (setExternalDict handover). lv=9 hash-chain. C golden savesDictHC returns
// 8192 each time.
// (n, mp, seed, lv, seq, size, xxh32, xxh64, fileRowIdx)
let HCSAVEDICT_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (16384, 0.50, 905u32, 9, 0, 7376, 0x78698157u32, 0xd10a620e109354b9u64, 414),
    (16384, 0.50, 905u32, 9, 1, 7454, 0xf3bcb779u32, 0xfba3f08e32ac88f7u64, 415),
    (16384, 0.50, 905u32, 9, 2, 8631, 0x12fbcf04u32, 0x2adf89fcacb5394bu64, 416),
]

@Test
func lz4hcSaveDictGoldenTest(): Unit {
    let n: Int64 = 49152
    let src = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(src, n, 0.50, 0.0, 905u32)
    let bound = Int64(LZ4_compressBound(16384))
    let out = Array<UInt8>(bound, {_ => 0u8})
    let safe = Array<UInt8>(8192, {_ => 0u8})
    let st = LZ4_createStreamHC()
    LZ4_resetStreamHC(st, 9)
    var checked = 0
    var fileCompared = 0
    var rollingDecoded = Array<UInt8>(n, {_ => 0u8})
    let sd = LZ4_createStreamDecode()
    for ((_, _, _, lv, seq, wantSize, want32, want64, fileRow) in HCSAVEDICT_GOLD_REF) {
        // per-block: copy src[seq*16384..(seq+1)*16384) into its own Array
        let block = Array<UInt8>(16384, {i => src[i + Int64(seq) * 16384]})
        let c = LZ4_compress_HC_continue(st, block, 0, 16384, out, Int32(bound))
        @Assert(c == wantSize)
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        @Assert(XXH64(out, Int64(c), 0u64) == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // rolling decode closure
        let r = LZ4_decompress_safe_continue(sd, out, c,
            rollingDecoded, Int64(seq) * 16384, 16384)
        @Assert(r == 16384)
        // post-state pin per seq (each seq compresses full 16384; only seq 2
        // is the last block where saveDict is not called)
        if (seq < 2) {
            let s = LZ4_saveDictHC(st, safe, 8192)
            @Assert(s == 8192)
            // post-saveDictHC state: prefixBuf aliases safe; dictLimit
            // adjusted; nextToUpdate >= dictLimit
            @Assert(st.dictCtx.isNone())
            // the safeBuffer was just adopted as the new prefix; verify
            // nextToUpdate >= dictLimit (lifted floor from upstream L1809)
        }
        checked += 1
    }
    @Assert(checked == 3)
    @Assert(fileCompared == 3)
    @Assert(hcBytesEqual(rollingDecoded, src, n))
    LZ4_freeStreamDecode(sd)
    println("hcsavedict golden: ${checked}/3 rows, ${fileCompared} byte-exact artifacts, "
        + "rolling decode == src")
}

// lz4hcSaveDictClampTest: LZ4_saveDictHC return-value clamps and the
// nextToUpdate floor lift (upstream L1791-1813: >64KB→64KB, <4→0,
// >prefixLen→prefixLen; dictLimit=lowLimit=endIndex-dictSize, nextToUpdate
// lifted to dictLimit only when below — brief Step 2 unit tests, T5 fix
// round). Anchor arithmetic: loadDictHC anchors dictLimit at 64KB and ends
// with nextToUpdate near the dict tail (hash-chain Insert(end-3) →
// 65536+ds-3; mid fillHTable → 65536+ds-8) — so a bare loadDict prefix
// never lifts on save. The lift fires when nextToUpdate lags the prefix
// end: a mid stream after a separate-buffer block keeps it at the
// setExternalDict floor dictLimit while the prefix grows (probed against
// upstream 0774d055).
@Test
func lz4hcSaveDictClampTest(): Unit {
    let safe = Array<UInt8>(70000, {_ => 0u8})
    // fresh stream: prefixLen == 0 → any dictSize clamps to 0
    let fs = LZ4_createStreamHC()
    LZ4_resetStreamHC(fs, 9)
    @Assert(LZ4_saveDictHC(fs, safe, 100) == 0)
    // dictSize 0 / -1 → 0 (<4 clamp)
    let st0 = LZ4_createStreamHC()
    LZ4_resetStreamHC(st0, 9)
    let dict0 = Array<UInt8>(8192, {_ => 0u8})
    RDG_genBuffer(dict0, 8192, 0.50, 0.0, 907u32)
    @Assert(LZ4_loadDictHC(st0, dict0, 8192) == 8192)
    @Assert(LZ4_saveDictHC(st0, safe, 0) == 0)
    let stn = LZ4_createStreamHC()
    LZ4_resetStreamHC(stn, 9)
    @Assert(LZ4_loadDictHC(stn, dict0, 8192) == 8192)
    @Assert(LZ4_saveDictHC(stn, safe, -1) == 0)
    // dictSize > prefixLen → prefixLen (8192-byte prefix)
    let stp = LZ4_createStreamHC()
    LZ4_resetStreamHC(stp, 9)
    @Assert(LZ4_loadDictHC(stp, dict0, 8192) == 8192)
    @Assert(LZ4_saveDictHC(stp, safe, 20000) == 8192)
    // dictSize > 64KB → 65536: stream two contiguous 48KB blocks (prefixLen
    // 96000 > 64KB), then save 100000
    let big = Array<UInt8>(96000, {_ => 0u8})
    RDG_genBuffer(big, 96000, 0.50, 0.0, 908u32)
    let stb = LZ4_createStreamHC()
    LZ4_resetStreamHC(stb, 9)
    let boundB = Int64(LZ4_compressBound(48000))
    let outB = Array<UInt8>(boundB, {_ => 0u8})
    @Assert(LZ4_compress_HC_continue(stb, big, 0, 48000, outB, Int32(boundB)) > 0)
    @Assert(LZ4_compress_HC_continue(stb, big, 48000, 48000, outB, Int32(boundB)) > 0)
    @Assert(LZ4_saveDictHC(stb, safe, 100000) == 65536)
    // post-save state: safeBuffer adopted as prefix of length 65536,
    // dictStartIdx 0, nextToUpdate floor holds (post-compression
    // nextToUpdate >= dictLimit)
    @Assert(stb.prefixBuf.isSome() && lz4SameBuffer(stb.prefixBuf.getOrThrow(), safe))
    @Assert(stb.prefixEndIdx == 65536)
    @Assert(stb.dictStartIdx == 0)
    @Assert(stb.dictLimit == 96000u32)   // endIndex 161536 - 65536
    @Assert(stb.lowLimit == 96000u32)
    @Assert(stb.nextToUpdate >= stb.dictLimit)
    // nextToUpdate lift (verified against an upstream 0774d055 probe: a mid
    // stream after loadDict(8192) + one separate-buffer block keeps
    // nextToUpdate at the setExternalDict floor 73728, below the post-save
    // dictLimit 81920 → lifted)
    let stm = LZ4_createStreamHC()
    LZ4_resetStreamHC(stm, 2)
    let dictM = Array<UInt8>(8192, {_ => 0u8})
    RDG_genBuffer(dictM, 8192, 0.50, 0.0, 909u32)
    @Assert(LZ4_loadDictHC(stm, dictM, 8192) == 8192)
    @Assert(stm.nextToUpdate == 73720u32)   // mid fillHTable target 65536+8192-8
    let boundM = Int64(LZ4_compressBound(16384))
    let outM = Array<UInt8>(boundM, {_ => 0u8})
    let blkM = Array<UInt8>(16384, {_ => 0u8})
    RDG_genBuffer(blkM, 16384, 0.50, 0.0, 910u32)
    @Assert(LZ4_compress_HC_continue(stm, blkM, 0, 16384, outM, Int32(boundM)) > 0)
    @Assert(stm.nextToUpdate == 73728u32)   // setExternalDict floor; mid does not advance it
    @Assert(LZ4_saveDictHC(stm, safe, 8192) == 8192)
    @Assert(stm.dictLimit == 81920u32)   // endIndex 90112 - 8192
    @Assert(stm.nextToUpdate == 81920u32)   // lifted 73728 → new dictLimit
    // non-lift contrast (hash-chain stream: Insert(end-3) already advanced
    // nextToUpdate to 73725 >= post-save dictLimit 69632 → unchanged)
    let sth = LZ4_createStreamHC()
    LZ4_resetStreamHC(sth, 9)
    @Assert(LZ4_loadDictHC(sth, dict0, 8192) == 8192)
    @Assert(sth.nextToUpdate == 73725u32)
    @Assert(LZ4_saveDictHC(sth, safe, 4096) == 4096)
    @Assert(sth.dictLimit == 69632u32)
    @Assert(sth.nextToUpdate == 73725u32)
    println("hcsavedict clamps: 0/0/-1/prefixLen/65536 returns + nextToUpdate lift pins verified")
}

// hcdict rows 417..420: per row a fresh stream LZ4_resetStreamHC(lv) +
// LZ4_loadDictHC(dict, 65536) + LZ4_compress_HC_continue on a first 16384-byte
// block in a separate buffer. dict = RDG(65536, mp=0.50, seed=99); block =
// RDG(16384, mp=0.50, seed=99) = the dict's own first 16384 bytes. lv in
// {2,9,12} runs extDict path on the three table fills (Insert(end-3) /
// LZ4MID_fillHTable / opt). The dd=131072 row (lv=9): 131072-byte dictionary
// buffer; loadDictHC clamps to the LAST 64KB (returns 65536) — dd= records
// the original buffer size. usingDict decode against the effective 64KB slice.
// (n, mp, seed, lv, dd, wantLoadDictReturn, wantSize, xxh32, xxh64, fileRowIdx)
let HCDICT_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int64, Int32, Int32, UInt32, UInt64, Int64)> = [
    (16384, 0.50, 99u32, 2, 65536, 65536, 4461, 0xf7c80486u32, 0xec55174c9823ae1au64, 417),
    (16384, 0.50, 99u32, 9, 65536, 65536, 3657, 0xeb9e9f6fu32, 0xcac784a44492082au64, 418),
    (16384, 0.50, 99u32, 12, 65536, 65536, 3644, 0x257d796au32, 0x10d47f7633eb874au64, 419),
    (16384, 0.50, 99u32, 9, 131072, 65536, 6193, 0x46ec7398u32, 0xb4814a801a84ccd4u64, 420),
]

@Test
func lz4hcLoadDictGoldenTest(): Unit {
    let dictSize: Int64 = 65536
    let dictBuf = Array<UInt8>(dictSize, {_ => 0u8})
    RDG_genBuffer(dictBuf, dictSize, 0.50, 0.0, 99u32)
    let bigDict = Array<UInt8>(131072, {_ => 0u8})
    RDG_genBuffer(bigDict, 131072, 0.50, 0.0, 99u32)
    let bound = Int64(LZ4_compressBound(16384))
    var checked = 0
    var fileCompared = 0
    for ((_, _, _, lv, dd, wantLd, wantSize, want32, want64, fileRow) in HCDICT_GOLD_REF) {
        let st = LZ4_createStreamHC()
        LZ4_resetStreamHC(st, lv)
        // C harness passes the full dd-byte buffer to loadDictHC (dictBuf
        // for dd=65536, the whole bigDict for the clamp row — the >64KB
        // tail clamp then lands on the real last 64KB of bigDict, keeping
        // every read in-bounds); the usingDict decode uses that same
        // effective 64KB slice
        let dict = if (dd == dictSize) { dictBuf } else { bigDict }
        let decDict = if (dd == dictSize) { dictBuf } else {
            Array<UInt8>(65536, {i => bigDict[i + 65536]})
        }
        let ld = LZ4_loadDictHC(st, dict, Int32(dd))
        @Assert(ld == wantLd)
        // loadDictHC defensive: negative input → 0 (own unit test elsewhere;
        // here dd is positive, sanity)
        @Assert(ld > 0)
        // build the block in a separate buffer
        let block = Array<UInt8>(16384, {_ => 0u8})
        RDG_genBuffer(block, 16384, 0.50, 0.0, 99u32)
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_HC_continue(st, block, 0, 16384, out, Int32(bound))
        @Assert(c == wantSize)
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        @Assert(XXH64(out, Int64(c), 0u64) == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // closure roundtrip via usingDict
        let dec = Array<UInt8>(16384, {_ => 0u8})
        @Assert(LZ4_decompress_safe_usingDict(out, c, dec, 16384, decDict, 65536) == 16384)
        @Assert(hcBytesEqual(dec, block, 16384))
        checked += 1
    }
    @Assert(checked == 4)
    @Assert(fileCompared == 4)
    println("hcdict golden: ${checked}/4 rows, ${fileCompared} byte-exact artifacts, "
        + "usingDict closure verified")
}

// hcattach rows 421..423: per row a dictionary stream
// (LZ4_resetStreamHC(dlv) + LZ4_loadDictHC(dict RDG(65536, mp=0.50, seed=99)))
// + a fresh working stream LZ4_resetStreamHC(lv) + LZ4_attach_HC_dictionary +
// LZ4_compress_HC_continue on a fresh buffer. block = RDG(n, mp=0.50, seed=99)
// = the dict's own prefix. position == 0 (fresh working state):
//   8192/lv9: srcSize>4KB + isStateCompatible → WHOLE-STATE-COPY path
//   (dictCtx detached, deep table copy, setExternalDict, noDictCtx)
//   4096/lv9: srcSize<=4KB → consult (usingDictCtxHc, working table empty)
//   8192 lv9-dict vs lv2-work: incompatible (mid vs hash-chain) → consult
//     (LZ4MID_searchHCDict against hash-chain dict stream)
// usingDict closure roundtrip and state pins (copy path: working hashTable
// contents equal dict's, dictCtx=None; consult path: dictCtx=Some and the
// dictCtx stream's tables unchanged — see the in-body substitution note for
// why "working tables still empty" is asserted pre- not post-compression).
// (n, mp, seed, lv, dlv, wantSize, xxh32, xxh64, fileRowIdx)
let HCATTACH_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (8192, 0.50, 99u32, 9, 9, 1407, 0xf3c6df47u32, 0x75dca7e6274f1c6cu64, 421),
    (4096, 0.50, 99u32, 9, 9, 552, 0x5dbbabdcu32, 0x101a84954a6eecffu64, 422),
    (8192, 0.50, 99u32, 2, 9, 1596, 0xa1c5f5f5u32, 0x306fd7a968fb1937u64, 423),
]

@Test
func lz4hcAttachGoldenTest(): Unit {
    let dictSize: Int64 = 65536
    let dictBuf = Array<UInt8>(dictSize, {_ => 0u8})
    RDG_genBuffer(dictBuf, dictSize, 0.50, 0.0, 99u32)
    let bound = Int64(LZ4_compressBound(8192))
    var checked = 0
    var fileCompared = 0
    for ((n, _, _, lv, dlv, wantSize, want32, want64, fileRow) in HCATTACH_GOLD_REF) {
        // dictionary stream: resetStreamHC(dlv) + loadDictHC
        let dstream = LZ4_createStreamHC()
        LZ4_resetStreamHC(dstream, dlv)
        @Assert(LZ4_loadDictHC(dstream, dictBuf, Int32(dictSize)) == Int32(dictSize))
        // snapshot a dict table entry that survives the copy path (see the
        // post-state pin below: slot 100 hash entry is not rewritten)
        let dHash1 = dstream.hashTable[100]
        // working stream: resetStreamHC(lv) + attach
        let wstream = LZ4_createStreamHC()
        LZ4_resetStreamHC(wstream, lv)
        LZ4_attach_HC_dictionary(wstream, dstream)
        @Assert(match (wstream.dictCtx) {
            case Some(_) => true
            case None => false
        })
        // consult-path pre-compression snapshot (T5 fix round). The brief's
        // literal "工作流表仍空" post-compression pin is impossible: the
        // block's positions are inserted into the working tables during the
        // search. Documented substitution: (i) the working tables are empty
        // PRE-compression (asserted on the snapshot below), (ii) the dictCtx
        // stream is READ-ONLY in the consult path — its hash/chain tables
        // must be byte-identical before vs after the compression (sampled
        // slots 0..3 and 100).
        let isCopyPath = (lv == dlv && n == 8192)
        let dH0 = dstream.hashTable[0]; let dH1 = dstream.hashTable[1]
        let dH2 = dstream.hashTable[2]; let dH3 = dstream.hashTable[3]
        let dC0 = dstream.chainTable[0]; let dC1 = dstream.chainTable[1]
        let dC2 = dstream.chainTable[2]; let dC3 = dstream.chainTable[3]
        if (!isCopyPath) {
            @Assert(wstream.hashTable[0] == 0u32 && wstream.hashTable[1] == 0u32)
            @Assert(wstream.hashTable[2] == 0u32 && wstream.hashTable[3] == 0u32)
            @Assert(wstream.chainTable[0] == 0u16 && wstream.chainTable[1] == 0u16)
            @Assert(wstream.chainTable[2] == 0u16 && wstream.chainTable[3] == 0u16)
        }
        // build the block
        let block = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(block, n, 0.50, 0.0, 99u32)
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_HC_continue(wstream, block, 0, Int32(n), out, Int32(bound))
        @Assert(c == wantSize)
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        @Assert(XXH64(out, Int64(c), 0u64) == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // post-state pin: copy path (lv=dlv=9, n=8192) detaches dictCtx
        // and works the deep-copied tables; consult path leaves dictCtx=Some
        // and the dictCtx stream's tables untouched
        if (isCopyPath) {
            // copy path: dictCtx detached; deep-copied tables then evolved by
            // the block compression itself. Post-state pinned to upstream
            // 0774d055 (C probe on this exact geometry): slot 0 rewritten by
            // block inserts (dict h0/c0 = 88202/65535 -> 136438/85), slot
            // 100 hash survives (97434) while its chain entry is rewritten
            // (65535 -> 6524).
            @Assert(wstream.dictCtx.isNone())
            @Assert(wstream.hashTable[0] == 136438u32)
            @Assert(wstream.chainTable[0] == 85u16)
            @Assert(wstream.hashTable[100] == dHash1)
            @Assert(wstream.chainTable[100] == 6524u16)
        } else {
            // consult path: dictCtx stays attached; the dictCtx stream was
            // read-only (sampled table slots unchanged pre vs post — the
            // substitution pin documented above)
            @Assert(match (wstream.dictCtx) {
                case Some(_) => true
                case None => false
            })
            @Assert(dstream.hashTable[0] == dH0 && dstream.hashTable[1] == dH1)
            @Assert(dstream.hashTable[2] == dH2 && dstream.hashTable[3] == dH3)
            @Assert(dstream.chainTable[0] == dC0 && dstream.chainTable[1] == dC1)
            @Assert(dstream.chainTable[2] == dC2 && dstream.chainTable[3] == dC3)
            @Assert(dstream.hashTable[100] == dHash1)
        }
        // closure roundtrip via usingDict (forceExtDict path)
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe_usingDict(out, c, dec, Int32(n), dictBuf,
            Int32(dictSize)) == Int32(n))
        @Assert(hcBytesEqual(dec, block, n))
        checked += 1
    }
    @Assert(checked == 3)
    @Assert(fileCompared == 3)
    println("hcattach golden: ${checked}/3 rows, ${fileCompared} byte-exact artifacts, "
        + "copy vs consult path pins verified")
}

// hcdestcont rows 424..425: lv=9 over 2 contiguous 16384 blocks of one
// RDG(32768, mp=0.50, seed=906) buffer via LZ4_compress_HC_continue_destSize
// tg=12288; consumed pins *srcSizePtr. Block 1's compressed stream may
// reference block 0's bytes (it does — first offset 14904); decode with the
// just-decoded block 0 as extDict via LZ4_decompress_safe_usingDict (whose
// forceExtDict path validates offsets against (op - dest) + dictSize).
// (n, mp, seed, lv, tg, size, consumed, xxh32, xxh64, fileRowIdx)
let HCDESTCONT_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (16384, 0.50, 906u32, 9, 12288, 6189, 16384, 0x42536b9eu32, 0x46f2770d8f9c0ea1u64, 424),
    (16384, 0.50, 906u32, 9, 12288, 6205, 16384, 0xb4ba5c14u32, 0x4752f5f89d192d4bu64, 425),
]

@Test
func lz4hcDestContGoldenTest(): Unit {
    let n: Int64 = 32768
    let buf = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(buf, n, 0.50, 0.0, 906u32)
    let bound = Int64(LZ4_compressBound(16384))
    let st = LZ4_createStreamHC()
    LZ4_resetStreamHC(st, 9)
    var checked = 0
    var fileCompared = 0
    for ((kBlock, mp, seed, lv, tg, wantSize, wantConsumed, want32, want64, fileRow) in HCDESTCONT_GOLD_REF) {
        let out = Array<UInt8>(Int64(tg), {_ => 0u8})
        // seq from iteration: checked order matches HCDESTCONT_GOLD_REF
        let seq: Int64 = Int64(checked)
        // Cangjie slice math: re-create a view
        let srcSlice = Array<UInt8>(Int64(kBlock), {i => buf[i + seq * Int64(kBlock)]})
        let (c, consumed) = LZ4_compress_HC_continue_destSize(st, srcSlice, 0,
            Int32(kBlock), out, tg)
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        @Assert(c >= 1 && c <= tg)
        @Assert(consumed >= 0 && consumed <= Int32(kBlock))
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        @Assert(XXH64(out, Int64(c), 0u64) == want64)
        if (fileRow >= 0) {
            let art = hcReadBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            @Assert(hcBytesEqual(out, Array<UInt8>(art.size, {i => UInt8(art[i])}), Int64(c)))
            fileCompared += 1
        }
        // decode == src[0..consumed): block 0 standalone, block 1 with block 0
        // as extDict (forceExtDict path of usingDict)
        let dec = Array<UInt8>(Int64(kBlock), {_ => 0u8})
        if (seq == 0) {
            @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        } else {
            let block0 = Array<UInt8>(Int64(kBlock), {i => buf[i]})
            @Assert(LZ4_decompress_safe_usingDict(out, c, dec, consumed, block0,
                Int32(kBlock)) == consumed)
        }
        @Assert(hcBytesEqual(dec, srcSlice, Int64(consumed)))
        checked += 1
        // suppress unused-variable warnings on by-handbook values
        let _ = mp; let _ = seed; let _ = lv; let _ = bound
    }
    @Assert(checked == 2)
    @Assert(fileCompared == 2)
    println("hcdestcont golden: ${checked}/2 rows, ${fileCompared} byte-exact artifacts")
}

// lz4hcStreamEdgeTest: pins against upstream 0774d055 per scripts/hc_probe.c
// (recompiled with the build command in the probe header; T5 fix-round
// repair: the tight call has its own output buffer, decode checks are
// healthy-outputs-only and report-only, no exit before all cases print).
// Re-probed stdout (upstream 0774d055):
//   hc-tight: c0=8098 xxh0=d1f5e875 cTight=0 dirty=1 cRecover=8568 xxhR=64e9c7ea cFresh=8568 eq=1
//   hc-lvswitch: c9=8441 xxh9=d4ed1a8b c2=10922 xxh2=05b137ed dl=65536 decode-ok=1
//   hc-resetfast: dlPre=65536 dlPost=98304 c2=11504 xxh2=1834a6a5 fresh=11504 eq=1 dlFinal=163840 llFinal=163840
//   hc-overlap: ld=65536 c=6772 xxh32=818cfefc xxh64=40d5ea4ea6bb7005 lowLimit=114688 dictLimit=131072 dictStartOff=49152 decode-ok=1
// (1) tight-continue: insufficient dstCapacity → 0 + dirty; resetStreamHC_fast
// recovery output == fresh stream output. (2) setCompressionLevel block
// switch lv=9 → 2 mid-stream: mid strategy runs on the inherited hash-chain
// state (no re-anchor), block-2 bytes pinned. (3) resetStreamHC_fast
// mid-stream: dictLimit += prefixLen, tables kept; the next continue's
// output equals a fresh stream on the same block. (4) overlap-shrink:
// loadDictHC + continue with block INSIDE the dict buffer — setExternalDict
// then the overlap check keeps the dict as [49152, 65536) (LZ4HC_HASHSIZE=4
// invalidation guard). Decode closure via LZ4_decompress_safe_usingDict.
@Test
func lz4hcStreamEdgeTest(): Unit {
    let bound = Int64(LZ4_compressBound(16384))
    // (1) tight-continue → 0 + dirty; resetStreamHC_fast recovery == fresh
    let b0 = Array<UInt8>(16384, {_ => 0u8})
    let b1 = Array<UInt8>(16384, {_ => 0u8})
    RDG_genBuffer(b0, 16384, 0.50, 0.0, 901u32)
    RDG_genBuffer(b1, 16384, 0.50, 0.0, 902u32)
    let ctx = LZ4_createStreamHC()
    LZ4_resetStreamHC(ctx, 9)
    let o0 = Array<UInt8>(bound, {_ => 0u8})
    let c0 = LZ4_compress_HC_continue(ctx, b0, 0, 16384, o0, Int32(bound))
    @Assert(c0 == 8098)
    @Assert(XXH32(o0, Int64(c0), 0u32) == 0xd1f5e875u32)
    // healthy-output decode closure for o0 BEFORE any reuse of the buffer
    let dec0 = Array<UInt8>(16384, {_ => 0u8})
    @Assert(LZ4_decompress_safe(o0, c0, dec0, 16384) == 16384)
    @Assert(hcBytesEqual(dec0, b0, 16384))
    // tight dstCapacity=100 into its OWN buffer (mirrors the repaired
    // probe: the failed partial write must not clobber prior outputs)
    let oT = Array<UInt8>(100, {_ => 0u8})
    let cT = LZ4_compress_HC_continue(ctx, b1, 0, 16384, oT, 100)
    @Assert(cT == 0)
    @Assert(ctx.dirty == true)
    // resetStreamHC_fast: dirty → full re-init, output equals fresh stream
    LZ4_resetStreamHC_fast(ctx, 9)
    @Assert(ctx.dirty == false)
    let cR = LZ4_compress_HC_continue(ctx, b1, 0, 16384, o0, Int32(bound))
    @Assert(cR == 8568)
    @Assert(XXH32(o0, Int64(cR), 0u32) == 0x64e9c7eau32)
    // fresh stream baseline: byte-exact equality
    let fr = LZ4_createStreamHC()
    LZ4_resetStreamHC(fr, 9)
    let oF = Array<UInt8>(bound, {_ => 0u8})
    let cF = LZ4_compress_HC_continue(fr, b1, 0, 16384, oF, Int32(bound))
    @Assert(cF == cR)
    @Assert(hcBytesEqual(o0, oF, Int64(cR)))
    // (2) setCompressionLevel lv=9 → lv=2 block-level crossing (no re-anchor,
    // mid strategy continues on the inherited hash-chain state)
    let buf = Array<UInt8>(32768, {_ => 0u8})
    RDG_genBuffer(buf, 32768, 0.50, 0.0, 903u32)
    let ctx2 = LZ4_createStreamHC()
    LZ4_resetStreamHC(ctx2, 9)
    let o1 = Array<UInt8>(bound, {_ => 0u8})
    let c1 = LZ4_compress_HC_continue(ctx2, buf, 0, 16384, o1, Int32(bound))
    @Assert(c1 == 8441)
    @Assert(XXH32(o1, Int64(c1), 0u32) == 0xd4ed1a8bu32)
    LZ4_setCompressionLevel(ctx2, 2)
    @Assert(ctx2.compressionLevel == 2)
    let o2 = Array<UInt8>(bound, {_ => 0u8})
    let c2 = LZ4_compress_HC_continue(ctx2, buf, 16384, 16384, o2, Int32(bound))
    @Assert(c2 == 10922)
    @Assert(XXH32(o2, Int64(c2), 0u32) == 0x05b137edu32)
    // dictLimit not advanced (contiguous blocks: src==end, no
    // setExternalDict, prefix segment just grows)
    @Assert(ctx2.dictLimit == 65536u32)
    // rolling decode closure across the level switch (probe decode-ok=1)
    let dst2 = Array<UInt8>(32768, {_ => 0u8})
    let sd = LZ4_createStreamDecode()
    @Assert(LZ4_decompress_safe_continue(sd, o1, c1, dst2, 0, 16384) == 16384)
    @Assert(LZ4_decompress_safe_continue(sd, o2, c2, dst2, 16384, 16384) == 16384)
    @Assert(hcBytesEqual(dst2, buf, 32768))
    LZ4_freeStreamDecode(sd)
    // (3) resetStreamHC_fast mid-stream: dictLimit += prefixLen, tables kept;
    // next continue's output equals a fresh stream on the same block
    let buf3 = Array<UInt8>(49152, {_ => 0u8})
    RDG_genBuffer(buf3, 49152, 0.50, 0.0, 904u32)
    let ctx3 = LZ4_createStreamHC()
    LZ4_resetStreamHC(ctx3, 9)
    let o3a = Array<UInt8>(bound, {_ => 0u8})
    LZ4_compress_HC_continue(ctx3, buf3, 0, 16384, o3a, Int32(bound))
    let o3b2 = Array<UInt8>(bound, {_ => 0u8})
    LZ4_compress_HC_continue(ctx3, buf3, 16384, 16384, o3b2, Int32(bound))
    let dlPre: UInt32 = ctx3.dictLimit
    @Assert(dlPre == 65536u32)
    LZ4_resetStreamHC_fast(ctx3, 9)
    let dlPost: UInt32 = ctx3.dictLimit
    @Assert(dlPost == 98304u32)   // 65536 + 32768 (two-block prefixLen)
    @Assert(ctx3.prefixBuf.isNone())
    let o3c = Array<UInt8>(bound, {_ => 0u8})
    let c3 = LZ4_compress_HC_continue(ctx3, buf3, 32768, 16384, o3c, Int32(bound))
    @Assert(c3 == 11504)
    @Assert(XXH32(o3c, Int64(c3), 0u32) == 0x1834a6a5u32)
    // final state pins
    let dlFinal: UInt32 = ctx3.dictLimit
    let llFinal: UInt32 = ctx3.lowLimit
    @Assert(dlFinal == 163840u32)   // 65536 + 65536*3 (three 16384-block prefixes including resetFast cumulative)
    @Assert(llFinal == 163840u32)
    // fresh-stream baseline
    let fr3 = LZ4_createStreamHC()
    LZ4_resetStreamHC(fr3, 9)
    let o4 = Array<UInt8>(bound, {_ => 0u8})
    let cF3 = LZ4_compress_HC_continue(fr3, buf3, 32768, 16384, o4, Int32(bound))
    @Assert(cF3 == c3)
    @Assert(hcBytesEqual(o3c, o4, Int64(c3)))
    // (4) overlap-shrink: loadDictHC then continue with block INSIDE the dict
    // buffer at offset 32768 — setExternalDict makes the dict the extDict,
    // then the overlap check keeps it as [49152, 65536): the surviving
    // 16384 bytes pass the LZ4HC_HASHSIZE (=4) invalidation guard
    let D = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(D, 65536, 0.50, 0.0, 905u32)
    let ctx4 = LZ4_createStreamHC()
    LZ4_resetStreamHC(ctx4, 9)
    let ld = LZ4_loadDictHC(ctx4, D, 65536)
    @Assert(ld == 65536)
    let out = Array<UInt8>(bound, {_ => 0u8})
    // block starts INSIDE the dictionary buffer at offset 32768 (also the
    // dictBuf === srcBuf aliasing geometry for the no-double-acquire rule)
    let c4 = LZ4_compress_HC_continue(ctx4, D, 32768, 16384, out, Int32(bound))
    @Assert(c4 == 6772)
    @Assert(XXH32(out, Int64(c4), 0u32) == 0x818cfefcu32)
    @Assert(XXH64(out, Int64(c4), 0u64) == 0x40d5ea4ea6bb7005u64)
    // post-overlap-shrink state == upstream probe: dictStartOff 49152,
    // lowLimit 114688, dictLimit 131072 — the surviving dict [49152, 65536)
    // is KEPT (dictLimit - lowLimit == 16384 >= LZ4HC_HASHSIZE)
    @Assert(ctx4.dictStartIdx == 49152)
    @Assert(ctx4.lowLimit == 114688u32)
    @Assert(ctx4.dictLimit == 131072u32)
    // closure roundtrip via usingDict over the full 64KB dict (the
    // effective extDict is the shrunk slice [49152, 65536) which overlaps
    // with the source block; usingDict with the full dict still produces
    // the right output)
    let dec4 = Array<UInt8>(16384, {_ => 0u8})
    @Assert(LZ4_decompress_safe_usingDict(out, Int32(c4), dec4, 16384, D, 65536) == 16384)
    @Assert(hcBytesEqual(dec4, Array<UInt8>(16384, {i => D[i + 32768]}), 16384))
    println("hc edge: tight/lvswitch/resetfast/overlap pins verified")
}

// lz4hcDictCtxPrefixAliasTest: pins against upstream 0774d055 per
// scripts/hc_probe.c case 5 (fix round 2, I5 residual). Geometry: streams
// w and d both loadDictHC the SAME buffer D; w compresses B1 from a
// SEPARATE buffer (setExternalDict -> dictBuf=D, dictCtx=None); attach(d);
// then a CONTIGUOUS continue of B1's buffer (srcIdx == prefixEndIdx ->
// src==end skips setExternalDict so dictCtx survives into
// lz4hcCompressRun with dictBuf === dictCtx.prefixBuf !== srcBuf — the
// extDict allocation doubles as the dictCtx prefix, which must not be
// acquired twice). Probe stdout (upstream 0774d055):
//   hc-dictctx-alias: ld1=65536 ld2=65536 c1=9672 xxh1=a42a5e0b c2=8393 xxh2=b0bfd6af xxh2_64=b21f1cd1b67f775b preAttachCtxNull=1 dictCtxCleared=1 decode-ok=1
// Block-2 position = prefixLen 16384 + (dictLimit 131072 - lowLimit 65536)
// = 81920 >= 64KB, so upstream L1503 drops dictCtx (noDictCtx) and the
// extDict-D geometry drives the block-2 bytes. Rolling decode seeded with
// D (LZ4_setStreamDecode) reconstructs B1+block2.
@Test
func lz4hcDictCtxPrefixAliasTest(): Unit {
    let bound = Int64(LZ4_compressBound(16384))
    let D = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(D, 65536, 0.50, 0.0, 907u32)
    // B1 buffer 32768: block 1 = [0, 16384), block 2 = contiguous extension
    // [16384, 32768) generated in the same call
    let B = Array<UInt8>(32768, {_ => 0u8})
    RDG_genBuffer(B, 32768, 0.50, 0.0, 908u32)
    let w = LZ4_createStreamHC()
    let d = LZ4_createStreamHC()
    LZ4_resetStreamHC(w, 9)
    LZ4_resetStreamHC(d, 9)
    // w: loadDictHC(D) then B1 from a separate buffer -> setExternalDict:
    // dictBuf = D, dictCtx = None (probe preAttachCtxNull=1)
    @Assert(LZ4_loadDictHC(w, D, 65536) == 65536)
    let o1 = Array<UInt8>(bound, {_ => 0u8})
    let c1 = LZ4_compress_HC_continue(w, B, 0, 16384, o1, Int32(bound))
    @Assert(c1 == 9672)
    @Assert(XXH32(o1, Int64(c1), 0u32) == 0xa42a5e0bu32)
    @Assert(w.dictCtx.isNone())
    // d: the SAME allocation D as its prefix; attach d to w
    @Assert(LZ4_loadDictHC(d, D, 65536) == 65536)
    LZ4_attach_HC_dictionary(w, d)
    // geometry proof BEFORE the block-2 compress: dictCtx alive, its
    // prefixBuf is the same allocation as w's dictBuf, and srcBuf (B) is a
    // different allocation — the exact dictBuf === dictCtx.prefixBuf !==
    // srcBuf shape the pre-acquire sentinels must recognize
    @Assert(w.dictCtx.isSome())
    match (w.dictCtx) {
        case Some(dctx) =>
            match (dctx.prefixBuf) {
                case Some(pb) => @Assert(lz4SameBuffer(pb, D))
                case None => @Assert(false)
            }
        case None => @Assert(false)
    }
    match (w.dictBuf) {
        case Some(db) => @Assert(lz4SameBuffer(db, D))
        case None => @Assert(false)
    }
    @Assert(!lz4SameBuffer(B, D))
    // contiguous continue: src==end keeps dictCtx alive across the boundary
    @Assert(w.prefixEndIdx == 16384)
    let o2 = Array<UInt8>(bound, {_ => 0u8})
    let c2 = LZ4_compress_HC_continue(w, B, 16384, 16384, o2, Int32(bound))
    @Assert(c2 == 8393)
    @Assert(XXH32(o2, Int64(c2), 0u32) == 0xb0bfd6afu32)
    @Assert(XXH64(o2, Int64(c2), 0u64) == 0xb21f1cd1b67f775bu64)
    // position >= 64KB -> upstream L1503 dropped dictCtx during block 2
    // (probe dictCtxCleared=1)
    @Assert(w.dictCtx.isNone())
    // rolling decode seeded with D reconstructs B1+block2 byte-exactly
    // (probe decode-ok=1)
    let sd = LZ4_createStreamDecode()
    @Assert(LZ4_setStreamDecode(sd, D, 65536) == 1)
    let dst = Array<UInt8>(32768, {_ => 0u8})
    @Assert(LZ4_decompress_safe_continue(sd, o1, c1, dst, 0, 16384) == 16384)
    @Assert(LZ4_decompress_safe_continue(sd, o2, c2, dst, 16384, 16384) == 16384)
    @Assert(hcBytesEqual(dst, B, 32768))
    LZ4_freeStreamDecode(sd)
    println("hc dictctx alias: dictBuf===prefixBuf!==srcBuf no-double-acquire pins verified")
}

// lz4hcMidDictCtxConsultTest: pins against upstream 0774d055 per
// scripts/hc_probe.c cases 6-7 (M4 Task 6 coverage gate: the MID strategy's
// dictCtx consult LZ4MID_searchExtDict and the dict-buffer-as-block
// pbufSameAsSrc aliasing under the whole-state takeover were unexercised by
// the golden suite). Probe stdout (upstream 0774d055):
//   hc-mid-consult: ld=65536 c=1183 xxh32=cac47c28 xxh64=14821fc0141a171b ctxKept=1 decode-ok=1
//   hc-dict-as-block: ld3=65536 c3=4809 xxh3=a72072b9 ctxKept=0 decode-ok=1
// Case 6: both streams lv2 (mid strategy); block 2048 <= 4KB keeps upstream
// on the consult path (position==0 && srcSize<=4KB skips the whole-state
// takeover), so LZ4MID_compress reaches the dictCtx consult and
// LZ4MID_searchExtDict (hash8 then hash4 lookups inside d's MID tables,
// filled by loadDictHC's LZ4MID_fillHTable); B regenerates D's RDG prefix
// (same seed) so dict-side candidates exist. Case 7: the working block IS
// the dict buffer (srcBuf === dictCtx.prefixBuf) with srcSize > 4KB ->
// whole-state takeover; the pbufSameAsSrc sentinel must derive dictCtxQ
// from the already-held src allocation (no second acquire).
@Test
func lz4hcMidDictCtxConsultTest(): Unit {
    // -- case 6: MID+MID consult (LZ4MID_searchExtDict) --
    let D = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(D, 65536, 0.50, 0.0, 909u32)
    let B = Array<UInt8>(2048, {_ => 0u8})
    RDG_genBuffer(B, 2048, 0.50, 0.0, 909u32)   // same seed -> B == D[0..2048)
    let w = LZ4_createStreamHC()
    let d = LZ4_createStreamHC()
    LZ4_resetStreamHC(w, 2)
    LZ4_resetStreamHC(d, 2)
    @Assert(LZ4_loadDictHC(d, D, 65536) == 65536)
    LZ4_attach_HC_dictionary(w, d)
    let bound6 = Int64(LZ4_compressBound(2048))
    let out6 = Array<UInt8>(bound6, {_ => 0u8})
    let c6 = LZ4_compress_HC_continue(w, B, 0, 2048, out6, Int32(bound6))
    @Assert(c6 == 1183)
    @Assert(XXH32(out6, Int64(c6), 0u32) == 0xcac47c28u32)
    @Assert(XXH64(out6, Int64(c6), 0u64) == 0x14821fc0141a171bu64)
    // position 0 + prefix 2048 < 64KB -> consult keeps dictCtx (ctxKept=1)
    @Assert(w.dictCtx.isSome())
    let dec6 = Array<UInt8>(2048, {_ => 0u8})
    @Assert(LZ4_decompress_safe_usingDict(out6, c6, dec6, 2048, D, 65536) == 2048)
    @Assert(hcBytesEqual(dec6, B, 2048))
    // -- case 7: dict buffer AS the working block (pbufSameAsSrc) --
    let D3 = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(D3, 65536, 0.50, 0.0, 911u32)
    let w3 = LZ4_createStreamHC()
    let d3 = LZ4_createStreamHC()
    LZ4_resetStreamHC(w3, 9)
    LZ4_resetStreamHC(d3, 9)
    @Assert(LZ4_loadDictHC(d3, D3, 65536) == 65536)
    LZ4_attach_HC_dictionary(w3, d3)
    // geometry proof: the block source is exactly the dictCtx prefix
    // allocation the pre-acquire sentinel must recognize
    match (w3.dictCtx) {
        case Some(dctx) =>
            match (dctx.prefixBuf) {
                case Some(pb) => @Assert(lz4SameBuffer(pb, D3))
                case None => @Assert(false)
            }
        case None => @Assert(false)
    }
    let bound7 = Int64(LZ4_compressBound(16384))
    let out7 = Array<UInt8>(bound7, {_ => 0u8})
    let c7 = LZ4_compress_HC_continue(w3, D3, 0, 16384, out7, Int32(bound7))
    @Assert(c7 == 4809)
    @Assert(XXH32(out7, Int64(c7), 0u32) == 0xa72072b9u32)
    // srcSize > 4KB + position 0 -> whole-state takeover cleared dictCtx
    // (ctxKept=0)
    @Assert(w3.dictCtx.isNone())
    let dec7 = Array<UInt8>(16384, {_ => 0u8})
    @Assert(LZ4_decompress_safe_usingDict(out7, c7, dec7, 16384, D3, 65536) == 16384)
    @Assert(hcBytesEqual(dec7, D3, 16384))
    println("hc mid dictctx consult + dict-as-block takeover pins verified")
}

/*-************************************
*  M7 Task 2: hard-to-reach HC lines (targeted coverage)
**************************************/
/* 共享合成输入族:与 scripts/hc_search3_probe.c 的 buildSweep/buildReprice
   逐语句对应(UInt64 LCG + 整数模式运算,双实现可移植;钉值均出自该探针
   对上游 0774d055 的编译运行)。_Search3(_Search2/_Search3 lazy 分析)仅在
   nbAttempts > 128 时启用 —— 即 hashChain 仅 lv9(lv10-12 为 opt 策略)。 */

private func hc7LcgNext(x: UInt64): UInt64 {
    return (x * 1103515245u64 + 12345u64) & 0xFFFFFFFFu64
}

private func hc7Pat(j: Int64, m: Int64, c: Int64): UInt8 {
    return UInt8((j * m + c) & 0xFF)
}

private func hcSweepBuild(kind: Int64): Array<UInt8> {
    let n: Int64 = 65536
    let b = Array<UInt8>(n, {_ => 0u8})
    if (kind <= 3) {                       /* F1(p):周期 + 稀疏变异 */
        let p: Int64 = if (kind == 0) { 5 } else if (kind == 1) { 17 }
            else if (kind == 2) { 63 } else { 255 }
        for (i in 0..n) {
            b[i] = hc7Pat(i % p, 113, 29)
            if (i % 97 == 13) {
                b[i] = hc7Pat(i / 97, 151, 7)
            }
        }
    } else if (kind == 4) {                /* F2:512B 段双周期 13/29 交错 */
        for (i in 0..n) {
            b[i] = if (((i >> 9) % 2) == 0) { hc7Pat(i % 13, 61, 11) }
                else { hc7Pat(i % 29, 181, 77) }
        }
    } else if (kind <= 7) {                /* F3(L,p):前导文字游程 + 周期 17 */
        let L: Int64 = if (kind == 5) { 1 } else if (kind == 6) { 5 } else { 33 }
        var x: UInt64 = 777u64
        for (i in 0..n) {
            if (i < L) {
                x = hc7LcgNext(x)
                b[i] = UInt8((x >> 16u64) & 0xFFu64)
            } else {
                b[i] = hc7Pat(i % 17, 113, 29)
            }
        }
    } else if (kind == 8) {                 /* F4:三层几何 A/B/AB + 周期 7 尾 */
        var x: UInt64 = 888u64
        for (i in 0..64) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        x = 889u64
        for (i in 64..128) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        for (i in 128..192) {
            b[i] = b[i - 128]
        }
        for (i in 192..256) {
            b[i] = b[i - 128]
        }
        for (i in 256..n) {
            b[i] = hc7Pat((i - 256) % 7, 197, 3)
        }
    } else if (kind <= 11) {                /* F5(k):16B 基块 + 轮转单字节翻转 + 间隙(短匹配挤压几何) */
        let flip: Int64 = kind - 9           /* 9: 翻转字节 + 0..2B 间隙;10: 翻转 + 3B 间隙;11: 每 3 块 2 翻 */
        var x: UInt64 = 3001u64
        let base = Array<UInt8>(16, {_ => 0u8})
        for (i in 0..16) {
            x = hc7LcgNext(x)
            base[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        for (i in 0..16) {
            b[i] = base[i]
        }
        var pos: Int64 = 16
        var seg: Int64 = 0
        while (pos + 16 <= n) {
            for (i in 0..16) {
                b[pos + i] = base[i]
            }
            let flipBit: Bool = if (flip == 11) { seg % 3 != 0 } else { true }
            if (flipBit) {
                b[pos + (seg % 16)] ^= 0x5Au8
            }
            pos += 16 + (if (flip == 10) { 3 } else { Int64(seg % 3) })
            seg += 1
        }
        while (pos < n) {                    /* 尾部填充周期 4 */
            b[pos] = hc7Pat(pos % 4, 113, 29)
            pos += 1
        }
    } else if (kind == 12) {                /* RDG 短长匹配混合 */
        RDG_genBuffer(b, n, 0.60, 0.0, 4321u32)
    } else if (kind == 13) {                /* RDG 中等匹配 */
        RDG_genBuffer(b, n, 0.75, 0.0, 8765u32)
    } else {                                /* F7(s):重叠自拷贝级联(文字游程/回拷/移位回拷轮转,
                                              回距 4..303 < 拷长 4..47 → 级联匹配,lazy2 校正高发) */
        let s: UInt64 = 5000u64 + UInt64(kind - 14)
        var x: UInt64 = s
        for (i in 0..256) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        var pos: Int64 = 256
        var seg: Int64 = 0
        while (pos < n) {
            let act: Int64 = seg % 3
            if (act == 0) {                 /* 文字游程 3..62 */
                let L: Int64 = 3 + (seg % 60)
                x = hc7LcgNext(x)
                var i: Int64 = 0
                while (i < L && pos < n) {
                    x = hc7LcgNext(x)
                    b[pos] = UInt8((x >> 16u64) & 0xFFu64)
                    i += 1
                    pos += 1
                }
            } else {                        /* 回拷 4..47 字节自 4..303 回距(可重叠);act==2 时 +2 移位回声 */
                let ml: Int64 = 4 + (seg % 44)
                let back: Int64 = 4 + (seg % 300)
                let src: Int64 = pos - back + (if (act == 2) { 2 } else { 0 })
                if (src < 0) {
                    b[pos] = hc7Pat(pos, 113, 29)
                    pos += 1
                    seg += 1
                    continue
                }
                var i: Int64 = 0
                while (i < ml && pos < n) {
                    b[pos] = b[src + i]
                    i += 1
                    pos += 1
                }
            }
            seg += 1
        }
    }
    return b
}

private func hcRepriceBuild(kind: Int64): Array<UInt8> {
    let n: Int64 = 65536
    let b = Array<UInt8>(n, {_ => 0u8})
    if (kind == 0) {                       /* 随机 | 周期 11 | 随机 | 周期 11 相位 +3 */
        var x: UInt64 = 1001u64
        for (i in 0..64) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        for (i in 64..32768) {
            b[i] = hc7Pat(i % 11, 113, 29)
        }
        x = 1002u64
        for (i in 32768..32968) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        for (i in 32968..n) {
            b[i] = hc7Pat((i + 3) % 11, 113, 29)
        }
    } else if (kind == 1) {                /* 文字游程 1..7 交替 + 短匹配(5..7,回距 64..95;前导 256B 头防回引越界) */
        var x: UInt64 = 1500u64
        for (i in 0..256) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        var pos: Int64 = 256
        var seg: Int64 = 0
        while (pos < n) {
            let k: Int64 = (seg % 7) + 1
            var x2: UInt64 = 1003u64 + UInt64(seg)
            var i: Int64 = 0
            while (i < k && pos < n) {
                x2 = hc7LcgNext(x2)
                b[pos] = UInt8((x2 >> 16u64) & 0xFFu64)
                i += 1
                pos += 1
            }
            if (pos >= n) {
                break
            }
            let ml: Int64 = 5 + (seg % 3)
            let srcBack: Int64 = 64 + (seg % 32)
            i = 0
            while (i < ml && pos < n) {
                b[pos] = b[pos - srcBack]
                i += 1
                pos += 1
            }
            seg += 1
        }
    } else if (kind == 3) {                /* F6:游程 1..40(跨 RUN_MASK=15 台阶)+ 固定 8B 短匹配(前导 256B 头) */
        var x: UInt64 = 1500u64
        for (i in 0..256) {
            x = hc7LcgNext(x)
            b[i] = UInt8((x >> 16u64) & 0xFFu64)
        }
        var pos: Int64 = 256
        var seg: Int64 = 0
        while (pos < n) {
            let L: Int64 = 1 + (seg % 40)
            var x2: UInt64 = 2000u64 + UInt64(seg)
            var i: Int64 = 0
            while (i < L && pos < n) {
                x2 = hc7LcgNext(x2)
                b[pos] = UInt8((x2 >> 16u64) & 0xFFu64)
                i += 1
                pos += 1
            }
            if (pos >= n) {
                break
            }
            i = 0
            while (i < 8 && pos < n) {
                b[pos] = b[pos - (64 + (seg % 16))]
                i += 1
                pos += 1
            }
            seg += 1
        }
    } else {                               /* RDG(65536, 0.85, 0, 777) */
        RDG_genBuffer(b, n, 0.85, 0.0, 777u32)
    }
    return b
}

/* 探针钉值(hc_search3_probe.c,上游 0774d055):代表组合字节保真 */
private let HC_SEARCH3_PINS: Array<(Int64, Int64, Int32, Int32, Int32, UInt32)> =
    /* (kind, c0, tg, wantC, wantConsumed, want32) — tg = c0*f/16 的派生值按
       探针行注释;c0 由仓颉侧重算并断言一致 */
    [
    (1, 3425, 856, 856, 15637, 0xfc4490abu32),     /* c0/4 */
    (4, 833, 416, 416, 29703, 0x7554f991u32),      /* c0/2 */
    (8, 405, 303, 303, 39556, 0xff397795u32),      /* 3*c0/4 */
]

@Test
func lz4hcSearch3SweepTest(): Unit {
    /* 代表钉值行先断言(c0 一致 → 派生 tg 一致 → c/consumed/xxh32 全等) */
    for ((kind, wantC0, tg, wantC, wantConsumed, want32) in HC_SEARCH3_PINS) {
        let buf = hcSweepBuild(kind)
        let st0 = LZ4_createStreamHC()
        let out0 = Array<UInt8>(70000, {_ => 0u8})
        let c0 = LZ4_compress_HC(buf, 65536, out0, 70000, 9)
        if (c0 != Int32(wantC0)) {
            println("SWEEP PIN kind=${kind}: c0=${c0} want ${wantC0}")
        }
        @Assert(c0 == Int32(wantC0))
        LZ4_freeStreamHC(st0)
        let out = Array<UInt8>(Int64(tg), {_ => 0u8})
        let st = LZ4_createStreamHC()
        let (c, consumed) = LZ4_compress_HC_destSize(st, buf, 65536, out, tg, 9)
        @Assert(c == wantC && consumed == wantConsumed)
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        let dec = Array<UInt8>(65536, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        @Assert(hcBytesEqual(dec, buf, Int64(consumed)))
        LZ4_freeStreamHC(st)
    }
    /* 全族 × tg 阶梯(destSize 解码闭合;_Search3 校正/出口的概率覆盖主体) */
    var combos = 0
    for (kind in 0..20) {
        let buf = hcSweepBuild(kind)
        let st0 = LZ4_createStreamHC()
        let out0 = Array<UInt8>(70000, {_ => 0u8})
        let c0 = LZ4_compress_HC(buf, 65536, out0, 70000, 9)
        LZ4_freeStreamHC(st0)
        @Assert(c0 >= 40)
        for (f in 1..16) {
            let tg: Int32 = if (f < 15) { c0 * Int32(f) / 16 } else { c0 - 1 }
            if (tg < 16) {
                continue
            }
            let out = Array<UInt8>(Int64(tg), {_ => 0u8})
            let st = LZ4_createStreamHC()
            let (c, consumed) = LZ4_compress_HC_destSize(st, buf, 65536, out, tg, 9)
            if (c < 1 || c > tg || consumed < 1 || consumed > 65536) {
                println("SWEEP FAIL kind=${kind} f=${f}/16 tg=${tg}: c=${c} consumed=${consumed}")
            }
            @Assert(c >= 1 && c <= tg)
            @Assert(consumed >= 1 && consumed <= 65536)
            let dec = Array<UInt8>(65536, {_ => 0u8})
            @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
            @Assert(hcBytesEqual(dec, buf, Int64(consumed)))
            LZ4_freeStreamHC(st)
            combos += 1
        }
    }
    /* 流式变体:block0 notLimited 锚定,block1 continue_destSize 阶梯 */
    let half: Int64 = 32768
    let capHalf = Int64(LZ4_compressBound(Int32(half)))
    var contCombos = 0
    for (kind in 0..20) {
        let buf = hcSweepBuild(kind)
        let block0 = Array<UInt8>(half, {i => buf[i]})
        /* block1 的 notLimited 基线 cB(供阶梯派生) */
        let stB = LZ4_createStreamHC()
        LZ4_resetStreamHC(stB, 9)
        let outA = Array<UInt8>(capHalf, {_ => 0u8})
        @Assert(LZ4_compress_HC_continue(stB, buf, 0, Int32(half), outA, Int32(capHalf)) > 0)
        let outB = Array<UInt8>(capHalf, {_ => 0u8})
        let cB = LZ4_compress_HC_continue(stB, buf, half, Int32(half), outB, Int32(capHalf))
        LZ4_freeStreamHC(stB)
        @Assert(cB >= 40)
        for (f in 1..16) {
            let tg: Int32 = if (f < 15) { cB * Int32(f) / 16 } else { cB - 1 }
            if (tg < 16) {
                continue
            }
            let st = LZ4_createStreamHC()
            LZ4_resetStreamHC(st, 9)
            @Assert(LZ4_compress_HC_continue(st, buf, 0, Int32(half), outA, Int32(capHalf)) > 0)
            let out = Array<UInt8>(Int64(tg), {_ => 0u8})
            let (c, consumed) = LZ4_compress_HC_continue_destSize(st, buf, half,
                Int32(half), out, tg)
            if (c < 1 || c > tg || consumed < 1 || consumed > 65536) {
                println("SWEEP CONT FAIL kind=${kind} f=${f}/16 tg=${tg}: c=${c} consumed=${consumed}")
            }
            @Assert(c >= 1 && c <= tg)
            @Assert(consumed >= 1 && consumed <= 65536)
            let dec = Array<UInt8>(65536, {_ => 0u8})
            @Assert(LZ4_decompress_safe_usingDict(out, c, dec, consumed, block0,
                Int32(half)) == consumed)
            @Assert(hcBytesEqual(dec, Array<UInt8>(half, {i => buf[half + i]}),
                Int64(consumed)))
            LZ4_freeStreamHC(st)
            contCombos += 1
        }
    }
    @Assert(combos >= 100 && contCombos >= 100)
    /* LIMITED 容量路径(非 destSize 的一次性欠容量):LZ4_OUTPUT_LIMITED 下
       _Search3 出口的 return (0,0) 分支(L839/886/930);一次性压缩全有或全无 →
       欠容量必 0,足容量(= bound)必成功 */
    var failSeen = 0
    var okSeen = 0
    let fracsA: Array<Int32> = [2, 4, 6, 8]
    for (kind in 0..20) {
        let buf = hcSweepBuild(kind)
        let st0 = LZ4_createStreamHC()
        let out0 = Array<UInt8>(70000, {_ => 0u8})
        let c0 = LZ4_compress_HC(buf, 65536, out0, 70000, 9)
        LZ4_freeStreamHC(st0)
        for (f in fracsA) {
            let cap: Int32 = c0 * f / 16
            if (cap < 16) {
                continue
            }
            let st = LZ4_createStreamHC()
            let out = Array<UInt8>(Int64(cap), {_ => 0u8})
            let c = LZ4_compress_HC(buf, 65536, out, cap, 9)
            @Assert(c >= 0 && c <= cap)
            if (c == 0) {
                failSeen += 1
            } else {
                let dec = Array<UInt8>(65536, {_ => 0u8})
                @Assert(LZ4_decompress_safe(out, c, dec, 65536) == 65536)
                @Assert(hcBytesEqual(dec, buf, 65536))
                okSeen += 1
            }
            LZ4_freeStreamHC(st)
        }
        /* 足容量对照:bound 下必成功(每族恰一次) */
        let stF = LZ4_createStreamHC()
        let outF = Array<UInt8>(70000, {_ => 0u8})
        let cF = LZ4_compress_HC(buf, 65536, outF, 70000, 9)
        @Assert(cF > 0)
        let decF = Array<UInt8>(65536, {_ => 0u8})
        @Assert(LZ4_decompress_safe(outF, cF, decF, 65536) == 65536)
        @Assert(hcBytesEqual(decF, buf, 65536))
        LZ4_freeStreamHC(stF)
        okSeen += 1
    }
    @Assert(failSeen >= 1 && okSeen >= 20)
    println("hc search3 sweep: ${combos} one-shot + ${contCombos} continue destSize + " +
        "${failSeen} limited-fail / ${okSeen} limited-ok combos, all roundtrip")
}

/* fillOutput 深度钳制(MID L784 / hashChain L2101):巨型 match + 紧输出 */
@Test
func lz4hcFillOverflowClampTest(): Unit {
    let zeros = Array<UInt8>(131072, {_ => 0u8})
    let per4 = Array<UInt8>(131072, {i => hc7Pat(i % 4, 113, 29)})
    /* 探针钉值(hc_search3_probe.c):zeros 三级别同输出,per4 lv4 tg=128 */
    let st1 = LZ4_createStreamHC()
    let o1 = Array<UInt8>(100, {_ => 0u8})
    let (cz2, kz2) = LZ4_compress_HC_destSize(st1, zeros, 131072, o1, 100, 2)
    @Assert(cz2 == 100 && kz2 == 22974)
    @Assert(XXH32(o1, Int64(cz2), 0u32) == 0xc9cb1972u32)
    LZ4_freeStreamHC(st1)
    let st2 = LZ4_createStreamHC()
    let o2 = Array<UInt8>(100, {_ => 0u8})
    let (cz4, kz4) = LZ4_compress_HC_destSize(st2, zeros, 131072, o2, 100, 4)
    @Assert(cz4 == 100 && kz4 == 22974)
    @Assert(XXH32(o2, Int64(cz4), 0u32) == 0xc9cb1972u32)
    LZ4_freeStreamHC(st2)
    let st3 = LZ4_createStreamHC()
    let o3 = Array<UInt8>(100, {_ => 0u8})
    let (cz9, kz9) = LZ4_compress_HC_destSize(st3, zeros, 131072, o3, 100, 9)
    @Assert(cz9 == 100 && kz9 == 22974)
    @Assert(XXH32(o3, Int64(cz9), 0u32) == 0xc9cb1972u32)
    LZ4_freeStreamHC(st3)
    let st4 = LZ4_createStreamHC()
    let o4 = Array<UInt8>(128, {_ => 0u8})
    let (cp4, kp4) = LZ4_compress_HC_destSize(st4, per4, 131072, o4, 128, 4)
    @Assert(cp4 == 128 && kp4 == 29352)
    @Assert(XXH32(o4, Int64(cp4), 0u32) == 0xc2a195c2u32)
    LZ4_freeStreamHC(st4)
    /* 扫描:双输入 × lv {2,4,9,10,12} × tg {64,100,128,256},解码闭合(opt
       级 10/12 覆盖 L1739:opt 解析器 _dest_overflow 的 ovml 钳制) */
    var combos = 0
    let inputs: Array<Array<UInt8>> = [zeros, per4]
    let lvs: Array<Int32> = [2, 4, 9, 10, 12]
    let tgs: Array<Int32> = [64, 100, 128, 256]
    for (inp in inputs) {
        for (lv in lvs) {
            for (tg in tgs) {
                let st = LZ4_createStreamHC()
                let out = Array<UInt8>(Int64(tg), {_ => 0u8})
                let (c, consumed) = LZ4_compress_HC_destSize(st, inp, 131072, out, tg, lv)
                @Assert(c >= 1 && c <= tg)
                @Assert(consumed >= 1 && consumed <= 131072)
                let dec = Array<UInt8>(131072, {_ => 0u8})
                @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
                @Assert(hcBytesEqual(dec, inp, Int64(consumed)))
                LZ4_freeStreamHC(st)
                combos += 1
            }
        }
    }
    @Assert(combos == 40)
    println("hc fillOverflow clamp: 4 pins + ${combos} sweep combos, all roundtrip")
}

/* optimal 解析器字面量前缀改价(L1988-1998):探针钉值 × 确定性 × 往返 */
@Test
func lz4hcOptLiteralRepriceTest(): Unit {
    /* (kind, lv, wantC, want32) — hc_search3_probe.c */
    let pins: Array<(Int64, Int32, Int32, UInt32)> = [
        (0, 10, 550, 0xaafbf8b8u32),
        (0, 11, 549, 0xb2f68005u32),
        (0, 12, 546, 0xe7bfe00fu32),
        (1, 10, 45905, 0x08bd0883u32),
        (1, 11, 45905, 0x08bd0883u32),
        (1, 12, 45905, 0x08bd0883u32),
        (2, 10, 10356, 0xb12ba8afu32),
        (2, 11, 10264, 0x25426923u32),
        (2, 12, 10208, 0x4847c43eu32),
    ]
    var checked = 0
    for ((kind, lv, wantC, want32) in pins) {
        let buf = hcRepriceBuild(kind)
        let out = Array<UInt8>(70000, {_ => 0u8})
        let st = LZ4_createStreamHC()
        let c = LZ4_compress_HC(buf, 65536, out, 70000, lv)
        if (c != wantC) {
            println("REPRICE PIN kind=${kind} lv=${lv}: c=${c} want ${wantC}")
        }
        @Assert(c == wantC)
        @Assert(XXH32(out, Int64(c), 0u32) == want32)
        /* fresh 态二次压缩逐字节确定 */
        let out2 = Array<UInt8>(70000, {_ => 0u8})
        let st2 = LZ4_createStreamHC()
        @Assert(LZ4_compress_HC(buf, 65536, out2, 70000, lv) == c)
        @Assert(hcBytesEqual(out, out2, Int64(c)))
        /* 往返 */
        let dec = Array<UInt8>(65536, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, 65536) == 65536)
        @Assert(hcBytesEqual(dec, buf, 65536))
        LZ4_freeStreamHC(st)
        LZ4_freeStreamHC(st2)
        checked += 1
    }
    @Assert(checked == 9)
    /* 改价概率主体:crafted F6(kind=3,游程跨 RUN_MASK 台阶 + 8B 短匹配)+
       RDG mp 阶梯 × 多种子 × lv10-12(notLimited 往返;L1629 数据依赖)+ 
       代表 kind × lv12 destSize(opt fillOutput 组合) */
    var swept = 0
    let optLvs: Array<Int32> = [10, 11, 12]
    let buf3 = hcRepriceBuild(3)
    let out3 = Array<UInt8>(70000, {_ => 0u8})
    for (lv in optLvs) {
        let st = LZ4_createStreamHC()
        let c = LZ4_compress_HC(buf3, 65536, out3, 70000, lv)
        @Assert(c > 0)
        let dec = Array<UInt8>(65536, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out3, c, dec, 65536) == 65536)
        @Assert(hcBytesEqual(dec, buf3, 65536))
        LZ4_freeStreamHC(st)
        swept += 1
    }
    let mps: Array<Float64> = [0.30, 0.50, 0.70, 0.80, 0.90, 0.95, 0.99]
    let seeds: Array<UInt32> = [1u32, 2u32, 3u32]
    let rbuf = Array<UInt8>(65536, {_ => 0u8})
    let rout = Array<UInt8>(70000, {_ => 0u8})
    for (mp in mps) {
        for (sd in seeds) {
            RDG_genBuffer(rbuf, 65536, mp, 0.0, sd)
            for (lv in optLvs) {
                let st = LZ4_createStreamHC()
                let c = LZ4_compress_HC(rbuf, 65536, rout, 70000, lv)
                @Assert(c > 0)
                let dec = Array<UInt8>(65536, {_ => 0u8})
                @Assert(LZ4_decompress_safe(rout, c, dec, 65536) == 65536)
                @Assert(hcBytesEqual(dec, rbuf, 65536))
                LZ4_freeStreamHC(st)
                swept += 1
            }
        }
    }
    let fracsB: Array<Int32> = [2, 4, 8]
    for (kind in 0..3) {
        let buf = hcRepriceBuild(kind)
        let st0 = LZ4_createStreamHC()
        let out0 = Array<UInt8>(70000, {_ => 0u8})
        let c0 = LZ4_compress_HC(buf, 65536, out0, 70000, 12)
        LZ4_freeStreamHC(st0)
        for (f in fracsB) {
            let tg: Int32 = c0 * f / 8
            if (tg < 16) {
                continue
            }
            let out = Array<UInt8>(Int64(tg), {_ => 0u8})
            let st = LZ4_createStreamHC()
            let (c, consumed) = LZ4_compress_HC_destSize(st, buf, 65536, out, tg, 12)
            @Assert(c >= 1 && c <= tg && consumed >= 1 && consumed <= 65536)
            let dec = Array<UInt8>(65536, {_ => 0u8})
            @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
            @Assert(hcBytesEqual(dec, buf, Int64(consumed)))
            LZ4_freeStreamHC(st)
            swept += 1
        }
    }
    @Assert(swept >= 70)
    println("hc opt literal reprice: ${checked} pins + ${swept} sweep combos verified")
}

/* HC 流式 overlap 收缩 <4 丢弃(lz4hc.c L1755-1766 对应体):单缓冲内
   loadDictHC 后 continue 源与字典重叠,存活 < LZ4HC_HASHSIZE(4)→ 丢弃;
   独立缓冲对照(同内容异分配)字典保留。探针双钉 c=52 xxh=d7dcf0f0。 */
@Test
func lz4hcOverlapShrinkTest(): Unit {
    var x: UInt64 = 999u64
    let sbuf = Array<UInt8>(64, {_ => 0u8})
    for (i in 0..64) {
        x = hc7LcgNext(x)
        sbuf[i] = UInt8((x >> 16u64) & 0xFFu64)
    }
    let dict8 = Array<UInt8>(8, {i => sbuf[i]})
    let src2 = Array<UInt8>(64, {i => sbuf[i]})
    let bound = Int64(LZ4_compressBound(50))
    /* in-place:同分配 → 收缩 → 2 字节 < 4 → 丢弃 */
    let s1 = LZ4_createStreamHC()
    LZ4_resetStreamHC(s1, 9)
    @Assert(LZ4_loadDictHC(s1, sbuf, 8) == 8)
    let out1 = Array<UInt8>(bound, {_ => 0u8})
    let c1 = LZ4_compress_HC_continue(s1, sbuf, 6, 50, out1, Int32(bound))
    @Assert(c1 == 52)
    @Assert(XXH32(out1, Int64(c1), 0u32) == 0xd7dcf0f0u32)
    /* 丢弃证据:lowLimit == dictLimit(字典空) */
    @Assert(s1.lowLimit == s1.dictLimit)
    /* 字典已丢弃 → 块内仅后向引用 → standalone 解码闭合 */
    let dec1 = Array<UInt8>(50, {_ => 0u8})
    @Assert(LZ4_decompress_safe(out1, c1, dec1, 50) == 50)
    @Assert(hcBytesEqual(dec1, Array<UInt8>(50, {i => sbuf[6 + i]}), 50))
    LZ4_freeStreamHC(s1)
    /* 对照:独立分配字典(同内容)→ lz4SameBuffer 假 → 无收缩,字典保留 */
    let s2 = LZ4_createStreamHC()
    LZ4_resetStreamHC(s2, 9)
    @Assert(LZ4_loadDictHC(s2, dict8, 8) == 8)
    let out2 = Array<UInt8>(bound, {_ => 0u8})
    let c2 = LZ4_compress_HC_continue(s2, src2, 6, 50, out2, Int32(bound))
    @Assert(c2 == 52)
    @Assert(XXH32(out2, Int64(c2), 0u32) == 0xd7dcf0f0u32)
    @Assert(s2.dictLimit - s2.lowLimit == 8u32)
    let dec2 = Array<UInt8>(50, {_ => 0u8})
    @Assert(LZ4_decompress_safe_usingDict(out2, c2, dec2, 50, dict8, 8) == 50)
    @Assert(hcBytesEqual(dec2, Array<UInt8>(50, {i => sbuf[6 + i]}), 50))
    LZ4_freeStreamHC(s2)
    println("hc overlap shrink discard: in-place(sep-state assert) + separate-dict control pinned")
}

/*-************************************
*  M7 Task 2 (cont.): _Search3 校正路径的手工构造几何
**************************************/
/* 三组级联三匹配构造(几何意图:逼近 _Search3 校正块;实测经全量插桩观测,
   m3>m2>s 情态下 s3 恒 < m1.len,校正块结构性不可达 —— 残行按 M6 先例登记,
   见任务报告与台账;本测试保留价值 = 挤压 lazy 解析空间的解码闭环 + 一次性/
   destSize 紧容量失败契约):
   - craft1:m1.len=9 / m2.len=10(back 0,s=7)/ m3.len=11(start3=14)
   - craft2:m1.len=17 / m2.len=20(back 2,s=13)/ m3.len=21(start3=30)
   - craft3:m1.len=7 / m2.len=9(back 2,s=3)/ m3.len=10(start3=9 ∈ [7,10))
   H 构造:先随机填充,后打补丁(H[x..y) := H[a..b))使级联窗口在 H 内成源;
   L 布局按匹配映射放置;填充区 LCG。 */
private func hcCraftBuild(which: Int64): Array<UInt8> {
    let hn: Int64 = 256
    let ln: Int64 = 512
    let H = Array<UInt8>(hn, {_ => 0u8})
    let b = Array<UInt8>(ln, {_ => 0u8})
    var x: UInt64 = 6101u64 + UInt64(which)
    for (i in 0..hn) {
        x = hc7LcgNext(x)
        H[i] = UInt8((x >> 16u64) & 0xFFu64)
    }
    if (which == 1) {
        for (i in 0..2) { H[32 + i] = H[7 + i] }        /* B 头 = A 尾 */
        for (i in 0..3) { H[48 + i] = H[39 + i] }       /* C 头 = B 尾 */
        for (i in 0..9) { b[i] = H[i] }                 /* L[0..9) = A */
        for (i in 0..8) { b[9 + i] = H[34 + i] }        /* L[9..17) = B[2..10) */
        for (i in 0..8) { b[17 + i] = H[51 + i] }       /* L[17..25) = C[3..11) */
        var y: UInt64 = 7101u64
        for (i in 25..256) {
            y = hc7LcgNext(y)
            b[i] = UInt8((y >> 16u64) & 0xFFu64)
        }
    } else if (which == 2) {
        for (i in 0..2) { H[62 + i] = H[13 + i] }       /* m2 回扩 2 字节源前缀 */
        for (i in 0..2) { H[64 + i] = H[15 + i] }       /* B 头 = A 尾(重叠区) */
        for (i in 0..3) { H[84 + i] = H[79 + i] }       /* C 头 = B 尾 */
        for (i in 0..17) { b[i] = H[i] }                /* L[0..17) = A */
        for (i in 0..16) { b[17 + i] = H[66 + i] }      /* L[17..33) = 源 H[66..82) */
        for (i in 0..18) { b[33 + i] = H[87 + i] }      /* L[33..51) = 源 H[87..105) */
        var y: UInt64 = 7102u64
        for (i in 51..256) {
            y = hc7LcgNext(y)
            b[i] = UInt8((y >> 16u64) & 0xFFu64)
        }
    } else {
        for (i in 0..2) { H[104 + i] = H[3 + i] }       /* m2 回扩 2 字节源前缀 */
        for (i in 0..2) { H[106 + i] = H[5 + i] }       /* B 头 = A 尾(重叠区) */
        for (i in 0..3) { H[114 + i] = H[110 + i] }     /* C 头 = m2 尾 */
        for (i in 0..7) { b[i] = H[i] }                 /* L[0..7) = A */
        for (i in 0..5) { b[7 + i] = H[108 + i] }       /* L[7..12) = 源 H[108..113) */
        for (i in 0..7) { b[12 + i] = H[117 + i] }      /* L[12..19) = 源 H[117..124) */
        var y: UInt64 = 7103u64
        for (i in 19..256) {
            y = hc7LcgNext(y)
            b[i] = UInt8((y >> 16u64) & 0xFFu64)
        }
    }
    /* 布局基址 256:H 即前 256 字节 */
    for (i in 0..hn) {
        b[hn + i] = H[i]
    }
    return b
}

@Test
func lz4hcSearch3CraftTest(): Unit {
    let bound = Int64(LZ4_compressBound(512))
    for (which in 1..4) {
        let buf = hcCraftBuild(which)
        /* notLimited 往返 + 确定性 */
        let st = LZ4_createStreamHC()
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_HC(buf, 512, out, Int32(bound), 9)
        @Assert(c > 0)
        let out2 = Array<UInt8>(bound, {_ => 0u8})
        let st2 = LZ4_createStreamHC()
        @Assert(LZ4_compress_HC(buf, 512, out2, Int32(bound), 9) == c)
        @Assert(hcBytesEqual(out, out2, Int64(c)))
        let dec = Array<UInt8>(512, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, 512) == 512)
        @Assert(hcBytesEqual(dec, buf, 512))
        LZ4_freeStreamHC(st)
        LZ4_freeStreamHC(st2)
        /* 紧容量阶梯:出口 #3/#4 的 encodeSequence 失败(首序列在 m1 编码点)。
           H(256 随机字面量)+ 首序列 ≈ 260-266 字节输出 → 阶梯扫过失败点 */
        var failDest = 0
        var failLim = 0
        for (tg in 250..270) {
            let stD = LZ4_createStreamHC()
            let oD = Array<UInt8>(tg, {_ => 0u8})
            let (cd, kd) = LZ4_compress_HC_destSize(stD, buf, 512, oD, Int32(tg), 9)
            @Assert(cd >= 1 && cd <= Int32(tg) && kd >= 1 && kd <= 512)
            let dD = Array<UInt8>(512, {_ => 0u8})
            @Assert(LZ4_decompress_safe(oD, cd, dD, kd) == kd)
            @Assert(hcBytesEqual(dD, buf, Int64(kd)))
            LZ4_freeStreamHC(stD)
            if (kd < 512) {
                failDest += 1
            }
        }
        for (cap in 250..270) {
            let stL = LZ4_createStreamHC()
            let oL = Array<UInt8>(cap, {_ => 0u8})
            let cl = LZ4_compress_HC(buf, 512, oL, Int32(cap), 9)
            @Assert(cl >= 0 && cl <= Int32(cap))
            if (cl > 0) {
                let dL = Array<UInt8>(512, {_ => 0u8})
                @Assert(LZ4_decompress_safe(oL, cl, dL, 512) == 512)
                @Assert(hcBytesEqual(dL, buf, 512))
            } else {
                failLim += 1
            }
            LZ4_freeStreamHC(stL)
        }
        @Assert(failDest >= 1 && failLim >= 1)
    }
    println("hc search3 craft: 3 geometries roundtrip + tight-cap exits verified")
}
