package streaming_hc_ring_buffer

/* HC 流式环形缓冲示例(概念源自上游 examples/streamingHC_ringBuffer.c;上游
   examples 整体为 GPL-2,本文件为独立仓颉实现):
   与 block_streaming_ring_buffer 同构,压缩侧换用 LZ4_compress_HC_continue
   (高压缩策略,匹配搜索更远更深),回卷前用 LZ4_saveDictHC 显式保存历史。
   解压侧与普通块完全相同 —— HC 只改压缩侧,块格式与解码器不变。 */

import lz4.*

let BLOCK: Int32 = 8 * 1024
let RING_CAP: Int64 = Int64(BLOCK) * 2
let NBLOCKS: Int64 = 8
let DICT_KEEP: Int32 = 4 * 1024

func byteAt(globalIdx: Int64): UInt8 {
    UInt8(((globalIdx * 7 + (globalIdx / 2048) * 13) % 251))   /* 局部重复 + 缓变基线 */
}

main(): Int64 {
    let ring = Array<UInt8>(RING_CAP, {_ => 0u8})
    let safeDict = Array<UInt8>(64 * 1024, {_ => 0u8})
    let state = LZ4_createStreamHC()
    let bound = LZ4_compressBound(BLOCK)
    let outs = Array<Array<UInt8>>(NBLOCKS, {_ => Array<UInt8>(Int64(bound), {_ => 0u8})})
    let sizes = Array<Int32>(NBLOCKS, {_ => 0})

    for (k in 0..NBLOCKS) {
        let start: Int64 = (k % 2) * Int64(BLOCK)
        if (k >= 2 && k % 2 == 0) {
            if (LZ4_saveDictHC(state, safeDict, DICT_KEEP) <= 0) {
                println("saveDictHC FAILED at block ${k}"); return 1
            }
        }
        for (i in 0..Int64(BLOCK)) { ring[start + i] = byteAt(Int64(BLOCK) * k + i) }
        sizes[k] = LZ4_compress_HC_continue(state, ring, start, BLOCK, outs[k], bound)
        if (sizes[k] <= 0) { println("block ${k} HC compress FAILED"); return 1 }
    }
    LZ4_freeStreamHC(state)
    var total: Int64 = 0
    for (k in 0..NBLOCKS) { total += Int64(sizes[k]) }
    println("HC-compressed ${Int64(BLOCK) * NBLOCKS} bytes -> ${total} bytes (decoder is the plain block decoder)")

    /* 解压:滚动明文历史 + setStreamDecode,与普通块流式完全一致 */
    let sd = LZ4_createStreamDecode()
    let hist = Array<UInt8>(Int64(BLOCK) * NBLOCKS, {_ => 0u8})
    var histLen: Int64 = 0
    for (k in 0..NBLOCKS) {
        let out = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
        if (histLen > 0) { LZ4_setStreamDecode(sd, hist, Int32(histLen)) }
        let d = LZ4_decompress_safe_continue(sd, outs[k], sizes[k], out, 0, BLOCK)
        if (d != BLOCK) { println("block ${k} decompress FAILED (${d})"); return 1 }
        for (i in 0..Int64(BLOCK)) {
            if (out[i] != byteAt(Int64(BLOCK) * k + i)) { println("block ${k} MISMATCH at ${i}"); return 1 }
        }
        for (i in 0..Int64(BLOCK)) { hist[histLen + i] = out[i] }
        histLen += Int64(BLOCK)
    }
    LZ4_freeStreamDecode(sd)
    println("HC ring-buffer roundtrip OK: ${NBLOCKS} blocks verified byte-for-byte")
    return 0
}
