package oob_repro

/* cjc windows-x64 伪越界误编译的独立复现尝试(原 scripts/oob_repro.cj;
   2026-10-28 搬入 examples/,核心函数逐字保留 —— 代码形状即探针载荷,勿重构)。
   瞄准的 bug 形状(fuzzFrameDecodeTest 双工具链均命中,见
   report/windows_test_findings.md):从堆数组读出长度后,向 Array<UInt8>(8+sz)
   做连续常量下标存储 [0..6] 均正常,轮到 [7] 时抛
     IndexOutOfBoundsException: The length of the array is 3691, but the index is 7.
   而 sf.size == 3691 打印在侧,自相矛盾。
   已知结论:本独立程序在 LTS/STS 均不复现 —— 误编译依赖整包编译布局,
   单文件形状不足以触发;保留作误编译形状文档与将来工具链修复后的对照验证
   (修复后本程序与全量套件应均无伪越界)。compile-option 钉 -O2:误编译
   属优化器,-O0 不触发。 */

/* 被探测的形状:堆数组取长度(segSkipSize[0])→ 分配 8+sz → 连续常量下标写。
   与 fuzz 失败点的存储序列逐字一致,包括最后那个 [7]。 */
func fillSkippable(segSkipSize: Array<Int64>): Array<UInt8> {
    let sz = segSkipSize[0]
    let sf = Array<UInt8>(8 + sz, { _ => 0u8 })
    println("constructed sf.size=${sf.size}")
    sf[0] = 0x50u8
    sf[1] = 0x2Au8
    sf[2] = 0x4Du8
    sf[3] = 0x18u8
    sf[4] = UInt8(sz & 0xFF)
    sf[5] = UInt8((sz >> 8) & 0xFF)
    sf[6] = UInt8((sz >> 16) & 0xFF)
    sf[7] = UInt8((sz >> 24) & 0xFF)   // <-- windows-x64 -O2 下曾在此抛伪越界
    return sf
}

main(): Int64 {
    let segSkipSize = Array<Int64>(3, { _ => 3683 })   // 原 failing 尺寸:3691 = 8 + 3683
    let sf = fillSkippable(segSkipSize)
    println("store7 OK, sf.size=${sf.size}")
    return 0
}
