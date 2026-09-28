// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.
// Corresponds to upstream MEM_*/LZ4_read*/LZ4_write* macro families in lz4.c.
// Target platforms (x86_64/aarch64) are little-endian, matching C builds.

package lz4

internal func LZ4_readLE16(p: CPointer<UInt8>, i: Int64): UInt16 {
    return unsafe { CPointer<UInt16>(p + i).read() }
}

internal func LZ4_readLE32(p: CPointer<UInt8>, i: Int64): UInt32 {
    return unsafe { CPointer<UInt32>(p + i).read() }
}

internal func LZ4_readLE64(p: CPointer<UInt8>, i: Int64): UInt64 {
    return unsafe { CPointer<UInt64>(p + i).read() }
}

internal func LZ4_writeLE16(p: CPointer<UInt8>, i: Int64, v: UInt16): Unit {
    unsafe { CPointer<UInt16>(p + i).write(v) }
}

internal func LZ4_writeLE32(p: CPointer<UInt8>, i: Int64, v: UInt32): Unit {
    unsafe { CPointer<UInt32>(p + i).write(v) }
}

internal func LZ4_writeLE64(p: CPointer<UInt8>, i: Int64, v: UInt64): Unit {
    unsafe { CPointer<UInt64>(p + i).write(v) }
}

internal func LZ4_memcpyPtr(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64): Unit {
    unsafe {
        var k: Int64 = 0
        while (k < len) {
            (op + oi + k).write((ip + ii + k).read())
            k += 1
        }
    }
}

/* 上游 LZ4_wildCopy8:8 字节步进,最后一步可能越过 oi+len(至多 7 字节),
   调用方必须保证 dst 有 8 字节安全余量(M3 解压热路径)。 */
internal func LZ4_wildCopy8(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64): Unit {
    unsafe {
        var k: Int64 = 0
        while (k < len) {
            CPointer<UInt64>(op + oi + k).write(CPointer<UInt64>(ip + ii + k).read())
            k += 8
        }
    }
}


