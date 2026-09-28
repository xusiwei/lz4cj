// Reproducible test-corpus generator, output-compatible with upstream
// LZ4 tests/datagen.c (algorithm by Yann Collet). Independent Cangjie
// expression, BSD-2-Clause, see LICENSE.
package lz4

private const DATAGEN_PRIME1: UInt32 = 2654435761u32
private const DATAGEN_PRIME2: UInt32 = 2246822519u32
private const DATAGEN_LTLOG: Int32 = 13
private const DATAGEN_LTSIZE: Int64 = 8192
private const DATAGEN_LTMASK: UInt32 = 8191u32

internal class RDG_seed {
    public var v: UInt32 = 0
    public init(v: UInt32) { this.v = v }
}

private func RDG_rand(seed: RDG_seed): UInt32 {
    var rand32 = seed.v
    rand32 *= DATAGEN_PRIME1
    rand32 ^= DATAGEN_PRIME2
    rand32 = (rand32 << 13u32) | (rand32 >> 19u32)
    seed.v = rand32
    return rand32
}

private func RDG_fillLiteralDistrib(ld: Float64): Array<UInt8> {
    let lt = Array<UInt8>(DATAGEN_LTSIZE, {_ => 0u8})
    let firstChar: UInt8 = if (ld <= 0.0) { 0u8 } else { 40u8 }   /* '(' */
    let lastChar: UInt8 = if (ld <= 0.0) { 255u8 } else { 125u8 } /* '}' */
    var character: UInt8 = if (ld <= 0.0) { 0u8 } else { 48u8 }   /* '0' */
    var u: Int64 = 0
    while (u < DATAGEN_LTSIZE) {
        var weight = Int64(Float64(DATAGEN_LTSIZE - u) * ld) + 1
        var end = u + weight
        if (end > DATAGEN_LTSIZE) { end = DATAGEN_LTSIZE }
        while (u < end) {
            lt[u] = character
            u += 1
        }
        character += 1u8
        if (character > lastChar) { character = firstChar }
    }
    return lt
}

private func RDG_genChar(seed: RDG_seed, lt: Array<UInt8>): UInt8 {
    let id = RDG_rand(seed) & DATAGEN_LTMASK
    return lt[Int64(id)]
}

/* C 宏展开(保持求值次序):
   RDG_RAND15BITS = (RDG_rand >> 3) & 32767
   RDG_RANDLENGTH = cond ? (rand & 15) : (rand & 511) + 15   */
private func RDG_randLength(seed: RDG_seed): Int64 {
    if (((RDG_rand(seed) >> 7u32) & 7u32) != 0u32) {
        return Int64(RDG_rand(seed) & 15u32)
    }
    return Int64(RDG_rand(seed) & 511u32) + 15
}

private func RDG_genBlock(buffer: Array<UInt8>, buffSize: Int64, prefixSize: Int64,
        matchProba: Float64, lt: Array<UInt8>, seed: RDG_seed): Unit {
    let matchProba32 = UInt32(32768.0 * matchProba)
    var pos: Int64 = prefixSize

    /* special case : matchProba >= 1.0 */
    while (matchProba >= 1.0) {
        var size0 = Int64(RDG_rand(seed) & 3u32)
        size0 = 1 << (16 + size0 * 2)
        size0 += Int64(RDG_rand(seed) & UInt32(size0 - 1))
        if (buffSize < pos + size0) {
            var i = pos
            while (i < buffSize) { buffer[i] = 0u8; i += 1 }
            return
        }
        var i = pos
        while (i < pos + size0) { buffer[i] = 0u8; i += 1 }
        pos += size0
        buffer[pos - 1] = RDG_genChar(seed, lt)
    }

    /* init */
    if (pos == 0) {
        let c = RDG_genChar(seed, lt)
        if (buffSize > 0) { buffer[0] = c }
        pos = 1
    }

    /* Generate compressible data */
    while (pos < buffSize) {
        if (((RDG_rand(seed) >> 3u32) & 32767u32) < matchProba32) {
            /* Copy (within 32K) */
            let length = RDG_randLength(seed) + 4
            var offset = ((RDG_rand(seed) >> 3u32) & 32767u32) + 1u32
            if (Int64(offset) > pos) { offset = UInt32(pos) }
            var matchPos = pos - Int64(offset)
            var d = pos + length
            if (d > buffSize) { d = buffSize }
            while (pos < d) {
                buffer[pos] = buffer[matchPos]
                pos += 1
                matchPos += 1
            }
        } else {
            /* Literal (noise) */
            let length = RDG_randLength(seed)
            var d = pos + length
            if (d > buffSize) { d = buffSize }
            while (pos < d) {
                buffer[pos] = RDG_genChar(seed, lt)
                pos += 1
            }
        }
    }
}

internal func RDG_genBuffer(buffer: Array<UInt8>, size: Int64, matchProba: Float64, litProba: Float64, seed: UInt32): Unit {
    var lp = litProba
    if (lp == 0.0) { lp = matchProba / 4.5 }
    let lt = RDG_fillLiteralDistrib(lp)
    RDG_genBlock(buffer, size, 0, matchProba, lt, RDG_seed(seed))
}
