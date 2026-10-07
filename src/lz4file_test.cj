// M9 lz4file API tests: file-level convenience handles over LZ4F_*.
// Upstream reference: lib/lz4file.c @ 0774d055. Pinned values originate from
// scripts/lz4file_probe.c runs against upstream (Task 4).

package lz4

import std.unittest.*
import std.fs.*

/*-************************************
*  Test helpers
**************************************/

func lz4fileTempPath(name: String): String {
    try { Directory.create("tmp") } catch (e: Exception) { }
    try { Directory.create("tmp/lz4file") } catch (e: Exception) { }
    return "tmp/lz4file/" + name
}

func lz4fileWriteBytes(path: String, bytes: Array<UInt8>): Unit {
    let wf = File(path, OpenMode.Write)
    wf.write(bytes)
    wf.close()
}

func lz4fileRDG(n: Int64, seed: UInt32): Array<UInt8> {
    let b = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(b, n, 0.50, 0.0, seed)
    return b
}

func lz4fileMakeFrame(input: Array<UInt8>, n: Int64,
        prefs: Option<LZ4F_preferences_t>): Array<UInt8> {
    let cap = LZ4F_compressFrameBound(n, prefs)
    let frame = Array<UInt8>(cap, {_ => 0u8})
    let fsize = LZ4F_compressFrame(frame, 0, cap, input, n, prefs)
    if (LZ4F_isError(fsize)) {
        throw Exception("lz4file test: compressFrame failed ${fsize}")
    }
    return frame[0..fsize].toArray()
}

/*-************************************
*  readOpen / readClose (lz4file.c L119-152 / L198-204)
**************************************/

@Test
func lz4fileReadOpenBasicTest(): Unit {
    let n: Int64 = 300000
    let input = lz4fileRDG(n, 1u32)
    let frame = lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t()))
    let path = lz4fileTempPath("open_basic.frm")
    lz4fileWriteBytes(path, frame)
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == LZ4F_OK_NoError)
    match (h) {
        case Some(t) => @Assert(LZ4F_readClose(t) == LZ4F_OK_NoError)
        case None => @Assert(false)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadOpenShortFileTest(): Unit {
    // L83: bytesRead < HEADER_SIZE_MIN + ENDMARK_SIZE (7+4=11) -> io_read
    let path = lz4fileTempPath("short.bin")
    lz4fileWriteBytes(path, Array<UInt8>(10, {_ => 0u8}))
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == -LZ4F_ERROR_io_read)
    match (h) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadOpenEmptyFileTest(): Unit {
    // 0-byte file: same io_read path (fread returns 0)
    let path = lz4fileTempPath("empty.bin")
    lz4fileWriteBytes(path, Array<UInt8>(0, {_ => 0u8}))
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == -LZ4F_ERROR_io_read)
    match (h) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadOpenBadMagicTest(): Unit {
    // L89-92: getFrameInfo error propagates (decodeHeader -> frameType_unknown)
    let bytes = Array<UInt8>(11, {_ => 0u8})
    bytes[0] = 0xDEu8; bytes[1] = 0xADu8; bytes[2] = 0xBEu8; bytes[3] = 0xEFu8
    let path = lz4fileTempPath("badmagic.bin")
    lz4fileWriteBytes(path, bytes)
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == -LZ4F_ERROR_frameType_unknown)
    match (h) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadOpenHeaderChecksumTest(): Unit {
    // valid magic + FLG/BD but wrong HC byte -> headerChecksum_invalid propagates
    let bytes = Array<UInt8>(11, {_ => 0u8})
    bytes[0] = 0x04u8; bytes[1] = 0x22u8; bytes[2] = 0x4Du8; bytes[3] = 0x18u8
    bytes[4] = 0x60u8   // FLG: version 01, blockChecksum, no contentChecksum
    bytes[5] = 0x40u8   // BD: bsID 4 (64KB)
    bytes[6] = 0x00u8   // HC deliberately wrong
    let path = lz4fileTempPath("badhc.bin")
    lz4fileWriteBytes(path, bytes)
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == -LZ4F_ERROR_headerChecksum_invalid)
    match (h) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadOpenSkippablePrefixTest(): Unit {
    // quirk: readOpen on a skippable frame succeeds (blockSizeID=0 -> getBlockSize
    // 65536); frameInfo.blockSizeID stays 0, srcBuf = 64KB (C L94-100)
    let skip = Array<UInt8>(8 + 4, {_ => 0u8})
    skip[0] = 0x50u8; skip[1] = 0x2Au8; skip[2] = 0x4Du8; skip[3] = 0x18u8
    lz4fWriteLE32(skip, 4, 4u32)   // skip content size = 4
    let n: Int64 = 1000
    let input = lz4fileRDG(n, 2u32)
    let frame = lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t()))
    let path = lz4fileTempPath("skippable.bin")
    let all = Array<UInt8>(skip.size + frame.size, {_ => 0u8})
    var i: Int64 = 0
    while (i < skip.size) { all[i] = skip[i]; i += 1 }
    i = 0
    while (i < frame.size) { all[skip.size + i] = frame[i]; i += 1 }
    lz4fileWriteBytes(path, all)
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == LZ4F_OK_NoError)
    match (h) {
        case Some(t) => @Assert(LZ4F_readClose(t) == LZ4F_OK_NoError)
        case None => @Assert(false)
    }
    fp.close()
    removeIfExists(path)
}

/*-************************************
*  LZ4F_read (lz4file.c L154-196)
**************************************/

func lz4fileReadAll(path: String, n: Int64, chunk: Int64): Array<UInt8> {
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == LZ4F_OK_NoError)
    let out = Array<UInt8>(n, {_ => 0u8})
    match (h) {
        case Some(t) =>
            var got: Int64 = 0
            while (got < n) {
                let want = if (n - got < chunk) { n - got } else { chunk }
                // C callers advance buf + got (fileCompress.c L107); this port's
                // LZ4F_read writes at buf[0..], so stage per-call and copy to out.
                let piece = Array<UInt8>(want, {_ => 0u8})
                let r = LZ4F_read(t, piece, size: want)
                if (r <= 0) { break }
                var i: Int64 = 0
                while (i < r) { out[got + i] = piece[i]; i += 1 }
                got += r
            }
            @Assert(got == n)
            @Assert(LZ4F_readClose(t) == LZ4F_OK_NoError)
        case None => @Assert(false)
    }
    fp.close()
    return out
}

@Test
func lz4fileReadWholeTest(): Unit {
    // single full read: 300000B input (RDG .50) crosses 64KB blocks
    let n: Int64 = 300000
    let input = lz4fileRDG(n, 3u32)
    let frame = lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t()))
    let path = lz4fileTempPath("read_whole.frm")
    lz4fileWriteBytes(path, frame)
    let out = lz4fileReadAll(path, n, n)
    @Assert(out == input)
    removeIfExists(path)
}

@Test
func lz4fileReadChunkedTest(): Unit {
    // 997-byte chunk pattern (odd to incommensurate with block/header sizes)
    let n: Int64 = 200000
    let input = lz4fileRDG(n, 4u32)
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = LZ4F_max256KB
    prefs.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled
    let frame = lz4fileMakeFrame(input, n, Some(prefs))
    let path = lz4fileTempPath("read_997.frm")
    lz4fileWriteBytes(path, frame)
    let out = lz4fileReadAll(path, n, 997)
    @Assert(out == input)
    removeIfExists(path)
}

@Test
func lz4fileReadByteAtATimeTest(): Unit {
    // 1-byte reads: exercises loop with dstBytes=1 (decompress clamps)
    let n: Int64 = 4096
    let input = lz4fileRDG(n, 5u32)
    let frame = lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t()))
    let path = lz4fileTempPath("read_1b.frm")
    lz4fileWriteBytes(path, frame)
    let out = lz4fileReadAll(path, n, 1)
    @Assert(out == input)
    removeIfExists(path)
}

@Test
func lz4fileRead4MBBlocksTest(): Unit {
    // >4MB input with max4MB blocks + blockChecksum (large geometry)
    let n: Int64 = 5000000
    let input = lz4fileRDG(n, 6u32)
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = LZ4F_max4MB
    prefs.frameInfo.blockChecksumFlag = LZ4F_blockChecksumEnabled
    let frame = lz4fileMakeFrame(input, n, Some(prefs))
    let path = lz4fileTempPath("read_4mb.frm")
    lz4fileWriteBytes(path, frame)
    let out = lz4fileReadAll(path, n, 1 << 20)
    @Assert(out == input)
    removeIfExists(path)
}

@Test
func lz4fileReadEmptyFrameTest(): Unit {
    // empty frame: read returns 0 at once (loop breaks on first EOF)
    let frame = lz4fileMakeFrame(Array<UInt8>(0, {_ => 0u8}), 0,
        Some(LZ4F_preferences_t()))
    let path = lz4fileTempPath("read_empty.frm")
    lz4fileWriteBytes(path, frame)
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == LZ4F_OK_NoError)
    let buf = Array<UInt8>(16, {_ => 0u8})
    match (h) {
        case Some(t) =>
            @Assert(LZ4F_read(t, buf, size: 16) == 0)
            @Assert(LZ4F_readClose(t) == LZ4F_OK_NoError)
        case None => @Assert(false)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadZeroSizeTest(): Unit {
    // size=0: while loop never runs -> 0 (C L162)
    let n: Int64 = 100
    let input = lz4fileRDG(n, 7u32)
    let frame = lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t()))
    let path = lz4fileTempPath("read_zero.frm")
    lz4fileWriteBytes(path, frame)
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == LZ4F_OK_NoError)
    let buf = Array<UInt8>(16, {_ => 0u8})
    match (h) {
        case Some(t) =>
            @Assert(LZ4F_read(t, buf, size: 0) == 0)
            @Assert(LZ4F_readClose(t) == LZ4F_OK_NoError)
        case None => @Assert(false)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileReadEofPartialTest(): Unit {
    // truncated mid-frame: fread hits EOF -> break -> partial count, no error
    let n: Int64 = 200000
    let input = lz4fileRDG(n, 8u32)
    let frame = lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t()))
    let cut: Int64 = 7 + 4 + 65536 + 2
    let path = lz4fileTempPath("read_trunc.frm")
    lz4fileWriteBytes(path, frame[0..cut].toArray())
    let fp = File(path, OpenMode.Read)
    let (code, h) = LZ4F_readOpen(fp)
    @Assert(code == LZ4F_OK_NoError)
    let buf = Array<UInt8>(n, {_ => 0u8})
    var partial: Int64 = -1
    match (h) {
        case Some(t) => partial = LZ4F_read(t, buf, size: n)
        case None => @Assert(false)
    }
    // C semantics: 65536 bytes decoded, then EOF break; no error sign
    @Assert(partial == 65536)
    @Assert(buf[0..65536] == input[0..65536])
    fp.close()
    removeIfExists(path)
}

/*-************************************
*  write family (lz4file.c L208-362)
**************************************/

func lz4fileWriteRoundtrip(name: String, input: Array<UInt8>, n: Int64,
        prefs: Option<LZ4F_preferences_t>,
        chunks: Array<Int64>): Array<UInt8> {
    let path = lz4fileTempPath(name)
    let fp = File(path, OpenMode.Write)
    let (code, h) = LZ4F_writeOpen(fp, prefs)
    @Assert(code == LZ4F_OK_NoError)
    match (h) {
        case Some(w) =>
            var off: Int64 = 0
            var ci: Int64 = 0
            while (off < n) {
                let want = if (ci < chunks.size) { chunks[ci] } else { n - off }
                let len = if (n - off < want) { n - off } else { want }
                // C callers advance buf + off (probe: LZ4F_write(w, in + off, len));
                // this port's LZ4F_write reads from buf[0..size], so stage per-call
                // and copy from input (lz4fileReadAll staging precedent).
                let piece = Array<UInt8>(len, {_ => 0u8})
                var i: Int64 = 0
                while (i < len) { piece[i] = input[off + i]; i += 1 }
                let r = LZ4F_write(w, piece, size: len)
                @Assert(r == len)
                off += len
                ci += 1
            }
            @Assert(!LZ4F_isError(LZ4F_writeClose(w)))   // tail count varies per variant
        case None => @Assert(false)
    }
    fp.close()
    let bytes = File.readFrom(path)
    removeIfExists(path)
    return bytes
}

@Test
func lz4fileWriteDefaultPrefsTest(): Unit {
    // default prefs (None): file must equal compressFrame byte-for-byte
    // (same Begin + per-block Update + End chunking as C lz4file)
    let n: Int64 = 300000
    let input = lz4fileRDG(n, 11u32)
    let prefs = LZ4F_preferences_t()
    let bytes = lz4fileWriteRoundtrip("w_def.frm", input, n, Some(prefs), [65536])
    @Assert(bytes == lz4fileMakeFrame(input, n, Some(prefs)))
}

@Test
func lz4fileWritePrefsVariantsTest(): Unit {
    // variants cross-check vs upstream C lz4file write path (probe-pinned):
    // v2/v3: file bytes == compressFrame(same prefs) as in C. v0/v1 differ
    // from one-shot IN C ITSELF (v0: compressFrame's optimalBSID shrinks
    // 4MB->1MB BD byte; v1: one-shot compresses from src with autoFlush=1 +
    // forced blockIndependent, write path buffers + flushes from tmpBuff) -
    // those two pinned to upstream file size + XXH32 instead.
    let n: Int64 = 400000
    let input = lz4fileRDG(n, 12u32)
    var v0 = LZ4F_preferences_t()
    v0.frameInfo.blockSizeID = LZ4F_max4MB
    v0.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled
    var v1 = LZ4F_preferences_t()
    v1.frameInfo.blockSizeID = LZ4F_max1MB
    v1.frameInfo.blockChecksumFlag = LZ4F_blockChecksumEnabled
    v1.compressionLevel = 3
    var v2 = LZ4F_preferences_t()
    v2.frameInfo.blockSizeID = LZ4F_max256KB
    v2.frameInfo.blockMode = LZ4F_blockIndependent
    v2.compressionLevel = 9
    var v3 = LZ4F_preferences_t()
    v3.frameInfo.contentSize = UInt64(n)   // contentSize present
    let variants = [v0, v1, v2, v3]
    var i: Int64 = 0
    while (i < 4) {
        let bytes = lz4fileWriteRoundtrip("w_v${i}.frm", input, n,
            Some(variants[i]), [1000])
        if (i == 0) {
            // C probe @0774d055: size=230809 xxh=ad520c82
            @Assert(bytes.size == 230809)
            @Assert(XXH32(bytes, bytes.size, 0u32) == 0xAD520C82u32)
        } else if (i == 1) {
            // C probe @0774d055: size=183829 xxh=d214bb3a
            @Assert(bytes.size == 183829)
            @Assert(XXH32(bytes, bytes.size, 0u32) == 0xD214BB3Au32)
        } else {
            @Assert(bytes == lz4fileMakeFrame(input, n, Some(variants[i])))
        }
        i += 1
    }
}

@Test
func lz4fileWriteNonePrefsTest(): Unit {
    // prefsPtr=None == zeroed prefs (C L262: NULL -> LZ4F_default)
    let n: Int64 = 100000
    let input = lz4fileRDG(n, 13u32)
    let viaNone = lz4fileWriteRoundtrip("w_none.frm", input, n,
        Option<LZ4F_preferences_t>.None, [65536])
    let viaZero = lz4fileWriteRoundtrip("w_zero.frm", input, n,
        Some(LZ4F_preferences_t()), [65536])
    @Assert(viaNone == viaZero)
    @Assert(viaNone == lz4fileMakeFrame(input, n, Some(LZ4F_preferences_t())))
}

@Test
func lz4fileWriteManySmallWritesTest(): Unit {
    // autoFlush=0 buffering: many sub-block writes == one-shot frame bytes
    let n: Int64 = 200001
    let input = lz4fileRDG(n, 14u32)
    let prefs = LZ4F_preferences_t()
    let bytes = lz4fileWriteRoundtrip("w_small.frm", input, n, Some(prefs), [7, 1000, 33333])
    @Assert(bytes == lz4fileMakeFrame(input, n, Some(prefs)))
}

@Test
func lz4fileWriteBadBlockSizeTest(): Unit {
    // invalid blockSizeID=2: C gets allocation_failed via unsigned wrap
    // (probe-pinned); Cangjie early-exits maxBlockSize_invalid (deviation #5)
    let path = lz4fileTempPath("w_badbs.frm")
    let fp = File(path, OpenMode.Write)
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = 2
    let (code, h) = LZ4F_writeOpen(fp, Some(prefs))
    @Assert(code == -LZ4F_ERROR_maxBlockSize_invalid)
    match (h) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    fp.close()
    removeIfExists(path)
}

@Test
func lz4fileWriteEmptyInputTest(): Unit {
    // zero-length write then close: file = header + endmark (11B default)
    let path = lz4fileTempPath("w_empty.frm")
    let fp = File(path, OpenMode.Write)
    let (code, h) = LZ4F_writeOpen(fp, Option<LZ4F_preferences_t>.None)
    @Assert(code == LZ4F_OK_NoError)
    match (h) {
        case Some(w) =>
            @Assert(LZ4F_write(w, Array<UInt8>(0, {_ => 0u8}), size: 0) == 0)
            // C probe @0774d055: close=4 (endmark byte count, isError=0)
            @Assert(LZ4F_writeClose(w) == 4)
        case None => @Assert(false)
    }
    fp.close()
    let bytes = File.readFrom(path)
    @Assert(bytes.size == 11)   // 7B header + 4B endmark
    // roundtrip through read side
    let rp = File(path, OpenMode.Read)
    let (rcode, rh) = LZ4F_readOpen(rp)
    @Assert(rcode == LZ4F_OK_NoError)
    let buf = Array<UInt8>(4, {_ => 0u8})
    match (rh) {
        case Some(t) => @Assert(LZ4F_read(t, buf, size: 4) == 0)
        case None => @Assert(false)
    }
    rp.close()
    removeIfExists(path)
}

@Test
func lz4fileWriteCloseStickyErrTest(): Unit {
    // white-box: errCode != OK -> writeClose skips compressEnd, returns OK
    // (C L346-357 quirk: no endmark written)
    let path = lz4fileTempPath("w_sticky.frm")
    let fp = File(path, OpenMode.Write)
    let n: Int64 = 10
    let (code, h) = LZ4F_writeOpen(fp, Option<LZ4F_preferences_t>.None)
    @Assert(code == LZ4F_OK_NoError)
    match (h) {
        case Some(w) =>
            let input = lz4fileRDG(n, 15u32)
            @Assert(LZ4F_write(w, input, size: n) == n)
            w.errCode = -LZ4F_ERROR_io_write        // simulate sticky error
            @Assert(LZ4F_writeClose(w) == LZ4F_OK_NoError)
        case None => @Assert(false)
    }
    fp.close()
    let bytes = File.readFrom(path)
    // file = header only (C probe @0774d055: 7 bytes): 10-byte write fully
    // buffered (autoFlush=0, < maxWriteSize), errCode skips compressEnd ->
    // no block, no endmark ever written
    @Assert(bytes.size == 7)
    removeIfExists(path)
}
