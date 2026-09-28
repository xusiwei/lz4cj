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
   字典字段(dictCtx/dictionary/dictSize)留待 M5 补齐。 */
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

/*-************************************
*  Compression core (lz4.c L939-1347, noDict paths)
**************************************/
/* LZ4_compress_generic_validated 的 noDict 移植:byU16/byU32 × limitedOutput/
   notLimited。C 的 const 参数宏展开改用两个 Bool 显式分支,语义逐行对照。
   全部位置为相对 src 基指针的 Int64 索引;one-shot 新态 startIndex=0、base=source
   (L955-956),索引即 0 基偏移(controller ruling #3);hashTable 存 0 基索引。
   goto _last_literals / _next_match 用标志位 + 标签循环重排,控制流等价。 */
internal func LZ4_compress_generic_noDict(
        state: LZ4_stream_t, src: CPointer<UInt8>, n: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, limitedOutput: Bool, acceleration: Int64): Int64 {
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

    /* L999-1009: 更新上下文(dictSize 字段 M5 补;tableType 枚举值沿上游
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
            if (limitedOutput &&                       /* L1123-1126: 溢出检查 */
                    (op + litLength + (2 + 1 + LZ4_LASTLITERALS) + litLength / 255 > olimit)) {
                return 0
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
                /* Encode Offset(L1163-1172;maybe_extMem == false → 同段偏移) */
                LZ4_writeLE16(dst, op, UInt16(ip - matchPos))                    /* L1171 */
                op += 2

                /* Encode MatchLength(L1174-1235) */
                var matchCode: Int64 = LZ4_count(src, ip + LZ4_MINMATCH,
                    matchPos + LZ4_MINMATCH, matchlimit)                         /* L1191 */
                ip += matchCode + LZ4_MINMATCH                                /* L1192 */
                if (limitedOutput &&                                          /* L1196-1197 + L1219 */
                        (op + (1 + LZ4_LASTLITERALS) + (matchCode + 240) / 255 > olimit)) {
                    return 0
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
            if (!runMain) {
                break
            }
        }
    }

    /* _last_literals(L1311-1338) */
    let lastRun: Int64 = iend - anchor                   /* L1313 */
    if (limitedOutput &&                                 /* L1314-1315 + L1323 */
            (op + lastRun + 1 + (lastRun + 255 - LZ4_RUN_MASK) / 255 > olimit)) {
        return 0
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
    op += lastRun
    return op                                                /* L1343 */
}

/* LZ4_compress_generic 包装(lz4.c L1353-1388):srcSize 校验与空输入特判。
   指针上下文由公开 API 的单一 unsafe 块提供(指针三律)。 */
internal func lz4CompressDispatch(state: LZ4_stream_t, src: CPointer<UInt8>, srcSize: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, limitedOutput: Bool, acceleration: Int64): Int64 {
    if (srcSize < 0 || srcSize > Int64(LZ4_MAX_INPUT_SIZE)) {   /* L1369(无符号比较语义) */
        return 0
    }
    if (srcSize == 0) {                                          /* L1370-1381 */
        if (limitedOutput && dstCapacity <= 0) {
            return 0
        }
        LZ4_write8(dst, 0, 0u8)                                  /* L1375: 空块 = 单字节 0x00 */
        return 1
    }
    return LZ4_compress_generic_noDict(state, src, srcSize, dst,
        dstCapacity, byU16, limitedOutput, acceleration)
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
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        let r = lz4CompressDispatch(state, sh.pointer, Int64(srcSize), dh.pointer,
            Int64(dstCapacity), byU16, !notLimited, Int64(accel))
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
   state):clearedTable → 不清表、currentOffset==0 → noDictIssue,与 extState 路径
   完全一致;脏表复用的正确性属流式范畴(M4+),届时移植 prepareTable。 */
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
