// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

import std.unittest.*
import std.fs.*

@Test
func lz4VersionTest(): Unit {
    @Assert(LZ4_versionNumber() == 11000)
    @Assert(LZ4_versionString() == "1.10.0")
    @Assert(LZ4_VERSION_MAJOR == 1 && LZ4_VERSION_MINOR == 10 && LZ4_VERSION_RELEASE == 0)
}

@Test
func lz4CompressBoundTest(): Unit {
    @Assert(LZ4_compressBound(0) == 16)
    @Assert(LZ4_compressBound(1) == 17)
    @Assert(LZ4_compressBound(255) == 272)      // 255+1+16
    @Assert(LZ4_compressBound(256) == 273)      // 256+1+16
    @Assert(LZ4_compressBound(65536) == 65809)  // 65536+257+16
    @Assert(LZ4_compressBound(-1) == 0)
    @Assert(LZ4_compressBound(LZ4_MAX_INPUT_SIZE + 1) == 0)
    @Assert(LZ4_compressBound(LZ4_MAX_INPUT_SIZE) == LZ4_MAX_INPUT_SIZE + LZ4_MAX_INPUT_SIZE / 255 + 16)
    @Assert(LZ4_MAX_INPUT_SIZE == 0x7E000000)
}

@Test
func lz4StreamStateTest(): Unit {
    let st = LZ4_stream_t()
    @Assert(LZ4_initStream(st) == 0)
    @Assert(st.currentOffset == 0u32)
    @Assert(st.hashTable.size == 16384)
    @Assert(st.hashTable[0] == 0u32 && st.hashTable[16383] == 0u32)
    @Assert(LZ4_sizeofState() == LZ4_STREAMSIZE)
    @Assert(LZ4_STREAMSIZE == 16416)
}

/*-************************************
*  M2 block compression: unit + golden
**************************************/

@Test
func lz4CompressEmptyTest(): Unit {
    let src = Array<UInt8>(0, {_ => 0u8})
    let dst = Array<UInt8>(16, {_ => 0xFFu8})
    // empty input -> 1-byte block, token 0x00 (upstream L1370-1380)
    @Assert(LZ4_compress_default(src, 0, dst, 16) == 1)
    @Assert(dst[0] == 0u8)
    // limitedOutput with dstCapacity <= 0 -> 0 (upstream L1371)
    @Assert(LZ4_compress_default(src, 0, dst, 0) == 0)
    // extState entry + acceleration < 1 clamped to default 1 (upstream L1395)
    let st = LZ4_stream_t()
    @Assert(LZ4_compress_fast_extState(st, src, 0, dst, 16, -5) == 1 && dst[0] == 0u8)
    @Assert(LZ4_compress_fast_extState_fastReset(st, src, 0, dst, 16, 0) == 1 && dst[0] == 0u8)
}

@Test
func lz4CompressInsufficientDstTest(): Unit {
    let src = Array<UInt8>(4096, {_ => 0u8})
    RDG_genBuffer(src, 4096, 0.0, 0.0, 0u32)   // incompressible PRNG bytes
    let dst = Array<UInt8>(16, {_ => 0u8})
    @Assert(LZ4_compress_fast(src, 4096, dst, 16, 1) == 0)
    let st = LZ4_stream_t()
    @Assert(LZ4_compress_fast_extState_fastReset(st, src, 4096, dst, 16, 8) == 0)
}

@Test
func lz4CompressBoundExactTest(): Unit {
    let src = Array<UInt8>(255, {_ => 0u8})
    RDG_genBuffer(src, 255, 0.5, 0.0, 7u32)
    let bound = LZ4_compressBound(255)
    @Assert(bound == 272)
    // dstCapacity == bound is already notLimited (upstream uses >=, L1397)
    let dst = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c = LZ4_compress_default(src, 255, dst, bound)
    @Assert(c > 0 && c <= bound)
    // larger capacity must produce identical bytes (both notLimited)
    let big = Array<UInt8>(Int64(bound) + 64, {_ => 0u8})
    let c2 = LZ4_compress_default(src, 255, big, bound + 64)
    @Assert(c == c2)
    for (i in 0..Int64(c)) {
        @Assert(dst[i] == big[i])
    }
}

/*-************************************
*  M2 compression golden (vs upstream C, commit 0774d055)
**************************************/
// Embedded from corpus/block_golden_ref.txt (scripts/gen_golden.c, 256 rows;
// mode=dest rows are Task 4's scope and omitted here => 192 rows).
// litProba is 0.0 for every row (gen_golden.c hardcodes it).
let BLOCK_MPS: Array<Float64> = [0.0, 0.5, 0.9, 1.0]

// hex32/hex64 in datagen_test.cj are file-private; local copies for diagnostics
private let BLK_HEX: Array<String> =
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

private func blkHex32(v: UInt32): String {
    var s = "0x"
    for (i in 0..8) {
        s += BLK_HEX[Int64((v >> UInt32((7 - i) * 4)) & 0xFu32)]
    }
    return s
}

private func blkHex64(v: UInt64): String {
    var s = "0x"
    for (i in 0..16) {
        s += BLK_HEX[Int64((v >> UInt64((15 - i) * 4)) & 0xFu64)]
    }
    return s
}

// (n, mpIndex, seed, modeIndex[0=default,1=fast1,2=fast8], size, xxh32, xxh64, fileRowIdx),
// fileRowIdx = manifest row index (000..255) of the corpus/block/<idx>.lz4 artifact, -1 = none
let BLOCK_REF: Array<(Int64, Int64, UInt32, Int64, Int32, UInt32, UInt64, Int64)> = [
    (0, 0, 0u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 0),
    (0, 0, 0u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 1),
    (0, 0, 0u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 2),
    (0, 0, 7u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 4),
    (0, 0, 7u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 5),
    (0, 0, 7u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 6),
    (0, 1, 0u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 8),
    (0, 1, 0u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 9),
    (0, 1, 0u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 10),
    (0, 1, 7u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 12),
    (0, 1, 7u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 13),
    (0, 1, 7u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 14),
    (0, 2, 0u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 16),
    (0, 2, 0u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 17),
    (0, 2, 0u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 18),
    (0, 2, 7u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 20),
    (0, 2, 7u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 21),
    (0, 2, 7u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 22),
    (0, 3, 0u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 24),
    (0, 3, 0u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 25),
    (0, 3, 0u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 26),
    (0, 3, 7u32, 0, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 28),
    (0, 3, 7u32, 1, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 29),
    (0, 3, 7u32, 2, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 30),
    (1, 0, 0u32, 0, 2, 0x47bed82cu32, 0xec3cae3829bb6262u64, 32),
    (1, 0, 0u32, 1, 2, 0x47bed82cu32, 0xec3cae3829bb6262u64, 33),
    (1, 0, 0u32, 2, 2, 0x47bed82cu32, 0xec3cae3829bb6262u64, 34),
    (1, 0, 7u32, 0, 2, 0x58adcfb1u32, 0xc1881941a0d84fe0u64, 36),
    (1, 0, 7u32, 1, 2, 0x58adcfb1u32, 0xc1881941a0d84fe0u64, 37),
    (1, 0, 7u32, 2, 2, 0x58adcfb1u32, 0xc1881941a0d84fe0u64, 38),
    (1, 1, 0u32, 0, 2, 0x2a48629bu32, 0x52af69c62e494cd4u64, 40),
    (1, 1, 0u32, 1, 2, 0x2a48629bu32, 0x52af69c62e494cd4u64, 41),
    (1, 1, 0u32, 2, 2, 0x2a48629bu32, 0x52af69c62e494cd4u64, 42),
    (1, 1, 7u32, 0, 2, 0x586a35acu32, 0x860d39e6340d7355u64, 44),
    (1, 1, 7u32, 1, 2, 0x586a35acu32, 0x860d39e6340d7355u64, 45),
    (1, 1, 7u32, 2, 2, 0x586a35acu32, 0x860d39e6340d7355u64, 46),
    (1, 2, 0u32, 0, 2, 0x958523dbu32, 0x67cf4e42457fb77du64, 48),
    (1, 2, 0u32, 1, 2, 0x958523dbu32, 0x67cf4e42457fb77du64, 49),
    (1, 2, 0u32, 2, 2, 0x958523dbu32, 0x67cf4e42457fb77du64, 50),
    (1, 2, 7u32, 0, 2, 0x0ed2f8cau32, 0xdcadfb4995a8a6b7u64, 52),
    (1, 2, 7u32, 1, 2, 0x0ed2f8cau32, 0xdcadfb4995a8a6b7u64, 53),
    (1, 2, 7u32, 2, 2, 0x0ed2f8cau32, 0xdcadfb4995a8a6b7u64, 54),
    (1, 3, 0u32, 0, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 56),
    (1, 3, 0u32, 1, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 57),
    (1, 3, 0u32, 2, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 58),
    (1, 3, 7u32, 0, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 60),
    (1, 3, 7u32, 1, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 61),
    (1, 3, 7u32, 2, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 62),
    (255, 0, 0u32, 0, 257, 0x42be5aa6u32, 0x1fb93d0dad1a834du64, 64),
    (255, 0, 0u32, 1, 257, 0x42be5aa6u32, 0x1fb93d0dad1a834du64, 65),
    (255, 0, 0u32, 2, 257, 0x42be5aa6u32, 0x1fb93d0dad1a834du64, 66),
    (255, 0, 7u32, 0, 257, 0x0ed29158u32, 0xb4f125c8c1816af3u64, 68),
    (255, 0, 7u32, 1, 257, 0x0ed29158u32, 0xb4f125c8c1816af3u64, 69),
    (255, 0, 7u32, 2, 257, 0x0ed29158u32, 0xb4f125c8c1816af3u64, 70),
    (255, 1, 0u32, 0, 238, 0xa1ed468du32, 0x7a32da63abaf06e2u64, 72),
    (255, 1, 0u32, 1, 238, 0xa1ed468du32, 0x7a32da63abaf06e2u64, 73),
    (255, 1, 0u32, 2, 252, 0xd612adf7u32, 0x334730c0ce47d36bu64, 74),
    (255, 1, 7u32, 0, 11, 0x3b48606au32, 0x4bee6aad626bda16u64, 76),
    (255, 1, 7u32, 1, 11, 0x3b48606au32, 0x4bee6aad626bda16u64, 77),
    (255, 1, 7u32, 2, 11, 0x3b48606au32, 0x4bee6aad626bda16u64, 78),
    (255, 2, 0u32, 0, 11, 0x387b105fu32, 0x6ade35f444efe462u64, 80),
    (255, 2, 0u32, 1, 11, 0x387b105fu32, 0x6ade35f444efe462u64, 81),
    (255, 2, 0u32, 2, 11, 0x387b105fu32, 0x6ade35f444efe462u64, 82),
    (255, 2, 7u32, 0, 11, 0x8ebfdc6du32, 0xf9f9a04a61934aaau64, 84),
    (255, 2, 7u32, 1, 11, 0x8ebfdc6du32, 0xf9f9a04a61934aaau64, 85),
    (255, 2, 7u32, 2, 11, 0x8ebfdc6du32, 0xf9f9a04a61934aaau64, 86),
    (255, 3, 0u32, 0, 11, 0x83f66756u32, 0x3ed8172ad694afa3u64, 88),
    (255, 3, 0u32, 1, 11, 0x83f66756u32, 0x3ed8172ad694afa3u64, 89),
    (255, 3, 0u32, 2, 11, 0x83f66756u32, 0x3ed8172ad694afa3u64, 90),
    (255, 3, 7u32, 0, 11, 0x83f66756u32, 0x3ed8172ad694afa3u64, 92),
    (255, 3, 7u32, 1, 11, 0x83f66756u32, 0x3ed8172ad694afa3u64, 93),
    (255, 3, 7u32, 2, 11, 0x83f66756u32, 0x3ed8172ad694afa3u64, 94),
    (4096, 0, 0u32, 0, 4114, 0x754fae48u32, 0xb179757c99f97c27u64, 96),
    (4096, 0, 0u32, 1, 4114, 0x754fae48u32, 0xb179757c99f97c27u64, 97),
    (4096, 0, 0u32, 2, 4114, 0x754fae48u32, 0xb179757c99f97c27u64, 98),
    (4096, 0, 7u32, 0, 4114, 0x833d749cu32, 0xeacc7240615d52b9u64, 100),
    (4096, 0, 7u32, 1, 4114, 0x833d749cu32, 0xeacc7240615d52b9u64, 101),
    (4096, 0, 7u32, 2, 4114, 0x833d749cu32, 0xeacc7240615d52b9u64, 102),
    (4096, 1, 0u32, 0, 2527, 0x84900dc4u32, 0xc1d36a7b7ae8ce5cu64, 104),
    (4096, 1, 0u32, 1, 2527, 0x84900dc4u32, 0xc1d36a7b7ae8ce5cu64, 105),
    (4096, 1, 0u32, 2, 2848, 0x1e0dbab8u32, 0x02ddf1af546ca401u64, 106),
    (4096, 1, 7u32, 0, 1442, 0x9af1d84eu32, 0xe8758bb9f62bc933u64, 108),
    (4096, 1, 7u32, 1, 1442, 0x9af1d84eu32, 0xe8758bb9f62bc933u64, 109),
    (4096, 1, 7u32, 2, 1450, 0x50dfff5bu32, 0xfe2addf4079e4097u64, 110),
    (4096, 2, 0u32, 0, 443, 0xcd28d50du32, 0x017e097f399fb1a0u64, 112),
    (4096, 2, 0u32, 1, 443, 0xcd28d50du32, 0x017e097f399fb1a0u64, 113),
    (4096, 2, 0u32, 2, 449, 0x7ba25060u32, 0x3b5603e2375611e0u64, 114),
    (4096, 2, 7u32, 0, 350, 0x0a37027au32, 0xb0b1b7a51c084a07u64, 116),
    (4096, 2, 7u32, 1, 350, 0x0a37027au32, 0xb0b1b7a51c084a07u64, 117),
    (4096, 2, 7u32, 2, 382, 0x4c6327bdu32, 0xc84fe3d68efd46adu64, 118),
    (4096, 3, 0u32, 0, 26, 0x1fc69d86u32, 0xca765317388e8959u64, 120),
    (4096, 3, 0u32, 1, 26, 0x1fc69d86u32, 0xca765317388e8959u64, 121),
    (4096, 3, 0u32, 2, 26, 0x1fc69d86u32, 0xca765317388e8959u64, 122),
    (4096, 3, 7u32, 0, 26, 0x1fc69d86u32, 0xca765317388e8959u64, 124),
    (4096, 3, 7u32, 1, 26, 0x1fc69d86u32, 0xca765317388e8959u64, 125),
    (4096, 3, 7u32, 2, 26, 0x1fc69d86u32, 0xca765317388e8959u64, 126),
    (65535, 0, 0u32, 0, 65793, 0x10eb4be3u32, 0x3b261b93f74a21c4u64, -1),
    (65535, 0, 0u32, 1, 65793, 0x10eb4be3u32, 0x3b261b93f74a21c4u64, -1),
    (65535, 0, 0u32, 2, 65793, 0x10eb4be3u32, 0x3b261b93f74a21c4u64, -1),
    (65535, 0, 7u32, 0, 65793, 0x6af9d1a6u32, 0xb657c0174306c848u64, -1),
    (65535, 0, 7u32, 1, 65793, 0x6af9d1a6u32, 0xb657c0174306c848u64, -1),
    (65535, 0, 7u32, 2, 65793, 0x6af9d1a6u32, 0xb657c0174306c848u64, -1),
    (65535, 1, 0u32, 0, 36459, 0x2fc26585u32, 0xd8e8dcf0914b5f2au64, 136),
    (65535, 1, 0u32, 1, 36459, 0x2fc26585u32, 0xd8e8dcf0914b5f2au64, 137),
    (65535, 1, 0u32, 2, 42371, 0x41808f86u32, 0x200c81c78ce4b4d1u64, 138),
    (65535, 1, 7u32, 0, 36301, 0x46f64282u32, 0x21df072ddb19c417u64, 140),
    (65535, 1, 7u32, 1, 36301, 0x46f64282u32, 0x21df072ddb19c417u64, 141),
    (65535, 1, 7u32, 2, 43159, 0x981540cdu32, 0x83bf31a845c8eb27u64, 142),
    (65535, 2, 0u32, 0, 7990, 0x24f6ba6au32, 0x4ffc0e50553460cbu64, 144),
    (65535, 2, 0u32, 1, 7990, 0x24f6ba6au32, 0x4ffc0e50553460cbu64, 145),
    (65535, 2, 0u32, 2, 9893, 0x67ff9251u32, 0x13601519627e2663u64, 146),
    (65535, 2, 7u32, 0, 6560, 0xed2eed3fu32, 0x0a21015356d924b2u64, 148),
    (65535, 2, 7u32, 1, 6560, 0xed2eed3fu32, 0x0a21015356d924b2u64, 149),
    (65535, 2, 7u32, 2, 7953, 0xaad5c296u32, 0x67fc71ca3a537e36u64, 150),
    (65535, 3, 0u32, 0, 267, 0xda906640u32, 0x6e4ac478020b8d34u64, 152),
    (65535, 3, 0u32, 1, 267, 0xda906640u32, 0x6e4ac478020b8d34u64, 153),
    (65535, 3, 0u32, 2, 267, 0xda906640u32, 0x6e4ac478020b8d34u64, 154),
    (65535, 3, 7u32, 0, 267, 0xda906640u32, 0x6e4ac478020b8d34u64, 156),
    (65535, 3, 7u32, 1, 267, 0xda906640u32, 0x6e4ac478020b8d34u64, 157),
    (65535, 3, 7u32, 2, 267, 0xda906640u32, 0x6e4ac478020b8d34u64, 158),
    (65536, 0, 0u32, 0, 65794, 0x0a92397au32, 0x5c8462a7bf58a498u64, -1),
    (65536, 0, 0u32, 1, 65794, 0x0a92397au32, 0x5c8462a7bf58a498u64, -1),
    (65536, 0, 0u32, 2, 65794, 0x0a92397au32, 0x5c8462a7bf58a498u64, -1),
    (65536, 0, 7u32, 0, 65794, 0x97ac44b5u32, 0xe2811b109edf46c4u64, -1),
    (65536, 0, 7u32, 1, 65794, 0x97ac44b5u32, 0xe2811b109edf46c4u64, -1),
    (65536, 0, 7u32, 2, 65794, 0x97ac44b5u32, 0xe2811b109edf46c4u64, -1),
    (65536, 1, 0u32, 0, 36459, 0xcee2d4bau32, 0x38152d09e4a6dc03u64, 168),
    (65536, 1, 0u32, 1, 36459, 0xcee2d4bau32, 0x38152d09e4a6dc03u64, 169),
    (65536, 1, 0u32, 2, 42371, 0x3bd2b7d5u32, 0x51ab75c6e3b53a4bu64, 170),
    (65536, 1, 7u32, 0, 36301, 0x23c335d6u32, 0x2fb95125f201e883u64, 172),
    (65536, 1, 7u32, 1, 36301, 0x23c335d6u32, 0x2fb95125f201e883u64, 173),
    (65536, 1, 7u32, 2, 43159, 0xe625142bu32, 0x932aec96346d49e2u64, 174),
    (65536, 2, 0u32, 0, 7990, 0x07cf5a54u32, 0xd51a175057341acdu64, 176),
    (65536, 2, 0u32, 1, 7990, 0x07cf5a54u32, 0xd51a175057341acdu64, 177),
    (65536, 2, 0u32, 2, 9886, 0x1e81178au32, 0xb63f67735535e91eu64, 178),
    (65536, 2, 7u32, 0, 6560, 0x1d22b405u32, 0x3118e96287656c84u64, 180),
    (65536, 2, 7u32, 1, 6560, 0x1d22b405u32, 0x3118e96287656c84u64, 181),
    (65536, 2, 7u32, 2, 7953, 0x8ee3d375u32, 0xe0fde9699981eea9u64, 182),
    (65536, 3, 0u32, 0, 267, 0x277289ebu32, 0x14e218580c0f5ba9u64, 184),
    (65536, 3, 0u32, 1, 267, 0x277289ebu32, 0x14e218580c0f5ba9u64, 185),
    (65536, 3, 0u32, 2, 267, 0x277289ebu32, 0x14e218580c0f5ba9u64, 186),
    (65536, 3, 7u32, 0, 267, 0x277289ebu32, 0x14e218580c0f5ba9u64, 188),
    (65536, 3, 7u32, 1, 267, 0x277289ebu32, 0x14e218580c0f5ba9u64, 189),
    (65536, 3, 7u32, 2, 267, 0x277289ebu32, 0x14e218580c0f5ba9u64, 190),
    (65537, 0, 0u32, 0, 65795, 0x8cf92a01u32, 0xb1b0b7f4991f7023u64, -1),
    (65537, 0, 0u32, 1, 65795, 0x8cf92a01u32, 0xb1b0b7f4991f7023u64, -1),
    (65537, 0, 0u32, 2, 65795, 0x8cf92a01u32, 0xb1b0b7f4991f7023u64, -1),
    (65537, 0, 7u32, 0, 65795, 0x677ad4b9u32, 0x4b3b2fb8a9320f8fu64, -1),
    (65537, 0, 7u32, 1, 65795, 0x677ad4b9u32, 0x4b3b2fb8a9320f8fu64, -1),
    (65537, 0, 7u32, 2, 65795, 0x677ad4b9u32, 0x4b3b2fb8a9320f8fu64, -1),
    (65537, 1, 0u32, 0, 36459, 0x76045679u32, 0x1aa7283971638263u64, 200),
    (65537, 1, 0u32, 1, 36459, 0x76045679u32, 0x1aa7283971638263u64, 201),
    (65537, 1, 0u32, 2, 42371, 0xdcc6940au32, 0xdc00bf37c2832870u64, 202),
    (65537, 1, 7u32, 0, 36301, 0x2d65bd38u32, 0x56ab98ab9f496768u64, 204),
    (65537, 1, 7u32, 1, 36301, 0x2d65bd38u32, 0x56ab98ab9f496768u64, 205),
    (65537, 1, 7u32, 2, 43159, 0x4e5eff05u32, 0x5c05c58f8c119d02u64, 206),
    (65537, 2, 0u32, 0, 7991, 0x5ced5b43u32, 0x14beb48deeb1e588u64, 208),
    (65537, 2, 0u32, 1, 7991, 0x5ced5b43u32, 0x14beb48deeb1e588u64, 209),
    (65537, 2, 0u32, 2, 9887, 0x0d5095feu32, 0x6d2636d3e666e99du64, 210),
    (65537, 2, 7u32, 0, 6560, 0xe3e25513u32, 0x23389cfe80bd4402u64, 212),
    (65537, 2, 7u32, 1, 6560, 0xe3e25513u32, 0x23389cfe80bd4402u64, 213),
    (65537, 2, 7u32, 2, 7953, 0x990538bcu32, 0xf75c2b9e8a1bb738u64, 214),
    (65537, 3, 0u32, 0, 267, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 216),
    (65537, 3, 0u32, 1, 267, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 217),
    (65537, 3, 0u32, 2, 267, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 218),
    (65537, 3, 7u32, 0, 267, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 220),
    (65537, 3, 7u32, 1, 267, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 221),
    (65537, 3, 7u32, 2, 267, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 222),
    (131072, 0, 0u32, 0, 131587, 0x79e8f630u32, 0x4d07d08494c8307fu64, -1),
    (131072, 0, 0u32, 1, 131587, 0x79e8f630u32, 0x4d07d08494c8307fu64, -1),
    (131072, 0, 0u32, 2, 131587, 0x79e8f630u32, 0x4d07d08494c8307fu64, -1),
    (131072, 0, 7u32, 0, 131587, 0x1e04e7d1u32, 0xf9e315287726f0a7u64, -1),
    (131072, 0, 7u32, 1, 131587, 0x1e04e7d1u32, 0xf9e315287726f0a7u64, -1),
    (131072, 0, 7u32, 2, 131587, 0x1e04e7d1u32, 0xf9e315287726f0a7u64, -1),
    (131072, 1, 0u32, 0, 76310, 0x1d8ec3c9u32, 0x495d931abaa34a6cu64, -1),
    (131072, 1, 0u32, 1, 76310, 0x1d8ec3c9u32, 0x495d931abaa34a6cu64, -1),
    (131072, 1, 0u32, 2, 90645, 0x86ed0724u32, 0x076e6e3222ddbb91u64, -1),
    (131072, 1, 7u32, 0, 76231, 0xea217222u32, 0xc865ab10f26d48bbu64, -1),
    (131072, 1, 7u32, 1, 76231, 0xea217222u32, 0xc865ab10f26d48bbu64, -1),
    (131072, 1, 7u32, 2, 91425, 0xbe6e2ba4u32, 0xd47878da1fe645a5u64, -1),
    (131072, 2, 0u32, 0, 24200, 0xee2f4626u32, 0x183c9f274a7c7b4bu64, 240),
    (131072, 2, 0u32, 1, 24200, 0xee2f4626u32, 0x183c9f274a7c7b4bu64, 241),
    (131072, 2, 0u32, 2, 32092, 0xd73f5c53u32, 0xc6f4e691aca1fcf5u64, 242),
    (131072, 2, 7u32, 0, 16789, 0xaf347eedu32, 0x2a7512c0e8542ccau64, 244),
    (131072, 2, 7u32, 1, 16789, 0xaf347eedu32, 0x2a7512c0e8542ccau64, 245),
    (131072, 2, 7u32, 2, 21985, 0x3c754f77u32, 0x1c7c831d003ed486u64, 246),
    (131072, 3, 0u32, 0, 524, 0x5fb89b06u32, 0x5d85b5212525a475u64, 248),
    (131072, 3, 0u32, 1, 524, 0x5fb89b06u32, 0x5d85b5212525a475u64, 249),
    (131072, 3, 0u32, 2, 524, 0x5fb89b06u32, 0x5d85b5212525a475u64, 250),
    (131072, 3, 7u32, 0, 524, 0x5fb89b06u32, 0x5d85b5212525a475u64, 252),
    (131072, 3, 7u32, 1, 524, 0x5fb89b06u32, 0x5d85b5212525a475u64, 253),
    (131072, 3, 7u32, 2, 524, 0x5fb89b06u32, 0x5d85b5212525a475u64, 254),
]

// cjpm test runs from the repo root; ../corpus covers invocations from src/.
private func readBlockArtifact(rowIdx: Int64): Array<Byte> {
    let s = rowIdx.toString()
    let padded = if (s.size == 1) { "00${s}" } else if (s.size == 2) { "0${s}" } else { s }
    let name = "/block/${padded}.lz4"
    try {
        return File.readFrom("corpus" + name)
    } catch (_: Exception) {
        return File.readFrom("../corpus" + name)
    }
}

@Test
func lz4CompressGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    for ((n, mpIdx, seed, modeIdx, wantSize, want32, want64, fileRow) in BLOCK_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c: Int32 = if (modeIdx == 0) {
            LZ4_compress_default(buf, Int32(n), out, Int32(bound))
        } else {
            LZ4_compress_fast(buf, Int32(n), out, Int32(bound), if (modeIdx == 1) { 1 } else { 8 })
        }
        if (c != wantSize) {
            println("SIZE n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} mode=${modeIdx}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} mode=${modeIdx} size=${c}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (fileRow >= 0) {
            // byte-exact comparison against the C-generated artifact
            let art = readBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            var eq = art.size == Int64(c)
            for (i in 0..Int64(c)) {
                if (UInt8(art[i]) != out[i]) { eq = false; break }
            }
            if (!eq) { println("BYTES differ n=${n} mode=${modeIdx} row=${fileRow}") }
            @Assert(eq)
            fileCompared += 1
        }
        checked += 1
    }
    @Assert(checked == 192)
    @Assert(fileCompared == 162)
    println("golden: ${checked}/192 rows, ${fileCompared} byte-exact artifacts")
}

