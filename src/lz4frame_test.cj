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

/*-************************************
*  M6 Task 2: 解压状态机 + getFrameInfo + decompress 公开族 (L2/L3)
**************************************/
// 对应上游 lz4frame.c L1373-1464(decodeHeader)、L1512-1551(getFrameInfo)、
// L1558-1623(updateDict)、L1644-2147(decompress 状态机 + 尾部历史保存)、
// L2154-2167(decompress_usingDict)。期望值钉 C 语义常量(错误契约三元组、
// hint 序列、fdt/frhdr/frame golden 行)。

// 小工具:按 prefs 一次性成帧(compressFrame 变换按上游,单块强制
// independent/af=1 与本测试无关紧要,解压侧只读帧字节)
private func lz4fMkFrame(prefs: LZ4F_preferences_t, input: Array<UInt8>, n: Int64): (Array<UInt8>, Int64) {
    let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
    let dst = Array<UInt8>(dstCap, {_ => 0u8})
    let r = LZ4F_compressFrame(dst, 0, dstCap, input, n, Some(prefs))
    return (dst, r)
}

@Test
func lz4fRoundTripMatrixTest(): Unit {
    // L2:A 输入 × {bs 4/5/6/7 × bm 0/1 × ccs 0/1 × bcs 0/1 × csz{0,n} × af 0/1}
    // = 128 组;单次 LZ4F_decompress(dst 容量 n)→ (0, size, n) + 输出==输入
    // (compressFrame 的 prefs 变换会折叠 bs/bm/af,矩阵维度按 brief 保留迭代)
    let n: Int64 = 65536
    let input = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(input, n, 0.50, 0.0, 0u32)
    @Assert(XXH32(input, n, 0u32) == 0xc20f7bccu32)      // A=RDG(65536,0.50,0) C manifest 钉值
    // XXH32 offset 重载等价性:offset=1 的 n-1 字节 == 尾 n-1 字节切片
    let shifted = Array<UInt8>(n - 1, {i => input[i + 1]})
    @Assert(XXH32(input, n - 1, 0u32, offset: 1) == XXH32(shifted, n - 1, 0u32))
    var combos = 0
    let bsIDs: Array<Int32> = [4, 5, 6, 7]
    let bmodes: Array<Int32> = [0, 1]
    let ccss: Array<Int32> = [0, 1]
    let bcss: Array<Int32> = [0, 1]
    let cszs: Array<Int64> = [0, 65536]
    let afs: Array<Int32> = [0, 1]
    for (bs in bsIDs) {
        for (bm in bmodes) {
            for (ccs in ccss) {
                for (bcs in bcss) {
                    for (csz in cszs) {
                        for (af in afs) {
                            var prefs = LZ4F_preferences_t()
                            prefs.frameInfo.blockSizeID = bs
                            prefs.frameInfo.blockMode = bm
                            prefs.frameInfo.contentChecksumFlag = ccs
                            prefs.frameInfo.blockChecksumFlag = bcs
                            prefs.frameInfo.contentSize = UInt64(csz)
                            prefs.autoFlush = UInt32(af)
                            let (frame, size) = lz4fMkFrame(prefs, input, n)
                            @Assert(!LZ4F_isError(size))
                            let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
                            let out = Array<UInt8>(n, {_ => 0u8})
                            let (ret, consumed, written) = LZ4F_decompress(dctx, out, 0, n,
                                frame, 0, size, Option<LZ4F_decompressOptions_t>.None)
                            if (ret != 0 || consumed != size || written != n) {
                                println("RT bs=${bs} bm=${bm} ccs=${ccs} bcs=${bcs} csz=${csz} af=${af}: (${ret},${consumed},${written}) size=${size}")
                            }
                            @Assert(ret == 0)
                            @Assert(consumed == size)
                            @Assert(written == n)
                            var eq = true
                            for (k in 0..n) {
                                if (out[k] != input[k]) {
                                    eq = false
                                }
                            }
                            if (!eq) {
                                println("RT bs=${bs} bm=${bm} ccs=${ccs} bcs=${bcs} csz=${csz} af=${af}: output mismatch")
                            }
                            @Assert(eq)
                            @Assert(XXH32(out, n, 0u32) == 0xc20f7bccu32)
                            if (csz == n) {
                                // csz 组:解码侧 frameInfo.contentSize == n(getFrameInfo 三岔之 header 解码岔)
                                let dctx2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
                                let (code, fi, used) = LZ4F_getFrameInfo(dctx2, frame, 0, size)
                                @Assert(code == 4)      // BHSize hint
                                @Assert(used == 15)     // 7 + 8(csz 头)
                                @Assert(fi.contentSize == UInt64(n))
                            }
                            combos += 1
                        }
                    }
                }
            }
        }
    }
    @Assert(combos == 128)
    println("lz4f roundtrip matrix: ${combos}/128 combos decoded byte-exact")
}

@Test
func lz4fDecodeGoldenTest(): Unit {
    // L3 双向:27 行 golden 帧仓颉重建 → 整段解压 → 输出 XXH32 == 行内钉值
    // inxxh;artifact 存在时解 C 产物字节 == 仓颉输入(双向闭合)。
    var checked = 0
    var fileDecoded = 0
    for (row in FRAME_GOLD_REF) {
        let (n, mp, seed, bs, bm, ccs, bcs, csz, did, lv, fav, af, ss, scen, wantSize, want32, want64, fileRow) = row
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
        let frame = Array<UInt8>(dstCap, {_ => 0u8})
        var pos: Int64 = 0
        var r = LZ4F_compressBegin(cctx, frame, pos, dstCap - pos, Some(prefs))
        @Assert(!LZ4F_isError(r))
        pos += r
        var cOpt = Option<LZ4F_compressOptions_t>.None
        if (ss != 0) {
            var o = LZ4F_compressOptions_t()
            o.stableSrc = 1u32
            cOpt = Some(o)
        }
        if (scen == 0) {
            r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, n, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
        } else if (scen == 1) {
            r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, 50000, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_flush(cctx, frame, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 50000, n - 50000, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
        } else if (scen == 2) {
            r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, 65536, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_uncompressedUpdate(cctx, frame, pos, dstCap - pos, input, 65536, 32768, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 98304, 32768, cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
        } else {
            let chunkSizes: Array<Int64> = [26214, 26214, 26214, 26215, 26215]
            var off: Int64 = 0
            for (k in 0..5) {
                r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, off, chunkSizes[k], cOpt)
                @Assert(!LZ4F_isError(r))
                pos += r
                off += chunkSizes[k]
            }
        }
        r = LZ4F_compressEnd(cctx, frame, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
        @Assert(!LZ4F_isError(r))
        pos += r
        @Assert(pos == wantSize)
        // 输入出处钉值(同 lz4fFrameGoldenTest)
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
        // 仓颉重建帧整段解压:末次 ret==0、Σconsumed==size、Σwritten==n
        let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
        let out = Array<UInt8>(n, {_ => 0u8})
        let (ret, consumed, written) = LZ4F_decompress(dctx, out, 0, n, frame, 0, pos,
            Option<LZ4F_decompressOptions_t>.None)
        if (ret != 0 || consumed != pos || written != n) {
            println("DECODE row ${fileRow}: (${ret},${consumed},${written}) size=${pos}")
        }
        @Assert(ret == 0)
        @Assert(consumed == pos)
        @Assert(written == n)
        if (XXH32(out, n, 0u32) != wantIn32) {
            println("OUTXXH row ${fileRow}: ${XXH32(out, n, 0u32)} want ${wantIn32}")
        }
        @Assert(XXH32(out, n, 0u32) == wantIn32)
        var eq = true
        for (k in 0..n) {
            if (out[k] != input[k]) {
                eq = false
            }
        }
        if (!eq) {
            println("BYTES row ${fileRow}: decoded != input")
        }
        @Assert(eq)
        // 双向闭合:解 C 产物 artifact 字节 → 输出 == 仓颉输入
        match (lz4fReadArtifact(fileRow)) {
            case Some(art) =>
                @Assert(Int64(art.size) == pos)
                let dctx2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
                let out2 = Array<UInt8>(n, {_ => 0u8})
                let (ret2, consumed2, written2) = LZ4F_decompress(dctx2, out2, 0, n,
                    art, 0, Int64(art.size), Option<LZ4F_decompressOptions_t>.None)
                if (ret2 != 0 || consumed2 != Int64(art.size) || written2 != n) {
                    println("ART row ${fileRow}: (${ret2},${consumed2},${written2})")
                }
                @Assert(ret2 == 0)
                @Assert(consumed2 == Int64(art.size))
                @Assert(written2 == n)
                @Assert(XXH32(out2, n, 0u32) == wantIn32)
                var eq2 = true
                for (k in 0..n) {
                    if (out2[k] != input[k]) {
                        eq2 = false
                    }
                }
                if (!eq2) {
                    println("ARTBYTES row ${fileRow}: C-artifact decode != cangjie input")
                }
                @Assert(eq2)
                fileDecoded += 1
            case None => println("frame row ${fileRow}: artifact missing, C-bytes decode skipped")
        }
        checked += 1
    }
    @Assert(checked == 27)
    @Assert(fileDecoded == 27 || fileDecoded == 0)   // corpus policy: all-or-nothing
    println("frame decode golden: ${checked}/27 rows, ${fileDecoded} C-artifact double-direction decodes")
}

@Test
func lz4fGetFrameInfoTest(): Unit {
    // 岔一:fresh dctx + 完整默认头(7B)→ (4=BHSize, fi 全钉, consumed=7)
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    let hbuf = Array<UInt8>(19, {_ => 0u8})
    let hb = LZ4F_compressBegin(cctx, hbuf, 0, 19, Option<LZ4F_preferences_t>.None)
    @Assert(hb == 7)     // frhdr row 426 几何:FLG=0x40 BD=0x40
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (code, fi, used) = LZ4F_getFrameInfo(dctx, hbuf, 0, hb)
    @Assert(code == 4)
    @Assert(used == 7)
    @Assert(fi.blockSizeID == 4)
    @Assert(fi.blockMode == 0)
    @Assert(fi.contentChecksumFlag == 0)
    @Assert(fi.blockChecksumFlag == 0)
    @Assert(fi.contentSize == 0u64)
    @Assert(fi.dictID == 0u32)
    @Assert(fi.frameType == LZ4F_frame)
    @Assert(dctx.dStage == dstage_init)   // decodeHeader 副作用
    // csz+did 头(19B,frhdr row 429 几何)→ (4, …csz/did…, 19)
    let cctx2 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var p2 = LZ4F_preferences_t()
    p2.frameInfo.contentSize = 65536u64
    p2.frameInfo.dictID = 305419896u32
    let hbuf2 = Array<UInt8>(19, {_ => 0u8})
    @Assert(LZ4F_compressBegin(cctx2, hbuf2, 0, 19, Some(p2)) == 19)
    let dctx2b = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (code2, fi2, used2) = LZ4F_getFrameInfo(dctx2b, hbuf2, 0, 19)
    @Assert(code2 == 4)
    @Assert(used2 == 19)
    @Assert(fi2.contentSize == 65536u64)
    @Assert(fi2.dictID == 305419896u32)
    @Assert(fi2.blockSizeID == 4)
    // 岔二:解压半帧(dStage>storeFrameHeader)后 → consumed=0、fi 相同、hint=4
    let dctx3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let dst = Array<UInt8>(256, {_ => 0u8})
    let (r3, c3, w3) = LZ4F_decompress(dctx3, dst, 0, 256, hbuf, 0, 7,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(r3 == 4 && c3 == 7 && w3 == 0)   // 头吃尽 → storeBlockHeader hint=4
    @Assert(dctx3.dStage > dstage_storeFrameHeader)
    let empty = Array<UInt8>(0, {_ => 0u8})
    let (code3, fi3, used3) = LZ4F_getFrameInfo(dctx3, empty, 0, 0)
    @Assert(code3 == 4)
    @Assert(used3 == 0)
    @Assert(fi3.blockSizeID == fi.blockSizeID)
    @Assert(fi3.blockMode == fi.blockMode)
    @Assert(fi3.contentChecksumFlag == fi.contentChecksumFlag)
    @Assert(fi3.blockChecksumFlag == fi.blockChecksumFlag)
    @Assert(fi3.contentSize == fi.contentSize)
    @Assert(fi3.dictID == fi.dictID)
    @Assert(fi3.frameType == fi.frameType)
    // 岔三:首调 decompress 仅 6B(storeFrameHeader 中途)→ -19
    let dctx4 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r4, _, _) = LZ4F_decompress(dctx4, dst, 0, 256, hbuf, 0, 6,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(r4 == 5)      // (7-6)+4:剩余头 1 + 下一块头 4
    @Assert(dctx4.dStage == dstage_storeFrameHeader)
    let (code4, _, used4) = LZ4F_getFrameInfo(dctx4, empty, 0, 0)
    @Assert(code4 == -LZ4F_ERROR_frameDecoding_alreadyStarted)
    @Assert(used4 == 0)
    // srcSize=6 < hSize=7 → -12(headerSize 成功后长度不足岔)
    let dctx5 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (code5, _, used5) = LZ4F_getFrameInfo(dctx5, hbuf, 0, 6)
    @Assert(code5 == -LZ4F_ERROR_frameHeader_incomplete)
    @Assert(used5 == 0)
    // skippable 头:consumed=4、frameType==skippableFrame
    let skipHdr = Array<UInt8>(8, {_ => 0u8})
    skipHdr[0] = 0x50u8
    skipHdr[1] = 0x2Au8
    skipHdr[2] = 0x4Du8
    skipHdr[3] = 0x18u8
    let dctx6 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (code6, fi6, used6) = LZ4F_getFrameInfo(dctx6, skipHdr, 0, 8)
    @Assert(code6 == 4)
    @Assert(used6 == 4)
    @Assert(fi6.frameType == LZ4F_skippableFrame)
    @Assert(fi6.contentSize == 0u64 && fi6.blockSizeID == 0 && fi6.dictID == 0u32)
    @Assert(dctx6.dStage == dstage_getSFrameSize)
    println("lz4f getFrameInfo three-branch pins verified")
}

@Test
func lz4fDecodeErrorContractTest(): Unit {
    // 错误契约:C 入口即置 *srcSizePtr=0;*dstSizePtr=0,RETURN_ERROR 直返
    // → 每例断言三元组 (code, 0, 0)(含已部分消费/写出的调用)。
    // 错误后 dctx 上游不担保复用(C 契约同),不测续用。
    let n: Int64 = 65536
    let input = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(input, n, 0.50, 0.0, 0u32)
    let dst = Array<UInt8>(n, {_ => 0u8})
    // 手工 19B 坏头(≥ maxFHSize 走 decodeHeader 捷径路径)
    let badHdr = Array<UInt8>(19, {_ => 0u8})
    badHdr[0] = 0x04u8; badHdr[1] = 0x22u8; badHdr[2] = 0x4Du8; badHdr[3] = 0x18u8
    // 坏魔数 → -13
    let h1 = Array<UInt8>(19, {i => badHdr[i]})
    h1[3] = 0x05u8
    h1[4] = 0x60u8; h1[5] = 0x40u8
    let d1 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e1, ec1, ew1) = LZ4F_decompress(d1, dst, 0, n, h1, 0, 19, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e1 == -LZ4F_ERROR_frameType_unknown)
    @Assert(ec1 == 0 && ew1 == 0)
    // FLG version=2(0x80)→ -6
    let h2 = Array<UInt8>(19, {i => badHdr[i]})
    h2[4] = 0x80u8; h2[5] = 0x40u8
    let d2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e2, ec2, ew2) = LZ4F_decompress(d2, dst, 0, n, h2, 0, 19, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e2 == -LZ4F_ERROR_headerVersion_wrong)
    @Assert(ec2 == 0 && ew2 == 0)
    // FLG 保留位(0x62 bit1)→ -8
    let h3 = Array<UInt8>(19, {i => badHdr[i]})
    h3[4] = 0x62u8; h3[5] = 0x40u8
    let d3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e3, ec3, ew3) = LZ4F_decompress(d3, dst, 0, n, h3, 0, 19, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e3 == -LZ4F_ERROR_reservedFlag_set)
    @Assert(ec3 == 0 && ew3 == 0)
    // BD bsID=3(0x30)→ -2
    let h4 = Array<UInt8>(19, {i => badHdr[i]})
    h4[4] = 0x60u8; h4[5] = 0x30u8
    let d4 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e4, ec4, ew4) = LZ4F_decompress(d4, dst, 0, n, h4, 0, 19, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e4 == -LZ4F_ERROR_maxBlockSize_invalid)
    @Assert(ec4 == 0 && ew4 == 0)
    // 坏 HC 字节 → -17(合法头翻转 HC)
    let h5 = Array<UInt8>(19, {i => badHdr[i]})
    h5[4] = 0x60u8; h5[5] = 0x40u8
    let flgbd = Array<UInt8>(2, {_ => 0u8})
    flgbd[0] = 0x60u8
    flgbd[1] = 0x40u8
    h5[6] = lz4fHeaderChecksum(flgbd, 2) ^ 0xFFu8
    let d5 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e5, ec5, ew5) = LZ4F_decompress(d5, dst, 0, n, h5, 0, 19, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e5 == -LZ4F_ERROR_headerChecksum_invalid)
    @Assert(ec5 == 0 && ew5 == 0)
    // 压缩块内篡改 1 字节(保长度)→ -16。篡改点选块首 token 字节
    // (探针钉值:该帧中部/尾部字面量字节翻转仍可解析,token 必 -16)
    var p0 = LZ4F_preferences_t()
    let (f6, s6) = lz4fMkFrame(p0, input, n)
    @Assert(!LZ4F_isError(s6))
    let f6b = Array<UInt8>(s6, {i => f6[i]})
    f6b[11] = f6b[11] ^ 0xFFu8    // 7 头 + 4 块头 = 压缩块首字节
    let d6 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e6, ec6, ew6) = LZ4F_decompress(d6, dst, 0, n, f6b, 0, s6, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e6 == -LZ4F_ERROR_decompressionFailed)
    @Assert(ec6 == 0 && ew6 == 0)
    // 篡改块校验和尾 4B → -7
    var p7 = LZ4F_preferences_t()
    p7.frameInfo.blockChecksumFlag = 1
    let (f7, s7) = lz4fMkFrame(p7, input, n)
    @Assert(!LZ4F_isError(s7))
    let csize7 = Int64(lz4fReadLE32(f7, 7) & 0x7FFFFFFFu32)
    let f7b = Array<UInt8>(s7, {i => f7[i]})
    f7b[11 + csize7] = f7b[11 + csize7] ^ 0xFFu8    // 块校验和首字节
    let d7 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e7, ec7, ew7) = LZ4F_decompress(d7, dst, 0, n, f7b, 0, s7, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e7 == -LZ4F_ERROR_blockChecksum_invalid)
    @Assert(ec7 == 0 && ew7 == 0)
    // 篡改内容校验和尾 4B → -18
    var p8 = LZ4F_preferences_t()
    p8.frameInfo.contentChecksumFlag = 1
    let (f8, s8) = lz4fMkFrame(p8, input, n)
    @Assert(!LZ4F_isError(s8))
    let f8b = Array<UInt8>(s8, {i => f8[i]})
    f8b[s8 - 1] = f8b[s8 - 1] ^ 0xFFu8
    let d8 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e8, ec8, ew8) = LZ4F_decompress(d8, dst, 0, n, f8b, 0, s8, Option<LZ4F_decompressOptions_t>.None)
    @Assert(e8 == -LZ4F_ERROR_contentChecksum_invalid)
    @Assert(ec8 == 0 && ew8 == 0)
    // csz 帧实际内容不符 → -14(csz=n+1 头 + 无 csz 帧主体)
    let cctx9 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var p9 = LZ4F_preferences_t()
    p9.frameInfo.contentSize = UInt64(n + 1)
    let hdr9 = Array<UInt8>(19, {_ => 0u8})
    @Assert(LZ4F_compressBegin(cctx9, hdr9, 0, 19, Some(p9)) == 15)   // Begin 不校验 csz
    var p9b = LZ4F_preferences_t()
    let (f9, s9) = lz4fMkFrame(p9b, input, n)   // csz=0 主体(块结构与 csz 无关)
    @Assert(!LZ4F_isError(s9))
    let f9b = Array<UInt8>(15 + s9 - 7, {_ => 0u8})
    for (i in 0..15) {
        f9b[i] = hdr9[i]
    }
    for (i in 7..s9) {
        f9b[8 + i] = f9[i]    // 15 - 7 = 8 偏移
    }
    let d9 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (e9, ec9, ew9) = LZ4F_decompress(d9, dst, 0, n, f9b, 0, Int64(f9b.size), Option<LZ4F_decompressOptions_t>.None)
    @Assert(e9 == -LZ4F_ERROR_frameSize_wrong)
    @Assert(ec9 == 0 && ew9 == 0)
    println("lz4f decode error contract: 9 triples pinned (code, 0, 0)")
}

@Test
func lz4fDecompressStateTest(): Unit {
    // ① 0 字节首调用 → (7,0,0) 且 dStage 不变(保真点②:L1686-1687 先于 storeFrameHeader)
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let empty = Array<UInt8>(0, {_ => 0u8})
    let dst = Array<UInt8>(256, {_ => 0u8})
    let (r0, c0, w0) = LZ4F_decompress(dctx, dst, 0, 256, empty, 0, 0,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(r0 == 7)
    @Assert(c0 == 0 && w0 == 0)
    @Assert(dctx.dStage == dstage_getFrameHeader)
    // ② 7B 头调用 → consumed=7、hint≥4、dStage≥3
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    let hbuf = Array<UInt8>(19, {_ => 0u8})
    let hb = LZ4F_compressBegin(cctx, hbuf, 0, 19, Option<LZ4F_preferences_t>.None)
    @Assert(hb == 7)
    let (r1, c1, w1) = LZ4F_decompress(dctx, dst, 0, 256, hbuf, 0, 7,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(r1 >= 4)
    @Assert(c1 == 7)
    @Assert(w1 == 0)
    @Assert(dctx.dStage >= dstage_getBlockHeader)
    // ③ ccs 帧解码后 xxh digest 状态 == 输入 XXH32(reset 不清 xxh)
    let n: Int64 = 65536
    let input = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(input, n, 0.50, 0.0, 0u32)
    var pc = LZ4F_preferences_t()
    pc.frameInfo.contentChecksumFlag = 1
    let (fc, sc) = lz4fMkFrame(pc, input, n)
    @Assert(!LZ4F_isError(sc))
    let dctx2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out = Array<UInt8>(n, {_ => 0u8})
    let (rc, cc2, wc) = LZ4F_decompress(dctx2, out, 0, n, fc, 0, sc,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(rc == 0 && cc2 == sc && wc == n)
    @Assert(XXH32_digest(dctx2.xxh) == 0xc20f7bccu32)
    // ④ 完整帧后 dStage==0(自动 reset)→ 同 dctx 续解第二帧(保真点⑰)
    let nd: Int64 = 255
    let dIn = Array<UInt8>(nd, {_ => 0u8})
    RDG_genBuffer(dIn, nd, 0.50, 0.0, 0u32)
    var pd = LZ4F_preferences_t()
    let (fd1, sd1) = lz4fMkFrame(pd, dIn, nd)
    let (fd2, sd2) = lz4fMkFrame(pd, dIn, nd)
    @Assert(!LZ4F_isError(sd1) && !LZ4F_isError(sd2))
    let cat = Array<UInt8>(sd1 + sd2, {_ => 0u8})
    for (i in 0..sd1) {
        cat[i] = fd1[i]
    }
    for (i in 0..sd2) {
        cat[sd1 + i] = fd2[i]
    }
    let dctx3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out3 = Array<UInt8>(nd, {_ => 0u8})
    let (ra, ca, wa) = LZ4F_decompress(dctx3, out3, 0, nd, cat, 0, sd1,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(ra == 0 && ca == sd1 && wa == nd)
    @Assert(dctx3.dStage == dstage_getFrameHeader)   // 自动 reset
    var eqa = true
    for (k in 0..nd) {
        if (out3[k] != dIn[k]) {
            eqa = false
        }
    }
    @Assert(eqa)
    let (rb2, cb2, wb2) = LZ4F_decompress(dctx3, out3, 0, nd, cat, sd1, sd2,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(rb2 == 0 && cb2 == sd2 && wb2 == nd)
    var eqb = true
    for (k in 0..nd) {
        if (out3[k] != dIn[k]) {
            eqb = false
        }
    }
    @Assert(eqb)
    // ⑤ 空输入帧(F)解压 → (0, 11, 0)(7 头 + 4 endmark)
    let emptyIn = Array<UInt8>(0, {_ => 0u8})
    let (fe, se) = lz4fMkFrame(LZ4F_preferences_t(), emptyIn, 0)
    @Assert(!LZ4F_isError(se))
    @Assert(se == 11)
    let dctx4 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out4 = Array<UInt8>(16, {_ => 0u8})
    let (re4, ce4, we4) = LZ4F_decompress(dctx4, out4, 0, 16, fe, 0, se,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(re4 == 0 && ce4 == 11 && we4 == 0)
    println("lz4f decompress state machine pins verified")
}

@Test
func lz4fUsingDictDecodeTest(): Unit {
    // fdt 行 1 几何:A dd=65536 dseed=99 lv=0 bm=0(linked)——仓颉
    // compressBegin_usingDict 成帧(38651 golden 已钉)→ usingDict 解压
    let n: Int64 = 65536
    let input = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(input, n, 0.50, 0.0, 0u32)
    @Assert(XXH32(input, n, 0u32) == 0xc20f7bccu32)
    let dict = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(dict, n, 0.50, 0.0, 99u32)
    @Assert(XXH32(dict, n, 0u32) == 0x059edec2u32)      // fdt golden 字典钉值
    var prefs = LZ4F_preferences_t()
    prefs.compressionLevel = 0
    prefs.frameInfo.blockMode = LZ4F_blockLinked
    let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
    let frame = Array<UInt8>(dstCap, {_ => 0u8})
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos: Int64 = 0
    pos += LZ4F_compressBegin_usingDict(cctx, frame, pos, dstCap - pos, dict, n, Some(prefs))
    pos += LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, n,
        Option<LZ4F_compressOptions_t>.None)
    pos += LZ4F_compressEnd(cctx, frame, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
    @Assert(pos == 38651)      // fdt row 473 golden
    // with-dict 解压:输出 == 输入
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out = Array<UInt8>(n, {_ => 0u8})
    let (ret, consumed, written) = LZ4F_decompress_usingDict(dctx, out, 0, n, frame, 0, pos,
        dict, n, Option<LZ4F_decompressOptions_t>.None)
    @Assert(ret == 0)
    @Assert(consumed == pos)
    @Assert(written == n)
    var eq = true
    for (k in 0..n) {
        if (out[k] != input[k]) {
            eq = false
        }
    }
    if (!eq) {
        println("DICT decode: output mismatch")
    }
    @Assert(eq)
    // no-dict 结果由 T3 fdmp 行钉值
    let dctx2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out2 = Array<UInt8>(n, {_ => 0u8})
    let (ret2, consumed2, written2) = LZ4F_decompress(dctx2, out2, 0, n, frame, 0, pos,
        Option<LZ4F_decompressOptions_t>.None)
    println("lz4f usingDict no-dict probe (T3 pins): ret=${ret2} consumed=${consumed2} written=${written2}")
    // dict 注入仅 dStage<=dstage_init:半帧后 usingDict 不改 dict(状态断言)
    let dctx3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let dst3 = Array<UInt8>(256, {_ => 0u8})
    let (r3, _, _) = LZ4F_decompress(dctx3, dst3, 0, 256, frame, 0, 7,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(r3 >= 4)
    @Assert(dctx3.dStage > dstage_init)
    let smallDict = Array<UInt8>(8, {_ => 0x77u8})
    let (_, _, _) = LZ4F_decompress_usingDict(dctx3, dst3, 0, 256, frame, 7, 0,
        smallDict, 8, Option<LZ4F_decompressOptions_t>.None)
    @Assert(dctx3.dictBuf.size == 0)
    @Assert(dctx3.dictIdx == 0)
    @Assert(dctx3.dictSize == 0)
    @Assert(!dctx3.dictInTmp)
    println("lz4f usingDict decode pins verified")
}

/*-************************************
*  M6 Task 3: 分片续传矩阵 + options + skippable/拼接 + fdmp golden
**************************************/
// 对应 golden 清单 mode=fdmp 14 行(corpus/block_golden_ref.txt 再生值嵌入,
// manifest 仅出处;C harness scripts/gen_golden.c fdmp 节 @ 0774d055)。
// out= 三元组 = consumed:written:hint;错误契约恒 (code, 0, 0)。

// 小工具:流式成帧(Begin + Update 整段 + End,raw prefs,无 compressFrame
// 变换)——fdmp/concat/stableDst 测试统一用它,C harness fdmpFrame 同构
private func lz4fFdmpFrame(prefs: LZ4F_preferences_t, input: Array<UInt8>, n: Int64): (Array<UInt8>, Int64) {
    let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
    let frame = Array<UInt8>(dstCap, {_ => 0u8})
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos: Int64 = 0
    pos += LZ4F_compressBegin(cctx, frame, pos, dstCap - pos, Some(prefs))
    pos += LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, n,
        Option<LZ4F_compressOptions_t>.None)
    pos += LZ4F_compressEnd(cctx, frame, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
    return (frame, pos)
}

// 本地 LCG(fuzzLcgNext 同式,文件私有不可跨文件 → 本节自带)
private func lz4fFdmpLcgNext(x: UInt64): UInt64 {
    return x * 6364136223846793005u64 + 1442695040888963407u64
}

@Test
func lz4fDecodeFdmpGoldenTest(): Unit {
    let noneOpt = Option<LZ4F_decompressOptions_t>.None
    let n: Int64 = 65536
    let A = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(A, n, 0.50, 0.0, 0u32)
    @Assert(XXH32(A, n, 0u32) == 0xc20f7bccu32)
    let nd: Int64 = 255
    let D = Array<UInt8>(nd, {_ => 0u8})
    RDG_genBuffer(D, nd, 0.50, 0.0, 0u32)
    // 行 1 sc=fi:A 默认帧,getFrameInfo(fresh, srcSize=19) → out=7:4
    var p1 = LZ4F_preferences_t()
    let (f1, _) = lz4fFdmpFrame(p1, A, n)
    let dc1 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (code1, fi1, used1) = LZ4F_getFrameInfo(dc1, f1, 0, 19)
    @Assert(used1 == 7)
    @Assert(code1 == 4)
    @Assert(fi1.blockSizeID == 4)
    @Assert(fi1.blockMode == 0)
    @Assert(fi1.contentChecksumFlag == 0)
    @Assert(fi1.blockChecksumFlag == 0)
    @Assert(fi1.frameType == LZ4F_frame)
    @Assert(fi1.contentSize == 0u64)
    @Assert(fi1.dictID == 0u32)
    // 行 2 sc=fi:A csz=65536 did=305419896 帧 → out=19:4
    var p2 = LZ4F_preferences_t()
    p2.frameInfo.contentSize = 65536u64
    p2.frameInfo.dictID = 305419896u32
    let (f2, _) = lz4fFdmpFrame(p2, A, n)
    let dc2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (code2, fi2, used2) = LZ4F_getFrameInfo(dc2, f2, 0, 19)
    @Assert(used2 == 19)
    @Assert(code2 == 4)
    @Assert(fi2.blockSizeID == 4)
    @Assert(fi2.contentSize == 65536u64)
    @Assert(fi2.dictID == 305419896u32)
    // 行 3 sc=fimid:A ccs=1 帧,先喂 size-4(头+块+endmark),再 getFrameInfo
    // → already-decoded 岔:pre=38688:65536:4、out=0:4
    var p3 = LZ4F_preferences_t()
    p3.frameInfo.contentChecksumFlag = 1
    let (f3, s3) = lz4fFdmpFrame(p3, A, n)
    @Assert(s3 == 38692)      // frame row 438 同几何
    let dc3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out3 = Array<UInt8>(n, {_ => 0u8})
    let (pr3, pc3, pw3) = LZ4F_decompress(dc3, out3, 0, n, f3, 0, s3 - 4, noneOpt)
    @Assert(pc3 == 38688)
    @Assert(pw3 == 65536)
    @Assert(pr3 == 4)
    let (g3, gi3, gu3) = LZ4F_getFrameInfo(dc3, f3, 0, 19)
    @Assert(gu3 == 0)
    @Assert(g3 == 4)
    @Assert(gi3.blockSizeID == 4)
    @Assert(gi3.contentChecksumFlag == 1)
    @Assert(gi3.frameType == LZ4F_frame)
    // 行 4 sc=fimid2:仅喂 6B(storeFrameHeader 中途)→ pre=6:0:5、code=-19
    var p4 = LZ4F_preferences_t()
    let (f4, _) = lz4fFdmpFrame(p4, A, n)
    let dc4 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let dst4 = Array<UInt8>(256, {_ => 0u8})
    let (pr4, pc4, pw4) = LZ4F_decompress(dc4, dst4, 0, 256, f4, 0, 6, noneOpt)
    @Assert(pc4 == 6)
    @Assert(pw4 == 0)
    @Assert(pr4 == 5)
    let (g4, _, gu4) = LZ4F_getFrameInfo(dc4, f4, 0, 19)
    @Assert(g4 == -LZ4F_ERROR_frameDecoding_alreadyStarted)
    @Assert(gu4 == 0)
    // 行 5 sc=fishort:srcSize=6 → -12;srcSize=4(headerSize MIN 先拒)→ -12
    let dc5a = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (g5a, _, gu5a) = LZ4F_getFrameInfo(dc5a, f4, 0, 6)
    @Assert(g5a == -LZ4F_ERROR_frameHeader_incomplete)
    @Assert(gu5a == 0)
    let dc5b = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (g5b, _, gu5b) = LZ4F_getFrameInfo(dc5b, f4, 0, 4)
    @Assert(g5b == -LZ4F_ERROR_frameHeader_incomplete)
    @Assert(gu5b == 0)
    // 行 6 sc=seq1:D ccs=1 bcs=1 bm=0 lv=0 帧,feed=[1,6,11,55,55,余] × cap 65536
    var p6 = LZ4F_preferences_t()
    p6.frameInfo.contentChecksumFlag = 1
    p6.frameInfo.blockChecksumFlag = 1
    p6.frameInfo.blockMode = LZ4F_blockLinked
    p6.compressionLevel = 0
    let (f6, s6) = lz4fFdmpFrame(p6, D, nd)
    @Assert(s6 == 261)      // 7 头 + 4 块头 + 238 块 + 4 块 CRC + 4 endmark + 4 内容 CRC
    let want6: Array<(Int64, Int64, Int64)> = [
        (1, 0, 10), (6, 0, 4), (11, 0, 243), (55, 0, 188), (55, 0, 133), (133, 255, 0)]
    let feeds6: Array<Int64> = [1, 6, 11, 55, 55]
    let dc6 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out6 = Array<UInt8>(nd, {_ => 0u8})
    var off6: Int64 = 0
    var w6: Int64 = 0
    for (k in 0..6) {
        let chunk6 = if (k < 5) { feeds6[k] } else { s6 - off6 }
        let (r6, c6, ww6) = LZ4F_decompress(dc6, out6, w6, nd - w6, f6, off6, chunk6, noneOpt)
        let (ec6, ew6, eh6) = want6[k]
        if (c6 != ec6 || ww6 != ew6 || r6 != eh6) {
            println("SEQ1 k=${k}: (${c6},${ww6},${r6}) want (${ec6},${ew6},${eh6})")
        }
        @Assert(c6 == ec6)
        @Assert(ww6 == ew6)
        @Assert(r6 == eh6)
        off6 += c6
        w6 += ww6
    }
    @Assert(off6 == s6)
    @Assert(w6 == nd)
    var eq6 = true
    for (k in 0..nd) {
        if (out6[k] != D[k]) {
            eq6 = false
        }
    }
    @Assert(eq6)
    // 行 7 sc=seq2:同帧几何,feed=[30,30,30,30,blk,余] × cap=[2,2,2,2,2,65536]
    // (cap5 保持 2 迫使压缩块在小 dst 下完成 → decode-into-tmp + flushOut
    //  部分 tmpOutStart + withinTmp updateDict + 尾部历史保存 flushOut 分支)
    let (f7, s7) = lz4fFdmpFrame(p6, D, nd)
    @Assert(s7 == 261)
    let csize7 = Int64(lz4fReadLE32(f7, 7) & 0x7FFFFFFFu32)
    @Assert(csize7 == 238)
    let blockEnd7 = 11 + csize7 + 4      // bcs=1:+4 块 CRC
    @Assert(blockEnd7 == 253)
    let want7: Array<(Int64, Int64, Int64)> = [
        (30, 0, 231), (30, 0, 201), (30, 0, 171), (30, 0, 141), (133, 2, 4), (8, 253, 0)]
    let dc7 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out7 = Array<UInt8>(nd, {_ => 0u8})
    var off7: Int64 = 0
    var w7: Int64 = 0
    for (k in 0..6) {
        let chunk7 = if (k < 4) { 30 } else if (k == 4) { blockEnd7 - off7 } else { s7 - off7 }
        let cap7 = if (k < 5) { 2 } else { nd - w7 }
        let (r7, c7, ww7) = LZ4F_decompress(dc7, out7, w7, cap7, f7, off7, chunk7, noneOpt)
        let (ec7, ew7, eh7) = want7[k]
        if (c7 != ec7 || ww7 != ew7 || r7 != eh7) {
            println("SEQ2 k=${k}: (${c7},${ww7},${r7}) want (${ec7},${ew7},${eh7})")
        }
        @Assert(c7 == ec7)
        @Assert(ww7 == ew7)
        @Assert(r7 == eh7)
        off7 += c7
        w7 += ww7
    }
    @Assert(off7 == s7)
    @Assert(w7 == nd)
    var eq7 = true
    for (k in 0..nd) {
        if (out7[k] != D[k]) {
            eq7 = false
        }
    }
    @Assert(eq7)
    // 行 8 sc=seq3:skippable(0x184D2A50, size=13, 零载荷),feed=[3,2,6,余]
    let sf8 = Array<UInt8>(21, {_ => 0u8})
    sf8[0] = 0x50u8
    sf8[1] = 0x2Au8
    sf8[2] = 0x4Du8
    sf8[3] = 0x18u8
    sf8[4] = 13u8
    let want8: Array<(Int64, Int64, Int64)> = [(3, 0, 8), (2, 0, 6), (6, 0, 10), (10, 0, 0)]
    let feeds8: Array<Int64> = [3, 2, 6]
    let empty = Array<UInt8>(0, {_ => 0u8})
    let dc8 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    var off8: Int64 = 0
    for (k in 0..4) {
        let chunk8 = if (k < 3) { feeds8[k] } else { 21 - off8 }
        let (r8, c8, w8) = LZ4F_decompress(dc8, empty, 0, 0, sf8, off8, chunk8, noneOpt)
        let (ec8, ew8, eh8) = want8[k]
        @Assert(c8 == ec8)
        @Assert(w8 == ew8)
        @Assert(r8 == eh8)
        off8 += c8
    }
    @Assert(off8 == 21)
    @Assert(dc8.dStage == dstage_getFrameHeader)   // 跳帧完成自动 reset
    // 行 9 sc=seq4:skippable(0x184D2A5F, size=0)整帧单调用 → out=8:0:0
    let sf9 = Array<UInt8>(8, {_ => 0u8})
    sf9[0] = 0x5Fu8
    sf9[1] = 0x2Au8
    sf9[2] = 0x4Du8
    sf9[3] = 0x18u8
    let dc9 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r9, c9, w9) = LZ4F_decompress(dc9, empty, 0, 0, sf9, 0, 8, noneOpt)
    @Assert(c9 == 8)
    @Assert(w9 == 0)
    @Assert(r9 == 0)
    // 行 10 sc=cat:D ccs=1 帧 + skippable(size=5)+ D bcs=1 帧,单 dctx 顺序解压
    var p10a = LZ4F_preferences_t()
    p10a.frameInfo.contentChecksumFlag = 1
    let (seg10a, ss10a) = lz4fFdmpFrame(p10a, D, nd)
    @Assert(ss10a == 257)    // 7 + 4 + 238 + 4 + 4(ccs)
    let seg10b = Array<UInt8>(13, {_ => 0u8})
    seg10b[0] = 0x50u8
    seg10b[1] = 0x2Au8
    seg10b[2] = 0x4Du8
    seg10b[3] = 0x18u8
    seg10b[4] = 5u8
    var p10c = LZ4F_preferences_t()
    p10c.frameInfo.blockChecksumFlag = 1
    let (seg10c, ss10c) = lz4fFdmpFrame(p10c, D, nd)
    @Assert(ss10c == 257)    // 7 + 4 + 238 + 4(bcs) + 4
    let want10: Array<(Int64, Int64, Int64)> = [(257, 255, 0), (13, 0, 0), (257, 255, 0)]
    let dc10 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out10 = Array<UInt8>(n, {_ => 0u8})
    var w10: Int64 = 0
    for (k in 0..3) {
        if (k == 0) {
            let (r10, c10, ww10) = LZ4F_decompress(dc10, out10, w10, n - w10, seg10a, 0, ss10a, noneOpt)
            let (ec, ew, eh) = want10[0]
            @Assert(r10 == eh)
            @Assert(c10 == ec)
            @Assert(ww10 == ew)
            w10 += ww10
        } else if (k == 1) {
            let (r10, c10, ww10) = LZ4F_decompress(dc10, out10, w10, n - w10, seg10b, 0, 13, noneOpt)
            let (ec, ew, eh) = want10[1]
            @Assert(r10 == eh)
            @Assert(c10 == ec)
            @Assert(ww10 == ew)
        } else {
            let (r10, c10, ww10) = LZ4F_decompress(dc10, out10, w10, n - w10, seg10c, 0, ss10c, noneOpt)
            let (ec, ew, eh) = want10[2]
            @Assert(r10 == eh)
            @Assert(c10 == ec)
            @Assert(ww10 == ew)
            w10 += ww10
        }
    }
    @Assert(w10 == 2 * nd)
    var eq10 = true
    for (k in 0..nd) {
        if (out10[k] != D[k] || out10[nd + k] != D[k]) {
            eq10 = false
        }
    }
    @Assert(eq10)
    // 行 11 sc=dict:A dd=65536 dseed=0(字典内容 == 输入)lv=0 bm=0
    // Begin_usingDict 帧:out=34858:65536:0 code=-16 outxxh32=c20f7bcc(双钉)
    let dict0 = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(dict0, n, 0.50, 0.0, 0u32)
    @Assert(XXH32(dict0, n, 0u32) == 0xc20f7bccu32)   // dseed=0 → 与 A 逐字节相同
    var eqd0 = true
    for (k in 0..n) {
        if (dict0[k] != A[k]) {
            eqd0 = false
        }
    }
    @Assert(eqd0)
    var p11 = LZ4F_preferences_t()
    p11.compressionLevel = 0
    p11.frameInfo.blockMode = LZ4F_blockLinked
    let cap11 = LZ4F_compressFrameBound(n, Some(p11))
    let f11 = Array<UInt8>(cap11, {_ => 0u8})
    let cctx11 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos11: Int64 = 0
    pos11 += LZ4F_compressBegin_usingDict(cctx11, f11, pos11, cap11 - pos11, dict0, n, Some(p11))
    pos11 += LZ4F_compressUpdate(cctx11, f11, pos11, cap11 - pos11, A, 0, n,
        Option<LZ4F_compressOptions_t>.None)
    pos11 += LZ4F_compressEnd(cctx11, f11, pos11, cap11 - pos11, Option<LZ4F_compressOptions_t>.None)
    @Assert(pos11 == 34858)      // C 钉值(块引用字典,34858 < 无字典 38688)
    let dc11 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out11 = Array<UInt8>(n, {_ => 0u8})
    let (r11, c11, w11) = LZ4F_decompress_usingDict(dc11, out11, 0, n, f11, 0, pos11,
        dict0, n, noneOpt)
    @Assert(r11 == 0)
    @Assert(c11 == 34858)
    @Assert(w11 == 65536)
    @Assert(XXH32(out11, n, 0u32) == 0xc20f7bccu32)
    var eq11 = true
    for (k in 0..n) {
        if (out11[k] != A[k]) {
            eq11 = false
        }
    }
    @Assert(eq11)
    // 同帧无字典 → -16(引用越界必败,错误契约三元组)
    let dc11b = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out11b = Array<UInt8>(n, {_ => 0u8})
    let (r11b, c11b, w11b) = LZ4F_decompress(dc11b, out11b, 0, n, f11, 0, pos11, noneOpt)
    @Assert(r11b == -LZ4F_ERROR_decompressionFailed)
    @Assert(c11b == 0)
    @Assert(w11b == 0)
    // T2 延迟断言(ruling 2):fdt row 473 几何(dseed=99)同帧无字典 → -16
    // (C harness fdmp 节 stderr 探针 2026-10-02:r=-16;T2 报告仓颉探针同值)
    let dict99 = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(dict99, n, 0.50, 0.0, 99u32)
    @Assert(XXH32(dict99, n, 0u32) == 0x059edec2u32)
    let cap99 = LZ4F_compressFrameBound(n, Some(p11))
    let f99 = Array<UInt8>(cap99, {_ => 0u8})
    let cctx99 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos99: Int64 = 0
    pos99 += LZ4F_compressBegin_usingDict(cctx99, f99, pos99, cap99 - pos99, dict99, n, Some(p11))
    pos99 += LZ4F_compressUpdate(cctx99, f99, pos99, cap99 - pos99, A, 0, n,
        Option<LZ4F_compressOptions_t>.None)
    pos99 += LZ4F_compressEnd(cctx99, f99, pos99, cap99 - pos99, Option<LZ4F_compressOptions_t>.None)
    @Assert(pos99 == 38651)      // fdt row 473 golden
    let dc99 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out99 = Array<UInt8>(n, {_ => 0u8})
    let (r99, c99, w99) = LZ4F_decompress(dc99, out99, 0, n, f99, 0, pos99, noneOpt)
    @Assert(r99 == -LZ4F_ERROR_decompressionFailed)
    @Assert(c99 == 0)
    @Assert(w99 == 0)
    // 行 12 sc=errhdr:坏帧 5 例 → code=-13;-6;-8;-2;-17
    let wantHdr: Array<Int64> = [
        -LZ4F_ERROR_frameType_unknown, -LZ4F_ERROR_headerVersion_wrong,
        -LZ4F_ERROR_reservedFlag_set, -LZ4F_ERROR_maxBlockSize_invalid,
        -LZ4F_ERROR_headerChecksum_invalid]
    let out12 = Array<UInt8>(n, {_ => 0u8})
    for (v in 0..5) {
        let h12 = Array<UInt8>(19, {_ => 0u8})
        h12[0] = 0x04u8
        h12[1] = 0x22u8
        h12[2] = 0x4Du8
        h12[3] = 0x18u8
        h12[4] = 0x60u8
        h12[5] = 0x40u8
        if (v == 0) {
            h12[3] = 0x05u8
        } else if (v == 1) {
            h12[4] = 0x80u8
        } else if (v == 2) {
            h12[4] = 0x62u8
        } else if (v == 3) {
            h12[5] = 0x30u8
        } else {
            let hb = Array<UInt8>(2, {_ => 0u8})
            hb[0] = 0x60u8
            hb[1] = 0x40u8
            h12[6] = lz4fHeaderChecksum(hb, 2) ^ 0xFFu8
        }
        let dc12 = LZ4F_createDecompressionContext(LZ4F_VERSION)
        let (r12, c12, w12) = LZ4F_decompress(dc12, out12, 0, n, h12, 0, 19, noneOpt)
        @Assert(r12 == wantHdr[v])
        @Assert(c12 == 0)
        @Assert(w12 == 0)
    }
    // 行 13 sc=errblk:块大小字段改 65537 → -2;块校验和尾篡改 → -7
    let (f13, s13) = lz4fFdmpFrame(LZ4F_preferences_t(), A, n)
    @Assert(s13 == 38688)
    let f13b = Array<UInt8>(s13, {i => f13[i]})
    f13b[7] = 0x01u8
    f13b[8] = 0x00u8
    f13b[9] = 0x00u8
    f13b[10] = 0x01u8      // 65537 LE(> maxBlockSize 65536)
    let dc13 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out13 = Array<UInt8>(n, {_ => 0u8})
    let (r13, c13, w13) = LZ4F_decompress(dc13, out13, 0, n, f13b, 0, s13, noneOpt)
    @Assert(r13 == -LZ4F_ERROR_maxBlockSize_invalid)
    @Assert(c13 == 0)
    @Assert(w13 == 0)
    var p13c = LZ4F_preferences_t()
    p13c.frameInfo.blockChecksumFlag = 1
    let (f13c, s13c) = lz4fFdmpFrame(p13c, A, n)
    @Assert(s13c == 38692)
    let csize13 = Int64(lz4fReadLE32(f13c, 7) & 0x7FFFFFFFu32)
    let f13d = Array<UInt8>(s13c, {i => f13c[i]})
    f13d[11 + csize13] = f13d[11 + csize13] ^ 0xFFu8
    let dc13d = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r13d, c13d, w13d) = LZ4F_decompress(dc13d, out13, 0, n, f13d, 0, s13c, noneOpt)
    @Assert(r13d == -LZ4F_ERROR_blockChecksum_invalid)
    @Assert(c13d == 0)
    @Assert(w13d == 0)
    // 行 14 sc=errtail:尾 CRC 篡改 → -18;csz=60000 解码完成 → -14;
    // 截断半帧喂入 → 正 hint=19344(非错误钉值)
    let f14 = Array<UInt8>(s3, {i => f3[i]})
    f14[s3 - 1] = f14[s3 - 1] ^ 0xFFu8
    let dc14 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out14 = Array<UInt8>(n, {_ => 0u8})
    let (r14, c14, w14) = LZ4F_decompress(dc14, out14, 0, n, f14, 0, s3, noneOpt)
    @Assert(r14 == -LZ4F_ERROR_contentChecksum_invalid)
    @Assert(c14 == 0)
    @Assert(w14 == 0)
    let cctx14 = LZ4F_createCompressionContext(LZ4F_VERSION)
    var ph14 = LZ4F_preferences_t()
    ph14.frameInfo.contentSize = 60000u64
    let hdr14 = Array<UInt8>(19, {_ => 0u8})
    @Assert(LZ4F_compressBegin(cctx14, hdr14, 0, 19, Some(ph14)) == 15)
    let f14b = Array<UInt8>(15 + s13 - 7, {_ => 0u8})
    for (i in 0..15) {
        f14b[i] = hdr14[i]
    }
    for (i in 7..s13) {
        f14b[8 + i] = f13[i]
    }
    let dc14b = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r14b, c14b, w14b) = LZ4F_decompress(dc14b, out14, 0, n, f14b, 0, Int64(f14b.size), noneOpt)
    @Assert(r14b == -LZ4F_ERROR_frameSize_wrong)
    @Assert(c14b == 0)
    @Assert(w14b == 0)
    let dc14c = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r14c, c14c, w14c) = LZ4F_decompress(dc14c, out14, 0, n, f13, 0, s13 / 2, noneOpt)
    @Assert(r14c == 19344)      // 正 hint 钉值(storeCBlock 剩余 + BHSize)
    @Assert(c14c == 19344)
    @Assert(w14c == 0)
    println("lz4f fdmp golden: 14 scenarios replayed with C-pinned triples")
}

// FRAME_GOLD_REF 行 → 帧重建(lz4fDecodeGoldenTest 同构,抽出供随机切分复用)
private func lz4fBuildGoldFrame(bs: Int32, bm: Int32, ccs: Int32, bcs: Int32, csz: UInt64,
        did: UInt32, lv: Int32, fav: Int32, af: Int32, ss: Int32, scen: Int32,
        input: Array<UInt8>, n: Int64): (Array<UInt8>, Int64) {
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
    let frame = Array<UInt8>(dstCap, {_ => 0u8})
    var pos: Int64 = 0
    var r = LZ4F_compressBegin(cctx, frame, pos, dstCap - pos, Some(prefs))
    @Assert(!LZ4F_isError(r))
    pos += r
    var cOpt = Option<LZ4F_compressOptions_t>.None
    if (ss != 0) {
        var o = LZ4F_compressOptions_t()
        o.stableSrc = 1u32
        cOpt = Some(o)
    }
    if (scen == 0) {
        r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, n, cOpt)
        @Assert(!LZ4F_isError(r))
        pos += r
    } else if (scen == 1) {
        r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, 50000, cOpt)
        @Assert(!LZ4F_isError(r))
        pos += r
        r = LZ4F_flush(cctx, frame, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
        @Assert(!LZ4F_isError(r))
        pos += r
        r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 50000, n - 50000, cOpt)
        @Assert(!LZ4F_isError(r))
        pos += r
    } else if (scen == 2) {
        r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 0, 65536, cOpt)
        @Assert(!LZ4F_isError(r))
        pos += r
        r = LZ4F_uncompressedUpdate(cctx, frame, pos, dstCap - pos, input, 65536, 32768, cOpt)
        @Assert(!LZ4F_isError(r))
        pos += r
        r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, 98304, 32768, cOpt)
        @Assert(!LZ4F_isError(r))
        pos += r
    } else {
        let chunkSizes: Array<Int64> = [26214, 26214, 26214, 26215, 26215]
        var off: Int64 = 0
        for (k in 0..5) {
            r = LZ4F_compressUpdate(cctx, frame, pos, dstCap - pos, input, off, chunkSizes[k], cOpt)
            @Assert(!LZ4F_isError(r))
            pos += r
            off += chunkSizes[k]
        }
    }
    r = LZ4F_compressEnd(cctx, frame, pos, dstCap - pos, Option<LZ4F_compressOptions_t>.None)
    @Assert(!LZ4F_isError(r))
    pos += r
    return (frame, pos)
}

// 随机切分解码核:按 chunk 模式喂入至 ret==0 → 输出逐字节 == 输入 +
// Σconsumed==size;capLimit 小容量逼 flushOut 多轮回;dstIdx>0 位置对解码
// (输出落于大缓冲中部,[0, dstIdx) 哨兵不动)
private func lz4fFdmpSplitDecode(frame: Array<UInt8>, size: Int64, input: Array<UInt8>, n: Int64,
        chunkMode: Int64, capLimit: Int64, dstIdx: Int64, lcgSeed: UInt64, rowTag: Int64): Unit {
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out = Array<UInt8>(dstIdx + n, {i => if (i < dstIdx) { 0xA5u8 } else { 0u8 }})
    var rng = lcgSeed + 1u64
    var off: Int64 = 0
    var written: Int64 = 0
    var r: Int64 = 1
    var iters: Int64 = 0
    let maxIters = 4 * size + 64
    while (r != 0) {
        iters += 1
        if (iters > maxIters) {
            println("SPLIT STALL row=${rowTag} mode=${chunkMode} cap=${capLimit} off=${off}/${size} w=${written}/${n}")
        }
        @Assert(iters <= maxIters)
        var chunk: Int64 = 0
        if (chunkMode == 0) {
            chunk = 1
        } else if (chunkMode == 1) {
            chunk = 7
        } else if (chunkMode == 2) {
            chunk = 997
        } else {
            rng = lz4fFdmpLcgNext(rng)
            chunk = 1 + Int64(rng % 997u64)
        }
        if (chunk > size - off) {
            chunk = size - off
        }
        var cap = capLimit
        if (cap > n - written) {
            cap = n - written
        }
        let (rr, cc, ww) = LZ4F_decompress(dctx, out, dstIdx + written, cap, frame, off, chunk,
            Option<LZ4F_decompressOptions_t>.None)
        if (LZ4F_isError(rr)) {
            println("SPLIT ERR row=${rowTag} mode=${chunkMode} cap=${capLimit} off=${off} chunk=${chunk}: ret=${rr}")
        }
        @Assert(!LZ4F_isError(rr))
        off += cc
        written += ww
        r = rr
    }
    if (off != size || written != n) {
        println("SPLIT SUM row=${rowTag} mode=${chunkMode} cap=${capLimit}: off=${off}/${size} w=${written}/${n}")
    }
    @Assert(off == size)
    @Assert(written == n)
    var eq = true
    for (k in 0..n) {
        if (out[dstIdx + k] != input[k]) {
            eq = false
        }
    }
    if (!eq) {
        println("SPLIT BYTES row=${rowTag} mode=${chunkMode} cap=${capLimit} dstIdx=${dstIdx}")
    }
    @Assert(eq)
    if (dstIdx > 0) {
        var pre = true
        for (k in 0..dstIdx) {
            if (out[k] != 0xA5u8) {
                pre = false
            }
        }
        @Assert(pre)
    }
}

@Test
func lz4fRandomSplitTest(): Unit {
    // FRAME_GOLD_REF 27 行 × 切分模式 {1B, 7B, 997B, LCG(seed=行号)} × 容量
    // {n, 10, 1000} + dstIdx=4096 位置对;全部按 hint 循环喂入至 ret==0
    var checked = 0
    for (ri in 0..FRAME_GOLD_REF.size) {
        let (n, mp, seed, bs, bm, ccs, bcs, csz, did, lv, fav, af, ss, scen, wantSize, _, _, _) = FRAME_GOLD_REF[ri]
        let input = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(input, n, mp, 0.0, seed)
        let (frame, size) = lz4fBuildGoldFrame(bs, bm, ccs, bcs, csz, did, lv, fav, af, ss, scen,
            input, n)
        @Assert(size == wantSize)
        for (mode in 0..4) {
            lz4fFdmpSplitDecode(frame, size, input, n, mode, n, 0, UInt64(ri), Int64(ri))
        }
        lz4fFdmpSplitDecode(frame, size, input, n, 3, 10, 0, UInt64(ri), Int64(ri))
        lz4fFdmpSplitDecode(frame, size, input, n, 3, 1000, 0, UInt64(ri), Int64(ri))
        lz4fFdmpSplitDecode(frame, size, input, n, 2, n, 4096, UInt64(ri), Int64(ri))
        checked += 1
    }
    @Assert(checked == 27)
    println("lz4f random split: ${checked}/27 rows x 7 variants decoded byte-exact")
}

@Test
func lz4fStableDstTest(): Unit {
    // bm=0 多块(2x65536)C 几何帧:pledge 兑现 —— 128KB 缓冲,第二调用
    // dstIdx=65536,先前产出 [0, 65536) 不动;stableDst=1 与 =0 输出一致
    let n: Int64 = 131072
    let input = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(input, n, 0.90, 0.0, 0u32)
    var prefs = LZ4F_preferences_t()      // bs=4 bm=0(linked)lv=0 默认
    let (frame, size) = lz4fFdmpFrame(prefs, input, n)
    let csize1 = Int64(lz4fReadLE32(frame, 7) & 0x7FFFFFFFu32)
    let blockEnd = 11 + csize1            // bcs=0
    @Assert(blockEnd < size)
    var opt = LZ4F_decompressOptions_t()
    opt.stableDst = 1u32
    // stableDst=1 走廊
    let buf1 = Array<UInt8>(n, {_ => 0xA5u8})
    let d1 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r1a, c1a, w1a) = LZ4F_decompress(d1, buf1, 0, 65536, frame, 0, blockEnd, Some(opt))
    @Assert(c1a == blockEnd)
    @Assert(w1a == 65536)
    @Assert(r1a == 4)                     // 块 1 直解,余下块头 hint
    var eqp = true
    for (k in 0..65536) {
        if (buf1[k] != input[k]) {
            eqp = false
        }
    }
    @Assert(eqp)
    let (r1b, c1b, w1b) = LZ4F_decompress(d1, buf1, 65536, 65536, frame, blockEnd,
        size - blockEnd, Some(opt))
    @Assert(r1b == 0)
    @Assert(c1b == size - blockEnd)
    @Assert(w1b == 65536)
    var eq1 = true
    for (k in 0..n) {
        if (buf1[k] != input[k]) {
            eq1 = false
        }
    }
    @Assert(eq1)                          // pledge:[0,65536) 首调用产出原地未动
    // stableDst=0 同几何:输出一致(性能语义差异仅调用内部路径,不断言调用数)
    let buf2 = Array<UInt8>(n, {_ => 0xA5u8})
    let d2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r2a, c2a, w2a) = LZ4F_decompress(d2, buf2, 0, 65536, frame, 0, blockEnd,
        Option<LZ4F_decompressOptions_t>.None)
    @Assert(c2a == blockEnd)
    @Assert(w2a == 65536)
    let (r2b, c2b, w2b) = LZ4F_decompress(d2, buf2, 65536, 65536, frame, blockEnd,
        size - blockEnd, Option<LZ4F_decompressOptions_t>.None)
    @Assert(r2b == 0)
    @Assert(c2b == size - blockEnd)
    @Assert(w2b == 65536)
    var eq2 = true
    for (k in 0..n) {
        if (buf1[k] != buf2[k]) {
            eq2 = false
        }
    }
    @Assert(eq2)
    println("lz4f stableDst pledge honored, stable=1/0 outputs identical")
}

@Test
func lz4fSkipChecksumsTest(): Unit {
    // ccs=1 bcs=1 帧两处 CRC 篡改 + 仅内容 CRC 坏帧,四个探针:
    // 上游 0774d055 怪癖 —— checkSuffix 有 skipChecksum 守卫(L2047,内容
    // CRC 跳过),storeCBlock 簇 one-shot 块校验和(L1904-1916)无守卫:
    // 双坏帧 skip=1 仍 -7;仅内容坏帧 skip=1 → 0(C 探针 stderr 钉值,
    // gen_golden.c fdmp 节 skipChecksum probes);=0 → -7 / -18;粘滞:
    // 首调用置 1 后续不传 options 仍跳过(仅内容坏帧验证成功路径)
    let n: Int64 = 65536
    let input = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(input, n, 0.50, 0.0, 0u32)
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.contentChecksumFlag = 1
    prefs.frameInfo.blockChecksumFlag = 1
    let (f, s) = lz4fFdmpFrame(prefs, input, n)
    let csize = Int64(lz4fReadLE32(f, 7) & 0x7FFFFFFFu32)
    let fb = Array<UInt8>(s, {i => f[i]})
    fb[11 + csize] = fb[11 + csize] ^ 0xFFu8    // 块校验和首字节
    fb[s - 1] = fb[s - 1] ^ 0xFFu8              // 内容校验和尾字节
    var opt = LZ4F_decompressOptions_t()
    opt.skipChecksums = 1u32
    let out = Array<UInt8>(n, {_ => 0u8})
    let noneOpt = Option<LZ4F_decompressOptions_t>.None
    // 双坏帧 skip=1 → -7(one-shot 块校验和不跳过,上游怪癖钉值)
    let d1 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r1, c1, w1) = LZ4F_decompress(d1, out, 0, n, fb, 0, s, Some(opt))
    @Assert(r1 == -LZ4F_ERROR_blockChecksum_invalid)
    @Assert(c1 == 0)
    @Assert(w1 == 0)
    // 仅内容 CRC 坏帧 skip=1 → 0 且输出 == 输入(checkSuffix 跳过)
    var p1 = LZ4F_preferences_t()
    p1.frameInfo.contentChecksumFlag = 1
    let (f1, s1) = lz4fFdmpFrame(p1, input, n)
    let f1b = Array<UInt8>(s1, {i => f1[i]})
    f1b[s1 - 1] = f1b[s1 - 1] ^ 0xFFu8
    let d1b = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let (r1b, c1b, w1b) = LZ4F_decompress(d1b, out, 0, n, f1b, 0, s1, Some(opt))
    @Assert(r1b == 0)
    @Assert(c1b == s1)
    @Assert(w1b == n)
    var eq1 = true
    for (k in 0..n) {
        if (out[k] != input[k]) {
            eq1 = false
        }
    }
    @Assert(eq1)
    // skip=0(默认):块校验和先失败 → -7
    let d2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out2 = Array<UInt8>(n, {_ => 0u8})
    let (r2, c2, w2) = LZ4F_decompress(d2, out2, 0, n, fb, 0, s, noneOpt)
    @Assert(r2 == -LZ4F_ERROR_blockChecksum_invalid)
    @Assert(c2 == 0)
    @Assert(w2 == 0)
    // 仅内容 CRC 坏帧 skip=0 → -18
    let d3 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out3 = Array<UInt8>(n, {_ => 0u8})
    let (r3, c3, w3) = LZ4F_decompress(d3, out3, 0, n, f1b, 0, s1, noneOpt)
    @Assert(r3 == -LZ4F_ERROR_contentChecksum_invalid)
    @Assert(c3 == 0)
    @Assert(w3 == 0)
    // 粘滞:首调用(仅 7B 头)置 skipChecksums=1,后续调用不传 options
    // 仍跳过(仅内容坏帧 → 成功;C 探针 call1=(4,7,0) call2=(0,余,65536))
    let d4 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out4 = Array<UInt8>(n, {_ => 0u8})
    let (r4a, c4a, w4a) = LZ4F_decompress(d4, out4, 0, n, f1b, 0, 7, Some(opt))
    @Assert(c4a == 7)
    @Assert(w4a == 0)
    @Assert(r4a == 4)
    @Assert(d4.skipChecksum == 1)         // 置位粘滞(帧内持续,保真点⑮)
    let (r4b, c4b, w4b) = LZ4F_decompress(d4, out4, w4a, n - w4a, f1b, c4a, s1 - c4a, noneOpt)
    @Assert(r4b == 0)
    @Assert(c4b == s1 - 7)
    @Assert(w4b == n)
    var eq4 = true
    for (k in 0..n) {
        if (out4[k] != input[k]) {
            eq4 = false
        }
    }
    @Assert(eq4)
    @Assert(d4.skipChecksum == 0)         // 帧完成自动 reset 清位(L1360)
    println("lz4f skipChecksums skip/sticky pins verified")
}

@Test
func lz4fSkippableTest(): Unit {
    // 尺寸 {0,1,13,70000} × 魔数 {0x184D2A50, 0x184D2A5F}:整段与
    // [3,2,余] 切分 → (0, 8+size, 0) 且零输出;跳帧完成后同 dctx 续解
    // 正常帧(reset 语义)
    let noneOpt = Option<LZ4F_decompressOptions_t>.None
    let empty = Array<UInt8>(0, {_ => 0u8})
    let sizes: Array<Int64> = [0, 1, 13, 70000]
    let magics: Array<UInt8> = [0x50u8, 0x5Fu8]
    let nd: Int64 = 255
    let D = Array<UInt8>(nd, {_ => 0u8})
    RDG_genBuffer(D, nd, 0.50, 0.0, 0u32)
    let (fd, sd) = lz4fFdmpFrame(LZ4F_preferences_t(), D, nd)
    var combos = 0
    for (mi in 0..2) {
        for (si in 0..4) {
            let size = sizes[si]
            let total = 8 + size
            let sf = Array<UInt8>(total, {_ => 0u8})
            sf[0] = magics[mi]
            sf[1] = 0x2Au8
            sf[2] = 0x4Du8
            sf[3] = 0x18u8
            sf[4] = UInt8(size & 0xFF)
            sf[5] = UInt8((size >> 8) & 0xFF)
            sf[6] = UInt8((size >> 16) & 0xFF)
            sf[7] = UInt8((size >> 24) & 0xFF)
            // 整段
            let dA = LZ4F_createDecompressionContext(LZ4F_VERSION)
            let (rA, cA, wA) = LZ4F_decompress(dA, empty, 0, 0, sf, 0, total, noneOpt)
            @Assert(rA == 0)
            @Assert(cA == total)
            @Assert(wA == 0)
            // [3, 2, 余] 切分
            let dB = LZ4F_createDecompressionContext(LZ4F_VERSION)
            var off: Int64 = 0
            let (r1, c1, _) = LZ4F_decompress(dB, empty, 0, 0, sf, off, 3, noneOpt)
            @Assert(r1 > 0)
            off += c1
            let (r2, c2, _) = LZ4F_decompress(dB, empty, 0, 0, sf, off, 2, noneOpt)
            @Assert(r2 > 0)
            off += c2
            let (r3, c3, w3) = LZ4F_decompress(dB, empty, 0, 0, sf, off, total - off, noneOpt)
            @Assert(r3 == 0)
            off += c3
            @Assert(off == total)
            @Assert(w3 == 0)
            @Assert(dB.dStage == dstage_getFrameHeader)
            // 跳帧完成后同 dctx 续解正常帧(reset 语义)
            let outD = Array<UInt8>(nd, {_ => 0u8})
            let (rD, cD, wD) = LZ4F_decompress(dB, outD, 0, nd, fd, 0, sd, noneOpt)
            @Assert(rD == 0)
            @Assert(cD == sd)
            @Assert(wD == nd)
            var eqD = true
            for (k in 0..nd) {
                if (outD[k] != D[k]) {
                    eqD = false
                }
            }
            @Assert(eqD)
            combos += 1
        }
    }
    @Assert(combos == 8)
    println("lz4f skippable: ${combos}/8 magic x size combos whole+split, reset semantics ok")
}

@Test
func lz4fFrameConcatTest(): Unit {
    // 仓颉自产 4 帧矩阵(ccs/bcs/skippable 混排)单 dctx 顺序解压:输出
    // 拼接 == 各输入拼接;getFrameInfo 在段间可调用(每段先探测再续解)
    let n: Int64 = 65536
    let A = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(A, n, 0.50, 0.0, 0u32)
    let nd: Int64 = 255
    let D = Array<UInt8>(nd, {_ => 0u8})
    RDG_genBuffer(D, nd, 0.50, 0.0, 0u32)
    var p1 = LZ4F_preferences_t()
    p1.frameInfo.contentChecksumFlag = 1
    let (seg1, ss1) = lz4fFdmpFrame(p1, A, n)
    let seg2 = Array<UInt8>(21, {_ => 0u8})
    seg2[0] = 0x50u8
    seg2[1] = 0x2Au8
    seg2[2] = 0x4Du8
    seg2[3] = 0x18u8
    seg2[4] = 13u8
    var p3 = LZ4F_preferences_t()
    p3.frameInfo.blockChecksumFlag = 1
    let (seg3, ss3) = lz4fFdmpFrame(p3, D, nd)
    let (seg4, ss4) = lz4fFdmpFrame(LZ4F_preferences_t(), A, n)
    let totalOut = n + nd + n
    let out = Array<UInt8>(totalOut, {_ => 0u8})
    let noneOpt = Option<LZ4F_decompressOptions_t>.None
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    var written: Int64 = 0
    // 段 1:A ccs=1(getFrameInfo 先行,消耗 7B 头)
    let (g1, gi1, gu1) = LZ4F_getFrameInfo(dctx, seg1, 0, 19)
    @Assert(g1 == 4)
    @Assert(gu1 == 7)
    @Assert(gi1.contentChecksumFlag == 1)
    let (r1, c1, w1) = LZ4F_decompress(dctx, out, written, totalOut - written, seg1, gu1,
        ss1 - gu1, noneOpt)
    @Assert(r1 == 0)
    @Assert(c1 == ss1 - 7)
    @Assert(w1 == n)
    written += w1
    // 段 2:skippable(size=13)
    let (g2, gi2, gu2) = LZ4F_getFrameInfo(dctx, seg2, 0, 19)
    @Assert(g2 == 4)
    @Assert(gu2 == 4)
    @Assert(gi2.frameType == LZ4F_skippableFrame)
    let (r2, c2, w2) = LZ4F_decompress(dctx, out, written, totalOut - written, seg2, gu2,
        21 - gu2, noneOpt)
    @Assert(r2 == 0)
    @Assert(c2 == 17)
    @Assert(w2 == 0)
    // 段 3:D bcs=1
    let (g3, gi3, gu3) = LZ4F_getFrameInfo(dctx, seg3, 0, 19)
    @Assert(g3 == 4)
    @Assert(gu3 == 7)
    @Assert(gi3.blockChecksumFlag == 1)
    let (r3, c3, w3) = LZ4F_decompress(dctx, out, written, totalOut - written, seg3, gu3,
        ss3 - gu3, noneOpt)
    @Assert(r3 == 0)
    @Assert(c3 == ss3 - 7)
    @Assert(w3 == nd)
    written += w3
    // 段 4:A 默认
    let (g4, gi4, gu4) = LZ4F_getFrameInfo(dctx, seg4, 0, 19)
    @Assert(g4 == 4)
    @Assert(gu4 == 7)
    @Assert(gi4.contentChecksumFlag == 0)
    let (r4, c4, w4) = LZ4F_decompress(dctx, out, written, totalOut - written, seg4, gu4,
        ss4 - gu4, noneOpt)
    @Assert(r4 == 0)
    @Assert(c4 == ss4 - 7)
    @Assert(w4 == n)
    written += w4
    @Assert(written == totalOut)
    // 输出拼接 == 输入拼接(A ++ D ++ A;skippable 无贡献)
    var eq = true
    for (k in 0..n) {
        if (out[k] != A[k] || out[n + nd + k] != A[k]) {
            eq = false
        }
    }
    for (k in 0..nd) {
        if (out[n + k] != D[k]) {
            eq = false
        }
    }
    @Assert(eq)
    @Assert(dctx.dStage == dstage_getFrameHeader)
    println("lz4f frame concat: 4 mixed segments on one dctx, getFrameInfo between segments")
}
