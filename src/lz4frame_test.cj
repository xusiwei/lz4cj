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

package lz4

import std.unittest.*

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
