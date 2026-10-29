package block_streaming_double_buffer

/* 流式双缓冲示例(概念源自上游 examples/blockStreaming_doubleBuffer.c;上游
   examples 整体为 GPL-2,本文件为独立仓颉实现):
   压缩侧用 LZ4_compress_fast_continue 逐块续压 —— 两个源缓冲交替使用,
   正在被压缩的块与作为历史窗口(64KB 字典)的上一块同时存活;
   解压侧用 LZ4_streamDecode_t + LZ4_decompress_safe_continue 同样双缓冲续解。
   演示要点:跨块匹配(字典红利)依赖"上一块缓冲在续压期间不可复用/移动"。 */

import lz4.*

let BLOCK: Int32 = 8 * 1024      /* 每块 8KB,4 块 */
let NBLOCKS: Int64 = 4

/* 跨块强重复的合成流:周期 4KB 的模式,块间存在大量可回溯匹配 */
func makeBlock(blockIdx: Int64): Array<UInt8> {
    Array<UInt8>(Int64(BLOCK), { i => UInt8(((i + blockIdx * 64) % 4096) / 16) })
}

main(): Int64 {
    let bound = LZ4_compressBound(BLOCK)
    let state = LZ4_createStream()
    let bufA = Array<UInt8>(Int64(BLOCK), {_ => 0u8})      /* 双缓冲:交替使用 */
    let bufB = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
    let outs = Array<Array<UInt8>>(NBLOCKS, { _ => Array<UInt8>(Int64(bound), {_ => 0u8}) })
    let sizes = Array<Int32>(NBLOCKS, {_ => 0})

    /* ---- 压缩:交替填充 bufA / bufB,续压时上一块作为字典仍在 ---- */
    for (k in 0..NBLOCKS) {
        let cur = if (k % 2 == 0) { bufA } else { bufB }
        let blk = makeBlock(k)
        for (i in 0..Int64(BLOCK)) { cur[i] = blk[i] }
        sizes[k] = LZ4_compress_fast_continue(state, cur, 0, BLOCK, outs[k], bound, 1)
        if (sizes[k] <= 0) { println("block ${k} compress FAILED"); return 1 }
    }
    LZ4_freeStream(state)
    var total: Int64 = 0
    for (k in 0..NBLOCKS) { total += Int64(sizes[k]) }
    println("compressed ${Int64(BLOCK) * NBLOCKS} bytes -> ${total} bytes (cross-block matches via 64KB window)")

    /* ---- 解压:同构双缓冲 + streamDecode 续解 ---- */
    let sd = LZ4_createStreamDecode()
    let backA = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
    let backB = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
    for (k in 0..NBLOCKS) {
        let out = if (k % 2 == 0) { backA } else { backB }
        let d = LZ4_decompress_safe_continue(sd, outs[k], sizes[k], out, 0, BLOCK)
        if (d != BLOCK) { println("block ${k} decompress FAILED (${d})"); return 1 }
        let want = makeBlock(k)
        for (i in 0..Int64(BLOCK)) {
            if (out[i] != want[i]) { println("block ${k} MISMATCH at ${i}"); return 1 }
        }
    }
    LZ4_freeStreamDecode(sd)
    println("double-buffer roundtrip OK: ${NBLOCKS} blocks verified byte-for-byte")
    return 0
}
