// Cangjie side of the lz4cj e2e suite: minimal file-to-file LZ4 frame
// compressor/decompressor built on the lz4cj port (path dependency on the
// repository root). CLI contract mirrors e2e/cli-c/lz4cli.c exactly:
//   lz4cli-cj -c|-d -i <input> -o <output>
//   -c  compress   (LZ4F_compressFrame, default preferences)
//   -d  decompress (streaming LZ4F_decompress, growing output buffer)
// Exit codes: 0 ok, 1 runtime error (I/O, corrupt/truncated frame,
// trailing garbage), 2 usage.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause (algorithm).
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.

package lz4cli_cj

import std.env.*
import std.fs.*

import lz4.*

const USAGE = "usage: lz4cli-cj -c|-d -i <input> -o <output>"

func err(msg: String): Unit {
    println("lz4cli-cj: ${msg}")
}

private func writeExact(path: String, buf: Array<UInt8>, size: Int64): Unit {
    // File.write emits the whole buffer; hand it an exact-size view
    let out = if (size == buf.size) {
        buf
    } else {
        Array<UInt8>(size, {k => buf[k]})
    }
    // File.create refuses existing paths: remove first to get the C tool's
    // fopen("wb") overwrite semantics
    try {
        removeIfExists(path)
    } catch (_: Exception) {
    }
    let f = File.create(path)
    f.write(out)
    f.close()
}

private func doCompress(inPath: String, outPath: String): Int64 {
    let src = File.readFrom(inPath)
    let n: Int64 = Int64(src.size)
    let bound = LZ4F_compressFrameBound(n, Option<LZ4F_preferences_t>.None)
    let dst = Array<UInt8>(bound, {_ => 0u8})
    let c = LZ4F_compressFrame(dst, 0, bound, src, n,
        Option<LZ4F_preferences_t>.None)
    if (LZ4F_isError(c)) {
        err("compress failed: ${LZ4F_getErrorName(c)}")
        return 1
    }
    writeExact(outPath, dst, c)
    return 0
}

private func doDecompress(inPath: String, outPath: String): Int64 {
    let src = File.readFrom(inPath)
    let srcLen: Int64 = Int64(src.size)
    var cap: Int64 = if (srcLen < 4096) {
        4096
    } else {
        srcLen * 4
    }
    var dst = Array<UInt8>(cap, {_ => 0u8})
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    var readPos: Int64 = 0
    var written: Int64 = 0
    while (true) {
        let room: Int64 = cap - written
        let chunk: Int64 = srcLen - readPos
        let (ret, consumed, wrote) = LZ4F_decompress(dctx, dst, written, room,
            src, readPos, chunk, Option<LZ4F_decompressOptions_t>.None)
        if (LZ4F_isError(ret)) {
            err("decompress failed: ${LZ4F_getErrorName(ret)}")
            return 1
        }
        readPos += consumed
        written += wrote
        if (ret == 0) {
            break
        }
        if (readPos == srcLen) {
            err("truncated frame: ${inPath}")
            return 1
        }
        if (written == cap) {              // needs more room: grow
            cap *= 2
            let old = dst
            dst = Array<UInt8>(cap, {k => if (k < old.size) {
                old[k]
            } else {
                0u8
            }})
        }
    }
    if (readPos != srcLen) {
        err("trailing garbage after frame: ${inPath}")
        return 1
    }
    writeExact(outPath, dst, written)
    return 0
}

main(): Int64 {
    let args = getCommandLine()
    var inPath = ""
    var outPath = ""
    var comp = false
    var dec = false
    var i = 1
    while (i < args.size) {
        let a = args[i]
        if (a == "-c") {
            comp = true
        } else if (a == "-d") {
            dec = true
        } else if (a == "-i" && i + 1 < args.size) {
            i += 1
            inPath = args[i]
        } else if (a == "-o" && i + 1 < args.size) {
            i += 1
            outPath = args[i]
        } else {
            err(USAGE)
            return 2
        }
        i += 1
    }
    if (comp == dec) {                     // exactly one of -c/-d
        err(USAGE)
        return 2
    }
    if (inPath == "" || outPath == "") {
        err(USAGE)
        return 2
    }
    try {
        return if (comp) {
            doCompress(inPath, outPath)
        } else {
            doDecompress(inPath, outPath)
        }
    } catch (e: Exception) {
        err("${e}")
        return 1
    }
}
