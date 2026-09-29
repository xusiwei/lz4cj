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

/* 上游 LZ4_wildCopy8(lz4.c L465-472):do-while 8 字节步进 —— 首步无条件
   执行(len==0 仍写 8 字节,与 C 一致;T1 曾以 while 移植,本任务对齐),
   末步可越过 oi+len(至多 7 字节),调用方必须保证 dst 有 8 字节安全余量。
   len==0 位点审计(T3,详见任务报告):压缩侧 L1141(litLength==0,olimit
   检查保证 op+8 ≤ olimit;anchor+8 ≤ iend-4)与解压 safe 循环 L2350
   (length==0,op+8 ≤ oend-MFLIMIT+8、ip+8 ≤ iend)均在界内,越写内容随
   后被后续编码/解码覆写,输出等价。 */
internal func LZ4_wildCopy8(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64): Unit {
    unsafe {
        var k: Int64 = 0
        do {
            CPointer<UInt64>(op + oi + k).write(CPointer<UInt64>(ip + ii + k).read())
            k += 8
        } while (k < len)
    }
}

/* 上游 LZ4_wildCopy32(lz4.c L529-537):32 字节步进,每步两次 16 字节拷贝
   (而非单次 32 字节 —— 须与 offset ≥ 16 的 match 源兼容);do-while 语义,
   len==0 仍拷 32 字节。调用方必须保证 dst 有 32 字节安全余量(fast 解压
   循环字面量/match 拷贝,界由 cpy ≤ oend-32 / op+len < oend-64 保证)。 */
internal func LZ4_wildCopy32(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64): Unit {
    unsafe {
        var k: Int64 = 0
        do {
            CPointer<UInt64>(op + oi + k).write(CPointer<UInt64>(ip + ii + k).read())
            CPointer<UInt64>(op + oi + k + 8).write(CPointer<UInt64>(ip + ii + k + 8).read())
            CPointer<UInt64>(op + oi + k + 16).write(CPointer<UInt64>(ip + ii + k + 16).read())
            CPointer<UInt64>(op + oi + k + 24).write(CPointer<UInt64>(ip + ii + k + 24).read())
            k += 32
        } while (k < len)
    }
}

/* lz4.c L475-476:offset<8 时交叠 match 拷贝的增量表(上游置于 wildCopy
   助手旁;fast 循环 LZ4_memcpy_using_offset_base 与 safe 循环 L2431-2433 共用)。 */
internal let LZ4_INC32TABLE: Array<Int64> = [0, 1, 2, 1, 0, 4, 4, 4]
internal let LZ4_DEC64TABLE: Array<Int64> = [0, 0, 0, -1, -4, 1, 2, 3]

/* 上游 LZ4_memcpy_using_offset_base(lz4.c L489-512):offset<8 的交叠首
   8 字节(2+2+4 拷贝,inc32/dec64 表补偿指针回摆)+ wildCopy8 收尾;
   offset≥8 直接 8 字节 + wildCopy8。调用方义务(上游 L540-543 断言):
   dstEndIdx ≥ oi + 4(MINMATCH);dstEndIdx 之后至少 12 字节可写。
   mi 与 oi 同属 dst 缓冲(match 交叠源),mi + offset == oi。 */
internal func LZ4_memcpy_using_offset_base(dst: CPointer<UInt8>, oi: Int64, mi: Int64,
        dstEndIdx: Int64, offset: Int64): Unit {
    unsafe {
        var d: Int64 = oi
        var s: Int64 = mi
        if (offset < 8) {
            LZ4_writeLE32(dst, d, 0u32)                     /* L495: 消 msan 警告(offset==0 时传播零) */
            LZ4_memcpyPtr(dst, d, dst, s, 2)                /* L497-498 */
            LZ4_memcpyPtr(dst, d + 2, dst, s + 2, 2)
            s += LZ4_INC32TABLE[offset]                     /* L499 */
            LZ4_memcpyPtr(dst, d + 4, dst, s, 4)            /* L500 */
            s -= LZ4_DEC64TABLE[offset]                     /* L501 */
            d += 8
        } else {
            LZ4_memcpyPtr(dst, d, dst, s, 8)                /* L504 */
            d += 8
            s += 8
        }
        LZ4_wildCopy8(dst, d, dst, s, dstEndIdx - d)        /* L510 */
    }
}

/* 上游 LZ4_memcpy_using_offset(lz4.c L538-580):offset 1/2/4 的 8 字节
   周期模式复制(C 的 BYTE v[8] 以 UInt64 模式承载),其余(0/3/5..7 及
   经 base 的 ≥8)走 LZ4_memcpy_using_offset_base。上游仅 fast 解压循环
   调用(lz4.c L2210,offset<16)。调用方义务同 base。 */
internal func LZ4_memcpy_using_offset(dst: CPointer<UInt8>, oi: Int64, mi: Int64,
        dstEndIdx: Int64, offset: Int64): Unit {
    unsafe {
        var v: UInt64
        if (offset == 1) {
            let b: UInt64 = UInt64((dst + mi).read())       /* L545: MEM_INIT(v, *srcPtr, 8) */
            v = b
            v |= b << 8
            v |= b << 16
            v |= b << 24
            v |= b << 32
            v |= b << 40
            v |= b << 48
            v |= b << 56
        } else if (offset == 2) {
            let h: UInt64 = UInt64(LZ4_readLE16(dst, mi))   /* L548-553 */
            v = h | (h << 16) | (h << 32) | (h << 48)
        } else if (offset == 4) {
            let w: UInt64 = UInt64(LZ4_readLE32(dst, mi))   /* L555-557 */
            v = w | (w << 32)
        } else {
            LZ4_memcpy_using_offset_base(dst, oi, mi, dstEndIdx, offset)   /* L566-567 */
            return
        }
        var d: Int64 = oi
        CPointer<UInt64>(dst + d).write(v)                  /* L570 */
        d += 8
        while (d < dstEndIdx) {                             /* L572-574 */
            CPointer<UInt64>(dst + d).write(v)
            d += 8
        }
    }
}
