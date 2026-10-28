package arr_probe

/* cjc windows-x64 数组越界检查异常探针(2026-10-07;原 scripts/arr_probe.cj,
   2026-10-28 搬入 examples/ 并函数化 —— 被探测的存储序列逐字保留,只拆分外围)。
   背景:fuzz 测试在 windows-x64 上对长度 8+sz(sz 数千)的 Array<UInt8> 做连续
   常量下标写时,`sf[7]` 偶发抛 IndexOutOfBoundsException,而 7 < sf.size 恒成立
   (见 fuzz_test.cj skippable 段与 report/windows_test_findings.md)。
   行为:a) 单尺寸演示 —— 原 failing case(sz=4216,长度 4224)的四个存储点;
   b) 尺寸扫描 —— 0..5000 逐尺寸构造 + 仅写 [7],统计伪越界窗口(最多报 5 个)。
   结果(2026-10-07 双工具链实证):LTS/STS 均未单独复现 —— 伪越界依赖整包
   代码布局,非单文件形状;保留作行为窗口测绘与后续对照。 */

/* 单尺寸检查:构造 8+sz 数组并执行被探测的存储序列(序列与原始失败点逐字一致,
   勿改动 —— 这段代码的形状就是探针的载荷) */
func writeCheck(sz: Int64): Unit {
    let sf = Array<UInt8>(8 + sz, { _ => 0u8 })
    println("constructed size=${sf.size}")
    sf[7] = UInt8((sz >> 24) & 0xFF)           // <-- 此处曾在 win-1.0.5 抛伪越界
    println("write [7] ok")
    sf[0] = 0x50u8
    sf[4] = UInt8(sz & 0xFF)
    sf[sf.size - 1] = 0x2Au8
    println("write [0],[4],[size-1] ok")
}

/* 尺寸扫描:逐尺寸构造 + 仅写 [7],捕获伪越界异常;返回命中的尺寸数(封顶 5) */
func sweepSizes(limit: Int64): Int64 {
    var bad: Int64 = 0
    for (s in 0..limit) {
        let a = Array<UInt8>(8 + Int64(s), { _ => 0u8 })
        try {
            a[7] = 1u8
        } catch (e: Exception) {
            println("OOB at size=${a.size} index=7: ${e}")
            bad += 1
            if (bad >= 5) { break }
        }
    }
    return bad
}

main(): Int64 {
    writeCheck(4216)                            // 原 failing case:长度 4224
    let bad = sweepSizes(5001)
    println(if (bad == 0) { "sweep clean" } else { "sweep found ${bad}+ bad sizes" })
    return 0
}
