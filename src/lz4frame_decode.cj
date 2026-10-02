// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream lib/lz4frame.c + lib/lz4frame.h (frame format).
// M6 Task 1: 解压侧骨架 —— dStage 常量族 + LZ4F_dctx 生命周期
// (create/free/reset,lz4frame.c L1266-1341/L1354-1362)+ LZ4F_headerSize
// (L1471-1495)+ decompressOptions;解压状态机由 M6 后续任务落地。

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
