// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream lib/lz4frame.c + lib/lz4frame.h (frame format).
// M6 Task 1: 解压侧骨架 —— dStage 常量族 + LZ4F_dctx 生命周期
// (create/free/reset,lz4frame.c L1266-1341/L1354-1362)+ LZ4F_headerSize
// (L1471-1495)+ decompressOptions;解压状态机由 M6 后续任务落地。
// M6 Task 2: decodeHeader(L1373-1464)+ getFrameInfo(L1512-1551)+
// updateDict(L1558-1623)+ decompress 状态机与尾部历史保存
// (L1644-2147)+ decompress_usingDict(L2154-2167)。

package lz4

/*-************************************
*  decompressOptions (lz4frame.h L370-383)
**************************************/
/* LZ4F_decompressOptions_t:stableDst/skipChecksums;reserved1/reserved0
   省略(设计 §4.5 注记,同 compressOptions 处理)。 */
public struct LZ4F_decompressOptions_t {
    public var stableDst: UInt32 = 0u32
    public var skipChecksums: UInt32 = 0u32
    public init() {}
}

/* LZ4F_MIN_SIZE_TO_KNOW_HEADER_LENGTH(lz4frame.h L408):判定头长所需
   最少字节数(魔数 4 + FLG 1)。 */
public const LZ4F_MIN_SIZE_TO_KNOW_HEADER_LENGTH: Int64 = 5

/*-************************************
*  dStage 常量族 (lz4frame.c L1266-1276)
**************************************/
/* dStage_t 枚举(15 级);仓颉无 C 值枚举,以 internal Int32 常量族
   承载,成员名逐字(设计 §4.5 注记,同 LZ4F_* 枚举处理)。 */
internal const dstage_getFrameHeader: Int32 = 0
internal const dstage_storeFrameHeader: Int32 = 1
internal const dstage_init: Int32 = 2
internal const dstage_getBlockHeader: Int32 = 3
internal const dstage_storeBlockHeader: Int32 = 4
internal const dstage_copyDirect: Int32 = 5
internal const dstage_getBlockChecksum: Int32 = 6
internal const dstage_getCBlock: Int32 = 7
internal const dstage_storeCBlock: Int32 = 8
internal const dstage_flushOut: Int32 = 9
internal const dstage_getSuffix: Int32 = 10
internal const dstage_storeSuffix: Int32 = 11
internal const dstage_getSFrameSize: Int32 = 12
internal const dstage_storeSFrameSize: Int32 = 13
internal const dstage_skipSkippable: Int32 = 14

/*-************************************
*  dctx (lz4frame.c L1278-1299)
**************************************/
/* LZ4F_dctx_s 结构:指针字段按设计 §4.4 翻译表承载——
   tmpIn/tmpOutBuffer/dictBuf 以数组(空 = C NULL)、C 指针 dict/
   tmpOut 以"缓冲 + 索引"对、dict==tmpOutBuffer 同一性以 dictInTmp
   标记(每个赋值点同步)。header[19] = LZ4F_HEADER_SIZE_MAX;
   cmem(定制分配器)不移植。 */
public class LZ4F_dctx {
    internal var frameInfo: LZ4F_frameInfo_t = LZ4F_frameInfo_t()
    internal var version: UInt32 = 0u32
    internal var dStage: Int32 = 0                        // dstage_* 常量族(0..14)
    internal var frameRemainingSize: UInt64 = 0u64
    internal var maxBlockSize: Int64 = 0
    internal var maxBufferSize: Int64 = 0
    internal var tmpIn: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})       // 空 = C NULL;dstage_init 分配 maxBlockSize+4
    internal var tmpInSize: Int64 = 0
    internal var tmpInTarget: Int64 = 0
    internal var tmpOutBuffer: Array<UInt8> = Array<UInt8>(0, {_ => 0u8}) // 空 = C NULL;分配 maxBlockSize + (linked?128KB:0)
    internal var dictBuf: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})      // C const BYTE* dict → 引用对
    internal var dictIdx: Int64 = 0
    internal var dictInTmp: Bool = false                   // dict 指向 tmpOutBuffer(C 指针同一性标记,每个赋值点同步)
    internal var dictSize: Int64 = 0
    internal var tmpOut: Int64 = 0                         // C BYTE* tmpOut → tmpOutBuffer 内索引
    internal var tmpOutSize: Int64 = 0
    internal var tmpOutStart: Int64 = 0
    internal var xxh: XXH32_state_t = XXH32_state_t()
    internal var blockChecksum: XXH32_state_t = XXH32_state_t()
    internal var skipChecksum: Int32 = 0
    internal var header: Array<UInt8> = Array<UInt8>(19, {_ => 0u8})      // LZ4F_HEADER_SIZE_MAX
}

/* LZ4F_createDecompressionContext(lz4frame.c L1317-1330,public 版;
   advanced 变体 L1302-1316 不移植):C 侧经出参返回 dctx + 错误码;
   仓颉侧直接返回实例。calloc 零初始化由字段默认值承载;分配失败在
   GC 模型下不可达(无 allocation_failed 出口)。version 仅存字段,
   C 不作校验。 */
public func LZ4F_createDecompressionContext(version: UInt32): LZ4F_dctx {
    let dctx = LZ4F_dctx()
    dctx.version = version
    dctx.dStage = dstage_getFrameHeader     /* calloc 零值 = dstage_getFrameHeader */
    return dctx
}

/* LZ4F_freeDecompressionContext(lz4frame.c L1331-1341):返回释放时的
   dStage(C 语义)。tmpIn/tmpOutBuffer/dctx 三段堆释放由 GC 承载,
   无动作;C 可接受 NULL 输入(如 free()),仓颉非空类型下不设该
   分支(N/A 登记)。 */
public func LZ4F_freeDecompressionContext(dctx: LZ4F_dctx): Int64 {
    return Int64(dctx.dStage)
}

/* LZ4F_resetDecompressionContext(lz4frame.c L1354-1362):复位五字段
   (dStage/dict/dictSize/skipChecksum/frameRemainingSize);dict=NULL
   翻译为 dictBuf 置空数组,并同步清除 dictInTmp 标记(翻译表:
   每个赋值点同步)。 */
public func LZ4F_resetDecompressionContext(dctx: LZ4F_dctx): Unit {
    dctx.dStage = dstage_getFrameHeader
    dctx.dictBuf = Array<UInt8>(0, {_ => 0u8})
    dctx.dictInTmp = false
    dctx.dictSize = 0
    dctx.skipChecksum = 0
    dctx.frameRemainingSize = 0u64
}

/*-************************************
*  headerSize (lz4frame.c L1471-1495)
**************************************/
/* 安全索引层 LE32 读取(common.cj LZ4_readLE32 为 CPointer 版,
   本层按字节组装;先例 lz4frame_test.cj lz4fReadLE32)。 */
private func lz4fReadLE32(buf: Array<UInt8>, idx: Int64): UInt32 {
    return UInt32(buf[idx]) | (UInt32(buf[idx + 1]) << 8) |
        (UInt32(buf[idx + 2]) << 16) | (UInt32(buf[idx + 3]) << 24)
}

/* LZ4F_headerSize:srcSize<5 → -12(frameHeader_incomplete,L1476-1477);
   skippable 魔数前缀(低 4 位掩码)→ 恒 8(L1480-1481);魔数不符 →
   -13(frameType_unknown,L1485-1486);否则 minFHSize + csz*8 + did*4
   (L1490-1493)。C 的 src==NULL → -15(srcPtr_wrong,L1473)在非空
   数组类型下 N/A;FUZZING 构建豁免魔数校验的 ifdef 分支不移植
   (标准构建路径)。 */
public func LZ4F_headerSize(srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64): Int64 {
    if (srcSize < LZ4F_MIN_SIZE_TO_KNOW_HEADER_LENGTH) {             /* L1476-1477 */
        return -LZ4F_ERROR_frameHeader_incomplete
    }
    if ((lz4fReadLE32(srcBuf, srcIdx) & 0xFFFFFFF0u32) == LZ4F_MAGIC_SKIPPABLE_START) {
        return 8                                                      /* L1480-1481 */
    }
    if (lz4fReadLE32(srcBuf, srcIdx) != LZ4F_MAGICNUMBER) {          /* L1485-1486 */
        return -LZ4F_ERROR_frameType_unknown
    }
    let FLG = srcBuf[srcIdx + 4]                                      /* L1490 */
    let contentSizeFlag = (UInt32(FLG) >> 3) & 1u32                   /* L1491 */
    let dictIDFlag = UInt32(FLG) & 1u32                               /* L1492 */
    return LZ4F_HEADER_SIZE_MIN + Int64(contentSizeFlag) * 8 +
        Int64(dictIDFlag) * 4                                         /* L1493 */
}

/*-************************************
*  decodeHeader / getFrameInfo (lz4frame.c L1373-1464 / L1512-1551)
**************************************/
/* 安全索引层 LE64 读取(contentSize 字段,decodeHeader 用)。 */
private func lz4fReadLE64(buf: Array<UInt8>, idx: Int64): UInt64 {
    return UInt64(buf[idx]) | (UInt64(buf[idx + 1]) << 8) |
        (UInt64(buf[idx + 2]) << 16) | (UInt64(buf[idx + 3]) << 24) |
        (UInt64(buf[idx + 4]) << 32) | (UInt64(buf[idx + 5]) << 40) |
        (UInt64(buf[idx + 6]) << 48) | (UInt64(buf[idx + 7]) << 56)
}

/* 全字段清零 frameInfo(C MEM_INIT 等价)—— 注意 ≠ LZ4F_frameInfo_t()
   结构体默认值(INIT_FRAMEINFO 的 blockSizeID 默认是 4 不是 0,
   lz4frame.c L1385)。 */
internal func lz4fZeroFrameInfo(): LZ4F_frameInfo_t {
    var fi = LZ4F_frameInfo_t()
    fi.blockSizeID = 0
    fi.blockMode = 0
    fi.contentChecksumFlag = 0
    fi.frameType = 0
    fi.contentSize = 0u64
    fi.dictID = 0u32
    fi.blockChecksumFlag = 0
    return fi
}

/* lz4fDecodeHeader(LZ4F_decodeHeader,lz4frame.c L1373-1464):解码帧头,
   设置 dctx 内部状态(frameInfo/dStage/maxBlockSize/内部缓冲目标),
   返回消费字节数(≤ srcSize)或负错误码。srcIsHeader 翻译 C 的
   `src == (void*)(dctx->header)` 指针比较(翻译表 ruling 9):
   storeFrameHeader 路径(源即 dctx.header)传 true;getFrameHeader
   捷径与 getFrameInfo 路径传 false。FUZZING 构建豁免魔数/HC 校验的
   ifdef 分支不移植(标准构建路径)。 */
internal func lz4fDecodeHeader(dctx: LZ4F_dctx, srcBuf: Array<UInt8>, srcIdx: Int64,
        srcSize: Int64, srcIsHeader: Bool): Int64 {
    if (srcSize < LZ4F_HEADER_SIZE_MIN) {                             /* L1382-1383 */
        return -LZ4F_ERROR_frameHeader_incomplete
    }
    dctx.frameInfo = lz4fZeroFrameInfo()                              /* L1385 MEM_INIT */

    /* L1388-1399:skippable 特判(低 4 位掩码) */
    if ((lz4fReadLE32(srcBuf, srcIdx) & 0xFFFFFFF0u32) == LZ4F_MAGIC_SKIPPABLE_START) {
        dctx.frameInfo.frameType = LZ4F_skippableFrame
        if (srcIsHeader) {                                            /* src == dctx->header */
            dctx.tmpInSize = srcSize                                  /* 怪癖:暂存已有字节数(保真点④) */
            dctx.tmpInTarget = 8
            dctx.dStage = dstage_storeSFrameSize
            return srcSize
        } else {
            dctx.dStage = dstage_getSFrameSize
            return 4
        }
    }

    /* L1401-1406:魔数校验 */
    if (lz4fReadLE32(srcBuf, srcIdx) != LZ4F_MAGICNUMBER) {
        return -LZ4F_ERROR_frameType_unknown
    }
    dctx.frameInfo.frameType = LZ4F_frame

    /* L1409-1421:FLG 位提取与校验(保留位检查先于版本号) */
    let FLG = UInt32(srcBuf[srcIdx + 4])
    let version = (FLG >> 6) & 3u32
    let blockChecksumFlag = (FLG >> 4) & 1u32
    let blockMode = (FLG >> 5) & 1u32
    let contentSizeFlag = (FLG >> 3) & 1u32
    let contentChecksumFlag = (FLG >> 2) & 1u32
    let dictIDFlag = FLG & 1u32
    if (((FLG >> 1) & 1u32) != 0u32) {                                /* L1418 */
        return -LZ4F_ERROR_reservedFlag_set
    }
    if (version != 1u32) {                                            /* L1419 */
        return -LZ4F_ERROR_headerVersion_wrong
    }

    /* L1424:帧头长度 */
    let frameHeaderSize = LZ4F_HEADER_SIZE_MIN + Int64(contentSizeFlag) * 8 +
        Int64(dictIDFlag) * 4

    if (srcSize < frameHeaderSize) {                                  /* L1426-1433:头不完整 */
        if (!srcIsHeader) {                                           /* srcPtr != dctx->header → memcpy */
            var i: Int64 = 0
            while (i < srcSize) {
                dctx.header[i] = srcBuf[srcIdx + i]
                i += 1
            }
        }
        dctx.tmpInSize = srcSize
        dctx.tmpInTarget = frameHeaderSize
        dctx.dStage = dstage_storeFrameHeader
        return srcSize
    }

    /* L1435-1441:BD 校验(先于 HC) */
    let BD = UInt32(srcBuf[srcIdx + 5])
    let blockSizeID = Int32((BD >> 4) & 7u32)
    if (((BD >> 7) & 1u32) != 0u32) {                                 /* L1438 */
        return -LZ4F_ERROR_reservedFlag_set
    }
    if (blockSizeID < 4) {                                            /* L1439 */
        return -LZ4F_ERROR_maxBlockSize_invalid
    }
    if ((BD & 15u32) != 0u32) {                                       /* L1440 */
        return -LZ4F_ERROR_reservedFlag_set
    }

    /* L1444-1449:头校验字节(HC = XXH32(FLG..) >> 8 低 8 位;源位置经
       XXH32 offset 重载,免切片) */
    let xxh = XXH32(srcBuf, frameHeaderSize - 5, 0u32, offset: srcIdx + 4)
    let HC = UInt8((xxh >> 8) & 0xFFu32)
    if (HC != srcBuf[srcIdx + frameHeaderSize - 1]) {
        return -LZ4F_ERROR_headerChecksum_invalid
    }

    /* L1452-1461:保存解码结果到 dctx */
    dctx.frameInfo.blockMode = Int32(blockMode)
    dctx.frameInfo.blockChecksumFlag = Int32(blockChecksumFlag)
    dctx.frameInfo.contentChecksumFlag = Int32(contentChecksumFlag)
    dctx.frameInfo.blockSizeID = blockSizeID
    dctx.maxBlockSize = LZ4F_getBlockSize(blockSizeID)
    if (contentSizeFlag != 0u32) {
        let csz = lz4fReadLE64(srcBuf, srcIdx + 6)
        dctx.frameInfo.contentSize = csz
        dctx.frameRemainingSize = csz
    }
    if (dictIDFlag != 0u32) {
        dctx.frameInfo.dictID = lz4fReadLE32(srcBuf, srcIdx + frameHeaderSize - 5)
    }

    dctx.dStage = dstage_init                                         /* L1463 */
    return frameHeaderSize                                            /* L1464 */
}

/* LZ4F_getFrameInfo(lz4frame.c L1512-1551)三岔,返回 (code/hint,
   frameInfo 拷贝, srcConsumed):
   - dStage>storeFrameHeader:已解码 → 不读输入(consumed=0),hint 取
     以空 dst/src 调 lz4fDecompressBody(C decompress(dctx,NULL,0,NULL,0,
     NULL) 等价,ruling 11)的返回码;
   - dStage==storeFrameHeader:头解码中途 → -19;
   - 否则:headerSize → 不足 -12 → decodeHeader → 成功 consumed=hSize、
     返回 BHSize=4,错误 consumed=0。
   frameInfo 无论如何都拷出(C 错误路径亦写 *frameInfoPtr;-19 岔 C 未写
   出参,仓颉元组恒携带,取 dctx 当前值)。C 的 frameInfoPtr/srcSizePtr
   NULL 检查在非空类型下 N/A。 */
public func LZ4F_getFrameInfo(dctx: LZ4F_dctx, srcBuf: Array<UInt8>, srcIdx: Int64,
        srcSize: Int64): (Int64, LZ4F_frameInfo_t, Int64) {
    if (dctx.dStage > dstage_storeFrameHeader) {                      /* L1525:已解码岔 */
        let empty = Array<UInt8>(0, {_ => 0u8})
        let (hint, _, _) = lz4fDecompressBody(dctx, empty, 0, 0, empty, 0, 0,
            LZ4F_decompressOptions_t())
        return (hint, dctx.frameInfo, 0)
    } else {
        if (dctx.dStage == dstage_storeFrameHeader) {                 /* L1531:中途岔 */
            return (-LZ4F_ERROR_frameDecoding_alreadyStarted, dctx.frameInfo, 0)
        } else {
            let hSize = LZ4F_headerSize(srcBuf, srcIdx, srcSize)      /* L1535 */
            if (LZ4F_isError(hSize)) {
                return (hSize, dctx.frameInfo, 0)
            }
            if (srcSize < hSize) {
                return (-LZ4F_ERROR_frameHeader_incomplete, dctx.frameInfo, 0)   /* L1539-1541 */
            }
            let decodeResult = lz4fDecodeHeader(dctx, srcBuf, srcIdx, hSize, false)   /* L1544 */
            if (LZ4F_isError(decodeResult)) {
                return (decodeResult, dctx.frameInfo, 0)
            }
            return (LZ4F_BLOCK_HEADER_SIZE, dctx.frameInfo, decodeResult)   /* L1547:decodeResult=BHSize */
        }
    }
}

/*-************************************
*  updateDict + 前缀谓词 (lz4frame.c L1558-1623)
**************************************/
/* lz4fDictPrefixAt:C `dict + dictSize == dstPtr` 前缀连续判定的内容窗口
   等价(翻译表 ruling 7):dictIdx+dictSize == dstPos 且尾部
   min(dictSize, 64KB) 字节逐字节相等。健全性(输出不变式):假阳性 ⇒
   历史字节相同 ⇒ 解码输出相同;假阴性 ⇒ 走 join-into-tmp 拷贝路径 ⇒
   输出相同仅性能差异。纯性能选择。dstPos-k ≥ 0 由 dictIdx ≥ 0 蕴含。 */
internal func lz4fDictPrefixAt(dctx: LZ4F_dctx, dstArr: Array<UInt8>, dstPos: Int64): Bool {
    if (dctx.dictBuf.size == 0 || dctx.dictSize <= 0) {
        return false
    }
    if (dctx.dictIdx + dctx.dictSize != dstPos) {
        return false
    }
    let k: Int64 = if (dctx.dictSize < 65536) { dctx.dictSize } else { 65536 }
    var i: Int64 = 0
    while (i < k) {
        if (dctx.dictBuf[dctx.dictIdx + dctx.dictSize - k + i] != dstArr[dstPos - k + i]) {
            return false
        }
        i += 1
    }
    return true
}

/* lz4fUpdateDict(LZ4F_updateDict,lz4frame.c L1558-1623,仅 linked 模式):
   五分支逐行。dstPos/dstBaseIdx = C dstPtr/dstBufferStart 在 dstBuf 内的
   索引;withinTmp = 本段内容同时在 tmpOutBuffer 中(flushOut 路径)。
   每次 dict 赋值点同步四元组 (dictBuf, dictIdx, dictSize, dictInTmp);
   dictInTmp=true 仅当 C 指针指向 tmpOutBuffer(不变量:dictInTmp ⇒
   dictIdx==0,C `dict == dctx->tmpOutBuffer` 指针相等即索引 0)。
   同缓冲内的拷贝(branch 6/截尾)源区间与目标区间按上游不变量 disjoint
   (linked 下 maxBufferSize ≥ 64KB+128KB),正向循环等价 memcpy。 */
internal func lz4fUpdateDict(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstPos: Int64,
        dstSize: Int64, dstBaseIdx: Int64, withinTmp: Bool): Unit {
    if (dctx.dictSize == 0) {                                         /* L1565:dict = dstPtr → prefix mode */
        dctx.dictBuf = dstBuf
        dctx.dictIdx = dstPos
        dctx.dictInTmp = false
    }

    /* L1568:dict + dictSize == dstPtr 前缀延展(指针比较 → 谓词;
       dictInTmp 时 C 指针比较对不同分配恒假,前置 !dictInTmp 对齐) */
    if (!dctx.dictInTmp && dctx.dictBuf.size != 0 &&
            lz4fDictPrefixAt(dctx, dstBuf, dstPos)) {
        dctx.dictSize += dstSize
        return
    }

    /* L1573-1577:dst 内历史 ≥ 64KB → dict = dstBufferStart */
    if (dstPos - dstBaseIdx + dstSize >= 65536) {
        dctx.dictBuf = dstBuf
        dctx.dictIdx = dstBaseIdx
        dctx.dictInTmp = false
        dctx.dictSize = (dstPos - dstBaseIdx) + dstSize
        return
    }

    /* L1582-1586:withinTmp && dict == tmpOutBuffer → tmp 内延展
       (withinTmp 期望:[dstPtr,dstSize) 内容与 [dict+dictSize,..) 相同) */
    if (withinTmp && dctx.dictInTmp) {
        dctx.dictSize += dstSize
        return
    }

    if (withinTmp) {                                                  /* L1588-1596:dict 相关段拷至 tmpOut 前 */
        let preserveSize = dctx.tmpOut                                /* tmpOut - tmpOutBuffer */
        var copySize = 65536 - dctx.tmpOutSize
        let oldDictEnd = dctx.dictIdx + dctx.dictSize - dctx.tmpOutStart   /* dict + dictSize - tmpOutStart */
        if (dctx.tmpOutSize > 65536) {
            copySize = 0
        }
        if (copySize > preserveSize) {
            copySize = preserveSize
        }
        var i: Int64 = 0
        while (i < copySize) {
            dctx.tmpOutBuffer[preserveSize - copySize + i] = dctx.dictBuf[oldDictEnd - copySize + i]
            i += 1
        }
        dctx.dictBuf = dctx.tmpOutBuffer
        dctx.dictIdx = 0
        dctx.dictInTmp = true
        dctx.dictSize = preserveSize + dctx.tmpOutStart + dstSize
        return
    }

    if (dctx.dictInTmp) {                                             /* L1598-1608:dict==tmpOutBuffer(非 withinTmp)→ dst 内容拷至 tmp 补全 */
        if (dctx.dictSize + dstSize > dctx.maxBufferSize) {           /* tmp 容量不足 → 保尾 64KB-dstSize */
            let preserveSize = 65536 - dstSize
            var i: Int64 = 0
            while (i < preserveSize) {
                dctx.tmpOutBuffer[i] = dctx.dictBuf[dctx.dictIdx + dctx.dictSize - preserveSize + i]
                i += 1
            }
            dctx.dictIdx = 0
            dctx.dictSize = preserveSize
        }
        var j: Int64 = 0
        while (j < dstSize) {                                         /* memcpy(tmpOutBuffer + dictSize, dstPtr, dstSize) */
            dctx.tmpOutBuffer[dctx.dictSize + j] = dstBuf[dstPos + j]
            j += 1
        }
        dctx.dictSize += dstSize
        return
    }

    /* L1611-1621:join dict & dst into tmp(终局分支) */
    var preserveSize = 65536 - dstSize
    if (preserveSize > dctx.dictSize) {
        preserveSize = dctx.dictSize
    }
    var i: Int64 = 0
    while (i < preserveSize) {
        dctx.tmpOutBuffer[i] = dctx.dictBuf[dctx.dictIdx + dctx.dictSize - preserveSize + i]
        i += 1
    }
    var j: Int64 = 0
    while (j < dstSize) {
        dctx.tmpOutBuffer[preserveSize + j] = dstBuf[dstPos + j]
        j += 1
    }
    dctx.dictBuf = dctx.tmpOutBuffer
    dctx.dictIdx = 0
    dctx.dictInTmp = true
    dctx.dictSize = preserveSize + dstSize
}

/*-************************************
*  块解码实例化(纯性能选择,输出不变式)
**************************************/
/* lz4fDecodeBlock:C LZ4_decompress_safe_usingDict(L1932/L1977 调用点)的
   实例化择取(翻译表 ruling 8),decodePos = 解码目标位置(dstBuf 内
   dstPos,或 tmpOutBuffer 内 tmpOut):
   - dict 空/size 0 → noDict(lowPrefixIdx=decodePos,dict None);
   - 前缀连续(lz4fDictPrefixAt 对实际解码目标缓冲判定)→ prefix 实例化
     (lowPrefixIdx = decodePos - (dictSize>=65535 ? 65536 : dictSize),
     镜像 lz4.cj rolling 分支钳制,dict None);
   - 否则 extDict(lowPrefixIdx=decodePos,dict=Some(dictBuf),
     dictStartIdx=dictIdx;dictSize > 1GB 截尾:dictIdx += dictSize-65536、
     dictSize=65536)。
   统一经 LZ4_decompress_generic(lz4.cj:1753),outputSize=maxBlockSize、
   partialDecoding=false;返回 <0 → 调用方报 -16 decompressionFailed。 */
private func lz4fDecodeBlock(dctx: LZ4F_dctx, selBuf: Array<UInt8>, selIdx: Int64,
        dstArr: Array<UInt8>, decodePos: Int64): Int64 {
    /* 偏差登记:C 从 selectedIn 原位解码;LZ4_decompress_generic 接口
       无 src 位置参数(dst 侧才有 dstIdx),src 中部的块经 tmpIn 暂存
       一次再从索引 0 解码(字节相同 ⇒ 输出等价,仅性能差异;
       tmpIn 容量 maxBlockSize+4 ≥ tmpInTarget 恒成立;selBuf==tmpIn
       的 storeCBlock 路径 selIdx==0 不经此拷贝)。 */
    var srcArr = selBuf
    if (selIdx != 0) {
        var i: Int64 = 0
        while (i < dctx.tmpInTarget) {
            dctx.tmpIn[i] = selBuf[selIdx + i]
            i += 1
        }
        srcArr = dctx.tmpIn
    }
    var lowPrefixIdx = decodePos
    var dictOpt = Option<Array<UInt8>>.None
    var dictStartIdx: Int64 = 0
    var dictSize = dctx.dictSize
    if (dctx.dictBuf.size != 0 && dictSize > 0) {
        if (lz4fDictPrefixAt(dctx, dstArr, decodePos)) {
            /* prefix 实例化(rolling 钳制) */
            lowPrefixIdx = decodePos - (if (dictSize >= 65535) { 65536 } else { dictSize })
        } else {
            /* extDict 实例化(>1GB 截尾,C 溢出控制) */
            if (dictSize > 1073741824) {
                dictStartIdx = dctx.dictIdx + dictSize - 65536
                dictSize = 65536
            } else {
                dictStartIdx = dctx.dictIdx
            }
            dictOpt = Some(dctx.dictBuf)
        }
    }
    return LZ4_decompress_generic(srcArr, dctx.tmpInTarget, dstArr, decodePos,
        dctx.maxBlockSize, false, lowPrefixIdx, dictOpt, dictStartIdx, dictSize)
}

/*-************************************
*  decompress 状态机 (lz4frame.c L1644-2147)
**************************************/
/* lz4fDecompressBody(LZ4F_decompress 主体,lz4frame.c L1644-2147):
   分片续传状态机,返回 (ret=hint/错误码, srcConsumed, dstWritten)。
   错误契约:C 入口即置 *srcSizePtr=0; *dstSizePtr=0,RETURN_ERROR 直返
   → 错误路径恒 (code, 0, 0),包括已部分消费/写出的调用(保真点①)。
   dst NULL 语义:C dstBuffer==NULL,*dstSizePtr==0 ⇔ 空数组 + dstIdx=0 +
   dstCapacity=0(翻译表 ruling 3)—— C 的全部 dstPtr==NULL 守卫在容量 0
   下算术自然归零(sizeToCopy=0、dstPtr==dstEnd),不设特判分支。
   srcPtr/dstPtr 以 srcPos/dstPos: Int64 游标表达;selectedIn 以
   (selBuf, selIdx) 对表达。结构:C 单 while(doAnotherStage) + switch
   以内层 while(true) 顺序分派直译 —— 每个 stage 块以
   {break(=C break switch)、doAnotherStage=false、错误直返} 之一出口;
   fall-through(getFrameHeader→storeFrameHeader、init→getBlockHeader、
   getCBlock→flushOut、以及 `if (dStage==dstage_storeX)` 可跳过式与
   `if (0)` 式)不 break,同迭代顺序落入下一 stage 块(保真点⑲)。 */
internal func lz4fDecompressBody(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64,
        dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64,
        dOpt: LZ4F_decompressOptions_t): (Int64, Int64, Int64) {
    let srcEndIdx = srcIdx + srcSize                                  /* L1647-1648 */
    let dstEndIdx = dstIdx + dstCapacity
    var srcPos = srcIdx
    var dstPos = dstIdx
    var selBuf: Array<UInt8> = srcBuf                                 /* selectedIn(读前必赋,占位初值) */
    var selIdx: Int64 = 0
    var doAnotherStage = true                                         /* L1651-1652 */
    var nextSrcSizeHint: Int64 = 1

    if (dOpt.skipChecksums != 0u32) {                                 /* L1672:skipChecksum 粘滞置位(至 reset) */
        dctx.skipChecksum = 1
    }

    while (doAnotherStage) {                                          /* L1673 */
        while (true) {    /* 单轮 switch 直译;break = C break switch 后回外层 while 重判 */
            if (dctx.dStage == dstage_getFrameHeader) {               /* L1678-1691 */
                if (srcEndIdx - srcPos >= LZ4F_HEADER_SIZE_MAX) {     /* ≥ maxFHSize=19 → 捷径 */
                    let hSize = lz4fDecodeHeader(dctx, srcBuf, srcPos, srcEndIdx - srcPos, false)
                    if (hSize < 0) {                                  /* FORWARD_IF_ERROR */
                        return (hSize, 0, 0)
                    }
                    srcPos += hSize
                    break
                }
                dctx.tmpInSize = 0
                if (srcEndIdx == srcPos) {                            /* L1686-1687:0 字节输入(保真点②:先于 storeFrameHeader,dStage 不变) */
                    return (LZ4F_HEADER_SIZE_MIN, 0, 0)
                }
                dctx.tmpInTarget = LZ4F_HEADER_SIZE_MIN
                dctx.dStage = dstage_storeFrameHeader
                /* fall-through L1691 */
            }
            if (dctx.dStage == dstage_storeFrameHeader) {             /* L1692-1706 */
                let sizeToCopy = if (dctx.tmpInTarget - dctx.tmpInSize < srcEndIdx - srcPos) {
                    dctx.tmpInTarget - dctx.tmpInSize
                } else {
                    srcEndIdx - srcPos
                }
                var i: Int64 = 0
                while (i < sizeToCopy) {
                    dctx.header[dctx.tmpInSize + i] = srcBuf[srcPos + i]
                    i += 1
                }
                dctx.tmpInSize += sizeToCopy
                srcPos += sizeToCopy
                if (dctx.tmpInSize < dctx.tmpInTarget) {              /* 头仍不完整 */
                    nextSrcSizeHint = (dctx.tmpInTarget - dctx.tmpInSize) +
                        LZ4F_BLOCK_HEADER_SIZE                        /* 剩余头 + 下一块头(保真点③) */
                    doAnotherStage = false
                    break
                }
                let hSize = lz4fDecodeHeader(dctx, dctx.header, 0, dctx.tmpInTarget, true)
                if (hSize < 0) {                                      /* FORWARD_IF_ERROR */
                    return (hSize, 0, 0)
                }
                break
            }
            if (dctx.dStage == dstage_init) {                         /* L1707-1730 */
                if (dctx.frameInfo.contentChecksumFlag != 0) {        /* L1712:xxh reset 仅 ccs 帧(保真点⑱) */
                    XXH32_reset(dctx.xxh, 0u32)
                }
                /* 内部缓冲分配(GC 模型不失败;容量不足才重分配) */
                let bufferNeeded = dctx.maxBlockSize +
                    (if (dctx.frameInfo.blockMode == LZ4F_blockLinked) { 131072 } else { 0 })
                if (bufferNeeded > dctx.maxBufferSize) {              /* L1716-1727 */
                    dctx.maxBufferSize = 0                            /* 下次进入时重试分配 */
                    dctx.tmpIn = Array<UInt8>(dctx.maxBlockSize +
                        LZ4F_BLOCK_CHECKSUM_SIZE, {_ => 0u8})
                    dctx.tmpOutBuffer = Array<UInt8>(bufferNeeded, {_ => 0u8})
                    dctx.maxBufferSize = bufferNeeded
                }
                dctx.tmpInSize = 0
                dctx.tmpInTarget = 0
                dctx.tmpOut = 0
                dctx.tmpOutStart = 0
                dctx.tmpOutSize = 0
                dctx.dStage = dstage_getBlockHeader
                /* fall-through L1730 */
            }
            if (dctx.dStage == dstage_getBlockHeader ||
                    dctx.dStage == dstage_storeBlockHeader) {         /* L1732-1781 簇 */
                if (dctx.dStage == dstage_getBlockHeader) {
                    if (srcEndIdx - srcPos >= LZ4F_BLOCK_HEADER_SIZE) {
                        selBuf = srcBuf                               /* 直读 */
                        selIdx = srcPos
                        srcPos += LZ4F_BLOCK_HEADER_SIZE
                    } else {
                        dctx.tmpInSize = 0                            /* 暂存于 tmpIn(保真点⑤) */
                        dctx.dStage = dstage_storeBlockHeader
                    }
                }
                if (dctx.dStage == dstage_storeBlockHeader) {         /* L1741 可跳过式:直读路径不进 */
                    let remainingInput = srcEndIdx - srcPos
                    let wantedData = LZ4F_BLOCK_HEADER_SIZE - dctx.tmpInSize
                    let sizeToCopy = if (wantedData < remainingInput) { wantedData } else { remainingInput }
                    var i: Int64 = 0
                    while (i < sizeToCopy) {
                        dctx.tmpIn[dctx.tmpInSize + i] = srcBuf[srcPos + i]
                        i += 1
                    }
                    srcPos += sizeToCopy
                    dctx.tmpInSize += sizeToCopy
                    if (dctx.tmpInSize < LZ4F_BLOCK_HEADER_SIZE) {    /* 输入不足 */
                        nextSrcSizeHint = LZ4F_BLOCK_HEADER_SIZE - dctx.tmpInSize
                        doAnotherStage = false
                        break
                    }
                    selBuf = dctx.tmpIn
                    selIdx = 0
                }   /* if (dStage == storeBlockHeader) */
                /* L1758-1781:块头解码(公共尾) */
                let blockHeader = lz4fReadLE32(selBuf, selIdx)
                let nextCBlockSize = Int64(blockHeader & 0x7FFFFFFFu32)
                let crcSize = Int64(dctx.frameInfo.blockChecksumFlag) * LZ4F_BLOCK_CHECKSUM_SIZE
                if (blockHeader == 0u32) {                            /* endmark → 帧尾 */
                    dctx.dStage = dstage_getSuffix
                    break
                }
                if (nextCBlockSize > dctx.maxBlockSize) {             /* 保真点⑥ */
                    return (-LZ4F_ERROR_maxBlockSize_invalid, 0, 0)
                }
                if ((blockHeader & 0x80000000u32) != 0u32) {          /* 未压缩块(保真点⑥) */
                    dctx.tmpInTarget = nextCBlockSize
                    if (dctx.frameInfo.blockChecksumFlag != 0) {
                        XXH32_reset(dctx.blockChecksum, 0u32)         /* 块校验流状态在此 reset */
                    }
                    dctx.dStage = dstage_copyDirect
                    break
                }
                /* 压缩块 */
                dctx.tmpInTarget = nextCBlockSize + crcSize
                dctx.dStage = dstage_getCBlock
                if (dstPos == dstEndIdx || srcPos == srcEndIdx) {     /* L1784-1787 早退 hint(保真点⑦) */
                    nextSrcSizeHint = LZ4F_BLOCK_HEADER_SIZE + nextCBlockSize + crcSize
                    doAnotherStage = false
                }
                break
            }
            if (dctx.dStage == dstage_copyDirect) {                   /* L1791-1828:未压缩块直拷 */
                /* C L1793-1795 dstPtr==NULL → sizeToCopy=0:空数组哨兵下
                   容量 0 算术归零,不特判(ruling 3) */
                let minBuffSize = if (srcEndIdx - srcPos < dstEndIdx - dstPos) {
                    srcEndIdx - srcPos
                } else {
                    dstEndIdx - dstPos
                }
                let sizeToCopy = if (dctx.tmpInTarget < minBuffSize) { dctx.tmpInTarget } else { minBuffSize }
                var i: Int64 = 0
                while (i < sizeToCopy) {
                    dstBuf[dstPos + i] = srcBuf[srcPos + i]
                    i += 1
                }
                if (dctx.skipChecksum == 0) {
                    if (dctx.frameInfo.blockChecksumFlag != 0) {
                        XXH32_update(dctx.blockChecksum, srcBuf, sizeToCopy, offset: srcPos)   /* 源字节(保真点⑨) */
                    }
                    if (dctx.frameInfo.contentChecksumFlag != 0) {
                        XXH32_update(dctx.xxh, srcBuf, sizeToCopy, offset: srcPos)
                    }
                }
                if (dctx.frameInfo.contentSize != 0u64) {
                    dctx.frameRemainingSize -= UInt64(sizeToCopy)
                }
                if (dctx.frameInfo.blockMode == LZ4F_blockLinked) {   /* 历史管理(仅 linked) */
                    lz4fUpdateDict(dctx, dstBuf, dstPos, sizeToCopy, dstIdx, false)
                }
                srcPos += sizeToCopy
                dstPos += sizeToCopy
                if (sizeToCopy == dctx.tmpInTarget) {                 /* 本块拷完 */
                    if (dctx.frameInfo.blockChecksumFlag != 0) {
                        dctx.tmpInSize = 0
                        dctx.dStage = dstage_getBlockChecksum
                    } else {
                        dctx.dStage = dstage_getBlockHeader
                    }
                    break
                }
                dctx.tmpInTarget -= sizeToCopy                        /* 未拷完,续 */
                nextSrcSizeHint = dctx.tmpInTarget +
                    (if (dctx.frameInfo.blockChecksumFlag != 0) { LZ4F_BLOCK_CHECKSUM_SIZE } else { 0 }) +
                    LZ4F_BLOCK_HEADER_SIZE
                doAnotherStage = false
                break
            }
            if (dctx.dStage == dstage_getBlockChecksum) {             /* L1834-1868 */
                var crcBuf: Array<UInt8> = srcBuf
                var crcIdx: Int64 = 0
                if (srcEndIdx - srcPos >= 4 && dctx.tmpInSize == 0) {
                    crcBuf = srcBuf                                   /* crcSrc = srcPtr 直读 */
                    crcIdx = srcPos
                    srcPos += 4
                } else {
                    let stillToCopy = 4 - dctx.tmpInSize
                    let remaining = srcEndIdx - srcPos
                    let sizeToCopy = if (stillToCopy < remaining) { stillToCopy } else { remaining }
                    var i: Int64 = 0
                    while (i < sizeToCopy) {                          /* 暂存于 header(保真点⑭) */
                        dctx.header[dctx.tmpInSize + i] = srcBuf[srcPos + i]
                        i += 1
                    }
                    dctx.tmpInSize += sizeToCopy
                    srcPos += sizeToCopy
                    if (dctx.tmpInSize < 4) {                         /* 输入吃尽;C 此处不改 hint(怪癖保留) */
                        doAnotherStage = false
                        break
                    }
                    crcBuf = dctx.header
                    crcIdx = 0
                }
                if (dctx.skipChecksum == 0) {
                    let readCRC = lz4fReadLE32(crcBuf, crcIdx)
                    let calcCRC = XXH32_digest(dctx.blockChecksum)
                    if (readCRC != calcCRC) {
                        return (-LZ4F_ERROR_blockChecksum_invalid, 0, 0)
                    }
                }
                dctx.dStage = dstage_getBlockHeader                   /* 新块 */
                break
            }
            if (dctx.dStage == dstage_getCBlock ||
                    dctx.dStage == dstage_storeCBlock) {              /* L1870-1996 簇 */
                if (dctx.dStage == dstage_getCBlock) {
                    if (srcEndIdx - srcPos < dctx.tmpInTarget) {
                        dctx.tmpInSize = 0
                        dctx.dStage = dstage_storeCBlock              /* 暂存于 tmpIn(保真点⑤) */
                    } else {
                        selBuf = srcBuf                               /* 整块直读 */
                        selIdx = srcPos
                        srcPos += dctx.tmpInTarget
                        /* C L1885 `if (0)`:恒跳过 storeCBlock */
                    }
                }
                if (dctx.dStage == dstage_storeCBlock) {              /* `if (0)`/暂存可跳过式 */
                    let wantedData = dctx.tmpInTarget - dctx.tmpInSize
                    let inputLeft = srcEndIdx - srcPos
                    let sizeToCopy = if (wantedData < inputLeft) { wantedData } else { inputLeft }
                    var i: Int64 = 0
                    while (i < sizeToCopy) {
                        dctx.tmpIn[dctx.tmpInSize + i] = srcBuf[srcPos + i]
                        i += 1
                    }
                    dctx.tmpInSize += sizeToCopy
                    srcPos += sizeToCopy
                    if (dctx.tmpInSize < dctx.tmpInTarget) {          /* 需要更多输入 */
                        nextSrcSizeHint = (dctx.tmpInTarget - dctx.tmpInSize) +
                            (if (dctx.frameInfo.blockChecksumFlag != 0) { LZ4F_BLOCK_CHECKSUM_SIZE } else { 0 }) +
                            LZ4F_BLOCK_HEADER_SIZE
                        doAnotherStage = false
                        break
                    }
                    selBuf = dctx.tmpIn
                    selIdx = 0
                }

                /* 至此输入足够解码一块:先块校验和(one-shot XXH32 覆盖
                   [selIdx, selIdx+tmpInTarget),tmpInTarget-=4 后尾 4B 为
                   存储 CRC;保真点⑧) */
                if (dctx.frameInfo.blockChecksumFlag != 0) {
                    dctx.tmpInTarget -= 4
                    let readBlockCrc = lz4fReadLE32(selBuf, selIdx + dctx.tmpInTarget)
                    let calcBlockCrc = XXH32(selBuf, dctx.tmpInTarget, 0u32, offset: selIdx)
                    if (readBlockCrc != calcBlockCrc) {
                        return (-LZ4F_ERROR_blockChecksum_invalid, 0, 0)
                    }
                }

                /* L1916-1951:dst 剩余 ≥ maxBlockSize 且字典不在 tmpOut 时
                   直接解码入 dst(decode-directly;保真点⑩:
                   dict+dictSize==tmpOut 例外按 dictInTmp 索引精确判定) */
                if (dstEndIdx - dstPos >= dctx.maxBlockSize &&
                        !(dctx.dictBuf.size != 0 && dctx.dictInTmp &&
                            dctx.dictIdx + dctx.dictSize == dctx.tmpOut)) {
                    let decodedSize = lz4fDecodeBlock(dctx, selBuf, selIdx, dstBuf, dstPos)
                    if (decodedSize < 0) {
                        return (-LZ4F_ERROR_decompressionFailed, 0, 0)
                    }
                    if (dctx.frameInfo.contentChecksumFlag != 0 && dctx.skipChecksum == 0) {
                        XXH32_update(dctx.xxh, dstBuf, decodedSize, offset: dstPos)   /* 解码后字节(保真点⑨) */
                    }
                    if (dctx.frameInfo.contentSize != 0u64) {
                        dctx.frameRemainingSize -= UInt64(decodedSize)
                    }
                    if (dctx.frameInfo.blockMode == LZ4F_blockLinked) {
                        lz4fUpdateDict(dctx, dstBuf, dstPos, decodedSize, dstIdx, false)
                    }
                    dstPos += decodedSize
                    dctx.dStage = dstage_getBlockHeader               /* 块完,取下一块头 */
                    break
                }

                /* dst 不足:解码入 tmpOut —— 先 dict 布置(保真点⑪) */
                if (dctx.frameInfo.blockMode == LZ4F_blockLinked) {
                    if (dctx.dictInTmp) {                             /* dict == tmpOutBuffer */
                        if (dctx.dictSize > 131072) {                 /* >128KB 截尾至 64KB */
                            var i: Int64 = 0
                            while (i < 65536) {
                                dctx.tmpOutBuffer[i] = dctx.dictBuf[dctx.dictIdx + dctx.dictSize - 65536 + i]
                                i += 1
                            }
                            dctx.dictSize = 65536                     /* dict 指针不动(dictIdx==0 不变量) */
                        }
                        dctx.tmpOut = dctx.dictSize                   /* tmpOut = tmpOutBuffer + dictSize */
                    } else {                                          /* dict 不在 tmp → 预留 min(dictSize,64KB) */
                        dctx.tmpOut = if (dctx.dictSize < 65536) { dctx.dictSize } else { 65536 }
                    }
                }

                /* 解码入 tmpOut(实例化对 tmpOutBuffer@tmpOut 判定) */
                let decodedSize2 = lz4fDecodeBlock(dctx, selBuf, selIdx, dctx.tmpOutBuffer, dctx.tmpOut)
                if (decodedSize2 < 0) {
                    return (-LZ4F_ERROR_decompressionFailed, 0, 0)
                }
                if (dctx.frameInfo.contentChecksumFlag != 0 && dctx.skipChecksum == 0) {
                    XXH32_update(dctx.xxh, dctx.tmpOutBuffer, decodedSize2, offset: dctx.tmpOut)
                }
                if (dctx.frameInfo.contentSize != 0u64) {
                    dctx.frameRemainingSize -= UInt64(decodedSize2)
                }
                dctx.tmpOutSize = decodedSize2
                dctx.tmpOutStart = 0
                dctx.dStage = dstage_flushOut
                /* fall-through L1996 */
            }
            if (dctx.dStage == dstage_flushOut) {                     /* L1992-2012:tmpOut → dst 冲刷 */
                /* C L2000 dstPtr!=NULL 守卫:容量 0 算术归零,不特判(ruling 3) */
                let sizeToCopy = if (dctx.tmpOutSize - dctx.tmpOutStart < dstEndIdx - dstPos) {
                    dctx.tmpOutSize - dctx.tmpOutStart
                } else {
                    dstEndIdx - dstPos
                }
                var i: Int64 = 0
                while (i < sizeToCopy) {
                    dstBuf[dstPos + i] = dctx.tmpOutBuffer[dctx.tmpOut + dctx.tmpOutStart + i]
                    i += 1
                }
                if (dctx.frameInfo.blockMode == LZ4F_blockLinked) {
                    lz4fUpdateDict(dctx, dstBuf, dstPos, sizeToCopy, dstIdx, true)   /* withinTmp=1(保真点⑫) */
                }
                dctx.tmpOutStart += sizeToCopy
                dstPos += sizeToCopy
                if (dctx.tmpOutStart == dctx.tmpOutSize) {            /* 冲刷完毕 */
                    dctx.dStage = dstage_getBlockHeader
                    break
                }
                doAnotherStage = false                               /* 冲刷不完:仅请求块头 */
                nextSrcSizeHint = LZ4F_BLOCK_HEADER_SIZE
                break
            }
            if (dctx.dStage == dstage_getSuffix ||
                    dctx.dStage == dstage_storeSuffix) {              /* L2014-2061 簇 */
                if (dctx.dStage == dstage_getSuffix) {
                    if (dctx.frameRemainingSize != 0u64) {            /* L2018:-14 先于 ccs 分支(保真点⑬) */
                        return (-LZ4F_ERROR_frameSize_wrong, 0, 0)
                    }
                    if (dctx.frameInfo.contentChecksumFlag == 0) {    /* 无 ccs:帧完成 */
                        nextSrcSizeHint = 0
                        LZ4F_resetDecompressionContext(dctx)
                        doAnotherStage = false
                        break
                    }
                    if (srcEndIdx - srcPos < 4) {                     /* ccs 字节不足 → 暂存 */
                        dctx.tmpInSize = 0
                        dctx.dStage = dstage_storeSuffix
                    } else {
                        selBuf = srcBuf
                        selIdx = srcPos
                        srcPos += 4
                    }
                }
                if (dctx.dStage == dstage_storeSuffix) {              /* 可跳过式;暂存于 tmpIn(保真点⑭) */
                    let remainingInput = srcEndIdx - srcPos
                    let wantedData = 4 - dctx.tmpInSize
                    let sizeToCopy = if (wantedData < remainingInput) { wantedData } else { remainingInput }
                    var i: Int64 = 0
                    while (i < sizeToCopy) {
                        dctx.tmpIn[dctx.tmpInSize + i] = srcBuf[srcPos + i]
                        i += 1
                    }
                    srcPos += sizeToCopy
                    dctx.tmpInSize += sizeToCopy
                    if (dctx.tmpInSize < 4) {                         /* 后缀不足 */
                        nextSrcSizeHint = 4 - dctx.tmpInSize
                        doAnotherStage = false
                        break
                    }
                    selBuf = dctx.tmpIn
                    selIdx = 0
                }   /* if (dStage == storeSuffix) */
                /* checkSuffix L2046-2061 */
                if (dctx.skipChecksum == 0) {
                    let readCRC = lz4fReadLE32(selBuf, selIdx)
                    let resultCRC = XXH32_digest(dctx.xxh)
                    if (readCRC != resultCRC) {
                        return (-LZ4F_ERROR_contentChecksum_invalid, 0, 0)
                    }
                }
                nextSrcSizeHint = 0
                LZ4F_resetDecompressionContext(dctx)
                doAnotherStage = false
                break
            }
            if (dctx.dStage == dstage_getSFrameSize ||
                    dctx.dStage == dstage_storeSFrameSize) {          /* L2063-2096 簇 */
                if (dctx.dStage == dstage_getSFrameSize) {
                    if (srcEndIdx - srcPos >= 4) {
                        selBuf = srcBuf
                        selIdx = srcPos
                        srcPos += 4
                    } else {
                        dctx.tmpInSize = 4                            /* 保真点④:header 已持 4B 魔数,不足时 tmpInSize=4 */
                        dctx.tmpInTarget = 8
                        dctx.dStage = dstage_storeSFrameSize
                    }
                }
                if (dctx.dStage == dstage_storeSFrameSize) {          /* 可跳过式;暂存于 header */
                    let remaining = srcEndIdx - srcPos
                    let wanted = dctx.tmpInTarget - dctx.tmpInSize
                    let sizeToCopy = if (wanted < remaining) { wanted } else { remaining }
                    var i: Int64 = 0
                    while (i < sizeToCopy) {
                        dctx.header[dctx.tmpInSize + i] = srcBuf[srcPos + i]
                        i += 1
                    }
                    srcPos += sizeToCopy
                    dctx.tmpInSize += sizeToCopy
                    if (dctx.tmpInSize < dctx.tmpInTarget) {          /* sBlockSize 不完整 */
                        nextSrcSizeHint = dctx.tmpInTarget - dctx.tmpInSize
                        doAnotherStage = false
                        break
                    }
                    selBuf = dctx.header
                    selIdx = 4                                        /* selectedIn = dctx->header + 4 */
                }   /* if (dStage == storeSFrameSize) */
                /* decodeSFrameSize L2090-2096(无直入) */
                let SFrameSize = Int64(lz4fReadLE32(selBuf, selIdx))
                dctx.frameInfo.contentSize = UInt64(SFrameSize)
                dctx.tmpInTarget = SFrameSize
                dctx.dStage = dstage_skipSkippable
                break
            }
            if (dctx.dStage == dstage_skipSkippable) {                /* L2098-2108 */
                let remaining = srcEndIdx - srcPos
                let skipSize = if (dctx.tmpInTarget < remaining) { dctx.tmpInTarget } else { remaining }
                srcPos += skipSize
                dctx.tmpInTarget -= skipSize
                doAnotherStage = false
                nextSrcSizeHint = dctx.tmpInTarget
                if (nextSrcSizeHint != 0) {                           /* 还有待跳字节 */
                    break
                }
                /* 帧跳完:为下一帧复位上下文 */
                LZ4F_resetDecompressionContext(dctx)
                break
            }
            break    /* 不可达:dStage ∈ [0,14] 全覆盖,防御退出 */
        }
    }

    /* L2112-2142:尾部历史保存(跨调用保留历史于 tmpOut)。
       条件翻译(翻译表):linked;dict 不在 tmp(dict != tmpOutBuffer ⇔
       !dictInTmp);dict 存在(dict != NULL ⇔ dictBuf.size != 0);
       !stableDst;stage 域 [init, getSuffix) ⇔ dStage ∈ [2,10)。 */
    if (dctx.frameInfo.blockMode == LZ4F_blockLinked &&
            dctx.dictBuf.size != 0 && !dctx.dictInTmp &&
            dOpt.stableDst == 0u32 &&
            dctx.dStage >= dstage_init && dctx.dStage < dstage_getSuffix) {
        if (dctx.dStage == dstage_flushOut) {                         /* L2122-2134:flushOut 特殊分支 */
            let preserveSize = dctx.tmpOut                            /* tmpOut - tmpOutBuffer */
            var copySize = 65536 - dctx.tmpOutSize
            let oldDictEnd = dctx.dictIdx + dctx.dictSize - dctx.tmpOutStart
            if (dctx.tmpOutSize > 65536) {
                copySize = 0
            }
            if (copySize > preserveSize) {
                copySize = preserveSize
            }
            var i: Int64 = 0
            while (i < copySize) {
                dctx.tmpOutBuffer[preserveSize - copySize + i] = dctx.dictBuf[oldDictEnd - copySize + i]
                i += 1
            }
            dctx.dictBuf = dctx.tmpOutBuffer
            dctx.dictIdx = 0
            dctx.dictInTmp = true
            dctx.dictSize = preserveSize + dctx.tmpOutStart
        } else {                                                      /* L2135-2142:其余分支 */
            let newDictSize = if (dctx.dictSize < 65536) { dctx.dictSize } else { 65536 }
            var i: Int64 = 0
            while (i < newDictSize) {
                dctx.tmpOutBuffer[i] = dctx.dictBuf[dctx.dictIdx + dctx.dictSize - newDictSize + i]
                i += 1
            }
            dctx.dictBuf = dctx.tmpOutBuffer
            dctx.dictIdx = 0
            dctx.dictInTmp = true
            dctx.dictSize = newDictSize
            dctx.tmpOut = newDictSize
        }
    }

    return (nextSrcSizeHint, srcPos - srcIdx, dstPos - dstIdx)        /* L2144-2147 */
}

/* LZ4F_decompress(lz4frame.c L1644-2147 公开包装):dOptPtr None → 零值
   options;skipChecksum 粘滞置位在 body 入口(L1672)。返回
   (hint/错误, srcConsumed, dstWritten)。 */
public func LZ4F_decompress(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64,
        dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64,
        dOptPtr: Option<LZ4F_decompressOptions_t>): (Int64, Int64, Int64) {
    let dOpt = match (dOptPtr) {
        case Some(o) => o
        case None => LZ4F_decompressOptions_t()                      /* MEM_INIT 零值 */
    }
    return lz4fDecompressBody(dctx, dstBuf, dstIdx, dstCapacity, srcBuf, srcIdx, srcSize, dOpt)
}

/* LZ4F_decompress_usingDict(lz4frame.c L2154-2167):dStage <= dstage_init
   (≤2,即帧未开始解码)才注入字典(dictBuf=dictBuffer/dictIdx=0/
   dictSize/dictInTmp=false);后直通 LZ4F_decompress。字典"C 须整帧
   存活"契约由仓颉 GC 引用天然满足(注释登记)。 */
public func LZ4F_decompress_usingDict(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64,
        dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64,
        dictBuffer: Array<UInt8>, dictSize: Int64,
        dOptPtr: Option<LZ4F_decompressOptions_t>): (Int64, Int64, Int64) {
    if (dctx.dStage <= dstage_init) {                                 /* L2160 */
        dctx.dictBuf = dictBuffer
        dctx.dictIdx = 0
        dctx.dictSize = dictSize
        dctx.dictInTmp = false
    }
    return LZ4F_decompress(dctx, dstBuf, dstIdx, dstCapacity, srcBuf, srcIdx, srcSize, dOptPtr)
}
