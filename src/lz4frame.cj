// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream lib/lz4frame.c + lib/lz4frame.h (frame format).
// M5 Task 1: 类型/枚举/错误族/边界数学 + cctx 生命周期骨架(尚无压缩逻辑;
// 压缩主体由 M5 后续任务落地)。
// M5 Task 2: compressBegin 家族 —— 帧头字节级编码 + cctx 双标记 ctx 管理
// + 缓冲管理(lz4frame.c L657-876)。

package lz4

/*-************************************
*  Version (lz4frame.h L87)
**************************************/
/* LZ4F_VERSION = 100(1.10.0 编码,lz4frame.h L87 LZ4F_VERSION)。 */
public const LZ4F_VERSION: UInt32 = 100u32

/*-************************************
*  帧格式常量(lz4frame.h L281-294 / L406-407)
**************************************/
/* 头长随参数变化:最小 7(魔数 4 + FLG 1 + BD 1 + HC 1),
   最大 19(+contentSize 8 +dictID 4)。 */
public const LZ4F_HEADER_SIZE_MIN: Int64 = 7
public const LZ4F_HEADER_SIZE_MAX: Int64 = 19
/* 块头 4 字节 LE(最高位标记未压缩块)。 */
public const LZ4F_BLOCK_HEADER_SIZE: Int64 = 4
/* 块尾校验 4 字节 LE。 */
public const LZ4F_BLOCK_CHECKSUM_SIZE: Int64 = 4
/* 帧内容校验 4 字节。 */
public const LZ4F_CONTENT_CHECKSUM_SIZE: Int64 = 4
/* 帧尾结束标记 4 字节(全零块头)。 */
public const LZ4F_ENDMARK_SIZE: Int64 = 4
/* 魔数与可跳帧前缀(lz4frame.h L406-407;skippable 常量 M6 解码侧消费,
   先行落位)。 */
public const LZ4F_MAGICNUMBER: UInt32 = 0x184D2204u32
public const LZ4F_MAGIC_SKIPPABLE_START: UInt32 = 0x184D2A50u32

/*-************************************
*  枚举常量族(lz4frame.h L143-167;仓颉无 C 值枚举,以 Int32 常量承载,
*  成员名逐字;设计 §4.5 类型条目注记)
**************************************/
/* LZ4F_blockSizeID_t(lz4frame.h L143-150) */
public const LZ4F_default: Int32 = 0
public const LZ4F_max64KB: Int32 = 4
public const LZ4F_max256KB: Int32 = 5
public const LZ4F_max1MB: Int32 = 6
public const LZ4F_max4MB: Int32 = 7

/* LZ4F_blockMode_t(lz4frame.h L153-156) */
public const LZ4F_blockLinked: Int32 = 0
public const LZ4F_blockIndependent: Int32 = 1

/* LZ4F_contentChecksum_t(lz4frame.h L159-162) */
public const LZ4F_noContentChecksum: Int32 = 0
public const LZ4F_contentChecksumEnabled: Int32 = 1

/* LZ4F_blockChecksum_t(lz4frame.h L130 附近,v1.8.2+) */
public const LZ4F_noBlockChecksum: Int32 = 0
public const LZ4F_blockChecksumEnabled: Int32 = 1

/* LZ4F_frameType_t(lz4frame.h L166-169) */
public const LZ4F_frame: Int32 = 0
public const LZ4F_skippableFrame: Int32 = 1

/* LZ4F_BLOCKSIZEID_DEFAULT(lz4frame.c L249)== LZ4F_max64KB */
internal const LZ4F_BLOCKSIZEID_DEFAULT: Int32 = LZ4F_max64KB

/*-************************************
*  错误码族(lz4frame.h L668-693 LZ4F_LIST_ERRORS 序;仓颉无值枚举,
*  以 Int64 常量承载——frame 错误按 size_t 数值语义走 Int64,设计 §4.7)
**************************************/
public const LZ4F_OK_NoError: Int64 = 0
public const LZ4F_ERROR_GENERIC: Int64 = 1
public const LZ4F_ERROR_maxBlockSize_invalid: Int64 = 2
public const LZ4F_ERROR_blockMode_invalid: Int64 = 3
public const LZ4F_ERROR_parameter_invalid: Int64 = 4
public const LZ4F_ERROR_compressionLevel_invalid: Int64 = 5
public const LZ4F_ERROR_headerVersion_wrong: Int64 = 6
public const LZ4F_ERROR_blockChecksum_invalid: Int64 = 7
public const LZ4F_ERROR_reservedFlag_set: Int64 = 8
public const LZ4F_ERROR_allocation_failed: Int64 = 9
public const LZ4F_ERROR_srcSize_tooLarge: Int64 = 10
public const LZ4F_ERROR_dstMaxSize_tooSmall: Int64 = 11
public const LZ4F_ERROR_frameHeader_incomplete: Int64 = 12
public const LZ4F_ERROR_frameType_unknown: Int64 = 13
public const LZ4F_ERROR_frameSize_wrong: Int64 = 14
public const LZ4F_ERROR_srcPtr_wrong: Int64 = 15
public const LZ4F_ERROR_decompressionFailed: Int64 = 16
public const LZ4F_ERROR_headerChecksum_invalid: Int64 = 17
public const LZ4F_ERROR_contentChecksum_invalid: Int64 = 18
public const LZ4F_ERROR_frameDecoding_alreadyStarted: Int64 = 19
public const LZ4F_ERROR_compressionState_uninitialized: Int64 = 20
public const LZ4F_ERROR_parameter_null: Int64 = 21
public const LZ4F_ERROR_io_write: Int64 = 22
public const LZ4F_ERROR_io_read: Int64 = 23
public const LZ4F_ERROR_maxCode: Int64 = 24

/* LZ4F_errorStrings[](lz4frame.c L287-289 LZ4F_GENERATE_STRING 展开):
   名字去 LZ4F_ 前缀,25 项,与错误码常量序一致。 */
internal let LZ4F_ERROR_NAMES: Array<String> = [
    "OK_NoError", "ERROR_GENERIC", "ERROR_maxBlockSize_invalid",
    "ERROR_blockMode_invalid", "ERROR_parameter_invalid",
    "ERROR_compressionLevel_invalid", "ERROR_headerVersion_wrong",
    "ERROR_blockChecksum_invalid", "ERROR_reservedFlag_set",
    "ERROR_allocation_failed", "ERROR_srcSize_tooLarge",
    "ERROR_dstMaxSize_tooSmall", "ERROR_frameHeader_incomplete",
    "ERROR_frameType_unknown", "ERROR_frameSize_wrong",
    "ERROR_srcPtr_wrong", "ERROR_decompressionFailed",
    "ERROR_headerChecksum_invalid", "ERROR_contentChecksum_invalid",
    "ERROR_frameDecoding_alreadyStarted",
    "ERROR_compressionState_uninitialized", "ERROR_parameter_null",
    "ERROR_io_write", "ERROR_io_read", "ERROR_maxCode"
]

/*-************************************
*  Error management (lz4frame.c L291-331)
**************************************/
/* LZ4F_isError(lz4frame.c L291-294):C 为无符号比较
   code > (size_t)(-LZ4F_ERROR_maxCode),即仅 (-24, 0) 的补码邻域为错误;
   有符号等价:code < 0 && code > -24。边沿:code==-24(= -maxCode 本身)
   非错误(上游行为,保留)。 */
public func LZ4F_isError(code: Int64): Bool {
    return code < 0 && code > -LZ4F_ERROR_maxCode
}

/* LZ4F_getErrorName(lz4frame.c L296-301):非错误返回统一提示串。 */
public func LZ4F_getErrorName(code: Int64): String {
    let codeError = "Unspecified error code"
    if (LZ4F_isError(code)) {
        return LZ4F_ERROR_NAMES[Int64(-code)]
    }
    return codeError
}

/* LZ4F_getErrorCode(lz4frame.c L303-307):非错误→0;错误→取负还原枚举序号。 */
public func LZ4F_getErrorCode(functionResult: Int64): Int64 {
    if (!LZ4F_isError(functionResult)) {
        return LZ4F_OK_NoError
    }
    return -functionResult
}

/* LZ4F_getVersion / LZ4F_compressionLevel_max(lz4frame.c L327-331)。 */
public func LZ4F_getVersion(): UInt32 {
    return LZ4F_VERSION
}

public func LZ4F_compressionLevel_max(): Int32 {
    return LZ4HC_CLEVEL_MAX
}

/*-************************************
*  getBlockSize (lz4frame.c L335-344)
**************************************/
public func LZ4F_getBlockSize(blockSizeID: Int32): Int64 {
    /* blockSizes[] = { 64 KB, 256 KB, 1 MB, 4 MB } */
    let blockSizes: Array<Int64> = [65536, 262144, 1048576, 4194304]

    var bsid = blockSizeID
    if (bsid == 0) {
        bsid = LZ4F_BLOCKSIZEID_DEFAULT                             /* L340 */
    }
    if (bsid < LZ4F_max64KB || bsid > LZ4F_max4MB) {
        return -LZ4F_ERROR_maxBlockSize_invalid                     /* L341-342 */
    }
    let blockSizeIdx = Int64(bsid - LZ4F_max64KB)                   /* L343 */
    return blockSizes[blockSizeIdx]
}

/*-************************************
*  Private functions (lz4frame.c L346-355)
**************************************/
/* LZ4F_headerChecksum(lz4frame.c L351-355):对魔数之后的头区域
   (FLG/BD/可选字段)计算 XXH32,取 (xxh >> 8) 的低 8 位。 */
internal func lz4fHeaderChecksum(header: Array<UInt8>, length: Int64): UInt8 {
    let xxh = XXH32(header, length, 0u32)
    return UInt8((xxh >> 8) & 0xFFu32)
}

/*-************************************
*  Simple-pass compression functions (lz4frame.c L357-418)
**************************************/
/* LZ4F_optimalBSID(lz4frame.c L361-373):为 srcSize 挑选不大于所需容量的
   最小块号。怪癖保留:requested==0 时循环体不进,原样返回 0(调用方
   compressBegin 侧另有 0→默认 代换)。 */
internal func lz4fOptimalBSID(requestedBSID: Int32, srcSize: Int64): Int32 {
    var proposedBSID = LZ4F_max64KB
    var maxBlockSize: Int64 = 65536
    while (requestedBSID > proposedBSID) {
        if (srcSize <= maxBlockSize) {
            return proposedBSID
        }
        proposedBSID += 1
        maxBlockSize <<= 2
    }
    return requestedBSID
}

/* lz4fCompressBoundInternal —— LZ4F_compressBound_internal
   (lz4frame.c L381-406):给定 srcSize 的最坏情况输出上界。
   prefs 为 None 时代入 LZ4F_INIT_PREFERENCES 副本并将 contentChecksumFlag /
   blockChecksumFlag 最坏置 1(L383-385);C 的 (size_t)-1 哨兵
   (public compressBound 非 autoFlush 路径)以 Int64.Max 传入;
   bufferedSize = min(alreadyBuffered, blockSize-1)(L391)。 */
internal func lz4fCompressBoundInternal(srcSize: Int64,
        prefs: Option<LZ4F_preferences_t>, alreadyBuffered: Int64): Int64 {
    var prefsNull = LZ4F_preferences_t()
    prefsNull.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled  /* worst case */
    prefsNull.frameInfo.blockChecksumFlag = LZ4F_blockChecksumEnabled      /* worst case */
    let p: LZ4F_preferences_t = match (prefs) {
        case Some(pr) => pr
        case None => prefsNull
    }
    /* BHSize=4(块头)、BFSize=4(块/帧校验尾) */
    let flush: Bool = (p.autoFlush != 0u32) || (srcSize == 0)       /* L387 */
    let blockSize = LZ4F_getBlockSize(p.frameInfo.blockSizeID)      /* L388 */
    let maxBuffered = blockSize - 1                                 /* L389 */
    let bufferedSize = if (alreadyBuffered < maxBuffered) { alreadyBuffered } else { maxBuffered }
    let maxSrcSize = srcSize + bufferedSize                         /* L392 */
    let nbFullBlocks = maxSrcSize / blockSize                       /* L393 */
    let partialBlockSize = maxSrcSize & (blockSize - 1)             /* L394 */
    let lastBlockSize = if (flush) { partialBlockSize } else { 0 }  /* L395 */
    let nbBlocks = nbFullBlocks + (if (lastBlockSize > 0) { 1 } else { 0 })  /* L396 */
    let blockCRCSize = 4 * Int64(p.frameInfo.blockChecksumFlag)     /* L398 */
    let frameEnd = 4 + Int64(p.frameInfo.contentChecksumFlag) * 4   /* L399 */
    return ((4 + blockCRCSize) * nbBlocks)
        + (blockSize * nbFullBlocks) + lastBlockSize + frameEnd     /* L401-403 */
}

/* LZ4F_compressFrameBound(lz4frame.c L408-418):maxFHSize=19(含全部可选
   字段的头最大长度)+ internal 上界。注意 None 时 C 走 MEM_INIT 零值 prefs
   (blockSizeID=0 等,零值≠INIT 默认),随后 autoFlush 强制 1(L413-416)。 */
public func LZ4F_compressFrameBound(srcSize: Int64,
        preferencesPtr: Option<LZ4F_preferences_t>): Int64 {
    let headerSize: Int64 = 19                                      /* maxFHSize */
    var prefs = LZ4F_preferences_t()
    match (preferencesPtr) {
        case Some(p) => prefs = p
        case None =>
            /* MEM_INIT 零值:仅 blockSizeID 与 INIT 默认(4)不同,置 0 */
            prefs.frameInfo.blockSizeID = 0
    }
    prefs.autoFlush = 1u32
    return headerSize + lz4fCompressBoundInternal(srcSize, prefs, 0)
}

/* LZ4F_compressBound(lz4frame.c L884-890,public):autoFlush 已置 1 的 prefs
   直接以 alreadyBuffered=0 求;否则以 (size_t)-1 哨兵(Int64.Max)求,
   令 bufferedSize 钳到 blockSize-1。本函数不可失败。 */
public func LZ4F_compressBound(srcSize: Int64,
        preferencesPtr: Option<LZ4F_preferences_t>): Int64 {
    match (preferencesPtr) {
        case Some(p) =>
            if (p.autoFlush != 0u32) {
                return lz4fCompressBoundInternal(srcSize, Some(p), 0)
            }
        case None => ()
    }
    return lz4fCompressBoundInternal(srcSize, preferencesPtr, Int64.Max)
}

/*-************************************
*  Structures (lz4frame.h L176-246)
**************************************/
/* LZ4F_frameInfo_t(lz4frame.h L176-187):默认值 = LZ4F_INIT_FRAMEINFO
   (lz4frame.h L186)。仓颉结构体无 C 联合/裸缓冲问题,可直接默认构造;
   reserved 字段仓颉侧省略(设计 §4.5 注记)。 */
public struct LZ4F_frameInfo_t {
    public var blockSizeID: Int32 = LZ4F_max64KB
    public var blockMode: Int32 = LZ4F_blockLinked
    public var contentChecksumFlag: Int32 = LZ4F_noContentChecksum
    public var frameType: Int32 = LZ4F_frame
    public var contentSize: UInt64 = 0u64
    public var dictID: UInt32 = 0u32
    public var blockChecksumFlag: Int32 = LZ4F_noBlockChecksum
    public init() {}
}

/* LZ4F_preferences_t(lz4frame.h L191-202):默认值 = LZ4F_INIT_PREFERENCES
   (lz4frame.h L201)。reserved[3] 省略(设计 §4.5 注记)。 */
public struct LZ4F_preferences_t {
    public var frameInfo: LZ4F_frameInfo_t = LZ4F_frameInfo_t()
    public var compressionLevel: Int32 = 0
    public var autoFlush: UInt32 = 0u32
    public var favorDecSpeed: UInt32 = 0u32
    public init() {}
}

/* LZ4F_compressOptions_t(lz4frame.h L242-246):reserved 省略(设计 §4.5 注记)。 */
public struct LZ4F_compressOptions_t {
    public var stableSrc: UInt32 = 0u32
    public init() {}
}

/*-************************************
*  LZ4F_CDict 占位(Task 4 完整化:fastCtx/HCCtx 预消化字典内容)
**************************************/
public class LZ4F_CDict {
    internal var dictContent: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})
    /* 预消化字典流(Task 4 的 createCDict 初始化;本任务仅作为
       lz4fInitStream 挂接目标存在,默认构造即可)。 */
    internal var fastCtx: LZ4_stream_t = LZ4_stream_t()
    internal var HCCtx: LZ4_streamHC_t = LZ4_streamHC_t()
}

/*-************************************
*  LZ4F_cctx (lz4frame.c L256-273 LZ4F_cctx_s)
**************************************/
/* 上游为堆分配 POD + cmem 自定义分配器;仓颉侧改为类承载(GC 模型,
   设计 §4.4 同 ruling)。tmpBuff 空 Array == C NULL;tmpIn 在 C 中是
   tmpBuff 内指针,这里改为偏移量(M3a 解码侧先例)。lz4CtxPtr 拆为
   lz4CtxFast / lz4CtxHC 两个 Option 字段 + lz4CtxAlloc/lz4CtxType 记账
   (0=none 1=fast 2=hc)。 */
public class LZ4F_cctx {
    internal var prefs: LZ4F_preferences_t = LZ4F_preferences_t()
    internal var version: UInt32 = 0
    internal var cStage: Int32 = 0                        // 0 未初始化 / 1 已 Begin
    internal var cdict: Option<LZ4F_CDict> = None
    internal var maxBlockSize: Int64 = 0
    internal var maxBufferSize: Int64 = 0
    internal var tmpBuff: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})  // 空 = C NULL
    internal var tmpIn: Int64 = 0                         // tmpBuff 内偏移
    internal var tmpInSize: Int64 = 0
    internal var totalInSize: UInt64 = 0
    internal var xxh: XXH32_state_t = XXH32_state_t()
    internal var lz4CtxFast: Option<LZ4_stream_t> = None
    internal var lz4CtxHC: Option<LZ4_streamHC_t> = None
    internal var lz4CtxAlloc: Int32 = 0                   // 0=none 1=fast 2=hc
    internal var lz4CtxType: Int32 = 0
    internal var blockCompressMode: Int32 = 0             // LZ4B_COMPRESSED
}

/* LZ4F_createCompressionContext(lz4frame.c L605-615 advanced / L626-636
   public):C 侧经出参返回 cctx + 错误码;仓颉侧直接返回实例(分配失败
   不存在,GC 模型)。version 仅存字段,不作校验(advanced 同样仅存储)。 */
public func LZ4F_createCompressionContext(version: UInt32): LZ4F_cctx {
    let cctx = LZ4F_cctx()
    cctx.version = version
    cctx.cStage = 0         /* Uninitialized. Next stage : init cctx (L613) */
    return cctx
}

/* LZ4F_freeCompressionContext(lz4frame.c L638-647):C 释放 lz4CtxPtr/
    tmpBuff/cctx 三段堆内存;仓颉由 GC 管理,无动作,恒返回 OK(0)。
    C 支持 free(NULL),仓颉侧无空引用,不设 None 分支。 */
public func LZ4F_freeCompressionContext(cctx: LZ4F_cctx): Int64 {
    return LZ4F_OK_NoError
}

/*-************************************
*  compressBegin 家族 (lz4frame.c L657-876)
**************************************/
/* lz4fInitStream —— LZ4F_initStream(lz4frame.c L657-683):为新一轮压缩
    准备内部 LZ4(HC) 流:复位上下文并挂接字典(如有)。linked 帧头调用
    一次;blockIndependent 模式逐块调用(M5 后续任务消费)。C 传 void* ctx
    单指针,仓颉侧按 cctx 拆分字段 + cctx.cdict(调用点刚完成赋值,
    L777 等价)。 */
internal func lz4fInitStream(cctx: LZ4F_cctx, level: Int32,
        blockMode: Int32): Unit {
    if (level < LZ4HC_CLEVEL_MIN) {                                  /* L660 */
        if (cctx.cdict.isSome() || blockMode == LZ4F_blockLinked) {  /* L661 */
            /* 此后走 LZ4_compress_fast_continue(),需要已复位的流;
               one-shot API 自带复位,此处复位属无效功(L662-666 注释
               语义照搬)。 */
            if (let Some(st) <- cctx.lz4CtxFast) {
                LZ4_resetStream_fast(st)                             /* L667 */
                if (let Some(cd) <- cctx.cdict) {
                    LZ4_attach_dictionary(st, cd.fastCtx)            /* L669 */
                }
            }
        }
    } else {
        if (let Some(st) <- cctx.lz4CtxHC) {
            LZ4_resetStreamHC_fast(st, level)                        /* L673 */
            if (let Some(cd) <- cctx.cdict) {
                LZ4_attach_HC_dictionary(st, cd.HCCtx)               /* L675 */
            }
        }
    }
}

/* lz4fCompressBeginInternal —— LZ4F_compressBegin_internal
    (lz4frame.c L706-830):写帧头 + cctx/缓冲/上下文三段管理。
    注:C 仅接受 cdict 与 dictBuffer 二者其一非空(L706 注释),
    assert(cdict == NULL)(L784),仓颉侧同样不设联合分支。 */
internal func lz4fCompressBeginInternal(cctx: LZ4F_cctx,
        dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64,
        dictBuffer: Option<Array<UInt8>>, dictSize: Int64,
        cdict: Option<LZ4F_CDict>,
        prefsPtr: Option<LZ4F_preferences_t>): Int64 {
    /* L710:dstCapacity < maxFHSize(19) -> dstMaxSize_tooSmall */
    if (dstCapacity < LZ4F_HEADER_SIZE_MAX) {
        return -LZ4F_ERROR_dstMaxSize_tooSmall
    }
    /* L716-718:prefsPtr == NULL 时代入 INIT 默认;值拷贝入 cctx.prefs
       (此后 C 经 preferencesPtr 的读取均与 cctx.prefs 等价)。 */
    var prefs = LZ4F_preferences_t()
    match (prefsPtr) {
        case Some(p) => prefs = p
        case None => ()
    }
    cctx.prefs = prefs                                             /* L718 */

    /* cctx Management(L722-752):ctxTypeID 1=fast 2=hc。C 以字节数比较
       (allocatedSize < requiredSize);尺寸随类型单调(0 < 16416 < 262200),
       等价于 lz4CtxAlloc < ctxTypeID 的标记比较。 */
    let ctxTypeID: Int32 = if (cctx.prefs.compressionLevel < LZ4HC_CLEVEL_MIN) {
        1
    } else {
        2
    }
    if (cctx.lz4CtxAlloc < ctxTypeID) {
        /* 空间不足:整体重分配。C 先 free 旧 lz4CtxPtr 再 malloc 新类型
           (L727);仓颉侧 = 目标类型建新对象、另一类型字段置 None
           (free 的镜像),双标记同步更新。 */
        if (ctxTypeID == 1) {
            cctx.lz4CtxHC = None                                   /* L727 镜像 */
            let st = LZ4_stream_t()
            LZ4_initStream(st)                                     /* L733 */
            cctx.lz4CtxFast = Some(st)
        } else {
            cctx.lz4CtxFast = None                                 /* L727 镜像 */
            let st = LZ4_streamHC_t()
            LZ4_initStreamHC(st)                                   /* L737 */
            cctx.lz4CtxHC = Some(st)
        }
        cctx.lz4CtxAlloc = ctxTypeID                               /* L740 */
        cctx.lz4CtxType = ctxTypeID                                /* L741 */
    } else if (cctx.lz4CtxType != ctxTypeID) {
        /* 空间已足但类型不符:原位复位为正确类型,仅更新类型标记
           (L743-750)。C 将同一块内存按新类型重解释(initStream 整表
           清零);仓颉侧以对应类型的类实例承载 —— Some 时原位 init、
           None 时新建,输出等价(设计 §4.4 偏差注记)。 */
        if (ctxTypeID == 1) {
            match (cctx.lz4CtxFast) {
                case Some(st) => LZ4_initStream(st)                 /* L746 */
                case None =>
                    let st = LZ4_stream_t()
                    LZ4_initStream(st)
                    cctx.lz4CtxFast = Some(st)
            }
        } else {
            match (cctx.lz4CtxHC) {
                case Some(st) =>
                    LZ4_initStreamHC(st)                            /* L749 */
                    LZ4_setCompressionLevel(st, cctx.prefs.compressionLevel)
                case None =>
                    let st = LZ4_streamHC_t()
                    LZ4_initStreamHC(st)
                    LZ4_setCompressionLevel(st, cctx.prefs.compressionLevel)
                    cctx.lz4CtxHC = Some(st)
            }
        }
        cctx.lz4CtxType = ctxTypeID                                /* L751 */
    }

    /* Buffer Management(L754-772) */
    if (cctx.prefs.frameInfo.blockSizeID == 0) {
        cctx.prefs.frameInfo.blockSizeID = LZ4F_BLOCKSIZEID_DEFAULT /* L755 */
    }
    cctx.maxBlockSize = LZ4F_getBlockSize(cctx.prefs.frameInfo.blockSizeID)
                                                                    /* L757 */
    let linked = cctx.prefs.frameInfo.blockMode == LZ4F_blockLinked
    let requiredBuffSize: Int64 = if (prefs.autoFlush != 0u32) {   /* L760 */
        if (linked) { 65536 } else { 0 }    /* 仅 linked 需 64KB 历史窗口 */
    } else {
        cctx.maxBlockSize + (if (linked) { 131072 } else { 0 })
    }
    if (cctx.maxBufferSize < requiredBuffSize) {
        cctx.maxBufferSize = 0                                     /* L764 */
        cctx.tmpBuff = Array<UInt8>(requiredBuffSize, {_ => 0u8})  /* L766 */
        cctx.maxBufferSize = requiredBuffSize                      /* L768 */
    }
    cctx.tmpIn = 0                                                 /* L770 */
    cctx.tmpInSize = 0                                             /* L771 */
    XXH32_reset(cctx.xxh, 0u32)                                    /* L772 */

    /* context init(L774-794) */
    cctx.cdict = cdict                                             /* L777 */
    if (cctx.prefs.frameInfo.blockMode == LZ4F_blockLinked) {
        /* 仅 blockLinked 帧级初始化;blockIndependent 逐块初始化 */
        lz4fInitStream(cctx, cctx.prefs.compressionLevel, LZ4F_blockLinked)
    }                                                              /* L778-780 */
    if (prefs.compressionLevel >= LZ4HC_CLEVEL_MIN) {
        if (let Some(hc) <- cctx.lz4CtxHC) {
            LZ4_favorDecompressionSpeed(hc, Int32(prefs.favorDecSpeed))
        }
    }                                                              /* L781-783 */
    match (dictBuffer) {
        case Some(dict) =>
            if (dictSize > Int64(Int32.Max)) {
                return -LZ4F_ERROR_parameter_invalid               /* L786 */
            }
            if (cctx.lz4CtxType == 1) {
                /* lz4 fast(L787-789) */
                if (let Some(st) <- cctx.lz4CtxFast) {
                    LZ4_loadDict(st, dict, Int32(dictSize))
                }
            } else {
                /* lz4hc(L790-793) */
                if (let Some(st) <- cctx.lz4CtxHC) {
                    LZ4_loadDictHC(st, dict, Int32(dictSize))
                }
            }
        case None => ()
    }

    /* Stage 2: Write Frame Header(L796-829);冷路径,安全索引直写 */

    /* Magic Number,LE32(L799) */
    var p = dstIdx
    dstBuf[p] = UInt8(LZ4F_MAGICNUMBER & 0xFFu32)
    dstBuf[p + 1] = UInt8((LZ4F_MAGICNUMBER >> 8) & 0xFFu32)
    dstBuf[p + 2] = UInt8((LZ4F_MAGICNUMBER >> 16) & 0xFFu32)
    dstBuf[p + 3] = UInt8((LZ4F_MAGICNUMBER >> 24) & 0xFFu32)
    p += 4
    let headerStart = p

    /* FLG Byte(L803-809):版本 '01' <<6 + 各单双位标志 */
    var flg: UInt32 = (1u32 & 0x3u32) << 6
    flg += UInt32(cctx.prefs.frameInfo.blockMode & 1) << 5
    flg += UInt32(cctx.prefs.frameInfo.blockChecksumFlag & 1) << 4
    flg += (if (cctx.prefs.frameInfo.contentSize > 0u64) { 1u32 } else { 0u32 }) << 3
    flg += UInt32(cctx.prefs.frameInfo.contentChecksumFlag & 1) << 2
    flg += if (cctx.prefs.frameInfo.dictID > 0u32) { 1u32 } else { 0u32 }
    dstBuf[p] = UInt8(flg)
    p += 1

    /* BD Byte(L810):块号低 3 位左移 4 */
    dstBuf[p] = UInt8(UInt32(cctx.prefs.frameInfo.blockSizeID & 7) << 4)
    p += 1

    /* Optional Frame content size field,LE64(L811-814);
       上游怪癖:仅此分支置 totalInSize = 0。 */
    if (cctx.prefs.frameInfo.contentSize != 0u64) {
        let csz = cctx.prefs.frameInfo.contentSize
        dstBuf[p] = UInt8(csz & 0xFFu64)
        dstBuf[p + 1] = UInt8((csz >> 8) & 0xFFu64)
        dstBuf[p + 2] = UInt8((csz >> 16) & 0xFFu64)
        dstBuf[p + 3] = UInt8((csz >> 24) & 0xFFu64)
        dstBuf[p + 4] = UInt8((csz >> 32) & 0xFFu64)
        dstBuf[p + 5] = UInt8((csz >> 40) & 0xFFu64)
        dstBuf[p + 6] = UInt8((csz >> 48) & 0xFFu64)
        dstBuf[p + 7] = UInt8((csz >> 56) & 0xFFu64)
        p += 8
        cctx.totalInSize = 0
    }

    /* Optional dictionary ID field,LE32(L815-818) */
    if (cctx.prefs.frameInfo.dictID != 0u32) {
        let did = cctx.prefs.frameInfo.dictID
        dstBuf[p] = UInt8(did & 0xFFu32)
        dstBuf[p + 1] = UInt8((did >> 8) & 0xFFu32)
        dstBuf[p + 2] = UInt8((did >> 16) & 0xFFu32)
        dstBuf[p + 3] = UInt8((did >> 24) & 0xFFu32)
        p += 4
    }

    /* Header CRC Byte(L820-821):魔数后区域的 (xxh >> 8) 低 8 位 */
    let hdrLen = p - headerStart
    let hdr = Array<UInt8>(hdrLen, {i => dstBuf[headerStart + i]})
    dstBuf[p] = lz4fHeaderChecksum(hdr, hdrLen)
    p += 1

    cctx.cStage = 1    /* header written, now request input data block(L826) */
    return p - dstIdx                                              /* L828 */
}

/* LZ4F_compressBegin(lz4frame.c L832-839):无字典直通 internal。 */
public func LZ4F_compressBegin(cctx: LZ4F_cctx, dstBuf: Array<UInt8>,
        dstIdx: Int64, dstCapacity: Int64,
        prefsPtr: Option<LZ4F_preferences_t>): Int64 {
    return lz4fCompressBeginInternal(cctx, dstBuf, dstIdx, dstCapacity,
        Option<Array<UInt8>>.None, 0, Option<LZ4F_CDict>.None, prefsPtr)
}

/* LZ4F_compressBegin_usingDict(lz4frame.c L855-866):经 usingDictOnce
    直通 internal(上游注释照搬:仅首块使用字典的已知不完整实现 ——
    独立块帧应逐块重挂字典,此处只挂一次)。 */
public func LZ4F_compressBegin_usingDict(cctx: LZ4F_cctx,
        dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64,
        dict: Array<UInt8>, dictSize: Int64,
        prefsPtr: Option<LZ4F_preferences_t>): Int64 {
    return lz4fCompressBeginInternal(cctx, dstBuf, dstIdx, dstCapacity,
        Some(dict), dictSize, Option<LZ4F_CDict>.None, prefsPtr)
}

/* LZ4F_compressBegin_usingCDict(lz4frame.c L868-876):cdict 透传。 */
public func LZ4F_compressBegin_usingCDict(cctx: LZ4F_cctx,
        dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64,
        cdict: Option<LZ4F_CDict>,
        prefsPtr: Option<LZ4F_preferences_t>): Int64 {
    return lz4fCompressBeginInternal(cctx, dstBuf, dstIdx, dstCapacity,
        Option<Array<UInt8>>.None, 0, cdict, prefsPtr)
}
