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
// M5 Task 3: frame golden matrix (frame rows 436..462 - full streaming
// frames via Begin + Update[/uncompressedUpdate/flush]* + End, values from
// the regenerated C corpus incl. per-call return pins probed on stderr) plus
// update state / error / flush-quirk / uncompressed-semantics pins.

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

/*-************************************
*  M5 Task 3: frame golden matrix (vs upstream C, 0774d055)
**************************************/
// frame rows of corpus/block_golden_ref.txt (rows 436..462): fresh cctx per
// row, one dst buffer sized LZ4F_compressFrameBound(n, &prefs), pointer
// advanced per call with capacity = remaining (compressFrame_usingCDict
// pattern; NO compressFrame parameter overrides - the raw row prefs drive
// Begin). Inputs: A=RDG(65536,0.50,0) rows 1-7+27, C=RDG(131072,0.90,0)
// rows 8-23, D=RDG(255,0.50,0), G=RDG(1,0.00,0), F=RDG(0,0.00,0).
// Scenario codes (scen): 0=1shot, 1=flushmid (50000 + flush + 81072),
// 2=umix (bm=1: 65536 + uncompressedUpdate 32768 + 32768), 3=chunks5
// (26214 x3 + 26215 x2). ss=1 rows pass {stableSrc=1} to the Updates.
// (n, mp, seed, bs, bm, ccs, bcs, csz, did, lv, fav, af, ss, scen,
//  wantSize, want32, want64, fileRowIdx)
let FRAME_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32, Int32,
        UInt64, UInt32, Int32, Int32, Int32, Int32, Int32,
        Int64, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 38688, 0xa2371855u32, 0x54ad2015adcf2431u64, 436),
    (65536, 0.50, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 1, 0, 0, 38688, 0xa2371855u32, 0x54ad2015adcf2431u64, 437),
    (65536, 0.50, 0u32, 4, 0, 1, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 38692, 0x1d540383u32, 0xfd0788e74ed12bcdu64, 438),
    (65536, 0.50, 0u32, 4, 0, 0, 1, 0u64, 0u32, 0, 0, 0, 0, 0, 38692, 0x4b1f7df2u32, 0x1c652b10d1c44b9du64, 439),
    (65536, 0.50, 0u32, 4, 0, 1, 1, 0u64, 0u32, 0, 0, 0, 0, 0, 38696, 0xb5b0cb46u32, 0xeb8940a12d1ad8ecu64, 440),
    (65536, 0.50, 0u32, 4, 1, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 36474, 0xc4aa94e0u32, 0xe004ae20c13bd03bu64, 441),
    (65536, 0.50, 0u32, 4, 1, 1, 1, 0u64, 0u32, 0, 0, 0, 0, 0, 36482, 0x570daea3u32, 0x5896cdf09b61aa11u64, 442),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 24223, 0xce05c0d4u32, 0x8929915b8696d39du64, 443),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 1, 0, 24223, 0xce05c0d4u32, 0x8929915b8696d39du64, 444),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 1, 0, 0, 24223, 0xce05c0d4u32, 0x8929915b8696d39du64, 445),
    (131072, 0.90, 0u32, 4, 1, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 25344, 0x20d9d6b0u32, 0xcc8ff21ea6df12d5u64, 446),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 3, 0, 0, 0, 0, 18386, 0x725bd936u32, 0x187be24aa58b09d5u64, 447),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 9, 0, 0, 0, 0, 17711, 0xc06c71feu32, 0xb418920b1f7ba3deu64, 448),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 12, 0, 0, 0, 0, 17576, 0x8f36fe8au32, 0x2b44accc0cc1f155u64, 449),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 12, 1, 0, 0, 0, 17766, 0x6bb0cd69u32, 0xac1e568d74329562u64, 450),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, -3, 0, 0, 0, 0, 27653, 0xff56c5c9u32, 0x85380027cdb0c592u64, 451),
    (131072, 0.90, 0u32, 5, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 24215, 0xd1b08705u32, 0x93d72f2f595c339bu64, 452),
    (131072, 0.90, 0u32, 6, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 24215, 0xb2a44c91u32, 0x8fe4d15fe4d0f4a7u64, 453),
    (131072, 0.90, 0u32, 7, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 24215, 0x623fca64u32, 0x1a8bdccba89800e6u64, 454),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 131072u64, 0u32, 0, 0, 0, 0, 0, 24231, 0xb74dd86eu32, 0xfc1ce4c31356dbdeu64, 455),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 1, 24244, 0xd9525d2au32, 0x98e6a260f29a07eeu64, 456),
    (131072, 0.90, 0u32, 4, 1, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 2, 52010, 0x085a3fe4u32, 0x4e0a19e835862d16u64, 457),
    (131072, 0.90, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 3, 24223, 0xce05c0d4u32, 0x8929915b8696d39du64, 458),
    (255, 0.50, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 253, 0x24e5d1c3u32, 0x8d71210396ddea98u64, 459),
    (1, 0.00, 0u32, 4, 0, 0, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 16, 0x40b7cb54u32, 0x884fded16025931cu64, 460),
    (0, 0.00, 0u32, 4, 0, 1, 0, 0u64, 0u32, 0, 0, 0, 0, 0, 15, 0x67a81150u32, 0x0de3431ec7da9349u64, 461),
    (65536, 0.50, 0u32, 4, 0, 0, 0, 0u64, 42u32, 0, 0, 0, 0, 0, 38692, 0xc6b180e2u32, 0xf1553e445e7d35e4u64, 462),
]

// 读游标辅助:LE32 解码(块头/校验解析用)
private func lz4fReadLE32(buf: Array<UInt8>, idx: Int64): UInt32 {
    return UInt32(buf[idx]) | (UInt32(buf[idx + 1]) << 8) |
        (UInt32(buf[idx + 2]) << 16) | (UInt32(buf[idx + 3]) << 24)
}

@Test
func lz4fFrameGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    var indepDecoded = 0
    var ccsChecked = 0
    for ((n, mp, seed, bs, bm, ccs, bcs, csz, did, lv, fav, af, ss, scen, wantSize, want32, want64, fileRow) in FRAME_GOLD_REF) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        var prefs = LZ4F_preferences_t()
        prefs.frameInfo.blockSizeID = bs
        prefs.frameInfo.blockMode = bm
        prefs.frameInfo.contentChecksumFlag = ccs
        prefs.frameInfo.blockChecksumFlag = bcs
        prefs.frameInfo.contentSize = csz
        prefs.frameInfo.dictID = did
        prefs.compressionLevel = lv
        prefs.favorDecSpeed = UInt32(fav)
        prefs.autoFlush = UInt32(af)
        let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
        let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
        let dst = Array<UInt8>(dstCap, {_ => 0u8})
        var pos: Int64 = 0
        var r = LZ4F_compressBegin(cctx, dst, pos, dstCap - pos, Some(prefs))
        @Assert(!LZ4F_isError(r))
        pos += r
        var cOpt = Option<LZ4F_compressOptions_t>.None
        if (ss != 0) {
            var o = LZ4F_compressOptions_t()
            o.stableSrc = 1u32
            cOpt = Some(o)
        }
        if (scen == 0) {
            r = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, 0, n, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
        } else if (scen == 1) {
            r = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, 0, 50000, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_flush(cctx, dst, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, 50000, n - 50000, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
        } else if (scen == 2) {
            r = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, 0, 65536, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_uncompressedUpdate(cctx, dst, pos, dstCap - pos, input, 65536, 32768, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, 98304, 32768, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
        } else {
            let chunkSizes: Array<Int64> = [26214, 26214, 26214, 26215, 26215]
            var off: Int64 = 0
            for (k in 0..5) {
                r = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, off, chunkSizes[k], cOpt)
                @Assert(!LZ4F_isError(r))
                pos += r
                off += chunkSizes[k]
            }
        }
        r = LZ4F_compressEnd(cctx, dst, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
        @Assert(!LZ4F_isError(r))
        pos += r
        // input provenance: digests must still equal the C manifest inxxh
        // values (also proves no compression path mutates the src buffer)
        let wantIn32 = XXH32(input, n, 0u32)
        if (n == 131072) {
            @Assert(wantIn32 == 0xbf1377f2u32)      // C=RDG(131072,0.90,0)
        } else if (n == 65536) {
            @Assert(wantIn32 == 0xc20f7bccu32)      // A=RDG(65536,0.50,0)
        } else if (n == 255) {
            @Assert(wantIn32 == 0xf125f7b1u32)      // D=RDG(255,0.50,0)
        } else if (n == 1) {
            @Assert(wantIn32 == 0x9608f5fbu32)      // G=RDG(1,0.00,0)
        } else {
            @Assert(wantIn32 == 0x02cc5d05u32)      // F=RDG(0,0.00,0)
        }
        if (pos != wantSize) {
            println("FRAME row ${fileRow}: got ${pos} want ${wantSize}")
        }
        @Assert(pos == wantSize)
        let got32 = XXH32(dst, pos, 0u32)
        let got64 = XXH64(dst, pos, 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST row ${fileRow}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        match (lz4fReadArtifact(fileRow)) {
            case Some(art) =>
                @Assert(Int64(art.size) == pos)
                var eq = true
                for (k in 0..pos) {
                    if (UInt8(art[k]) != dst[k]) {
                        eq = false
                    }
                }
                if (!eq) {
                    println("BYTES row ${fileRow}: artifact mismatch")
                }
                @Assert(eq)
                fileCompared += 1
            case None => println("frame row ${fileRow}: artifact missing, byte-compare skipped")
        }
        // blockIndependent 闭环:解析自身输出,逐块独立解码,重组内容的
        // XXH32 == 输入的 XXH32(输入摘要在场景后立即以 C manifest 值钉校,
        // 见上方 provenance 断言)。比对经单一小状态累加器承载:全量套件
        // 高 GC 压力下,直接的大数组逐字节比对观测到偶发旁观数组陈旧读/
        // 覆写(复读即消失;dec/blk/dst 均已经多重 C 锚点字节校验 —— 见
        // 任务报告“关注项”),摘要累加路径在两工具链全部观测中稳定。
        if (bm == LZ4F_blockIndependent) {
            var p: Int64 = 7 + (if (csz > 0u64) { 8 } else { 0 }) + (if (did > 0u32) { 4 } else { 0 })
            var endmarkSeen = false
            let reassembly = XXH32_state_t()
            XXH32_reset(reassembly, 0u32)
            while (!endmarkSeen) {
                let bhdr = lz4fReadLE32(dst, p)
                if (bhdr == 0u32) {
                    endmarkSeen = true
                    break
                }
                let raw = (bhdr & 0x80000000u32) != 0u32
                let bsize = Int64(bhdr & 0x7FFFFFFFu32)
                if (raw) {
                    XXH32_update(reassembly, dst, bsize, offset: p + 4)
                } else {
                    let p0: Int64 = p
                    let blk = Array<UInt8>(bsize, {i => dst[p0 + 4 + i]})
                    let dec = Array<UInt8>(n, {_ => 0u8})
                    let dr = LZ4_decompress_safe(blk, Int32(bsize), dec, Int32(n))
                    if (dr <= 0) {
                        println("INDEP row ${fileRow}: block at ${p} decode got ${dr}")
                    }
                    @Assert(dr > 0)
                    XXH32_update(reassembly, dec, Int64(dr), offset: 0)
                }
                p += 4 + bsize + (if (bcs != 0) { 4 } else { 0 })
            }
            let gotReassembly = XXH32_digest(reassembly)
            if (gotReassembly != wantIn32) {
                println("INDEP row ${fileRow}: reassembly digest ${gotReassembly} want ${wantIn32}")
            }
            @Assert(gotReassembly == wantIn32)
            // endmark 之后仅剩可选内容校验
            @Assert(pos - p == 4 + Int64(ccs) * 4)
            indepDecoded += 1
        }
        // ccs 闭环:尾 4 字节 == XXH32(输入, seed 0)
        if (ccs == LZ4F_contentChecksumEnabled) {
            let tail = lz4fReadLE32(dst, pos - 4)
            if (tail != XXH32(input, n, 0u32)) {
                println("CCS row ${fileRow}: tail ${tail} want ${XXH32(input, n, 0u32)}")
            }
            @Assert(tail == XXH32(input, n, 0u32))
            ccsChecked += 1
        }
        checked += 1
    }
    @Assert(checked == 27)
    @Assert(fileCompared == 27 || fileCompared == 0)   // corpus policy: all-or-nothing
    @Assert(indepDecoded == 4)    // rows 6, 7, 11, 22
    @Assert(ccsChecked == 4)      // rows 3, 5, 7, 26
    println("frame golden: ${checked}/27 rows, ${fileCompared} byte-exact artifacts, ${indepDecoded} indep-decoded, ${ccsChecked} ccs-verified")
}

/*-************************************
*  M5 Task 3: update state evolution
**************************************/
@Test
func lz4fUpdateStateTest(): Unit {
    // chunks5 前 2 次 Update 返回 0(全缓冲 26214x2 < 65536)+ tmpInSize 累积
    let n: Int64 = 131072
    let cIn = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(cIn, n, 0.90, 0.0, 0u32)
    var prefs = LZ4F_preferences_t()   // C default: bs=4, af=0, linked
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dst = Array<UInt8>(140000, {_ => 0u8})
    var pos: Int64 = 0
    pos += LZ4F_compressBegin(cctx, dst, pos, 140000 - pos, Some(prefs))
    let chunkSizes: Array<Int64> = [26214, 26214, 26214, 26215, 26215]
    var off: Int64 = 0
    for (k in 0..5) {
        let r = LZ4F_compressUpdate(cctx, dst, pos, 140000 - pos, cIn, off, chunkSizes[k],
            Option<LZ4F_compressOptions_t>.None)
        if (k == 0 || k == 1) {
            @Assert(r == 0)   // C probe: upd1=0 upd2=0
            @Assert(cctx.tmpInSize == Int64(k + 1) * 26214)
        }
        if (k == 2) {
            @Assert(r == 8308)   // C probe: block 1 flushed from tmpBuff
        }
        if (k == 4) {
            @Assert(r == 15904)  // C probe: block 2 flushed from tmpBuff
        }
        pos += r
        off += chunkSizes[k]
    }
    @Assert(cctx.totalInSize == 131072u64)
    @Assert(pos + 4 == 24223)   // golden row 23 minus endmark
    @Assert(LZ4F_compressEnd(cctx, dst, pos, 140000 - pos, Option<LZ4F_compressOptions_t>.None) == 4)
    // csz 行 totalInSize 演进(row 20:csz=131072 精确匹配)
    var pcsz = LZ4F_preferences_t()
    pcsz.frameInfo.contentSize = 131072u64
    let cctx2 = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dst2 = Array<UInt8>(140000, {_ => 0u8})
    var pos2: Int64 = 0
    pos2 += LZ4F_compressBegin(cctx2, dst2, pos2, 140000 - pos2, Some(pcsz))
    @Assert(cctx2.totalInSize == 0u64)   // Begin(contentSize!=0) 重置
    let half = LZ4F_compressUpdate(cctx2, dst2, pos2, 140000 - pos2, cIn, 0, 65536,
        Option<LZ4F_compressOptions_t>.None)
    @Assert(!LZ4F_isError(half))
    pos2 += half
    @Assert(cctx2.totalInSize == 65536u64)
    let half2 = LZ4F_compressUpdate(cctx2, dst2, pos2, 140000 - pos2, cIn, 65536, 65536,
        Option<LZ4F_compressOptions_t>.None)
    @Assert(!LZ4F_isError(half2))
    pos2 += half2
    @Assert(cctx2.totalInSize == 131072u64)
    @Assert(LZ4F_compressEnd(cctx2, dst2, pos2, 140000 - pos2, Option<LZ4F_compressOptions_t>.None) == 4)
    // A 默认行:恰一块满(n == blockSize)直接自 src 出块,C 实测返回
    // 38677(任务简报"返回 0 入 tmpBuff"与上游 >= 语义不符,C 探针钉正);
    // linked + fromSrcBuffer + 非 stableSrc → localSaveDict 后 tmpIn = 64KB
    let a = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(a, 65536, 0.50, 0.0, 0u32)
    let cctx3 = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dst3 = Array<UInt8>(70000, {_ => 0u8})
    var pos3: Int64 = 0
    pos3 += LZ4F_compressBegin(cctx3, dst3, pos3, 70000 - pos3, Option<LZ4F_preferences_t>.None)
    let rA = LZ4F_compressUpdate(cctx3, dst3, pos3, 70000 - pos3, a, 0, 65536,
        Option<LZ4F_compressOptions_t>.None)
    @Assert(rA == 38677)   // C probe: begin=7 upd=38677 end=4
    pos3 += rA
    @Assert(cctx3.tmpInSize == 0)
    @Assert(cctx3.tmpIn == 65536)   // localSaveDict 拷贝 64KB 字典后越过
    @Assert(cctx3.totalInSize == 65536u64)
    @Assert(LZ4F_compressEnd(cctx3, dst3, pos3, 70000 - pos3, Option<LZ4F_compressOptions_t>.None) == 4)
    @Assert(pos3 + 4 == 38688)   // golden row 1
    println("lz4f update state evolution pins verified")
}

/*-************************************
*  M5 Task 3: update error paths
**************************************/
@Test
func lz4fUpdateErrorTest(): Unit {
    let n: Int64 = 65536
    let a = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(a, n, 0.50, 0.0, 0u32)
    // 未 Begin 先 Update → -20(cStage 检查先于 bound 检查)
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dst = Array<UInt8>(70000, {_ => 0u8})
    let r1 = LZ4F_compressUpdate(cctx, dst, 0, 70000, a, 0, n, Option<LZ4F_compressOptions_t>.None)
    @Assert(r1 == -20)
    @Assert(LZ4F_isError(r1))
    @Assert(LZ4F_getErrorName(r1) == "ERROR_compressionState_uninitialized")
    // Begin 后 dstCapacity = compressBound - 1 → -11(与 cctx 实际默认
    // prefs 对齐求界;None 求界代入最坏偏好,不适用本断言)
    @Assert(LZ4F_compressBegin(cctx, dst, 0, 19, Option<LZ4F_preferences_t>.None) == 7)
    let bound = LZ4F_compressBound(n, Some(LZ4F_preferences_t()))
    let r2 = LZ4F_compressUpdate(cctx, dst, 0, bound - 1, a, 0, n, Option<LZ4F_compressOptions_t>.None)
    @Assert(r2 == -11)
    @Assert(LZ4F_isError(r2))
    @Assert(LZ4F_getErrorName(r2) == "ERROR_dstMaxSize_tooSmall")
    // End 时 csz 声明与实际不符 → -14(错误后状态废弃,不复用;上游契约)
    let cctx2 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var p = LZ4F_preferences_t()
    p.frameInfo.contentSize = 1u64
    @Assert(LZ4F_compressBegin(cctx2, dst, 0, 19, Some(p)) == 15)
    let r3 = LZ4F_compressUpdate(cctx2, dst, 15, 70000 - 15, a, 0, 100, Option<LZ4F_compressOptions_t>.None)
    @Assert(!LZ4F_isError(r3))
    let r4 = LZ4F_compressEnd(cctx2, dst, 15 + r3, 70000 - 15 - r3, Option<LZ4F_compressOptions_t>.None)
    @Assert(r4 == -14)
    @Assert(LZ4F_isError(r4))
    @Assert(LZ4F_getErrorName(r4) == "ERROR_frameSize_wrong")
    @Assert(cctx2.cStage == 0)   // 错误在 cStage=0 之后检出(顺序保真)
    println("lz4f update error path pins verified")
}

/*-************************************
*  M5 Task 3: flush quirks
**************************************/
@Test
func lz4fFlushQuirkTest(): Unit {
    let dst = Array<UInt8>(1000, {_ => 0u8})
    // fresh cctx(未 Begin)flush → 0:tmpInSize==0 先于 cStage 检查
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    @Assert(LZ4F_flush(cctx, dst, 0, 1000, Option<LZ4F_compressOptions_t>.None) == 0)
    // Begin 后无数据 flush → 0
    @Assert(LZ4F_compressBegin(cctx, dst, 0, 19, Option<LZ4F_preferences_t>.None) == 7)
    @Assert(LZ4F_flush(cctx, dst, 7, 1000 - 7, Option<LZ4F_compressOptions_t>.None) == 0)
    // buffering 后 flush 返回块字节数;再 flush → 0
    let d = Array<UInt8>(255, {_ => 0u8})
    RDG_genBuffer(d, 255, 0.50, 0.0, 0u32)
    @Assert(LZ4F_compressUpdate(cctx, dst, 7, 1000 - 7, d, 0, 255, Option<LZ4F_compressOptions_t>.None) == 0)
    let fr = LZ4F_flush(cctx, dst, 7, 1000 - 7, Option<LZ4F_compressOptions_t>.None)
    @Assert(fr == 242)   // C probe row 24: end=246 = flush(4+238=242) + endmark(4)
    @Assert(LZ4F_flush(cctx, dst, 7 + fr, 1000 - 7 - fr, Option<LZ4F_compressOptions_t>.None) == 0)
    // 带 4 字节缓冲的 cStage 错误路径:End 之后再 flush(tmpInSize==0)→ 0
    @Assert(LZ4F_compressEnd(cctx, dst, 7 + fr, 1000 - 7 - fr, Option<LZ4F_compressOptions_t>.None) == 4)
    @Assert(LZ4F_flush(cctx, dst, 0, 1000, Option<LZ4F_compressOptions_t>.None) == 0)
    println("lz4f flush quirk pins verified")
}

/*-************************************
*  M5 Task 3: uncompressedUpdate semantics
**************************************/
@Test
func lz4fUncompressedSemanticsTest(): Unit {
    // bm=1 umix 序列仓颉侧重放 == C golden 行 22,返回值序列钉住:
    // Update(65536) 出压缩块(7994);uncompressedUpdate(32768) af=0 下
    // 先全缓冲(0);Update(32768) 触发模式切换 flush 出原样块(4+32768),
    // 再缓冲新数据(0 不返回 —— 返回值即 flush 的 32772);End flush 出
    // 末块 + endmark(11237)。
    let n: Int64 = 131072
    let cIn = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(cIn, n, 0.90, 0.0, 0u32)
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockMode = LZ4F_blockIndependent
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
    let dst = Array<UInt8>(dstCap, {_ => 0u8})
    var pos: Int64 = 0
    pos += LZ4F_compressBegin(cctx, dst, pos, dstCap - pos, Some(prefs))
    @Assert(cctx.blockCompressMode == LZ4F_LZ4B_COMPRESSED)
    let r1 = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, cIn, 0, 65536,
        Option<LZ4F_compressOptions_t>.None)
    @Assert(r1 == 7994)   // C probe: upd1=7994
    pos += r1
    let r2 = LZ4F_uncompressedUpdate(cctx, dst, pos, dstCap - pos, cIn, 65536, 32768,
        Option<LZ4F_compressOptions_t>.None)
    @Assert(r2 == 0)      // C probe: uupd=0(全缓冲)
    @Assert(cctx.blockCompressMode == LZ4F_LZ4B_UNCOMPRESSED)
    @Assert(cctx.tmpInSize == 32768)
    pos += r2
    let r3 = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, cIn, 98304, 32768,
        Option<LZ4F_compressOptions_t>.None)
    @Assert(r3 == 32772)  // C probe: upd2=32772(模式切换 flush = 原样块)
    pos += r3
    // flush 出的原样块:4B 头最高位置 1 + 32768 原始字节
    let bhdr = lz4fReadLE32(dst, pos - 32772)
    @Assert(bhdr == (32768u32 | 0x80000000u32))
    let r4 = LZ4F_compressEnd(cctx, dst, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
    @Assert(r4 == 11237)  // C probe: end=11237
    pos += r4
    @Assert(pos == 52010)   // golden row 22 size
    @Assert(XXH32(dst, pos, 0u32) == 0x085a3fe4u32)
    @Assert(XXH64(dst, pos, 0u64) == 0x4e0a19e835862d16u64)
    match (lz4fReadArtifact(457)) {
        case Some(art) =>
            @Assert(Int64(art.size) == pos)
            var eq = true
            for (k in 0..pos) {
                if (UInt8(art[k]) != dst[k]) {
                    eq = false
                }
            }
            @Assert(eq)
        case None => println("umix artifact missing, byte-compare skipped")
    }
    println("lz4f uncompressedUpdate semantics pins verified")
}

/*-************************************
*  M5 Task 4: one-shot compressFrame golden (vs upstream C, 0774d055)
**************************************/
// f1s rows of corpus/block_golden_ref.txt (rows 463..470): one-shot
// LZ4F_compressFrame over A/B/C. compressFrame applies its prefs
// transforms before delegating to compressFrame_usingCDict(None):
// prefs==None -> MEM_INIT-0 defaults, csz!=0 -> srcSize auto-rewrite,
// optimalBSID, autoFlush=1, srcSize<=getBlockSize -> forced independent,
// options.stableSrc=1. NOTE: f1s row 5 (C lv=9) lands byte-identical to
// frame row 13 (same input, raw af=0/bm=0 prefs) in C — autoFlush is
// output-neutral for exact block multiples — so the coinciding digests
// are C truth, not a copy error (values independently regenerated).
// (n, mp, seed, usePrefs, lv, ccs, csz, did, wantSize, want32, want64, fileRowIdx)
let F1S_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32, Int32,
        UInt64, UInt32, Int64, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 0, 0, 0, 0u64, 0u32, 36474, 0xc4aa94e0u32, 0xe004ae20c13bd03bu64, 463),
    (65536, 0.90, 7u32, 1, 3, 0, 0u64, 0u32, 5692, 0xa20f09e6u32, 0xa380622e95ab3b9cu64, 464),
    (65536, 0.90, 7u32, 1, 9, 0, 0u64, 0u32, 5561, 0xc7e873b1u32, 0x7b63a4490b842838u64, 465),
    (65536, 0.90, 7u32, 1, 12, 0, 0u64, 0u32, 5537, 0xf5a2b367u32, 0xcb8322be63b7bd27u64, 466),
    (131072, 0.90, 0u32, 1, 9, 0, 0u64, 0u32, 17711, 0xc06c71feu32, 0xb418920b1f7ba3deu64, 467),
    (65536, 0.50, 0u32, 1, 0, 0, 1u64, 0u32, 36482, 0x7f8ff7bau32, 0x47959d272b2ac65cu64, 468),
    (65536, 0.50, 0u32, 1, 0, 1, 0u64, 305419896u32, 36482, 0x4016ace0u32, 0x51f059e1a5bf5be2u64, 469),
    (65536, 0.50, 0u32, 1, -3, 0, 0u64, 0u32, 39278, 0xdb9c07b1u32, 0x23ac1aee62e91b35u64, 470),
]

@Test
func lz4fFrameOneShotGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    for ((n, mp, seed, usePrefs, lv, ccs, csz, did, wantSize, want32, want64, fileRow) in F1S_GOLD_REF) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        var prefsOpt = Option<LZ4F_preferences_t>.None
        if (usePrefs != 0) {
            var p = LZ4F_preferences_t()
            p.compressionLevel = lv
            p.frameInfo.contentChecksumFlag = ccs
            p.frameInfo.contentSize = csz
            p.frameInfo.dictID = did
            prefsOpt = Some(p)
        }
        let dstCap = LZ4F_compressFrameBound(n, prefsOpt)
        let dst = Array<UInt8>(dstCap, {_ => 0u8})
        let r = LZ4F_compressFrame(dst, 0, dstCap, input, n, prefsOpt)
        if (r != wantSize) {
            println("F1S row ${fileRow}: got ${r} want ${wantSize}")
        }
        @Assert(!LZ4F_isError(r))
        @Assert(r == wantSize)
        @Assert(r <= dstCap)
        let got32 = XXH32(dst, r, 0u32)
        let got64 = XXH64(dst, r, 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST row ${fileRow}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        // row 1(None prefs)结果必须 == 行间独立断言的 frame 行 6(bm=1)
        // 值:单块强制独立使然(双源交叉验证,防误拷贝)
        if (fileRow == 463) {
            @Assert(want32 == 0xc4aa94e0u32)
        }
        // row 6:头内 contentSize == 自动改写后的 srcSize(LE64 @ [6,14))
        if (fileRow == 468) {
            var cszBack: UInt64 = 0u64
            for (k in 0..8) {
                cszBack += UInt64(dst[6 + k]) << (8 * k)
            }
            @Assert(cszBack == 65536u64)   // csz=1 请求被改写为 srcSize
        }
        // row 5:多块 linked 保留(FLG bit5 = 0)+ 与 frame 行 13 的 C 巧合
        if (fileRow == 467) {
            @Assert((UInt32(dst[4]) & 0x20u32) == 0u32)
            @Assert(got32 == 0xc06c71feu32)
        }
        match (lz4fReadArtifact(fileRow)) {
            case Some(art) =>
                @Assert(Int64(art.size) == r)
                var eq = true
                for (k in 0..r) {
                    if (UInt8(art[k]) != dst[k]) {
                        eq = false
                    }
                }
                if (!eq) {
                    println("BYTES row ${fileRow}: artifact mismatch")
                }
                @Assert(eq)
                fileCompared += 1
            case None => println("f1s row ${fileRow}: artifact missing, byte-compare skipped")
        }
        checked += 1
    }
    @Assert(checked == 8)
    @Assert(fileCompared == 8 || fileCompared == 0)   // corpus policy: all-or-nothing
    println("f1s golden: ${checked}/8 rows, ${fileCompared} byte-exact artifacts")
}

/*-************************************
*  M5 Task 4: CDict one-shot golden (vs upstream C, 0774d055)
**************************************/
// fcd rows (471..472): fresh cctx + LZ4F_compressFrame_usingCDict with a
// CDict digested from dict=RDG(65536, mp=0.50, seed=99) (createCDict:
// loadDictSlow fast ctx / CLEVEL_DEFAULT loadDictHC ctx).
// (n, mp, seed, lv, bm, wantSize, want32, want64, fileRowIdx)
let FCD_GOLD_REF: Array<(Int64, Float64, UInt32, Int32, Int32,
        Int64, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 0, 0, 38651, 0x52e2a673u32, 0xa696a177293937eeu64, 471),
    (131072, 0.90, 0u32, 9, 1, 19109, 0x91bd0668u32, 0x0dd60c2f5c5274ffu64, 472),
]

@Test
func lz4fCDictGoldenTest(): Unit {
    // 字典出处钉值(与 M3 dictfast/dictslow 行同一字典)
    let dd: Int64 = 65536
    let dict = Array<UInt8>(dd, {_ => 0u8})
    RDG_genBuffer(dict, dd, 0.50, 0.0, 99u32)
    @Assert(XXH32(dict, dd, 0u32) == 0x059edec2u32)
    @Assert(XXH64(dict, dd, 0u64) == 0xd41565bb0ecfa4e3u64)
    let cdict = LZ4F_createCDict(dict, dd)
    var checked = 0
    var fileCompared = 0
    for ((n, mp, seed, lv, bm, wantSize, want32, want64, fileRow) in FCD_GOLD_REF) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        var prefs = LZ4F_preferences_t()
        prefs.compressionLevel = lv
        prefs.frameInfo.blockMode = bm
        let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
        let dst = Array<UInt8>(dstCap, {_ => 0u8})
        let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
        let r = LZ4F_compressFrame_usingCDict(cctx, dst, 0, dstCap, input, n,
            Some(cdict), Some(prefs))
        if (r != wantSize) {
            println("FCD row ${fileRow}: got ${r} want ${wantSize}")
        }
        @Assert(!LZ4F_isError(r))
        @Assert(r == wantSize)
        @Assert(r <= dstCap)
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
                if (!eq) {
                    println("BYTES row ${fileRow}: artifact mismatch")
                }
                @Assert(eq)
                fileCompared += 1
            case None => println("fcd row ${fileRow}: artifact missing, byte-compare skipped")
        }
        checked += 1
    }
    LZ4F_freeCDict(cdict)
    @Assert(checked == 2)
    @Assert(fileCompared == 2 || fileCompared == 0)
    println("fcd golden: ${checked}/2 rows, ${fileCompared} byte-exact artifacts")
}

/*-************************************
*  M5 Task 4: Begin_usingDict frame golden (vs upstream C, 0774d055)
**************************************/
// fdt rows (473..474): raw prefs via LZ4F_compressBegin_usingDict +
// Update + End (no compressFrame transforms: af=0, explicit bm).
// Row 1 (bm=0): linked frames keep the Begin-loaded dictionary for the
// whole frame (38651 < the 38688 no-dict frame row). Row 2 pins the
// blockIndependent dictionary quirk: lz4frame.h L556-559 documents
// usingDict as "only the first block uses the dictionary", but at this
// commit the per-block LZ4F_initStream(..., blockIndependent) reset
// detaches the dictionary ENTIRELY - the frame comes out byte-identical
// to a no-dict frame (C probe 2026-10-02: seed-77 64B dict and even an
// input-prefix dict both reproduce the exact no-dict frame, fast lv=0
// and HC lv=9 alike). CDict is the per-block-attach path instead (fcd
// row 2: 19109 < 20479 on the same input).
// (n, mp, seed, dd, dseed, lv, bm, wantSize, want32, want64, fileRowIdx)
let FDT_GOLD_REF: Array<(Int64, Float64, UInt32, Int64, UInt32, Int32, Int32,
        Int64, UInt32, UInt64, Int64)> = [
    (65536, 0.50, 0u32, 65536, 99u32, 0, 0, 38651, 0xe65dfaaeu32, 0x01941bd54d5dace4u64, 473),
    (131072, 0.90, 0u32, 64, 77u32, 9, 1, 20479, 0xebe5524bu32, 0x011ded165e31e20au64, 474),
]

@Test
func lz4fBeginDictGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    for ((n, mp, seed, dd, dseed, lv, bm, wantSize, want32, want64, fileRow) in FDT_GOLD_REF) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        let dict = Array<UInt8>(dd, {_ => 0u8})
        RDG_genBuffer(dict, dd, 0.50, 0.0, dseed)
        // 字典出处钉值(row1 与 fcd 同字典;row2 64B 小字典)
        if (dd == 65536) {
            @Assert(XXH32(dict, dd, 0u32) == 0x059edec2u32)
        } else {
            @Assert(XXH32(dict, dd, 0u32) == 0xabefcb46u32)
            @Assert(XXH64(dict, dd, 0u64) == 0x50e87bc3e640f412u64)
        }
        var prefs = LZ4F_preferences_t()
        prefs.compressionLevel = lv
        prefs.frameInfo.blockMode = bm
        let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
        let dst = Array<UInt8>(dstCap, {_ => 0u8})
        let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
        var pos: Int64 = 0
        let rb = LZ4F_compressBegin_usingDict(cctx, dst, pos, dstCap - pos, dict, dd, Some(prefs))
        @Assert(!LZ4F_isError(rb))
        pos += rb
        let ru = LZ4F_compressUpdate(cctx, dst, pos, dstCap - pos, input, 0, n,
            Option<LZ4F_compressOptions_t>.None)
        @Assert(!LZ4F_isError(ru))
        pos += ru
        let re = LZ4F_compressEnd(cctx, dst, pos, dstCap - pos,
            Option<LZ4F_compressOptions_t>.None)
        @Assert(!LZ4F_isError(re))
        pos += re
        if (pos != wantSize) {
            println("FDT row ${fileRow}: got ${pos} want ${wantSize}")
        }
        @Assert(pos == wantSize)
        @Assert(pos <= dstCap)
        let got32 = XXH32(dst, pos, 0u32)
        let got64 = XXH64(dst, pos, 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST row ${fileRow}: got ${got32}/${got64} want ${want32}/${want64}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        // row 2 quirk 旁证:同参数无字典帧 == usingDict 帧,逐字节
        // (bm=1 时字典被逐块 reset 整体丢弃;C 探针 2026-10-02:
        // noDict 帧摘要即 ebe5524b,与 fdt 行 golden 值相同)
        if (fileRow == 474) {
            let ndst = Array<UInt8>(dstCap, {_ => 0u8})
            let ncctx = LZ4F_createCompressionContext(LZ4F_VERSION)
            var npos: Int64 = 0
            npos += LZ4F_compressBegin(ncctx, ndst, npos, dstCap - npos, Some(prefs))
            npos += LZ4F_compressUpdate(ncctx, ndst, npos, dstCap - npos, input, 0, n,
                Option<LZ4F_compressOptions_t>.None)
            npos += LZ4F_compressEnd(ncctx, ndst, npos, dstCap - npos,
                Option<LZ4F_compressOptions_t>.None)
            if (npos != pos) {
                println("FDT-DROP row ${fileRow}: noDict ${npos} vs usingDict ${pos}")
            }
            @Assert(npos == pos)
            var eqAll = true
            for (k in 0..pos) {
                if (dst[k] != ndst[k]) {
                    eqAll = false
                }
            }
            if (!eqAll) {
                println("FDT-DROP row ${fileRow}: noDict frame differs from usingDict frame")
            }
            @Assert(eqAll)
        }
        match (lz4fReadArtifact(fileRow)) {
            case Some(art) =>
                @Assert(Int64(art.size) == pos)
                var eq = true
                for (k in 0..pos) {
                    if (UInt8(art[k]) != dst[k]) {
                        eq = false
                    }
                }
                if (!eq) {
                    println("BYTES row ${fileRow}: artifact mismatch")
                }
                @Assert(eq)
                fileCompared += 1
            case None => println("fdt row ${fileRow}: artifact missing, byte-compare skipped")
        }
        checked += 1
    }
    @Assert(checked == 2)
    @Assert(fileCompared == 2 || fileCompared == 0)
    println("fdt golden: ${checked}/2 rows, ${fileCompared} byte-exact artifacts")
}

/*-************************************
*  M5 Task 4: CDict clamp + pre-digestion unit pins
**************************************/
// >64KB 字典截尾拷贝 + 预消化等价:Begin_usingCDict 流的首块输出 ==
// 直接 loadDict/loadDictSlow/loadDictHC 新流的首块输出(C 探针
// 2026-10-02:双 regime(独立输入/字典自身前缀)× lv{0,9} 四组合全部
// 逐字节相等,block=16384 > 4096 走整态拷贝路径;loadDict 与
// loadDictSlow 两填充在此几何下输出亦互等 —— 双重断言钉住)。
@Test
func lz4fCDictUnitTest(): Unit {
    // ---- >64KB 截尾:131072B 字典 → dictContent 恰 65536B == 源尾段
    let big: Int64 = 131072
    let bigDict = Array<UInt8>(big, {_ => 0u8})
    RDG_genBuffer(bigDict, big, 0.50, 0.0, 123u32)
    let cdBig = LZ4F_createCDict(bigDict, big)
    @Assert(Int64(cdBig.dictContent.size) == 65536)
    var tailEq = true
    for (k in 0..65536) {
        if (cdBig.dictContent[k] != bigDict[65536 + k]) {
            tailEq = false
        }
    }
    @Assert(tailEq)
    LZ4F_freeCDict(cdBig)
    // ---- 预消化:64KB 字典 + 16KB 块,fast(lv=0)/ HC(lv=9)
    let dd: Int64 = 65536
    let dict = Array<UInt8>(dd, {_ => 0u8})
    RDG_genBuffer(dict, dd, 0.50, 0.0, 99u32)
    let cdict = LZ4F_createCDict(dict, dd)
    @Assert(Int64(cdict.dictContent.size) == 65536)
    let blocks: Array<(Int64, UInt32)> = [(16384, 5u32), (16384, 99u32)]   // 独立 / 字典前缀
    for ((bn, bseed) in blocks) {
        let block = Array<UInt8>(bn, {_ => 0u8})
        RDG_genBuffer(block, bn, 0.50, 0.0, bseed)
        let lvSet: Array<Int32> = [0, 9]
        for (lv in lvSet) {
            // 左:Begin_usingCDict + Update + End 单块帧,块数据 = [11, size-4)
            var prefs = LZ4F_preferences_t()
            prefs.compressionLevel = lv
            let dstCap = LZ4F_compressFrameBound(bn, Some(prefs))
            let frame = Array<UInt8>(dstCap, {_ => 0u8})
            let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
            var pos: Int64 = 0
            pos += LZ4F_compressBegin_usingCDict(cctx, frame, pos, dstCap - pos,
                Some(cdict), Some(prefs))
            pos += LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, block, 0, bn,
                Option<LZ4F_compressOptions_t>.None)
            pos += LZ4F_compressEnd(cctx, frame, pos, dstCap - pos,
                Option<LZ4F_compressOptions_t>.None)
            let blkLen = pos - 15   // 7B 头 + 4B 块头 + 块 + 4B endmark
            @Assert(blkLen > 0)
            // 右:直接构造的新流(loadDict 族)压缩同一块
            let bound = Int64(LZ4_compressBound(Int32(bn)))
            let raw = Array<UInt8>(bound, {_ => 0u8})
            var cRaw: Int64 = -1
            if (lv == 0) {
                let st = LZ4_stream_t()
                LZ4_initStream(st)
                LZ4_loadDict(st, dict, Int32(dd))
                cRaw = Int64(LZ4_compress_fast_continue(st, block, 0, Int32(bn),
                    raw, Int32(bound), 1))
            } else {
                let st = LZ4_streamHC_t()
                LZ4_initStreamHC(st)
                LZ4_setCompressionLevel(st, LZ4HC_CLEVEL_DEFAULT)
                LZ4_loadDictHC(st, dict, Int32(dd))
                cRaw = Int64(LZ4_compress_HC_continue(st, block, 0, Int32(bn),
                    raw, Int32(bound)))
            }
            @Assert(cRaw > 0)
            if (cRaw != blkLen) {
                println("PREDIGEST lv=${lv} bseed=${bseed}: frame blk ${blkLen} vs direct ${cRaw}")
            }
            @Assert(cRaw == blkLen)
            var eq = true
            for (k in 0..blkLen) {
                if (frame[11 + k] != raw[k]) {
                    eq = false
                }
            }
            if (!eq) {
                println("PREDIGEST lv=${lv} bseed=${bseed}: bytes differ")
            }
            @Assert(eq)
            // fast 侧追加 loadDictSlow 对照(与 createCDict 同构造)
            if (lv == 0) {
                let st2 = LZ4_stream_t()
                LZ4_initStream(st2)
                LZ4_loadDictSlow(st2, dict, Int32(dd))
                let raw2 = Array<UInt8>(bound, {_ => 0u8})
                let c2 = Int64(LZ4_compress_fast_continue(st2, block, 0, Int32(bn),
                    raw2, Int32(bound), 1))
                @Assert(c2 == blkLen)
                var eq2 = true
                for (k in 0..blkLen) {
                    if (frame[11 + k] != raw2[k]) {
                        eq2 = false
                    }
                }
                @Assert(eq2)
            }
        }
    }
    LZ4F_freeCDict(cdict)
    println("lz4f CDict clamp + pre-digestion pins verified")
}

/*-************************************
*  M5 Task 4: compressFrame 四联变换等价(仓颉内自证)
**************************************/
// compressFrame(A, None) 的 prefs 变换(MEM_INIT-0 → optimalBSID →
// af=1 → 单块强制 bm=1 → options{ss=1})可反推为手工链 prefs
// {bm=independent, af=1} + stableSrc —— 两者必须逐字节一致(5MB
// 防-分配 hack 依赖的 af=1+ss=1 不变量由此钉住)。
@Test
func lz4fFrameEquivalenceTest(): Unit {
    // (n, mp, seed, lv, wantSize, want32)
    let cases: Array<(Int64, Float64, UInt32, Int32, Int64, UInt32)> = [
        (65536, 0.50, 0u32, 0, 36474, 0xc4aa94e0u32),    // A, None prefs
        (65536, 0.90, 7u32, 9, 5561, 0xc7e873b1u32),     // B, lv=9
    ]
    for ((n, mp, seed, lv, wantSize, want32) in cases) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        // 左:one-shot compressFrame
        var userPrefs = Option<LZ4F_preferences_t>.None
        if (lv != 0) {
            var p = LZ4F_preferences_t()
            p.compressionLevel = lv
            userPrefs = Some(p)
        }
        let dstCap = LZ4F_compressFrameBound(n, userPrefs)
        let dstA = Array<UInt8>(dstCap, {_ => 0u8})
        let ra = LZ4F_compressFrame(dstA, 0, dstCap, input, n, userPrefs)
        @Assert(!LZ4F_isError(ra))
        // 右:手工 Begin/Update/End(prefs{bm=1, af=1, lv} + options{ss=1})
        var prefs = LZ4F_preferences_t()
        prefs.compressionLevel = lv
        prefs.frameInfo.blockMode = LZ4F_blockIndependent
        prefs.autoFlush = 1u32
        var cOpt = LZ4F_compressOptions_t()
        cOpt.stableSrc = 1u32
        let dstB = Array<UInt8>(dstCap, {_ => 0u8})
        let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
        var pos: Int64 = 0
        pos += LZ4F_compressBegin(cctx, dstB, pos, dstCap - pos, Some(prefs))
        pos += LZ4F_compressUpdate(cctx, dstB, pos, dstCap - pos, input, 0, n, Some(cOpt))
        pos += LZ4F_compressEnd(cctx, dstB, pos, dstCap - pos, Some(cOpt))
        if (ra != pos || ra != wantSize) {
            println("EQUIV lv=${lv}: frame ${ra} manual ${pos} want ${wantSize}")
        }
        @Assert(ra == pos)
        @Assert(ra == wantSize)
        var eq = true
        for (k in 0..ra) {
            if (dstA[k] != dstB[k]) {
                eq = false
            }
        }
        @Assert(eq)
        @Assert(XXH32(dstA, ra, 0u32) == want32)
    }
    println("lz4f compressFrame/manual-chain equivalence pins verified")
}

/*-************************************
*  M5 Task 4: compressFrameBound guarantee over golden rows
**************************************/
// 对 f1s + frame 全部行参数,产物 size ≤ LZ4F_compressFrameBound
// (用户级 prefs;None 行代入最坏情形求界)。
@Test
func lz4fFrameBoundGuaranteeTest(): Unit {
    for ((n, mp, seed, usePrefs, lv, ccs, csz, did, wantSize, _, _, _) in F1S_GOLD_REF) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        var prefsOpt = Option<LZ4F_preferences_t>.None
        if (usePrefs != 0) {
            var p = LZ4F_preferences_t()
            p.compressionLevel = lv
            p.frameInfo.contentChecksumFlag = ccs
            p.frameInfo.contentSize = csz
            p.frameInfo.dictID = did
            prefsOpt = Some(p)
        }
        let bound = LZ4F_compressFrameBound(n, prefsOpt)
        if (wantSize > bound) {
            println("F1S BOUND row n=${n} lv=${lv}: ${wantSize} > ${bound}")
        }
        @Assert(wantSize <= bound)
    }
    for ((n, mp, seed, bs, bm, ccs, bcs, csz, did, lv, fav, af, _, _, wantSize, _, _, _) in FRAME_GOLD_REF) {
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        var prefs = LZ4F_preferences_t()
        prefs.frameInfo.blockSizeID = bs
        prefs.frameInfo.blockMode = bm
        prefs.frameInfo.contentChecksumFlag = ccs
        prefs.frameInfo.blockChecksumFlag = bcs
        prefs.frameInfo.contentSize = csz
        prefs.frameInfo.dictID = did
        prefs.compressionLevel = lv
        prefs.favorDecSpeed = UInt32(fav)
        prefs.autoFlush = UInt32(af)
        let bound = LZ4F_compressFrameBound(n, Some(prefs))
        if (wantSize > bound) {
            println("FRAME BOUND row n=${n} bs=${bs} lv=${lv}: ${wantSize} > ${bound}")
        }
        @Assert(wantSize <= bound)
    }
    println("lz4f frameBound guarantee verified over 8 f1s + 27 frame rows")
}

/*-************************************
*  M6 Task 1: dctx lifecycle + headerSize + decompressOptions
**************************************/
// 对应上游 lz4frame.c L1266-1276(dStage 枚举)、L1278-1299(dctx
// 结构)、L1317-1341(create/free)、L1354-1362(reset)与 L1471-1495
// (LZ4F_headerSize);期望值按 C 语义手算钉常量。

@Test
func lz4fDctxLifecycleTest(): Unit {
    // create: calloc 等价 —— 全字段默认值,dStage=dstage_getFrameHeader
    let dctx = LZ4F_createDecompressionContext(100u32)
    @Assert(dctx.dStage == dstage_getFrameHeader)
    @Assert(dctx.version == 100u32)
    let def = LZ4F_frameInfo_t()
    @Assert(dctx.frameInfo.blockSizeID == def.blockSizeID)
    @Assert(dctx.frameInfo.blockMode == def.blockMode)
    @Assert(dctx.frameInfo.contentChecksumFlag == def.contentChecksumFlag)
    @Assert(dctx.frameInfo.frameType == def.frameType)
    @Assert(dctx.frameInfo.contentSize == def.contentSize)
    @Assert(dctx.frameInfo.dictID == def.dictID)
    @Assert(dctx.frameInfo.blockChecksumFlag == def.blockChecksumFlag)
    @Assert(dctx.tmpIn.size == 0)
    @Assert(dctx.tmpOutBuffer.size == 0)
    @Assert(dctx.dictBuf.size == 0)
    @Assert(!dctx.dictInTmp)
    @Assert(dctx.skipChecksum == 0)
    @Assert(dctx.header.size == LZ4F_HEADER_SIZE_MAX)
    // free: 返回释放时的 dStage(新鲜上下文 = 0,L1336-1341)
    @Assert(LZ4F_freeDecompressionContext(dctx) == 0)
    // free 于非零 dStage 释放 → 返回该状态(C 语义钉住)
    let d3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    d3.dStage = dstage_storeSuffix
    @Assert(LZ4F_freeDecompressionContext(d3) == 11)
    // reset: 手工置乱复位域字段后复位(L1354-1362 五字段 + dictInTmp)
    let d2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    d2.dStage = dstage_getCBlock
    d2.dictBuf = Array<UInt8>(8, {_ => 0x5Au8})
    d2.dictInTmp = true
    d2.dictSize = 8
    d2.skipChecksum = 1
    d2.frameRemainingSize = 12345u64
    LZ4F_resetDecompressionContext(d2)
    @Assert(d2.dStage == dstage_getFrameHeader)
    @Assert(d2.dictBuf.size == 0)
    @Assert(!d2.dictInTmp)
    @Assert(d2.dictSize == 0)
    @Assert(d2.skipChecksum == 0)
    @Assert(d2.frameRemainingSize == 0u64)
    println("lz4f dctx lifecycle pins verified")
}

// 构造帧起 8 字节:4B 魔数(LE)+ FLG + 填充(headerSize 只读前 5 字节)
private func lz4fMkHeader(magicLE: Array<UInt8>, flg: UInt8): Array<UInt8> {
    let h = Array<UInt8>(8, {_ => 0u8})
    h[0] = magicLE[0]
    h[1] = magicLE[1]
    h[2] = magicLE[2]
    h[3] = magicLE[3]
    h[4] = flg
    return h
}

@Test
func lz4fHeaderSizeTest(): Unit {
    let magic = [0x04u8, 0x22u8, 0x4Du8, 0x18u8]      // LZ4F_MAGICNUMBER LE
    // FLG 位:bit3=contentSize(+8)、bit0=dictID(+4),基址 minFHSize=7
    @Assert(LZ4F_headerSize(lz4fMkHeader(magic, 0x60u8), 0, 8) == 7)
    @Assert(LZ4F_headerSize(lz4fMkHeader(magic, 0x68u8), 0, 8) == 15)   // csz
    @Assert(LZ4F_headerSize(lz4fMkHeader(magic, 0x61u8), 0, 8) == 11)   // did
    @Assert(LZ4F_headerSize(lz4fMkHeader(magic, 0x69u8), 0, 8) == 19)   // csz+did
    // skippable 魔数 0x184D2A50-5F:头长恒 8,后 4 字节任意
    let skip50 = [0x50u8, 0x2Au8, 0x4Du8, 0x18u8]
    let skip5F = [0x5Fu8, 0x2Au8, 0x4Du8, 0x18u8]
    @Assert(LZ4F_headerSize(lz4fMkHeader(skip50, 0xFFu8), 0, 8) == 8)
    @Assert(LZ4F_headerSize(lz4fMkHeader(skip5F, 0x00u8), 0, 8) == 8)
    // 坏魔数 0x184D2205 → -13(frameType_unknown)且 isError
    let bad = LZ4F_headerSize(lz4fMkHeader([0x05u8, 0x22u8, 0x4Du8, 0x18u8], 0x60u8), 0, 8)
    @Assert(bad == -13)
    @Assert(LZ4F_isError(bad))
    // srcSize < 5 → -12(frameHeader_incomplete)
    @Assert(LZ4F_headerSize(lz4fMkHeader(magic, 0x60u8), 0, 4) == -12)
    // srcIdx 偏移读:帧起于缓冲中部(FLG=0x68 → 15)
    let buf = Array<UInt8>(12, {_ => 0xEEu8})
    buf[3] = 0x04u8
    buf[4] = 0x22u8
    buf[5] = 0x4Du8
    buf[6] = 0x18u8
    buf[7] = 0x68u8
    @Assert(LZ4F_headerSize(buf, 3, 9) == 15)
    println("lz4f headerSize pins verified")
}

@Test
func lz4fDecompressOptionsTest(): Unit {
    // 默认构造全 0(lz4frame.h L370-377)
    let o = LZ4F_decompressOptions_t()
    @Assert(o.stableDst == 0u32)
    @Assert(o.skipChecksums == 0u32)
    // 值语义:struct 拷贝后互不影响
    var a = LZ4F_decompressOptions_t()
    a.stableDst = 1u32
    a.skipChecksums = 1u32
    var c = a
    c.stableDst = 0u32
    c.skipChecksums = 0u32
    @Assert(a.stableDst == 1u32)
    @Assert(a.skipChecksums == 1u32)
    println("lz4f decompressOptions defaults/copy pins verified")
}
