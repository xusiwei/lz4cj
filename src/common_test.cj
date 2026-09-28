// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

import std.unittest.*

@Test
func commonPtrIOTest(): Unit {
    let arr = Array<UInt8>(64, {i => UInt8(i)})
    let dst = Array<UInt8>(64, {_ => 0u8})
    unsafe {
        let h = acquireArrayRawData<UInt8>(arr)
        let p = h.pointer
        @Assert(LZ4_readLE16(p, 3) == 0x0403u16)
        @Assert(LZ4_readLE32(p, 3) == 0x06050403u32)
        @Assert(LZ4_readLE64(p, 5) == 0x0C0B0A0908070605u64)
        releaseArrayRawData<UInt8>(h)
        let dh = acquireArrayRawData<UInt8>(dst)
        let d = dh.pointer
        LZ4_writeLE32(d, 1, 0xDEADBEEFu32)
        @Assert(dst[1] == 0xEFu8 && dst[2] == 0xBEu8 && dst[3] == 0xADu8 && dst[4] == 0xDEu8)
        LZ4_writeLE64(d, 8, 0x0123456789ABCDEFu64)
        @Assert(dst[8] == 0xEFu8 && dst[15] == 0x01u8)
        LZ4_writeLE16(d, 20, 0xBEEFu16)
        @Assert(dst[20] == 0xEFu8 && dst[21] == 0xBEu8)
        releaseArrayRawData<UInt8>(dh)
    }
}

@Test
func commonWildCopyTest(): Unit {
    // wildCopy8: 8 字节步进,len=20 → 写 k=0/8/16,末次可越 oi+len 至多 7 字节,dst 需 8 字节余量
    let src = Array<UInt8>(40, {i => UInt8(i + 100)})
    let dst = Array<UInt8>(48, {_ => 0u8})
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        LZ4_wildCopy8(dh.pointer, 4, sh.pointer, 0, 20)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
    }
    for (i in 0..20) {
        @Assert(dst[i + 4] == UInt8(i + 100))
    }
}

@Test
func commonCopyTest(): Unit {
    let src = Array<UInt8>(40, {i => UInt8(i + 100)})
    let dst = Array<UInt8>(48, {_ => 0u8})
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        LZ4_memcpyPtr(dh.pointer, 4, sh.pointer, 0, 40)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
    }
    for (i in 0..40) {
        @Assert(dst[i + 4] == UInt8(i + 100))
    }
}
