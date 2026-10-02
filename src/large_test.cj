// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// M7 Task 4: >256KB runtime matrix (design 8.2 final row) - runtime datagen
// roundtrip + C-pinned hash comparison; NOT persisted (no corpus artifacts).
// All pins from scripts/large_probe.c against upstream 0774d055.

package lz4

import std.unittest.*
import std.fs.*

/* 输入(与探针同参):L_A=RDG(300000,0.50,4242) L_B=RDG(1048576,0.90,5353)
   L_C=RDG(327680,0.00,6464) L_D=RDG(1048576,1.00,7575) */
private func largeIn(n: Int64, mp: Float64, seed: UInt32): Array<UInt8> {
    let b = Array<UInt8>(n, {_ => 0u8})
    RDG_genBuffer(b, n, mp, 0.0, seed)
    return b
}

@Test
func lz4LargeBlockTest(): Unit {
    let LA = largeIn(300000, 0.50, 4242u32)
    let LB = largeIn(1048576, 0.90, 5353u32)
    let LD = largeIn(1048576, 1.00, 7575u32)
    /* blk A default: c=175088 */
    let capA = LZ4_compressBound(300000)
    let oA = Array<UInt8>(Int64(capA) + 16, {_ => 0u8})
    let cA = LZ4_compress_default(LA, 300000, oA, capA)
    @Assert(cA == 175088)
    @Assert(XXH32(oA, Int64(cA), 0u32) == 0xae109d9du32)
    @Assert(XXH64(oA, Int64(cA), 0u64) == 0x3b4a48c678c24487u64)
    let dA = Array<UInt8>(300000, {_ => 0u8})
    @Assert(LZ4_decompress_safe(oA, cA, dA, 300000) == 300000)
    @Assert(dA == LA)   /* 同尺寸(300000):结构相等可用 */
    /* blk A fast8: c=212531 */
    let oA2 = Array<UInt8>(Int64(capA) + 16, {_ => 0u8})
    let cA2 = LZ4_compress_fast(LA, 300000, oA2, capA, 8)
    @Assert(cA2 == 212531)
    @Assert(XXH32(oA2, Int64(cA2), 0u32) == 0xff280b96u32)
    @Assert(XXH64(oA2, Int64(cA2), 0u64) == 0xa691c5e50d8e4b1fu64)
    let dA2 = Array<UInt8>(300000, {_ => 0u8})
    @Assert(LZ4_decompress_safe(oA2, cA2, dA2, 300000) == 300000)
    @Assert(dA2 == LA)
    /* blk B destSize tg=786432: c=136227 consumed=1048576 */
    let oB = Array<UInt8>(786432, {_ => 0u8})
    let stB = LZ4_createStreamHC()
    let (cB, kB) = LZ4_compress_HC_destSize(stB, LB, 1048576, oB, 786432, 9)
    @Assert(cB == 136227 && kB == 1048576)
    @Assert(XXH32(oB, Int64(cB), 0u32) == 0x77771c95u32)
    @Assert(XXH64(oB, Int64(cB), 0u64) == 0x664eb7b8331f1604u64)
    let dB = Array<UInt8>(1048576, {_ => 0u8})
    @Assert(LZ4_decompress_safe(oB, cB, dB, kB) == kB)
    @Assert(dB == LB)
    LZ4_freeStreamHC(stB)
    /* blk D default: c=4133 */
    let capD = LZ4_compressBound(1048576)
    let oD = Array<UInt8>(Int64(capD) + 16, {_ => 0u8})
    let cD = LZ4_compress_default(LD, 1048576, oD, capD)
    @Assert(cD == 4133)
    @Assert(XXH32(oD, Int64(cD), 0u32) == 0x3bfd7819u32)
    @Assert(XXH64(oD, Int64(cD), 0u64) == 0xb5a1ea18a290acc0u64)
    let dD = Array<UInt8>(1048576, {_ => 0u8})
    @Assert(LZ4_decompress_safe(oD, cD, dD, 1048576) == 1048576)
    @Assert(dD == LD)
    println("large block: 4 pins (>256KB) bytes + roundtrip verified")
}

@Test
func lz4LargeHcTest(): Unit {
    let LA = largeIn(300000, 0.50, 4242u32)
    let LB = largeIn(1048576, 0.90, 5353u32)
    let LD = largeIn(1048576, 1.00, 7575u32)
    /* (n, lv, fav, wantC, want32, want64) */
    let capA = LZ4_compressBound(300000)
    let capB = LZ4_compressBound(1048576)
    /* hc A lv2 / lv9 */
    let o1 = Array<UInt8>(Int64(capA) + 16, {_ => 0u8})
    @Assert(LZ4_compress_HC(LA, 300000, o1, capA, 2) == 150967)
    @Assert(XXH32(o1, 150967, 0u32) == 0x93ab3a9bu32)
    @Assert(XXH64(o1, 150967, 0u64) == 0xc7003908c6167b52u64)
    let o2 = Array<UInt8>(Int64(capA) + 16, {_ => 0u8})
    @Assert(LZ4_compress_HC(LA, 300000, o2, capA, 9) == 138409)
    @Assert(XXH32(o2, 138409, 0u32) == 0xf9718e03u32)
    @Assert(XXH64(o2, 138409, 0u64) == 0xff57b22d535eb67au64)
    /* hc B lv12 + favorDecompressionSpeed(经流式路径,与探针同构) */
    let o3 = Array<UInt8>(Int64(capB) + 16, {_ => 0u8})
    @Assert(LZ4_compress_HC(LB, 1048576, o3, capB, 12) == 135529)
    @Assert(XXH32(o3, 135529, 0u32) == 0xda06330cu32)
    @Assert(XXH64(o3, 135529, 0u64) == 0xb042ab9e7b249d99u64)
    let stF = LZ4_createStreamHC()
    LZ4_resetStreamHC(stF, 12)
    LZ4_favorDecompressionSpeed(stF, 1)
    let o4 = Array<UInt8>(Int64(capB) + 16, {_ => 0u8})
    @Assert(LZ4_compress_HC_continue(stF, LB, 0, 1048576, o4, capB) == 135961)
    @Assert(XXH32(o4, 135961, 0u32) == 0xdf53973au32)
    @Assert(XXH64(o4, 135961, 0u64) == 0x97a580b82e7903a3u64)
    LZ4_freeStreamHC(stF)
    /* hc D lv9 */
    let o5 = Array<UInt8>(Int64(capB) + 16, {_ => 0u8})
    @Assert(LZ4_compress_HC(LD, 1048576, o5, capB, 9) == 4133)
    @Assert(XXH32(o5, 4133, 0u32) == 0x3bfd7819u32)
    @Assert(XXH64(o5, 4133, 0u64) == 0xb5a1ea18a290acc0u64)
    /* HC 流式 4×262144 滚动解码闭环 + 输出流 XXH32 钉值 d8d702d8 */
    let stC = LZ4_createStreamHC()
    LZ4_resetStreamHC(stC, 9)
    let xs = XXH32_createState()
    @Assert(XXH32_reset(xs, 0u32) == 0)
    let capBlk = LZ4_compressBound(262144)
    let dec = LZ4_createStreamDecode()
    let rolling = Array<UInt8>(262144 * 4, {_ => 0u8})
    var off: Int64 = 0
    var wAt: Int64 = 0
    while (off < 1048576) {
        let o = Array<UInt8>(Int64(capBlk) + 16, {_ => 0u8})
        let c = LZ4_compress_HC_continue(stC, LB, off, 262144, o, capBlk)
        @Assert(c > 0)
        @Assert(XXH32_update(xs, o, Int64(c), offset: 0) == 0)
        /* rolling 解码(decode continue 位置对) */
        let dr = LZ4_decompress_safe_continue(dec, o, c, rolling, wAt, 262144)
        @Assert(dr == 262144)
        off += 262144
        wAt += 262144
    }
    @Assert(XXH32_digest(xs) == 0xd8d702d8u32)
    @Assert(rolling == LB)
    LZ4_freeStreamHC(stC)
    LZ4_freeStreamDecode(dec)
    println("large hc: 6 pins + streaming rolling-decode closure verified")
}

@Test
func lz4LargeFrameTest(): Unit {
    let LA = largeIn(300000, 0.50, 4242u32)
    let LB = largeIn(1048576, 0.90, 5353u32)
    let LC = largeIn(327680, 0.00, 6464u32)
    let LD = largeIn(1048576, 1.00, 7575u32)
    let noneOpt = Option<LZ4F_decompressOptions_t>.None
    /* 一次性 6 行:(input, bs, bm, ccs, bcs, csz, did, lv, af, wantC, want32, want64) */
    let rows: Array<(Array<UInt8>, Int64, Int32, Int32, Int32, Int32, Int64, Int32, Int32, Int32, Int32, UInt32, UInt64)> = [
        (LA, 300000, 4, 0, 0, 0, 0, 0, 0, 0, 174575, 0x4ee15dcfu32, 0x95de9c7656f05a4cu64),
        (LB, 1048576, 6, 1, 1, 1, 1, 0, 0, 0, 227589, 0x65130763u32, 0x1a1e19826e5c8e8eu64),
        (LC, 327680, 4, 0, 0, 0, 0, 0, 0, 0, 327711, 0xde8015edu32, 0x1a446eba43495263u64),
        (LD, 1048576, 7, 0, 0, 0, 0, 0, 0, 1, 4148, 0x898589ccu32, 0xb75bca1adb16fa1au64),
        (LB, 1048576, 4, 0, 0, 0, 0, 0, 12, 0, 135734, 0x50920e4fu32, 0xba1cf5d88871a2adu64),
        (LA, 300000, 4, 0, 1, 0, 0, 42, 0, 0, 174583, 0xb9f1c4d0u32, 0x0532fd737a99e42bu64),
    ]
    for ((src, n, bs, bm, ccs, bcs, csz, did, lv, af, wantC, want32, want64) in rows) {
        var prefs = LZ4F_preferences_t()
        prefs.frameInfo.blockSizeID = bs
        prefs.frameInfo.blockMode = bm
        prefs.frameInfo.contentChecksumFlag = ccs
        prefs.frameInfo.blockChecksumFlag = bcs
        if (csz != 0) {
            prefs.frameInfo.contentSize = UInt64(n)
        }
        prefs.frameInfo.dictID = UInt32(did)
        prefs.compressionLevel = lv
        prefs.autoFlush = UInt32(af)
        let dstCap = LZ4F_compressFrameBound(n, Some(prefs))
        let dst = Array<UInt8>(dstCap, {_ => 0u8})
        let c = LZ4F_compressFrame(dst, 0, dstCap, src, n, Some(prefs))
        @Assert(c == Int64(wantC))
        @Assert(XXH32(dst, c, 0u32) == want32)
        @Assert(XXH64(dst, c, 0u64) == want64)
        /* 整段解压闭环 */
        let dctx = LZ4F_createDecompressionContext(LZ4F_VERSION)
        let out = Array<UInt8>(n + 16, {_ => 0u8})
        let (r, cc, ww) = LZ4F_decompress(dctx, out, 0, n + 16, dst, 0, c, noneOpt)
        @Assert(r == 0 && cc == c && ww == n)
        var eq = true
        var fd: Int64 = -1
        for (i in 0..n) {
            if (out[i] != src[i]) {
                eq = false
                if (fd < 0) { fd = i }
            }
        }
        if (!eq) {
            println("LARGE FRAME MISMATCH at ${fd}")
        }
        @Assert(eq)
    }
    /* 流式长链(af=0,1MB > 192KB → cctx localSaveDict 滞留迁移;中途 flush) */
    var prefs = LZ4F_preferences_t()
    prefs.frameInfo.blockSizeID = 4
    prefs.frameInfo.blockMode = 0
    prefs.autoFlush = 0u32
    let cap = LZ4F_compressFrameBound(1048576, Some(prefs))
    let dst = Array<UInt8>(cap, {_ => 0u8})
    let cctx = LZ4F_createCompressionContext(LZ4F_VERSION)
    var pos = LZ4F_compressBegin(cctx, dst, 0, cap, Some(prefs))
    var off: Int64 = 0
    let noneCOpt = Option<LZ4F_compressOptions_t>.None
    while (off < 1048576) {
        let k: Int64 = if (1048576 - off < 65536) { 1048576 - off } else { 65536 }
        pos += LZ4F_compressUpdate(cctx, dst, pos, cap - pos, LB, off, k, noneCOpt)
        off += k
        if (off == 65536 * 8) {
            pos += LZ4F_flush(cctx, dst, pos, cap - pos, noneCOpt)
        }
    }
    pos += LZ4F_compressEnd(cctx, dst, pos, cap - pos, noneCOpt)
    @Assert(pos == 227828)
    @Assert(XXH32(dst, pos, 0u32) == 0x4976b9afu32)
    @Assert(XXH64(dst, pos, 0u64) == 0x85f13fbbb92c68d3u64)
    let dctx2 = LZ4F_createDecompressionContext(LZ4F_VERSION)
    let out2 = Array<UInt8>(1048576 + 16, {_ => 0u8})
    let (r2, cc2, ww2) = LZ4F_decompress(dctx2, out2, 0, 1048576 + 16, dst, 0, pos, noneOpt)
    @Assert(r2 == 0 && cc2 == pos && ww2 == 1048576)
    var eq2 = true
    for (i in 0..1048576) {
        if (out2[i] != LB[i]) {
            eq2 = false
        }
    }
    @Assert(eq2)
    println("large frame: 6 one-shot pins + af0 streaming chain (localSaveDict migration) verified")
}
