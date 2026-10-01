// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream lib/lz4hc.c (HC high-compression mode).
// M4 Tasks 1-5: state family + level table + hash/count/pattern primitives +
// encodeSequence, hash-chain core (levels 3-9), lz4mid core (levels 1-2),
// optimal parser (levels 10-12) + favorDecompressionSpeed, generic dispatch,
// streaming family with loadDictHC, attach_HC_dictionary, continue +
// continue_destSize, saveDictHC + 3-way dictCtx dispatch (lz4hcCompressRun
// restructured for dictCtxBase independence).

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
internal const LZ4HC_HASHSIZE: Int64 = 4             /* lz4hc.c L120: 最小可用字典段 */
internal const LZ4MID_HASHLOG: Int64 = 14            /* lz4hc.c L142: HASH_LOG-1 */
internal const LZ4MID_HASHTABLESIZE: Int64 = 1 << 14 /* 16384, lz4hc.c L143 */
internal const LZ4MID_HASHSIZE: Int64 = 8            /* lz4hc.c L141 */
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
        src: CPointer<UInt8>, ipStart: Int64,
        dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, maxOutputSize: Int64,
        maxNbAttempts: Int32, limit: Int32, dict: Int32): (Int64, Int64) {
    let inputSize: Int64 = srcSize
    let patternAnalysis: Bool = maxNbAttempts > 128                 /* L1171: levels 9+ */

    let iend: Int64 = ipStart + inputSize
    let mflimit: Int64 = iend - LZ4_MFLIMIT
    let matchlimit: Int64 = iend - LZ4_LASTLITERALS

    var ip: Int64 = ipStart
    var anchor: Int64 = ipStart
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

    return (op, ip - ipStart)                                       /* L1382-1383 */
}

/*-************************************
*  Mid compression, levels 1-2 (lz4hc.c L389-803)
**************************************/
/* LZ4HC_searchExtDict(L389-430):自家链外借 dictCtx 哈希链搜字典 match。
   ip/iLowLimit/iHighLimit 为工作 prefix 缓冲(prefixPtr)侧索引;dictCtx 的
   prefix 缓冲由外层 unsafe 域以 dictCtxBase 供给(matchPtr 索引 =
   lDictMatchIndex - dictCtx.dictLimit)。lDictEndIndex = dictCtx.prefixLen +
   dictCtx.dictLimit;matchIndex 平移(+ gDictEndIndex - (U32)lDictEndIndex)
   与链回退均 U32 回绕。本任务无入口可达(dictCtx 仅 T5 流式 API 挂接),
   随 LZ4MID_compress 一并移植。 */
internal func LZ4HC_searchExtDict(prefixPtr: CPointer<UInt8>, ip: Int64, ipIndex: UInt32,
        iLowLimit: Int64, iHighLimit: Int64, dictCtx: LZ4_streamHC_t, dictCtxBase: CPointer<UInt8>,
        gDictEndIndex: UInt32, currentBestMLIn: Int32, nbAttemptsIn: Int32): LZ4HC_match {
    let lDictEndIndex: UInt64 = UInt64(dictCtx.prefixEndIdx - dictCtx.prefixStartIdx) + UInt64(dictCtx.dictLimit)   /* L393 */
    var lDictMatchIndex: UInt32 = dictCtx.hashTable[Int64(LZ4HC_hashPtr(prefixPtr, ip))]   /* L394 */
    var matchIndex: UInt32 = lDictMatchIndex + gDictEndIndex - UInt32(lDictEndIndex)   /* L395: U32 回绕 */
    var offset: Int32 = 0
    var sBack: Int32 = 0
    var currentBestML: Int32 = currentBestMLIn
    var nbAttempts: Int32 = nbAttemptsIn
    while ((ipIndex - matchIndex <= LZ4_DISTANCE_MAX) && (nbAttempts > 0)) {   /* L398: C 后缀减予定序 */
        nbAttempts -= 1
        let matchPtrIdx: Int64 = Int64(lDictMatchIndex) - Int64(dictCtx.dictLimit)   /* L399: prefixStart - dictLimit + idx */
        if (LZ4_readLE32(dictCtxBase, matchPtrIdx) == LZ4_readLE32(prefixPtr, ip)) {   /* L401 */
            var back: Int32 = 0
            var vLimit: Int64 = ip + Int64(lDictEndIndex - UInt64(lDictMatchIndex))   /* L404 */
            if (vLimit > iHighLimit) {
                vLimit = iHighLimit                                    /* L405 */
            }
            var mlt: Int32 = Int32(LZ4_count2(prefixPtr, ip + LZ4_MINMATCH,
                dictCtxBase, matchPtrIdx + LZ4_MINMATCH, vLimit)) + Int32(LZ4_MINMATCH)   /* L406: 跨段计数 */
            back = if (ip > iLowLimit) {                               /* L407: bMin = dictCtx->prefixStart */
                LZ4HC_countBack(prefixPtr, ip, dictCtxBase, matchPtrIdx, iLowLimit, 0)
            } else {
                0
            }
            mlt -= back
            if (mlt > currentBestML) {
                currentBestML = mlt
                offset = Int32(ipIndex - matchIndex)                   /* L410: U32 减 */
                sBack = back
            }
        }
        let nextOffset: UInt32 = UInt32(dictCtx.chainTable[Int64(lDictMatchIndex & 0xFFFFu32)])   /* L415: DELTANEXTU16 */
        lDictMatchIndex -= nextOffset
        matchIndex -= nextOffset
    }
    return LZ4HC_match(offset, currentBestML, sBack)                   /* L419-424 */
}

/* LZ4MID_searchHCDict(L436-444):dictCtx 为 hash-chain 流时的字典搜索:
   委托 searchExtDict,iLowLimit = ip(不回看)、currentBestML = MINMATCH-1、
   nbAttempts = 2。T5 hcattach 不兼容行(dict lv9 + work lv2)消费。 */
internal func LZ4MID_searchHCDict(prefixPtr: CPointer<UInt8>, ip: Int64, ipIndex: UInt32,
        iHighLimit: Int64, dictCtx: LZ4_streamHC_t, dictCtxBase: CPointer<UInt8>,
        gDictEndIndex: UInt32): LZ4HC_match {
    return LZ4HC_searchExtDict(prefixPtr, ip, ipIndex, ip, iHighLimit,
        dictCtx, dictCtxBase, gDictEndIndex, Int32(LZ4_MINMATCH) - 1, 2)   /* L441-443 */
}

/* LZ4MID_searchExtDict(L446-496):dictCtx 为 mid 流时的字典搜索:hash8 先查
   后 hash4,safeLen = MIN(lDictEndIndex - lMatchIndex, iHighLimit - ip) 钳制
   (跨段读取下界),mlt >= MINMATCH 即返(back 恒 0)。hash8 槽位于
   hashTable[LZ4MID_HASHTABLESIZE, 32768)。 */
internal func LZ4MID_searchExtDict(prefixPtr: CPointer<UInt8>, ip: Int64, ipIndex: UInt32,
        iHighLimit: Int64, dictCtx: LZ4_streamHC_t, dictCtxBase: CPointer<UInt8>,
        gDictEndIndex: UInt32): LZ4HC_match {
    let lDictEndIndex: UInt64 = UInt64(dictCtx.prefixEndIdx - dictCtx.prefixStartIdx) + UInt64(dictCtx.dictLimit)   /* L447 */
    /* search long match first (L451-466) */
    let l8DictMatchIndex: UInt32 = dictCtx.hashTable[LZ4MID_HASHTABLESIZE + Int64(LZ4MID_hash8Ptr(prefixPtr, ip))]   /* L452 */
    let m8Index: UInt32 = l8DictMatchIndex + gDictEndIndex - UInt32(lDictEndIndex)   /* L453: U32 回绕 */
    if (ipIndex - m8Index <= LZ4_DISTANCE_MAX) {                      /* L455 */
        let matchPtrIdx: Int64 = Int64(l8DictMatchIndex) - Int64(dictCtx.dictLimit)   /* L456 */
        let a: UInt64 = lDictEndIndex - UInt64(l8DictMatchIndex)
        let b: UInt64 = UInt64(iHighLimit - ip)
        let safeLen: UInt64 = if (a < b) { a } else { b }             /* L457: MIN */
        let mlt: Int32 = Int32(LZ4_count2(prefixPtr, ip, dictCtxBase, matchPtrIdx, ip + Int64(safeLen)))   /* L458 */
        if (mlt >= Int32(LZ4_MINMATCH)) {
            return LZ4HC_match(Int32(ipIndex - m8Index), mlt, 0)      /* L460-464 */
        }
    }
    /* search for short match second (L469-485) */
    let l4DictMatchIndex: UInt32 = dictCtx.hashTable[Int64(LZ4MID_hash4Ptr(prefixPtr, ip))]   /* L470 */
    let m4Index: UInt32 = l4DictMatchIndex + gDictEndIndex - UInt32(lDictEndIndex)   /* L471 */
    if (ipIndex - m4Index <= LZ4_DISTANCE_MAX) {
        let matchPtrIdx: Int64 = Int64(l4DictMatchIndex) - Int64(dictCtx.dictLimit)
        let a: UInt64 = lDictEndIndex - UInt64(l4DictMatchIndex)
        let b: UInt64 = UInt64(iHighLimit - ip)
        let safeLen: UInt64 = if (a < b) { a } else { b }
        let mlt: Int32 = Int32(LZ4_count2(prefixPtr, ip, dictCtxBase, matchPtrIdx, ip + Int64(safeLen)))
        if (mlt >= Int32(LZ4_MINMATCH)) {
            return LZ4HC_match(Int32(ipIndex - m4Index), mlt, 0)
        }
    }
    return LZ4HC_match(0, 0, 0)                                       /* L488-491: nothing found */
}

/* LZ4MID_addPosition + ADDPOS 宏(L502-508):hash4 槽位于 hashTable
   [0, 16384),hash8 槽位于 [16384, 32768)。 */
internal func LZ4MID_addPos4(s: LZ4_streamHC_t, p: CPointer<UInt8>, i: Int64, index: UInt32): Unit {
    s.hashTable[Int64(LZ4MID_hash4Ptr(p, i))] = index
}

internal func LZ4MID_addPos8(s: LZ4_streamHC_t, p: CPointer<UInt8>, i: Int64, index: UInt32): Unit {
    s.hashTable[LZ4MID_HASHTABLESIZE + Int64(LZ4MID_hash8Ptr(p, i))] = index
}

/* LZ4MID_fillHTable(L513-538):字典入表(仅 mid 策略可利用)。第一循环
   3 步进双表(idx 位 ADDPOS4 + idx+1 位 ADDPOS8);第二循环尾段 32KB 1 步进
   ADDPOS8,起点 = size > 32KB+8 ? target-32KB : nextToUpdate;出函数
   nextToUpdate = target;size <= 8 直返(表不动)。T5 loadDictHC 消费。
   dictPtr = s 的 prefixStart(上游 assert(dict == cctx->prefixStart))。 */
internal func LZ4MID_fillHTable(s: LZ4_streamHC_t, dictPtr: CPointer<UInt8>, size: Int64): Unit {
    let prefixIdx: UInt32 = s.dictLimit                               /* L518 */
    let target: UInt32 = prefixIdx + UInt32(size) - UInt32(LZ4MID_HASHSIZE)   /* L519: U32 回绕 */
    var idx: UInt32 = s.nextToUpdate                                  /* L520 */
    if (size <= LZ4MID_HASHSIZE) {                                    /* L523-524 */
        return
    }
    while (idx < target) {                                            /* L526 */
        LZ4MID_addPos4(s, dictPtr, Int64(idx) - Int64(prefixIdx), idx)          /* L527: ADDPOS4 */
        LZ4MID_addPos8(s, dictPtr, Int64(idx) + 1 - Int64(prefixIdx), idx + 1u32)   /* L528: ADDPOS8 */
        idx += 3u32
    }
    idx = if (size > 32768 + LZ4MID_HASHSIZE) {                       /* L531: 32 KB + LZ4MID_HASHSIZE */
        target - 32768u32
    } else {
        s.nextToUpdate
    }
    while (idx < target) {                                            /* L532 */
        LZ4MID_addPos8(s, dictPtr, Int64(idx) - Int64(prefixIdx), idx)          /* L533 */
        idx += 1u32
    }
    s.nextToUpdate = target                                           /* L536 */
}

/* select_searchDict_function(L540-546):C 返回函数指针(NULL = 不查);
   仓颉以选择码替代。T5 流式 dictCtx 路径消费。 */
internal const LZ4MID_SEARCH_NONE: Int32 = 0
internal const LZ4MID_SEARCH_EXTDICT: Int32 = 1
internal const LZ4MID_SEARCH_HCDICT: Int32 = 2

internal func lz4midSelectSearchDict(dictCtx: Option<LZ4_streamHC_t>): Int32 {
    match (dictCtx) {
        case None =>
            return LZ4MID_SEARCH_NONE                                 /* L542 */
        case Some(dctx) =>
            if (lz4hcGetCLevelParams(dctx.compressionLevel).strat == LZ4HC_STRAT_MID) {
                return LZ4MID_SEARCH_EXTDICT                          /* L544: mid 流 */
            }
            return LZ4MID_SEARCH_HCDICT                               /* L545: hash-chain 流 */
    }
}

/* LZ4MID_compress(L554-803):mid 策略核心(1-2 级)。hash8/hash4 双查、短
   匹配 ip+1 二次确认(gated by ip < mflimit)、catch-back(无符号
   (U32)(ip-prefixPtr) > matchDistance 判定)、表填充位点(匹配首 3 位 +
   尾 5 位)、skip 步进 1+((ip-anchor)>>9)、_lz4mid_last_literals、fillOutput
   的 oend hack 与 _lz4mid_dest_overflow。C 的 goto _lz4mid_encode_sequence
   以 encode 标志重组、_lz4mid_dest_overflow 以 overflow 标志;注意
   encodeSequence 的 buffer-issue 契约在 MID 特殊:op 恢复 saved_op(丢弃其
   推进值,C L704-706 显式恢复 —— 与 hashChain 核心的 optr 机制不同源)。
   dictCtx 路径(dict == usingDictCtxHc)T5 流式 API 才可达,随函数体一并
   移植。前置:srcSize ∈ [1, LZ4_MAX_INPUT_SIZE]、dstCapacity >= 1(清洗在
   generic_internal);返回 (result, srcSizeOut)(srcSizePtr 出值语义,失败
   (0, 0))。单一 unsafe 域内调用,纯指针运算、无分配。 */
internal func LZ4MID_compress(ctx: LZ4_streamHC_t,
        src: CPointer<UInt8>, ipStart: Int64,
        dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        limit: Int32, dict: Int32): (Int64, Int64) {
    /* hash4Table = ctx.hashTable[0, 16384),hash8Table = [16384, 32768) */
    var ip: Int64 = ipStart
    var anchor: Int64 = ipStart
    let iend: Int64 = ipStart + srcSize
    let mflimit: Int64 = iend - LZ4_MFLIMIT
    let matchlimit: Int64 = iend - LZ4_LASTLITERALS
    let ilimit: Int64 = iend - LZ4MID_HASHSIZE
    var op: Int64 = 0
    var oend: Int64 = dstCapacity

    let prefixPtr: CPointer<UInt8> = src                              /* L572: prefixStart = 状态前缀基(dictLimit 映射) */
    let prefixIdx: UInt32 = ctx.dictLimit                             /* L564 */
    let ilimitIdx: UInt32 = UInt32(ilimit & 0xFFFFFFFFi64) + prefixIdx   /* L565: (U32)(ilimit-prefixPtr)+prefixIdx */
    let dictIdx: UInt32 = ctx.lowLimit                                /* L566: dictStart 虚拟基 */
    let gDictEndIndex: UInt32 = ctx.lowLimit                          /* L567 */
    var matchLength: UInt32 = 0u32
    var matchDistance: UInt32 = 0u32
    var overflow = false                                              /* goto _lz4mid_dest_overflow */

    if (limit == LZ4_OUTPUT_FILL) {
        oend -= LZ4_LASTLITERALS                                      /* L592: fillOutput 尾量预留 hack */
    }

    if (srcSize >= LZ4_minLength) {                                   /* L594: 小输入全字面量 goto */
        while (!overflow && ip <= mflimit) {                          /* L597: main loop */
            let ipIndex: UInt32 = UInt32(ip) + prefixIdx              /* L598 */
            var encode = false                                        /* goto _lz4mid_encode_sequence */
            /* search long match (L600-623) */
            let h8: UInt32 = LZ4MID_hash8Ptr(prefixPtr, ip)           /* L601 */
            let pos8: UInt32 = ctx.hashTable[LZ4MID_HASHTABLESIZE + Int64(h8)]   /* L602 */
            ctx.hashTable[LZ4MID_HASHTABLESIZE + Int64(h8)] = ipIndex /* L604: addPosition */
            if (ipIndex - pos8 <= LZ4_DISTANCE_MAX) {                 /* L605: U32 回绕 */
                if (pos8 >= prefixIdx) {                              /* L607: prefix 段内 */
                    let matchPtrIdx: Int64 = Int64(pos8 - prefixIdx)
                    matchLength = UInt32(LZ4_count(prefixPtr, ip, matchPtrIdx, matchlimit))   /* L610 */
                    if (matchLength >= UInt32(LZ4_MINMATCH)) {
                        matchDistance = ipIndex - pos8                /* L613 */
                        encode = true
                    }
                } else if (pos8 >= dictIdx) {                         /* L616: extDict 段 */
                    let matchPtrIdx: Int64 = Int64(pos8 - dictIdx)    /* dictStart + (pos8 - dictIdx) */
                    let a: UInt64 = UInt64(prefixIdx - pos8)
                    let b: UInt64 = UInt64(matchlimit - ip)
                    let safeLen: UInt64 = if (a < b) { a } else { b } /* L618: MIN */
                    matchLength = UInt32(LZ4_count2(prefixPtr, ip, dictQ, matchPtrIdx, ip + Int64(safeLen)))   /* L619 */
                    if (matchLength >= UInt32(LZ4_MINMATCH)) {
                        matchDistance = ipIndex - pos8
                        encode = true
                    }
                }
            }
            /* search short match (L625-677) */
            if (!encode) {
                let h4: UInt32 = LZ4MID_hash4Ptr(prefixPtr, ip)       /* L627 */
                let pos4: UInt32 = ctx.hashTable[Int64(h4)]           /* L628 */
                ctx.hashTable[Int64(h4)] = ipIndex                    /* L630 */
                if (ipIndex - pos4 <= LZ4_DISTANCE_MAX) {
                    if (pos4 >= prefixIdx) {                          /* L633: 仅 prefix 段内查 */
                        let matchPtrIdx: Int64 = Int64(pos4 - prefixIdx)
                        matchLength = UInt32(LZ4_count(prefixPtr, ip, matchPtrIdx, matchlimit))   /* L638 */
                        if (matchLength >= UInt32(LZ4_MINMATCH)) {
                            /* short match found, let's just check ip+1 for longer (L641-670) */
                            let h8m2: UInt32 = LZ4MID_hash8Ptr(prefixPtr, ip + 1)   /* L642 */
                            let pos8m2: UInt32 = ctx.hashTable[LZ4MID_HASHTABLESIZE + Int64(h8m2)]   /* L643 */
                            let m2Distance: UInt32 = ipIndex + 1u32 - pos8m2        /* L644 */
                            matchDistance = ipIndex - pos4            /* L645 */
                            if ((m2Distance <= LZ4_DISTANCE_MAX) &&
                                    (pos8m2 >= prefixIdx) &&          /* L647: 仅 prefix 段 */
                                    (ip < mflimit)) {                 /* L648: 二次确认门槛 */
                                let m2PtrIdx: Int64 = Int64(pos8m2 - prefixIdx)
                                let ml2: UInt32 = UInt32(LZ4_count(prefixPtr, ip + 1, m2PtrIdx, matchlimit))   /* L651 */
                                if (ml2 > matchLength) {
                                    ctx.hashTable[LZ4MID_HASHTABLESIZE + Int64(h8m2)] = ipIndex + 1u32   /* L655 */
                                    ip += 1
                                    matchLength = ml2
                                    matchDistance = m2Distance
                                }
                            }
                            encode = true
                        }
                    } else if (pos4 >= dictIdx) {                     /* L668: extDict match candidate */
                        let matchPtrIdx: Int64 = Int64(pos4 - dictIdx)
                        let a: UInt64 = UInt64(prefixIdx - pos4)
                        let b: UInt64 = UInt64(matchlimit - ip)
                        let safeLen: UInt64 = if (a < b) { a } else { b }
                        matchLength = UInt32(LZ4_count2(prefixPtr, ip, dictQ, matchPtrIdx, ip + Int64(safeLen)))   /* L671 */
                        if (matchLength >= UInt32(LZ4_MINMATCH)) {
                            matchDistance = ipIndex - pos4
                            encode = true
                        }
                    }
                }
            }
            /* no match found in prefix: search into external dictionary (L678-690) */
            if ((!encode) && (dict == LZ4HC_DICT_USINGDICTCTXHC) &&
                    (ipIndex - gDictEndIndex < LZ4_DISTANCE_MAX - 8u32)) {   /* L679: U32 */
                match (ctx.dictCtx) {
                    case Some(dctx) =>
                        let sel = lz4midSelectSearchDict(ctx.dictCtx)
                        let dMatch = if (sel == LZ4MID_SEARCH_EXTDICT) {
                            LZ4MID_searchExtDict(prefixPtr, ip, ipIndex, matchlimit,
                                dctx, dictCtxQ, gDictEndIndex)
                        } else {
                            LZ4MID_searchHCDict(prefixPtr, ip, ipIndex, matchlimit,
                                dctx, dictCtxQ, gDictEndIndex)
                        }
                        if (Int64(dMatch.len) >= LZ4_MINMATCH) {
                            /* assert(dMatch.back == 0) */
                            matchLength = UInt32(Int64(dMatch.len))
                            matchDistance = UInt32(Int64(dMatch.off))
                            encode = true
                        }
                    case None => ()
                }
            }
            if (!encode) {
                /* no match found: skip faster over incompressible data */
                ip += 1 + ((ip - anchor) >> 9)                        /* L689 */
                continue
            }

            /* _lz4mid_encode_sequence (L691-716) */
            /* catch back */
            while (((ip > anchor) && (UInt32(ip) > matchDistance)) && /* L692: (U32)(ip-prefixPtr) 无符号判定 */
                    (LZ4_read8(prefixPtr, ip - 1) == LZ4_read8(prefixPtr, ip - Int64(matchDistance) - 1))) {
                ip -= 1
                matchLength += 1u32
            }
            /* fill table with beginning of match */
            LZ4MID_addPos8(ctx, prefixPtr, ip + 1, ipIndex + 1u32)    /* L699 */
            LZ4MID_addPos8(ctx, prefixPtr, ip + 2, ipIndex + 2u32)    /* L700 */
            LZ4MID_addPos4(ctx, prefixPtr, ip + 1, ipIndex + 1u32)    /* L701 */
            /* encode */
            let savedOp: Int64 = op                                   /* L703 */
            let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(prefixPtr, ip,
                dst, op, anchor, Int32(matchLength), Int32(matchDistance), limit, oend)
            if (issue != 0) {
                op = savedOp                                          /* L705: 恢复(丢弃推进值) */
                if (limit != LZ4_OUTPUT_FILL) {
                    return (0, 0)                                     /* L802-803: compression failed */
                }
                overflow = true                                       /* goto _lz4mid_dest_overflow */
                break
            }
            ip = nip
            op = nop
            anchor = nanchor
            /* fill table with end of match */
            let endMatchIdx: UInt32 = UInt32(ip) + prefixIdx          /* L710 */
            let posM2: UInt32 = endMatchIdx - 2u32                    /* L711 */
            if (posM2 < ilimitIdx) {                                  /* L712: U32 */
                if (ip > 5) {                                         /* L713: ip - prefixPtr > 5 */
                    LZ4MID_addPos8(ctx, prefixPtr, ip - 5, endMatchIdx - 5u32)   /* L714 */
                }
                LZ4MID_addPos8(ctx, prefixPtr, ip - 3, endMatchIdx - 3u32)       /* L716 */
                LZ4MID_addPos8(ctx, prefixPtr, ip - 2, endMatchIdx - 2u32)       /* L717 */
                LZ4MID_addPos4(ctx, prefixPtr, ip - 2, endMatchIdx - 2u32)       /* L718 */
                LZ4MID_addPos4(ctx, prefixPtr, ip - 1, endMatchIdx - 1u32)       /* L719 */
            }
        }
    }

    if (overflow) {
        /* _lz4mid_dest_overflow(L786-801,仅 fillOutput):ip/anchor/op/
           matchLength/matchDistance 已就位(op 已恢复 savedOp) */
        let ll: Int64 = ip - anchor                                   /* L775 */
        let llAddbytes: Int64 = (ll + 240) / 255                      /* L776 */
        let llTotalCost: Int64 = 1 + llAddbytes + ll                  /* L777 */
        let maxLitPos: Int64 = oend - 3                               /* L778: 2 offset + 1 token */
        if (op + llTotalCost <= maxLitPos) {
            let bytesLeftForMl: Int64 = maxLitPos - (op + llTotalCost)   /* L781 */
            let maxMlSize: Int64 = LZ4_MINMATCH + (LZ4_ML_MASK - 1) + bytesLeftForMl * 255   /* L782 */
            if (Int64(matchLength) > maxMlSize) {
                matchLength = UInt32(maxMlSize)                       /* L784 */
            }
            if ((oend + LZ4_LASTLITERALS) - (op + llTotalCost + 2) - 1 + Int64(matchLength) >= LZ4_MFLIMIT) {   /* L785 */
                let (issue2, nip2, nop2, nanchor2) = LZ4HC_encodeSequence(prefixPtr, ip,
                    dst, op, anchor, Int32(matchLength), Int32(matchDistance), LZ4_OUTPUT_NOT_LIMITED, oend)   /* L786: notLimited 不可能 issue */
                if (issue2 == 0) {
                    ip = nip2
                    op = nop2
                    anchor = nanchor2
                }
            }
        }
        /* goto _lz4mid_last_literals */
    }

    /* _lz4mid_last_literals (L758-788) */
    var lastRunSize: Int64 = iend - anchor                            /* L759 */
    var llAdd: Int64 = (lastRunSize + 255 - LZ4_RUN_MASK) / 255       /* L760 */
    let totalSize: Int64 = 1 + llAdd + lastRunSize                    /* L761 */
    if (limit == LZ4_OUTPUT_FILL) {
        oend += LZ4_LASTLITERALS                                      /* L762: 恢复真实 oend */
    }
    if (limit != LZ4_OUTPUT_NOT_LIMITED && (op + totalSize > oend)) { /* L763 */
        if (limit == LZ4_OUTPUT_LIMITED) {
            return (0, 0)                                             /* L764: not enough space in dst */
        }
        lastRunSize = (oend - op) - 1                                 /* L766: 适配填满 dst */
        llAdd = (lastRunSize + 256 - LZ4_RUN_MASK) / 256              /* L767: 255/256 非对称(同 T2) */
        lastRunSize -= llAdd
    }
    ip = anchor + lastRunSize                                         /* L771: fillOutput 时可 < iend */
    if (lastRunSize >= LZ4_RUN_MASK) {                                /* L773-780 */
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
    LZ4_memcpyPtr(dst, op, prefixPtr, anchor, lastRunSize)            /* L782 */
    op += lastRunSize

    return (op, ip - ipStart)                                        /* L786-787: *srcSizePtr = ip-src; return op-dst */
}

/* isStateCompatible(L1483-1488):两状态同为 mid 或同为非 mid 才兼容
   (mid 与 hash-chain 的 hashTable 布局不同:hash4/hash8 对分 vs
   hash+chain)。T5 流式 dictCtx 挂接(attach 前置校验)消费。 */
internal func lz4hcIsStateCompatible(ctx1: LZ4_streamHC_t, ctx2: LZ4_streamHC_t): Bool {
    let isMid1: Bool = lz4hcGetCLevelParams(ctx1.compressionLevel).strat == LZ4HC_STRAT_MID
    let isMid2: Bool = lz4hcGetCLevelParams(ctx2.compressionLevel).strat == LZ4HC_STRAT_MID
    return !(isMid1 != isMid2)                                        /* L1487: !(isMid1 ^ isMid2) */
}

/*-************************************
*  Optimal parser, levels 10-12 (lz4hc.c L1816-2186)
**************************************/
/* LZ4HC_optimal_t(L1819-1824):opt[pos] = 位置 pos 的最优解析状态;
   mlen==1 表示字面量路径,price 按字节计。 */
internal struct LZ4HC_optimal {
    var price: Int32
    var off: Int32
    var mlen: Int32
    var litlen: Int32
    init(price: Int32, off: Int32, mlen: Int32, litlen: Int32) {
        this.price = price
        this.off = off
        this.mlen = mlen
        this.litlen = litlen
    }
}

/* LZ4HC_literalsPrice(L1827-1834):litlen + litlen>=RUN_MASK(15) →
   1 + (litlen-15)/255(截断除)。 */
internal func LZ4HC_literalsPrice(litlen: Int32): Int32 {
    var price: Int32 = litlen                                    /* L1829 */
    if (litlen >= Int32(LZ4_RUN_MASK)) {                         /* L1831 */
        price += 1 + ((litlen - Int32(LZ4_RUN_MASK)) / 255)
    }
    return price
}

/* LZ4HC_sequencePrice(L1837-1849):token(1)+ 16 位 offset(2)+
   literalsPrice + mlen>=ML_MASK+MINMATCH(19) → 1 + (mlen-19)/255。
   要求 mlen >= MINMATCH(调用点保证)。 */
internal func LZ4HC_sequencePrice(litlen: Int32, mlen: Int32): Int32 {
    var price: Int32 = 1 + 2                                     /* L1840 */
    price += LZ4HC_literalsPrice(litlen)                         /* L1844 */
    if (mlen >= Int32(LZ4_ML_MASK + LZ4_MINMATCH)) {             /* L1846 */
        price += 1 + ((mlen - Int32(LZ4_ML_MASK + LZ4_MINMATCH)) / 255)
    }
    return price
}

/* LZ4HC_FindLongerMatch(L1851-1869):wider 搜索(iLowLimit==ip 禁回看,
   故 md.back==0)+ favor 截断(len∈(18,36] → 18,解压速度优先捷径)。 */
internal func LZ4HC_findLongerMatch(ctx: LZ4_streamHC_t,
        prefixPtr: CPointer<UInt8>, dictBase: CPointer<UInt8>, dictCtxBase: CPointer<UInt8>,
        ip: Int64, iHighLimit: Int64, minLen: Int32, nbSearches: Int32,
        dict: Int32, favorDecSpeed: Bool): LZ4HC_match {
    var md = LZ4HC_insertAndGetWiderMatch(ctx, prefixPtr, dictBase, dictCtxBase,
        ip, ip, iHighLimit, minLen, nbSearches,
        true /* patternAnalysis */, true /* chainSwap */,
        dict, favorDecSpeed)                                     /* L1861-1862 */
    if (md.len <= minLen) {                                      /* L1863 */
        return LZ4HC_match(0, 0, 0)                              /* match0 */
    }
    if (favorDecSpeed) {                                         /* L1865 */
        if ((md.len > 18) && (md.len <= 36)) {                   /* L1866:(len>18)&(len<=36) */
            md.len = 18                                          /* favor dec.speed shortcut */
        }
    }
    return md
}

/* LZ4HC_compress_optimal(L1879-2186,10-12 级):最优解析核心。前置:
   1 ≤ srcSize ≤ LZ4_MAX_INPUT_SIZE、dstCapacity ≥ 1(清洗在
   generic_internal 完成);返回 (cSize, consumed),consumed 即 C 的
   *srcSizePtr 出值(L1896 先置 0,末尾写 ip;limitedOutput 失败保持 0)。
   opt 数组每次调用新建(C HEAPMODE LZ4HC_HEAPMODE==1 每调用 ALLOC 的等价
   结构:先分配、后运行;元素整体赋值,读槽位均已被同轮写入 —— C 未初始化
   读风险不可达)。C 的 goto 以 encodeNow(自 cur 扫描转出至 encode 块)/
   overflow(→ _dest_overflow)标志重组;_dest_overflow 仅 fillOutput 落
   overflow 适配,非 fillOutput 直落 (0,0)(C retval==0)。ovml/ovoff 自
   两处 encode 位点(即时编码 + encode 循环)传播。opt 写入条件
   `pos > last_match_pos+3 || price <= opt[pos].price - favor`,favor 为
   (int)favorDecSpeed ∈ {0,1}。回溯改写 while(true) 的 break 条件
   `next_matchLength > candidate_pos` 逐字(双交换次序保持)。 */
internal func LZ4HC_compress_optimal(ctx: LZ4_streamHC_t,
        source: CPointer<UInt8>, ipStart: Int64,
        dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        nbSearches: Int32, sufficientLen: Int64,
        limit: Int32, fullUpdate: Bool,
        dict: Int32, favorDecSpeed: Bool): (Int64, Int64) {
    /* C HEAPMODE 每次 ALLOC(L1890-1893) —— 仓颉侧每次调用新建,等价 */
    let opt = Array<LZ4HC_optimal>(Int64(LZ4_OPT_NUM) + 3, {_ => LZ4HC_optimal(0, 0, 1, 0)})

    let favor: Int32 = if (favorDecSpeed) { 1 } else { 0 }       /* (int)favorDecSpeed */
    var sufficientLenLocal: Int64 = sufficientLen
    let iend: Int64 = ipStart + srcSize
    let mflimit: Int64 = iend - LZ4_MFLIMIT
    let matchlimit: Int64 = iend - LZ4_LASTLITERALS
    var ip: Int64 = ipStart
    var anchor: Int64 = ipStart
    var op: Int64 = 0
    var opSaved: Int64 = 0
    var oend: Int64 = dstCapacity
    var ovml: Int32 = Int32(LZ4_MINMATCH)                        /* L1899: overflow - last sequence */
    var ovoff: Int32 = 0

    if (limit == LZ4_OUTPUT_FILL) {
        oend -= LZ4_LASTLITERALS                                 /* L1903: fillOutput 尾量预留 hack */
    }
    if (sufficientLenLocal >= Int64(LZ4_OPT_NUM)) {              /* L1904 */
        sufficientLenLocal = Int64(LZ4_OPT_NUM) - 1
    }

    var overflow = false                                         /* goto _dest_overflow */

    /* Main Loop (L1906) */
    while (ip <= mflimit) {
        let llen: Int32 = Int32(ip - anchor)                     /* L1908 */
        var bestMlen: Int32 = 0
        var bestOff: Int32 = 0
        var cur: Int32 = 0
        var lastMatchPos: Int32 = 0

        let firstMatch = LZ4HC_findLongerMatch(ctx, source, dictQ, dictCtxQ,
            ip, matchlimit, Int32(LZ4_MINMATCH) - 1, nbSearches, dict, favorDecSpeed)   /* L1912 */
        if (firstMatch.len == 0) {                               /* L1913 */
            ip += 1
            continue
        }

        if (Int64(firstMatch.len) > sufficientLenLocal) {        /* L1915: 足够好 → 即时编码 */
            let firstML: Int32 = firstMatch.len
            opSaved = op
            let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(source, ip,
                dst, op, anchor, firstML, firstMatch.off, limit, oend)
            if (issue != 0) {
                op = nop
                ovml = firstML                                   /* L1920-1921 */
                ovoff = firstMatch.off
                overflow = true
                break
            }
            ip = nip
            op = nop
            anchor = nanchor
            continue
        }

        /* 首位置字面量价格(L1924-1933) */
        var rPos: Int32 = 0
        while (rPos < Int32(LZ4_MINMATCH)) {
            let cost: Int32 = LZ4HC_literalsPrice(llen + rPos)
            opt[Int64(rPos)] = LZ4HC_optimal(cost, 0, 1, llen + rPos)
            rPos += 1
        }
        /* 初始 match 价格(L1935-1945);matchML < sufficient_len < LZ4_OPT_NUM */
        let matchML: Int32 = firstMatch.len
        let offset0: Int32 = firstMatch.off
        var mlen: Int32 = Int32(LZ4_MINMATCH)
        while (mlen <= matchML) {
            let cost: Int32 = LZ4HC_sequencePrice(llen, mlen)
            opt[Int64(mlen)] = LZ4HC_optimal(cost, offset0, mlen, llen)
            mlen += 1
        }
        lastMatchPos = firstMatch.len                            /* L1946 */
        var addLit: Int32 = 1
        while (addLit <= 3) {                                    /* TRAILING_LITERALS */
            let lmp: Int64 = Int64(lastMatchPos)
            let litCost: Int32 = opt[lmp].price + LZ4HC_literalsPrice(addLit)
            opt[lmp + Int64(addLit)] = LZ4HC_optimal(litCost, 0, 1, addLit)
            addLit += 1
        }

        /* cur 扫描(L1954) */
        var encodeNow = false                                    /* goto encode */
        cur = 1
        while (cur < lastMatchPos) {
            let curPtr: Int64 = ip + Int64(cur)
            if (curPtr > mflimit) {                              /* L1958 */
                break
            }
            if (fullUpdate) {                                    /* L1962-1966: 双条件剪枝 */
                if ((opt[Int64(cur) + 1].price <= opt[Int64(cur)].price) &&
                        (opt[Int64(cur) + Int64(LZ4_MINMATCH)].price < opt[Int64(cur)].price + 3)) {
                    cur += 1
                    continue
                }
            } else {
                if (opt[Int64(cur) + 1].price <= opt[Int64(cur)].price) {   /* L1968 */
                    cur += 1
                    continue
                }
            }
            let newMatch = LZ4HC_findLongerMatch(ctx, source, dictQ, dictCtxQ,
                curPtr, matchlimit,
                if (fullUpdate) { Int32(LZ4_MINMATCH) - 1 } else { lastMatchPos - cur },
                nbSearches, dict, favorDecSpeed)                 /* L1970-1974 */
            if (newMatch.len == 0) {                             /* L1975 */
                cur += 1
                continue
            }

            if ((Int64(newMatch.len) > sufficientLenLocal) ||
                    (newMatch.len + cur >= LZ4_OPT_NUM)) {       /* L1979: 即时编码 */
                bestMlen = newMatch.len
                bestOff = newMatch.off
                lastMatchPos = cur + 1
                encodeNow = true
                break
            }

            /* match 前:字面量前缀改价(L1988-1998) */
            let baseLitlen: Int32 = opt[Int64(cur)].litlen
            var litlen: Int32 = 1
            while (litlen < Int32(LZ4_MINMATCH)) {
                let price: Int32 = opt[Int64(cur)].price -
                    LZ4HC_literalsPrice(baseLitlen) + LZ4HC_literalsPrice(baseLitlen + litlen)
                let pos: Int32 = cur + litlen
                if (price < opt[Int64(pos)].price) {
                    opt[Int64(pos)] = LZ4HC_optimal(price, 0, 1, baseLitlen + litlen)
                }
                litlen += 1
            }

            /* cur 处 match 定价(L2001-2030) */
            let matchML2: Int32 = newMatch.len
            var ml: Int32 = Int32(LZ4_MINMATCH)
            while (ml <= matchML2) {
                let pos: Int32 = cur + ml
                let offsetM: Int32 = newMatch.off
                var price: Int32 = 0
                var ll: Int32 = 0
                if (opt[Int64(cur)].mlen == 1) {                 /* L2013 */
                    ll = opt[Int64(cur)].litlen
                    price = (if (cur > ll) {                     /* L2015 */
                        opt[Int64(cur - ll)].price
                    } else {
                        0
                    }) + LZ4HC_sequencePrice(ll, ml)
                } else {
                    ll = 0
                    price = opt[Int64(cur)].price + LZ4HC_sequencePrice(0, ml)   /* L2019-2020 */
                }
                if ((pos > lastMatchPos + 3) ||                  /* L2026 */
                        (price <= opt[Int64(pos)].price - favor)) {   /* L2027: favor 偏置 */
                    if ((ml == matchML2) && (lastMatchPos < pos)) {   /* L2030-2031 */
                        lastMatchPos = pos
                    }
                    opt[Int64(pos)] = LZ4HC_optimal(price, offsetM, ml, ll)
                }
                ml += 1
            }
            /* 尾随字面量补全(L2032-2039) */
            var addLit2: Int32 = 1
            while (addLit2 <= 3) {
                let lmp: Int64 = Int64(lastMatchPos)
                let litCost: Int32 = opt[lmp].price + LZ4HC_literalsPrice(addLit2)
                opt[lmp + Int64(addLit2)] = LZ4HC_optimal(litCost, 0, 1, addLit2)
                addLit2 += 1
            }
            cur += 1
        }
        if (!encodeNow) {                                        /* L2042-2045 */
            bestMlen = opt[Int64(lastMatchPos)].mlen
            bestOff = opt[Int64(lastMatchPos)].off
            cur = lastMatchPos - bestMlen
        }

        /* encode(L2048):回溯链改写(L2053-2066,自尾向头交换;
           price/litlen 保持,mlen/off 双交换) */
        var candidatePos: Int32 = cur
        var selectedMatchLength: Int32 = bestMlen
        var selectedOffset: Int32 = bestOff
        while (true) {
            let nextMatchLength: Int32 = opt[Int64(candidatePos)].mlen   /* L2056: 可为 1 = 字面量 */
            let nextOffset: Int32 = opt[Int64(candidatePos)].off
            let keep = opt[Int64(candidatePos)]
            opt[Int64(candidatePos)] = LZ4HC_optimal(keep.price, selectedOffset,
                selectedMatchLength, keep.litlen)                /* L2057-2058 */
            selectedMatchLength = nextMatchLength                /* L2059 */
            selectedOffset = nextOffset                          /* L2060 */
            if (nextMatchLength > candidatePos) {                /* L2062: 首 match 当选 */
                break
            }
            candidatePos -= nextMatchLength                      /* L2064 */
        }

        /* encode all recorded sequences in order (L2069-2081) */
        var rPos2: Int32 = 0
        while (rPos2 < lastMatchPos) {
            let ml: Int32 = opt[Int64(rPos2)].mlen
            let offset: Int32 = opt[Int64(rPos2)].off
            if (ml == 1) {                                       /* L2074: 字面量跳过 */
                ip += 1
                rPos2 += 1
                continue
            }
            rPos2 += ml
            opSaved = op
            let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(source, ip,
                dst, op, anchor, ml, offset, limit, oend)
            if (issue != 0) {
                op = nop
                ovml = ml                                        /* L2078-2079 */
                ovoff = offset
                overflow = true
                break
            }
            ip = nip
            op = nop
            anchor = nanchor
        }
        if (overflow) {
            break
        }
    }

    /* _dest_overflow(L2087-2106,仅 fillOutput;非 fillOutput → retval 0) */
    if (overflow) {
        if (limit == LZ4_OUTPUT_FILL) {
            let ll: Int64 = ip - anchor                          /* L2090 */
            let llAddbytes: Int64 = (ll + 240) / 255             /* L2091 */
            let llTotalCost: Int64 = 1 + llAddbytes + ll         /* L2092 */
            let maxLitPos: Int64 = oend - 3                      /* L2093: 2 offset + 1 token */
            op = opSaved                                         /* L2095: 恢复输出指针 */
            if (op + llTotalCost <= maxLitPos) {
                let bytesLeftForMl: Int64 = maxLitPos - (op + llTotalCost)   /* L2098 */
                let maxMlSize: Int64 = LZ4_MINMATCH + (LZ4_ML_MASK - 1) + bytesLeftForMl * 255   /* L2099 */
                if (Int64(ovml) > maxMlSize) {                   /* L2101 */
                    ovml = Int32(maxMlSize)
                }
                if ((oend + LZ4_LASTLITERALS) - (op + llTotalCost + 2) - 1 + Int64(ovml) >= LZ4_MFLIMIT) {   /* L2103 */
                    let (issue, nip, nop, nanchor) = LZ4HC_encodeSequence(source, ip,
                        dst, op, anchor, ovml, ovoff, LZ4_OUTPUT_NOT_LIMITED, oend)   /* L2105: notLimited 不可能 issue */
                    if (issue == 0) {
                        ip = nip
                        op = nop
                        anchor = nanchor
                    }
                }
            }
            /* goto _last_literals */
        } else {
            return (0, 0)                                        /* _return_label: retval == 0 */
        }
    }

    /* _last_literals(L2110-2131) */
    var lastRunSize: Int64 = iend - anchor                       /* L2111 */
    var llAdd: Int64 = (lastRunSize + 255 - LZ4_RUN_MASK) / 255
    let totalSize: Int64 = 1 + llAdd + lastRunSize
    if (limit == LZ4_OUTPUT_FILL) {
        oend += LZ4_LASTLITERALS                                 /* L2115: 恢复真实 oend */
    }
    if (limit != LZ4_OUTPUT_NOT_LIMITED && (op + totalSize > oend)) {   /* L2116 */
        if (limit == LZ4_OUTPUT_LIMITED) {
            return (0, 0)                                        /* L2117 */
        }
        lastRunSize = (oend - op) - 1                            /* L2120: 适配填满 dst */
        llAdd = (lastRunSize + 256 - LZ4_RUN_MASK) / 256         /* L2121: 255/256 非对称(同 T2) */
        lastRunSize -= llAdd
    }
    ip = anchor + lastRunSize                                    /* L2125: fillOutput 时可 < iend */

    if (lastRunSize >= LZ4_RUN_MASK) {                           /* L2127-2128 */
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
    LZ4_memcpyPtr(dst, op, source, anchor, lastRunSize)          /* L2129 */
    op += lastRunSize

    return (op, ip - ipStart)                                    /* L2134-2135: *srcSizePtr = ip; retval = op */
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
    /* 连续流位置重定基(上游 ip 为真实指针,ipIndex = (ip - prefixStart) +
       dictLimit 由状态推导;仓颉核心以基指针 + 相对 ip 表达)。入口不变量:
       src 恒指向缓冲 prefixEndIdx 处 —— 一次性(initInternal 锚定 srcIdx ==
       prefixEndIdx)、continue 连续块(sameBuf 要求 srcIdx == prefixEndIdx)
       与 setExternalDict/整态接管后(prefixStartIdx == prefixEndIdx ==
       srcIdx)均成立,且 prefixBuf === srcBuf 同一数组(acquire 覆盖)。
       ipStart = 旧 prefixEndIdx - prefixStartIdx(块起点相对 prefixStart
       基的偏移);prefixBase = src - ipStart 即虚拟索引 dictLimit 映射的
       基指针,与上游 hc4->prefixStart 一致 —— 核心内 ipIndex/endMatchIdx
       等虚拟索引与候选回读据此天然正确,一次性路径 ipStart==0 行为不变。 */
    let ipStart: Int64 = s.prefixEndIdx - srcSize - s.prefixStartIdx
    let prefixBase: CPointer<UInt8> = unsafe { src - ipStart }
    let cParam = lz4hcGetCLevelParams(cLevel)                       /* L1441 */
    let favor: Bool = s.favorDecSpeed                               /* L1442 */
    var result: (Int64, Int64) = (0, 0)
    if (cParam.strat == LZ4HC_STRAT_MID) {
        /* lz4mid 策略(L1445-1448):T3 已接通 */
        result = LZ4MID_compress(s, prefixBase, ipStart, dictQ, dictCtxQ, dst, srcSize, dstCapacity, limit, dict)
    } else if (cParam.strat == LZ4HC_STRAT_HC) {
        result = LZ4HC_compress_hashChain(s, prefixBase, ipStart, dictQ, dictCtxQ, dst, srcSize, dstCapacity,   /* L1450-1452 */
            cParam.nbSearches, limit, dict)
    } else {
        /* lz4opt strategy (L1455-1459): T4 connected — fullUpdate = cLevel >=
            LZ4HC_CLEVEL_MAX (ultra mode), sufficient_len = targetLength, favor
            read from the stream state (L1442). */
        result = LZ4HC_compress_optimal(s, prefixBase, ipStart, dictQ, dictCtxQ, dst, srcSize, dstCapacity,
            cParam.nbSearches, Int64(cParam.targetLength), limit,
            cLevel >= LZ4HC_CLEVEL_MAX, dict, favor)
    }
    if (result[0] <= 0) {                                           /* L1461 */
        s.dirty = true
    }
    return result
}

/* lz4hcCompressRun:一次性/流式共用的单一 unsafe 域(指针三律:acquire →
    分派 → release,域内不分配;M3b lz4ContinueRun 先例)。srcQ 恒为
    prefixEnd 锚点处的块指针 —— 连续 continue 时 srcQ ≠ prefixStart 指针,
    prefixStart 基由 generic_internal 内部重定基推导(见其注释);
    extDict 段
    (dictBuf)与 dictCtx 前缀缓冲存在才 acquire,**T5 修正**:dictCtx!=None
    但 dictBuf==None 时,dictCtxQ 仍须为 dictCtx 自身 prefixBuf 的指针
    (usingDictCtxHc 咨询块要按 dictCtx 的 prefix 读取);此前传 srcQ 的
    写法会让 dictCtx 咨询块读到工作 prefix 的别名——T2 ledger minor。
    **T5 修复轮**:dictBuf / dictCtx.prefixBuf 与 srcBuf 同一分配时禁止
    重复 acquire(pre-acquire lz4SameBuffer 判定,命中由 srcBase 派生)。
    4 个分支独立 dispatch:
    (a) dictBuf=None, dictCtx=None → noDictCtx 路径 srcQ 占全部三位置
    (b) dictBuf=Some, dictCtx=None → noDictCtx with extDict
    (c) dictBuf=Some, dictCtx=Some → usingDictCtxHc consult
        (dictCtx 也可能是已 memcpy 后 dictBuf=None,见 (d))
    (d) dictBuf=None, dictCtx=Some → usingDictCtxHc consult
        dictCtxQ = dictCtx.prefixBuf + dictCtx.prefixStartIdx
    返回 (result, srcSizeOut)。 */
internal func lz4hcCompressRun(s: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64,
        dst: Array<UInt8>, dstCapacity: Int64,
        cLevel: Int32, limit: Int32): (Int32, Int64) {
    /* 同分配判定必须在任何 acquire 之前完成(lz4SameBuffer 带哨兵写,
       不得在有 raw handle 持有期间调用)。dictBuf === srcBuf(edge④ 几何:
       loadDictHC(D) 后 continue 的块仍驻 D)与 dictCtx.prefixBuf ===
       srcBuf(attach 后以字典流 prefix 缓冲本身作为工作块)都经公共 API
       可达 —— 命中时禁止重复 acquire,指针由已持有的 srcBase 派生。 */
    let dictBufOpt = s.dictBuf
    let dictCtxOpt = s.dictCtx
    let dictSameAsSrc: Bool = match (dictBufOpt) {
        case Some(db) => lz4SameBuffer(db, srcBuf)
        case None => false
    }
    let pbufSameAsSrc: Bool = match (dictCtxOpt) {
        case Some(dctx) =>
            match (dctx.prefixBuf) {
                case Some(pbuf) => lz4SameBuffer(pbuf, srcBuf)
                case None => false
            }
        case None => false
    }
    unsafe {
        let sh = acquireArrayRawData<UInt8>(srcBuf)
        let dh = acquireArrayRawData<UInt8>(dst)
        let srcBase = sh.pointer
        let srcQ = srcBase + srcIdx
        var r: (Int64, Int64) = (0, 0)
        if (let Some(db) <- dictBufOpt) {
            if (dictSameAsSrc) {
                /* db === srcBuf:同一分配已由 sh 持有,免二次 acquire */
                let dictQ = srcBase + s.dictStartIdx
                r = lz4hcRunDictCtxDispatch(s, srcBuf, srcIdx, srcBase, srcQ,
                    dictQ, dh.pointer, srcSize, dstCapacity, cLevel, limit, pbufSameAsSrc)
            } else {
                let bh = acquireArrayRawData<UInt8>(db)
                let dictQ = bh.pointer + s.dictStartIdx
                r = lz4hcRunDictCtxDispatch(s, srcBuf, srcIdx, srcBase, srcQ,
                    dictQ, dh.pointer, srcSize, dstCapacity, cLevel, limit, pbufSameAsSrc)
                releaseArrayRawData<UInt8>(bh)
            }
        } else {
            /* dictBuf=None:可能 noDictCtx,也可能 usingDictCtxHc consult
               (dictCtx 自带 prefixBuf 但本流 extDict 空 —— T5 修正) */
            r = lz4hcRunDictCtxDispatch(s, srcBuf, srcIdx, srcBase, srcQ,
                srcQ, dh.pointer, srcSize, dstCapacity, cLevel, limit, pbufSameAsSrc)
        }
        releaseArrayRawData<UInt8>(dh)
        releaseArrayRawData<UInt8>(sh)
        return (Int32(r[0]), r[1])
    }
}

/* lz4hcRunDictCtxDispatch:dictCtx 三态分派(dictBuf 侧 dictQ 指针已由
    调用方解析)。dctx.prefixBuf 与 srcBuf 同一分配(pbufSameAsSrc,调用方
    pre-acquire 判定)时以已持有的 srcBase 派生 dictCtxQ,免二次 acquire;
    不同分配才对 pbuf acquire。 */
internal func lz4hcRunDictCtxDispatch(s: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, srcBase: CPointer<UInt8>,
        srcQ: CPointer<UInt8>, dictQ: CPointer<UInt8>, dstQ: CPointer<UInt8>,
        srcSize: Int64, dstCapacity: Int64, cLevel: Int32, limit: Int32,
        pbufSameAsSrc: Bool): (Int64, Int64) {
    unsafe {
        match (s.dictCtx) {
            case Some(dctx) =>
                match (dctx.prefixBuf) {
                    case Some(pbuf) =>
                        if (pbufSameAsSrc) {
                            /* dctx.prefixBuf === srcBuf:同分配已持有 */
                            return lz4hcCompressGeneric(s, srcBuf, srcIdx, srcQ, dictQ,
                                srcBase + dctx.prefixStartIdx,
                                dstQ, srcSize, dstCapacity, cLevel, limit)
                        }
                        let phHandle = acquireArrayRawData<UInt8>(pbuf)
                        let r = lz4hcCompressGeneric(s, srcBuf, srcIdx, srcQ, dictQ,
                            phHandle.pointer + dctx.prefixStartIdx,
                            dstQ, srcSize, dstCapacity, cLevel, limit)
                        releaseArrayRawData<UInt8>(phHandle)
                        return r
                    case None =>
                        /* dictCtx 自身无 prefixBuf —— 咨询不可达,落 noDictCtx;
                           C 等价 dictCtx prefixStart==NULL 的 lookup 表 */
                        return lz4hcCompressGeneric(s, srcBuf, srcIdx, srcQ, dictQ, dictQ,
                            dstQ, srcSize, dstCapacity, cLevel, limit)
                }
            case None =>
                return lz4hcCompressGeneric(s, srcBuf, srcIdx, srcQ, dictQ, dictQ,
                    dstQ, srcSize, dstCapacity, cLevel, limit)
        }
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

/*-************************************
*  Streaming (lz4hc.c L1675-1813)
**************************************/
/* LZ4HC_setExternalDictPtr(L1709-1727 同型指针入参):dictCtx 整态拷贝
   路径的 setExternalDict(L1508)。此刻 s.prefixBuf 已是 dictCtx 的
   prefixBuf(整态拷贝交接),而该缓冲正被 lz4hcCompressRun 以 ph 持有 ——
   单 unsafe 域 hygiene 禁止二次 acquire,旧前缀基址改为 already-held
   指针入参:oldPrefixStartPtr = dictCtxQ = prefixStart 指针(虚拟索引
   dictLimit 映射的基址,srcQ 即新块 newBlockBuf[newBlockIdx] 侧指针)。
   Insert(end-3) 同上游:target 相对 prefixStart 基址 = prefixLen - 3。 */
internal func LZ4HC_setExternalDictPtr(s: LZ4_streamHC_t,
        oldPrefixStartPtr: CPointer<UInt8>, newBlockBuf: Array<UInt8>,
        newBlockIdx: Int64): Unit {
    let prefixLen: Int64 = s.prefixEndIdx - s.prefixStartIdx            /* end - prefixStart */
    if (prefixLen >= 4 &&                                               /* L1712 end >= prefixStart+4 */
            lz4hcGetCLevelParams(s.compressionLevel).strat != LZ4HC_STRAT_MID) {
        LZ4HC_insert(s, oldPrefixStartPtr, prefixLen - 3)               /* L1714 Insert(end-3) */
    }
    s.lowLimit = s.dictLimit                                            /* L1718 */
    s.dictBuf = s.prefixBuf                                             /* L1719 别名 */
    s.dictStartIdx = s.prefixStartIdx
    s.dictLimit = s.dictLimit + UInt32(prefixLen & 0xFFFFFFFFi64)       /* L1720 */
    s.prefixBuf = Some(newBlockBuf)                                     /* L1721 */
    s.prefixStartIdx = newBlockIdx
    s.prefixEndIdx = newBlockIdx                                        /* L1722 end = newBlock */
    s.nextToUpdate = s.dictLimit                                        /* L1723 */
    s.dictCtx = None                                                    /* L1726 */
}

/* lz4hcCompressGenericDictCtx(L1490-1514):dictCtx!=None 时三路分派。
   position = prefixLen + (dictLimit - lowLimit) —— 上游以指针差 + dictLimit
   差,仓颉双段引用对模型下等价(虚拟索引空间累计:prefix 段
   [dictLimit, dictLimit + prefixLen),dict 段 [lowLimit, dictLimit) →
   total = prefixLen + dictLimit - lowLimit)。
   1) position >= 64 KB → dictCtx = None,走 noDictCtx 直通
      (上游 L1503-1505:大字典已具备独立压缩能力,不再借用 dictCtx 的表)
   2) position == 0 && srcSize > 4 KB && isStateCompatible
      → **整态拷贝**:hashTable/chainTable 数组深拷贝(C LZ4_memcpy) +
      标量复制 + 缓冲引用对浅拷贝(C memcpy 全结构体浅别名 dictCtx 是
      const 不可写,这里改用 dictCtx 自身缓冲的浅拷贝)
      + setExternalDict(src) + compressionLevel = cLevel → noDictCtx
      (上游 L1507-1510:一字节都不漏的整态接管,后续不再用 dictCtx)
   3) 否则 → genericInternal(usingDictCtxHc) 咨询路径
    返回 (result, srcSizeOut)。注:此函数受调用方 unsafe 域保护,整态
    拷贝路径的 setExternalDict (L1508) 经 LZ4HC_setExternalDictPtr 走
    already-held 指针入参(dictCtx 的 prefixBuf 已被 lz4hcCompressRun
    以 ph 持有,单 unsafe 域内不再二次 acquire)。整态拷贝后
    s.prefixBuf/dictBuf 已指向 dictCtx 的 prefixBuf/dictBuf(浅别名),
    setExternalDict 必须把 srcBuf 接管为新 prefix。 */
internal func lz4hcCompressGenericDictCtx(s: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64,
        src: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        cLevel: Int32, limit: Int32): (Int64, Int64) {
    let position: UInt64 = UInt64(s.prefixEndIdx - s.prefixStartIdx) +
        UInt64(s.dictLimit - s.lowLimit)                                /* L1501 */
    match (s.dictCtx) {
        case Some(dctx) =>
            if (position >= 65536u64) {                                  /* L1503 */
                s.dictCtx = None
                return LZ4HC_compress_generic_internal(s, src, dictQ, dictCtxQ, dst,
                    srcSize, dstCapacity, cLevel, limit, LZ4HC_DICT_NODICTCTX)
            } else if (position == 0u64 && srcSize > 4096 &&
                    lz4hcIsStateCompatible(s, dctx)) {                   /* L1506 */
                /* 整态拷贝(L1507 LZ4_memcpy):深拷贝两表 + 标量 + 缓冲引用对
                   浅拷贝(dictCtx 是 const 不可写,这里改为以 dictCtx 当前
                   快照同步 s,dictCtx 保留引用对) */
                var i: Int64 = 0
                while (i < s.hashTable.size) {
                    s.hashTable[i] = dctx.hashTable[i]
                    i += 1
                }
                i = 0
                while (i < s.chainTable.size) {
                    s.chainTable[i] = dctx.chainTable[i]
                    i += 1
                }
                s.prefixBuf = dctx.prefixBuf
                s.prefixStartIdx = dctx.prefixStartIdx
                s.prefixEndIdx = dctx.prefixEndIdx
                s.dictBuf = dctx.dictBuf
                s.dictStartIdx = dctx.dictStartIdx
                s.dictLimit = dctx.dictLimit
                s.lowLimit = dctx.lowLimit
                s.nextToUpdate = dctx.nextToUpdate
                s.favorDecSpeed = dctx.favorDecSpeed
                /* Insert(end-3) 与 level 切换:setExternalDict 内置 strategy
                    guard(strat != lz4mid + prefixLen≥4);继续 noDictCtx。
                    setExternalDictPtr 以 dictCtxQ 为旧前缀基址(already-
                    held,免二次 acquire)、srcBuf/srcIdx 为新 prefix。 */
                LZ4HC_setExternalDictPtr(s, dictCtxQ, srcBuf, srcIdx)     /* L1508 */
                s.compressionLevel = cLevel                               /* L1509 */
                /* 整态接管后 dict 段(dictBuf)即 dictCtx 的旧前缀缓冲,
                    其基指针 dictStart == dictCtxQ(ph.pointer +
                    dctx.prefixStartIdx)。入口时刻的 dictQ 快照已随
                    wrapper 内状态改变而失效 —— memcpy 路径入口
                    dictBuf==None,dictQ 别名 srcQ,继续沿用会让 extDict
                    读取越过 src 数组末尾越界。两个指针位均传 dictCtxQ
                    (noDictCtx 模式下 dictCtxQ 位不参与读取)。 */
                return LZ4HC_compress_generic_internal(s, src, dictCtxQ, dictCtxQ, dst,
                    srcSize, dstCapacity, cLevel, limit, LZ4HC_DICT_NODICTCTX)
            } else {                                                      /* L1511 */
                return LZ4HC_compress_generic_internal(s, src, dictQ, dictCtxQ, dst,
                    srcSize, dstCapacity, cLevel, limit, LZ4HC_DICT_USINGDICTCTXHC)
            }
        case None => return (0, 0)   /* 不可达:dictCtx!=None 进入此函数 */
    }
}

/* lz4hcCompressGeneric(L1516-1532):T2 占位直通 genericInternal,T5 落三路
   分派(dictCtx!=None → dictCtx wrapper,否则 noDictCtx 直通)。dictCtx wrapper
   需要 srcBuf + srcIdx 以便整态拷贝路径的 setExternalDict 把 srcBuf 作为新
   prefix 接管(src 指针单独传亦可,但 Array 入参让 wrapper 内嵌套 unsafe
   域更直观)。 */
internal func lz4hcCompressGeneric(s: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64,
        src: CPointer<UInt8>, dictQ: CPointer<UInt8>, dictCtxQ: CPointer<UInt8>,
        dst: CPointer<UInt8>, srcSize: Int64, dstCapacity: Int64,
        cLevel: Int32, limit: Int32): (Int64, Int64) {
    match (s.dictCtx) {
        case Some(_) =>
            return lz4hcCompressGenericDictCtx(s, srcBuf, srcIdx,
                src, dictQ, dictCtxQ, dst, srcSize, dstCapacity, cLevel, limit)
        case None =>
            return LZ4HC_compress_generic_internal(s, src, dictQ, dictCtxQ, dst,
                srcSize, dstCapacity, cLevel, limit, LZ4HC_DICT_NODICTCTX)
    }
}

/* LZ4HC_setExternalDict(L1709-1727):extDict 切换。end≥prefixStart+4 且
   strat != lz4mid → Insert(end-3)(注意 setExternalDict 调用时 prefixBuf
   仍为旧块,Insert 走 prefixBuf 路径);随后摘除旧前缀、抬 dictLimit
   += prefixLen、prefix 换新块、nextToUpdate 复位至 dictLimit、dictCtx=None。
   仓颉双段引用对模型:dictBuf/prefixBuf 引用对交接 + dictStartIdx 镜像
   旧 prefixStart(零拷贝,C L1719-1720 别名)。 */
internal func LZ4HC_setExternalDict(s: LZ4_streamHC_t, newBlockBuf: Array<UInt8>,
        newBlockIdx: Int64): Unit {
    let prefixLen: Int64 = s.prefixEndIdx - s.prefixStartIdx              /* L1712: end - prefixStart */
    if (prefixLen >= 4 &&
            lz4hcGetCLevelParams(s.compressionLevel).strat != LZ4HC_STRAT_MID) {
        /* Insert(end-3):仓颉 Insert 的 prefixPtr 参数 = 虚拟索引
            dictLimit 映射的基指针 = 数组基 + prefixStartIdx,target
            相对该基 = prefixLen - 3;prefixStartIdx != 0 时(如 hcdict
            dd=131072 截尾锚定后 prefixStartIdx=65536)数组基与
            dictLimit 基不重合,误用数组基 + prefixEndIdx-3 会错位 */
        match (s.prefixBuf) {
            case Some(pbuf) =>
                unsafe {
                    let h = acquireArrayRawData<UInt8>(pbuf)
                    LZ4HC_insert(s, h.pointer + s.prefixStartIdx, prefixLen - 3)
                    releaseArrayRawData<UInt8>(h)
                }
            case None => ()
        }
    }
    s.lowLimit = s.dictLimit                                              /* L1718 */
    s.dictBuf = s.prefixBuf                                               /* L1719 别名 */
    s.dictStartIdx = s.prefixStartIdx
    s.dictLimit = s.dictLimit + UInt32(prefixLen & 0xFFFFFFFFi64)         /* L1720 */
    s.prefixBuf = Some(newBlockBuf)                                       /* L1721 */
    s.prefixStartIdx = newBlockIdx
    s.prefixEndIdx = newBlockIdx                                          /* L1722 end = newBlock */
    s.nextToUpdate = s.dictLimit                                          /* L1723 */
    s.dictCtx = None                                                      /* L1726 */
}

/* lz4hcContinueGeneric(L1729-1769):continue 主体。顺序:
   auto-init(prefixBuf.isNone → initInternal)、溢出检查(不可达保留)、
   src==end 判定(lz4SameBuffer && srcIdx == prefixEndIdx;否则 setExternalDict)、末
   generic。重叠收缩(sourceEnd 与 dict 段相交,仅同一分配下执行 ——
   dictBuf 与 srcBuf 同一缓冲且 [src, src+srcSize) 与 dict 段相交 → 抬
   lowLimit/dictStartIdx 至 sourceEnd,过短则丢弃 dict)。 */
internal func lz4hcContinueGeneric(s: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64,
        dst: Array<UInt8>, dstCapacity: Int64,
        cLevel: Int32, limit: Int32): (Int32, Int64) {
    let prefixBufBefore = s.prefixBuf                                     /* L1740 */
    if (prefixBufBefore.isNone()) {
        LZ4HC_initInternal(s, srcBuf, srcIdx)                             /* L1741 */
    }
    /* 溢出检查(L1744-1748,不可达:实际触发需 prefixLen + dictLimit > 2GB,
       仓颉侧 prefixEndIdx 索引已用 Int64 不溢出,但与上游 64 KB loadDictHC
       闸等价的语义保留以匹配二工具链一致性测试)。上游 L1746-1747 加载的是
       **当前前缀的尾部**(end - dictSize,驻 prefixBuf),非 srcBuf —— 以
       lz4hcLoadDictHCAt 在 prefixBuf 内锚定 prefixEndIdx - dictSize 表达。 */
    let prefixLen: Int64 = s.prefixEndIdx - s.prefixStartIdx
    if (UInt64(prefixLen) + UInt64(s.dictLimit) > 0x80000000u64) {
        var dictSize: Int64 = prefixLen
        if (dictSize > 65536) { dictSize = 65536 }
        match (s.prefixBuf) {
            case Some(pb) =>
                lz4hcLoadDictHCAt(s, pb, s.prefixEndIdx - dictSize, Int32(dictSize))
            case None => ()
        }
    }
    /* src==end 判定(L1751-1752):同缓冲且 srcIdx == prefixEndIdx → 直连
       (src 异缓冲 → setExternalDict) */
    let sameBuf: Bool = match (s.prefixBuf) {
        case Some(pb) => lz4SameBuffer(pb, srcBuf) && srcIdx == s.prefixEndIdx
        case None => false
    }
    if (!sameBuf) {
        LZ4HC_setExternalDict(s, srcBuf, srcIdx)
    }
    /* 重叠收缩(L1755-1766):sourceEnd = src + srcSize;dict 段 = dictBuf[0,
       dictLimit-lowLimit);若相交 → 抬 lowLimit/dictStartIdx 至 sourceEnd
       (clamp 至 dictEnd);过小则丢弃 dict(置 lowLimit == dictLimit,
       dictStartIdx == prefixStartIdx)。 */
    match (s.dictBuf) {
        case Some(db) =>
            if (lz4SameBuffer(db, srcBuf)) {                              /* 同分配判定 */
                let dictStartIdx: Int64 = s.dictStartIdx
                let dictEndIdx: Int64 = dictStartIdx + Int64(s.dictLimit - s.lowLimit)
                let sourceEndIdx: Int64 = srcIdx + srcSize
                if (sourceEndIdx > dictStartIdx && srcIdx < dictEndIdx) {
                    var newDictEnd: Int64 = sourceEndIdx
                    if (newDictEnd > dictEndIdx) { newDictEnd = dictEndIdx }
                    s.lowLimit = s.lowLimit + UInt32((newDictEnd - dictStartIdx) & 0xFFFFFFFFi64)
                    s.dictStartIdx = newDictEnd
                    if (Int64(s.dictLimit - s.lowLimit) < LZ4HC_HASHSIZE) {  /* L1763: <4 → 丢弃 */
                        s.lowLimit = s.dictLimit
                        s.dictStartIdx = s.prefixStartIdx
                    }
                }
            }
        case None => ()
    }
    return lz4hcCompressRun(s, srcBuf, srcIdx, srcSize, dst, dstCapacity, cLevel, limit)
}

/* LZ4_loadDictHC(L1675-1701):>64KB 截尾(以 dictStartIdx 偏移表达,
    **不拷贝**);cLevel 保存 → initStreamHC 全量 → setCompressionLevel 复原 →
    initInternal(dictionary, 0) → prefixEndIdx=dictSize → mid 策略 →
    LZ4MID_fillHTable else dictSize ≥ 4 → Insert(end-3);返回 dictSize(截尾
    后);defensive dictSize<0 → 0。 */
public func LZ4_loadDictHC(state: LZ4_streamHC_t, dictionary: Array<UInt8>,
        dictSize: Int32): Int32 {
    if (dictSize < 0) { return 0 }                                         /* L1681 defensive */
    var ds: Int32 = dictSize
    var dictIdx: Int64 = 0
    if (ds > 65536) {                                                     /* L1683 */
        dictIdx = Int64(ds - 65536)
        ds = 65536
    }
    lz4hcLoadDictHCAt(state, dictionary, dictIdx, ds)
    return ds                                                             /* L1700 */
}

/* lz4hcLoadDictHCAt:loadDictHC 主体(dictionary 内锚定 dictIdx,长度 ds,
    调用方保证 0 ≤ dictIdx、dictIdx + ds ≤ dictionary.size)。公共 API 以
    dictIdx=0(或 >64KB 截尾偏移)调用;lz4hcContinueGeneric 的溢出分支以
    prefixBuf 尾部锚定调用(上游 L1746-1747 传入 (end - dictSize) 指针,
    即本 helper 的 dictIdx = prefixEndIdx - dictSize 语义)。 */
internal func lz4hcLoadDictHCAt(state: LZ4_streamHC_t, dictionary: Array<UInt8>,
        dictIdx: Int64, ds: Int32): Unit {
    let cLevel: Int32 = state.compressionLevel                            /* L1688-1692 */
    LZ4_initStreamHC(state)
    LZ4_setCompressionLevel(state, cLevel)
    LZ4HC_initInternal(state, dictionary, dictIdx)                         /* L1693 */
    state.prefixEndIdx = state.prefixStartIdx + Int64(ds)                  /* L1694 */
    let cp = lz4hcGetCLevelParams(state.compressionLevel)
    unsafe {
        let h = acquireArrayRawData<UInt8>(dictionary)
        if (cp.strat == LZ4HC_STRAT_MID) {
            LZ4MID_fillHTable(state, h.pointer + dictIdx, Int64(ds))       /* L1696 */
        } else {
            if (ds >= Int32(LZ4HC_HASHSIZE)) {                             /* L1698: ≥4 → Insert */
                LZ4HC_insert(state, h.pointer + dictIdx, Int64(ds) - 3)
            }
        }
        releaseArrayRawData<UInt8>(h)
    }
}

/* LZ4_attach_HC_dictionary(L1703-1705):dictCtx = Some(dctx 内部状态);
   C 的 NULL 摘除分支(NULL 字典流)对类状态不可达(无 null 引用),Task 3 attach
   先例不暴露 NULL 入口。 */
public func LZ4_attach_HC_dictionary(workingStream: LZ4_streamHC_t,
        dictionaryStream: LZ4_streamHC_t): Unit {
    workingStream.dictCtx = Some(dictionaryStream)
}

/* LZ4_compress_HC_continue(L1771-1778):(state, srcBuf, srcIdx, srcSize,
   dst, dstCapacity):Int32。compressBound 择限 + defensive srcIdx/srcSize
   越界 → 0(M3b continue 先例)。 */
public func LZ4_compress_HC_continue(state: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int32,
        dst: Array<UInt8>, dstCapacity: Int32): Int32 {
    if (srcIdx < 0 || srcIdx > srcBuf.size || srcSize < 0 ||
            srcIdx + Int64(srcSize) > srcBuf.size) {
        return 0                                                           /* defensive */
    }
    let limit: Int32 = if (dstCapacity < LZ4_compressBound(srcSize)) {
        LZ4_OUTPUT_LIMITED
    } else {
        LZ4_OUTPUT_NOT_LIMITED
    }
    let (r, _) = lz4hcContinueGeneric(state, srcBuf, srcIdx, Int64(srcSize),
        dst, Int64(dstCapacity), state.compressionLevel, limit)
    return r
}

/* LZ4_compress_HC_continue_destSize(L1780-1783):fillOutput。返回
   (cSize, consumed);失败 (r<=0) → (0, srcSize)。委托语义同
   LZ4_compress_HC_destSize。 */
public func LZ4_compress_HC_continue_destSize(state: LZ4_streamHC_t,
        srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int32,
        dst: Array<UInt8>, targetDestSize: Int32): (Int32, Int32) {
    if (srcIdx < 0 || srcIdx > srcBuf.size || srcSize < 0 ||
            srcIdx + Int64(srcSize) > srcBuf.size) {
        return (0, srcSize)                                                /* defensive */
    }
    let (r, consumed) = lz4hcContinueGeneric(state, srcBuf, srcIdx,
        Int64(srcSize), dst, Int64(targetDestSize), state.compressionLevel,
        LZ4_OUTPUT_FILL)
    if (r <= 0) {
        return (0, srcSize)
    }
    return (r, Int32(consumed))
}

/* LZ4_saveDictHC(L1791-1813):三重钳制(>64KB→64KB、<4→0、>prefixLen→
   prefixLen);拷贝 end-dictSize..end → safeBuffer[0..dictSize];endIndex
   平移(dictLimit=lowLimit=endIndex-dictSize、dictStartIdx=0、prefixBuf=
   Some(safeBuffer)、nextToUpdate 抬底)。 */
public func LZ4_saveDictHC(state: LZ4_streamHC_t, safeBuffer: Array<UInt8>,
        dictSize: Int32): Int32 {
    let prefixLen: Int32 = Int32(state.prefixEndIdx - state.prefixStartIdx)   /* L1794 */
    var d: Int32 = dictSize
    if (d > 65536) { d = 65536 }                                          /* L1797 */
    if (d < 4) { d = 0 }                                                  /* L1798 */
    if (d > prefixLen) { d = prefixLen }                                  /* L1799 */
    if (d > 0) {
        /* 拷贝 end-dictSize..end → safeBuffer[0..dictSize] */
        match (state.prefixBuf) {
            case Some(pbuf) =>
                unsafe {
                    let h = acquireArrayRawData<UInt8>(pbuf)
                    let s = acquireArrayRawData<UInt8>(safeBuffer)
                    LZ4_memcpyPtr(s.pointer, 0, h.pointer,
                        state.prefixEndIdx - Int64(d), Int64(d))
                    releaseArrayRawData<UInt8>(s)
                    releaseArrayRawData<UInt8>(h)
                }
            case None => ()
        }
    }
    let endIndex: UInt32 = UInt32(state.prefixEndIdx - state.prefixStartIdx) + state.dictLimit   /* L1803 */
    state.prefixBuf = Some(safeBuffer)                                    /* L1804-1805 */
    state.prefixStartIdx = 0
    state.prefixEndIdx = Int64(d)                                         /* end = safeBuffer+d */
    state.dictLimit = endIndex - UInt32(d)                                /* L1806 */
    state.lowLimit = endIndex - UInt32(d)                                 /* L1807 */
    state.dictStartIdx = 0                                                /* L1808 dictStart = prefixStart */
    if (state.nextToUpdate < state.dictLimit) {                           /* L1809-1810 */
        state.nextToUpdate = state.dictLimit
    }
    return d                                                              /* L1812 */
}
