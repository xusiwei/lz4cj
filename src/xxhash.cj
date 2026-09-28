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

/*-************************************
*  XXH32 streaming
**************************************/
internal class XXH32_state_t {
    var total_len: UInt32 = 0
    var large_len: Bool = false
    var v1: UInt32 = 0
    var v2: UInt32 = 0
    var v3: UInt32 = 0
    var v4: UInt32 = 0
    var mem: Array<UInt8> = Array<UInt8>(16, {_ => 0u8})
    var memsize: UInt32 = 0
}

internal func XXH32_createState(): XXH32_state_t { return XXH32_state_t() }

internal func XXH32_freeState(state: XXH32_state_t): Int32 { return 0 } // GC 管理,API 对齐保留

internal func XXH32_reset(state: XXH32_state_t, seed: UInt32): Int32 {
    state.total_len = 0
    state.large_len = false
    state.v1 = seed + PRIME32_1 + PRIME32_2
    state.v2 = seed + PRIME32_2
    state.v3 = seed
    state.v4 = seed - PRIME32_1
    state.memsize = 0
    return 0
}

internal func XXH32_update(state: XXH32_state_t, input: Array<UInt8>, len: Int64, offset!: Int64): Int32 {
    var p: Int64 = offset
    let bEnd: Int64 = offset + len
    state.total_len += UInt32(len)
    state.large_len = state.large_len || (len >= 16) || (state.total_len >= 16u32)

    if (Int64(state.memsize) + len < 16) {
        var i: Int64 = 0
        while (i < len) {
            state.mem[Int64(state.memsize) + i] = input[p + i]
            i += 1
        }
        state.memsize += UInt32(len)
        return 0
    }

    if (state.memsize > 0u32) {
        while (Int64(state.memsize) < 16) {
            state.mem[Int64(state.memsize)] = input[p]
            state.memsize += 1u32
            p += 1
        }
        state.v1 = XXH32_round(state.v1, XXH_readLE32(state.mem, 0))
        state.v2 = XXH32_round(state.v2, XXH_readLE32(state.mem, 4))
        state.v3 = XXH32_round(state.v3, XXH_readLE32(state.mem, 8))
        state.v4 = XXH32_round(state.v4, XXH_readLE32(state.mem, 12))
        state.memsize = 0
    }

    if (bEnd - p >= 16) {
        let limit: Int64 = bEnd - 16
        var v1 = state.v1
        var v2 = state.v2
        var v3 = state.v3
        var v4 = state.v4
        do {
            v1 = XXH32_round(v1, XXH_readLE32(input, p)); p += 4
            v2 = XXH32_round(v2, XXH_readLE32(input, p)); p += 4
            v3 = XXH32_round(v3, XXH_readLE32(input, p)); p += 4
            v4 = XXH32_round(v4, XXH_readLE32(input, p)); p += 4
        } while (p <= limit)
        state.v1 = v1; state.v2 = v2; state.v3 = v3; state.v4 = v4
    }

    if (p < bEnd) {
        var i: Int64 = 0
        while (p + i < bEnd) {
            state.mem[i] = input[p + i]
            i += 1
        }
        state.memsize = UInt32(i)
    }
    return 0
}

internal func XXH32_digest(state: XXH32_state_t): UInt32 {
    var h: UInt32
    if (state.large_len) {
        h = XXH_rotl32(state.v1, 1u32) + XXH_rotl32(state.v2, 7u32) +
            XXH_rotl32(state.v3, 12u32) + XXH_rotl32(state.v4, 18u32)
    } else {
        h = state.v3 + PRIME32_5
    }
    h += state.total_len
    // finalize:mem[0, memsize) 上 4B→1B 贪心(等价上游 switch(len&15) fallthrough)
    let n: Int64 = Int64(state.memsize)
    var p: Int64 = 0
    while (p + 4 <= n) {
        h += XXH_readLE32(state.mem, p) * PRIME32_3
        h = XXH_rotl32(h, 17u32) * PRIME32_4
        p += 4
    }
    while (p < n) {
        h += UInt32(state.mem[p]) * PRIME32_5
        h = XXH_rotl32(h, 11u32) * PRIME32_1
        p += 1
    }
    return XXH32_avalanche(h)
}
