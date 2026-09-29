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
    字典字段(dictCtx/dictionary/dictSize)留待 M3 补齐。 */
public class LZ4_stream_t {
    internal var hashTable: Array<UInt32> = Array<UInt32>(16384, {_ => 0u32})
    internal var currentOffset: UInt32 = 0u32
    internal var tableType: Int32 = 0
}

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
    state.tableType = 0
    return 0
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
*  Compression core (lz4.c L939-1347, noDict paths)
**************************************/
/* LZ4_compress_generic_validated 的 noDict 移植:byU16/byU32 × outputDirective
   (notLimited/limitedOutput/fillOutput,lz4.c L330-333)。C 的 const 参数宏展开改用
   Int32 指令 + Bool 显式分支,语义逐行对照;fillOutput 专属分支(目标 dst 恰好填满,
   读入 src 前缀):L994 提前失败、L1127-1131/L1156-1161 中途退回 last_literals、
   L1198-1216 match 缩短 + 哈希清除、L1316-1320 lastRun 收缩。
   返回 (压缩字节数, srcConsumed):consumed 上游仅在 fillOutput 下写出(L1340-1342),
   此处统一返回 ip 终值(= anchor + lastRun,L1336,对非 fill 模式即完整 srcSize),
   由调用方按模式取用。
   全部位置为相对 src 基指针的 Int64 索引;one-shot 新态 startIndex=0、base=source
   (L955-956),索引即 0 基偏移(controller ruling #3);hashTable 存 0 基索引。
   goto _last_literals / _next_match 用标志位 + 标签循环重排,控制流等价。 */
internal func LZ4_compress_generic_noDict(
        state: LZ4_stream_t, src: CPointer<UInt8>, n: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, outputDirective: Int32, acceleration: Int64): (Int64, Int64) {
    var ip: Int64 = 0                                  /* L953: ip = source */
    let startIndex: UInt32 = state.currentOffset       /* L955(one-shot 恒 0) */
    /* L956: base = source - startIndex —— 索引为 startIndex 相对量,新态即 0 基 */
    var anchor: Int64 = 0                              /* L970 */
    let iend: Int64 = n                                /* L971 */
    let mflimitPlusOne: Int64 = iend - LZ4_MFLIMIT + 1 /* L972 */
    let matchlimit: Int64 = iend - LZ4_LASTLITERALS    /* L973 */
    var op: Int64 = 0                                  /* L982: op = dest */
    let olimit: Int64 = dstCapacity                    /* L983 */
    var forwardH: UInt32 = 0
    /* C 的真值判断 if (outputDirective) 预展开 */
    let limited: Bool = outputDirective != LZ4_OUTPUT_NOT_LIMITED

    /* L994: fillOutput 且 maxOutputSize < 1 —— 无法写入任何内容(先于上下文更新) */
    if (outputDirective == LZ4_OUTPUT_FILL && dstCapacity < 1) {
        return (0, 0)
    }

    /* L999-1009: 更新上下文(dictSize 字段 M3 补;tableType 枚举值沿上游
       {clearedTable=0, byPtr, byU32, byU16} → byU32=2 / byU16=3) */
    state.currentOffset = startIndex + UInt32(n)
    state.tableType = if (byU16) { 3 } else { 2 }

    var runMain = true
    var goLastLiterals = false
    if (n >= LZ4_minLength) {                          /* L1011: 小输入全 literal */
        /* First Byte (L1013-1020) */
        let h0 = LZ4_hashPosition(src, ip, byU16)
        lz4PutIndexOnHash(state.hashTable, startIndex, h0, byU16)   /* L1018 */
        ip += 1
        forwardH = LZ4_hashPosition(src, ip, byU16)    /* L1020 */

        while (runMain) {                              /* L1023 Main Loop */
            /* Find a match(L1049-1110,byU32/byU16 搜索分支) */
            var forwardIp: Int64 = ip                  /* L1051 */
            var step: Int64 = 1                        /* L1052 */
            var searchMatchNb: Int64 = acceleration << LZ4_skipTrigger   /* L1053 */
            var matchPos: Int64 = 0
            do {
                let h: UInt32 = forwardH                /* L1055 */
                let current: UInt32 = UInt32(forwardIp) /* L1056(0 基索引) */
                let matchIndex: UInt32 = lz4GetIndexOnHash(state.hashTable, h, byU16)  /* L1057 */
                ip = forwardIp                          /* L1060 */
                forwardIp += step                      /* L1061 */
                step = searchMatchNb >> LZ4_skipTrigger /* L1062: step = searchMatchNb++ >> skipTrigger */
                searchMatchNb += 1
                if (forwardIp > mflimitPlusOne) {      /* L1064 */
                    goLastLiterals = true
                    break
                }
                matchPos = Int64(matchIndex)               /* L1091: match = base + matchIndex(noDict 单段) */
                forwardH = LZ4_hashPosition(src, forwardIp, byU16)      /* L1093 */
                lz4PutIndexOnHash(state.hashTable, current, h, byU16)    /* L1094 */
                /* L1097: dictIssue == noDictIssue,prefixIdxLimit 检查跳过 */
                /* L1099-1102: too far——byU16 豁免(DISTANCE_MAX==ABSOLUTE_MAX),
                   byU32 跳过 matchIndex + 65535 < current 的候选 */
                if ((!byU16) && (matchIndex + LZ4_DISTANCE_MAX < current)) {
                    continue
                }
                if (LZ4_readLE32(src, matchPos) == LZ4_readLE32(src, ip)) {  /* L1105 */
                    break                               /* L1107: match found */
                }
            } while (true)
            if (goLastLiterals) {                       /* goto _last_literals */
                break
            }

            /* L1114: filledIp = ip —— 本轮主循环已登记进哈希表的最远位置,
               fillOutput 缩短 match 后清除越界登记的上界(L1204-1215) */
            let filledIp: Int64 = ip

            /* Catch up(L1113-1118;noDict lowLimit = source → 索引 0,L997) */
            if ((matchPos > 0) && (LZ4_read8(src, ip - 1) == LZ4_read8(src, matchPos - 1))) {
                do {
                    ip -= 1
                    matchPos -= 1
                } while ((ip > anchor) && (matchPos > 0) &&
                    (LZ4_read8(src, ip - 1) == LZ4_read8(src, matchPos - 1)))
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
            LZ4_wildCopy8(dst, op, src, anchor, litLength)                    /* L1141 */
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

                /* Encode Offset(L1163-1172;maybe_extMem == false → 同段偏移) */
                LZ4_writeLE16(dst, op, UInt16(ip - matchPos))                    /* L1171 */
                op += 2

                /* Encode MatchLength(L1174-1235) */
                var matchCode: Int64 = LZ4_count(src, ip + LZ4_MINMATCH,
                    matchPos + LZ4_MINMATCH, matchlimit)                         /* L1191 */
                ip += matchCode + LZ4_MINMATCH                                /* L1192 */
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
                                let hClear = LZ4_hashPosition(src, ptr, byU16)
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

                /* Fill table(L1244-1251):位置 ip-2 */
                let hFill = LZ4_hashPosition(src, ip - 2, byU16)
                lz4PutIndexOnHash(state.hashTable, UInt32(ip - 2), hFill, byU16)

                /* Test next position(L1253-1303,byU32/byU16 分支) */
                let hNext = LZ4_hashPosition(src, ip, byU16)                  /* L1264 */
                let current2: UInt32 = UInt32(ip)                             /* L1265 */
                let matchIndex2: UInt32 = lz4GetIndexOnHash(state.hashTable, hNext, byU16)  /* L1266 */
                lz4PutIndexOnHash(state.hashTable, current2, hNext, byU16)    /* L1292 */
                matchPos = Int64(matchIndex2)                                  /* L1290: match = base + matchIndex */
                /* L1294-1296:dictSmall 关;byU16 距离检查恒真(表内索引本就 < 65536),
                   byU32 要求 matchIndex + 65535 >= current */
                if ((byU16 || (matchIndex2 + LZ4_DISTANCE_MAX >= current2)) &&
                        (LZ4_readLE32(src, matchPos) == LZ4_readLE32(src, ip))) {
                    tokenIdx = op                                              /* L1297: token = op++ */
                    op += 1
                    LZ4_write8(dst, tokenIdx, 0u8)                             /* L1298: *token = 0 */
                    continue                                                   /* L1302: goto _next_match */
                }

                /* Prepare next loop(L1307) */
                ip += 1
                forwardH = LZ4_hashPosition(src, ip, byU16)
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
    LZ4_memcpyPtr(dst, op, src, anchor, lastRun)             /* L1335 */
    ip = anchor + lastRun                                   /* L1336(上游无条件) */
    op += lastRun
    return (op, ip)                                         /* L1340-1343(consumed 即 ip) */
}

/* LZ4_compress_generic 包装(lz4.c L1353-1388):srcSize 校验与空输入特判。
   返回 (压缩字节数, srcConsumed)(consumed 仅 fillOutput 有意义,L1376-1379)。
   指针上下文由公开 API 的单一 unsafe 块提供(指针三律)。 */
internal func lz4CompressDispatch(state: LZ4_stream_t, src: CPointer<UInt8>, srcSize: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, outputDirective: Int32, acceleration: Int64): (Int64, Int64) {
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
    return LZ4_compress_generic_noDict(state, src, srcSize, dst,
        dstCapacity, byU16, outputDirective, acceleration)
}

/* extState 公共尾部(lz4.c L1391-1412):加速度钳制 + 表型/输出模式选择 +
   指针 acquire→压缩→release(单一 unsafe,无内部分配)。 */
private func lz4CompressExtStateBody(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32 {
    var accel: Int32 = acceleration
    if (accel < 1) {
        accel = LZ4_ACCELERATION_DEFAULT                        /* L1395 */
    }
    if (accel > LZ4_ACCELERATION_MAX) {
        accel = LZ4_ACCELERATION_MAX                            /* L1396 */
    }
    let byU16: Bool = Int64(srcSize) < LZ4_64Klimit             /* L1398(64 位:否则 byU32) */
    let notLimited: Bool = dstCapacity >= LZ4_compressBound(srcSize)   /* L1397 */
    let outputDirective: Int32 = if (notLimited) {
        LZ4_OUTPUT_NOT_LIMITED
    } else {
        LZ4_OUTPUT_LIMITED
    }
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        let (r, _) = lz4CompressDispatch(state, sh.pointer, Int64(srcSize), dh.pointer,
            Int64(dstCapacity), byU16, outputDirective, Int64(accel))
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
    return lz4CompressExtStateBody(state, src, srcSize, dst, dstCapacity, acceleration)
}

/* 上游(L1423-1459)不调用 initStream,由 LZ4_prepareTable 依据 tableType/
   currentOffset 决定是否清表并处理 64KB gap。M2 仅 one-shot(新构造或已 init 的
   state):clearedTable → 不清表、   currentOffset==0 → noDictIssue,与 extState 路径
   完全一致;脏表复用的正确性属 M3 范畴,届时移植 prepareTable。 */
public func LZ4_compress_fast_extState_fastReset(state: LZ4_stream_t, src: Array<UInt8>,
        srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32 {
    return LZ4_compress_fast_extState(state, src, srcSize, dst, dstCapacity, acceleration)
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
   注:上游警告 destSize 会留下脏流状态(L1487-1489),此处每次新建/初始化
   one-shot 状态,无复用问题;destSize_extState 公开包装属 M4+ 流式范畴。 */
private func lz4CompressDestSizeInternal(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32,
        dst: Array<UInt8>, targetDstSize: Int32): (Int32, Int32) {
    LZ4_initStream(state)                                       /* L1492 */
    if (targetDstSize >= LZ4_compressBound(srcSize)) {          /* L1495 */
        let c = lz4CompressExtStateBody(state, src, srcSize, dst, targetDstSize, 1)
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
            Int64(targetDstSize), byU16, LZ4_OUTPUT_FILL, 1)    /* L1499-1502,acceleration=1(L1525) */
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
    return lz4CompressDestSizeInternal(ctx, src, srcSize, dst, targetDstSize)
}

/*-************************************
*  Decompression constants (lz4.c L243-249, L475-476)
**************************************/
internal const LZ4_WILDCOPYLENGTH: Int64 = 8                        /* lz4.c L245 */
/* lz4.c L248:2×WILDCOPYLENGTH-MINMATCH = 12,保证可写两组野复制而不越输出界 */
internal const LZ4_MATCH_SAFEGUARD_DISTANCE: Int64 = 2 * LZ4_WILDCOPYLENGTH - LZ4_MINMATCH
internal const LZ4_FASTLOOP_SAFE_DISTANCE: Int64 = 64               /* lz4.c L249(T3 fast 循环分派用) */

/* lz4.c L475-476:offset<8 时交叠 match 拷贝的增量表(safe 循环 L2425-2437 用) */
internal let LZ4_INC32TABLE: Array<Int64> = [0, 1, 2, 1, 0, 4, 4, 4]
internal let LZ4_DEC64TABLE: Array<Int64> = [0, 0, 0, -1, -4, 1, 2, 3]

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

/* LZ4_decompress_generic 的指针循环体(safe decode loop,L2226-2454)。
   (buf, idx) 位置模型:src/dst 以基指针 + Int64 索引表达;lowPrefixIdx 为
   dst 同缓冲内前缀起点(withPrefix64k 时 < dstIdx);dictIsExtDict 时
   dictP/dictStartIdx/dictSize 表达外字典(dictEnd = dictStartIdx + dictSize)。
   dict_directive 的位置编码:noDict = 低前缀与输出重合且无外字典;
   withPrefix64k = 无外字典但 lowPrefixIdx < dstIdx;usingExtDict = dictIsExtDict。
   _output_error 以 `return -(ip) - 1` 直接实现(L2462);成功返回输出字节数。
   T3 将在 L2074-2222 分派点插入 fast 解码循环(outputSize ≥
   FASTLOOP_SAFE_DISTANCE 时走 fast 路径),本函数即其 safe_decode 落点。 */
private func lz4DecompressGenericBody(
        src: CPointer<UInt8>, srcSize: Int64,
        dst: CPointer<UInt8>, dstIdx: Int64, outputSize: Int64,
        partialDecoding: Bool,
        lowPrefixIdx: Int64,
        dictP: CPointer<UInt8>, dictIsExtDict: Bool, dictStartIdx: Int64, dictSize: Int64): Int64 {
    let iend: Int64 = srcSize                                    /* L2038 */
    var op: Int64 = dstIdx                                       /* L2040 */
    let oend: Int64 = dstIdx + outputSize                        /* L2041 */
    let dictEnd: Int64 = dictStartIdx + dictSize                 /* L2044(dictIsExtDict 时有效) */
    let checkOffset: Bool = dictSize < 65536                     /* L2046 */
    let shortiend: Int64 = iend - 14 - 2                         /* L2050:maxLL+offset */
    let shortoend: Int64 = oend - 14 - 18                        /* L2051:maxLL+maxML */
    /* withPrefix64k:捷径分支 L2155/L2259 的字典指令豁免(位置模型编码) */
    let withPrefix64k: Bool = (!dictIsExtDict) && (lowPrefixIdx < dstIdx)

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

    /* T3 分派点(L2075):(oend - op) < FASTLOOP_SAFE_DISTANCE 时直接
       进入 safe 循环;fast 循环(L2079-2221)整体留待 T3 插入。 */
    var ip: Int64 = 0
    /* Main Loop:safe decode loop(L2226-2454) */
    while (true) {
        let token: UInt8 = LZ4_read8(src, ip)                     /* L2228 */
        ip += 1
        var length: Int64 = Int64(token >> 4)                     /* L2229: literal length */
        var offset: Int64 = 0
        var matchIdx: Int64 = 0
        var fromShortcut = false

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
                continue                                          /* L2266 */
            }
            fromShortcut = true                                   /* L2271: goto _copy_match */
        }

        if (!fromShortcut) {
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

            /* copy literals(L2289-2352) */
            var cpy: Int64 = op + length                          /* L2290 */
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
        }

        /* _copy_match(L2362) */
        if (length == LZ4_ML_MASK) {
            /* match 扩展字节后至少还需 1 token + LASTLITERALS 字面量(L2364) */
            let (addl, nip) = lz4ReadVariableLength(src, ip, iend - (1 + LZ4_LASTLITERALS))   /* L2365 */
            if (addl == -1) {
                return -nip - 1                                   /* _output_error */
            }
            ip = nip
            length += addl
            if (op + length < op) { return -ip - 1 }              /* L2368 溢出检测(64 位下不可达) */
        }
        length += LZ4_MINMATCH                                   /* L2370 */

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
            continue                                             /* L2402 */
        }

        /* copy match within block(L2406) */
        let cpy: Int64 = op + length

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
    }

    /* end of decoding(L2457-2458) */
    return op - dstIdx
}

/* LZ4_decompress_generic(lz4.c L2022-2464):解压核心,(buf, idx) 位置模型
   参数化(T2 的 partial/前缀、T4 的外字典直接复用);src+dst(+字典)在
   单一 unsafe 块内 acquire/release(指针三律)。无字典时 dictP 传 src 指针
   占位,dictIsExtDict=false 保证其绝不解引用。 */
internal func LZ4_decompress_generic(
        srcArr: Array<UInt8>, srcSize: Int64,
        dstArr: Array<UInt8>, dstIdx: Int64, outputSize: Int64,
        partialDecoding: Bool,
        lowPrefixIdx: Int64,
        dictArr: Option<Array<UInt8>>, dictStartIdx: Int64, dictSize: Int64): Int64 {
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
                    dictStartIdx, dictSize)
                releaseArrayRawData<UInt8>(kh)
                v
            case None =>
                lz4DecompressGenericBody(sh.pointer, srcSize, dh.pointer, dstIdx,
                    outputSize, partialDecoding, lowPrefixIdx, sh.pointer, false,
                    dictStartIdx, dictSize)
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
