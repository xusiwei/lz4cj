// Cangjie side of the lz4cj e2e suite: file-to-file LZ4 frame compressor/
// decompressor built on the lz4cj port (path dependency on the repository
// root). CLI contract mirrors e2e/cli-c/lz4cli.c exactly:
//   lz4cli-cj -c|-d -i <input> -o <output>
//   -c  compress   (LZ4F_writeOpen/write/writeClose, default preferences)
//   -d  decompress (windowed LZ4F_decompress streaming loop)
// Exit codes: 0 ok, 1 runtime error (I/O, corrupt/truncated frame,
// trailing garbage), 2 usage.
//
// Memory model: CONSTANT footprint, independent of file size (feed/output
// windows below + lz4file's 64KB block buffers). The previous whole-file
// layout (readFrom + compressFrameBound-sized dst / 4x dst guess) tripped
// the Cangjie runtime's default 256MiB heap cap on ~137MB inputs.
//
// Why decompression does not call LZ4F_read: lz4file's read side cannot
// distinguish a clean frame end from a truncated one (LZ4F_read returns a
// short count on both), and this CLI's contract requires rejecting
// truncated frames and trailing garbage. The loop below is LZ4F_read's
// own structure plus the ret==0 / src-exhausted signals those checks need.
//
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause (algorithm).
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.

package lz4cli_cj

import std.env.*
import std.fs.*

import lz4.*

const USAGE = "usage: lz4cli-cj -c|-d -i <input> -o <output>"

/* streaming windows: compress feed 4MB; decompress src 256KB / dst 1MB */
const FEED_W: Int64 = 4 * 1024 * 1024
const SRC_W: Int64 = 256 * 1024
const DST_W: Int64 = 1024 * 1024

func err(msg: String): Unit {
    println("lz4cli-cj: ${msg}")
}

private func openOutput(path: String): File {
    // File.create refuses existing paths: remove first to get the C tool's
    // fopen("wb") overwrite semantics
    try {
        removeIfExists(path)
    } catch (_: Exception) {
    }
    return File.create(path)
}

private func doCompress(inPath: String, outPath: String): Int64 {
    let inf = File(inPath, OpenMode.Read)
    let outf = openOutput(outPath)
    /* Reproduce LZ4F_compressFrame(NULL prefs) auto-adjustments
       (lz4frame.c L443-453): default blockSizeID resolves to max64KB, and
       an input that fits a single block switches to blockIndependent
       ("only one block => no need for inter-block link"). Plain
       LZ4F_writeOpen(..., None) keeps blockLinked for every size, which
       would break byte-identity against the C tool's whole-file
       compressFrame on inputs <= 64KB. */
    let n = inf.length
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = LZ4F_max64KB
    prefs.autoFlush = 1u32
    if (n <= LZ4F_getBlockSize(LZ4F_max64KB)) {
        prefs.frameInfo.blockMode = LZ4F_blockIndependent
    }
    let (openCode, h) = LZ4F_writeOpen(outf, Some(prefs))
    if (LZ4F_isError(openCode)) {
        err("compress failed: ${LZ4F_getErrorName(openCode)}")
        return 1
    }
    match (h) {
        case None =>
            err("compress failed: writeOpen returned no handle")
            return 1
        case Some(wf) =>
            let win = Array<UInt8>(FEED_W, {_ => 0u8})
            while (true) {
                let got = inf.read(win)
                if (got <= 0) {
                    break                                  /* EOF */
                }
                let w = LZ4F_write(wf, win, size: got)
                if (LZ4F_isError(w)) {
                    err("compress failed: ${LZ4F_getErrorName(w)}")
                    return 1
                }
            }
            let tail = LZ4F_writeClose(wf)
            if (LZ4F_isError(tail)) {
                err("compress failed: ${LZ4F_getErrorName(tail)}")
                return 1
            }
    }
    inf.close()
    outf.close()
    return 0
}

private func doDecompress(inPath: String, outPath: String): Int64 {
    let inf = File(inPath, OpenMode.Read)
    let outf = openOutput(outPath)
    let src = Array<UInt8>(SRC_W, {_ => 0u8})
    let dst = Array<UInt8>(DST_W, {_ => 0u8})
    let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
    var fill: Int64 = 0        /* valid bytes in src   */
    var pos: Int64 = 0         /* consumed offset      */
    while (true) {
        if (pos == fill) {     /* window drained: refill or fail truncated */
            fill = inf.read(src)
            pos = 0
            if (fill == 0) {
                err("truncated frame: ${inPath}")
                return 1
            }
        }
        let (ret, srcConsumed, dstWritten) = LZ4F_decompress(dctx,
            dst, 0, DST_W, src, pos, fill - pos,
            Option<LZ4F_decompressOptions_t>.None)
        if (LZ4F_isError(ret)) {
            err("decompress failed: ${LZ4F_getErrorName(ret)}")
            return 1
        }
        pos += srcConsumed
        if (dstWritten > 0) {
            outf.write(dst[0..dstWritten])
        }
        if (ret == 0) {        /* frame complete: reject trailing bytes */
            if (pos != fill) {
                err("trailing garbage after frame: ${inPath}")
                return 1
            }
            let probe = Array<UInt8>(1, {_ => 0u8})
            if (inf.read(probe) != 0) {
                err("trailing garbage after frame: ${inPath}")
                return 1
            }
            break
        }
    }
    inf.close()
    outf.close()
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
