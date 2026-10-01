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
*  Search machine (lz4hc.c L914-1150)
**************************************/
/* dictCtx_directive 枚举(lz4hc.c L80-84):noDictCtx=0 / usingDictCtxHc=1。
   T5 落 dictCtx 三路分派后 usingDictCtxHc 才随流式 API 可达。 */
internal const LZ4HC_DICT_NODICTCTX: Int32 = 0
internal const LZ4HC_DICT_USINGDICTCTXHC: Int32 = 1

/* LZ4HC_match_t(L383-387):off = ipIndex-matchIndex(正值),len = match 长,
   back = 负值(match 向前回看的公共字节数)。字段须可变(lazy 纠正改写
   m1.len/m2.len)。 */
internal struct LZ4HC_match {
    var off: Int32
    var len: Int32
    var back: Int32
    init(off: Int32, len: Int32, back: Int32) {
        this.off = off
        this.len = len
        this.back = back
    }
}

/* repeat_state_e(L1016-1018):PA 重复模式探测状态。 */
internal const LZ4HC_REP_UNTESTED: Int32 = 0
internal const LZ4HC_REP_NOT: Int32 = 1
internal const LZ4HC_REP_CONFIRMED: Int32 = 2

/* LZ4HC_InsertAndGetWiderMatch(L914-1136 全量):链表搜索机。前置:ip/
   iLowLimit/iHighLimit 均为相对 prefixPtr(= prefixStart 指针)的索引;
   dictBase 为 extDict 段基(dictStart 等价,段空 [lowLimit==dictLimit]
   时解引用不可达,可传占位指针);dictCtxBase 为 dictCtx 的 prefixStart
   指针(仅 dict==usingDictCtxHc 且 s.dictCtx 存在时解引用)。虚拟索引
   空间 v:prefix 段 v ∈ [dictLimit, …) ⟺ prefixPtr[v - dictLimit];dict 段
   v ∈ [lowLimit, dictLimit) ⟺ dictBase[v - lowLimit]。ipIndex/matchIndex
   等全部 UInt32 回绕语义逐字复刻。含 chainSwap(L996-1017)、PA 重复模式
   优化(L1020-1091)、extDict 跨段两段计数(L983-985,镜像解码侧
   LZ4_count2 先例)、dictCtx 咨询块(L1098-1127 —— 本任务一并移植,
   T5 流式 API 才使其可达)。 */
internal func LZ4HC_insertAndGetWiderMatch(s: LZ4_streamHC_t,
        prefixPtr: CPointer<UInt8>, dictBase: CPointer<UInt8>, dictCtxBase: CPointer<UInt8>,
        ip: Int64, iLowLimit: Int64, iHighLimit: Int64, longestIn: Int32,
        maxNbAttempts: Int32, patternAnalysis: Bool, chainSwap: Bool,
        dict: Int32, favorDecSpeed: Bool): LZ4HC_match {
    let prefixIdx: UInt32 = s.dictLimit                            /* L929 */
    let ipIndex: UInt32 = UInt32(ip) + prefixIdx                   /* L930 */
    let withinStartDistance: Bool = (s.lowLimit + (LZ4_DISTANCE_MAX + 1u32)) > ipIndex   /* L931: U32 回绕 */
    let lowestMatchIndex: UInt32 = if (withinStartDistance) {      /* L932 */
        s.lowLimit
    } else {
        ipIndex - LZ4_DISTANCE_MAX
    }
    let dictIdx: UInt32 = s.lowLimit                               /* L934 */
    let dictEndIdx: Int64 = Int64(prefixIdx - dictIdx)             /* L935: dictEnd - dictStart */
    let lookBackLength: Int32 = Int32(ip - iLowLimit)              /* L936 */
    var nbAttempts: Int32 = maxNbAttempts
    var matchChainPos: UInt32 = 0u32
    let pattern: UInt32 = LZ4_readLE32(prefixPtr, ip)              /* L939 */
    var matchIndex: UInt32 = 0u32
    var repeat: Int32 = LZ4HC_REP_UNTESTED
    var srcPatternLength: UInt64 = 0u64
    var offset: Int32 = 0
    var sBack: Int32 = 0
    var longest: Int32 = longestIn

    LZ4HC_insert(s, prefixPtr, ip)                                 /* L947 */
    matchIndex = s.hashTable[Int64(LZ4HC_hashPtr(prefixPtr, ip))]  /* L948 */

    while ((matchIndex >= lowestMatchIndex) && (nbAttempts > 0)) { /* L952 */
        var matchLength: Int32 = 0
        nbAttempts -= 1
        if (favorDecSpeed && (ipIndex - matchIndex < 8u32)) {      /* L956: U32 */
            /* 有意跳过 offset < 8 的候选(解压速度优先) */
        } else if (matchIndex >= prefixIdx) {                      /* L959: 当前 prefix 段内 */
            let matchPtrIdx: Int64 = Int64(matchIndex - prefixIdx)
            if (LZ4_readLE16(prefixPtr, iLowLimit + Int64(longest) - 1) ==
                    LZ4_readLE16(prefixPtr, matchPtrIdx - Int64(lookBackLength) + Int64(longest) - 1)) {   /* L963 */
                if (LZ4_readLE32(prefixPtr, matchPtrIdx) == pattern) {   /* L964 */
                    let back: Int32 = if (lookBackLength != 0) {   /* L965 */
                        LZ4HC_countBack(prefixPtr, ip, prefixPtr, matchPtrIdx, iLowLimit, 0)
                    } else {
                        0
                    }
                    matchLength = Int32(LZ4_MINMATCH) +
                        Int32(LZ4_count(prefixPtr, ip + LZ4_MINMATCH, matchPtrIdx + LZ4_MINMATCH, iHighLimit))   /* L966 */
                    matchLength -= back                            /* L967 */
                    if (matchLength > longest) {
                        longest = matchLength
                        offset = Int32(ipIndex - matchIndex)       /* L970: U32 减 */
                        sBack = back
                    }
                }
            }
        } else {                                                   /* L975: extDict 段 [lowestMatchIndex, dictLimit) */
            let matchPtrIdx: Int64 = Int64(matchIndex - dictIdx)   /* dictBase 侧索引 */
            if ((matchIndex <= prefixIdx - 4u32) &&                /* L978: U32 */
                    (LZ4_readLE32(dictBase, matchPtrIdx) == pattern)) {
                var back: Int32 = 0
                var vLimit: Int64 = ip + Int64(prefixIdx - matchIndex)   /* L981 */
                if (vLimit > iHighLimit) {
                    vLimit = iHighLimit                            /* L982 */
                }
                matchLength = Int32(LZ4_count2(prefixPtr, ip + LZ4_MINMATCH,
                    dictBase, matchPtrIdx + LZ4_MINMATCH, vLimit)) + Int32(LZ4_MINMATCH)   /* L983: 跨段计数 */
                if ((ip + Int64(matchLength) == vLimit) && (vLimit < iHighLimit)) {   /* L984 */
                    matchLength += Int32(LZ4_count(prefixPtr, ip + Int64(matchLength), 0, iHighLimit))   /* L985: 前缀段续数 */
                }
                back = if (lookBackLength != 0) {                  /* L986 */
                    LZ4HC_countBack(prefixPtr, ip, dictBase, matchPtrIdx, iLowLimit, 0)
                } else {
                    0
                }
                matchLength -= back                                /* L987 */
                if (matchLength > longest) {
                    longest = matchLength
                    offset = Int32(ipIndex - matchIndex)           /* L990 */
                    sBack = back
                }
            }
        }

        if (chainSwap && matchLength == longest) {                 /* L996: 更优链选取 */
            /* assert(lookBackLength == 0):仅前向搜索 */
            if (matchIndex + UInt32(longest) <= ipIndex) {         /* L998: U32 */
                let kTrigger: Int32 = 4                            /* L999 */
                var distanceToNextMatch: UInt32 = 1u32
                let end: Int32 = longest - Int32(LZ4_MINMATCH) + 1 /* L1001 */
                var step: Int32 = 1
                var accel: Int32 = 1 << kTrigger                   /* L1003 */
                var pos: Int32 = 0
                while (pos < end) {                                /* L1005 */
                    let candidateDist: UInt32 = UInt32(s.chainTable[Int64((matchIndex + UInt32(pos)) & 0xFFFFu32)])   /* L1006 */
                    step = accel >> kTrigger                       /* L1007: step = accel++ >> kTrigger */
                    accel += 1
                    if (candidateDist > distanceToNextMatch) {
                        distanceToNextMatch = candidateDist
                        matchChainPos = UInt32(pos)
                        accel = 1 << kTrigger                      /* L1011 */
                    }
                    pos += step
                }
                if (distanceToNextMatch > 1u32) {                  /* L1013 */
                    if (distanceToNextMatch > matchIndex) {
                        break                                      /* L1014: 防 U32 下溢 */
                    }
                    matchIndex -= distanceToNextMatch              /* L1015 */
                    continue
                }
            }
        }

        /* PA 重复模式优化(L1019-1091) */
        let distNextMatch: UInt32 = UInt32(s.chainTable[Int64(matchIndex & 0xFFFFu32)])   /* L1019 */
        if (patternAnalysis && distNextMatch == 1u32 && matchChainPos == 0u32) {  /* L1020 */
            let matchCandidateIdx: UInt32 = matchIndex - 1u32      /* L1021 */
            if (repeat == LZ4HC_REP_UNTESTED) {                    /* L1023 */
                if (((pattern & 0xFFFFu32) == (pattern >> 16)) &&  /* L1024-1025:C 以 & 连接两布尔,逻辑等价 && */
                        ((pattern & 0xFFu32) == (pattern >> 24))) {
                    repeat = LZ4HC_REP_CONFIRMED
                    srcPatternLength = UInt64(LZ4HC_countPattern(prefixPtr, ip + 4, iHighLimit, pattern)) + 4u64   /* L1028 */
                } else {
                    repeat = LZ4HC_REP_NOT
                }
            }
            if ((repeat == LZ4HC_REP_CONFIRMED) && (matchCandidateIdx >= lowestMatchIndex) &&
                    LZ4HC_protectDictEnd(prefixIdx, matchCandidateIdx)) {   /* L1032-1033 */
                let extDict: Bool = matchCandidateIdx < prefixIdx  /* L1034 */
                let matchPtrBase: CPointer<UInt8> = if (extDict) { dictBase } else { prefixPtr }   /* L1035 */
                let matchPtrIdx: Int64 = Int64(matchCandidateIdx) -
                    Int64(if (extDict) { dictIdx } else { prefixIdx })
                if (LZ4_readLE32(matchPtrBase, matchPtrIdx) == pattern) {   /* L1036: 好候选 */
                    let iLimitIdx: Int64 = if (extDict) { dictEndIdx } else { iHighLimit }   /* L1037 */
                    var forwardPatternLength: UInt64 = UInt64(LZ4HC_countPattern(matchPtrBase,
                        matchPtrIdx + 4, iLimitIdx, pattern)) + 4u64                             /* L1038 */
                    if (extDict && (matchPtrIdx + Int64(forwardPatternLength) == iLimitIdx)) {   /* L1039 */
                        let rotatedPattern = LZ4HC_rotatePattern(forwardPatternLength, pattern)
                        forwardPatternLength += UInt64(LZ4HC_countPattern(prefixPtr, 0, iHighLimit, rotatedPattern))   /* L1041: 前缀段续数 */
                    }
                    let lowestMatchPtrIdx: Int64 = 0               /* L1043: lowestMatchPtr = dictStart/prefixStart(均基址) */
                    var backLength: UInt64 = UInt64(LZ4HC_reverseCountPattern(matchPtrBase, matchPtrIdx, lowestMatchPtrIdx, pattern))   /* L1044 */
                    var currentSegmentLength: UInt64 = 0u64
                    if ((!extDict) && (matchPtrIdx - Int64(backLength) == 0) && (dictIdx < prefixIdx)) {   /* L1046-1048: matchPtr - backLength == prefixPtr */
                        let rotatedPattern = LZ4HC_rotatePattern(UInt64(0u32 - UInt32(backLength)), pattern)   /* L1049: (U32)(-(int)backLength) */
                        backLength += UInt64(LZ4HC_reverseCountPattern(dictBase, dictEndIdx, 0, rotatedPattern))   /* L1050: 字典段跨接 */
                    }
                    /* backLength 不越过 lowestMatchIndex(L1053,全 U32) */
                    let raw = matchCandidateIdx - UInt32(backLength)
                    let floorIdx = if (raw > lowestMatchIndex) { raw } else { lowestMatchIndex }
                    backLength = UInt64(matchCandidateIdx - floorIdx)
                    currentSegmentLength = backLength + forwardPatternLength      /* L1055 */
                    if ((currentSegmentLength >= srcPatternLength) &&            /* L1057: 段长足以容纳完整 srcPattern */
                            (forwardPatternLength <= srcPatternLength)) {        /* L1058: 尚未推进到该位置 */
                        let newMatchIndex: UInt32 = matchCandidateIdx + UInt32(forwardPatternLength) - UInt32(srcPatternLength)   /* L1059: U32 */
                        if (LZ4HC_protectDictEnd(prefixIdx, newMatchIndex)) {
                            matchIndex = newMatchIndex              /* L1061 */
                        } else {
                            matchIndex = prefixIdx                  /* L1065: 仅可能起点在 prefix 末 3 字节 */
                        }
                    } else {
                        let newMatchIndex: UInt32 = matchCandidateIdx - UInt32(backLength)   /* L1068: 段内最远位置 */
                        if (!LZ4HC_protectDictEnd(prefixIdx, newMatchIndex)) {
                            matchIndex = prefixIdx                  /* L1071 */
                        } else {
                            matchIndex = newMatchIndex
                            if (lookBackLength == 0) {              /* L1074: 无回看可能 */
                                let maxML: UInt64 = if (currentSegmentLength < srcPatternLength) {   /* L1075: MIN */
                                    currentSegmentLength
                                } else {
                                    srcPatternLength
                                }
                                if (UInt64(Int64(longest)) < maxML) {
                                    if ((ipIndex - matchIndex) > LZ4_DISTANCE_MAX) {
                                        break                       /* L1078: 距离超窗 */
                                    }
                                    longest = Int32(maxML)          /* L1080 */
                                    offset = Int32(ipIndex - matchIndex)   /* L1081 */
                                    /* assert(sBack == 0) */
                                }
                                let distToNextPattern: UInt32 = UInt32(s.chainTable[Int64(matchIndex & 0xFFFFu32)])   /* L1085 */
                                if (distToNextPattern > matchIndex) {
                                    break                           /* L1086: 防下溢 */
                                }
                                matchIndex -= distToNextPattern     /* L1087 */
                            }
                        }
                    }
                    continue                                        /* L1089 */
                }
            }
        }   /* PA 优化结束 */

        /* 沿当前链回退(L1094) */
        matchIndex -= UInt32(s.chainTable[Int64((matchIndex + matchChainPos) & 0xFFFFu32)])
    }

    /* dictCtx 咨询块(L1098-1127):自家链耗尽后借 dictCtx 的表续查。
       本任务无入口可达(dictCtx 仅 T5 流式 API 挂接),随函数体一并
       移植;dictEndOffset/matchIndex 平移均 U32。 */
    if (dict == LZ4HC_DICT_USINGDICTCTXHC && nbAttempts > 0 && withinStartDistance) {
        match (s.dictCtx) {
            case Some(dctx) =>
                let dictEndOffset: UInt64 = UInt64(dctx.prefixEndIdx - dctx.prefixStartIdx) + UInt64(dctx.dictLimit)   /* L1101 */
                var dictMatchIndex: UInt32 = dctx.hashTable[Int64(LZ4HC_hashPtr(prefixPtr, ip))]   /* L1102 */
                matchIndex = dictMatchIndex + lowestMatchIndex - UInt32(dictEndOffset)   /* L1104 */
                while ((ipIndex - matchIndex <= LZ4_DISTANCE_MAX) && (nbAttempts > 0)) {   /* L1106: C 后缀减予定序 */
                    nbAttempts -= 1
                    let matchPtrIdx: Int64 = Int64(dictMatchIndex) - Int64(dctx.dictLimit) /* L1107: dictCtx prefixStart - dictLimit + idx */
                    if (LZ4_readLE32(dictCtxBase, matchPtrIdx) == pattern) {   /* L1109 */
                        var back: Int32 = 0
                        var vLimit: Int64 = ip + Int64(dictEndOffset - UInt64(dictMatchIndex))   /* L1112 */
                        if (vLimit > iHighLimit) {
                            vLimit = iHighLimit
                        }
                        var mlt: Int32 = Int32(LZ4_count2(prefixPtr, ip + LZ4_MINMATCH,
                            dictCtxBase, matchPtrIdx + LZ4_MINMATCH, vLimit)) + Int32(LZ4_MINMATCH)   /* L1114: 跨段计数 */
                        back = if (lookBackLength != 0) {           /* L1115: bMin = dictCtx->prefixStart */
                            LZ4HC_countBack(prefixPtr, ip, dictCtxBase, matchPtrIdx, iLowLimit, 0)
                        } else {
                            0
                        }
                        mlt -= back
                        if (mlt > longest) {
                            longest = mlt
                            offset = Int32(ipIndex - matchIndex)    /* L1119 */
                            sBack = back
                        }
                    }
                    let nextOffset: UInt32 = UInt32(dctx.chainTable[Int64(dictMatchIndex & 0xFFFFu32)])   /* L1124 */
                    dictMatchIndex -= nextOffset
                    matchIndex -= nextOffset
                }
            case None => ()
        }
    }

    return LZ4HC_match(offset, longest, sBack)                      /* L1129-1135 */
}

/* LZ4HC_InsertAndFindBestMatch(L1138-1150):iLowLimit==ip 使 wider 不得
   向前搜索;longest=MINMATCH-1、chainSwap=0、favorCompressionRatio。 */
internal func LZ4HC_insertAndFindBestMatch(s: LZ4_streamHC_t,
        prefixPtr: CPointer<UInt8>, dictBase: CPointer<UInt8>, dictCtxBase: CPointer<UInt8>,
        ip: Int64, iLimit: Int64, maxNbAttempts: Int32,
        patternAnalysis: Bool, dict: Int32): LZ4HC_match {
    return LZ4HC_insertAndGetWiderMatch(s, prefixPtr, dictBase, dictCtxBase,
        ip, ip, iLimit, Int32(LZ4_MINMATCH) - 1, maxNbAttempts, patternAnalysis,
        false /* chainSwap */, dict, false /* favorCompressionRatio */)
}

/*-************************************
*  Hash-chain compression core (lz4hc.c L1159-1407)
**************************************/
/* LZ4HC_compress_hashChain(L1159-1407):lazy match(_Search2/_Search3 状态
   机)压缩核心。前置:1 ≤ srcSize ≤ LZ4_MAX_INPUT_SIZE、maxOutputSize ≥ 1
   (清洗在 generic_internal 完成)。ip/anchor/start0/2/3 与 op 均为相对
   src(= prefixStart 指针)与 dst 基址的索引;返回 (cSize, consumed),
   consumed 即 C 的 *srcSizePtr 出值(L1198 先置 0,末尾写 ip;limitedOutput
   失败保持 0)。C 的 goto 以 inSearch2(重入 _Search2)/goSearch2·goMain
   (自 _Search3 转出)/overflow(→ _dest_overflow)标志重组,转移条件逐字
   保持。encodeSequence 的 buffer-issue 契约:issue 时 ip/anchor 保持入参
   值、op 取返回值;fillOutput 经 _dest_overflow 以 optr 恢复后自适配。 */
internal func LZ4HC_compress_hashChain(s: LZ4_streamHC_t,
        src: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, maxOutputSize: Int64,
        maxNbAttempts: Int32, limit: Int32, dict: Int32): (Int64, Int64) {
    let inputSize: Int64 = srcSize
    let patternAnalysis: Bool = maxNbAttempts > 128                 /* L1171: levels 9+ */

    let iend: Int64 = inputSize
    let mflimit: Int64 = iend - LZ4_MFLIMIT
    let matchlimit: Int64 = iend - LZ4_LASTLITERALS

    var ip: Int64 = 0
    var anchor: Int64 = 0
    var op: Int64 = 0
    var optr: Int64 = 0
    var oend: Int64 = maxOutputSize

    var start0: Int64 = 0
    var start2: Int64 = 0
    var start3: Int64 = 0
    var m0 = LZ4HC_match(0, 0, 0)
    var m1 = LZ4HC_match(0, 0, 0)
    var m2 = LZ4HC_match(0, 0, 0)
    var m3 = LZ4HC_match(0, 0, 0)
    let nomatch = LZ4HC_match(0, 0, 0)

    var overflow = false                                            /* goto _dest_overflow */

    if (limit == LZ4_OUTPUT_FILL) {
        oend -= LZ4_LASTLITERALS                                   /* L1199: fillOutput 尾量预留 hack */
    }

    if (inputSize >= LZ4_minLength) {                              /* L1200: 小输入全字面量 */
        while (ip <= mflimit && !overflow) {                       /* L1203: Main Loop */
            m1 = LZ4HC_insertAndFindBestMatch(s, src, dictQ, dictCtxQ,
                ip, matchlimit, maxNbAttempts, patternAnalysis, dict)   /* L1204 */
            if (m1.len < Int32(LZ4_MINMATCH)) {
                ip += 1
                continue                                           /* L1205 */
            }
            start0 = ip                                            /* L1208: 保存,防跳过过多 */
            m0 = m1

            var inSearch2 = true
            while (inSearch2 && !overflow) {                       /* _Search2(L1210 标签) */
                inSearch2 = false
                if (ip + Int64(m1.len) <= mflimit) {              /* L1212 */
                    start2 = ip + Int64(m1.len) - 2
                    m2 = LZ4HC_insertAndGetWiderMatch(s, src, dictQ, dictCtxQ,
                        start2, ip, matchlimit, m1.len,
                        maxNbAttempts, patternAnalysis, false, dict, false)   /* L1214-1216 */
                    start2 += Int64(m2.back)                       /* L1217 */
                } else {
                    m2 = nomatch                                   /* L1219: 不再前搜 */
                }

                if (m2.len <= m1.len) {                            /* L1222: 无更优 → 立即编码 ML1 */
                    optr = op
                    let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(src, ip,
                        dst, op, anchor, m1.len, m1.off, limit, oend)
                    if (issue != 0) {
                        op = nop
                        if (limit == LZ4_OUTPUT_FILL) {
                            overflow = true
                            break
                        }
                        return (0, 0)                              /* L1405-1406: 压缩失败 */
                    }
                    ip = nip
                    op = nop
                    anchor = nanchor
                    break                                          /* continue Main */
                }

                if (start0 < ip) {                                 /* L1231: 首个 match 曾被跳过 */
                    if (start2 < ip + Int64(m0.len)) {             /* L1232: ML0 与 ML2 间挤压 ML1 */
                        ip = start0
                        m1 = m0
                    }
                }

                /* 此处 start0 == ip(L1236) */
                if (start2 - ip < 3) {                             /* L1237: 首 match 过小 → 移除 */
                    ip = start2
                    m1 = m2
                    inSearch2 = true                               /* goto _Search2 */
                    continue
                }

                var goSearch2 = false
                var goMain = false
                while (!overflow && !goSearch2 && !goMain) {       /* _Search3(L1243 标签) */
                    if (start2 - ip < Int64(OPTIMAL_ML)) {         /* L1244 */
                        var new_ml: Int32 = m1.len
                        if (new_ml > OPTIMAL_ML) {
                            new_ml = OPTIMAL_ML
                        }
                        if (ip + Int64(new_ml) > start2 + Int64(m2.len) - LZ4_MINMATCH) {   /* L1248 */
                            new_ml = Int32(start2 - ip) + m2.len - Int32(LZ4_MINMATCH)
                        }
                        let correction: Int32 = new_ml - Int32(start2 - ip)
                        if (correction > 0) {                      /* L1251 */
                            start2 += Int64(correction)
                            m2.len -= correction
                        }
                    }

                    if (start2 + Int64(m2.len) <= mflimit) {       /* L1257 */
                        start3 = start2 + Int64(m2.len) - 3
                        m3 = LZ4HC_insertAndGetWiderMatch(s, src, dictQ, dictCtxQ,
                            start3, start2, matchlimit, m2.len,
                            maxNbAttempts, patternAnalysis, false, dict, false)   /* L1259-1261 */
                        start3 += Int64(m3.back)                   /* L1262 */
                    } else {
                        m3 = nomatch                               /* L1264 */
                    }

                    if (m3.len <= m2.len) {                        /* L1267: 无更优 → 编码 ML1+ML2 */
                        if (start2 < ip + Int64(m1.len)) {         /* L1269 */
                            m1.len = Int32(start2 - ip)
                        }
                        optr = op
                        let (issue1, nip1, nop1, nanchor1) = LZ4HC_encodeSequence(src, ip,
                            dst, op, anchor, m1.len, m1.off, limit, oend)
                        if (issue1 != 0) {
                            op = nop1
                            if (limit == LZ4_OUTPUT_FILL) {
                                overflow = true
                                break
                            }
                            return (0, 0)
                        }
                        ip = nip1
                        op = nop1
                        anchor = nanchor1
                        ip = start2                                /* L1276 */
                        optr = op
                        let (issue2, nip2, nop2, nanchor2) = LZ4HC_encodeSequence(src, ip,
                            dst, op, anchor, m2.len, m2.off, limit, oend)
                        if (issue2 != 0) {
                            op = nop2
                            ip = nip2
                            anchor = nanchor2
                            m1 = m2                                /* L1281: _dest_overflow 依赖 */
                            if (limit == LZ4_OUTPUT_FILL) {
                                overflow = true
                                break
                            }
                            return (0, 0)
                        }
                        ip = nip2
                        op = nop2
                        anchor = nanchor2
                        goMain = true
                        break                                       /* continue Main */
                    }

                    if (start3 < ip + Int64(m1.len) + 3) {          /* L1287: match2 空间不足 → 移除 */
                        if (start3 >= ip + Int64(m1.len)) {         /* L1288: 可先写 Seq1 → Seq2 移除,Seq3 升为 Seq1 */
                            if (start2 < ip + Int64(m1.len)) {      /* L1289 */
                                let correction: Int32 = Int32(ip + Int64(m1.len) - start2)
                                start2 += Int64(correction)
                                m2.len -= correction
                                if (m2.len < Int32(LZ4_MINMATCH)) { /* L1293 */
                                    start2 = start3
                                    m2 = m3
                                }
                            }
                            optr = op
                            let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(src, ip,
                                dst, op, anchor, m1.len, m1.off, limit, oend)
                            if (issue != 0) {
                                op = nop
                                if (limit == LZ4_OUTPUT_FILL) {
                                    overflow = true
                                    break
                                }
                                return (0, 0)
                            }
                            ip = nip
                            op = nop
                            anchor = nanchor
                            ip = start3                             /* L1304 */
                            m1 = m3
                            start0 = start2                         /* L1307 */
                            m0 = m2
                            goSearch2 = true                        /* goto _Search2 */
                            break
                        }
                        start2 = start3                             /* L1312 */
                        m2 = m3
                        continue                                    /* goto _Search3 */
                    }

                    /* 三个递增 match:写出 ML1(L1317-1336) */
                    if (start2 < ip + Int64(m1.len)) {              /* L1322 */
                        if (start2 - ip < Int64(OPTIMAL_ML)) {
                            if (m1.len > OPTIMAL_ML) {              /* L1325 */
                                m1.len = OPTIMAL_ML
                            }
                            if (ip + Int64(m1.len) > start2 + Int64(m2.len) - LZ4_MINMATCH) {   /* L1326 */
                                m1.len = Int32(start2 - ip) + m2.len - Int32(LZ4_MINMATCH)
                            }
                            let correction: Int32 = m1.len - Int32(start2 - ip)
                            if (correction > 0) {                   /* L1329 */
                                start2 += Int64(correction)
                                m2.len -= correction
                            }
                        } else {
                            m1.len = Int32(start2 - ip)             /* L1334 */
                        }
                    }
                    optr = op
                    let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(src, ip,
                        dst, op, anchor, m1.len, m1.off, limit, oend)
                    if (issue != 0) {
                        op = nop
                        if (limit == LZ4_OUTPUT_FILL) {
                            overflow = true
                            break
                        }
                        return (0, 0)
                    }
                    ip = nip
                    op = nop
                    anchor = nanchor
                    ip = start2                                     /* L1344: ML2 升为 ML1 */
                    m1 = m2
                    start2 = start3                                 /* L1347: ML3 升为 ML2 */
                    m2 = m3
                    continue                                        /* goto _Search3:再找新 ML3 */
                }
                if (goSearch2) {
                    inSearch2 = true
                    continue
                }
                break                                               /* goMain/overflow → Main 轮转 */
            }
        }
    }

    if (overflow) {
        /* _dest_overflow(L1385-1403,仅 fillOutput):ip/anchor/optr/m1 已就位 */
        let ll: Int64 = ip - anchor                                 /* L1388 */
        let llAddbytes: Int64 = (ll + 240) / 255                    /* L1389 */
        let llTotalCost: Int64 = 1 + llAddbytes + ll                /* L1390 */
        let maxLitPos: Int64 = oend - 3                             /* L1391: 2 offset + 1 token */
        op = optr                                                   /* L1393: 恢复输出指针 */
        if (op + llTotalCost <= maxLitPos) {
            let bytesLeftForMl: Int64 = maxLitPos - (op + llTotalCost)   /* L1396 */
            let maxMlSize: Int64 = LZ4_MINMATCH + (LZ4_ML_MASK - 1) + bytesLeftForMl * 255   /* L1397 */
            if (Int64(m1.len) > maxMlSize) {                        /* L1399 */
                m1.len = Int32(maxMlSize)
            }
            if ((oend + LZ4_LASTLITERALS) - (op + llTotalCost + 2) - 1 + Int64(m1.len) >= LZ4_MFLIMIT) {   /* L1400 */
                let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(src, ip,
                    dst, op, anchor, m1.len, m1.off, LZ4_OUTPUT_NOT_LIMITED, oend)   /* L1401: notLimited 不可能 issue */
                if (issue == 0) {
                    ip = nip
                    op = nop
                    anchor = nanchor
                }
            }
        }
        /* goto _last_literals */
    }

    /* _last_literals(L1353-1379) */
    var lastRunSize: Int64 = iend - anchor                          /* L1355 */
    var llAdd: Int64 = (lastRunSize + 255 - LZ4_RUN_MASK) / 255     /* L1356 */
    let totalSize: Int64 = 1 + llAdd + lastRunSize                  /* L1357 */
    if (limit == LZ4_OUTPUT_FILL) {
        oend += LZ4_LASTLITERALS                                   /* L1358: 恢复真实 oend */
    }
    if (limit != LZ4_OUTPUT_NOT_LIMITED && (op + totalSize > oend)) {   /* L1359 */
        if (limit == LZ4_OUTPUT_LIMITED) {
            return (0, 0)                                          /* L1360 */
        }
        lastRunSize = (oend - op) - 1                               /* L1362: 适配填满 dst */
        llAdd = (lastRunSize + 256 - LZ4_RUN_MASK) / 256            /* L1363 */
        lastRunSize -= llAdd
    }
    ip = anchor + lastRunSize                                       /* L1367: fillOutput 时可 < iend */

    if (lastRunSize >= LZ4_RUN_MASK) {                              /* L1369-1376 */
        var accumulator: Int64 = lastRunSize - LZ4_RUN_MASK
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
        LZ4_write8(dst, op, UInt8(lastRunSize << LZ4_ML_BITS))
        op += 1
    }
    LZ4_memcpyPtr(dst, op, src, anchor, lastRunSize)                /* L1377 */
    op += lastRunSize

    return (op, ip)                                                 /* L1382-1383 */
}

/*-************************************
*  Strategy stubs (lz4hc.c L1410-1416 前向声明对应)
**************************************/
/* LZ4MID_compress(L436-660 区域,1-2 级):T3 实现并替换函数体;本任务
   占位返回失败。签名 FINAL:ctx + 块基址指针对 + 源/目的 + limit/dict 指令,
   返回 (result, srcSizeOut)(srcSizePtr 语义)。 */
internal func LZ4MID_compress(ctx: LZ4_streamHC_t,
        src: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        limit: Int32, dict: Int32): (Int64, Int64) {
    /* T3 占位:未实现策略一律失败 */
    return (0, 0)
}

/* LZ4HC_compress_optimal(L1410-1416,10-12 级):T4 实现并替换函数体。
   签名 FINAL:与上游一致(source/dst/srcSizePtr/dstCapacity/nbSearches/
   sufficient_len/limit/fullUpdate=dict/HCfavor_e),指针上下文同上。 */
internal func LZ4HC_compress_optimal(ctx: LZ4_streamHC_t,
        source: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        nbSearches: Int32, sufficientLen: Int64,
        limit: Int32, fullUpdate: Bool,
        dict: Int32, favorDecSpeed: Bool): (Int64, Int64) {
    /* T4 占位:未实现策略一律失败 */
    return (0, 0)
}

/*-************************************
*  Generic dispatch (lz4hc.c L1419-1532)
**************************************/
/* LZ4HC_compress_generic_internal(L1419-1464):输入清洗((U32)srcSize >
   LZ4_MAX_INPUT_SIZE → 0、dstCapacity<1 → 0、srcSize==0 → *dst=0,1)、
   ctx->end += *srcSizePtr(全量,先于核心;仓颉 prefixEndIdx += srcSize)、
   策略分派、result<=0 → dirty=true(清洗早退不置脏,逐字)。 */
internal func LZ4HC_compress_generic_internal(s: LZ4_streamHC_t,
        src: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        cLevel: Int32, limit: Int32, dict: Int32): (Int64, Int64) {
    if (UInt32(srcSize & 0xFFFFFFFFi64) > UInt32(LZ4_MAX_INPUT_SIZE)) {   /* L1434: (U32) 比较语义 */
        return (0, 0)
    }
    if (dstCapacity < 1) {                                          /* L1435 */
        return (0, 0)
    }
    if (srcSize == 0) {                                             /* L1437 */
        LZ4_write8(dst, 0, 0u8)
        return (1, 0)
    }
    s.prefixEndIdx += srcSize                                       /* L1440: ctx->end += *srcSizePtr */
    let cParam = lz4hcGetCLevelParams(cLevel)                       /* L1441 */
    let favor: Bool = s.favorDecSpeed                               /* L1442 */
    var result: (Int64, Int64) = (0, 0)
    if (cParam.strat == LZ4HC_STRAT_MID) {
        /* lz4mid 策略(L1445-1448):T3 替换 LZ4MID_compress 函数体 */
        result = LZ4MID_compress(s, src, dictQ, dictCtxQ, dst, srcSize, dstCapacity, limit, dict)
    } else if (cParam.strat == LZ4HC_STRAT_HC) {
        result = LZ4HC_compress_hashChain(s, src, dictQ, dictCtxQ, dst, srcSize, dstCapacity,   /* L1450-1452 */
            cParam.nbSearches, limit, dict)
    } else {
        /* lz4opt 策略(L1455-1459):T4 替换 LZ4HC_compress_optimal 函数体 */
        result = LZ4HC_compress_optimal(s, src, dictQ, dictCtxQ, dst, srcSize, dstCapacity,
            cParam.nbSearches, Int64(cParam.targetLength), limit,
            cLevel >= LZ4HC_CLEVEL_MAX, dict, favor)
    }
    if (result[0] <= 0) {                                           /* L1461 */
        s.dirty = true
    }
    return result
}

/* LZ4HC_compress_generic(L1516-1532):dictCtx==None → noDictCtx 直通
   (L1527-1528);dictCtx!=None → 本任务占位直通 genericInternal
   (usingDictCtxHc),T5 落三路分派(64KB 脱挂/状态拷贝/咨询)。 */
internal func lz4hcCompressGeneric(s: LZ4_streamHC_t,
        src: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        cLevel: Int32, limit: Int32): (Int64, Int64) {
    let dictDir: Int32 = if (s.dictCtx.isNone()) {                  /* L1527 */
        LZ4HC_DICT_NODICTCTX
    } else {
        LZ4HC_DICT_USINGDICTCTXHC                                   /* T5:三路分派替换此支 */
    }
    return LZ4HC_compress_generic_internal(s, src, dictQ, dictCtxQ, dst,
        srcSize, dstCapacity, cLevel, limit, dictDir)
}

/* lz4hcCompressRun:一次性/流式共用的单一 unsafe 域(指针三律:acquire →
   分派 → release,域内不分配;M3b lz4ContinueRun 先例)。prefixStart ==
   本块基址(initInternal 锚定),故 srcQ 即 prefixStart 指针;extDict 段
   (dictBuf)与 dictCtx 前缀缓冲存在才 acquire,空缺传占位指针(核内按
   指令取用,不解引用)。返回 (result, srcSizeOut)。 */
internal func lz4hcCompressRun(s: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64,
        dst: Array<UInt8>, dstCapacity: Int64,
        cLevel: Int32, limit: Int32): (Int32, Int64) {
    unsafe {
        let sh = acquireArrayRawData<UInt8>(srcBuf)
        let dh = acquireArrayRawData<UInt8>(dst)
        let srcQ = sh.pointer + srcIdx
        var r: (Int64, Int64) = (0, 0)
        match (s.dictBuf) {
            case Some(db) =>
                let bh = acquireArrayRawData<UInt8>(db)
                let dictQ = bh.pointer + s.dictStartIdx
                match (s.dictCtx) {
                    case Some(dctx) =>
                        match (dctx.prefixBuf) {
                            case Some(pbuf) =>
                                let ph = acquireArrayRawData<UInt8>(pbuf)
                                r = lz4hcCompressGeneric(s, srcQ, dictQ, ph.pointer + dctx.prefixStartIdx,
                                    dh.pointer, srcSize, dstCapacity, cLevel, limit)
                                releaseArrayRawData<UInt8>(ph)
                            case None =>
                                r = lz4hcCompressGeneric(s, srcQ, dictQ, dictQ,
                                    dh.pointer, srcSize, dstCapacity, cLevel, limit)
                        }
                    case None =>
                        r = lz4hcCompressGeneric(s, srcQ, dictQ, dictQ,
                            dh.pointer, srcSize, dstCapacity, cLevel, limit)
                }
                releaseArrayRawData<UInt8>(bh)
            case None =>
                r = lz4hcCompressGeneric(s, srcQ, srcQ, srcQ,
                    dh.pointer, srcSize, dstCapacity, cLevel, limit)
        }
        releaseArrayRawData<UInt8>(dh)
        releaseArrayRawData<UInt8>(sh)
        return (Int32(r[0]), r[1])
    }
}

/*-************************************
*  One-shot public APIs (lz4hc.c L1549-1594)
**************************************/
/* LZ4_compress_HC_extStateHC_fastReset(L1549-1559):快复位 + 新块锚定 +
   compressBound 择 notLimited/limitedOutput(C 的对齐检查对类状态不可达)。 */
public func LZ4_compress_HC_extStateHC_fastReset(state: LZ4_streamHC_t, src: Array<UInt8>,
        srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, compressionLevel: Int32): Int32 {
    LZ4_resetStreamHC_fast(state, compressionLevel)                 /* L1553 */
    LZ4HC_initInternal(state, src, 0)                               /* L1554 */
    let limit: Int32 = if (dstCapacity < LZ4_compressBound(srcSize)) {
        LZ4_OUTPUT_LIMITED                                          /* L1555-1556 */
    } else {
        LZ4_OUTPUT_NOT_LIMITED                                      /* L1557-1558 */
    }
    let (r, _) = lz4hcCompressRun(state, src, 0, Int64(srcSize), dst,
        Int64(dstCapacity), compressionLevel, limit)
    return r
}

/* LZ4_compress_HC_extStateHC(L1561-1566):全量 init 后走 fastReset 共体。 */
public func LZ4_compress_HC_extStateHC(state: LZ4_streamHC_t, src: Array<UInt8>,
        srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, compressionLevel: Int32): Int32 {
    LZ4_initStreamHC(state)                                         /* L1563 */
    return LZ4_compress_HC_extStateHC_fastReset(state, src, srcSize, dst, dstCapacity, compressionLevel)
}

/* LZ4_compress_HC(L1568-1584):临时状态 + extStateHC(C 栈上/堆态等价)。 */
public func LZ4_compress_HC(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>,
        dstCapacity: Int32, compressionLevel: Int32): Int32 {
    let state = LZ4_streamHC_t()                                    /* L1575 */
    return LZ4_compress_HC_extStateHC(state, src, srcSize, dst, dstCapacity, compressionLevel)
}

/* LZ4_compress_HC_destSize(L1587-1594):fillOutput 收缩压缩。返回
   (cSize, consumed):consumed 由核心写出(= C *srcSizePtr 出值);失败
   (r <= 0)→ (0, srcSize)(委托语义同 M2 destSize;target<1 清洗早退不触
   srcSizePtr,保持调用方初值)。本函数无委托分支 —— target ≥ compressBound
   时 fillOutput 自然全量消费。 */
public func LZ4_compress_HC_destSize(state: LZ4_streamHC_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, targetDstSize: Int32, cLevel: Int32): (Int32, Int32) {
    LZ4_initStreamHC(state)                                         /* L1589 */
    LZ4HC_initInternal(state, src, 0)                               /* L1591 */
    LZ4_setCompressionLevel(state, cLevel)                          /* L1592 */
    let (r, consumed) = lz4hcCompressRun(state, src, 0, Int64(srcSize), dst,
        Int64(targetDstSize), cLevel, LZ4_OUTPUT_FILL)              /* L1593 */
    if (r <= 0) {
        return (0, srcSize)
    }
    return (r, Int32(consumed))
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
