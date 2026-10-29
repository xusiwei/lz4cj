package block_streaming_ring_buffer

/* 流式环形缓冲示例(概念源自上游 examples/blockStreaming_ringBuffer.c;上游
   examples 整体为 GPL-2,本文件为独立仓颉实现):
   生产者把数据写进一个两块大小的环形缓冲,写到尾部回卷。回卷意味着
   "上一块"将马上被新数据覆盖 —— 破坏 64KB 历史窗口,因此在回卷前调用
   LZ4_saveDict 把最近历史(≤64KB)显式搬到安全区,状态改指安全区,
   环形缓冲即可安全复用。解压侧同构:LZ4_setStreamDecode 预置已还原的
   历史,再 LZ4_decompress_safe_continue 续解。 */

import lz4.*

let BLOCK: Int32 = 8 * 1024
let RING_CAP: Int64 = Int64(BLOCK) * 2      /* 环形缓冲 = 2 块 */
let NBLOCKS: Int64 = 8                      /* 总块数(含 3 次回卷) */
let DICT_KEEP: Int32 = 4 * 1024             /* 回卷时显式保存的历史量 */

/* 跨块强重复合成流(周期 4KB),确保历史窗口有实际收益 */
func byteAt(globalIdx: Int64): UInt8 {
    UInt8(((globalIdx % 4096) / 16))
}

main(): Int64 {
    let ring = Array<UInt8>(RING_CAP, {_ => 0u8})
    let safeDict = Array<UInt8>(65536, {_ => 0u8})   /* saveDict 目标安全区 */
    let state = LZ4_createStream()
    let bound = LZ4_compressBound(BLOCK)
    let outs = Array<Array<UInt8>>(NBLOCKS, {_ => Array<UInt8>(Int64(bound), {_ => 0u8})})
    let sizes = Array<Int32>(NBLOCKS, {_ => 0})

    /* ---- 压缩:环形写入,块起点轮换 0/BLOCK/0/BLOCK...;回卷前 saveDict ---- */
    for (k in 0..NBLOCKS) {
        let start: Int64 = (k % 2) * Int64(BLOCK)    /* 本块写入环形缓冲的起点 */
        if (k >= 2 && k % 2 == 0) {
            /* 即将覆写最老一块(它还在历史窗口里):先把 DICT_KEEP 字节
               搬到安全区,状态改指安全区 —— 此后环形缓冲任意复用 */
            let saved = LZ4_saveDict(state, safeDict, DICT_KEEP)
            if (saved <= 0) { println("saveDict FAILED at block ${k}"); return 1 }
        }
        for (i in 0..Int64(BLOCK)) { ring[start + i] = byteAt(Int64(BLOCK) * k + i) }
        sizes[k] = LZ4_compress_fast_continue(state, ring, start, BLOCK, outs[k], bound, 1)
        if (sizes[k] <= 0) { println("block ${k} compress FAILED"); return 1 }
    }
    LZ4_freeStream(state)
    var total: Int64 = 0
    for (k in 0..NBLOCKS) { total += Int64(sizes[k]) }
    println("compressed ${Int64(BLOCK) * NBLOCKS} bytes -> ${total} bytes across ${NBLOCKS} blocks, ring wrapped 3x with saveDict")

    /* ---- 解压:维护"至今全部明文"滚动历史,每块前 setStreamDecode 预置 ----
       压缩侧 saveDict 保存的是累积历史的尾部,后续块可能引用
       "安全区(更早块的尾部)+ 最近块"的组合;因此解压侧须提供不少于
       编码窗口的明文前缀(本演示总数据 64KB,恰为一个 LZ4 窗口,全量预置)。 */
    let sd = LZ4_createStreamDecode()
    let hist = Array<UInt8>(Int64(BLOCK) * NBLOCKS, {_ => 0u8})   /* 已还原明文(预分配+游标) */
    var histLen: Int64 = 0
    for (k in 0..NBLOCKS) {
        let out = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
        if (histLen > 0) {
            LZ4_setStreamDecode(sd, hist, Int32(histLen))
        }
        let d = LZ4_decompress_safe_continue(sd, outs[k], sizes[k], out, 0, BLOCK)
        if (d != BLOCK) { println("block ${k} decompress FAILED (${d})"); return 1 }
        for (i in 0..Int64(BLOCK)) {
            if (out[i] != byteAt(Int64(BLOCK) * k + i)) { println("block ${k} MISMATCH at ${i}"); return 1 }
        }
        for (i in 0..Int64(BLOCK)) { hist[histLen + i] = out[i] }
        histLen += Int64(BLOCK)
    }
    LZ4_freeStreamDecode(sd)
    println("ring-buffer roundtrip OK: ${NBLOCKS} blocks verified byte-for-byte")
    return 0
}
