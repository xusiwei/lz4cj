// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

/*-************************************
*  Version
**************************************/
public const LZ4_VERSION_MAJOR: Int32 = 1
public const LZ4_VERSION_MINOR: Int32 = 10
public const LZ4_VERSION_RELEASE: Int32 = 0

public func LZ4_versionNumber(): Int32 {
    return LZ4_VERSION_MAJOR * 100 * 100 + LZ4_VERSION_MINOR * 100 + LZ4_VERSION_RELEASE
}

public func LZ4_versionString(): String {
    return "${LZ4_VERSION_MAJOR}.${LZ4_VERSION_MINOR}.${LZ4_VERSION_RELEASE}"
}

/*-************************************
*  Constants
**************************************/
public const LZ4_MAX_INPUT_SIZE: Int32 = 0x7E000000
public const LZ4_STREAMSIZE: Int32 = 16416

/*-************************************
*  Compression bound
**************************************/
public func LZ4_compressBound(inputSize: Int32): Int32 {
    if (inputSize < 0 || inputSize > LZ4_MAX_INPUT_SIZE) {
        return 0
    }
    return inputSize + inputSize / 255 + 16
}

/*-************************************
*  Streaming state
**************************************/
/* 上游为裸缓冲 + memset 的流状态;仓颉侧改为类承载(设计 §4.4),
    LZ4_STREAMSIZE/LZ4_sizeofState 保留为信息性常量。
    字典字段(dictionary/dictSize/dictCtx,上游 LZ4_stream_t_internal)M3b-T1
    落位:dictBuf/dictStartIdx 为引用对(controller ruling:不拷贝,saveDict
    显式拷贝);dictCtx 为外挂字典流(T3 的 usingDictCtx 消费)。 */
public class LZ4_stream_t {
    internal var hashTable: Array<UInt32> = Array<UInt32>(16384, {_ => 0u32})
    internal var currentOffset: UInt32 = 0u32
    internal var tableType: Int32 = 0
    internal var dictBuf: Option<Array<UInt8>> = None
    internal var dictStartIdx: Int64 = 0
    internal var dictSize: Int64 = 0
    internal var dictCtx: Option<LZ4_stream_t> = None
}

/* 上游 tableType_t 枚举(lz4.c L726:{clearedTable=0, byPtr, byU32, byU16})。
   byPtr(指针表)仅存在于 32 位平台 src>64KB 的场景,64 位构建不可达,
   此处仅保序占位(prepareTable 的 byPtr 复位条件按上游保留)。 */
internal const LZ4_TABLE_CLEARED: Int32 = 0
internal const LZ4_TABLE_BYPTR: Int32 = 1
internal const LZ4_TABLE_BYU32: Int32 = 2
internal const LZ4_TABLE_BYU16: Int32 = 3

public func LZ4_sizeofState(): Int32 {
    return LZ4_STREAMSIZE
}

public func LZ4_initStream(state: LZ4_stream_t): Int32 {
    var i: Int64 = 0
    while (i < state.hashTable.size) {
        state.hashTable[i] = 0u32
        i += 1
    }
    state.currentOffset = 0u32
    state.tableType = LZ4_TABLE_CLEARED
    state.dictBuf = None
    state.dictStartIdx = 0
    state.dictSize = 0
    state.dictCtx = None
    return 0
}

/* LZ4_createStream(lz4.c L1540-1549):分配 + initStream;仓颉由构造器
   分配(GC 管理),语义等价。 */
public func LZ4_createStream(): LZ4_stream_t {
    let s = LZ4_stream_t()
    LZ4_initStream(s)
    return s
}

/* LZ4_freeStream(lz4.c L1584-1591):C 释放堆内存返回 0(支持 NULL);
   仓颉无空引用、GC 回收,恒 0。 */
public func LZ4_freeStream(s: LZ4_stream_t): Int32 {
    return 0
}

/* LZ4_prepareTable(lz4.c L893-937):fastReset 家族的表保留决策。
   5 个复位条件(任一命中即 memset 表 + currentOffset=0 + tableType=
   clearedTable):tableType 不匹配 / byU16 且 currentOffset+inputSize
   >= 0xFFFF / byU32 且 currentOffset > 1GB / 请求 byPtr / inputSize
   >= 4KB;否则复用脏表。随后 byU32 且 currentOffset != 0 时加 64KB 间隔
   (陈旧登记相对新位置必超过 DISTANCE_MAX,恒被 too-far 检查拒绝,
   比清表更快);最后无条件清字典历史(dictCtx/dictBuf/dictSize)。
   clearedTable 直通:上游信任"表全零"标记,不复位。
   (unsigned)inputSize 以位模式转换复刻 C 的回绕语义。 */
internal func LZ4_prepareTable(state: LZ4_stream_t, inputSize: Int64, tableType: Int32): Unit {
    if (state.tableType != LZ4_TABLE_CLEARED) {                 /* L900 */
        if (state.tableType != tableType                        /* L902 */
            || ((tableType == LZ4_TABLE_BYU16)
                && state.currentOffset + UInt32(inputSize & 0xFFFFFFFFi64) >= 0xFFFFu32)  /* L903 */
            || ((tableType == LZ4_TABLE_BYU32)
                && state.currentOffset > 0x40000000u32)         /* L904: 1 GB */
            || tableType == LZ4_TABLE_BYPTR                     /* L905 */
            || inputSize >= 4096) {                             /* L906: 4 KB */
            var i: Int64 = 0
            while (i < state.hashTable.size) {
                state.hashTable[i] = 0u32
                i += 1
            }
            state.currentOffset = 0u32
            state.tableType = LZ4_TABLE_CLEARED
        }                                                       /* else: 复用脏表 */
    }
    if (state.currentOffset != 0u32 && tableType == LZ4_TABLE_BYU32) {   /* L918 */
        state.currentOffset += 65536u32                         /* L920: 64 KB gap */
    }
    state.dictCtx = None                                        /* L924-926: 清历史 */
    state.dictBuf = None
    state.dictStartIdx = 0
    state.dictSize = 0
}

/* LZ4_resetStream(lz4.c L1573-1577):MEM_INIT 整个内部结构 = 全量再初始化
   (与 initStream 等价,上游已弃用,推荐 initStream)。 */
public func LZ4_resetStream(s: LZ4_stream_t): Unit {
    LZ4_initStream(s)
}

/* LZ4_resetStream_fast(lz4.c L1579-1580):= LZ4_prepareTable(ctx, 0, byU32)。
   非全量复位:byU32 同型小偏移状态复用表并加 64KB 间隔。 */
public func LZ4_resetStream_fast(s: LZ4_stream_t): Unit {
    LZ4_prepareTable(s, 0, LZ4_TABLE_BYU32)
}

/*-************************************
*  Compression constants (lz4.c L243-264, L719-720; lz4.h L697-698)
**************************************/
internal const LZ4_MINMATCH: Int64 = 4        /* lz4.c L243 */
internal const LZ4_LASTLITERALS: Int64 = 5    /* lz4.c L246 */
internal const LZ4_MFLIMIT: Int64 = 12        /* lz4.c L247 */
internal const LZ4_minLength: Int64 = LZ4_MFLIMIT + 1   /* lz4.c L250: 13 */
internal const LZ4_ML_BITS: Int64 = 4         /* lz4.c L261 */
internal const LZ4_ML_MASK: Int64 = 15        /* (1<<ML_BITS)-1, lz4.c L262 */
internal const LZ4_RUN_MASK: Int64 = 15       /* (1<<(8-ML_BITS))-1, lz4.c L263-264: token 高 4 位 */
/* lz4.c L719: ((64 KB) + (MFLIMIT-1)) = 65547(64KB+12-1)。
   台账曾记 65538,系笔误;以公式与 C 实测为准(instrumented probe:
   inputSize=65537 → byU16=1,golden n=65537 行 size/digest 复现)。 */
internal const LZ4_64Klimit: Int64 = 65536 + LZ4_MFLIMIT - 1
internal const LZ4_skipTrigger: Int64 = 6     /* lz4.c L720 */
internal const LZ4_ACCELERATION_DEFAULT: Int32 = 1   /* lz4.c L52 */
internal const LZ4_ACCELERATION_MAX: Int32 = 65537   /* lz4.c L58 */
internal const LZ4_HASHLOG: Int64 = 12        /* lz4.h L697: LZ4_MEMORY_USAGE(14)-2 */
internal const LZ4_DISTANCE_MAX: UInt32 = 65535  /* lz4.h L676; == LZ4_DISTANCE_ABSOLUTE_MAX (L256) */

/* 上游 limitedOutput_directive 枚举(lz4.c L330-333):notLimited=0 / limitedOutput=1 /
   fillOutput=2。核心函数以 Int32 指令承载(仓台账风格),分支处逐行标注上游行号。 */
internal const LZ4_OUTPUT_NOT_LIMITED: Int32 = 0
internal const LZ4_OUTPUT_LIMITED: Int32 = 1
internal const LZ4_OUTPUT_FILL: Int32 = 2

/* 上游 dict_directive 枚举(lz4.c L751:{noDict=0, withPrefix64k, usingExtDict,
   usingDictCtx})。dictIssue_directive(L752:{noDictIssue=0, dictSmall})沿既有
   先例以 Bool 承载(dictSmall)。M3b:压缩核心字典分支(fast_continue 消费)。 */
internal const LZ4_DICT_NODICT: Int32 = 0
internal const LZ4_DICT_PREFIX64K: Int32 = 1
internal const LZ4_DICT_EXTDICT: Int32 = 2
internal const LZ4_DICT_DICTCTX: Int32 = 3

/*-************************************
*  Internal byte helpers ((p, i) idiom, common.cj style)
**************************************/
internal func LZ4_read8(p: CPointer<UInt8>, i: Int64): UInt8 {
    unsafe { return (p + i).read() }
}

internal func LZ4_write8(p: CPointer<UInt8>, i: Int64, v: UInt8): Unit {
    unsafe { (p + i).write(v) }
}

/*-************************************
*  Match counting (lz4.c L689-712)
**************************************/
/* LZ4_NbCommonBytes,little-endian 64-bit 路径(lz4.c L602-618 ctz 版):
   最低差异字节序号 = 尾零位数 / 8。diff != 0 由调用点保证。 */
internal func LZ4_nbCommonBytes(diff: UInt64): Int64 {
    var v = diff
    var n: Int64 = 0
    while ((v & 0xFFu64) == 0u64) {
        v >>= 8
        n += 1
    }
    return n
}

/* LZ4_count(lz4.c L689-712):noDict 下 pIn/pMatch 同属 src 缓冲,均用索引表示,
   读取不越过 pInLimit(STEPSIZE=8 粗对齐循环 + 4/2/1 字节收尾,L693-710)。 */
internal func LZ4_count(src: CPointer<UInt8>, pIn: Int64, pMatch: Int64, pInLimit: Int64): Int64 {
    let pStart = pIn
    var pin = pIn
    var pm = pMatch
    if (pin < pInLimit - 7) {                                          /* L693 (STEPSIZE-1) */
        let diff = LZ4_readLE64(src, pm) ^ LZ4_readLE64(src, pin)
        if (diff == 0u64) {
            pin += 8
            pm += 8
        } else {
            return LZ4_nbCommonBytes(diff)                             /* L698 */
        }
    }
    while (pin < pInLimit - 7) {                                       /* L701 */
        let diff = LZ4_readLE64(src, pm) ^ LZ4_readLE64(src, pin)
        if (diff == 0u64) {
            pin += 8
            pm += 8
            continue
        }
        pin += LZ4_nbCommonBytes(diff)                                 /* L704 */
        return pin - pStart
    }
    if ((pin < pInLimit - 3) && (LZ4_readLE32(src, pm) == LZ4_readLE32(src, pin))) {   /* L708 */
        pin += 4
        pm += 4
    }
    if ((pin < pInLimit - 1) && (LZ4_readLE16(src, pm) == LZ4_readLE16(src, pin))) {   /* L709 */
        pin += 2
        pm += 2
    }
    if ((pin < pInLimit) && (LZ4_read8(src, pm) == LZ4_read8(src, pin))) {             /* L710 */
        pin += 1
    }
    return pin - pStart
}

/* LZ4_count 的双缓冲变体(跨段 match 计数,L1182):序列 A = 当前块(ip 侧,
   srcQ 基),序列 B = 字典尾(match 侧,dictQ 基),推进限界 iLimit 作用于 A 侧
   —— 与 C 的 LZ4_count(ip+MINMATCH, match+MINMATCH, limit) 逐行同构,仅
   两个读指针分属不同缓冲。读界:iLimit ≤ min(offset, matchlimit) 推导
   B 侧读末端 ≤ dictQ+0(字典尾锚),绝不越过字典末尾(见核心注释)。 */
internal func LZ4_count2(a: CPointer<UInt8>, ia: Int64, b: CPointer<UInt8>, ib: Int64,
        iLimit: Int64): Int64 {
    let pStart = ia
    var pin = ia
    var pm = ib
    if (pin < iLimit - 7) {                                          /* L693 */
        let diff = LZ4_readLE64(b, pm) ^ LZ4_readLE64(a, pin)
        if (diff == 0u64) {
            pin += 8
            pm += 8
        } else {
            return LZ4_nbCommonBytes(diff)                           /* L698 */
        }
    }
    while (pin < iLimit - 7) {                                       /* L701 */
        let diff = LZ4_readLE64(b, pm) ^ LZ4_readLE64(a, pin)
        if (diff == 0u64) {
            pin += 8
            pm += 8
            continue
        }
        pin += LZ4_nbCommonBytes(diff)                               /* L704 */
        return pin - pStart
    }
    if ((pin < iLimit - 3) && (LZ4_readLE32(b, pm) == LZ4_readLE32(a, pin))) {   /* L708 */
        pin += 4
        pm += 4
    }
    if ((pin < iLimit - 1) && (LZ4_readLE16(b, pm) == LZ4_readLE16(a, pin))) {   /* L709 */
        pin += 2
        pm += 2
    }
    if ((pin < iLimit) && (LZ4_read8(b, pm) == LZ4_read8(a, pin))) {             /* L710 */
        pin += 1
    }
    return pin - pStart
}

/*-************************************
*  Hashing (lz4.c L786-815, 64-bit little-endian build)
**************************************/
/* LZ4_hashPosition:L808 —— 64 位平台上 byU32 走 LZ4_hash5(LZ4_read_ARCH)(L794-803
   LE 分支);byU16 走 LZ4_hash4(LZ4_read32)(L789,移位 (MINMATCH*8)-(LZ4_HASHLOG+1)=19)。
   返回值天然落在各自表视界内(byU32 < 4096,byU16 < 8192)。 */
internal func LZ4_hashPosition(src: CPointer<UInt8>, i: Int64, byU16: Bool): UInt32 {
    if (byU16) {
        /* L789: (sequence * 2654435761U) >> (32 - (LZ4_HASHLOG+1)) = >> 19 */
        return (LZ4_readLE32(src, i) * 2654435761u32) >> 19u32
    }
    /* L799: ((sequence << 24) * 889523592379ULL) >> (64 - LZ4_HASHLOG) = >> 52 */
    return UInt32(((LZ4_readLE64(src, i) << 24) * 889523592379u64) >> 52)
}

/*-************************************
*  Hash table views (controller ruling #1)
**************************************/
/* 上游表为 16 KB 字节缓冲,按 tableType 解释为 u32[4096](byU32)或 u16[8192](byU16)
   (LZ4_HASHTABLESIZE = 1<<14,lz4.h L698)。我们的 Array<UInt32>(16384) 容量相同但
   以 u32 计——槽位索引必须按 C 视界掩码:byU32 → h & 4095(LZ4_HASHLOG=12),
   byU16 → h & 8191(LZ4_HASHLOG+1=13)。byU16 写入值显式截断 & 0xFFFF
   (UInt32 单元承载 u16 截断+零扩展语义,L837 (U16)idx)。哈希函数输出本就落在
   视界内,掩码是防御性复刻,保证两种视界下碰撞行为与 C 完全一致。 */
internal func lz4GetIndexOnHash(table: Array<UInt32>, h: UInt32, byU16: Bool): UInt32 {
    if (byU16) {
        return table[Int64(h & 8191u32)]
    }
    return table[Int64(h & 4095u32)]
}

internal func lz4PutIndexOnHash(table: Array<UInt32>, idx: UInt32, h: UInt32, byU16: Bool): Unit {
    if (byU16) {
        table[Int64(h & 8191u32)] = idx & 0xFFFFu32
    } else {
        table[Int64(h & 4095u32)] = idx
    }
}

/* LZ4_clearHash(lz4.c L823-831):byU32/byU16 视界下写 0(槽位掩码同上,
   仅 fillOutput 缩短 match 后清除越界登记时调用,L1210-1215)。 */
internal func lz4ClearHash(table: Array<UInt32>, h: UInt32, byU16: Bool): Unit {
    if (byU16) {
        table[Int64(h & 8191u32)] = 0u32
    } else {
        table[Int64(h & 4095u32)] = 0u32
    }
}

/*-************************************
*  Compression core (lz4.c L939-1347, noDict + dict branches)
**************************************/
/* LZ4_compress_generic_validated 的移植:M3b 起覆盖上游全部四个 dict 分支
    (noDict / withPrefix64k / usingExtDict / usingDictCtx,lz4.c L751)× 
    byU16/byU32 × outputDirective(notLimited/limitedOutput/fillOutput)。C 的
    const 参数宏展开改用 Int32 指令 + Bool 显式分支,语义逐行对照;fillOutput
    专属分支(目标 dst 恰好填满,读入 src 前缀):L994 提前失败、L1127-1131/
    L1156-1161 中途退回 last_literals、L1198-1216 match 缩短 + 哈希清除、
    L1316-1320 lastRun 收缩。返回 (压缩字节数, srcConsumed):consumed 上游仅
    在 fillOutput 下写出(L1340-1342),此处统一返回 ip 终值(= anchor +
    lastRun,L1336,对非 fill 模式即完整 srcSize),由调用方按模式取用。
    位置模型:ip/matchPos 为相对本块基指针(srcQ = srcBuf 基 + srcIdx)的
    Int64 索引;哈希表登记/查询的是绝对索引 startIndex + i(L956: base =
    source - startIndex)。表内绝对 matchIndex 映射回当前坐标:
      matchPos = matchIndex - startIndex
    —— matchIndex ≥ startIndex 的候选位于本块内(matchPos ∈ [0, ip)); 
    matchIndex < startIndex 的候选位于前缀/字典(-k 处,k = startIndex -
    matchIndex 字节回溯):
      withPrefix64k(前缀同缓冲,dictEndIdx == srcIdx):单段读
        srcQ[matchPos](matchPos ∈ [-dictSize, 0) 落在 srcBuf[srcIdx-dictSize,
        srcIdx) 内,由 prefix 连续性保证界内);
      usingExtDict:字典侧读 dictQ[matchPos](dictQ = 自家字典缓冲基 +
        dictEndIdx,matchPos ∈ [-dictSize, 0) 即字典区间 [dictStartIdx,
        dictEndIdx));
      usingDictCtx:自家表未命中(matchIndex < startIndex,含空槽 0)时咨询
        dictCtx 表(L1071):mIdx(字典流坐标)→ matchPos = mIdx -
        dictCtx.currentOffset(dictCtx 字典尾锚定),matchIndex = mIdx +
        dictDelta(startIndex - dictCtx.currentOffset,L965)可比化后参与
        dictSmall/too-far 检查与 offset 计算(ip - matchPos == current -
        matchIndex,与上游 L1167 (U16)offset 逐字节一致)。
    读界不变量(上游守卫的精确复刻,UB-输入除外):
      too-far 检查(L1099/L1295:matchIndex + DISTANCE_MAX ≥ current)保留
      ≤ 65535 回溯;dictSmall 前缀界(L1097/L1294:matchIndex ≥ startIndex -
      dictSize)拒绝字典窗口之外的陈旧登记;noDictIssue 路径的不变量
      (dictSize ≥ 64KB 或 ≥ currentOffset)同样保证 startIndex - matchIndex
      ≤ dictSize。故字典侧/前缀侧读恒落在 [dictStartIdx, dictEndIdx) 内。
    跨段 match 延伸(L1177-1188):limit = ip + (dictEnd - match) = ip -
    matchPos(两量在 catch-up 中同步递减,保持恒等;数值上即 offset)→ 
    min(limit, matchlimit) 处切段,第二段自本块 0 位起单缓冲计数(L1185:
    match = source)。withPrefix64k 不切段(L1177 首条件限定 extDict/dictCtx)。
    goto _last_literals / _next_match 用标志位 + 标签循环重排,控制流等价。
    noDict 路径(M2 既有 48 测试的回归基线)与旧实现逐语句一致:新增分支均
    以 dictDirective 门控,无字典调用下 matchInDict 恒 false、lowPos 恒 0、
    候选读恒走 srcQ。 */
internal func LZ4_compress_generic_validated(
        state: LZ4_stream_t, srcQ: CPointer<UInt8>, n: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, outputDirective: Int32, acceleration: Int64,
        dictDirective: Int32, dictSmall: Bool,
        dictQ: CPointer<UInt8>, dictEntrySize: Int64,
        ctxDictQ: CPointer<UInt8>, ctxDictSize: Int64,
        ctxTable: Array<UInt32>, ctxCurrentOffset: UInt32): (Int64, Int64) {
    var ip: Int64 = 0                                  /* L953: ip = source */
    let startIndex: UInt32 = state.currentOffset       /* L955 */
    /* L962-963:字典大小按指令取自家入口值(dictEntrySize)或 dictCtx 字典
        (ctxDictSize);dictEntrySize 为调用时冻结的入口值,先于 L1006 的
        dictSize += inputSize。 */
    let dictSizeL: Int64 = if (dictDirective == LZ4_DICT_DICTCTX) { ctxDictSize } else { dictEntrySize }
    /* L965:dictDelta = startIndex - dictCtx->currentOffset(U32 回绕) */
    let dictDelta: UInt32 = startIndex - ctxCurrentOffset
    let prefixMode: Bool = dictDirective == LZ4_DICT_PREFIX64K
    /* 字典侧候选的读指针:usingDictCtx 读 dictCtx 字典尾,其余读自家字典尾
        (noDict 下不被解引用;withPrefix64k 的负位读走 srcQ 单段) */
    let dictReadQ: CPointer<UInt8> = if (dictDirective == LZ4_DICT_DICTCTX) { ctxDictQ } else { dictQ }
    /* L968: prefixIdxLimit = startIndex - dictSize(dictSize 取入口值,
        L1003/L1006 的 dictSize 更新在其后;prepareTable 已清 0 → 复用路径
        即 startIndex) */
    let prefixIdxLimit: UInt32 = startIndex - UInt32(dictSizeL & 0xFFFFFFFFi64)
    var anchor: Int64 = 0                              /* L970 */
    let iend: Int64 = n                                /* L971 */
    let mflimitPlusOne: Int64 = iend - LZ4_MFLIMIT + 1 /* L972 */
    let matchlimit: Int64 = iend - LZ4_LASTLITERALS    /* L973 */
    var op: Int64 = 0                                  /* L982: op = dest */
    let olimit: Int64 = dstCapacity                    /* L983 */
    var matchPos: Int64 = 0                            /* match = base + matchIndex */
    var matchInDict: Bool = false                      /* ⟺ C lowLimit == dictionary */
    var forwardH: UInt32 = 0
    /* C 的真值判断 if (outputDirective) 预展开 */
    let limited: Bool = outputDirective != LZ4_OUTPUT_NOT_LIMITED

    /* L994: fillOutput 且 maxOutputSize < 1 —— 无法写入任何内容(先于上下文更新) */
    if (outputDirective == LZ4_OUTPUT_FILL && dstCapacity < 1) {
        return (0, 0)
    }

    /* L999-1009: 更新上下文(usingDictCtx:dictCtx 摘除 + dictSize 重置为
        inputSize,L1003-1004;其余分支 dictSize += inputSize,L1006;tableType
        枚举值沿上游 {clearedTable=0, byPtr, byU32, byU16} → byU32=2 / byU16=3) */
    if (dictDirective == LZ4_DICT_DICTCTX) {
        state.dictCtx = None
        state.dictSize = n
    } else {
        state.dictSize += n
    }
    state.currentOffset = startIndex + UInt32(n)
    state.tableType = if (byU16) { LZ4_TABLE_BYU16 } else { LZ4_TABLE_BYU32 }

    var runMain = true
    var goLastLiterals = false
    if (n >= LZ4_minLength) {                          /* L1011: 小输入全 literal */
        /* First Byte (L1013-1020) */
        let h0 = LZ4_hashPosition(srcQ, ip, byU16)
        lz4PutIndexOnHash(state.hashTable, startIndex, h0, byU16)   /* L1018 */
        ip += 1
        forwardH = LZ4_hashPosition(srcQ, ip, byU16)    /* L1020 */

        while (runMain) {                              /* L1023 Main Loop */
            /* Find a match(L1049-1110,byU32/byU16 搜索分支) */
            var forwardIp: Int64 = ip                  /* L1051 */
            var step: Int64 = 1                        /* L1052 */
            var searchMatchNb: Int64 = acceleration << LZ4_skipTrigger   /* L1053 */
            do {
                let h: UInt32 = forwardH                /* L1055 */
                let current: UInt32 = startIndex + UInt32(forwardIp)   /* L1056(绝对索引) */
                var matchIndex: UInt32 = lz4GetIndexOnHash(state.hashTable, h, byU16)  /* L1057 */
                ip = forwardIp                          /* L1060 */
                forwardIp += step                       /* L1061 */
                step = searchMatchNb >> LZ4_skipTrigger /* L1062: step = searchMatchNb++ >> skipTrigger */
                searchMatchNb += 1
                if (forwardIp > mflimitPlusOne) {      /* L1064 */
                    goLastLiterals = true
                    break
                }
                /* L1067-1092: 候选解析 —— match = base/dictBase + matchIndex,
                    lowLimit 随候选落点改写(字典侧 = dictionary,本块侧 =
                    source;仓颉以 matchInDict + lowPos 表达) */
                if (dictDirective == LZ4_DICT_DICTCTX) {
                    if (matchIndex < startIndex) {      /* L1068: 自家表未命中 → 查 dictCtx 表 */
                        let mIdx: UInt32 = lz4GetIndexOnHash(ctxTable, h, byU16)   /* L1071 */
                        matchInDict = true              /* L1074: lowLimit = dictionary */
                        matchIndex = mIdx + dictDelta   /* L1073: 可比化 */
                        matchPos = Int64(mIdx) - Int64(ctxCurrentOffset)
                    } else {
                        matchInDict = false             /* L1077: lowLimit = source */
                        matchPos = Int64(matchIndex) - Int64(startIndex)
                    }
                } else if (dictDirective == LZ4_DICT_EXTDICT) {
                    matchInDict = matchIndex < startIndex   /* L1080/L1085 */
                    matchPos = Int64(matchIndex) - Int64(startIndex)
                } else {
                    /* L1091: 单段(noDict / withPrefix64k;后者的 matchPos
                        可为负 = 前缀内位置,读仍走 srcQ) */
                    matchInDict = false
                    matchPos = Int64(matchIndex) - Int64(startIndex)
                }
                forwardH = LZ4_hashPosition(srcQ, forwardIp, byU16)      /* L1093 */
                lz4PutIndexOnHash(state.hashTable, current, h, byU16)    /* L1094 */
                /* L1097: dictSmall —— matchIndex < prefixIdxLimit 的候选
                    (陈旧登记与空槽 0)在有效区之外,跳过 */
                if (dictSmall && matchIndex < prefixIdxLimit) {
                    continue
                }
                /* L1099-1102: too far——byU16 豁免(DISTANCE_MAX==ABSOLUTE_MAX),
                    byU32 跳过 matchIndex + 65535 < current 的候选 */
                if ((!byU16) && (matchIndex + LZ4_DISTANCE_MAX < current)) {
                    continue
                }
                /* L1105: read32 候选比较(字典侧候选读字典尾锚指针) */
                let candLE32: UInt32 = if (matchInDict) {
                    LZ4_readLE32(dictReadQ, matchPos)
                } else {
                    LZ4_readLE32(srcQ, matchPos)
                }
                if (candLE32 == LZ4_readLE32(srcQ, ip)) {
                    break                               /* L1107: match found */
                }
            } while (true)
            if (goLastLiterals) {                       /* goto _last_literals */
                break
            }

            /* L1114: filledIp = ip —— 本轮主循环已登记进哈希表的最远位置,
                fillOutput 缩短 match 后清除越界登记的上界(L1204-1215) */
            let filledIp: Int64 = ip

            /* Catch up(L1113-1118;lowLimit = source - (withPrefix64k ?
                dictSize : 0)(L997)——块相对坐标即前缀侧候选边界 -dictSizeL;
                字典侧候选的 lowLimit = dictionary(dict 缓冲底)同为
                -dictSizeL;本块侧候选 lowLimit = source → 0。noDict 下
                matchPos > 0 与上游 match > source 逐位一致) */
            let lowPos: Int64 = if (matchInDict || prefixMode) { -dictSizeL } else { 0 }
            let matchReadQ: CPointer<UInt8> = if (matchInDict) { dictReadQ } else { srcQ }
            if ((matchPos > lowPos) && (LZ4_read8(matchReadQ, matchPos - 1) == LZ4_read8(srcQ, ip - 1))) {
                do {
                    ip -= 1
                    matchPos -= 1
                } while ((ip > anchor) && (matchPos > lowPos) &&
                    (LZ4_read8(matchReadQ, matchPos - 1) == LZ4_read8(srcQ, ip - 1)))
            }

            /* Encode Literals(L1120-1145) */
            var tokenIdx: Int64
            let litLength: Int64 = ip - anchor         /* L1121 */
            tokenIdx = op
            op += 1                                    /* L1122: token = op++ */
            if (outputDirective == LZ4_OUTPUT_LIMITED &&   /* L1123-1126: 溢出检查 */
                    (op + litLength + (2 + 1 + LZ4_LASTLITERALS) + litLength / 255 > olimit)) {
                return (0, 0)
            }
            /* L1127-1131(fillOutput):剩余空间不足以容纳 本序列 + 最小尾字面量 */
            if (outputDirective == LZ4_OUTPUT_FILL &&
                    (op + (litLength + 240) / 255 /* litlen 扩展字节 */ + litLength /* literals */ +
                    2 /* offset */ + 1 /* token */ + LZ4_MFLIMIT - LZ4_MINMATCH /* min last literals */ > olimit)) {
                op -= 1                                 /* L1129: 撤回 token 字节 */
                goLastLiterals = true                   /* L1130: goto _last_literals */
                break
            }
            if (litLength >= LZ4_RUN_MASK) {           /* L1132-1137: 255 进位扩展字节 */
                var len: Int64 = litLength - LZ4_RUN_MASK
                LZ4_write8(dst, tokenIdx, UInt8((LZ4_RUN_MASK << LZ4_ML_BITS) & 0xFF))
                while (len >= 255) {
                    LZ4_write8(dst, op, 255u8)
                    op += 1
                    len -= 255
                }
                LZ4_write8(dst, op, UInt8(len))
                op += 1
            } else {
                LZ4_write8(dst, tokenIdx, UInt8(litLength << LZ4_ML_BITS))   /* L1138 */
            }
            LZ4_wildCopy8(dst, op, srcQ, anchor, litLength)                    /* L1141 */
            op += litLength                                                   /* L1142 */

            /* _next_match(L1147):offset + match length;"test next position"
               命中时已写好全零 token,回到此处(跳过搜索与 literal 编码) */
            var inMatch = true
            while (inMatch) {
                /* L1156-1161(fillOutput):match 距输出末尾过近,回退整个 token
                   (含已写字面量段)后转 last_literals */
                if (outputDirective == LZ4_OUTPUT_FILL &&
                        (op + 2 /* offset */ + 1 /* token */ +
                            LZ4_MFLIMIT - LZ4_MINMATCH /* min last literals */ > olimit)) {
                    op = tokenIdx                       /* L1159: op = token */
                    goLastLiterals = true              /* L1160: goto _last_literals */
                    break
                }

                /* Encode Offset(L1163-1172):maybe_extMem 路径写 find 时算得
                    的 offset(= current - matchIndex),同段路径写 ip - match;
                    两者在本位置模型下同为 ip - matchPos(catch-up 同步增减,
                    恒等于 find 时的 offset),单一表达式覆盖全部分支 */
                LZ4_writeLE16(dst, op, UInt16(ip - matchPos))                    /* L1167/L1171 */
                op += 2

                /* Encode MatchLength(L1174-1235) */
                var matchCode: Int64
                if (matchInDict) {
                    /* L1177-1188:跨段 match(起点在外字典)—— 字典内段计数至
                        limit = ip + (dictEnd - match) = ip - matchPos(即 offset,
                        字典耗尽的对齐位置),截到 matchlimit;恰好吃尽则第二段
                        自本块 0 位继续(L1185: match = source,与本块起点对齐
                        即 distance-offset 处) */
                    var limitPos: Int64 = ip - matchPos
                    if (limitPos > matchlimit) {
                        limitPos = matchlimit
                    }
                    matchCode = LZ4_count2(srcQ, ip + LZ4_MINMATCH,
                        dictReadQ, matchPos + LZ4_MINMATCH, limitPos)            /* L1182 */
                    ip += matchCode + LZ4_MINMATCH                               /* L1183 */
                    if (ip == limitPos) {
                        let more: Int64 = LZ4_count(srcQ, limitPos, 0, matchlimit)   /* L1185 */
                        matchCode += more
                        ip += more
                    }
                } else {
                    matchCode = LZ4_count(srcQ, ip + LZ4_MINMATCH,
                        matchPos + LZ4_MINMATCH, matchlimit)                     /* L1191 */
                    ip += matchCode + LZ4_MINMATCH                               /* L1192 */
                }
                if (limited &&                                               /* L1196-1197 */
                        (op + (1 + LZ4_LASTLITERALS) + (matchCode + 240) / 255 > olimit)) {
                    if (outputDirective == LZ4_OUTPUT_FILL) {
                        /* L1198-1216: match 描述过长,按剩余空间缩短 */
                        let newMatchCode: Int64 =
                            15 /* in token */ - 1 /* 避免零字节 */ + (olimit - op - 1 - LZ4_LASTLITERALS) * 255
                        ip -= matchCode - newMatchCode
                        matchCode = newMatchCode
                        if (ip <= filledIp) {                                 /* L1204 */
                            /* 回退越过已登记位置:清除 [ip, filledIp] 的哈希登记,
                               避免表中残留超前索引(状态复用时会误匹配) */
                            var ptr: Int64 = ip
                            while (ptr <= filledIp) {
                                let hClear = LZ4_hashPosition(srcQ, ptr, byU16)
                                lz4ClearHash(state.hashTable, hClear, byU16)
                                ptr += 1
                            }
                        }
                    } else {
                        return (0, 0)                                        /* L1219 */
                    }
                }
                if (matchCode >= LZ4_ML_MASK) {                               /* L1222-1232 */
                    LZ4_write8(dst, tokenIdx, LZ4_read8(dst, tokenIdx) + UInt8(LZ4_ML_MASK))
                    matchCode -= LZ4_ML_MASK
                    LZ4_writeLE32(dst, op, 0xFFFFFFFFu32)                      /* L1225 */
                    while (matchCode >= 4 * 255) {                             /* L1226-1230 */
                        op += 4
                        LZ4_writeLE32(dst, op, 0xFFFFFFFFu32)
                        matchCode -= 4 * 255
                    }
                    op += matchCode / 255                                      /* L1231 */
                    LZ4_write8(dst, op, UInt8(matchCode % 255))                /* L1232 */
                    op += 1
                } else {
                    LZ4_write8(dst, tokenIdx, LZ4_read8(dst, tokenIdx) + UInt8(matchCode))  /* L1234 */
                }

                anchor = ip                                                   /* L1239 */

                /* Test end of chunk(L1242):退出主循环 → _last_literals */
                if (ip >= mflimitPlusOne) {
                    runMain = false
                    break
                }

                /* Fill table(L1244-1251):位置 ip-2(绝对索引,L1248 idx = (ip-2)-base) */
                let hFill = LZ4_hashPosition(srcQ, ip - 2, byU16)
                lz4PutIndexOnHash(state.hashTable, startIndex + UInt32(ip - 2), hFill, byU16)

                /* Test next position(L1253-1303,byU32/byU16 分支) */
                let hNext = LZ4_hashPosition(srcQ, ip, byU16)                  /* L1264 */
                let current2: UInt32 = startIndex + UInt32(ip)                /* L1265(绝对索引) */
                var matchIndex2: UInt32 = lz4GetIndexOnHash(state.hashTable, hNext, byU16)  /* L1266 */
                /* L1268-1291:候选解析(与搜索循环 L1067-1092 同构) */
                if (dictDirective == LZ4_DICT_DICTCTX) {
                    if (matchIndex2 < startIndex) {
                        let mIdx2: UInt32 = lz4GetIndexOnHash(ctxTable, hNext, byU16)   /* L1272 */
                        matchInDict = true               /* L1274: lowLimit = dictionary */
                        matchIndex2 = mIdx2 + dictDelta  /* L1275 */
                        matchPos = Int64(mIdx2) - Int64(ctxCurrentOffset)
                    } else {
                        matchInDict = false              /* L1278: lowLimit = source */
                        matchPos = Int64(matchIndex2) - Int64(startIndex)
                    }
                } else if (dictDirective == LZ4_DICT_EXTDICT) {
                    matchInDict = matchIndex2 < startIndex
                    matchPos = Int64(matchIndex2) - Int64(startIndex)          /* L1283/L1286 */
                } else {
                    matchInDict = false
                    matchPos = Int64(matchIndex2) - Int64(startIndex)          /* L1290 */
                }
                lz4PutIndexOnHash(state.hashTable, current2, hNext, byU16)    /* L1292 */
                /* L1294-1296:dictSmall 前缀界检查;byU16 距离检查恒真(表内索引
                    本就 < 65536),byU32 要求 matchIndex + 65535 >= current */
                let cand2LE32: UInt32 = if (matchInDict) {
                    LZ4_readLE32(dictReadQ, matchPos)
                } else {
                    LZ4_readLE32(srcQ, matchPos)
                }
                if ((!dictSmall || matchIndex2 >= prefixIdxLimit) &&
                        (byU16 || (matchIndex2 + LZ4_DISTANCE_MAX >= current2)) &&
                        (cand2LE32 == LZ4_readLE32(srcQ, ip))) {
                    tokenIdx = op                                              /* L1297: token = op++ */
                    op += 1
                    LZ4_write8(dst, tokenIdx, 0u8)                             /* L1298: *token = 0 */
                    continue                                                   /* L1302: goto _next_match */
                }

                /* Prepare next loop(L1307) */
                ip += 1
                forwardH = LZ4_hashPosition(srcQ, ip, byU16)
                inMatch = false
            }
            if (goLastLiterals) {                /* fillOutput L1160 的中途退出 */
                break
            }
            if (!runMain) {
                break
            }
        }
    }

    /* _last_literals(L1311-1338) */
    var lastRun: Int64 = iend - anchor                   /* L1313 */
    if (limited &&                                       /* L1314-1315 */
            (op + lastRun + 1 + (lastRun + 255 - LZ4_RUN_MASK) / 255 > olimit)) {
        if (outputDirective == LZ4_OUTPUT_FILL) {
            /* L1316-1320: 收缩 lastRun 以恰好填满 dst */
            lastRun = (olimit - op) - 1                  /* 减 token 字节 */
            lastRun -= (lastRun + 256 - LZ4_RUN_MASK) / 256   /* 额外长度字节 */
        } else {
            return (0, 0)                                /* L1323 */
        }
    }
    if (lastRun >= LZ4_RUN_MASK) {                       /* L1327-1331 */
        var accumulator: Int64 = lastRun - LZ4_RUN_MASK
        LZ4_write8(dst, op, UInt8((LZ4_RUN_MASK << LZ4_ML_BITS) & 0xFF))
        op += 1
        while (accumulator >= 255) {
            LZ4_write8(dst, op, 255u8)
            op += 1
            accumulator -= 255
        }
        LZ4_write8(dst, op, UInt8(accumulator))
        op += 1
    } else {
        LZ4_write8(dst, op, UInt8(lastRun << LZ4_ML_BITS))   /* L1333 */
        op += 1
    }
    LZ4_memcpyPtr(dst, op, srcQ, anchor, lastRun)             /* L1335 */
    ip = anchor + lastRun                                   /* L1336(上游无条件) */
    op += lastRun
    return (op, ip)                                         /* L1340-1343(consumed 即 ip) */
}

/* LZ4_compress_generic 包装(lz4.c L1353-1388):srcSize 校验与空输入特判。
    返回 (压缩字节数, srcConsumed)(consumed 仅 fillOutput 有意义,L1376-1379)。
    字典参数原样透传(指针上下文由公开 API 的单一 unsafe 块提供,指针三律;
    noDict 调用传 LZ4_DICT_NODICT + 占位指针,核内不被解引用)。 */
internal func lz4CompressDispatch(state: LZ4_stream_t, srcQ: CPointer<UInt8>, srcSize: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, outputDirective: Int32, acceleration: Int64,
        dictSmall: Bool, dictDirective: Int32,
        dictQ: CPointer<UInt8>, dictEntrySize: Int64,
        ctxDictQ: CPointer<UInt8>, ctxDictSize: Int64,
        ctxTable: Array<UInt32>, ctxCurrentOffset: UInt32): (Int64, Int64) {
    if (srcSize < 0 || srcSize > Int64(LZ4_MAX_INPUT_SIZE)) {   /* L1369(无符号比较语义) */
        return (0, 0)
    }
    if (srcSize == 0) {                                          /* L1370-1381 */
        if (outputDirective != LZ4_OUTPUT_NOT_LIMITED && dstCapacity <= 0) {
            return (0, 0)                                        /* L1371 */
        }
        LZ4_write8(dst, 0, 0u8)                                  /* L1375: 空块 = 单字节 0x00 */
        return (1, 0)                                            /* L1376-1380(fillOutput consumed=0) */
    }
    return LZ4_compress_generic_validated(state, srcQ, srcSize, dst,
        dstCapacity, byU16, outputDirective, acceleration,
        dictDirective, dictSmall, dictQ, dictEntrySize,
        ctxDictQ, ctxDictSize, ctxTable, ctxCurrentOffset)
}

/* extState 公共尾部(上游 L1391-1412 / L1423-1459 共形):加速度钳制 +
   表型/输出模式选择;fastReset=true 时以 LZ4_prepareTable 替代全量 init
   (L1433/1441/1447/1455),byU16 且复用后 currentOffset != 0 → dictSmall
   (L1435-1439/1443-1447;byU32 分支恒 noDictIssue)。
   指针 acquire→压缩→release(单一 unsafe,无内部分配)。 */
private func lz4CompressExtStateBody(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32, fastReset: Bool): Int32 {
    var accel: Int32 = acceleration
    if (accel < 1) {
        accel = LZ4_ACCELERATION_DEFAULT                        /* L1395/L1428 */
    }
    if (accel > LZ4_ACCELERATION_MAX) {
        accel = LZ4_ACCELERATION_MAX                            /* L1396/L1429 */
    }
    let byU16: Bool = Int64(srcSize) < LZ4_64Klimit             /* L1398/L1433(64 位:否则 byU32) */
    let notLimited: Bool = dstCapacity >= LZ4_compressBound(srcSize)   /* L1397/L1432 */
    let outputDirective: Int32 = if (notLimited) {
        LZ4_OUTPUT_NOT_LIMITED
    } else {
        LZ4_OUTPUT_LIMITED
    }
    var dictSmall: Bool = false
    if (fastReset) {
        LZ4_prepareTable(state, Int64(srcSize),
            if (byU16) { LZ4_TABLE_BYU16 } else { LZ4_TABLE_BYU32 })   /* L1433/1447 */
        dictSmall = byU16 && state.currentOffset != 0u32        /* L1435/1443: if (ctx->currentOffset) */
    }
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        let (r, _) = lz4CompressDispatch(state, sh.pointer, Int64(srcSize), dh.pointer,
            Int64(dstCapacity), byU16, outputDirective, Int64(accel), dictSmall,
            LZ4_DICT_NODICT, sh.pointer, state.dictSize,
            sh.pointer, 0, state.hashTable, 0u32)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
        return Int32(r)
    }
}

/*-************************************
*  Public compression API
**************************************/
public func LZ4_compress_fast_extState(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32 {
    LZ4_initStream(state)                                       /* L1393 */
    return lz4CompressExtStateBody(state, src, srcSize, dst, dstCapacity, acceleration, false)
}

/* 上游 L1423-1459:与 extState 的差异即"快复位"——不做全量 initStream,
   由 LZ4_prepareTable 依据 tableType/currentOffset/inputSize 决定复用脏表
   (byU16 且 currentOffset+inputSize < 0xFFFF 且 inputSize < 4KB)或清表,
   复用路径以 dictSmall 前缀界拒绝陈旧登记(安全性必需:陈旧 matchIndex
   映射回本块为负位置)。输出与全新状态压缩逐字节一致(空槽 0 候选在
   全新模式下同样不可能通过 read32 比较),差异在状态演化:复用累积
   currentOffset、保留脏表(golden fastreset 行的 off=/tt= 所锚定)。
   M2 时期曾委托全量 init(等价性注释),本函数为该登记义务的履行。 */
public func LZ4_compress_fast_extState_fastReset(state: LZ4_stream_t, src: Array<UInt8>,
        srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32 {
    return lz4CompressExtStateBody(state, src, srcSize, dst, dstCapacity, acceleration, true)
}

public func LZ4_compress_fast(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32, acceleration: Int32): Int32 {
    let ctxPtr = LZ4_stream_t()                                 /* L1469: 栈上临时 ctx */
    return LZ4_compress_fast_extState(ctxPtr, src, srcSize, dst, dstCapacity, acceleration)
}

public func LZ4_compress_default(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32): Int32 {
    return LZ4_compress_fast(src, srcSize, dst, dstCapacity, 1) /* L1483 */
}

/* LZ4_compress_destSize_extState_internal(lz4.c L1490-1504):target ≥ compressBound
    时压缩必成,委托常规路径(不写 *srcSizePtr → consumed 保持调用方初值);
    否则走 fillOutput 核心,consumed 由核心写出。失败(r == 0)时 C 不触碰
    *srcSizePtr,按调用方初值约定(= srcSize,与 gen_golden/lz4 CLI 一致)返回。
    入口 initStream(L1492);出口清态由公开包装 LZ4_compress_destSize_extState
    负责(L1510),one-shot LZ4_compress_destSize 用后即弃无需清态。 */
private func lz4CompressDestSizeInternal(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, targetDstSize: Int32, acceleration: Int32): (Int32, Int32) {
    LZ4_initStream(state)                                       /* L1492 */
    if (targetDstSize >= LZ4_compressBound(srcSize)) {          /* L1495 */
        let c = lz4CompressExtStateBody(state, src, srcSize, dst, targetDstSize, acceleration, false)
        if (c == 0) {
            return (0, srcSize)                                 /* srcSizePtr 未触碰 */
        }
        return (c, srcSize)                                     /* 全量压缩,consumed = srcSize */
    }
    let byU16: Bool = Int64(srcSize) < LZ4_64Klimit             /* L1498(64 位:否则 byU32) */
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        let (r, consumed) = lz4CompressDispatch(state, sh.pointer, Int64(srcSize), dh.pointer,
            Int64(targetDstSize), byU16, LZ4_OUTPUT_FILL, Int64(acceleration), false,
            LZ4_DICT_NODICT, sh.pointer, state.dictSize,
            sh.pointer, 0, state.hashTable, 0u32)   /* L1499-1502 */
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
        if (r == 0) {
            return (0, srcSize)                                 /* L994/L1371 失败路径 */
        }
        return (Int32(r), Int32(consumed))
    }
}

/* LZ4_compress_destSize(lz4.c L1515-1531):压缩 src 前缀直至产出恰好不超过
   targetDstSize 的块;返回 (压缩字节数, srcConsumed)。失败(target ≤ 0 等)
   返回 (0, srcSize)(C 返回 0 且 *srcSizePtr 保持调用方初值)。 */
public func LZ4_compress_destSize(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        targetDstSize: Int32): (Int32, Int32) {
    let ctx = LZ4_stream_t()                                    /* L1521-1522: 栈上临时 ctx */
    return lz4CompressDestSizeInternal(ctx, src, srcSize, dst, targetDstSize, 1)   /* L1525: accel=1 */
}

/* LZ4_compress_destSize_extState(lz4.c L1506-1512):带外部状态的 destSize;
    internal 后无条件 initStream 清态(L1510,上游注释:destSize 留下脏流,
    包装器保证出口干净——复用脏 state 的后续调用不继承 4KB 加速位点等残留)。
    返回 (压缩字节数, srcConsumed) 元组(§4.3 规则 1:*srcSizePtr 并入返回值;
    委托路径不触碰 → consumed = 调用方 srcSize;fillOutput 路径核心写出)。 */
public func LZ4_compress_destSize_extState(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, targetDstSize: Int32, acceleration: Int32): (Int32, Int32) {
    let r = lz4CompressDestSizeInternal(state, src, srcSize, dst, targetDstSize, acceleration)
    LZ4_initStream(state)                                       /* L1510: clean the state on exit */
    return r
}

/*-************************************
*  Streaming compression (lz4.c L1596-1843)
**************************************/
/* 同一分配判定(别名探针):仓颉无引用同一性比较(=== 不存在;CPointer 无
    ==/</-/equals/toIntNative,逐一探针证伪),而流式压缩的分支抉择
    (L1755 dictEnd == source 的指针相等)依赖"字典与本块是否同一缓冲"。
    探针:经 d1 写入瞬态哨兵字节、经 d2 读回、即刻复原——同一底层对象则
    写入可见。读写间仅有整数异或与数组访问,不分配、不可抛出(下标界内:
    k=0 < d1.size),单线程契约下与 C 指针相等语义严格一致(同一分配 ⟺
    可见)。内容相等的不同分配(twin 缓冲)判 false —— 这是与"内容窗口
    相等"替代案(M3a 解码侧先例)的本质差异:压缩侧内容判定会在
    savedict/extdict 场景产生错误的状态演化(内容等价仅保证当次输出,
    prefix 分支的 dictSize 累积 vs extDict 分支的重置会改变后续块的
    dictSmall 抉择与字典区间,且 dictSize 越过 safeBuffer 容量时读越界),
    已被 M3b golden(savedict seq=1 / extdict zig-zag)排除。 */
internal func lz4SameBuffer(d1: Array<UInt8>, d2: Array<UInt8>): Bool {
    if (d1.size != d2.size || d1.size == 0) {
        return false                    /* 尺寸不同必非同一分配 */
    }
    let save: UInt8 = d1[0]
    let sent: UInt8 = save ^ 0xFFu8     /* 必不同于原值 */
    d1[0] = sent
    let visible: Bool = (d2[0] == sent)
    d1[0] = save
    return visible
}

/* LZ4_renormDictT(lz4.c L1696-1713):currentOffset + nextSize 越过 2GB 时的
    表刻度重整 —— 全表条目减去 (currentOffset - 64KB)(小于该 delta 的清 0),
    currentOffset 归位 64KB,字典截尾至 64KB 并前移 dictStartIdx 使 dictEnd
    不变(60 位指针差的溢出防护,64 位构建不可达但按上游保留)。 */
internal func lz4RenormDictT(state: LZ4_stream_t, nextSize: Int64): Unit {
    if (state.currentOffset + UInt32(nextSize & 0xFFFFFFFFi64) > 0x80000000u32) {   /* L1699 */
        let delta: UInt32 = state.currentOffset - 65536u32                          /* L1701 */
        let dictEndIdx: Int64 = state.dictStartIdx + state.dictSize                 /* L1702 */
        var i: Int64 = 0
        while (i < state.hashTable.size) {                                          /* L1705 */
            if (state.hashTable[i] < delta) {
                state.hashTable[i] = 0u32
            } else {
                state.hashTable[i] -= delta
            }
            i += 1
        }
        state.currentOffset = 65536u32                                              /* L1709 */
        if (state.dictSize > 65536) {
            state.dictSize = 65536                                                  /* L1710 */
        }
        state.dictStartIdx = dictEndIdx - state.dictSize                            /* L1711 */
    }
}

/* LZ4_loadDict_internal(lz4.c L1596-1655,_ld_fast/_ld_slow):
    1) 全量 resetStream(注释 L1608-1611:不能只 prepareTable,防溢出的
       matchIndex);2) currentOffset += 64KB —— 保证窗口内只有合法 offset,
       fast_continue 得以在字典不足 64KB 时仍走 noDictIssue(见 L1614-1619
       注释与 L1765-1770);3) dictSize < HASH_UNIT(64 位 reg_t = 8)早退 0;
    4) 超过 64KB 截尾(只留最后 64KB);5) _ld_fast:从 (currentOffset-
    dictSize) 起每 3 字节入表(覆盖式,偏向字典尾);6) _ld_slow 追加第二
    遍:逐字节,仅当槽内现值 ≤ currentOffset - 64KB(空/太旧)才入表
    (非覆盖式,偏向字典头)—— 两策略产生不同表,golden dictfast/dictslow
    分别锚定。返回字典有效长度(截尾后)。
    字典记 (dictBuf, dictStartIdx, dictSize) 引用对,不拷贝(调用方保证
    存活期,与 C 生命周期契约一致);dictSize > dictionary.size 在 C 侧为
    越界读 UB,防御性同 < HASH_UNIT 早退 0。 */
internal func lz4LoadDictInternal(dictState: LZ4_stream_t, dictionary: Array<UInt8>,
        dictSize: Int32, slow: Bool): Int32 {
    LZ4_resetStream(dictState)                                   /* L1612 */
    dictState.currentOffset += 65536u32                          /* L1620 */
    if (dictSize < 8 /* HASH_UNIT = sizeof(reg_t), 64 位 */ || Int64(dictSize) > dictionary.size) {
        return 0                                                 /* L1622 */
    }
    var p: Int64 = 0
    let dictEnd: Int64 = Int64(dictSize)                         /* L1603 */
    if (dictEnd - p > 65536) {
        p = dictEnd - 65536                                      /* L1626: 截尾至最后 64KB */
    }
    dictState.dictBuf = Some(dictionary)                         /* L1627 */
    dictState.dictStartIdx = p
    dictState.dictSize = dictEnd - p                             /* L1628 */
    dictState.tableType = LZ4_TABLE_BYU32                        /* L1629 */
    var idx32: UInt32 = dictState.currentOffset - UInt32(dictState.dictSize)   /* L1630 */
    unsafe {
        let dh = acquireArrayRawData<UInt8>(dictionary)
        while (p <= dictEnd - 8) {                               /* L1632 */
            let h = LZ4_hashPosition(dh.pointer, p, false)
            lz4PutIndexOnHash(dictState.hashTable, idx32, h, false)   /* L1635: 覆盖式 */
            p += 3
            idx32 += 3
        }
        if (slow) {                                              /* L1639-1652 */
            p = dictState.dictStartIdx
            idx32 = dictState.currentOffset - UInt32(dictState.dictSize)
            while (p <= dictEnd - 8) {
                let h = LZ4_hashPosition(dh.pointer, p, false)
                let limit: UInt32 = dictState.currentOffset - 65536u32   /* L1645 */
                if (lz4GetIndexOnHash(dictState.hashTable, h, false) <= limit) {
                    lz4PutIndexOnHash(dictState.hashTable, idx32, h, false)   /* L1648: 非覆盖式 */
                }
                p += 1
                idx32 += 1
            }
        }
        releaseArrayRawData<UInt8>(dh)
    }
    return Int32(dictState.dictSize)                             /* L1654 */
}

/* LZ4_loadDict(lz4.c L1657-1660) */
public func LZ4_loadDict(dictState: LZ4_stream_t, dictionary: Array<UInt8>, dictSize: Int32): Int32 {
    return lz4LoadDictInternal(dictState, dictionary, dictSize, false)
}

/* LZ4_loadDictSlow(lz4.c L1662-1665) */
public func LZ4_loadDictSlow(dictState: LZ4_stream_t, dictionary: Array<UInt8>, dictSize: Int32): Int32 {
    return lz4LoadDictInternal(dictState, dictionary, dictSize, true)
}

/* LZ4_attach_dictionary(lz4.c L1667-1693):把 loadDict 产出的字典流挂为
    workingStream 的 dictCtx(只读咨询,L1067-1074)。workingStream 的
    currentOffset 为 0 时先抬到 64KB(L1682-1684:offset 0 下自家表永远
    "未命中"不存在,dictCtx 无从触发);空字典不挂接(L1688-1690)。
    C 的 dictionaryStream == NULL(摘除)在仓颉无空引用,不可达;上游无
    tableType 兼容检查(0774d055 版),逐字对照。 */
public func LZ4_attach_dictionary(workingStream: LZ4_stream_t, dictionaryStream: LZ4_stream_t): Unit {
    if (workingStream.currentOffset == 0u32) {
        workingStream.currentOffset = 65536u32                   /* L1683 */
    }
    if (dictionaryStream.dictSize == 0) {
        workingStream.dictCtx = None                             /* L1689: 空字典不挂 */
    } else {
        workingStream.dictCtx = Some(dictionaryStream)           /* L1692 */
    }
}

/* fast_continue 的单一 unsafe 域(指针三律:acquire → 分派 → release,域内
    不分配):按分支 acquire 源/目的/辅助字典(EXTDICT = 自家字典缓冲,
    DICTCTX = dictCtx 字典缓冲,前缀/无字典 = 无辅助句柄),dictQ/ctxDictQ
    同传 auxQ(字典尾锚 = 缓冲基 + auxEndIdx),核内按指令取用。 */
private func lz4ContinueRun(state: LZ4_stream_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, n: Int64,
        dst: Array<UInt8>, dstCapacity: Int64, accel: Int64,
        dictDirective: Int32, dictSmall: Bool,
        auxArr: Option<Array<UInt8>>, auxEndIdx: Int64, dictEntrySize: Int64,
        ctxDictSize: Int64, ctxTable: Array<UInt32>, ctxCurrentOffset: UInt32): Int32 {
    unsafe {
        let sh = acquireArrayRawData<UInt8>(srcBuf)
        let dh = acquireArrayRawData<UInt8>(dst)
        let srcQ = sh.pointer + srcIdx
        var r: Int64 = 0
        match (auxArr) {
            case Some(a) =>
                let ah = acquireArrayRawData<UInt8>(a)
                let auxQ = ah.pointer + auxEndIdx
                let (v, _) = lz4CompressDispatch(state, srcQ, n, dh.pointer, dstCapacity,
                    false, LZ4_OUTPUT_LIMITED, accel, dictSmall, dictDirective,
                    auxQ, dictEntrySize, auxQ, ctxDictSize, ctxTable, ctxCurrentOffset)
                r = v
                releaseArrayRawData<UInt8>(ah)
            case None =>
                let (v, _) = lz4CompressDispatch(state, srcQ, n, dh.pointer, dstCapacity,
                    false, LZ4_OUTPUT_LIMITED, accel, dictSmall, dictDirective,
                    srcQ, dictEntrySize, srcQ, ctxDictSize, ctxTable, ctxCurrentOffset)
                r = v
        }
        releaseArrayRawData<UInt8>(dh)
        releaseArrayRawData<UInt8>(sh)
        return Int32(r)
    }
}

/* LZ4_compress_fast_continue(lz4.c L1716-1792):流式续压。
    块位置:仓颉签名以 (srcBuf, srcIdx) 缓冲-位置对表达本块
    srcBuf[srcIdx, srcIdx+srcSize)(M3a 流式解码 (dstBuf, dstIdx) 先例,
    设计 §4.3 规则 4 同族;C 的 source 指针前移无 6 参等价表达 —— 块起点
    不可从状态推导:extdict twin 场景要求跨缓冲换位后块起点 40960,而
    dict 场景新缓冲块起点 0,几何不可区分,必须显式传递)。
    场景分派(逐行对照上游):
      L1723 dictEnd 局部量 = dictSize ? dictionary+dictSize : NULL(仓颉:
        dictEndValid + dictEndL + 同一分配判定 lz4SameBuffer);
      L1727 renormDictT;L1728-29 加速度钳制;
      L1731-42 微字典失效(dictSize<4 且 dictEnd≠source 且 n>0 且无
        dictCtx → dictionary=(srcBuf, srcIdx), dictSize=0 → prefix);
      L1744-52 输入/字典重叠收缩(跨分配指针比较在 C 为未定义,仅在
        同一分配下执行:state.dictSize=dictEnd-sourceEnd 截 64KB,<4 归 0,
        dictStartIdx 前移;局部 dictEndL 不更新 —— 上游同用陈旧局部值);
      L1755 prefix 分支(dictEnd == source ⟺ 同一分配 && dictEndIdx ==
        srcIdx):withPrefix64k,dictSmall = dictSize<64KB && dictSize<
        currentOffset;直接返回(generic 内 dictSize 累积、dictionary 不动);
      L1762-91 外字典分支:dictCtx 在且 n≤4KB → usingDictCtx(自家表 +
        dictCtx 表回退);dictCtx 在且 n>4KB → 整状态拷贝自 dictCtx(表/
        currentOffset/字典引用,L1776 memcpy)后 usingExtDict(仅查一表);
        无 dictCtx → usingExtDict,dictSmall 同 prefix 判式。事后统一
        dictionary=(srcBuf, srcIdx)、dictSize=inputSize(L1788-89)。
    prefix vs extDict 的输出等价性(内容窗口论证,勿混淆于分支判定):
    同一分配前缀连续时,前缀读(本块负位)与 extDict 读(字典尾锚)字节
    相同 → 两种实现的候选/计数/offset 完全一致;本实现按 C 原分支执行
    (prefix 走单段读,不依赖该等价性),等价性仅作为 twin 缓冲等极端
    场景的失败安全网。 */
public func LZ4_compress_fast_continue(state: LZ4_stream_t, srcBuf: Array<UInt8>, srcIdx: Int64,
        srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32 {
    /* 校验:C 侧 srcSize 经 generic 的 (U32) 比较(>MAX_INPUT_SIZE → 0);
    srcIdx/缓冲关系为仓颉块位置参数的防御检查(C 为调用方指针契约) */
    if (srcSize < 0 || Int64(srcSize) > Int64(LZ4_MAX_INPUT_SIZE)) {
        return 0
    }
    if (srcIdx < 0 || srcIdx + Int64(srcSize) > srcBuf.size) {
        return 0
    }
    let n: Int64 = Int64(srcSize)
    var accel: Int32 = acceleration
    if (accel < 1) {
        accel = LZ4_ACCELERATION_DEFAULT                        /* L1728 */
    }
    if (accel > LZ4_ACCELERATION_MAX) {
        accel = LZ4_ACCELERATION_MAX                            /* L1729 */
    }

    /* L1723:dictEnd 局部量(renorm 之前取值,与上游顺序一致) */
    var dictEndL: Int64 = 0
    var dictEndValid: Bool = false
    var dictSameBuf: Bool = false
    match (state.dictBuf) {
        case Some(d) =>
            if (state.dictSize != 0) {
                dictEndValid = true
                dictEndL = state.dictStartIdx + state.dictSize
                dictSameBuf = lz4SameBuffer(d, srcBuf)
            }
        case None => ()
    }
    /* L1755 的指针相等判定 ⟺ 有效字典尾 && 同一分配 && 字典尾 == 本块起点 */
    var prefixCont: Bool = dictEndValid && dictSameBuf && (dictEndL == srcIdx)

    lz4RenormDictT(state, n)                                     /* L1727 */

    /* L1731-1742: 微字典失效 */
    if ((state.dictSize < 4) && (!prefixCont) && (n > 0) && (state.dictCtx.isNone())) {
        state.dictBuf = Some(srcBuf)
        state.dictStartIdx = srcIdx
        state.dictSize = 0
        dictEndValid = true
        dictEndL = srcIdx
        dictSameBuf = true
        prefixCont = true
    }

    /* L1744-1752: 输入/字典重叠收缩(仅同一分配下有定义) */
    let sourceEnd: Int64 = srcIdx + n
    if (dictEndValid && dictSameBuf && (sourceEnd > state.dictStartIdx) && (sourceEnd < dictEndL)) {
        state.dictSize = dictEndL - sourceEnd
        if (state.dictSize > 65536) {
            state.dictSize = 65536
        }
        if (state.dictSize < 4) {
            state.dictSize = 0
        }
        state.dictStartIdx = dictEndL - state.dictSize
    }

    if (prefixCont) {
        /* L1755-1759: prefix 模式 —— source 数据接续字典(同一分配连续) */
        let dSmall: Bool = (state.dictSize < 65536) && (state.dictSize < Int64(state.currentOffset))
        return lz4ContinueRun(state, srcBuf, srcIdx, n, dst, Int64(dstCapacity), Int64(accel),
            LZ4_DICT_PREFIX64K, dSmall, None<Array<UInt8>>, 0, state.dictSize,
            0, state.hashTable, 0u32)
    }

    /* L1762-1791: 外字典模式 */
    var result: Int32 = 0
    match (state.dictCtx) {
        case Some(dc) =>
            if (n > 4096) {
                /* L1771-1777: 大块 —— 拷贝 dictCtx 整内部状态(表 + 偏移 +
                    字典引用;loadDict 保证其表条目全部落在字典区间,拷贝后
                    usingExtDict 可安全 noDictIssue),压缩循环只查一张表 */
                var i: Int64 = 0
                while (i < state.hashTable.size) {
                    state.hashTable[i] = dc.hashTable[i]
                    i += 1
                }
                state.currentOffset = dc.currentOffset
                state.tableType = dc.tableType
                state.dictBuf = dc.dictBuf
                state.dictStartIdx = dc.dictStartIdx
                state.dictSize = dc.dictSize
                state.dictCtx = dc.dictCtx
                let endIdx: Int64 = state.dictStartIdx + state.dictSize
                result = lz4ContinueRun(state, srcBuf, srcIdx, n, dst, Int64(dstCapacity),
                    Int64(accel), LZ4_DICT_EXTDICT, false,
                    state.dictBuf, endIdx, state.dictSize, 0, state.hashTable, 0u32)
            } else {
                /* L1779: usingDictCtx —— 自家表 + dictCtx 表回退(noDictIssue,
                    L1765-1770 注释:loadDict 的 64KB 偏移保证字典区间无越界) */
                var ctxEndIdx: Int64 = 0
                match (dc.dictBuf) {
                    case Some(cd) => ctxEndIdx = dc.dictStartIdx + dc.dictSize
                    case None => ()
                }
                result = lz4ContinueRun(state, srcBuf, srcIdx, n, dst, Int64(dstCapacity),
                    Int64(accel), LZ4_DICT_DICTCTX, false,
                    dc.dictBuf, ctxEndIdx, state.dictSize,
                    dc.dictSize, dc.hashTable, dc.currentOffset)
            }
        case None =>
            /* L1781-1786: 小数据/无 dictCtx 的外字典 */
            let dSmall: Bool = (state.dictSize < 65536) && (state.dictSize < Int64(state.currentOffset))
            let endIdx: Int64 = state.dictStartIdx + state.dictSize
            result = lz4ContinueRun(state, srcBuf, srcIdx, n, dst, Int64(dstCapacity),
                Int64(accel), LZ4_DICT_EXTDICT, dSmall,
                state.dictBuf, endIdx, state.dictSize, 0, state.hashTable, 0u32)
    }
    state.dictBuf = Some(srcBuf)                                 /* L1788 */
    state.dictStartIdx = srcIdx
    state.dictSize = n                                           /* L1789 */
    return result
}

/* LZ4_saveDict(lz4.c L1823-1843):把字典末尾 min(dictSize, 64KB, 可用)
    显式拷贝到 safeBuffer[0..saved)(本家族唯一拷贝点),状态改指 safeBuffer
    —— 此后缓冲原址失效亦不影响续压。返回实际保存长度;dictSize 入参的
    无符号钳制逐行复刻((U32)dictSize > 64KB → 64KB;> 可用 → 可用)。
    前向拷贝恒安全:目的区间自 0 起,源区间自 dictEndIdx-saved 起
    (≥ dictStartIdx ≥ 0),交叠时必为 dst < src 的经典安全向。 */
public func LZ4_saveDict(state: LZ4_stream_t, safeBuffer: Array<UInt8>, dictSize: Int32): Int32 {
    var ds: Int32 = dictSize
    if (UInt32(ds) > 65536u32) {                                 /* L1829(无符号比较) */
        ds = 65536
    }
    if (UInt32(ds) > UInt32(state.dictSize & 0xFFFFFFFFi64)) {   /* L1830 */
        ds = Int32(state.dictSize)
    }
    if (ds > 0) {
        let dictEndIdx: Int64 = state.dictStartIdx + state.dictSize
        let fromIdx: Int64 = dictEndIdx - Int64(ds)
        unsafe {
            let sh = acquireArrayRawData<UInt8>(safeBuffer)
            match (state.dictBuf) {
                case Some(d) =>
                    let kh = acquireArrayRawData<UInt8>(d)
                    LZ4_memcpyPtr(sh.pointer, 0, kh.pointer, fromIdx, Int64(ds))   /* L1836 memmove */
                    releaseArrayRawData<UInt8>(kh)
                case None => ()
            }
            releaseArrayRawData<UInt8>(sh)
        }
    }
    state.dictBuf = Some(safeBuffer)                             /* L1839 */
    state.dictStartIdx = 0
    state.dictSize = Int64(ds)                                   /* L1840 */
    return ds
}

/*-************************************
*  Decompression constants (lz4.c L243-249)
**************************************/
internal const LZ4_WILDCOPYLENGTH: Int64 = 8                        /* lz4.c L245 */
/* lz4.c L248:2×WILDCOPYLENGTH-MINMATCH = 12,保证可写两组野复制而不越输出界 */
internal const LZ4_MATCH_SAFEGUARD_DISTANCE: Int64 = 2 * LZ4_WILDCOPYLENGTH - LZ4_MINMATCH
/* lz4.c L249:FASTLOOP_SAFE_DISTANCE = 64(T3 fast 循环分派阈值);
   inc32/dec64 表移至 common.cj(上游 L475-476 置于 wildCopy 助手旁) */
internal const LZ4_FASTLOOP_SAFE_DISTANCE: Int64 = 64

/*-************************************
*  Decompression core (lz4.c L2015-2464, safe decode path)
**************************************/
/* 上游 read_variable_length(lz4.c L1978-2013):逐字节读取 255 进位长度。
   返回 (length, 新 ip);ilimit 为禁止越过的读界限;错误以 length == -1
   表示(rvl_error),此时第二个分量停在检测到界限时的 ip(与 C 的指针
   推进一致,供 -(ip)-1 位置编码使用)。L2007 的 32 位累加器溢出检查
   在 64 位构建(Int64 累加)下不可达,不移植。 */
internal func lz4ReadVariableLength(src: CPointer<UInt8>, ip: Int64, ilimit: Int64): (Int64, Int64) {
    var p = ip
    if (p >= ilimit) {                                           /* L1992 */
        return (-1, p)
    }
    var s: Int64 = Int64(LZ4_read8(src, p))
    p += 1
    var length: Int64 = s
    if (s != 255) {
        return (length, p)                                       /* L1998 */
    }
    do {
        if (p >= ilimit) {                                       /* L2000 */
            return (-1, p)
        }
        s = Int64(LZ4_read8(src, p))
        p += 1
        length += s
    } while (s == 255)
    return (length, p)
}

/* 解码循环入口阶段(T3):C 以 goto 从 fast 循环跳入 safe 循环的 4 个标签
   (safe_decode / safe_literal_copy_early / safe_literal_copy /
   safe_match_copy),仓颉无 goto,以 stage 状态机表达 —— safe 循环每轮从
   stage 指定的等价位点开始,循环内所有 continue 位点统一回到 STAGE_TOP。 */
private const DECODE_STAGE_TOP: Int64 = 0        /* L2226: 读新 token(捷径判定) */
private const DECODE_STAGE_LIT_LEN: Int64 = 1    /* L2287: safe_literal_copy_early */
private const DECODE_STAGE_LIT_COPY: Int64 = 2   /* L2293: safe_literal_copy */
private const DECODE_STAGE_COPY_MATCH: Int64 = 3 /* L2362: _copy_match */
private const DECODE_STAGE_SAFE_MATCH: Int64 = 4 /* L2372: safe_match_copy */

/* LZ4_decompress_generic 的指针循环体(safe + fast 两条解码循环)。
   (buf, idx) 位置模型:src/dst 以基指针 + Int64 索引表达;lowPrefixIdx 为
   dst 同缓冲内前缀起点(withPrefix64k 时前缀 ≥ 65535 字节);dictIsExtDict 时
   dictP/dictStartIdx/dictSize 表达外字典(dictEnd = dictStartIdx + dictSize)。
   dict_directive 的位置编码:noDict = 无外字典(小前缀或无前缀,守卫生效);
   withPrefix64k = 无外字典且前缀 ≥ 65535;usingExtDict = dictIsExtDict。
   _output_error 以 `return -(ip) - 1` 直接实现(L2462);成功返回输出字节数。
   T3:outputSize ≥ FASTLOOP_SAFE_DISTANCE 时分派进 fast 循环(L2074-2221,
   上游 x86_64/aarch64 默认 LZ4_FAST_DEC_LOOP=1;字面量拷贝移植 #else 支,
   即 32 字节边距 + wildCopy32,aarch64 的 64 字节变体不移植以保证双平台
   行为确定);forceSafe 为差分测试钩子(等价 LZ4_FAST_DEC_LOOP=0 构建)。 */
private func lz4DecompressGenericBody(
        src: CPointer<UInt8>, srcSize: Int64,
        dst: CPointer<UInt8>, dstIdx: Int64, outputSize: Int64,
        partialDecoding: Bool,
        lowPrefixIdx: Int64,
        dictP: CPointer<UInt8>, dictIsExtDict: Bool, dictStartIdx: Int64, dictSize: Int64,
        forceSafe: Bool): Int64 {
    let iend: Int64 = srcSize                                    /* L2038 */
    var op: Int64 = dstIdx                                       /* L2040 */
    let oend: Int64 = dstIdx + outputSize                        /* L2041 */
    let dictEnd: Int64 = dictStartIdx + dictSize                 /* L2044(dictIsExtDict 时有效) */
    let checkOffset: Bool = dictSize < 65536                     /* L2046 */
    let shortiend: Int64 = iend - 14 - 2                         /* L2050:maxLL+offset */
    let shortoend: Int64 = oend - 14 - 18                        /* L2051:maxLL+maxML */
    /* withPrefix64k:捷径分支 L2155/L2259 的字典指令豁免。上游仅在缓冲内
       前缀 ≥ 64KB-1 时以 withPrefix64k 实例化(lz4.c:2502 lowPrefix = dest-64KB;
       L2742-2747:dictSize ≥ 64KB-1 → withPrefix64k,小前缀走 withSmallPrefix
       (L2523-2529)仍持 noDict 守卫)。空集豁免的数学依据:offset ≤ 65535(u16),
       match = op - offset ≥ dstIdx - 65535,故 dstIdx - lowPrefixIdx ≥ 65535 时
       match ≥ lowPrefixIdx 恒真——豁免纯为省分支;小前缀下合法 offset 可指向
       lowPrefixIdx 之前,守卫必须生效。T3 在 L2155 等价位点需同样纪律。 */
    let withPrefix64k: Bool = (!dictIsExtDict) && (dstIdx - lowPrefixIdx >= Int64(LZ4_DISTANCE_MAX))

    /* Special cases(L2063-2068;L2062 断言 lowPrefix ≤ op 由模型保证) */
    if (outputSize == 0) {
        /* Empty output buffer */
        if (partialDecoding) {
            return 0
        }
        if (srcSize == 1 && LZ4_read8(src, 0) == 0u8) { return 0 }
        return -1
    }
    if (srcSize == 0) {
        return -1
    }

    /* LZ4_FAST_DEC_LOOP 分派(L2074-2077):(oend - op) < 64 → 直接
       safe_decode;否则进入 fast 循环。fast 循环主不变量(L2083):每轮
       oend - op ≥ 64,可无分支 32 字节野拷贝。 */
    var ip: Int64 = 0
    var token: UInt8 = 0u8
    var length: Int64 = 0
    var cpy: Int64 = 0
    var offset: Int64 = 0
    var matchIdx: Int64 = 0
    var stage: Int64 = DECODE_STAGE_TOP

    if ((!forceSafe) && (oend - op >= LZ4_FASTLOOP_SAFE_DISTANCE)) {
        /* Fast loop(L2079-2221):直至输出逼近 oend-64 或输入/输出解析
           限制触发,经 4 个标签位退回 safe 循环(此处即 break + stage)。 */
        while (true) {
            /* 断言等价(L2084):ip < iend —— 由字面量阶段的 iend 界检查
               归纳保证(含损坏输入),见上方派生。 */
            token = LZ4_read8(src, ip)                             /* L2085 */
            ip += 1
            length = Int64(token >> LZ4_ML_BITS)                   /* L2086: literal length */

            if (ip > iend - (16 + 1)) {                            /* L2088: 16字面量+offset+下token 余量不足 */
                stage = DECODE_STAGE_LIT_LEN                       /* goto safe_literal_copy_early */
                break
            }

            if (length == LZ4_RUN_MASK) {                          /* L2091 */
                /* 扩展字节不触及输入末尾 RUN_MASK 字节(L2092-2093) */
                let (addl, nip) = lz4ReadVariableLength(src, ip, iend - LZ4_RUN_MASK)   /* L2094 */
                if (addl == -1) {
                    return -nip - 1                                /* _output_error */
                }
                ip = nip
                length += addl
                cpy = op + length                                  /* L2103 */
                if (cpy < op) { return -ip - 1 }                   /* L2104 溢出检测(64 位下不可达,防御性保留) */
                if (ip + length < ip) { return -ip - 1 }           /* L2105 */
                /* x86-64 支(L2109-2113);__aarch64__ 的 64 边距/wildCopy64
                   变体不移植(差分确定性)。 */
                if ((cpy > oend - 32) || (ip + length > iend - 32)) {
                    stage = DECODE_STAGE_LIT_COPY                  /* goto safe_literal_copy */
                    break
                }
                LZ4_wildCopy32(dst, op, src, ip, length)           /* L2113: 越写 cpy 后至多 31 字节(界内) */
                ip += length
                op = cpy
            } else {
                LZ4_memcpyPtr(dst, op, src, ip, 16)                /* L2118: litLen ≤ 14 的 16 字节粗拷贝 */
                ip += length
                op += length
            }

            offset = Int64(LZ4_readLE16(src, ip))                  /* L2123 */
            ip += 2
            matchIdx = op - offset                                 /* L2125 */

            length = Int64(token & 0x0Fu8)                         /* L2128: match length */
            if (length == LZ4_ML_MASK) {                           /* L2130 */
                /* match 扩展字节后至少还需 1 token + LASTLITERALS 字面量 */
                let (addl, nip) = lz4ReadVariableLength(src, ip, iend - (1 + LZ4_LASTLITERALS))   /* L2133 */
                if (addl == -1) {
                    return -nip - 1                                /* _output_error */
                }
                ip = nip
                length += addl
                length += LZ4_MINMATCH                             /* L2136 */
                if (op + length < op) { return -ip - 1 }           /* L2141 溢出检测 */
                if (op + length >= oend - LZ4_FASTLOOP_SAFE_DISTANCE) {
                    stage = DECODE_STAGE_SAFE_MATCH                /* goto safe_match_copy(L2144) */
                    break
                }
            } else {
                length += LZ4_MINMATCH                             /* L2147 */
                if (op + length >= oend - LZ4_FASTLOOP_SAFE_DISTANCE) {
                    stage = DECODE_STAGE_SAFE_MATCH                /* goto safe_match_copy(L2149) */
                    break
                }

                /* 快路径(L2154-2164):offset ≥ 8 且 match 在前缀内 →
                   8+8+2 粗拷贝直接跳过 wildCopy32。守卫纪律同 safe 循环
                   捷径 L2259:withPrefix64k 豁免仅对 ≥ 65535 前缀成立
                   (offset ≤ 65535 ⇒ match ≥ lowPrefix 恒真,空集豁免)。 */
                if ((withPrefix64k) || (matchIdx >= lowPrefixIdx)) {
                    if (offset >= 8) {
                        LZ4_memcpyPtr(dst, op, dst, matchIdx, 8)         /* L2160-2162 */
                        LZ4_memcpyPtr(dst, op + 8, dst, matchIdx + 8, 8)
                        LZ4_memcpyPtr(dst, op + 16, dst, matchIdx + 16, 2)
                        op += length
                        continue                                    /* L2164 */
                    }
                }
            }

            if (checkOffset && (matchIdx + dictSize < lowPrefixIdx)) {   /* L2176: offset outside buffers */
                return -ip - 1
            }
            /* match 起自外字典(L2182-2208;与 safe 循环 L2377-2403 同构,
               上游亦两处重复) */
            if (dictIsExtDict && (matchIdx < lowPrefixIdx)) {
                if (op + length > oend - LZ4_LASTLITERALS) {       /* L2186 */
                    if (partialDecoding) {
                        length = if (length < oend - op) { length } else { oend - op }   /* L2188 */
                    } else {
                        return -ip - 1                             /* L2189 */
                    }
                }
                if (length <= lowPrefixIdx - matchIdx) {           /* L2194 */
                    /* match 全部位于外字典:直接拷贝 */
                    LZ4_memcpyPtr(dst, op, dictP, dictEnd - (lowPrefixIdx - matchIdx), length)   /* L2196 */
                    op += length
                } else {
                    /* match 跨外字典与当前块 */
                    let copySize: Int64 = lowPrefixIdx - matchIdx  /* L2199 */
                    let restSize: Int64 = length - copySize
                    LZ4_memcpyPtr(dst, op, dictP, dictEnd - copySize, copySize)   /* L2201 */
                    op += copySize
                    if (restSize > op - lowPrefixIdx) {            /* L2203: overlap copy */
                        let endOfMatch: Int64 = op + restSize
                        var copyFrom: Int64 = lowPrefixIdx
                        while (op < endOfMatch) {
                            LZ4_write8(dst, op, LZ4_read8(dst, copyFrom))
                            op += 1
                            copyFrom += 1
                        }
                    } else {
                        LZ4_memcpyPtr(dst, op, dst, lowPrefixIdx, restSize)   /* L2208 */
                        op += restSize
                    }
                }
                continue                                           /* L2207 */
            }

            /* 块内 match 拷贝(L2209-2217;至此必有 op + length < oend-64,
               满足 memcpy_using_offset / wildCopy32 的越写余量义务) */
            cpy = op + length
            if (offset < 16) {
                LZ4_memcpy_using_offset(dst, op, matchIdx, cpy, offset)   /* L2210: 交叠定长拷贝 */
            } else {
                LZ4_wildCopy32(dst, op, dst, matchIdx, cpy - op)          /* L2216 */
            }
            op = cpy                                               /* L2218: wildcopy correction */
        }
    }

    /* Main Loop:safe decode loop(L2226-2454),stage 状态机入口 */
    while (true) {
        if (stage == DECODE_STAGE_TOP) {
            token = LZ4_read8(src, ip)                             /* L2228 */
            ip += 1
            length = Int64(token >> 4)                             /* L2229: literal length */

            /* 两段式捷径(L2241-2272):litLen 0..14 且距输入/输出末尾足够远时,
               字面量超量拷贝 16 字节 + 尝试 18 字节 match 快拷 */
            if ((length != LZ4_RUN_MASK) && (ip < shortiend) && (op <= shortoend)) {
                /* Copy the literals(读界 shortiend/写界 shortoend 保证 16 字节安全) */
                LZ4_memcpyPtr(dst, op, src, ip, 16)                   /* L2245 */
                op += length
                ip += length
                length = Int64(token & 0x0Fu8)                        /* L2250: match length */
                offset = Int64(LZ4_readLE16(src, ip))                 /* L2252 */
                ip += 2
                matchIdx = op - offset                                   /* L2253 */
                /* 不处理交叠 match(offset ≥ 8 且不越 lowPrefix;withPrefix64k 豁免) */
                if ((length != LZ4_ML_MASK) && (offset >= 8) &&
                        (withPrefix64k || matchIdx >= lowPrefixIdx)) {   /* L2257-2259 */
                    LZ4_memcpyPtr(dst, op, dst, matchIdx, 8)             /* L2261-2263: 8+8+2 */
                    LZ4_memcpyPtr(dst, op + 8, dst, matchIdx + 8, 8)
                    LZ4_memcpyPtr(dst, op + 16, dst, matchIdx + 16, 2)
                    op += length + LZ4_MINMATCH
                    continue                                          /* L2266(stage 仍为 TOP) */
                }
                stage = DECODE_STAGE_COPY_MATCH                     /* L2271: goto _copy_match */
            } else {
                stage = DECODE_STAGE_LIT_LEN                        /* L2287 前:常规字面量解码 */
            }
        }

        if (stage == DECODE_STAGE_LIT_LEN) {
            /* decode literal length(L2279-2287) */
            if (length == LZ4_RUN_MASK) {
                /* 扩展字节不可能触及输入末尾 RUN_MASK 字节(L2280-2281) */
                let (addl, nip) = lz4ReadVariableLength(src, ip, iend - LZ4_RUN_MASK)   /* L2282 */
                if (addl == -1) {
                    return -nip - 1                               /* _output_error */
                }
                ip = nip
                length += addl
                if (op + length < op) { return -ip - 1 }          /* L2285 溢出检测(64 位下不可达,防御性保留) */
                if (ip + length < ip) { return -ip - 1 }          /* L2286 */
            }
            stage = DECODE_STAGE_LIT_COPY
        }

        if (stage == DECODE_STAGE_LIT_COPY) {
            /* copy literals(L2289-2352) */
            cpy = op + length                                      /* L2290 */
            if ((cpy > oend - LZ4_MFLIMIT) || (ip + length > iend - (2 + 1 + LZ4_LASTLITERALS))) {   /* L2297 */
                /* 命中输入或输出解析限制:整块解码时必为末序列,否则报错;
                   partialDecoding 时收缩到剩余空间(允许欠尺寸输出) */
                if (partialDecoding) {
                    if (ip + length > iend) {                     /* L2314: 输入不足 */
                        length = iend - ip
                        cpy = op + length
                    }
                    if (cpy > oend) {                             /* L2321: 输出不足 */
                        cpy = oend
                        length = oend - op
                    }
                } else {
                    /* 必须恰好吃尽输入且不越输出界(L2330) */
                    if ((ip + length != iend) || (cpy > oend)) {
                        return -ip - 1                            /* _output_error */
                    }
                }
                /* L2338 memmove:同缓冲交叠(原地解压)在分离缓冲模型下不存在,
                   精确正向拷贝等价 */
                LZ4_memcpyPtr(dst, op, src, ip, length)
                ip += length
                op += length
                /* L2346:非 partial 必然 EOF;partial 时填满输出或无法继续读
                   offset 也终止 */
                if ((!partialDecoding) || (cpy == oend) || (ip >= iend - 2)) {
                    break
                }
            } else {
                LZ4_wildCopy8(dst, op, src, ip, length)           /* L2350: 可越写 cpy 后至多 7 字节(界内) */
                ip += length
                op = cpy
            }

            /* get offset(L2355) */
            offset = Int64(LZ4_readLE16(src, ip))
            ip += 2
            matchIdx = op - offset                                   /* L2356 */

            /* get matchlength(L2359) */
            length = Int64(token & 0x0Fu8)
            stage = DECODE_STAGE_COPY_MATCH
        }

        /* _copy_match(L2362) */
        if (stage == DECODE_STAGE_COPY_MATCH) {
            if (length == LZ4_ML_MASK) {
                /* match 扩展字节后至少还需 1 token + LASTLITERALS 字面量(L2364) */
                let (addl, nip) = lz4ReadVariableLength(src, ip, iend - (1 + LZ4_LASTLITERALS))   /* L2365 */
                if (addl == -1) {
                    return -nip - 1                               /* _output_error */
                }
                ip = nip
                length += addl
                if (op + length < op) { return -ip - 1 }              /* L2368 溢出检测(64 位下不可达) */
            }
            length += LZ4_MINMATCH                                   /* L2370 */
            stage = DECODE_STAGE_SAFE_MATCH                          /* L2372 safe_match_copy */
        }

        if (checkOffset && (matchIdx + dictSize < lowPrefixIdx)) {   /* L2375: offset outside buffers */
            return -ip - 1
        }
        /* match starting within external dictionary(L2377-2403) */
        if (dictIsExtDict && (matchIdx < lowPrefixIdx)) {
            if (op + length > oend - LZ4_LASTLITERALS) {          /* L2379 */
                if (partialDecoding) {
                    length = if (length < oend - op) { length } else { oend - op }   /* L2380 */
                } else {
                    return -ip - 1                                /* L2381: 不满足解析限制 */
                }
            }
            if (length <= lowPrefixIdx - matchIdx) {                 /* L2384 */
                /* match 全部位于外字典:直接拷贝 */
                LZ4_memcpyPtr(dst, op, dictP, dictEnd - (lowPrefixIdx - matchIdx), length)   /* L2386 */
                op += length
            } else {
                /* match 跨外字典与当前块 */
                let copySize: Int64 = lowPrefixIdx - matchIdx        /* L2390 */
                let restSize: Int64 = length - copySize
                LZ4_memcpyPtr(dst, op, dictP, dictEnd - copySize, copySize)   /* L2392 */
                op += copySize
                if (restSize > op - lowPrefixIdx) {               /* L2394: overlap copy */
                    let endOfMatch: Int64 = op + restSize
                    var copyFrom: Int64 = lowPrefixIdx
                    while (op < endOfMatch) {
                        LZ4_write8(dst, op, LZ4_read8(dst, copyFrom))
                        op += 1
                        copyFrom += 1
                    }
                } else {
                    LZ4_memcpyPtr(dst, op, dst, lowPrefixIdx, restSize)   /* L2399 */
                    op += restSize
                }
            }
            stage = DECODE_STAGE_TOP
            continue                                             /* L2402 */
        }

        /* copy match within block(L2406;stage == SAFE_MATCH) */
        cpy = op + length

        /* partialDecoding:可在块内任意位置结束(L2411-2423) */
        if (partialDecoding && (cpy > oend - LZ4_MATCH_SAFEGUARD_DISTANCE)) {
            let mlen: Int64 = if (length < oend - op) { length } else { oend - op }   /* L2412 */
            let matchEnd: Int64 = matchIdx + mlen
            let copyEnd: Int64 = op + mlen
            if (matchEnd > op) {                                  /* L2415: overlap copy */
                while (op < copyEnd) {
                    LZ4_write8(dst, op, LZ4_read8(dst, matchIdx))
                    op += 1
                    matchIdx += 1
                }
            } else {
                LZ4_memcpyPtr(dst, op, dst, matchIdx, mlen)          /* L2418 */
            }
            op = copyEnd                                         /* L2420 */
            if (op == oend) {
                break                                            /* L2421 */
            }
            stage = DECODE_STAGE_TOP
            continue                                             /* L2422 */
        }

        if (offset < 8) {                                        /* L2425: 交叠 match */
            LZ4_writeLE32(dst, op, 0u32)                          /* L2426: 消 msan 警告(offset==0) */
            LZ4_write8(dst, op + 0, LZ4_read8(dst, matchIdx + 0))
            LZ4_write8(dst, op + 1, LZ4_read8(dst, matchIdx + 1))
            LZ4_write8(dst, op + 2, LZ4_read8(dst, matchIdx + 2))
            LZ4_write8(dst, op + 3, LZ4_read8(dst, matchIdx + 3))
            matchIdx += LZ4_INC32TABLE[Int64(offset)]                /* L2431 */
            LZ4_memcpyPtr(dst, op + 4, dst, matchIdx, 4)             /* L2432 */
            matchIdx -= LZ4_DEC64TABLE[Int64(offset)]              /* L2433 */
        } else {
            LZ4_memcpyPtr(dst, op, dst, matchIdx, 8)                 /* L2435 */
            matchIdx += 8
        }
        op += 8                                                   /* L2438 */

        if (cpy > oend - LZ4_MATCH_SAFEGUARD_DISTANCE) {          /* L2440 */
            let oCopyLimit: Int64 = oend - (LZ4_WILDCOPYLENGTH - 1)   /* L2441 */
            if (cpy > oend - LZ4_LASTLITERALS) {
                return -ip - 1                                    /* L2442: 末 LASTLITERALS 字节必须是字面量 */
            }
            if (op < oCopyLimit) {                                /* L2443 */
                LZ4_wildCopy8(dst, op, dst, matchIdx, oCopyLimit - op)   /* L2444 */
                matchIdx += oCopyLimit - op
                op = oCopyLimit
            }
            while (op < cpy) {                                    /* L2448: 逐字节收尾 */
                LZ4_write8(dst, op, LZ4_read8(dst, matchIdx))
                op += 1
                matchIdx += 1
            }
        } else {
            LZ4_memcpyPtr(dst, op, dst, matchIdx, 8)                 /* L2450 */
            if (length > 16) {
                LZ4_wildCopy8(dst, op + 8, dst, matchIdx + 8, cpy - (op + 8))   /* L2451 */
            }
        }
        op = cpy                                                  /* L2453: wildcopy correction */
        stage = DECODE_STAGE_TOP                                  /* 下一轮读新 token */
    }

    /* end of decoding(L2457-2458) */
    return op - dstIdx
}

/* LZ4_decompress_generic(lz4.c L2022-2464):解压核心,(buf, idx) 位置模型
   参数化(T2 的 partial/前缀、T4 的外字典直接复用);src+dst(+字典)在
   单一 unsafe 块内 acquire/release(指针三律)。无字典时 dictP 传 src 指针
   占位,dictIsExtDict=false 保证其绝不解引用。公开 API 走上游默认分派
   (outputSize ≥ 64 → fast 循环)。 */
internal func LZ4_decompress_generic(
        srcArr: Array<UInt8>, srcSize: Int64,
        dstArr: Array<UInt8>, dstIdx: Int64, outputSize: Int64,
        partialDecoding: Bool,
        lowPrefixIdx: Int64,
        dictArr: Option<Array<UInt8>>, dictStartIdx: Int64, dictSize: Int64): Int64 {
    return LZ4_decompress_generic_forced(srcArr, srcSize, dstArr, dstIdx, outputSize,
        partialDecoding, lowPrefixIdx, dictArr, dictStartIdx, dictSize, false)
}

/* 差分测试钩子(T3):forceSafe=true 恒走 safe 循环(等价上游
   LZ4_FAST_DEC_LOOP=0 构建);false 与公开 API/上游 x86-64 默认构建一致。 */
internal func LZ4_decompress_generic_forced(
        srcArr: Array<UInt8>, srcSize: Int64,
        dstArr: Array<UInt8>, dstIdx: Int64, outputSize: Int64,
        partialDecoding: Bool,
        lowPrefixIdx: Int64,
        dictArr: Option<Array<UInt8>>, dictStartIdx: Int64, dictSize: Int64,
        forceSafe: Bool): Int64 {
    if (outputSize < 0) {                                         /* L2035(src 模型恒非空) */
        return -1
    }
    unsafe {
        let sh = acquireArrayRawData<UInt8>(srcArr)
        let dh = acquireArrayRawData<UInt8>(dstArr)
        let r: Int64 = match (dictArr) {
            case Some(d) =>
                let kh = acquireArrayRawData<UInt8>(d)
                let v = lz4DecompressGenericBody(sh.pointer, srcSize, dh.pointer, dstIdx,
                    outputSize, partialDecoding, lowPrefixIdx, kh.pointer, true,
                    dictStartIdx, dictSize, forceSafe)
                releaseArrayRawData<UInt8>(kh)
                v
            case None =>
                lz4DecompressGenericBody(sh.pointer, srcSize, dh.pointer, dstIdx,
                    outputSize, partialDecoding, lowPrefixIdx, sh.pointer, false,
                    dictStartIdx, dictSize, forceSafe)
        }
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
        return r
    }
}

/*-************************************
*  Public decompression API
**************************************/
/* LZ4_decompress_safe(lz4.c L2470-2475):decode_full_block + noDict 实例化,
   lowPrefix = dst、无字典。入口校验:dstCapacity < 0 → -1(上游 L2035 的
   outputSize<0);srcSize < 0 防御性同报 -1(C 侧经 iend 下溢同样落入错误出口)。 */
public func LZ4_decompress_safe(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32): Int32 {
    if (srcSize < 0 || dstCapacity < 0) {
        return -1
    }
    return Int32(LZ4_decompress_generic(src, Int64(srcSize), dst, 0, Int64(dstCapacity),
        false, 0, None<Array<UInt8>>, 0, 0))
}

/* LZ4_decompress_safe_partial(lz4.c L2477-2484):dstCapacity ← MIN(target,
   dst) 后走 partial_decode + noDict 实例化。partial 语义由 generic 内已移植
   的分支承担(L2314-2325 字面量钳制、L2380 外字典 match 钳制、L2411-2422
   块内 match 保险分支、L2064 outputSize==0 → 0):尽早停止,返回实际产出
   ≤ target。target < 0 或 dstCapacity < 0 经 MIN 得负 outputSize → -1
   (L2035);srcSize < 0 防御性同报。 */
public func LZ4_decompress_safe_partial(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32, targetOutputSize: Int32): Int32 {
    if (srcSize < 0) {
        return -1
    }
    let cap: Int32 = if (targetOutputSize < dstCapacity) { targetOutputSize } else { dstCapacity }
    return Int32(LZ4_decompress_generic(src, Int64(srcSize), dst, 0, Int64(cap),
        true, 0, None<Array<UInt8>>, 0, 0))
}

/* LZ4_decompress_safe_usingDict(lz4.c L2738-2752):dictSize==0 → safe 路径
   (L2739-2742);C 的连续前缀分支(dictStart+dictSize==dest → withPrefix64k /
   withSmallPrefix,L2743-2750)要求字典与输出缓冲内存相邻,分离数组模型下
   结构不可达,恒映射 forceExtDict(L2510-2517)实例化:lowPrefix=dst、
   dictStart=dict 数组首、checkOffset=dictSize<64KB。dictSize<0 或超过
   dict.size 在 C 侧为 UB(assert(dictSize>=0) 后 size_t 下溢/越界读),
   防御性报 -1 而非未定义行为。 */
public func LZ4_decompress_safe_usingDict(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32, dict: Array<UInt8>, dictSize: Int32): Int32 {
    if (srcSize < 0 || dstCapacity < 0) {
        return -1
    }
    if (dictSize == 0) {
        return LZ4_decompress_safe(src, srcSize, dst, dstCapacity)
    }
    if (dictSize < 0 || Int64(dictSize) > dict.size) {
        return -1
    }
    return Int32(LZ4_decompress_generic(src, Int64(srcSize), dst, 0, Int64(dstCapacity),
        false, 0, Some(dict), 0, Int64(dictSize)))
}

/* LZ4_decompress_safe_partial_usingDict(lz4.c L2753-2770):MIN(target, dst)
   + partial_decode + forceExtDict 的组合(L2754-2756 的 dictSize==0 →
   safe_partial;分离数组模型下无前缀分支)。 */
public func LZ4_decompress_safe_partial_usingDict(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32, targetOutputSize: Int32, dict: Array<UInt8>, dictSize: Int32): Int32 {
    if (srcSize < 0) {
        return -1
    }
    let cap: Int32 = if (targetOutputSize < dstCapacity) { targetOutputSize } else { dstCapacity }
    if (dictSize == 0) {
        return Int32(LZ4_decompress_generic(src, Int64(srcSize), dst, 0, Int64(cap),
            true, 0, None<Array<UInt8>>, 0, 0))
    }
    if (dictSize < 0 || Int64(dictSize) > dict.size) {
        return -1
    }
    return Int32(LZ4_decompress_generic(src, Int64(srcSize), dst, 0, Int64(cap),
        true, 0, Some(dict), 0, Int64(dictSize)))
}

/*-************************************
*  Streaming decode state (lz4.h L755-771; lz4.c L2580-2621)
**************************************/
/* 上游 LZ4_streamDecode_t_internal 四字段:{prefixSize, extDictSize,
   prefixEnd(指针), externalDict(指针)}。仓颉侧按“缓冲引用 + 索引”对
   建模(design §4.3 规则 4):prefixEnd → (prefixEndBuf, prefixEndIdx),
   externalDict → (externalBuf, externalStartIdx),字典区间为
   [externalStartIdx, externalStartIdx + extDictSize)。 */
public class LZ4_streamDecode_t {
    internal var prefixSize: Int64 = 0
    internal var extDictSize: Int64 = 0
    internal var prefixEndBuf: Option<Array<UInt8>> = None
    internal var prefixEndIdx: Int64 = 0
    internal var externalBuf: Option<Array<UInt8>> = None
    internal var externalStartIdx: Int64 = 0
}

/* LZ4_createStreamDecode(lz4.c L2583-2593):零初始化状态。 */
public func LZ4_createStreamDecode(): LZ4_streamDecode_t {
    return LZ4_streamDecode_t()
}

/* LZ4_freeStreamDecode(lz4.c L2596-2600):C 支持对 NULL free 返回 0;
   仓颉无空引用,GC 回收,恒 0。 */
public func LZ4_freeStreamDecode(s: LZ4_streamDecode_t): Int32 {
    return 0
}

/* LZ4_setStreamDecode(lz4.c L2608-2621):以外部字典初始化状态。
   prefixEnd = dictionary + dictSize(单次赋值;dictSize==0 时即字典基址
   索引 0,prefixSize==0 → 后续 continue 首块走 noDict 路径,等价无字典)。
   返回 1;dictSize<0 或 > dict.size 在 C 侧为 size_t 回绕/越界 UB,
   此处防御性返回 0(错误码)。 */
public func LZ4_setStreamDecode(s: LZ4_streamDecode_t, dict: Array<UInt8>, dictSize: Int32): Int32 {
    if (dictSize < 0 || Int64(dictSize) > dict.size) {
        return 0
    }
    s.prefixSize = Int64(dictSize)
    s.prefixEndBuf = Some(dict)                 /* prefixEnd = dictionary + dictSize */
    s.prefixEndIdx = Int64(dictSize)
    s.externalBuf = None
    s.extDictSize = 0
    return 1
}

/* LZ4_decoderRingBufferSize(lz4.c L2634-2640;宏见 lz4.h L493):
   65536 + 14 + maxBlockSize;maxBlockSize<0 或 >LZ4_MAX_INPUT_SIZE → 0,
   <16 提到 16。 */
public func LZ4_decoderRingBufferSize(maxBlockSize: Int32): Int32 {
    var mbs: Int32 = maxBlockSize
    if (mbs < 0) { return 0 }
    if (mbs > LZ4_MAX_INPUT_SIZE) { return 0 }
    if (mbs < 16) { mbs = 16 }
    return 65536 + 14 + mbs
}

/* 上游 `lz4sd->prefixEnd == (BYTE*)dest` 的指针相等判定,仓颉无引用
   同一性比较(== 是整数组内容相等),改为“滚动窗口内容等价”谓词:
   比较 (end1-k, end1] 与 (end2-k, end2](k = min(prefixSize, 65536))。
   LZ4 块内 offset ≤ 65535,解码只可能引用前缀最近 65535 字节,故对
   extDictSize==0 状态与同缓冲换位,本谓词与 C 指针判定输出等价。
   窄分歧角:窗口字节被复制到不同 Array(同 idx)且状态仍有活跃外
   字典(extDictSize≠0)且块内 offset 深于前缀时,C 走换向并报错、
   本侧走 doubleDict 或成功;须精确复刻 C 的调用方用 setStreamDecode
   重注入。代价上限 64KB/次,与块解码同阶。 */
private func lz4RollingWindowEquals(b1: Array<UInt8>, end1: Int64,
        b2: Array<UInt8>, end2: Int64, k: Int64): Bool {
    var i: Int64 = 0
    while (i < k) {
        if (b1[end1 - k + i] != b2[end2 - k + i]) {
            return false
        }
        i += 1
    }
    return true
}

/* LZ4_decompress_safe_continue(lz4.c L2648-2719),dest 以 (dstBuf, dstIdx)
   位置对表达(rolling 契约:dstBuf[dstIdx-前缀, dstIdx) 为已解码内容)。
   三场景逐行对照:
   (a) prefixSize==0(L2650-2657):首块,noDict 解码(= safe 语义,写往
       dstIdx 起);成功后记录 prefixSize=result、prefixEnd=dstIdx+result;
   (b) prefixEnd==dest(L2659-2666 滚动):prefixSize ≥ 64KB-1 → withPrefix64k
       实例化(lowPrefixIdx = dstIdx - 65536,L2502);否则 extDictSize==0 →
       withSmallPrefix(lowPrefixIdx = dstIdx - prefixSize,L2523-2529);
       否则双字典(小前缀 + 外字典组合,上游 doubleDict L2510-2517);
       成功后 prefixSize/前缀末位置累进;
   (c) 否则(L2667-2671 缓冲回绕/切换):旧前缀换向外字典
       (externalStartIdx = prefixEndIdx - prefixSize),forceExtDict 实例化
       (lowPrefixIdx = dstIdx);成功后 prefixSize=result 重置。
   result ≤ 0 原样返回(L2655/L2665/L2670);错误后状态与 C 一致不担保
   可复用((c) 已先写 extDict 字段,(a)/(b) 未动)。 */
public func LZ4_decompress_safe_continue(s: LZ4_streamDecode_t, src: Array<UInt8>, srcSize: Int32,
        dstBuf: Array<UInt8>, dstIdx: Int64, maxOutputSize: Int32): Int32 {
    if (srcSize < 0 || maxOutputSize < 0 || dstIdx < 0) {
        return -1
    }
    var result: Int64
    if (s.prefixSize == 0) {
        /* The first call, no dictionary yet(L2651;断言 extDictSize==0:
           新态与 setStreamDecode(size=0) 均满足) */
        result = LZ4_decompress_generic(src, Int64(srcSize), dstBuf, dstIdx,
            Int64(maxOutputSize), false, dstIdx, None<Array<UInt8>>, 0, 0)
        if (result <= 0) { return Int32(result) }
        s.prefixSize = result
        s.prefixEndBuf = Some(dstBuf)
        s.prefixEndIdx = dstIdx + result
        return Int32(result)
    }
    let k: Int64 = if (s.prefixSize < 65536) { s.prefixSize } else { 65536 }
    let rolling: Bool = match (s.prefixEndBuf) {
        case Some(b) => s.prefixEndIdx == dstIdx && lz4RollingWindowEquals(b, s.prefixEndIdx, dstBuf, dstIdx, k)
        case None => false
    }
    if (rolling) {
        /* They're rolling the current segment(L2659) */
        if (s.prefixSize >= 65536 - 1) {
            result = LZ4_decompress_generic(src, Int64(srcSize), dstBuf, dstIdx,
                Int64(maxOutputSize), false, dstIdx - 65536, None<Array<UInt8>>, 0, 0)
        } else if (s.extDictSize == 0) {
            result = LZ4_decompress_generic(src, Int64(srcSize), dstBuf, dstIdx,
                Int64(maxOutputSize), false, dstIdx - s.prefixSize, None<Array<UInt8>>, 0, 0)
        } else {
            result = LZ4_decompress_generic(src, Int64(srcSize), dstBuf, dstIdx,
                Int64(maxOutputSize), false, dstIdx - s.prefixSize,
                s.externalBuf, s.externalStartIdx, s.extDictSize)
        }
        if (result <= 0) { return Int32(result) }
        s.prefixSize += result
        s.prefixEndIdx += result
    } else {
        /* The buffer wraps around, or they're switching to another buffer(L2667) */
        s.extDictSize = s.prefixSize
        s.externalBuf = s.prefixEndBuf
        s.externalStartIdx = s.prefixEndIdx - s.prefixSize
        result = LZ4_decompress_generic(src, Int64(srcSize), dstBuf, dstIdx,
            Int64(maxOutputSize), false, dstIdx,
            s.externalBuf, s.externalStartIdx, s.extDictSize)
        if (result <= 0) { return Int32(result) }
        s.prefixSize = result
        s.prefixEndBuf = Some(dstBuf)
        s.prefixEndIdx = dstIdx + result
    }
    return Int32(result)
}
