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
    // wildCopy8: do-while 8 字节步进(上游 L465-472)—— len=20 → 写 k=0/8/16,
    // 末次可越 oi+len 至多 7 字节;len=0 → 仍写首个 8 字节(do-while 语义)。
    // dst 均留 8 字节安全余量(调用方义务)。
    let src = Array<UInt8>(40, {i => UInt8(i + 100)})
    let dst = Array<UInt8>(48, {_ => 0u8})
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        LZ4_wildCopy8(dh.pointer, 4, sh.pointer, 0, 20)
        LZ4_wildCopy8(dh.pointer, 40, sh.pointer, 0, 0)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
    }
    for (i in 0..20) {
        @Assert(dst[i + 4] == UInt8(i + 100))
    }
    for (i in 0..8) {
        @Assert(dst[40 + i] == UInt8(i + 100))
    }
}

@Test
func commonWildCopy32Test(): Unit {
    // wildCopy32:32 字节步进(两次 16 字节,上游 L529-537)—— len=20 →
    // 写 k=0 一个 32 字节块(越 oi+len 至多 31 字节);len=0 → 仍写 32 字节。
    // dst 留 32 字节余量(调用方义务)。
    let src = Array<UInt8>(96, {i => UInt8(i + 100)})
    let dst = Array<UInt8>(96, {_ => 0u8})
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        LZ4_wildCopy32(dh.pointer, 4, sh.pointer, 0, 20)
        LZ4_wildCopy32(dh.pointer, 60, sh.pointer, 0, 0)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
    }
    for (i in 0..32) {
        @Assert(dst[4 + i] == UInt8(i + 100))
    }
    for (i in 0..32) {
        @Assert(dst[60 + i] == UInt8(i + 100))
    }
}

@Test
func commonMemcpyUsingOffsetTest(): Unit {
    // memcpy_using_offset:offset 1..15 的交叠拷贝,对照朴素逐字节参考
    // dst[i] = dst[dstPtr + i - offset](顺序求值 —— 已写字节成为后续源,
    // 与上游 v 版(1/2/4)和 base 版(0/3/5..15)的语义一致)。
    // dstEnd 之后留 ≥ 12 字节可写余量(调用方义务)。
    let dst = Array<UInt8>(128, {i => UInt8((i * 29 + 3) % 251)})
    let save = Array<UInt8>(128, {i => dst[i]})
    let expect = Array<UInt8>(64, {_ => 0u8})
    unsafe {
        let dh = acquireArrayRawData<UInt8>(dst)
        for (off in 1..16) {
            for (len in [4, 5, 8, 9, 16, 17, 33]) {
                let oi: Int64 = 64
                // reset region
                var i: Int64 = 0
                while (i < 128) {
                    (dh.pointer + i).write(save[i])
                    i += 1
                }
                // reference: sequential byte-at-a-time overlap copy
                i = 0
                while (i < Int64(len)) {
                    (dh.pointer + oi + i).write((dh.pointer + oi + i - Int64(off)).read())
                    i += 1
                }
                i = 0
                while (i < Int64(len)) {
                    expect[i] = (dh.pointer + oi + i).read()
                    i += 1
                }
                // reset region again, then the port under test
                i = 0
                while (i < 128) {
                    (dh.pointer + i).write(save[i])
                    i += 1
                }
                LZ4_memcpy_using_offset(dh.pointer, oi, oi - Int64(off), oi + Int64(len), Int64(off))
                i = 0
                while (i < Int64(len)) {
                    @Assert((dh.pointer + oi + i).read() == expect[i])
                    i += 1
                }
            }
        }
        releaseArrayRawData<UInt8>(dh)
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
