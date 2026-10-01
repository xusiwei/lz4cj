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
