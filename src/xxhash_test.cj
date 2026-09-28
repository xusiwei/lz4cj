// Cangjie port of xxhash (bundled with LZ4), upstream commit 0774d055.
// Upstream: Copyright (c) 2012-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

import std.collection.*
import std.unittest.*

func pattern255(): Array<UInt8> {
    let p = Array<UInt8>(255, {_ => 0u8})
    for (i in 0..255) {
        p[i] = UInt8((i * 7 + 3) % 251)
    }
    return p
}

@Test
func xxh32VectorTest(): Unit {
    let empty = Array<UInt8>(0, {_ => 0u8})
    let a = "a".toArray()
    let abc = "abc".toArray()
    let hello = "Hello, world!".toArray()
    let p255 = pattern255()
    @Assert(XXH32(empty, 0, 0u32) == 46947589u32)
    @Assert(XXH32(a, 1, 0u32) == 1426945110u32)
    @Assert(XXH32(abc, 3, 0u32) == 852579327u32)
    @Assert(XXH32(hello, 13, 0u32) == 834093149u32)
    @Assert(XXH32(p255, 255, 0u32) == 2034483925u32)
}

@Test
func xxh32StreamingTest(): Unit {
    // 分块 == one-shot(边界切分:1B/7B/15B/16B/17B/31B/32B)
    let data = pattern255()
    @Assert(streamAll(data, 0u32, [1, 7, 15, 16, 17, 31, 32, 255]) == XXH32(data, 255, 0u32))
    // 伪随机 LCG 数据 + 伪随机切分 + 非零 seed
    var prng: UInt64 = 0x9e3779b97f4a7c15u64
    let buf = Array<UInt8>(4096, {_ => 0u8})
    for (i in 0..4096) {
        prng = prng * 6364136223846793005u64 + 1442695040888963407u64
        buf[i] = UInt8(prng >> 56)
    }
    let expected = XXH32(buf, 4096, 2654435761u32)
    var splits = ArrayList<Int64>()
    var pos: Int64 = 0
    while (pos < 4096) {
        prng = prng * 6364136223846793005u64 + 1442695040888963407u64
        let step = Int64(prng % 37u64) + 1
        pos += step
        if (pos > 4096) { pos = 4096 }
        splits.add(pos)
    }
    @Assert(streamAt(buf, 2654435761u32, splits.toArray()) == expected)
}

func streamAll(data: Array<UInt8>, seed: UInt32, cuts: Array<Int64>): UInt32 {
    let st = XXH32_createState()
    @Assert(XXH32_reset(st, seed) == 0)
    var prev: Int64 = 0
    for (c in cuts) {
        @Assert(XXH32_update(st, data, c - prev, offset: prev) == 0)
        prev = c
    }
    return XXH32_digest(st)
}

func streamAt(data: Array<UInt8>, seed: UInt32, cuts: Array<Int64>): UInt32 {
    let st = XXH32_createState()
    @Assert(XXH32_reset(st, seed) == 0)
    var prev: Int64 = 0
    for (c in cuts) {
        @Assert(XXH32_update(st, data, c - prev, offset: prev) == 0)
        prev = c
    }
    return XXH32_digest(st)
}
