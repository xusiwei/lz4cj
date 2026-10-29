package frame_compress

/* Frame 流式文件压缩示例(概念源自上游 examples/frameCompress.c;上游
   examples 整体为 GPL-2,本文件为独立仓颉实现):
   文件 -> 文件的有界内存流式压缩与解压 ——
   压缩侧:LZ4F_compressBegin 预写帧头,然后按 64KB 分块
   LZ4F_compressUpdate 累积写出,末尾 LZ4F_compressEnd 收帧;
   解压侧:提示驱动循环 —— LZ4F_decompress 返回 (hint, consumed, written),
   written=本次产出、consumed=本次吃掉的输入、hint=收帧前还需要的输入字节数
   (0 = 帧完整)。两个循环是 frame 流式 API 的核心使用形态。
   与上游的刻意差异:不用 argv,程序内生成确定性输入文件(约 1MB)。 */

import std.fs.*
import lz4.*

let CHUNK: Int64 = 64 * 1024
let IN_PATH = "frame_example.in"
let LZ_PATH = "frame_example.lz4"
let OUT_PATH = "frame_example.out"

/* 确定性测试输入:重复文本(可压)与变化段(不可压)交替,约 1MB */
func makeBytes(): Array<UInt8> {
    let text = "frame example payload line 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ. "
    let period = text.size
    let n: Int64 = 1024 * 1024
    return Array<UInt8>(n, { i =>
        if (i % 65536 < period) { UInt8(text[i % 65536]) }        /* 可压段 */
        else { UInt8((i * 31 + 7) % 251) }                        /* 随机段 */
    })
}

/* 稳妥写:全量写出 buf[0..len) */
func writeAll(f: File, buf: Array<UInt8>, len: Int64): Bool {
    f.write(buf[0..len])
    return true
}

/* 流式压缩:inFile -> outFile,分块读入 + Begin/Update/End 累积写出。
   返回 (输入字节数, 压缩输出字节数)。 */
func compressFile(inFile: File, outFile: File): (Int64, Int64) {
    var prefs = LZ4F_preferences_t()             /* 值类型:需 var 才能改成员 */
    prefs.frameInfo.blockSizeID = 4              /* 64KB 块 */
    prefs.frameInfo.contentChecksumFlag = 1      /* 帧尾内容校验和 */
    let bound = LZ4F_compressFrameBound(CHUNK, Some(prefs))
    let dst = Array<UInt8>(bound, {_ => 0u8})
    let src = Array<UInt8>(CHUNK, {_ => 0u8})
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var totalIn: Int64 = 0
    var totalOut: Int64 = 0

    /* 帧头 */
    var w = LZ4F_compressBegin(cctx, dst, 0, bound, Some(prefs))
    if (LZ4F_isError(w)) { println("compressBegin FAILED: ${LZ4F_getErrorName(w)}"); return (-1, -1) }
    writeAll(outFile, dst, w)
    totalOut += w

    /* 分块 Update */
    while (true) {
        let got = inFile.read(src)
        if (got <= 0) { break }
        totalIn += got
        w = LZ4F_compressUpdate(cctx, dst, 0, bound, src, 0, got, None<LZ4F_compressOptions_t>)
        if (LZ4F_isError(w)) { println("compressUpdate FAILED: ${LZ4F_getErrorName(w)}"); return (-1, -1) }
        writeAll(outFile, dst, w)
        totalOut += w
    }

    /* 收帧(endMark + 内容校验和) */
    w = LZ4F_compressEnd(cctx, dst, 0, bound, None<LZ4F_compressOptions_t>)
    if (LZ4F_isError(w)) { println("compressEnd FAILED: ${LZ4F_getErrorName(w)}"); return (-1, -1) }
    writeAll(outFile, dst, w)
    totalOut += w
    return (totalIn, totalOut)
}

/* 流式解压:提示驱动循环 —— 每次用当前缓冲里未消费的输入调
   LZ4F_decompress,按 consumed 推进游标、按 written 产出,hint==0 收帧。
   游标(have/fill)必须活过整个循环:一次读入可能要分多次解压调用才消耗完,
   每次调用只处理剩余部分。 */
func decompressFile(lzFile: File, outFile: File): Int64 {
    let dstCap: Int64 = 4 * CHUNK                 /* 单次产出上限 */
    let dst = Array<UInt8>(dstCap, {_ => 0u8})
    let src = Array<UInt8>(CHUNK, {_ => 0u8})
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    var totalOut: Int64 = 0
    var hint: Int64 = 1
    var have: Int64 = 0                           /* src[have..fill) 未消费 */
    var fill: Int64 = 0
    var eof = false

    while (hint != 0) {
        while (have == fill && !eof) {            /* 输入吃尽则续读 */
            fill = lzFile.read(src)
            have = 0
            if (fill <= 0) { eof = true }
        }
        if (have == fill) {                       /* eof 且仍有 hint:帧不完整 */
            println("input exhausted before end of frame"); return -1
        }
        let (h, consumed, written) = LZ4F_decompress(dctx, dst, 0, dstCap,
            src, have, fill - have, None<LZ4F_decompressOptions_t>)
        if (h < 0) { println("decompress FAILED: ${LZ4F_getErrorName(h)}"); return -1 }
        writeAll(outFile, dst, written)
        totalOut += written
        have += consumed
        hint = h
    }
    return totalOut
}

/* 逐字节比对两个文件 */
func filesEqual(a: File, b: File): Bool {
    let ba = Array<UInt8>(CHUNK, {_ => 0u8})
    let bb = Array<UInt8>(CHUNK, {_ => 0u8})
    while (true) {
        let na = a.read(ba)
        let nb = b.read(bb)
        if (na != nb) { return false }
        if (na <= 0) { return true }
        for (i in 0..na) {
            if (ba[i] != bb[i]) { return false }
        }
    }
    return false    /* 不可达:上面的循环只在 na<=0 时经 return true 退出 */
}

main(): Int64 {
    /* 生成输入文件 */
    let data = makeBytes()
    let fin = File(IN_PATH, OpenMode.Write)
    writeAll(fin, data, data.size)
    fin.close()

    /* 压缩 */
    let inf = File(IN_PATH, OpenMode.Read)
    let outf = File(LZ_PATH, OpenMode.Write)
    let (nIn, nC) = compressFile(inf, outf)
    inf.close()
    outf.close()
    if (nIn < 0) { return 1 }
    println("compressed ${nIn} bytes -> ${nC} bytes (frame streaming, 64KB chunks)")

    /* 解压 */
    let lzf = File(LZ_PATH, OpenMode.Read)
    let out2 = File(OUT_PATH, OpenMode.Write)
    let nOut = decompressFile(lzf, out2)
    lzf.close()
    out2.close()
    if (nOut < 0) { return 1 }
    println("decompressed ${nC} bytes -> ${nOut} bytes (hint-driven loop)")

    /* 比对 */
    let fa = File(IN_PATH, OpenMode.Read)
    let fb = File(OUT_PATH, OpenMode.Read)
    let same = filesEqual(fa, fb)
    fa.close()
    fb.close()
    if (!same) { println("roundtrip MISMATCH"); return 1 }
    println("frame roundtrip OK: input == output, byte-for-byte")

    /* 清理临时文件 */
    removeIfExists(IN_PATH)
    removeIfExists(LZ_PATH)
    removeIfExists(OUT_PATH)
    return 0
}
