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
