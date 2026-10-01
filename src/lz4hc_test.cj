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
