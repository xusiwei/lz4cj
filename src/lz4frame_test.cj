// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream lib/lz4frame.c + lib/lz4frame.h (frame format).
// M5 Task 1: error family, version, getBlockSize, optimalBSID, bounds math,
// header checksum and cctx lifecycle. All bound expectations are hand-computed
// against upstream lz4frame.c L335-418/L884-890 and pinned as constants;
// header checksum pins were cross-checked against upstream xxhash via a
// temporary C probe (see the task report).
// M5 Task 2: compressBegin family golden (frhdr rows 426..435 of
// corpus/block_golden_ref.txt, values from the regenerated C corpus) plus
// cctx state / buffer-quadrant / ctx-type-switch / error-path pins.

package lz4

import std.unittest.*
import std.fs.*

/*-************************************
*  Error family (lz4frame.h L668-693)
**************************************/

@Test
func lz4fErrorTest(): Unit {
    // -1 .. -23 are all errors (25-entry enum, ERROR_maxCode=24)
    for (i in 1..24) {
        @Assert(LZ4F_isError(-Int64(i)) == true)
    }
    // upstream edge: unsigned C comparison makes -maxCode itself NOT an error
    @Assert(LZ4F_isError(-24) == false)
    @Assert(LZ4F_isError(0) == false)
    @Assert(LZ4F_isError(1) == false)
    @Assert(LZ4F_isError(10957) == false)
    // names with LZ4F_ prefix stripped (LZ4F_errorStrings[])
    @Assert(LZ4F_getErrorName(-1) == "ERROR_GENERIC")
    @Assert(LZ4F_getErrorName(-11) == "ERROR_dstMaxSize_tooSmall")
    @Assert(LZ4F_getErrorName(-14) == "ERROR_frameSize_wrong")
    @Assert(LZ4F_getErrorName(-20) == "ERROR_compressionState_uninitialized")
    @Assert(LZ4F_getErrorName(0) == "Unspecified error code")
    @Assert(LZ4F_getErrorName(5) == "Unspecified error code")
    @Assert(LZ4F_getErrorName(-24) == "Unspecified error code")
    // getErrorCode: non-error -> 0, error -> -code
    @Assert(LZ4F_getErrorCode(0) == 0)
    @Assert(LZ4F_getErrorCode(7) == 0)
    @Assert(LZ4F_getErrorCode(-3) == 3)
    // enum carrier sanity: error codes are Int64 constants, order preserved
    @Assert(LZ4F_OK_NoError == 0)
    @Assert(LZ4F_ERROR_GENERIC == 1)
    @Assert(LZ4F_ERROR_maxBlockSize_invalid == 2)
    @Assert(LZ4F_ERROR_maxCode == 24)
    println("lz4f error family pins verified")
}

/*-************************************
*  Version / level max
**************************************/

@Test
func lz4fVersionTest(): Unit {
    @Assert(LZ4F_VERSION == 100u32)
    @Assert(LZ4F_getVersion() == 100u32)
    @Assert(LZ4F_compressionLevel_max() == LZ4HC_CLEVEL_MAX)
    @Assert(LZ4F_compressionLevel_max() == 12)
    println("lz4f version + compressionLevel_max pins verified")
}

/*-************************************
*  getBlockSize (lz4frame.c L335-344)
**************************************/

@Test
func lz4fGetBlockSizeTest(): Unit {
    @Assert(LZ4F_getBlockSize(0) == 65536)      // 0 -> LZ4F_BLOCKSIZEID_DEFAULT(4)
    @Assert(LZ4F_getBlockSize(4) == 65536)
    @Assert(LZ4F_getBlockSize(5) == 262144)
    @Assert(LZ4F_getBlockSize(6) == 1048576)
    @Assert(LZ4F_getBlockSize(7) == 4194304)
    // out of range -> -(LZ4F_ERROR_maxBlockSize_invalid) == -2
    @Assert(LZ4F_getBlockSize(3) == -2)
    @Assert(LZ4F_getBlockSize(8) == -2)
    @Assert(LZ4F_getBlockSize(-1) == -2)
    println("lz4f getBlockSize pins verified")
}

/*-************************************
*  optimalBSID (lz4frame.c L361-373)
**************************************/

@Test
func lz4fOptimalBSIDTest(): Unit {
    @Assert(lz4fOptimalBSID(7, 0) == 4)
    @Assert(lz4fOptimalBSID(7, 65536) == 4)
    @Assert(lz4fOptimalBSID(7, 65537) == 5)
    @Assert(lz4fOptimalBSID(6, 262144) == 5)
    @Assert(lz4fOptimalBSID(6, 262145) == 6)
    @Assert(lz4fOptimalBSID(6, 300000) == 6)
    @Assert(lz4fOptimalBSID(5, 10) == 4)
    @Assert(lz4fOptimalBSID(4, 10) == 4)
    // upstream quirk: requested=0 returns 0 unchanged (loop never entered)
    @Assert(lz4fOptimalBSID(0, 999) == 0)
    println("lz4f optimalBSID pins verified")
}

/*-************************************
*  Bounds math (lz4frame.c L381-418, L884-890)
**************************************/

@Test
func lz4fCompressBoundTest(): Unit {
    // compressBound(0, None): None -> worst-case prefs (ccs=1, bcs=1, bs=4),
    // autoFlush=0 so public entry passes alreadyBuffered=(size_t)-1
    @Assert(LZ4F_compressBound(0, Option<LZ4F_preferences_t>.None) == 65551)
    // prefs{bs=4, af=1, ccs=1}: autoFlush set -> alreadyBuffered=0
    var p1 = LZ4F_preferences_t()
    p1.frameInfo.blockSizeID = LZ4F_max64KB
    p1.autoFlush = 1
    p1.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled
    @Assert(LZ4F_compressBound(100, Some(p1)) == 112)
    // prefs{bs=7, af=0}: buffered up to 4MB-1, no flush -> one full block +
    // frameEnd. NOTE: brief pinned 4, but upstream C probe at 0774d055
    // returns 4194312 (maxSrcSize=4194403 => nbFullBlocks=1); corrected
    // against executable upstream ground truth (see task report).
    var p2 = LZ4F_preferences_t()
    p2.frameInfo.blockSizeID = LZ4F_max4MB
    p2.autoFlush = 0
    @Assert(LZ4F_compressBound(100, Some(p2)) == 4194312)
    // compressFrameBound: None -> zeroed prefs + autoFlush=1, +maxFHSize(19)
    @Assert(LZ4F_compressFrameBound(0, Option<LZ4F_preferences_t>.None) == 23)
    @Assert(LZ4F_compressFrameBound(65536, Option<LZ4F_preferences_t>.None) == 65563)
    var p3 = LZ4F_preferences_t()
    p3.frameInfo.blockSizeID = LZ4F_max64KB
    p3.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled
    @Assert(LZ4F_compressFrameBound(65536, Some(p3)) == 65567)
    // internal sentinel: alreadyBuffered=Int64.Max clamps to blockSize-1
    @Assert(lz4fCompressBoundInternal(0, Option<LZ4F_preferences_t>.None, Int64.Max) == 65551)
    println("lz4f bounds pins verified")
}

/*-************************************
*  Header checksum (lz4frame.c L351-355)
**************************************/

@Test
func lz4fHeaderChecksumTest(): Unit {
    // default 7B header, checksum covers post-magic region (FLG+BD)
    let hdrA: Array<UInt8> = [0x40u8, 0x40u8]
    // 19B header with contentSize(12345) + dictID(0x00ABCDEF)
    let hdrB: Array<UInt8> = [
        0x49u8, 0x60u8,
        0x39u8, 0x30u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8,
        0xEFu8, 0xCDu8, 0xABu8, 0x00u8
    ]
    // pins cross-checked against upstream xxhash C probe (task report)
    @Assert(lz4fHeaderChecksum(hdrA, 2) == 0xC0u8)
    @Assert(lz4fHeaderChecksum(hdrB, 14) == 0x7Au8)
    // cross self-verification through this repo's XXH32
    let a32 = XXH32(hdrA, 2, 0u32)
    let b32 = XXH32(hdrB, 14, 0u32)
    @Assert(a32 == 0x101EC066u32)
    @Assert(b32 == 0xBB127A4Au32)
    @Assert(lz4fHeaderChecksum(hdrA, 2) == UInt8((a32 >> 8) & 0xFFu32))
    @Assert(lz4fHeaderChecksum(hdrB, 14) == UInt8((b32 >> 8) & 0xFFu32))
    println("lz4f header checksum pins verified")
}

/*-************************************
*  cctx lifecycle (lz4frame.c L605-643)
**************************************/

@Test
func lz4fCctxLifecycleTest(): Unit {
    let cctx = LZ4F_createCompressionContext(100u32)
    @Assert(cctx.version == 100u32)
    @Assert(cctx.cStage == 0)             // 0: compression uninitialized
    @Assert(cctx.tmpBuff.size == 0)       // empty array == C NULL
    @Assert(cctx.tmpIn == 0)
    @Assert(cctx.tmpInSize == 0)
    @Assert(cctx.maxBlockSize == 0)
    @Assert(cctx.maxBufferSize == 0)
    @Assert(cctx.totalInSize == 0u64)
    @Assert(cctx.lz4CtxFast.isNone())
    @Assert(cctx.lz4CtxHC.isNone())
    @Assert(cctx.lz4CtxAlloc == 0)       // 0=none
    @Assert(cctx.lz4CtxType == 0)
    @Assert(cctx.cdict.isNone())
    @Assert(cctx.blockCompressMode == 0)  // LZ4B_COMPRESSED
    @Assert(cctx.prefs.frameInfo.blockSizeID == LZ4F_max64KB)
    @Assert(LZ4F_freeCompressionContext(cctx) == 0)
    println("lz4f cctx lifecycle pins verified")
}

/*-************************************
*  Preference / option struct defaults
**************************************/

@Test
func lz4fPrefsDefaultsTest(): Unit {
    // LZ4F_preferences_t() == LZ4F_INIT_PREFERENCES field by field
    let p = LZ4F_preferences_t()
    @Assert(p.frameInfo.blockSizeID == LZ4F_max64KB)
    @Assert(p.frameInfo.blockMode == LZ4F_blockLinked)
    @Assert(p.frameInfo.contentChecksumFlag == LZ4F_noContentChecksum)
    @Assert(p.frameInfo.frameType == LZ4F_frame)
    @Assert(p.frameInfo.contentSize == 0u64)
    @Assert(p.frameInfo.dictID == 0u32)
    @Assert(p.frameInfo.blockChecksumFlag == LZ4F_noBlockChecksum)
    @Assert(p.compressionLevel == 0)
    @Assert(p.autoFlush == 0)
    @Assert(p.favorDecSpeed == 0)
    @Assert(LZ4F_compressOptions_t().stableSrc == 0)
    // struct copy independence (value semantics, incl. nested struct)
    var q = p
    q.frameInfo.blockSizeID = LZ4F_max1MB
    q.autoFlush = 1
    @Assert(q.frameInfo.blockSizeID == LZ4F_max1MB)
    @Assert(q.autoFlush == 1)
    @Assert(p.frameInfo.blockSizeID == LZ4F_max64KB)
    @Assert(p.autoFlush == 0)
    var fi = p.frameInfo
    fi.contentSize = 777u64
    @Assert(fi.contentSize == 777u64)
    @Assert(p.frameInfo.contentSize == 0u64)
    println("lz4f prefs defaults + copy independence verified")
}

/*-************************************
*  M5 Task 2: compressBegin golden (vs upstream C, 0774d055)
**************************************/
// frhdr rows of corpus/block_golden_ref.txt (rows 426..435): fresh cctx +
// LZ4F_compressBegin(dst 19B) over A=RDG(65536,0.50,0). The input is never
// consumed (Begin writes only the frame header) - its digests (inxxh32=..
// c20f7bcc / inxxh64=..197a59a7c9d2bd88, asserted below) pin row
// self-description per the manifest v2 convention. wantFlg/wantBd are the
// artifact's FLG/BD bytes (hard pins, not recomputed).
// (bs, bm, ccs, bcs, csz, did, lv, size, xxh32, xxh64, flg, bd, fileRowIdx)
let FRHDR_GOLD_REF: Array<(Int32, Int32, Int32, Int32, UInt64, UInt32, Int32,
        Int64, UInt32, UInt64, UInt8, UInt8, Int64)> = [
    (4, 0, 0, 0, 0u64, 0u32, 0, 7, 0x4d36acbbu32, 0xef673229f566e93eu64, 0x40u8, 0x40u8, 426),
    (4, 0, 0, 0, 65536u64, 0u32, 0, 15, 0xcc6af087u32, 0x3d3470bbdc08f320u64, 0x48u8, 0x40u8, 427),
    (4, 0, 0, 0, 0u64, 305419896u32, 0, 11, 0xb48af4b0u32, 0xf008a99e5fd84972u64, 0x41u8, 0x40u8, 428),
    (4, 0, 0, 0, 65536u64, 305419896u32, 0, 19, 0x82e1e15du32, 0x875ea16e45dc7986u64, 0x49u8, 0x40u8, 429),
    (4, 0, 1, 1, 0u64, 0u32, 0, 7, 0x4b25b029u32, 0xf7b88e7277de3f23u64, 0x54u8, 0x40u8, 430),
    (4, 1, 0, 0, 0u64, 0u32, 0, 7, 0x50e9b471u32, 0x3edc0ea251910496u64, 0x60u8, 0x40u8, 431),
    (5, 0, 0, 0, 0u64, 0u32, 0, 7, 0x9fd97441u32, 0x5d444498c766c70cu64, 0x40u8, 0x50u8, 432),
    (6, 0, 0, 0, 0u64, 0u32, 0, 7, 0x60b8dfcfu32, 0x4f8094eb26b16cadu64, 0x40u8, 0x60u8, 433),
    (7, 0, 0, 0, 0u64, 0u32, 0, 7, 0x07cb7622u32, 0xaaa8d219b1dba82eu64, 0x40u8, 0x70u8, 434),
    (4, 0, 0, 0, 0u64, 0u32, 9, 7, 0x4d36acbbu32, 0xef673229f566e93eu64, 0x40u8, 0x40u8, 435),
]

// corpus policy: artifact byte-compare is best-effort (corpus/ is untracked,
// regenerated via scripts/gen_golden.sh); size/digest assertions always run
private func lz4fReadArtifact(rowIdx: Int64): Option<Array<Byte>> {
    let s = rowIdx.toString()
    let padded = if (s.size == 1) { "00${s}" } else if (s.size == 2) { "0${s}" } else { s }
    let name = "/block/${padded}.lz4"
    try {
        return Some(File.readFrom("corpus" + name))
    } catch (_: Exception) {
        try {
            return Some(File.readFrom("../corpus" + name))
        } catch (_: Exception) {
            return None
        }
    }
}

@Test
func lz4fBeginHdrGoldenTest(): Unit {
    let n: Int64 = 65536
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.50, 0.0, 0u32)
    // manifest v2 input provenance: every frhdr row pins A via inxxh fields
    @Assert(XXH32(a, n, 0u32) == 0xc20f7bccu32)
    @Assert(XXH64(a, n, 0u64) == 0x197a59a7c9d2bd88u64)
    var checked = 0
    var fileCompared = 0
    for ((bs, bm, ccs, bcs, csz, did, lv, wantSize, want32, want64, wantFlg, wantBd, fileRow) in FRHDR_GOLD_REF) {
        var p = LZ4F_preferences_t()
        p.frameInfo.blockSizeID = bs
        p.frameInfo.blockMode = bm
        p.frameInfo.contentChecksumFlag = ccs
        p.frameInfo.blockChecksumFlag = bcs
        p.frameInfo.contentSize = csz
        p.frameInfo.dictID = did
        p.compressionLevel = lv
        let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
        let dst = Array<UInt8>(19, {_ => 0xEEu8})   // sentinel beyond written bytes
        let r = LZ4F_compressBegin(cctx, dst, 0, 19, Some(p))
        // size formula pin: 7 + 8*[csz>0] + 4*[did>0] (lz4frame.c L796-829)
        let wantByFormula = 7 + (if (csz > 0u64) { 8 } else { 0 }) + (if (did > 0u32) { 4 } else { 0 })
        if (r != wantSize || wantSize != wantByFormula) {
            println("FRHDR row ${fileRow}: got ${r} want ${wantSize} (formula ${wantByFormula})")
        }
        @Assert(r == wantSize)
        @Assert(wantSize == wantByFormula)
        if (r < 19) {
            @Assert(dst[r] == 0xEEu8)   // exactly r bytes written
        }
        // magic LE32 (LZ4F_MAGICNUMBER = 0x184D2204)
        @Assert(dst[0] == 0x04u8 && dst[1] == 0x22u8 && dst[2] == 0x4Du8 && dst[3] == 0x18u8)
        // FLG / BD bytes pinned from the C artifacts
        if (dst[4] != wantFlg || dst[5] != wantBd) {
            println("FLG/BD row ${fileRow}: got ${dst[4]}/${dst[5]} want ${wantFlg}/${wantBd}")
        }
        @Assert(dst[4] == wantFlg)
        @Assert(dst[5] == wantBd)
        // optional contentSize LE64 at offset 6 (L810-813)
        if (csz > 0u64) {
            var cszBack: UInt64 = 0u64
            for (k in 0..8) {
                cszBack += UInt64(dst[6 + k]) << (8 * k)
            }
            @Assert(cszBack == csz)
        }
        // optional dictID LE32 after the optional contentSize (L815-818)
        if (did > 0u32) {
            let didStart = 6 + (if (csz > 0u64) { 8 } else { 0 })
            var didBack: UInt32 = 0u32
            for (k in 0..4) {
                didBack += UInt32(dst[didStart + k]) << (8 * k)
            }
            @Assert(didBack == did)
        }
        // HC byte == lz4fHeaderChecksum over the post-magic region (Task 1 pin)
        let hdrLen = r - 1 - 4
        let hdr = Array<UInt8>(hdrLen, {i => dst[4 + i]})
        @Assert(dst[r - 1] == lz4fHeaderChecksum(hdr, hdrLen))
        let got32 = XXH32(dst, r, 0u32)
        let got64 = XXH64(dst, r, 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST row ${fileRow}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        match (lz4fReadArtifact(fileRow)) {
            case Some(art) =>
                @Assert(Int64(art.size) == r)
                var eq = true
                for (k in 0..r) {
                    if (UInt8(art[k]) != dst[k]) {
                        eq = false
                    }
                }
                @Assert(eq)
                fileCompared += 1
            case None => println("frhdr row ${fileRow}: artifact missing, byte-compare skipped")
        }
        checked += 1
    }
    @Assert(checked == 10)
    // prefsPtr == None == INIT defaults: bytes equal the all-default row 426
    let cctxN = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dstN = Array<UInt8>(19, {_ => 0u8})
    @Assert(LZ4F_compressBegin(cctxN, dstN, 0, 19, Option<LZ4F_preferences_t>.None) == 7)
    @Assert(dstN[0] == 0x04u8 && dstN[1] == 0x22u8 && dstN[2] == 0x4Du8 && dstN[3] == 0x18u8)
    @Assert(dstN[4] == 0x40u8)   // default FLG: version 01<<6, linked, no flags
    @Assert(dstN[5] == 0x40u8)   // default BD: (max64KB & 7) << 4
    @Assert(dstN[6] == 0xC0u8)   // HC over {0x40, 0x40} (Task 1 headerChecksum pin)
    println("frhdr golden: ${checked}/10 rows, ${fileCompared} byte-exact artifacts")
}

/*-************************************
*  M5 Task 2: cctx state / buffers / ctx types
**************************************/
@Test
func lz4fBeginStateTest(): Unit {
    let dst = Array<UInt8>(19, {_ => 0u8})
    // default begin: cStage 1, xxh reset (XXH32("") seed 0 = 0x02CC5D05)
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    @Assert(LZ4F_compressBegin(cctx, dst, 0, 19, Option<LZ4F_preferences_t>.None) == 7)
    @Assert(cctx.cStage == 1)
    @Assert(XXH32_digest(cctx.xxh) == 0x02cc5d05u32)
    @Assert(cctx.tmpIn == 0 && cctx.tmpInSize == 0)
    @Assert(cctx.totalInSize == 0u64)
    @Assert(cctx.cdict.isNone())
    @Assert(cctx.prefs.frameInfo.blockSizeID == LZ4F_max64KB)   // None -> INIT(4)
    // buffer-size four quadrants (lz4frame.c L754-772)
    // (autoFlush, blockMode) -> requiredBuffSize
    let quads: Array<(UInt32, Int32, Int64)> = [
        (1u32, LZ4F_blockLinked, 65536),       // af=1 linked: window only
        (1u32, LZ4F_blockIndependent, 0),      // af=1 independent: no buffering
        (0u32, LZ4F_blockLinked, 196608),      // af=0 bs=4 linked: 65536+128KB
        (0u32, LZ4F_blockIndependent, 65536),  // af=0 bs=4 independent: block only
    ]
    for ((af, bmode, wantSz) in quads) {
        var q = LZ4F_preferences_t()
        q.autoFlush = af
        q.frameInfo.blockMode = bmode
        let c = LZ4F_createCompressionContext(LZ4F_VERSION)
        @Assert(LZ4F_compressBegin(c, dst, 0, 19, Some(q)) == 7)
        if (c.maxBufferSize != wantSz || Int64(c.tmpBuff.size) != wantSz) {
            println("QUAD af=${af} bm=${bmode}: got ${c.maxBufferSize}/${c.tmpBuff.size} want ${wantSz}")
        }
        @Assert(c.maxBufferSize == wantSz)
        @Assert(Int64(c.tmpBuff.size) == wantSz)
    }
    // blockSizeID 0 -> LZ4F_max64KB substitution before getBlockSize (L754-755)
    var z = LZ4F_preferences_t()
    z.frameInfo.blockSizeID = 0
    let cz = LZ4F_createCompressionContext(LZ4F_VERSION)
    @Assert(LZ4F_compressBegin(cz, dst, 0, 19, Some(z)) == 7)
    @Assert(cz.prefs.frameInfo.blockSizeID == LZ4F_max64KB)
    @Assert(cz.maxBlockSize == 65536)
    @Assert(dst[5] == 0x40u8)   // BD of substituted bsID 4
    // ctx types: lv=0 -> fast(1), lv=9 -> hc(2)
    var p0 = LZ4F_preferences_t()
    p0.compressionLevel = 0
    let c0 = LZ4F_createCompressionContext(LZ4F_VERSION)
    @Assert(LZ4F_compressBegin(c0, dst, 0, 19, Some(p0)) == 7)
    @Assert(c0.lz4CtxAlloc == 1 && c0.lz4CtxType == 1)
    @Assert(c0.lz4CtxFast.isSome() && c0.lz4CtxHC.isNone())
    var p9 = LZ4F_preferences_t()
    p9.compressionLevel = 9
    let c9 = LZ4F_createCompressionContext(LZ4F_VERSION)
    @Assert(LZ4F_compressBegin(c9, dst, 0, 19, Some(p9)) == 7)
    @Assert(c9.lz4CtxAlloc == 2 && c9.lz4CtxType == 2)
    @Assert(c9.lz4CtxHC.isSome() && c9.lz4CtxFast.isNone())
    // same cctx lv9 -> lv0: alloc retained (2), type switched to 1, fresh fast
    // object (was None), HC object untouched; identical header bytes both times
    let cs = LZ4F_createCompressionContext(LZ4F_VERSION)
    let d1 = Array<UInt8>(19, {_ => 0u8})
    @Assert(LZ4F_compressBegin(cs, d1, 0, 19, Some(p9)) == 7)
    @Assert(cs.lz4CtxAlloc == 2 && cs.lz4CtxType == 2)
    @Assert(cs.lz4CtxFast.isNone())
    var hcLv: Int32 = -1
    if (let Some(h) <- cs.lz4CtxHC) {
        hcLv = h.compressionLevel
    }
    @Assert(hcLv == 9)   // linked initStream -> resetStreamHC_fast(HC, 9)
    let d2 = Array<UInt8>(19, {_ => 0u8})
    @Assert(LZ4F_compressBegin(cs, d2, 0, 19, Some(p0)) == 7)
    @Assert(cs.lz4CtxAlloc == 2 && cs.lz4CtxType == 1)   // alloc branch NOT taken
    @Assert(cs.lz4CtxFast.isSome())   // type-switch branch rebuilt the fast ctx
    var hcLv2: Int32 = -1
    if (let Some(h) <- cs.lz4CtxHC) {
        hcLv2 = h.compressionLevel
    }
    @Assert(hcLv2 == 9)   // HC object retained with its state
    for (k in 0..7) {
        @Assert(d1[k] == d2[k])
    }
    // same cctx lv0 -> lv9: alloc 1 -> 2 (HC fresh, fast dropped == C free)
    let cs2 = LZ4F_createCompressionContext(LZ4F_VERSION)
    @Assert(LZ4F_compressBegin(cs2, dst, 0, 19, Some(p0)) == 7)
    @Assert(cs2.lz4CtxAlloc == 1 && cs2.lz4CtxType == 1)
    @Assert(LZ4F_compressBegin(cs2, dst, 0, 19, Some(p9)) == 7)
    @Assert(cs2.lz4CtxAlloc == 2 && cs2.lz4CtxType == 2)
    @Assert(cs2.lz4CtxHC.isSome() && cs2.lz4CtxFast.isNone())
    // position-pair convention: header lands at dstIdx, prefix untouched
    let dOff = Array<UInt8>(32, {_ => 0xEEu8})
    @Assert(LZ4F_compressBegin(cctx, dOff, 3, 19, Option<LZ4F_preferences_t>.None) == 7)
    @Assert(dOff[2] == 0xEEu8 && dOff[3] == 0x04u8 && dOff[8] == 0x40u8)
    @Assert(dOff[9] == 0xC0u8 && dOff[10] == 0xEEu8)
    println("lz4f begin state / quadrant / ctx-type pins verified")
}

/*-************************************
*  M5 Task 2: begin error path
**************************************/
@Test
func lz4fBeginErrorTest(): Unit {
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dst = Array<UInt8>(19, {_ => 0u8})
    let r = LZ4F_compressBegin(cctx, dst, 0, 18, Option<LZ4F_preferences_t>.None)
    @Assert(r == -11)   // -LZ4F_ERROR_dstMaxSize_tooSmall
    @Assert(LZ4F_isError(r) == true)
    @Assert(LZ4F_getErrorName(r) == "ERROR_dstMaxSize_tooSmall")
    // exactly 19 (maxFHSize) passes (L710: strictly-less comparison)
    @Assert(LZ4F_compressBegin(cctx, dst, 0, 19, Option<LZ4F_preferences_t>.None) == 7)
    println("lz4f begin error path pins verified")
}

/*-************************************
*  M5 Task 2: Begin_usingDict dict state
**************************************/
@Test
func lz4fBeginDictStateTest(): Unit {
    let n: Int64 = 65536
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.50, 0.0, 0u32)
    let dict = Array<UInt8>(4096, {i => a[i]})   // A sliced to 4096 bytes
    let dst = Array<UInt8>(19, {_ => 0u8})
    // lv=0: lz4CtxType == ctxFast -> LZ4_loadDict(lz4CtxFast, dict, 4096)
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var p0 = LZ4F_preferences_t()
    p0.compressionLevel = 0
    @Assert(LZ4F_compressBegin_usingDict(cctx, dst, 0, 19, dict, 4096, Some(p0)) == 7)
    var ds = -1i64
    if (let Some(f) <- cctx.lz4CtxFast) {
        ds = f.dictSize
    }
    @Assert(ds == 4096)
    // lv=9: lz4CtxType == ctxHC -> LZ4_loadDictHC(lz4CtxHC, dict, 4096)
    let cctx2 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var p9 = LZ4F_preferences_t()
    p9.compressionLevel = 9
    @Assert(LZ4F_compressBegin_usingDict(cctx2, dst, 0, 19, dict, 4096, Some(p9)) == 7)
    var ds2 = -1i64
    if (let Some(h) <- cctx2.lz4CtxHC) {
        ds2 = h.prefixEndIdx - h.prefixStartIdx
    }
    @Assert(ds2 == 4096)
    println("lz4f begin_usingDict dict-state pins verified")
}
