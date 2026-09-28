// Cangjie port of xxhash (bundled with LZ4), upstream commit 0774d055.
// Upstream: Copyright (c) 2012-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

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
