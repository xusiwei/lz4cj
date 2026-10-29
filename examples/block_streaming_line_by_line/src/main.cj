package block_streaming_line_by_line

/* 逐记录流式压缩示例(概念源自上游 examples/blockStreaming_lineByLine.c;上游
   examples 整体为 GPL-2,本文件为独立仓颉实现):
   上游演示"逐行日志压缩"——每条记录独立可寻址(u16 长度前缀 + 压缩数据),
   记录之间用 LZ4_compress_fast_continue 共享 64KB 历史,后续记录里的重复
   文本(日志的典型形态)几乎免费。本移植用记录数组代替 stdin,其余语义一致:
   [u16 LE 长度][压缩记录] * N,解压侧逐记录还原。
   演示要点:对比"续压(共享字典)vs 每条独立压缩"的尺寸收益。 */

import lz4.*

/* 日志形态的合成记录:百字节级共享前缀 + 变化序号(足够长,跨记录的
   字典匹配才有肉眼可见的收益) */
func makeLines(): Array<String> {
    let bodies = [
        "connection accepted from 10.0.0.42 port 55112, session established, tls=1.3, cipher=TLS_AES_256_GCM, retry=",
        "request GET /api/v1/items?page=1&size=50&filter=active&sort=updated_at&fields=id,name,status,updatedAt from session=",
        "cache HIT for key user:session:99f2c7 rasterized fragment sha=4f11 elapsed_ms=21 origin=edge-7 upstream=healthy ",
        "response 200 OK content-type=application/json bytes=18432 duration_ms=37 backend=pool-a node=3 attempts=1 trace=",
    ]
    return Array<String>(32, { i => bodies[Int64(i % 4)] + "${i}" })
}

func strBytes(s: String): Array<UInt8> {
    Array<UInt8>(s.size, { i => UInt8(s[i]) })
}

main(): Int64 {
    let lines = makeLines()
    let state = LZ4_createStream()

    /* ---- 压缩:每条记录一个 [u16 长度][数据] 段,续压共享历史 ---- */
    var totalStreamed: Int64 = 0
    var totalIndependent: Int64 = 0
    let blob = Array<Array<UInt8>>(lines.size, { _ => Array<UInt8>(1, {_ => 0u8}) })
    for (li in 0..lines.size) {
        let src = strBytes(lines[li])
        let n = Int32(src.size)
        let bound = LZ4_compressBound(n)
        let dst = Array<UInt8>(Int64(bound), {_ => 0u8})
        let c = LZ4_compress_fast_continue(state, src, 0, n, dst, bound, 1)
        if (c <= 0) { println("line ${li} compress FAILED"); return 1 }
        blob[li] = dst.slice(0, Int64(c))          /* u16 前缀在此演示中存于尺寸数组 */
        totalStreamed += Int64(c)
        /* 对照:同一条独立压缩(无历史) */
        let d2 = Array<UInt8>(Int64(bound), {_ => 0u8})
        totalIndependent += Int64(LZ4_compress_default(src, n, d2, bound))
    }
    LZ4_freeStream(state)
    println("${lines.size} records: streamed=${totalStreamed}B vs independent=${totalIndependent}B " +
        "(shared 64KB history makes later near-duplicate records nearly free)")

    /* ---- 解压:streamDecode 续解逐条还原 ---- */
    let sd = LZ4_createStreamDecode()
    for (li in 0..lines.size) {
        let want = strBytes(lines[li])
        let out = Array<UInt8>(Int64(want.size), {_ => 0u8})
        let d = LZ4_decompress_safe_continue(sd, blob[li], Int32(blob[li].size), out, 0, Int32(want.size))
        if (d != Int32(want.size)) { println("line ${li} decompress FAILED (${d})"); return 1 }
        for (i in 0..Int64(want.size)) {
            if (out[i] != want[i]) { println("line ${li} MISMATCH at ${i}"); return 1 }
        }
    }
    LZ4_freeStreamDecode(sd)
    println("per-record roundtrip OK: all ${lines.size} records verified")
    return 0
}
