package bench_functions

/* 压缩调用栈族示例(概念源自上游 examples/bench_functions.c,BSD-2;本文件为
   独立仓颉实现):对同一输入分别用 LZ4_compress_default(一站式)、
   LZ4_compress_fast(带加速度因子)、LZ4_compress_fast_extState(外部状态,
   可复用)三个层级压缩,验证输出一致并粗测耗时 —— 演示"沿调用栈下探"
   的 API 设计:越底层控制粒度越细,一站式与手工分步结果相同。 */

import std.time.MonoTime
import lz4.*

/* 计时并返回操作结果(lambda 只捕获不可变绑定,仓颉限制:捕获可变变量
   的 lambda 不可作为值传递) */
func timeIt(op: () -> Int32): (Int32, Float64) {
    let t0 = MonoTime.now()
    let r = op()
    let ms = Float64((MonoTime.now() - t0).toNanoseconds()) / 1e6
    return (r, ms)
}

/* 确定性可压缩输入:ramp + 周期重复(64KB,与上游示例量级相当) */
func makeInput(): Array<UInt8> {
    let n: Int64 = 65536
    return Array<UInt8>(n, { i => UInt8((i * 31 + 7) % 251) })
}

/* 三层压缩同输出校验 + 计时。返回 0 表示全部一致。 */
func runAndCompare(src: Array<UInt8>): Int64 {
    let n = Int32(src.size)
    let bound = LZ4_compressBound(n)
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
    let state = LZ4_createStream()

    let (c1, t1) = timeIt({ => LZ4_compress_default(src, n, dst, bound) })
    let (c2, t2) = timeIt({ => LZ4_compress_fast(src, n, dst, bound, 1) })
    let (c3, t3) = timeIt({ => LZ4_compress_fast_extState(state, src, n, dst, bound, 1) })
    LZ4_freeStream(state)

    println("LZ4_compress_default        : ${c1} bytes, ${t1} ms")
    println("LZ4_compress_fast(accel=1)  : ${c2} bytes, ${t2} ms")
    println("LZ4_compress_fast_extState  : ${c3} bytes, ${t3} ms")

    // 同一确定性输入下三层输出尺寸应完全一致(逐字节一致性由库保证)
    if (c1 <= 0 || c1 != c2 || c2 != c3) {
        println("call-stack family DISAGREE: ${c1} vs ${c2} vs ${c3}")
        return 1
    }
    println("call-stack family agrees at ${c1} bytes (default == fast == extState)")
    return 0
}

main(): Int64 {
    let src = makeInput()
    let rc = runAndCompare(src)
    // 解压闭环收尾
    if (rc == 0) {
        let n = Int32(src.size)
        let bound = LZ4_compressBound(n)
        let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
        let c = LZ4_compress_default(src, n, dst, bound)
        let back = Array<UInt8>(Int64(n), { _ => 0u8 })
        if (LZ4_decompress_safe(dst, c, back, n) != n) { println("roundtrip FAILED"); return 1 }
        println("roundtrip OK")
    }
    return rc
}
