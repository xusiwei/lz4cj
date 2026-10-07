package lz4_ds_smoke

/* M8 下游依赖验收冒烟(设计 §10 验收标准):本地 path 依赖消费 lz4 制品,
   块 default / HC lv9 / frame 一次性三路压缩-解压逐字节往返 + 钉值断言。
   钉值为 2026-10-03 双工具链实证(LTS/STS 同值):c=517 hc=517 fc=532。
   M9 追加 lz4file 第四路(writeOpen/write/writeClose → readOpen/read/
   readClose 文件往返 + 文件尺寸钉值 lf;默认 prefs + 64KB 对齐单块输入,
   与 frame 一次性同几何,BD/块界完全一致)。 */

import std.fs.*
import lz4.*

main() {
    let n: Int32 = 65536
    let src = Array<UInt8>(Int64(n), { i => UInt8((i * 31 + 7) % 251) })
    // block
    let bound = LZ4_compressBound(n)
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
    let c = LZ4_compress_default(src, n, dst, bound)
    if (c <= 0) { println("block compress FAILED"); return 1 }
    let back = Array<UInt8>(Int64(n), { _ => 0u8 })
    let d = LZ4_decompress_safe(dst, c, back, n)
    if (d != n) { println("block decompress FAILED"); return 1 }
    for (i in 0..Int64(n)) { if (src[i] != back[i]) { println("block roundtrip MISMATCH"); return 1 } }
    if (c != 517) { println("block pin FAILED c=${c}"); return 1 }
    // HC
    let chc = LZ4_compress_HC(src, n, dst, bound, 9)
    if (chc <= 0) { println("HC compress FAILED"); return 1 }
    let d2 = LZ4_decompress_safe(dst, chc, back, n)
    if (d2 != n) { println("HC decompress FAILED"); return 1 }
    if (chc != 517) { println("HC pin FAILED hc=${chc}"); return 1 }
    // frame one-shot
    let fn: Int64 = 65536
    let fbound = LZ4F_compressFrameBound(fn, None<LZ4F_preferences_t>)
    let fdst = Array<UInt8>(fbound, { _ => 0u8 })
    let fc = LZ4F_compressFrame(fdst, 0, fbound, src, fn, None<LZ4F_preferences_t>)
    if (LZ4F_isError(fc)) { println("frame compress FAILED: ${LZ4F_getErrorName(fc)}"); return 1 }
    let fback = Array<UInt8>(fn, { _ => 0u8 })
    let dctx = LZ4F_createDecompressionContext(100)
    let (ret, _, written) = LZ4F_decompress(dctx, fback, 0, fn, fdst, 0, fc, None<LZ4F_decompressOptions_t>)
    if (ret != 0 || written != fn) { println("frame decompress FAILED ret=${ret} written=${written}"); return 1 }
    for (i in 0..fn) { if (src[i] != fback[i]) { println("frame roundtrip MISMATCH"); return 1 } }
    if (fc != 532) { println("frame pin FAILED fc=${fc}"); return 1 }
    // lz4file (M9): caller-owned File lifecycle, named size: args
    let lfp = "lz4file_smoke.bin"
    let wfh = File(lfp, OpenMode.Write)
    let (wcode, wh) = LZ4F_writeOpen(wfh, None<LZ4F_preferences_t>)
    if (LZ4F_isError(wcode)) { println("lz4file writeOpen FAILED: ${LZ4F_getErrorName(wcode)}"); return 1 }
    let whh = wh.getOrThrow()
    if (LZ4F_write(whh, src, size: fn) != fn) { println("lz4file write FAILED"); return 1 }
    if (LZ4F_isError(LZ4F_writeClose(whh))) { println("lz4file writeClose FAILED"); return 1 }
    wfh.close()
    let raw = Array<UInt8>(4096, { _ => 0u8 })
    let sfh = File(lfp, OpenMode.Read)
    let lf = sfh.read(raw)
    sfh.close()
    if (lf != 532) { println("lz4file pin FAILED lf=${lf}"); return 1 }
    let rfh = File(lfp, OpenMode.Read)
    let (rcode, rh) = LZ4F_readOpen(rfh)
    if (LZ4F_isError(rcode)) { println("lz4file readOpen FAILED: ${LZ4F_getErrorName(rcode)}"); return 1 }
    let rhh = rh.getOrThrow()
    let lback = Array<UInt8>(fn, { _ => 0u8 })
    let r2 = LZ4F_read(rhh, lback, size: fn)
    if (r2 != fn) { println("lz4file read FAILED r=${r2}"); return 1 }
    if (LZ4F_readClose(rhh) != LZ4F_OK_NoError) { println("lz4file readClose FAILED"); return 1 }
    rfh.close()
    for (i in 0..fn) { if (src[i] != lback[i]) { println("lz4file roundtrip MISMATCH"); return 1 } }
    removeIfExists(lfp)
    println("DOWNSTREAM_SMOKE_OK c=${c} hc=${chc} fc=${fc} lf=${lf}")
    return 0
}
