package dictionary_random_access

/* 字典随机访问示例(概念源自上游 examples/dictionaryRandomAccess.c;上游
   examples 整体为 GPL-2,本文件为独立仓颉实现):
   - 压缩侧:1 KiB 字典 + N 个 1 KiB 数据块。每块压缩前都用 LZ4_loadDict
     重载字典(忘掉此前已压历史),因此每块仅以字典为历史,块间完全独立、
     可单独解压。
   - 容器:与上游一致的布局 —— magic "TEST" + 块 0..N-1 + 尾部跳转表
     (N+1 个块偏移 + 偏移数量)。上游直接 fwrite 原生 int(平台相关),
     这里固定小端 Int32;上游走文件 fseek/fread,这里用单块内存缓冲 +
     下标模拟 seek,不做任何文件 IO。
   - 解压侧:任意区间 [offset, length) 由跳转表定位到其覆盖的块,逐块用
     LZ4_decompress_safe_usingDict 提供同一字典独立还原 —— 只解需要的块,
     不必顺序解前面的块,即"块级随机访问"。最后逐字节比对验证。 */

import lz4.*

let BLOCK: Int32 = 1024        /* 每块 1 KiB 未压缩数据 */
let DICT_SIZE: Int32 = 1024    /* 1 KiB 字典(每块压缩前重载) */
let NUM_BLOCKS: Int64 = 16     /* 数据块数(上游由文件大小决定,这里固定) */
let MAGIC: Array<UInt8> = [0x54u8, 0x45u8, 0x53u8, 0x54u8]   /* "TEST" */

/* ---------- 确定性测试数据 ---------- */

/* 伪随机字母(两轮乘法混合,确定性):所有中间乘积 < 2^62,Int64 内无溢出。
   注意单次"常量乘法+截位"得到的是等差序列,取模后短程强相关;两轮混合
   后各字节近似独立均匀,保证无字典时数据近乎不可压。 */
func dictLetter(i: Int64): Int64 {
    var h: Int64 = (i + 1) * 0x9E3779B1            /* 黄金比例常数 */
    h = h ^ (h >> 15)
    h = (h & 0x1FFFFF) * 0x85EBCA6B                /* 第二轮混合 */
    h = h ^ (h >> 13)
    return ((h >> 20) & 0x7FFFFFFF) % 26
}

/* 1 KiB 字典:16 行 x 64 列的伪随机文本表。行号 ':' 前缀使各行可辨识,
   62 字母列由 dictLetter 生成(行内/行间均无短周期重复)。数据块逐行
   原样复制字典内容 —— 字典收益只能来自 LZ4_loadDict 预载的历史。 */
func makeDictionary(): Array<UInt8> {
    let d = Array<UInt8>(Int64(DICT_SIZE), {_ => 0u8})
    for (r in 0..16) {
        d[r * 64] = UInt8(48 + r % 10)            /* '0'..'9' 行号 */
        d[r * 64 + 1] = 0x3A                      /* ':' 分隔符 */
        for (c in 2..64) {
            d[r * 64 + c] = UInt8(97 + dictLetter(r * 64 + c))
        }
    }
    return d
}

/* 第 k 块(1 KiB):每行借用字典某一行(块间轮换起点,步长 5 与 16 互质,
   块内 16 行恰好覆盖全部字典行)的前 60 字节;行尾 4 字节是递增计数器,
   制造块间差异。整体与字典强重复、块内几乎无重复 —— 无字典时近乎不可压,
   有字典时收益显著。 */
func makeBlock(k: Int64, dict: Array<UInt8>): Array<UInt8> {
    let b = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
    for (r in 0..16) {
        let srcRow: Int64 = ((k * 5 + r) % 16) * 64   /* 字典中被借用的行 */
        let dstRow: Int64 = r * 64
        for (c in 0..60) { b[dstRow + c] = dict[srcRow + c] }
        let seq: UInt32 = UInt32(k * 16 + r)          /* 行尾计数器:块间差异 */
        b[dstRow + 60] = UInt8(seq & 0xFFu32)
        b[dstRow + 61] = UInt8((seq >> 8) & 0xFFu32)
        b[dstRow + 62] = UInt8((seq >> 16) & 0xFFu32)
        b[dstRow + 63] = UInt8((seq >> 24) & 0xFFu32)
    }
    return b
}

/* ---------- 容器(内存版文件) ---------- */

/* 小端 Int32 写入(上游写原生 int,平台相关;这里固定小端) */
func putI32LE(buf: Array<UInt8>, pos: Int64, v: Int32): Unit {
    let u: UInt32 = UInt32(v)
    buf[pos] = UInt8(u & 0xFFu32)
    buf[pos + 1] = UInt8((u >> 8) & 0xFFu32)
    buf[pos + 2] = UInt8((u >> 16) & 0xFFu32)
    buf[pos + 3] = UInt8((u >> 24) & 0xFFu32)
}

/* 小端 Int32 读取 */
func getI32LE(buf: Array<UInt8>, pos: Int64): Int32 {
    let u: UInt32 = UInt32(buf[pos]) | (UInt32(buf[pos + 1]) << 8) | (UInt32(buf[pos + 2]) << 16) | (UInt32(buf[pos + 3]) << 24)
    return Int32(u)
}

/* 压缩全部块,产出容器:magic + 各块压缩数据 + 尾部跳转表。
   返回 (是否成功, 容器)。 */
func compressAll(dict: Array<UInt8>, blocks: Array<Array<UInt8>>): (Bool, Array<UInt8>) {
    let n: Int64 = blocks.size
    let bound: Int32 = LZ4_compressBound(BLOCK)
    let cap: Int64 = 4 + n * Int64(bound) + (n + 2) * 4
    let container = Array<UInt8>(cap, {_ => 0u8})
    let cmpBuf = Array<UInt8>(Int64(bound), {_ => 0u8})
    let offsets = Array<Int32>(n + 1, {_ => 0})       /* 块偏移表:N+1 个端点 */
    let state = LZ4_createStream()
    var pos: Int64 = 0
    for (i in 0..MAGIC.size) { container[pos] = MAGIC[i]; pos += 1 }
    offsets[0] = Int32(pos)
    for (k in 0..n) {
        /* 忘掉此前已压数据,重载字典 —— 每块历史仅字典,块间独立 */
        let loaded = LZ4_loadDict(state, dict, DICT_SIZE)
        if (loaded != DICT_SIZE) { return (false, container) }
        let cmpBytes = LZ4_compress_fast_continue(state, blocks[k], 0, BLOCK, cmpBuf, bound, 1)
        if (cmpBytes <= 0) { return (false, container) }
        for (i in 0..Int64(cmpBytes)) { container[pos + i] = cmpBuf[i] }
        pos += Int64(cmpBytes)
        offsets[k + 1] = Int32(pos)
    }
    LZ4_freeStream(state)
    /* 尾部跳转表:N+1 个偏移,再写偏移数量 N+1(上游同款布局) */
    for (j in 0..(n + 1)) { putI32LE(container, pos, offsets[j]); pos += 4 }
    putI32LE(container, pos, Int32(n + 1))
    pos += 4
    let result = Array<UInt8>(pos, {_ => 0u8})
    for (i in 0..pos) { result[i] = container[i] }
    return (true, result)
}

/* 读取尾部跳转表(偏移数量 = 块数 + 1) */
func jumpTable(container: Array<UInt8>): Array<Int32> {
    let tail: Int64 = Int64(container.size)
    let numOffsets: Int64 = Int64(getI32LE(container, tail - 4))
    let tableBase: Int64 = tail - 4 * (numOffsets + 1)
    let offs = Array<Int32>(numOffsets, {_ => 0})
    for (j in 0..numOffsets) { offs[j] = getI32LE(container, tableBase + 4 * j) }
    return offs
}

/* 压缩统计:每块压缩大小 + 容器总大小与压缩比;返回偏移表供复用 */
func printStats(container: Array<UInt8>, plainBytes: Int64): Array<Int32> {
    let offs = jumpTable(container)
    print("per-block compressed bytes (B):")
    var cmpSum: Int64 = 0
    for (j in 1..offs.size) {
        let sz: Int64 = Int64(offs[j] - offs[j - 1])
        cmpSum += sz
        print(" ${sz}")
    }
    let permille: Int64 = Int64(container.size) * 1000 / plainBytes
    println("  | container ${container.size} B (magic + ${offs.size - 1} blocks + jump table) for ${plainBytes} B plain -> ${permille / 10}.${permille % 10}%")
    return offs
}

/* ---------- 随机访问解码 ---------- */

/* 只解 [offset, offset+length) 覆盖到的块:跳转表给出每块精确字节位置
   (等价 fseek),逐块 LZ4_decompress_safe_usingDict + 同一字典独立还原。
   返回 (是否成功, 解码数据, 触及块数, 实际读取的压缩字节数)。 */
func decodeRange(container: Array<UInt8>, dict: Array<UInt8>,
        offset: Int64, length: Int64): (Bool, Array<UInt8>, Int64, Int64) {
    let bad = Array<UInt8>(1, {_ => 0u8})
    let plainTotal: Int64 = Int64(BLOCK) * NUM_BLOCKS
    if (offset < 0 || length <= 0 || offset + length > plainTotal) {
        return (false, bad, 0, 0)
    }
    let firstBlock: Int64 = offset / Int64(BLOCK)
    let endBlock: Int64 = ((offset + length - 1) / Int64(BLOCK)) + 1
    /* 尾部 4 字节 = 偏移数量;其前为全部偏移(与上游一致) */
    let tail: Int64 = Int64(container.size)
    let numOffsets: Int64 = Int64(getI32LE(container, tail - 4))
    if (numOffsets <= endBlock) { return (false, bad, 0, 0) }
    let tableBase: Int64 = tail - 4 * (numOffsets + 1)
    var currentBlock: Int64 = firstBlock
    var pos: Int64 = Int64(getI32LE(container, tableBase + 4 * currentBlock))
    var sliceOff: Int64 = offset % Int64(BLOCK)       /* 首块内要跳过的字节 */
    var remaining: Int64 = length
    var outPos: Int64 = 0
    var cmpRead: Int64 = 0
    let bound: Int32 = LZ4_compressBound(BLOCK)
    let cmpBuf = Array<UInt8>(Int64(bound), {_ => 0u8})
    let decBuf = Array<UInt8>(Int64(BLOCK), {_ => 0u8})
    let out = Array<UInt8>(length, {_ => 0u8})
    while (currentBlock < endBlock) {
        let blockStart: Int64 = Int64(getI32LE(container, tableBase + 4 * currentBlock))
        let blockEnd: Int64 = Int64(getI32LE(container, tableBase + 4 * (currentBlock + 1)))
        let cmpBytes: Int64 = blockEnd - blockStart
        /* 读出该块(等价 fseek + fread):其余块完全不触碰 */
        for (i in 0..cmpBytes) { cmpBuf[i] = container[pos + i] }
        pos += cmpBytes
        cmpRead += cmpBytes
        /* 关键:仅凭同一字典还原本块,不依赖前面的块 */
        let decBytes = LZ4_decompress_safe_usingDict(cmpBuf, Int32(cmpBytes), decBuf, BLOCK, dict, DICT_SIZE)
        if (decBytes <= 0) { return (false, bad, 0, 0) }
        let avail: Int64 = Int64(decBytes) - sliceOff
        let take: Int64 = if (remaining < avail) { remaining } else { avail }
        for (i in 0..take) { out[outPos + i] = decBuf[sliceOff + i] }
        outPos += take
        remaining -= take
        sliceOff = 0
        currentBlock += 1
    }
    return (true, out, endBlock - firstBlock, cmpRead)
}

/* 解码结果与原始明文 [offset, offset+length) 逐字节比对 */
func verifySlice(plain: Array<UInt8>, dec: Array<UInt8>, offset: Int64, length: Int64): Bool {
    for (i in 0..length) {
        if (plain[offset + i] != dec[i]) { return false }
    }
    return true
}

/* ---------- 编排 ---------- */

main(): Int64 {
    let plainBytes: Int64 = Int64(BLOCK) * NUM_BLOCKS
    println("=== lz4cj dictionary random access (concept from upstream dictionaryRandomAccess.c) ===")
    println("dictionary = ${DICT_SIZE} B, data = ${NUM_BLOCKS} blocks x ${BLOCK} B, container magic = \"TEST\"")

    /* 生成确定性数据(与字典强重复,行尾计数器制造块间差异) */
    let dict = makeDictionary()
    let plain = Array<UInt8>(plainBytes, {_ => 0u8})
    let blocks = Array<Array<UInt8>>(NUM_BLOCKS, {_ => Array<UInt8>(Int64(BLOCK), {_ => 0u8})})
    for (k in 0..NUM_BLOCKS) {
        blocks[k] = makeBlock(k, dict)
        for (i in 0..Int64(BLOCK)) { plain[Int64(BLOCK) * k + i] = blocks[k][i] }
    }

    /* 压缩:逐块 LZ4_loadDict 预载字典 + LZ4_compress_fast_continue */
    let (cok, container) = compressAll(dict, blocks)
    if (!cok) {
        println("compress FAILED")
        return 1
    }
    let offs = printStats(container, plainBytes)

    /* 字典收益对照:同一块,无字典压缩 vs 1 KiB 字典压缩 */
    let bound = LZ4_compressBound(BLOCK)
    let nodictBuf = Array<UInt8>(Int64(bound), {_ => 0u8})
    let nodictBytes = LZ4_compress_fast(blocks[0], BLOCK, nodictBuf, bound, 1)
    println("block 0: with dictionary ${Int64(offs[1] - offs[0])} B vs without dictionary ${Int64(nodictBytes)} B")

    /* 随机访问解码:首块起 / 中间块内 / 对齐单块 / 末块收尾 */
    println("--- random-access decode: only the blocks a range spans are read, each restored via LZ4_decompress_safe_usingDict + the same dictionary ---")
    let starts: Array<Int64> = [0, 7 * 1024 + 500, 11 * 1024, plainBytes - 333]
    let lengths: Array<Int64> = [1500, 600, 1024, 333]
    for (idx in 0..starts.size) {
        let off: Int64 = starts[idx]
        let len: Int64 = lengths[idx]
        let (ok, data, touched, cmpRead) = decodeRange(container, dict, off, len)
        if (!ok) {
            println("range [${off}, ${off + len}) decode FAILED")
            return 1
        }
        if (!verifySlice(plain, data, off, len)) {
            println("range [${off}, ${off + len}) verify NG")
            return 1
        }
        println("range [${off}, ${off + len}) touched ${touched} block(s), read ${cmpRead} compressed B, decoded ${len} B -> verify OK")
    }
    println("all ${starts.size} random-access ranges verified byte-for-byte")
    return 0
}
