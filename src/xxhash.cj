// Cangjie port of xxhash (bundled with LZ4), upstream commit 0774d055.
// Upstream: Copyright (c) 2012-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

/*-************************************
*  xxhash primitives
**************************************/
private const PRIME32_1: UInt32 = 2654435761u32
private const PRIME32_2: UInt32 = 2246822519u32
private const PRIME32_3: UInt32 = 3266489917u32
private const PRIME32_4: UInt32 = 668265263u32
private const PRIME32_5: UInt32 = 374761393u32

private func XXH_rotl32(x: UInt32, r: UInt32): UInt32 {
    (x << r) | (x >> (32u32 - r))
}

private func XXH_readLE32(d: Array<UInt8>, i: Int64): UInt32 {
    UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
}

private func XXH_readLE64(d: Array<UInt8>, i: Int64): UInt64 {
    UInt64(d[i]) | (UInt64(d[i + 1]) << 8) | (UInt64(d[i + 2]) << 16) | (UInt64(d[i + 3]) << 24) |
        (UInt64(d[i + 4]) << 32) | (UInt64(d[i + 5]) << 40) | (UInt64(d[i + 6]) << 48) | (UInt64(d[i + 7]) << 56)
}

private func XXH32_round(seed: UInt32, input: UInt32): UInt32 {
    return XXH_rotl32(seed + input * PRIME32_2, 13u32) * PRIME32_1
}

private func XXH32_avalanche(h32: UInt32): UInt32 {
    var h = h32 ^ (h32 >> 15u32)
    h *= PRIME32_2
    h ^= (h >> 13u32)
    h *= PRIME32_3
    h ^= (h >> 16u32)
    return h
}

/*-************************************
*  XXH32 one-shot
**************************************/
internal func XXH32(input: Array<UInt8>, len: Int64, seed: UInt32): UInt32 {
    var p: Int64 = 0
    var h: UInt32
    if (len >= 16) {
        var v1: UInt32 = seed + PRIME32_1 + PRIME32_2
        var v2: UInt32 = seed + PRIME32_2
        var v3: UInt32 = seed
        var v4: UInt32 = seed - PRIME32_1
        let limit: Int64 = len - 15
        do {
            v1 = XXH32_round(v1, XXH_readLE32(input, p)); p += 4
            v2 = XXH32_round(v2, XXH_readLE32(input, p)); p += 4
            v3 = XXH32_round(v3, XXH_readLE32(input, p)); p += 4
            v4 = XXH32_round(v4, XXH_readLE32(input, p)); p += 4
        } while (p < limit)
        h = XXH_rotl32(v1, 1u32) + XXH_rotl32(v2, 7u32) + XXH_rotl32(v3, 12u32) + XXH_rotl32(v4, 18u32)
    } else {
        h = seed + PRIME32_5
    }
    h += UInt32(len)
    while (p + 4 <= len) {
        h += XXH_readLE32(input, p) * PRIME32_3
        h = XXH_rotl32(h, 17u32) * PRIME32_4
        p += 4
    }
    while (p < len) {
        h += UInt32(input[p]) * PRIME32_5
        h = XXH_rotl32(h, 11u32) * PRIME32_1
        p += 1
    }
    return XXH32_avalanche(h)
}
