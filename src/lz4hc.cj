// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream lib/lz4hc.c (HC high-compression mode).
// M4 Task 1: state family + level table + hash/count/pattern primitives +
// encodeSequence. The three compression cores (lz4mid 1-2 / hash-chain 3-9 /
// optimal 10-12) land in Tasks 2-4.

package lz4

/*-************************************
*  Compression levels (lz4hc.h L47-50)
**************************************/
public const LZ4HC_CLEVEL_MIN: Int32 = 2
public const LZ4HC_CLEVEL_DEFAULT: Int32 = 9
public const LZ4HC_CLEVEL_OPT_MIN: Int32 = 10
public const LZ4HC_CLEVEL_MAX: Int32 = 12

/* LZ4_sizeofStateHC:信息性常量 LZ4_STREAMHC_MINSIZE = 262200(lz4hc.h L259;
   hashTable 32768*4 + chainTable 65536*2 = 262144 + 56 其余字段),§4.4 ruling:
   仓颉状态由类承载,无裸缓冲尺寸可查,保留供 API 对照完整性。 */
public func LZ4_sizeofStateHC(): Int32 {
    return 262200
}

/*-************************************
*  HC streaming state (lz4hc.h L229-257 LZ4HC_CCtx_internal)
**************************************/
/* 上游为 char minStateSize[262200] 联合体 + 内部字段;仓颉侧改为类承载
   (设计 §4.4,ruling 同 LZ4_stream_t)。双段引用对模型(§4.3 规则 4,M3a
   解码侧先例):虚拟索引空间 v 为 UInt32,
     v ∈ [lowLimit, dictLimit) → dictBuf[dictStartIdx + (v - lowLimit)]
     v ∈ [dictLimit, …)       → prefixBuf[prefixStartIdx + (v - dictLimit)]
   C 的 end - prefixStart = prefixEndIdx - prefixStartIdx;prefixStart == NULL
   ⟺ prefixBuf.isNone();src == end ⟺ lz4SameBuffer && srcIdx == prefixEndIdx
   (Task 5 continue 消费)。字典/前缀缓冲不拷贝(loadDictHC/saveDictHC 为唯一
   例外,saveDictHC 显式拷贝),调用方保证存活 —— 与 C 生命周期契约一致。 */
public class LZ4_streamHC_t {
    internal var hashTable: Array<UInt32> = Array<UInt32>(32768, {_ => 0u32})
    internal var chainTable: Array<UInt16> = Array<UInt16>(65536, {_ => 0u16})
    internal var prefixBuf: Option<Array<UInt8>> = None
    internal var prefixStartIdx: Int64 = 0
    internal var prefixEndIdx: Int64 = 0
    internal var dictBuf: Option<Array<UInt8>> = None
    internal var dictStartIdx: Int64 = 0
    internal var dictLimit: UInt32 = 0u32
    internal var lowLimit: UInt32 = 0u32
    internal var nextToUpdate: UInt32 = 0u32
    internal var compressionLevel: Int32 = 0
    internal var favorDecSpeed: Bool = false
    internal var dirty: Bool = false
    internal var dictCtx: Option<LZ4_streamHC_t> = None
}

/*-************************************
*  Level definition (lz4hc.c L85-116)
**************************************/
/* 上游 lz4hc_strat_e 枚举(L86):lz4mid / lz4hc / lz4opt。 */
internal const LZ4HC_STRAT_MID: Int32 = 0
internal const LZ4HC_STRAT_HC: Int32 = 1
internal const LZ4HC_STRAT_OPT: Int32 = 2

/* cParams_t(L87-91):strat + 搜索次数 + targetLength(opt 解析的
   sufficient_len,兼 PA 优化的重复模式判定阈值)。 */
internal struct CParams {
    let strat: Int32
    let nbSearches: Int32
    let targetLength: UInt32
    init(strat: Int32, nbSearches: Int32, targetLength: UInt32) {
        this.strat = strat
        this.nbSearches = nbSearches
        this.targetLength = targetLength
    }
}

/* k_clTable(L92-106):索引即压缩级别 0..12(0/1 未用,MIN=2)。 */
internal let kClTable: Array<CParams> = [
    CParams(LZ4HC_STRAT_MID, 2, 16u32),       /* 0, unused */
    CParams(LZ4HC_STRAT_MID, 2, 16u32),       /* 1, unused */
    CParams(LZ4HC_STRAT_MID, 2, 16u32),       /* 2 */
    CParams(LZ4HC_STRAT_HC, 4, 16u32),        /* 3 */
    CParams(LZ4HC_STRAT_HC, 8, 16u32),        /* 4 */
    CParams(LZ4HC_STRAT_HC, 16, 16u32),       /* 5 */
    CParams(LZ4HC_STRAT_HC, 32, 16u32),       /* 6 */
    CParams(LZ4HC_STRAT_HC, 64, 16u32),       /* 7 */
    CParams(LZ4HC_STRAT_HC, 128, 16u32),      /* 8 */
    CParams(LZ4HC_STRAT_HC, 256, 16u32),      /* 9 */
    CParams(LZ4HC_STRAT_OPT, 96, 64u32),      /* 10 == LZ4HC_CLEVEL_OPT_MIN */
    CParams(LZ4HC_STRAT_OPT, 512, 128u32),    /* 11 */
    CParams(LZ4HC_STRAT_OPT, 16384, 4096u32), /* 12 == LZ4HC_CLEVEL_MAX */
]

/* LZ4HC_getCLevelParams(L108-116):cLevel < 1 → DEFAULT(9),> MAX → 12。 */
internal func lz4hcGetCLevelParams(cLevel: Int32): CParams {
    var lv = cLevel
    if (lv < 1) {                                             /* L112-113 */
        lv = LZ4HC_CLEVEL_DEFAULT
    }
    if (lv > LZ4HC_CLEVEL_MAX) {                              /* L114 */
        lv = LZ4HC_CLEVEL_MAX
    }
    return kClTable[Int64(lv)]
}

/*-************************************
*  Internal constants (lz4hc.c L76-77, L141-143; lz4hc.h L233-235)
**************************************/
internal const LZ4HC_HASH_LOG: Int64 = 15            /* lz4hc.h L233 */
internal const LZ4HC_HASHTABLESIZE: Int64 = 1 << 15  /* 32768, lz4hc.h L234 */
internal const LZ4MID_HASHLOG: Int64 = 14            /* lz4hc.c L142: HASH_LOG-1 */
internal const LZ4MID_HASHTABLESIZE: Int64 = 1 << 14 /* 16384, lz4hc.c L143 */
internal const OPTIMAL_ML: Int32 = 18                /* lz4hc.c L76: (ML_MASK-1)+MINMATCH */
internal const LZ4_OPT_NUM: Int32 = 4096             /* lz4hc.c L77: 1<<12 */

/*-************************************
*  Hashing (lz4hc.c L119-163)
**************************************/
/* LZ4HC_hashPtr(L120-122):HASH_FUNCTION = (i * 2654435761) >> ((MINMATCH*8)
   - LZ4HC_HASH_LOG) = >> 17,输出天然 < 32768。 */
internal func LZ4HC_hashPtr(p: CPointer<UInt8>, i: Int64): UInt32 {
    return (LZ4_readLE32(p, i) * 2654435761u32) >> 17u32
}

/* LZ4MID_hash4(L145):(v * 2654435761) >> (32-14) = >> 18,输出 < 16384。 */
internal func LZ4MID_hash4(v: UInt32): UInt32 {
    return (v * 2654435761u32) >> 18u32
}

internal func LZ4MID_hash4Ptr(p: CPointer<UInt8>, i: Int64): UInt32 {
    return LZ4MID_hash4(LZ4_readLE32(p, i))
}

/* LZ4MID_hash7(L147-149):哈希 64 位值的低 56 位 —— v << (64-56) 丢弃最高
   字节(LE 第 8 字节),56 位全参与;回绕乘(UInt64 自然回绕)。 */
internal func LZ4MID_hash7(v: UInt64): UInt32 {
    return UInt32(((v << 8) * 58295818150454627u64) >> 50)
}

/* LZ4MID_hash8Ptr(L151):hash7(readLE64)。 */
internal func LZ4MID_hash8Ptr(p: CPointer<UInt8>, i: Int64): UInt32 {
    return LZ4MID_hash7(LZ4_readLE64(p, i))
}

/*-************************************
*  Count match length (lz4hc.c L167-225)
**************************************/
/* LZ4HC_NbCommonBytes32,Little-Endian 分支(L179):__builtin_clz(val) >> 3
   —— 顶部连续零字节数 = 4 字节窗口的公共后缀长度(回看计数用)。
   无内建 clz,以自 MSB 逐字节探测等价实现(clz>>3 与"最高非零字节以上
   的完整零字节数"恒等:最高非零字节 k → 31-hi ∈ [8(3-k), 8(3-k)+7])。
   val != 0 由调用点保证(C assert;countBack 的 XOR 分支)。 */
internal func LZ4HC_nbCommonBytes32(v: UInt32): Int32 {
    var x = v
    var n: Int32 = 0
    while ((x & 0xFF000000u32) == 0u32) {
        x <<= 8
        n += 1
    }
    return n
}

/* LZ4HC_countBack(L202-225):自 ai/bi 向前(负方向)计公共字节数,返回负值。
   4 字节步进 XOR 粗扫 + 尾部逐字节收尾;min = max(aMin-ai, bMin-bi) 为
   允许回看的下界(两缓冲各自的索引下限,a/b 可为不同分配)。 */
internal func LZ4HC_countBack(a: CPointer<UInt8>, ai: Int64, b: CPointer<UInt8>, bi: Int64,
        aMin: Int64, bMin: Int64): Int32 {
    var back: Int32 = 0
    let min: Int32 = Int32(max(aMin - ai, bMin - bi))        /* L209 */
    while ((back - min) > 3) {                               /* L214 */
        let v: UInt32 = LZ4_readLE32(a, ai + Int64(back) - 4) ^
            LZ4_readLE32(b, bi + Int64(back) - 4)            /* L215 */
        if (v != 0u32) {
            return back - LZ4HC_nbCommonBytes32(v)           /* L217 */
        }
        back -= 4                                            /* L218 */
    }
    while ((back > min) &&
        (LZ4_read8(a, ai + Int64(back) - 1) == LZ4_read8(b, bi + Int64(back) - 1))) {   /* L221-223 */
        back -= 1
    }
    return back
}

/*-************************************
*  Chain table updates (lz4hc.c L228-230, L811-832)
**************************************/
/* DELTANEXTU16(table, pos) = table[(U16)pos](L228):链表索引按 65536 回绕。 */

/* LZ4HC_Insert(L811-832):将 [nextToUpdate, target) 的每个位置入哈希链。
   target = targetIp(相对 prefixPtr 的索引)+ prefixIdx(= dictLimit,虚拟
   基);delta = idx - hashTable[h] 为 U32 减法回绕后与 LZ4_DISTANCE_MAX
   (65535)比较(C 以 size_t 承载零扩展结果,语义一致),截断值经 (U16)
   写入 chainTable[(U16)idx]。 */
internal func LZ4HC_insert(s: LZ4_streamHC_t, prefixPtr: CPointer<UInt8>, targetIp: Int64): Unit {
    let prefixIdx: UInt32 = s.dictLimit                       /* L816 */
    let target: UInt32 = UInt32(targetIp) + prefixIdx         /* L817 */
    var idx: UInt32 = s.nextToUpdate                          /* L818 */
    while (idx < target) {                                    /* L822 */
        let h: UInt32 = LZ4HC_hashPtr(prefixPtr, Int64(idx - prefixIdx))   /* L823 */
        var delta: UInt32 = idx - s.hashTable[Int64(h)]       /* L824:U32 回绕 */
        if (delta > LZ4_DISTANCE_MAX) {                       /* L825 */
            delta = LZ4_DISTANCE_MAX
        }
        s.chainTable[Int64(idx & 0xFFFFu32)] = UInt16(delta)  /* L826:DELTANEXTU16 */
        s.hashTable[Int64(h)] = idx                           /* L827 */
        idx += 1
    }
    s.nextToUpdate = target                                   /* L831 */
}

/*-************************************
*  Init (lz4hc.c L236-259)
**************************************/
/* LZ4HC_clearTables(L236-240):hash 置 0、chain 按字节 0xFF 填充(u16 元素
   = 0xFFFF,链表"无前驱"标记)。 */
internal func LZ4HC_clearTables(s: LZ4_streamHC_t): Unit {
    var i: Int64 = 0
    while (i < s.hashTable.size) {
        s.hashTable[i] = 0u32
        i += 1
    }
    i = 0
    while (i < s.chainTable.size) {
        s.chainTable[i] = 0xFFFFu16
        i += 1
    }
}

/* LZ4HC_init_internal(L242-259):新块锚定。newStartingOffset = prefixLen +
   dictLimit,>1GB → clearTables 重锚 0(溢出防护);无条件 +64KB(使陈旧
   链表登记相对新位置必超 DISTANCE_MAX)。prefix 换新块(start/end 同点),
   extDict 段清空(lowLimit == dictLimit,C 置 dictStart=start,仓颉侧空段
   不解引用,dictStartIdx 同步 srcIdx 镜像 C 值)。 */
internal func LZ4HC_initInternal(s: LZ4_streamHC_t, srcBuf: Array<UInt8>, srcIdx: Int64): Unit {
    let bufferSize: UInt64 = UInt64(s.prefixEndIdx - s.prefixStartIdx)   /* L244 */
    var newStartingOffset: UInt64 = bufferSize + UInt64(s.dictLimit)     /* L245 */
    if (newStartingOffset > 0x40000000u64) {                             /* L248: 1 GB */
        LZ4HC_clearTables(s)
        newStartingOffset = 0
    }
    newStartingOffset += 65536u64                                        /* L252: 64 KB */
    s.nextToUpdate = UInt32(newStartingOffset)                           /* L253 */
    s.prefixBuf = Some(srcBuf)                                           /* L254-255 */
    s.prefixStartIdx = srcIdx
    s.prefixEndIdx = srcIdx
    s.dictStartIdx = srcIdx                                              /* L256: dictStart = start */
    s.dictBuf = None                    /* extDict 段空(lowLimit == dictLimit) */
    s.dictLimit = UInt32(newStartingOffset)                              /* L257 */
    s.lowLimit = UInt32(newStartingOffset)                               /* L258 */
}

/*-************************************
*  Encode (lz4hc.c L289-380)
**************************************/
/* LZ4HC_encodeSequence(L292-380):单条序列(token + literals + offset +
   matchlength)编码。C 以 const BYTE** 别名宏 UPDATABLE(ip, op, anchor)
   即时写回调用方变量;仓颉封装为**多返回元组**:
       (bufferIssue, 新 ip, 新 op, 新 anchor): (Int32, Int64, Int64, Int64)
   —— ip/anchor 为 src 侧索引、op 为 dst 侧索引;成功返回 (0, ip+matchLength,
   op 终值, ip+matchLength)(L372-373);buffer issue 返回 1,且 ip/anchor 保持
   入参、op 反映 C 别名语义下已推进的值(token 已消费/字面量已写,L330 检查
   在写 token 之前、L357 检查在 offset 之后 —— 调用方按上游 goto
   _dest_overflow 语义取用)。Task 2+ 三个压缩核心在单一 unsafe 域内调用,
   纯指针运算、无分配。limit 取 lz4.cj 的 LZ4_OUTPUT_* 指令(notLimited==0,
   上游 L328 LZ4_STATIC_ASSERT 保证 if (limit) 真值判断与枚举一致)。 */
internal func LZ4HC_encodeSequence(src: CPointer<UInt8>, ipIn: Int64,
        dst: CPointer<UInt8>, opIn: Int64, anchorIn: Int64,
        matchLength: Int32, offset: Int32, limit: Int32, oend: Int64): (Int32, Int64, Int64, Int64) {
    var ip = ipIn
    var op = opIn
    var anchor = anchorIn
    let tokenIdx: Int64 = op                                 /* L305: token = op++ */
    op += 1

    /* Encode Literal length (L326-347) */
    let litLen: Int64 = ip - anchor                          /* L327 */
    if (limit != LZ4_OUTPUT_NOT_LIMITED &&                   /* L330 */
            (op + litLen / 255 + litLen + (2 + 1 + LZ4_LASTLITERALS) > oend)) {
        return (1, ip, op, anchor)
    }
    if (litLen >= LZ4_RUN_MASK) {                            /* L335-339 */
        var len: Int64 = litLen - LZ4_RUN_MASK
        LZ4_write8(dst, tokenIdx, UInt8((LZ4_RUN_MASK << LZ4_ML_BITS) & 0xFF))
        while (len >= 255) {
            LZ4_write8(dst, op, 255u8)
            op += 1
            len -= 255
        }
        LZ4_write8(dst, op, UInt8(len))
        op += 1
    } else {
        LZ4_write8(dst, tokenIdx, UInt8(litLen << LZ4_ML_BITS))   /* L341 */
    }
    /* Copy Literals */
    LZ4_wildCopy8(dst, op, src, anchor, litLen)              /* L345 */
    op += litLen                                             /* L346 */

    /* Encode Offset (L349-352);offset ∈ (0, 65535] 由调用方保证 */
    LZ4_writeLE16(dst, op, UInt16(offset))                   /* L352 */
    op += 2

    /* Encode MatchLength (L354-369) */
    var mlCode: Int64 = Int64(matchLength) - LZ4_MINMATCH    /* L356 */
    if (limit != LZ4_OUTPUT_NOT_LIMITED &&
            (op + mlCode / 255 + (1 + LZ4_LASTLITERALS) > oend)) {   /* L357 */
        return (1, ip, op, anchor)
    }
    if (mlCode >= LZ4_ML_MASK) {                             /* L361-366 */
        LZ4_write8(dst, tokenIdx, LZ4_read8(dst, tokenIdx) + UInt8(LZ4_ML_MASK))
        mlCode -= LZ4_ML_MASK
        while (mlCode >= 510) {                              /* L364 */
            LZ4_write8(dst, op, 255u8)
            LZ4_write8(dst, op + 1, 255u8)
            op += 2
            mlCode -= 510
        }
        if (mlCode >= 255) {                                 /* L365 */
            mlCode -= 255
            LZ4_write8(dst, op, 255u8)
            op += 1
        }
        LZ4_write8(dst, op, UInt8(mlCode))                   /* L366 */
        op += 1
    } else {
        LZ4_write8(dst, tokenIdx, LZ4_read8(dst, tokenIdx) + UInt8(mlCode))   /* L368 */
    }

    /* Prepare next loop (L371-373) */
    ip += Int64(matchLength)
    anchor = ip
    return (0, ip, op, anchor)
}

/*-************************************
*  Repetitive-pattern helpers (lz4hc.c L841-908)
**************************************/
/* LZ4HC_rotatePattern(L841-846):rotate 按字节取模(&3)后左移 8 位,rotl32。 */
internal func LZ4HC_rotatePattern(rotate: UInt64, pattern: UInt32): UInt32 {
    let bitsToRotate: UInt64 = (rotate & 3u64) << 3          /* L843: sizeof(U32)=4 */
    if (bitsToRotate == 0u64) {
        return pattern
    }
    let r: UInt32 = UInt32(bitsToRotate)
    return (pattern << r) | (pattern >> (32u32 - r))         /* L837: LZ4HC_rotl32 */
}

/* LZ4HC_countPattern(L848-878):自 ip 起 8 字节粗扫(64 位平台 reg_t=8,
   pattern64 = pattern32 | pattern32<<32)+ 字节收尾(patternByte 逐字节右移
   匹配)。pattern32 须为 1/2/4 字节周期样本(非 3)。 */
internal func LZ4HC_countPattern(p: CPointer<UInt8>, ipIn: Int64, iEnd: Int64,
        pattern32: UInt32): UInt32 {
    var ip = ipIn
    let iStart: Int64 = ip
    let pattern: UInt64 = UInt64(pattern32) | (UInt64(pattern32) << 32)   /* L854-855 */
    while (ip < iEnd - 7) {                                  /* L857: sizeof(reg_t)-1 */
        let diff: UInt64 = LZ4_readLE64(p, ip) ^ pattern     /* L858: LZ4_read_ARCH */
        if (diff == 0u64) {
            ip += 8
            continue
        }
        ip += LZ4_nbCommonBytes(diff)                        /* L860 */
        return UInt32(ip - iStart)
    }
    /* Little-Endian 字节收尾(L864-868) */
    var patternByte: UInt64 = pattern
    while ((ip < iEnd) && (LZ4_read8(p, ip) == UInt8(patternByte))) {
        ip += 1
        patternByte >>= 8
    }
    return UInt32(ip - iStart)
}

/* LZ4HC_reverseCountPattern(L880-898):逆向计数。4 字节窗口步进 + 尾部自
   pattern 的 MSB 字节(&pattern + 3,LE 即 byte3)向下逐字节比较。 */
internal func LZ4HC_reverseCountPattern(p: CPointer<UInt8>, ipIn: Int64, iLow: Int64,
        pattern: UInt32): UInt32 {
    var ip = ipIn
    let iStart: Int64 = ip
    while (ip >= iLow + 4) {                                 /* L888 */
        if (LZ4_readLE32(p, ip - 4) != pattern) {
            break
        }
        ip -= 4
    }
    var byteIdx: Int64 = 3                                   /* L892: bytePtr = &pattern + 3 */
    while (ip > iLow) {                                      /* L893 */
        if (LZ4_read8(p, ip - 1) != UInt8((pattern >> (UInt32(byteIdx) * 8)) & 0xFFu32)) {
            break
        }
        ip -= 1
        byteIdx -= 1
    }
    return UInt32(iStart - ip)
}

/* LZ4HC_protectDictEnd(L900-908):match 是否落在字典末 3 字节之内(4 字节
   MINMATCH 读取会溢出);true = 安全。U32 回绕减法语义逐字复刻。 */
internal func LZ4HC_protectDictEnd(dictLimit: UInt32, matchIndex: UInt32): Bool {
    return ((dictLimit - 1u32) - matchIndex) >= 3u32         /* L907 */
}

/*-************************************
*  Streaming state family (lz4hc.c L1601-1671)
**************************************/
/* LZ4_createStreamHC(L1603-1610):ALLOC_AND_ZERO + setCompressionLevel(DEFAULT);
   仓颉构造器零态 + initStreamHC 等价。 */
public func LZ4_createStreamHC(): LZ4_streamHC_t {
    let s = LZ4_streamHC_t()
    LZ4_initStreamHC(s)
    return s
}

/* LZ4_freeStreamHC(L1612-1618):C 释放堆内存(支持 NULL)返回 0;仓颉无空
   引用、GC 回收,恒 0。 */
public func LZ4_freeStreamHC(s: LZ4_streamHC_t): Int32 {
    return 0
}

/* LZ4_initStreamHC(L1622-1635):全字段 MEM_INIT(含两表)+ setCompressionLevel
   (DEFAULT)。C 的失败模式(NULL 缓冲 / size < sizeof / 未对齐,L1627-1629)
   对类状态不可达,恒成功返回 0(§4.4 先例:LZ4_initStream 同型)。 */
public func LZ4_initStreamHC(state: LZ4_streamHC_t): Int32 {
    var i: Int64 = 0
    while (i < state.hashTable.size) {                       /* L1632: MEM_INIT */
        state.hashTable[i] = 0u32
        i += 1
    }
    i = 0
    while (i < state.chainTable.size) {
        state.chainTable[i] = 0u16
        i += 1
    }
    state.prefixBuf = None
    state.prefixStartIdx = 0
    state.prefixEndIdx = 0
    state.dictBuf = None
    state.dictStartIdx = 0
    state.dictLimit = 0u32
    state.lowLimit = 0u32
    state.nextToUpdate = 0u32
    state.compressionLevel = 0
    state.favorDecSpeed = false
    state.dirty = false
    state.dictCtx = None
    LZ4_setCompressionLevel(state, LZ4HC_CLEVEL_DEFAULT)     /* L1633 */
    return 0
}

/* LZ4_resetStreamHC(L1638-1642):全量 init + 级别设置。 */
public func LZ4_resetStreamHC(s: LZ4_streamHC_t, compressionLevel: Int32): Unit {
    LZ4_initStreamHC(s)                                      /* L1640 */
    LZ4_setCompressionLevel(s, compressionLevel)             /* L1641 */
}

/* LZ4_resetStreamHC_fast(L1644-1658):dirty → 全量 init;净态仅平移 dictLimit
   (+= prefixLen)、摘除前缀缓冲与 dictCtx —— 表内容保留(脏表复用,陈旧
   登记由 initInternal 的 +64KB 锚保证不可达)。 */
public func LZ4_resetStreamHC_fast(s: LZ4_streamHC_t, compressionLevel: Int32): Unit {
    if (s.dirty) {                                           /* L1648 */
        LZ4_initStreamHC(s)                                  /* L1649 */
    } else {
        /* L1651: assert(end >= prefixStart) —— prefixLen 无负值 */
        s.dictLimit += UInt32((s.prefixEndIdx - s.prefixStartIdx) & 0xFFFFFFFFi64)   /* L1652 */
        s.prefixBuf = None                                   /* L1653-1654: prefixStart = end = NULL */
        s.prefixStartIdx = 0
        s.prefixEndIdx = 0
        s.dictCtx = None                                     /* L1655 */
    }
    LZ4_setCompressionLevel(s, compressionLevel)             /* L1657 */
}

/* LZ4_setCompressionLevel(L1660-1666):钳制 <1 → DEFAULT(9)、>12 → 12。 */
public func LZ4_setCompressionLevel(s: LZ4_streamHC_t, compressionLevel: Int32): Unit {
    var lv = compressionLevel
    if (lv < 1) {                                            /* L1663 */
        lv = LZ4HC_CLEVEL_DEFAULT
    }
    if (lv > LZ4HC_CLEVEL_MAX) {                             /* L1664 */
        lv = LZ4HC_CLEVEL_MAX
    }
    s.compressionLevel = lv
}

/* LZ4_favorDecompressionSpeed(L1668-1671):favor != 0 置位(opt 解析的
   match 长度偏置,Task 4 消费)。 */
public func LZ4_favorDecompressionSpeed(s: LZ4_streamHC_t, favor: Int32): Unit {
    s.favorDecSpeed = favor != 0
}
