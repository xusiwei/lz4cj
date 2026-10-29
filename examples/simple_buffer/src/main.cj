package simple_buffer

/* 块压缩入门示例(概念源自上游 examples/simple_buffer.c,BSD-2;本文件为
   独立仓颉实现):内存中完成一次 压缩 -> 解压 -> 逐字节比对 的完整往返,
   演示最常用的两个函数 LZ4_compress_default 与 LZ4_decompress_safe。
   与 C 版的差异由承载决定:显式压缩边界 LZ4_compressBound、无 malloc/GC、
   解压目标容量即原始长度。 */

import lz4.*

/* 确定性合成输入:带重复模式的文本,保证可压缩(示例用真实文本更直观) */
func makeInput(): Array<UInt8> {
    let text = "你好,lz4cj!Hello hello hello hello, LZ4 LZ4 LZ4. " +
        "This sentence contains enough repetition for the compressor to find matches. "
    let n = text.size
    let buf = Array<UInt8>(n, { i => UInt8(text[i]) })
    return buf
}

main(): Int64 {
    // 1) 压缩:先取压缩上界,分配输出缓冲
    let src = makeInput()
    let n = Int32(src.size)
    let bound = LZ4_compressBound(n)
    if (bound <= 0) { println("compressBound FAILED"); return 1 }
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })

    let c = LZ4_compress_default(src, n, dst, bound)
    if (c <= 0) { println("compression FAILED (is input too large for one block?)"); return 1 }
    println("compressed ${n} bytes into ${c} bytes")

    // 2) 解压:目标容量必须不小于原始长度
    let back = Array<UInt8>(Int64(n), { _ => 0u8 })
    let d = LZ4_decompress_safe(dst, c, back, n)
    if (d != n) { println("decompression FAILED (got ${d})"); return 1 }

    // 3) 校验:逐字节一致
    for (i in 0..Int64(n)) {
        if (src[i] != back[i]) { println("roundtrip MISMATCH at ${i}"); return 1 }
    }
    println("roundtrip OK: ${n} bytes verified byte-for-byte")
    return 0
}
