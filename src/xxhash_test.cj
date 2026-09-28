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

@Test
func xxh64VectorTest(): Unit {
    let empty = Array<UInt8>(0, {_ => 0u8})
    let a = "a".toArray()
    let abc = "abc".toArray()
    let hello = "Hello, world!".toArray()
    let p255 = pattern255()
    @Assert(XXH64(empty, 0, 0u64) == 17241709254077376921u64)
    @Assert(XXH64(a, 1, 0u64) == 15154266338359012955u64)
    @Assert(XXH64(abc, 3, 0u64) == 4952883123889572249u64)
    @Assert(XXH64(hello, 13, 0u64) == 17691043854468224118u64)
    @Assert(XXH64(p255, 255, 0u64) == 15989308032179186496u64)
}

@Test
func xxh64StreamingTest(): Unit {
    let data = pattern255()
    // 与 XXH32 相同的边界切分
    let st = XXH64_createState()
    @Assert(XXH64_reset(st, 0u64) == 0)
    var prev: Int64 = 0
    for (c in [1, 7, 15, 16, 17, 31, 32, 255]) {
        @Assert(XXH64_update(st, data, c - prev, offset: prev) == 0)
        prev = c
    }
    @Assert(XXH64_digest(st) == XXH64(data, 255, 0u64))
}

@Test
func xxhFreeStateResetTest(): Unit {
    // freeState 语义:归零复原 —— 弄脏后所有字段(含 mem)回到构造初值
    let data = pattern255()

    let st32 = XXH32_createState()
    @Assert(XXH32_reset(st32, 2654435761u32) == 0)
    @Assert(XXH32_update(st32, data, 255, offset: 0) == 0)
    @Assert(XXH32_digest(st32) != 0u32) // 确认状态已被弄脏
    @Assert(XXH32_freeState(st32) == 0)
    @Assert(st32.total_len == 0u32)
    @Assert(!st32.large_len)
    @Assert(st32.v1 == 0u32 && st32.v2 == 0u32 && st32.v3 == 0u32 && st32.v4 == 0u32)
    @Assert(st32.memsize == 0u32)
    for (i in 0..16) {
        @Assert(st32.mem[i] == 0u8)
    }
    // 归零后可正常复用:reset + 全量数据 == one-shot
    @Assert(XXH32_reset(st32, 2654435761u32) == 0)
    @Assert(XXH32_update(st32, data, 255, offset: 0) == 0)
    @Assert(XXH32_digest(st32) == XXH32(data, 255, 2654435761u32))

    let st64 = XXH64_createState()
    @Assert(XXH64_reset(st64, 11400714785074694791u64) == 0)
    @Assert(XXH64_update(st64, data, 255, offset: 0) == 0)
    @Assert(XXH64_digest(st64) != 0u64)
    @Assert(XXH64_freeState(st64) == 0)
    @Assert(st64.total_len == 0u64)
    @Assert(st64.v1 == 0u64 && st64.v2 == 0u64 && st64.v3 == 0u64 && st64.v4 == 0u64)
    @Assert(st64.memsize == 0u32)
    for (i in 0..32) {
        @Assert(st64.mem[i] == 0u8)
    }
    @Assert(XXH64_reset(st64, 11400714785074694791u64) == 0)
    @Assert(XXH64_update(st64, data, 255, offset: 0) == 0)
    @Assert(XXH64_digest(st64) == XXH64(data, 255, 11400714785074694791u64))
}

@Test
func xxhStreamingSmallInputTest(): Unit {
    // total_len < 16 的流式路径(v3 未轮转,digest 走 v3+PRIME5 分支)
    let a = "a".toArray()
    let hello = "Hello, world!".toArray()   // 13 字节,分块 5+8
    let st = XXH32_createState()
    @Assert(XXH32_reset(st, 0u32) == 0)
    @Assert(XXH32_update(st, a, 1, offset: 0) == 0)
    @Assert(XXH32_digest(st) == XXH32(a, 1, 0u32))
    @Assert(XXH32_reset(st, 0u32) == 0)
    @Assert(XXH32_update(st, hello, 5, offset: 0) == 0)
    @Assert(XXH32_update(st, hello, 8, offset: 5) == 0)
    @Assert(XXH32_digest(st) == XXH32(hello, 13, 0u32))
    let st64 = XXH64_createState()
    @Assert(XXH64_reset(st64, 0u64) == 0)
    @Assert(XXH64_update(st64, hello, 7, offset: 0) == 0)
    @Assert(XXH64_update(st64, hello, 6, offset: 7) == 0)
    @Assert(XXH64_digest(st64) == XXH64(hello, 13, 0u64))
}
