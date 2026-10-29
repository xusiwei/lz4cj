package file_compress

/* lz4file 高层 API 示例(概念源自上游 examples/fileCompress.c;上游 examples
   整体为 GPL-2,本文件为独立仓颉实现):
   像操作普通文件一样操作 lz4 压缩文件 —— 写侧 LZ4F_writeOpen / LZ4F_write /
   LZ4F_writeClose,读侧 LZ4F_readOpen / LZ4F_read / LZ4F_readClose。帧头、
   块缓冲、帧尾全部由便捷层接管,调用方只按块读写。File 生命周期归调用方
   (write/read/close 均不关文件),收尾手动 fp.close()。
   与上游的刻意差异:不用 argv,输入由程序内确定性生成(重复文本 + 变化段
   混合,约 1MB);读回后逐字节比对,结束清理产物。写出的文件本身即标准
   LZ4 帧(lz4file 落盘的就是 LZ4F 帧格式,可被 lz4 CLI 等标准工具解开)。 */

import std.fs.*
import lz4.*

const CHUNK: Int64 = 64 * 1024          /* 外部读写块大小(帧内块由默认 prefs 决定) */
const INPUT_SIZE: Int64 = 1024 * 1024   /* 确定性输入总量(约 1MB) */
const LZ4_PATH: String = "file_example.lz4"

const TEXT: String = "lz4cj fileCompress example: the lz4file API manipulates compressed files like normal files. "

/* 确定性输入:每 32KB 交替一段重复文本(高重复、可压缩)与一段 xorshift32
   拟随机段(周期 2^32-1,无小周期、接近不可压),压缩率分布有代表性;
   无外部文件依赖,双工具链稳定。while 循环填充(rng 为可变状态,
   不进 lambda —— 捕获可变量的 lambda 不能作为值传参)。 */
func makeInput(n: Int64): Array<UInt8> {
    let text = TEXT.toArray()
    let seg: Int64 = 32 * 1024
    let out = Array<UInt8>(n, {_ => 0u8})
    var rng: UInt32 = 0x9E3779B9u32
    var i: Int64 = 0
    while (i < n) {
        if ((i / seg) % 2 == 0) {
            out[i] = text[i % Int64(text.size)]
        } else {
            rng = rng ^ (rng << 13u32)
            rng = rng ^ (rng >> 17u32)
            rng = rng ^ (rng << 5u32)
            out[i] = UInt8(rng >> 24u32 & 0xFF)
        }
        i += 1
    }
    return out
}

/* 文件尺寸:只读打开即取 File.length,立即关闭 */
func fileSize(path: String): Int64 {
    let fp = File(path, OpenMode.Read)
    let n = fp.length
    fp.close()
    return n
}

/* 加分验证:lz4file 写出的文件就是标准 LZ4 帧 —— 头 4 字节应为帧魔数
   LZ4F_MAGICNUMBER 0x184D2204(小端 04 22 4D 18),可被 lz4 CLI 等标准
   工具直接解开 */
func verifyFrameMagic(): Bool {
    let fp = File(LZ4_PATH, OpenMode.Read)
    let head = Array<UInt8>(4, {_ => 0u8})
    let got = fp.read(head)
    fp.close()
    return got == 4 && head[0] == 0x04u8 && head[1] == 0x22u8 && head[2] == 0x4Du8 && head[3] == 0x18u8
}

/* 分块写压缩文件:LZ4F_writeOpen(默认 prefs)→ 64KB 块 LZ4F_write →
   LZ4F_writeClose 落帧尾。返回写出的明文字节数,失败打印错误名、
   清理半成品并返回 -1。 */
func writeCompressed(src: Array<UInt8>): Int64 {
    removeIfExists(LZ4_PATH)
    let fp = File(LZ4_PATH, OpenMode.Write)
    let (wcode, wh) = LZ4F_writeOpen(fp, None<LZ4F_preferences_t>)
    if (LZ4F_isError(wcode)) {
        println("LZ4F_writeOpen error: ${LZ4F_getErrorName(wcode)}")
        fp.close()
        return -1
    }
    let wf = wh.getOrThrow()
    let chunk = Array<UInt8>(CHUNK, {_ => 0u8})
    var pos: Int64 = 0
    while (pos < src.size) {
        let len = if (src.size - pos > CHUNK) { CHUNK } else { src.size - pos }
        for (i in 0..len) { chunk[i] = src[pos + i] }
        let w = LZ4F_write(wf, chunk, size: len)
        if (LZ4F_isError(w)) {
            println("LZ4F_write error: ${LZ4F_getErrorName(w)}")
            fp.close()
            return -1
        }
        pos += len
    }
    let tail = LZ4F_writeClose(wf)
    if (LZ4F_isError(tail)) {
        println("LZ4F_writeClose error: ${LZ4F_getErrorName(tail)}")
        fp.close()
        return -1
    }
    fp.close()
    return pos
}

/* 分块读压缩文件:LZ4F_readOpen(解析帧头)→ 循环 LZ4F_read(返回实际
   读到的字节数,0 = 帧尾)→ 边读边与原输入逐字节比对 → LZ4F_readClose。
   内存有界:任意时刻只有 CHUNK 缓冲 + 原输入。返回读回总字节数,
   失败或比对不一致返回 -1。 */
func readCompressedAndVerify(src: Array<UInt8>): Int64 {
    let fp = File(LZ4_PATH, OpenMode.Read)
    let (rcode, rh) = LZ4F_readOpen(fp)
    if (LZ4F_isError(rcode)) {
        println("LZ4F_readOpen error: ${LZ4F_getErrorName(rcode)}")
        fp.close()
        return -1
    }
    let rf = rh.getOrThrow()
    let chunk = Array<UInt8>(CHUNK, {_ => 0u8})
    var back: Int64 = 0
    while (true) {
        let got = LZ4F_read(rf, chunk, size: CHUNK)
        if (LZ4F_isError(got)) {
            println("LZ4F_read error: ${LZ4F_getErrorName(got)}")
            fp.close()
            return -1
        }
        if (got == 0) {
            break
        }
        if (back + got > src.size) {
            println("roundtrip MISMATCH: read back ${back + got} > original ${src.size}")
            fp.close()
            return -1
        }
        for (i in 0..got) {
            if (chunk[i] != src[back + i]) {
                println("roundtrip MISMATCH at offset ${back + i}")
                fp.close()
                return -1
            }
        }
        back += got
    }
    let rc = LZ4F_readClose(rf)
    if (LZ4F_isError(rc)) {
        println("LZ4F_readClose error: ${LZ4F_getErrorName(rc)}")
        fp.close()
        return -1
    }
    fp.close()
    return back
}

main(): Int64 {
    let src = makeInput(INPUT_SIZE)
    println("inp = [in-memory, ${INPUT_SIZE} bytes generated]")
    println("lz4 = [${LZ4_PATH}]")

    /* compress */
    println("compress : inp -> lz4 (chunked LZ4F_write, chunk = ${CHUNK} bytes)")
    let w = writeCompressed(src)
    if (w < 0) {
        return 1
    }
    let cSize = fileSize(LZ4_PATH)
    let pct10 = cSize * 1000 / INPUT_SIZE    /* 千分比整数运算,一位小数 */
    println("compress : ${INPUT_SIZE} -> ${cSize} bytes (${pct10 / 10}.${pct10 % 10}%)")
    println("compress : done")

    /* 标准帧确认 */
    if (!verifyFrameMagic()) {
        println("frame magic check FAILED (not a standard LZ4 frame)")
        return 1
    }
    println("frame    : magic 04 22 4D 18 -> standard LZ4 frame (decodable by the lz4 CLI)")

    /* decompress + verify */
    println("decompress : lz4 -> memory (chunked LZ4F_read)")
    let back = readCompressedAndVerify(src)
    if (back < 0) {
        return 1
    }
    println("decompress : done")
    println("verify : ${back} bytes match the original byte-for-byte")
    println("verify : OK")
    removeIfExists(LZ4_PATH)
    return 0
}
