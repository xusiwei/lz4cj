package downstream_smoke

/* 下游消费示例 / M8 下游依赖验收冒烟(设计 §10 验收标准;2026-10-08 搬入 examples/):
   以本地 path 依赖消费 lz4 制品,跑四路压缩-解压逐字节往返 + 尺寸钉值断言。
   钉值为 2026-10-03 双工具链实证(LTS/STS 同值):块 default / HC lv9 均 c=517,
   frame 一次性 / lz4file 均 532(默认 prefs + 64KB 对齐单块输入,与 frame 一次性
   同几何,BD/块界完全一致)。脚本 scripts/verify_downstream.sh 以本文件为准做
   下游验收:把 src/main.cj 拷入临时下游工程运行,断言输出行
   "DOWNSTREAM_SMOKE_OK c=517 hc=517 fc=532 lf=532"。 */

import std.fs.*
import lz4.*

/* 钉值常量(改输入生成器或压缩配置会破坏这些值,需双工具链重证) */
let PIN_BLOCK_HC: Int32 = 517     /* block default 与 HC lv9 同值 */
let PIN_FRAME_FILE: Int64 = 532   /* frame 一次性与 lz4file 同值 */

/* 确定性合成输入:非平凡字节数 ramp mod 251,双工具链稳定 */
func makeInput(n: Int64): Array<UInt8> {
    Array<UInt8>(n, { i => UInt8((i * 31 + 7) % 251) })
}

/* 逐字节比对,相等返回 true */
func sameBytes(a: Array<UInt8>, b: Array<UInt8>): Bool {
    if (a.size != b.size) { return false }
    for (i in 0..a.size) {
        if (a[i] != b[i]) { return false }
    }
    return true
}

/* 块压缩路:LZ4_compress_default → decompress_safe → 逐字节比对 → 钉值。
   返回压缩字节数,任一步失败打印原因并返回 -1。 */
func blockRoute(src: Array<UInt8>): Int32 {
    let n = Int32(src.size)
    let bound = LZ4_compressBound(n)
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
    let c = LZ4_compress_default(src, n, dst, bound)
    if (c <= 0) { println("block compress FAILED"); return -1 }
    let back = Array<UInt8>(Int64(n), { _ => 0u8 })
    if (LZ4_decompress_safe(dst, c, back, n) != n) {
        println("block decompress FAILED"); return -1
    }
    if (!sameBytes(src, back)) { println("block roundtrip MISMATCH"); return -1 }
    if (c != PIN_BLOCK_HC) { println("block pin FAILED c=${c}"); return -1 }
    return c
}

/* HC 高压缩路(lv9):与块路同形,复用 sameBytes 比对(M9 起补充逐字节校验)。 */
func hcRoute(src: Array<UInt8>): Int32 {
    let n = Int32(src.size)
    let bound = LZ4_compressBound(n)
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
    let hc = LZ4_compress_HC(src, n, dst, bound, 9)
    if (hc <= 0) { println("HC compress FAILED"); return -1 }
    let back = Array<UInt8>(Int64(n), { _ => 0u8 })
    if (LZ4_decompress_safe(dst, hc, back, n) != n) {
        println("HC decompress FAILED"); return -1
    }
    if (!sameBytes(src, back)) { println("HC roundtrip MISMATCH"); return -1 }
    if (hc != PIN_BLOCK_HC) { println("HC pin FAILED hc=${hc}"); return -1 }
    return hc
}

/* Frame 一次性路:LZ4F_compressFrame(默认 prefs)→ 流式 decompress → 钉值。 */
func frameRoute(src: Array<UInt8>): Int64 {
    let n = src.size
    let fbound = LZ4F_compressFrameBound(n, None<LZ4F_preferences_t>)
    let fdst = Array<UInt8>(fbound, { _ => 0u8 })
    let fc = LZ4F_compressFrame(fdst, 0, fbound, src, n, None<LZ4F_preferences_t>)
    if (LZ4F_isError(fc)) { println("frame compress FAILED: ${LZ4F_getErrorName(fc)}"); return -1 }
    let fback = Array<UInt8>(n, { _ => 0u8 })
    let dctx = LZ4F_createDecompressionContext(100)
    let (ret, _, written) = LZ4F_decompress(dctx, fback, 0, n, fdst, 0, fc, None<LZ4F_decompressOptions_t>)
    if (ret != 0 || written != n) { println("frame decompress FAILED ret=${ret} written=${written}"); return -1 }
    if (!sameBytes(src, fback)) { println("frame roundtrip MISMATCH"); return -1 }
    if (fc != PIN_FRAME_FILE) { println("frame pin FAILED fc=${fc}"); return -1 }
    return fc
}

/* lz4file 文件路(M9):调用方持有 File 生命周期(read/write/close 不关文件);
   写侧 writeOpen/write(size:)/writeClose,读侧以 4096 缓冲整读校验文件尺寸
   = 帧长,再 readOpen/read(size:)/readClose 往返。 */
func lz4fileRoute(src: Array<UInt8>): Int64 {
    let n = src.size
    let path = "lz4file_smoke.bin"
    let wfh = File(path, OpenMode.Write)
    let (wcode, wh) = LZ4F_writeOpen(wfh, None<LZ4F_preferences_t>)
    if (LZ4F_isError(wcode)) { println("lz4file writeOpen FAILED: ${LZ4F_getErrorName(wcode)}"); return -1 }
    let whh = wh.getOrThrow()
    if (LZ4F_write(whh, src, size: n) != n) { println("lz4file write FAILED"); return -1 }
    if (LZ4F_isError(LZ4F_writeClose(whh))) { println("lz4file writeClose FAILED"); return -1 }
    wfh.close()
    let raw = Array<UInt8>(4096, { _ => 0u8 })
    let sfh = File(path, OpenMode.Read)
    let lf = sfh.read(raw)
    sfh.close()
    if (lf != PIN_FRAME_FILE) { println("lz4file pin FAILED lf=${lf}"); return -1 }
    let rfh = File(path, OpenMode.Read)
    let (rcode, rh) = LZ4F_readOpen(rfh)
    if (LZ4F_isError(rcode)) { println("lz4file readOpen FAILED: ${LZ4F_getErrorName(rcode)}"); return -1 }
    let rhh = rh.getOrThrow()
    let lback = Array<UInt8>(n, { _ => 0u8 })
    if (LZ4F_read(rhh, lback, size: n) != n) { println("lz4file read FAILED"); return -1 }
    if (LZ4F_readClose(rhh) != LZ4F_OK_NoError) { println("lz4file readClose FAILED"); return -1 }
    rfh.close()
    if (!sameBytes(src, lback)) { println("lz4file roundtrip MISMATCH"); return -1 }
    removeIfExists(path)
    return lf
}

/* 四路串联:任一路失败即非零退出;全过打印钉值验收行(scripts/verify_downstream.sh
   断言的精确输出)。 */
main(): Int64 {
    let src = makeInput(65536)
    let c = blockRoute(src)
    if (c < 0) { return 1 }
    let hc = hcRoute(src)
    if (hc < 0) { return 1 }
    let fc = frameRoute(src)
    if (fc < 0) { return 1 }
    let lf = lz4fileRoute(src)
    if (lf < 0) { return 1 }
    println("DOWNSTREAM_SMOKE_OK c=${c} hc=${hc} fc=${fc} lf=${lf}")
    return 0
}
