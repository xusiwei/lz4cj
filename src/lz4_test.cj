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
// 192 default/fast rows here + 64 dest rows in BLOCK_DEST_REF below).
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

/*-************************************
*  M2 Task 4: LZ4_compress_destSize (fillOutput mode)
**************************************/
// dest rows of corpus/block_golden_ref.txt: target = n*3/4 (gen_golden.c),
// extra field consumed=<k> = C's *srcSizePtr after LZ4_compress_destSize
// (gen_golden presets consumed=n; C leaves it untouched on failure).
// (n, mpIndex, seed, size, consumed, xxh32, xxh64, fileRowIdx), -1 = no artifact
let BLOCK_DEST_REF: Array<(Int64, Int64, UInt32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (0, 0, 0u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 3),
    (0, 0, 7u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 7),
    (0, 1, 0u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 11),
    (0, 1, 7u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 15),
    (0, 2, 0u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 19),
    (0, 2, 7u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 23),
    (0, 3, 0u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 27),
    (0, 3, 7u32, 0, 0, 0x02cc5d05u32, 0xef46db3751d8e999u64, 31),
    (1, 0, 0u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 35),
    (1, 0, 7u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 39),
    (1, 1, 0u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 43),
    (1, 1, 7u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 47),
    (1, 2, 0u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 51),
    (1, 2, 7u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 55),
    (1, 3, 0u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 59),
    (1, 3, 7u32, 0, 1, 0x02cc5d05u32, 0xef46db3751d8e999u64, 63),
    (255, 0, 0u32, 191, 189, 0xac64f922u32, 0x18f7c571d64f08b9u64, 67),
    (255, 0, 7u32, 191, 189, 0x83be41afu32, 0x4bb31c8082b0cba1u64, 71),
    (255, 1, 0u32, 191, 203, 0xbf5e8316u32, 0x6e39a72f483d9a4du64, 75),
    (255, 1, 7u32, 11, 255, 0x3b48606au32, 0x4bee6aad626bda16u64, 79),
    (255, 2, 0u32, 11, 255, 0x387b105fu32, 0x6ade35f444efe462u64, 83),
    (255, 2, 7u32, 11, 255, 0x8ebfdc6du32, 0xf9f9a04a61934aaau64, 87),
    (255, 3, 0u32, 11, 255, 0x83f66756u32, 0x3ed8172ad694afa3u64, 91),
    (255, 3, 7u32, 11, 255, 0x83f66756u32, 0x3ed8172ad694afa3u64, 95),
    (4096, 0, 0u32, 3072, 3059, 0xf04835f6u32, 0xee4020d2c49cbf13u64, 99),
    (4096, 0, 7u32, 3072, 3059, 0x73023f27u32, 0x8397480e5e7db40eu64, 103),
    (4096, 1, 0u32, 2527, 4096, 0x84900dc4u32, 0xc1d36a7b7ae8ce5cu64, 107),
    (4096, 1, 7u32, 1442, 4096, 0x9af1d84eu32, 0xe8758bb9f62bc933u64, 111),
    (4096, 2, 0u32, 443, 4096, 0xcd28d50du32, 0x017e097f399fb1a0u64, 115),
    (4096, 2, 7u32, 350, 4096, 0x0a37027au32, 0xb0b1b7a51c084a07u64, 119),
    (4096, 3, 0u32, 26, 4096, 0x1fc69d86u32, 0xca765317388e8959u64, 123),
    (4096, 3, 7u32, 26, 4096, 0x1fc69d86u32, 0xca765317388e8959u64, 127),
    (65535, 0, 0u32, 49151, 48958, 0x69b425f0u32, 0x3b181318db8a56d9u64, 131),
    (65535, 0, 7u32, 49151, 48958, 0xe35e4e2eu32, 0x482a267c4a002fd1u64, 135),
    (65535, 1, 0u32, 36459, 65535, 0x2fc26585u32, 0xd8e8dcf0914b5f2au64, 139),
    (65535, 1, 7u32, 36301, 65535, 0x46f64282u32, 0x21df072ddb19c417u64, 143),
    (65535, 2, 0u32, 7990, 65535, 0x24f6ba6au32, 0x4ffc0e50553460cbu64, 147),
    (65535, 2, 7u32, 6560, 65535, 0xed2eed3fu32, 0x0a21015356d924b2u64, 151),
    (65535, 3, 0u32, 267, 65535, 0xda906640u32, 0x6e4ac478020b8d34u64, 155),
    (65535, 3, 7u32, 267, 65535, 0xda906640u32, 0x6e4ac478020b8d34u64, 159),
    (65536, 0, 0u32, 49152, 48959, 0x9c18b05bu32, 0x60e7c42ffb71b8b2u64, 163),
    (65536, 0, 7u32, 49152, 48959, 0x6ff324c8u32, 0x19513834e82bd61fu64, 167),
    (65536, 1, 0u32, 36459, 65536, 0xcee2d4bau32, 0x38152d09e4a6dc03u64, 171),
    (65536, 1, 7u32, 36301, 65536, 0x23c335d6u32, 0x2fb95125f201e883u64, 175),
    (65536, 2, 0u32, 7990, 65536, 0x07cf5a54u32, 0xd51a175057341acdu64, 179),
    (65536, 2, 7u32, 6560, 65536, 0x1d22b405u32, 0x3118e96287656c84u64, 183),
    (65536, 3, 0u32, 267, 65536, 0x277289ebu32, 0x14e218580c0f5ba9u64, 187),
    (65536, 3, 7u32, 267, 65536, 0x277289ebu32, 0x14e218580c0f5ba9u64, 191),
    (65537, 0, 0u32, 49152, 48959, 0x9c18b05bu32, 0x60e7c42ffb71b8b2u64, 195),
    (65537, 0, 7u32, 49152, 48959, 0x6ff324c8u32, 0x19513834e82bd61fu64, 199),
    (65537, 1, 0u32, 36459, 65537, 0x76045679u32, 0x1aa7283971638263u64, 203),
    (65537, 1, 7u32, 36301, 65537, 0x2d65bd38u32, 0x56ab98ab9f496768u64, 207),
    (65537, 2, 0u32, 7991, 65537, 0x5ced5b43u32, 0x14beb48deeb1e588u64, 211),
    (65537, 2, 7u32, 6560, 65537, 0xe3e25513u32, 0x23389cfe80bd4402u64, 215),
    (65537, 3, 0u32, 267, 65537, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 219),
    (65537, 3, 7u32, 267, 65537, 0xc4417ed0u32, 0x5271612dbff11fb5u64, 223),
    (131072, 0, 0u32, 98304, 97919, 0x0809cf30u32, 0xe7192940dc962351u64, -1),
    (131072, 0, 7u32, 98304, 97919, 0xd6f1954eu32, 0x409c43d9a4b12bb4u64, -1),
    (131072, 1, 0u32, 76310, 131072, 0x1d8ec3c9u32, 0x495d931abaa34a6cu64, -1),
    (131072, 1, 7u32, 76231, 131072, 0xea217222u32, 0xc865ab10f26d48bbu64, -1),
    (131072, 2, 0u32, 24200, 131072, 0xee2f4626u32, 0x183c9f274a7c7b4bu64, 243),
    (131072, 2, 7u32, 16789, 131072, 0xaf347eedu32, 0x2a7512c0e8542ccau64, 247),
    (131072, 3, 0u32, 524, 131072, 0x5fb89b06u32, 0x5d85b5212525a475u64, 251),
    (131072, 3, 7u32, 524, 131072, 0x5fb89b06u32, 0x5d85b5212525a475u64, 255),
]

@Test
func lz4CompressDestSizeGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    var consumedChecked = 0
    for ((n, mpIdx, seed, wantSize, wantConsumed, want32, want64, fileRow) in BLOCK_DEST_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let target = Int32(n * 3 / 4)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let (c, consumed): (Int32, Int32) = LZ4_compress_destSize(buf, Int32(n), out, target)
        // destSize invariants: output within target, input consumed within srcSize
        if (c < 0 || c > target || consumed < 0 || consumed > Int32(n)) {
            println("INVARIANT n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed}: c=${c} target=${target} consumed=${consumed}")
        }
        @Assert(c >= 0 && c <= target)
        @Assert(consumed >= 0 && consumed <= Int32(n))
        if (c != wantSize) {
            println("SIZE n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        if (consumed != wantConsumed) {
            println("CONSUMED n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed}: got ${consumed} want ${wantConsumed}")
        }
        @Assert(consumed == wantConsumed)
        consumedChecked += 1
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} size=${c}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
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
            if (!eq) { println("BYTES differ n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} row=${fileRow}") }
            @Assert(eq)
            fileCompared += 1
        }
        checked += 1
    }
    @Assert(checked == 64)
    @Assert(consumedChecked == 64)
    @Assert(fileCompared == 60)
    println("dest golden: ${checked}/64 rows, ${consumedChecked} consumed-exact, ${fileCompared} byte-exact artifacts")
}

@Test
func lz4CompressDestSizeTest(): Unit {
    let out = Array<UInt8>(512, {_ => 0u8})
    // target <= 0: C returns 0 and leaves *srcSizePtr at the caller-preset
    // value (lz4.c L994 maxOutputSize<1, L1371 dstCapacity<=0; gen_golden
    // presets consumed=n) -> our contract (0, srcSize)
    let src = Array<UInt8>(255, {_ => 0u8})
    RDG_genBuffer(src, 255, 0.5, 0.0, 0u32)
    let (c0, k0) = LZ4_compress_destSize(src, 255, out, 0)
    @Assert(c0 == 0 && k0 == 255)
    let (cn, kn) = LZ4_compress_destSize(src, 255, out, -3)
    @Assert(cn == 0 && kn == 255)
    // empty input, target >= 1: 1-byte empty block, consumed 0 (L1370-1380)
    let empty = Array<UInt8>(0, {_ => 0u8})
    let (ce, ke) = LZ4_compress_destSize(empty, 0, out, 16)
    @Assert(ce == 1 && ke == 0 && out[0] == 0u8)
    // empty input, target == 0: failure with (0, 0)
    let (ce0, ke0) = LZ4_compress_destSize(empty, 0, out, 0)
    @Assert(ce0 == 0 && ke0 == 0)
    // invariants over both table types (byU16 n<65547, byU32 above)
    let cases: Array<(Int64, Int64, UInt32)> =
        [(255, 0, 0u32), (4096, 1, 7u32), (65536, 2, 0u32), (65537, 3, 7u32)]
    for ((n, mpIdx, seed) in cases) {
        let b = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(b, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let target = Int32(n * 3 / 4)
        let o = Array<UInt8>(Int64(LZ4_compressBound(Int32(n))), {_ => 0u8})
        let (c, k) = LZ4_compress_destSize(b, Int32(n), o, target)
        @Assert(c >= 1 && c <= target)
        @Assert(k >= 0 && k <= Int32(n))
    }
    // target >= compressBound: guaranteed-success delegation to the regular
    // path (lz4.c L1495-1496); *srcSizePtr untouched -> consumed == srcSize,
    // bytes identical to LZ4_compress_default
    let bound = LZ4_compressBound(255)
    let d1 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let d2 = Array<UInt8>(Int64(bound), {_ => 0u8})
    let cd = LZ4_compress_default(src, 255, d1, bound)
    @Assert(cd > 0)
    let (ct, kt) = LZ4_compress_destSize(src, 255, d2, bound)
    @Assert(ct == cd && kt == 255)
    for (i in 0..Int64(ct)) {
        @Assert(d1[i] == d2[i])
    }
}

// Adversarial fillOutput cases from a C probe against upstream 0774d055
// (scripts/dest_probe.c: LZ4_compress_destSize on constant / periodic / LCG
// buffers with small targets; output regenerates these rows verbatim).
// These force the matchCode-reduction (lz4.c L1198-1216), which the
// n*3/4-target corpus rows never reach (mp=0.0 finds no matches; mp>=0.5
// compresses below target). The rewind hash-clearing sub-path inside it
// (L1204-1215) is not reached by these inputs (see CHANGELOG M2 coverage).
// (kind, n, target, size, consumed, xxh32, xxh64)
let DEST_REDUCTION_REF: Array<(Int64, Int64, Int32, Int32, Int32, UInt32, UInt64)> = [
    (0, 4096, 7, 7, 6, 0x6918cab6u32, 0x9caaf84e3e0e5634u64),
    (0, 4096, 20, 20, 2574, 0xcd62f967u32, 0x78c6d71811c93bfau64),
    (0, 4096, 33, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 46, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 59, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 72, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 85, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 98, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 111, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 124, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 137, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 150, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 163, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 176, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 189, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 202, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 215, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 228, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 241, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 254, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 267, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 280, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (0, 4096, 293, 26, 4096, 0x561fd3bdu32, 0x9850b777a413d0d1u64),
    (1, 1000, 7, 7, 6, 0xf063681fu32, 0x1f34c7ec4291d7e8u64),
    (1, 1000, 14, 14, 13, 0xb9c87168u32, 0xe0bcefc03474ffdfu64),
    (1, 1000, 21, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 28, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 35, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 42, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 49, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 56, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 63, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 70, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 77, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 84, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 91, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 98, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 105, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 112, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 119, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 126, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 133, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 140, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 147, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 154, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 161, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 168, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 175, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 182, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 189, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (1, 1000, 196, 20, 1000, 0x671c7560u32, 0xe82922249ae6d671u64),
    (2, 300, 7, 7, 6, 0xad8c3c89u32, 0xed20308c4303c288u64),
    (2, 300, 14, 14, 13, 0x58ceb8c3u32, 0x26ac8d2164dd28d4u64),
    (2, 300, 21, 21, 19, 0x91f33526u32, 0x61993155faa324b1u64),
    (2, 300, 28, 28, 26, 0x6e23372au32, 0x32f425d2cf8ac53eu64),
    (2, 300, 35, 35, 33, 0x116b290du32, 0xcde30184aa54fc69u64),
    (2, 300, 42, 42, 40, 0x214d3499u32, 0x86c4071c979b5670u64),
    (2, 300, 49, 49, 47, 0x934ac3a9u32, 0x90e2344d51a5f1bbu64),
    (2, 300, 56, 56, 54, 0xf0c3aa12u32, 0x9bab1cb8fe47f348u64),
    (2, 300, 63, 63, 61, 0x6128400fu32, 0xe6ff96f6a7466a75u64),
    (2, 300, 70, 70, 68, 0x106e3a0au32, 0x258fb0358540848eu64),
    (2, 300, 77, 77, 75, 0xa481a9f3u32, 0xd9d357c2753dbcc2u64),
    (2, 300, 84, 84, 82, 0xc559e5a6u32, 0x425a676e08158320u64),
    (2, 300, 91, 91, 89, 0x0d184459u32, 0x66d92d44fc6770a0u64),
    (2, 300, 98, 98, 96, 0xbf760cfau32, 0xc429f24655d1a375u64),
    (2, 300, 105, 105, 103, 0x54c69f8eu32, 0x7e5607dbe1c23d04u64),
    (2, 300, 112, 112, 110, 0x0ab1e1cau32, 0xeb5c9b5e12eddf29u64),
    (2, 300, 119, 119, 117, 0x94d665eeu32, 0x933fcce04243daf3u64),
    (3, 5000, 7, 7, 6, 0xb15d9da2u32, 0xc1e69de47dd0beacu64),
    (3, 5000, 14, 14, 29, 0xceb3f5a1u32, 0x952d39e5308a2166u64),
    (3, 5000, 21, 21, 37, 0x985bd464u32, 0xedb3f99afa937274u64),
    (3, 5000, 28, 28, 59, 0xc29a59f3u32, 0x418e184ed20b465du64),
    (3, 5000, 35, 35, 85, 0x149fe968u32, 0x5dc83f64cc44fca9u64),
    (3, 5000, 42, 42, 98, 0x7631a96bu32, 0xe06f8757666a8baeu64),
    (3, 5000, 49, 48, 104, 0x67ae5f57u32, 0xab0b5b42087fb3a2u64),
    (3, 5000, 56, 56, 121, 0x7a458d24u32, 0xcc6e298d152afa37u64),
    (3, 5000, 63, 63, 144, 0x991bb911u32, 0x24e0ff6f86b64333u64),
    (3, 5000, 70, 70, 159, 0x9c71f249u32, 0x3995c659fa3b13fbu64),
    (3, 5000, 77, 77, 173, 0xde83b1b1u32, 0x6140256b7750badeu64),
    (3, 5000, 84, 84, 193, 0x5254acc4u32, 0xbbe13728d3df8c40u64),
    (3, 5000, 91, 91, 201, 0x6ecbabcdu32, 0xbf5c807f09b133cau64),
    (3, 5000, 98, 98, 224, 0x50060b34u32, 0x8ebdfa6c6f73d8eau64),
    (3, 5000, 105, 105, 230, 0x9126e1a5u32, 0x6ac7830048c11ac1u64),
    (3, 5000, 112, 112, 245, 0xdbdcfd54u32, 0xcb8089d39f480f8au64),
    (3, 5000, 119, 119, 259, 0xd473b2d8u32, 0x178e66d5a3bf9ba6u64),
    (3, 5000, 126, 126, 277, 0xa5302290u32, 0xa79879f8ce926c1cu64),
    (3, 5000, 133, 133, 287, 0xf33b15bau32, 0x8aeea38978ccbc07u64),
    (3, 5000, 140, 140, 310, 0x47c5adf3u32, 0xe62cd8803a5d2259u64),
    (3, 5000, 147, 147, 329, 0xd534c41bu32, 0xae262a2db278937au64),
    (3, 5000, 154, 154, 338, 0x7033de41u32, 0x8480d89ddc39f54bu64),
    (3, 5000, 161, 161, 349, 0xb503845eu32, 0x137894a0ca6dd4cfu64),
    (3, 5000, 168, 168, 358, 0x59791269u32, 0x23fd6a0d91ca6f7eu64),
    (3, 5000, 175, 175, 369, 0xd1db5706u32, 0x01eed7ea2071a9beu64),
    (3, 5000, 182, 182, 385, 0xf3124ef5u32, 0xfd9dc2fe522ba179u64),
    (3, 5000, 189, 189, 399, 0x4a4c40e2u32, 0x149e99c3c3276b43u64),
    (3, 5000, 196, 196, 410, 0x395bb2ccu32, 0xdfc6f26130eddb42u64),
    (3, 5000, 203, 203, 421, 0xeb2886beu32, 0x4a264392b420af1au64),
    (3, 5000, 210, 210, 434, 0x3de5ac6au32, 0x54a444f42e9afa4eu64),
    (3, 5000, 217, 217, 443, 0x2b27b23eu32, 0x0aed53410c072e12u64),
    (3, 5000, 224, 224, 456, 0x0d64e52du32, 0x8abe1371e7277133u64),
    (3, 5000, 231, 231, 470, 0x07c3d0c9u32, 0xdcd62ccf1658bb24u64),
    (3, 5000, 238, 238, 496, 0x99349c27u32, 0xf1d63679cd83c9afu64),
    (3, 5000, 245, 245, 510, 0xfaefe5e9u32, 0x9475c42f1ff8cf75u64),
    (3, 5000, 252, 252, 519, 0x1d2f5837u32, 0x981a4b683bf6251du64),
    (3, 5000, 259, 259, 527, 0x1afe1aa3u32, 0xa2a0e0c4b5bc9ea6u64),
    (3, 5000, 266, 266, 535, 0xdacaaf46u32, 0x1e84efb643906b0eu64),
    (3, 5000, 273, 273, 543, 0x08a55f14u32, 0x99a28ac78e43a1ebu64),
    (3, 5000, 280, 280, 557, 0x33a718ecu32, 0xa1c17d8972f4bbf1u64),
    (3, 5000, 287, 287, 576, 0x4d5e962du32, 0x237f82c4749a4d47u64),
    (3, 5000, 294, 294, 589, 0x4e497445u32, 0xa9cc418547a3e1e7u64),
    (3, 5000, 301, 301, 597, 0xbd8dc2f7u32, 0x1bf9476caf556848u64),
    (3, 5000, 308, 308, 603, 0x004089fcu32, 0xc5b4bb7d1cd753f9u64),
    (3, 5000, 315, 315, 612, 0x23c7b034u32, 0x0429bbd214b91108u64),
    (3, 5000, 322, 322, 626, 0xa1d01382u32, 0xb73fa0e5acf3177au64),
    (3, 5000, 329, 329, 639, 0x900c785eu32, 0xf731c44a88683683u64),
    (3, 5000, 336, 336, 649, 0x53fb8102u32, 0xb0fe9f508f998158u64),
    (3, 5000, 343, 343, 670, 0xacca455du32, 0x864e6bb1e704e3e9u64),
    (3, 5000, 350, 350, 678, 0x8887faf9u32, 0xa4b446c71322dd8eu64),
    (3, 5000, 357, 357, 689, 0x716b6cffu32, 0x2de125999156ff7cu64),
    (3, 5000, 364, 364, 701, 0x5ee2a642u32, 0x3643505f9dab9198u64),
    (3, 5000, 371, 371, 707, 0x0e17a01eu32, 0x56735101fff00fc7u64),
    (3, 5000, 378, 378, 732, 0x2d229c80u32, 0xe083a34417b20ef7u64),
    (3, 5000, 385, 385, 740, 0xd070389bu32, 0x1d3041c99b757f9du64),
    (3, 5000, 392, 392, 749, 0x9299e30au32, 0x11a749b40abc1e37u64),
    (3, 5000, 399, 399, 774, 0x20bf7410u32, 0x20ae9132b3f0f656u64),
]

// probe input construction (must match probe.c byte-for-byte)
private func destProbeBuffer(kind: Int64): Array<UInt8> {
    if (kind == 0) {
        return Array<UInt8>(4096, {_ => 65u8})                     // memset 'A'
    }
    if (kind == 1) {
        return Array<UInt8>(1000, {i => UInt8(i % 7)})             // periodic
    }
    if (kind == 2) {
        let b = Array<UInt8>(300, {_ => 0u8})
        var s: UInt32 = 1u32
        for (i in 0..300) {
            s = s * 1103515245u32 + 12345u32
            b[i] = UInt8(s >> 16)
        }
        return b
    }
    let b = Array<UInt8>(5000, {_ => 0u8})
    var s: UInt32 = 42u32
    for (i in 0..5000) {
        s = s * 1103515245u32 + 12345u32
        b[i] = if (((s >> 24) & 7u32) != 0u32) { 120u8 } else { UInt8(s >> 16) }
    }
    return b
}

@Test
func lz4CompressDestSizeReductionTest(): Unit {
    var checked = 0
    var cache: Array<Array<UInt8>> = Array<Array<UInt8>>(4, {_ => Array<UInt8>(0, {_ => 0u8})})
    for ((kind, n, target, wantSize, wantConsumed, want32, want64) in DEST_REDUCTION_REF) {
        if (cache[kind].size == 0) {
            cache[kind] = destProbeBuffer(kind)
        }
        let buf = cache[kind]
        @Assert(buf.size == n)
        let out = Array<UInt8>(8192, {_ => 0u8})
        let (c, consumed): (Int32, Int32) = LZ4_compress_destSize(buf, Int32(n), out, target)
        @Assert(c >= 0 && c <= target)
        @Assert(consumed >= 0 && consumed <= Int32(n))
        if (c != wantSize || consumed != wantConsumed) {
            println("REDUCTION kind=${kind} target=${target}: got (${c}, ${consumed}) want (${wantSize}, ${wantConsumed})")
        }
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST kind=${kind} target=${target} size=${c}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        checked += 1
    }
    @Assert(checked == 125)
    println("reduction golden: ${checked}/125 rows exact (matchCode reduction + hash clear paths)")
}

/*-************************************
*  M2 leftover: tight-capacity golden rows (gen_golden.c mode=tight)
**************************************/
// tight rows of corpus/block_golden_ref.txt (rows 256..263): compress with
// full bound first, then re-encode with dstCapacity = c-1. The encode is
// deterministic, so the capacity-starved retry must bail out -> size=0.
// (n, mpIndex, seed), seed always 0, mp cycles 0.5/0.9/1.0/0.0 over sizes
let BLOCK_TIGHT_REF: Array<(Int64, Int64, UInt32)> = [
    (0, 1, 0u32), (1, 2, 0u32), (255, 3, 0u32), (4096, 0, 0u32),
    (65535, 1, 0u32), (65536, 2, 0u32), (65537, 3, 0u32), (131072, 0, 0u32),
]

@Test
func lz4CompressTightGoldenTest(): Unit {
    var checked = 0
    for ((n, mpIdx, seed) in BLOCK_TIGHT_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), out, Int32(bound))
        @Assert(c > 0)
        let tight = LZ4_compress_default(buf, Int32(n), out, c - 1)
        if (tight != 0) {
            println("TIGHT n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed}: got ${tight} want 0")
        }
        @Assert(tight == 0)
        checked += 1
    }
    @Assert(checked == 8)
    println("tight golden: ${checked}/8 rows size=0")
}

/*-************************************
*  M3 Task 1: LZ4_decompress_safe (golden + error semantics + roundtrip)
**************************************/
@Test
func lz4DecompressGoldenTest(): Unit {
    var decomp = 0
    var destEmpty = 0
    // default/fast rows: artifact decompresses to the full regenerated input
    for ((n, mpIdx, seed, modeIdx, wantSize, want32, want64, fileRow) in BLOCK_REF) {
        if (fileRow < 0) { continue }
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(wantSize))
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let out = Array<UInt8>(n, {_ => 0u8})
        let r = LZ4_decompress_safe(u8art, Int32(wantSize), out, Int32(n))
        if (r != Int32(n)) {
            println("DECOMP n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} mode=${modeIdx} row=${fileRow}: got ${r} want ${n}")
        }
        @Assert(r == Int32(n))
        var eq = true
        for (i in 0..n) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        if (!eq) { println("DECOMP BYTES differ row=${fileRow}") }
        @Assert(eq)
        decomp += 1
    }
    // dest rows: artifact decompresses to the consumed-prefix of the input
    for ((n, mpIdx, seed, wantSize, wantConsumed, want32, want64, fileRow) in BLOCK_DEST_REF) {
        if (fileRow < 0) { continue }
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(wantSize))
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        if (wantSize == 0) {
            // target<=0 failure rows: empty artifact, srcSize==0 -> -1 (L2068)
            let d0 = Array<UInt8>(n, {_ => 0u8})
            @Assert(LZ4_decompress_safe(u8art, 0, d0, Int32(n)) == -1)
            destEmpty += 1
            continue
        }
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let out = Array<UInt8>(Int64(wantConsumed), {_ => 0u8})
        let r = LZ4_decompress_safe(u8art, Int32(wantSize), out, wantConsumed)
        if (r != wantConsumed) {
            println("DECOMP-DEST n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} row=${fileRow}: got ${r} want ${wantConsumed}")
        }
        @Assert(r == wantConsumed)
        var eq = true
        for (i in 0..Int64(wantConsumed)) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        if (!eq) { println("DECOMP-DEST BYTES differ row=${fileRow}") }
        @Assert(eq)
        decomp += 1
    }
    @Assert(decomp == 206)
    @Assert(destEmpty == 16)
    println("decompress golden: ${decomp} artifacts byte-exact, ${destEmpty} empty artifacts -> -1")
}

@Test
func lz4DecompressErrorSemanticsTest(): Unit {
    let dst = Array<UInt8>(64, {_ => 0u8})
    let src = Array<UInt8>(16, {_ => 0u8})
    RDG_genBuffer(src, 16, 0.5, 0.0, 0u32)
    // entry validation: upstream L2035 (outputSize<0 -> -1); srcSize<0 fails alike
    @Assert(LZ4_decompress_safe(src, -1, dst, 64) == -1)
    @Assert(LZ4_decompress_safe(src, 16, dst, -1) == -1)
    // empty input (L2068) -> -1
    @Assert(LZ4_decompress_safe(src, 0, dst, 64) == -1)
    // outputSize==0 special cases (L2063-2067)
    @Assert(LZ4_decompress_safe(src, 16, dst, 0) == -1)
    let emptyBlock = Array<UInt8>(1, {_ => 0u8})
    @Assert(LZ4_decompress_safe(emptyBlock, 1, dst, 0) == 0)
    // handcrafted bad block: litLen nibble 15 but no extension byte ->
    // read_variable_length limit -> error position encoding -(ip)-1 = -2
    let badLitLen = Array<UInt8>(1, {_ => 0xF0u8})
    @Assert(LZ4_decompress_safe(badLitLen, 1, dst, 64) == -2)
    // literals declared (5) exceed remaining input (3) -> -(ip)-1 = -2
    let badLit = Array<UInt8>(4, {_ => 0x41u8})
    badLit[0] = 0x50u8
    @Assert(LZ4_decompress_safe(badLit, 4, dst, 64) == -2)
    // match offset outside buffers: offset=10 > 1 byte of history ->
    // checkOffset error after offset read (ip=4) -> -(ip)-1 = -5
    let badOffset = Array<UInt8>(12, {_ => 0u8})
    badOffset[0] = 0x10u8
    badOffset[1] = 0x41u8
    badOffset[2] = 0x0Au8
    @Assert(LZ4_decompress_safe(badOffset, 12, dst, 64) == -5)
    // truncations of a real artifact (row 64: n=255 mp=0.0 seed=0, 257 bytes)
    let art = readBlockArtifact(64)
    @Assert(art.size == 257)
    let full = Array<UInt8>(257, {i => UInt8(art[i])})
    let out255 = Array<UInt8>(255, {_ => 0u8})
    @Assert(LZ4_decompress_safe(full, 257, out255, 255) == 255)  // positive control
    let cuts: Array<Int32> = [1, 2, 13, 64, 128, 200, 256]
    for (cut in cuts) {
        let trunc = Array<UInt8>(Int64(cut), {i => full[i]})
        let r = LZ4_decompress_safe(trunc, cut, out255, 255)
        if (r >= 0) { println("TRUNC cut=${cut}: got ${r}") }
        @Assert(r < 0)
    }
    // dstCapacity too small for the final literal run -> negative
    let out254 = Array<UInt8>(254, {_ => 0u8})
    @Assert(LZ4_decompress_safe(full, 257, out254, 254) < 0)
    // trailing garbage byte -> last-run exact-consumption check fails
    let padded = Array<UInt8>(258, {i => if (i < 257) { full[i] } else { 0u8 } })
    @Assert(LZ4_decompress_safe(padded, 258, out255, 255) < 0)
    // corrupted extension byte (literal length inflated past input end)
    let corrupt = Array<UInt8>(257, {i => full[i]})
    corrupt[1] = 0xF1u8
    @Assert(LZ4_decompress_safe(corrupt, 257, out255, 255) < 0)
}

@Test
func lz4DecompressRoundtripTest(): Unit {
    // 3 small inputs across table types and content shapes
    let cases: Array<(Int64, Int64, UInt32)> = [(1, 3, 7u32), (255, 1, 0u32), (4096, 2, 7u32)]
    for ((n, mpIdx, seed) in cases) {
        let inBuf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(inBuf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(inBuf, Int32(n), comp, Int32(bound))
        @Assert(c > 0)
        let out = Array<UInt8>(n, {_ => 0u8})
        let r = LZ4_decompress_safe(comp, c, out, Int32(n))
        @Assert(r == Int32(n))
        for (i in 0..n) {
            @Assert(out[i] == inBuf[i])
        }
    }
    // constant-run input: exercises offset<8 incremental tables + long matches
    let ones = Array<UInt8>(300, {_ => 0x5Au8})
    let comp2 = Array<UInt8>(Int64(LZ4_compressBound(300)), {_ => 0u8})
    let c2 = LZ4_compress_default(ones, 300, comp2, LZ4_compressBound(300))
    @Assert(c2 > 0)
    let out2 = Array<UInt8>(300, {_ => 0u8})
    @Assert(LZ4_decompress_safe(comp2, c2, out2, 300) == 300)
    for (i in 0..300) {
        @Assert(out2[i] == 0x5Au8)
    }
}

/*-************************************
*  withPrefix64k guard-exemption condition (review fix)
**************************************/
// The shortcut's unguarded 18-byte match copy (upstream L2257-2259) may only
// bypass `match >= lowPrefix` when the in-buffer prefix is >= 65535 bytes
// (lz4.c:2502, L2742-2747): then offset <= 65535 (u16) implies
// match = op - offset >= dstIdx - 65535 >= lowPrefix, so the exemption is
// mathematically vacuous. Small prefixes keep the guard (upstream
// withSmallPrefix, L2523-2529). These cases drive the internal generic
// directly since LZ4_decompress_safe is always noDict.
@Test
func lz4DecompressPrefixGuardConditionTest(): Unit {
    // Small prefix (16 bytes): offset pointing below lowPrefix must error.
    // Shortcut-path variant (srcSize 20 -> ip < shortiend): match = -5
    // rejected by the guard, falls to _copy_match checkOffset -> -(ip)-1 = -8.
    let dstA = Array<UInt8>(64, {i => if (i < 16) { 0xEEu8 } else { 0u8 }})
    var srcA = Array<UInt8>(20, {_ => 0u8})
    srcA[0] = 0x40u8                                // litLen 4, matchLen 0 (+4)
    srcA[1] = 0x61u8; srcA[2] = 0x62u8; srcA[3] = 0x63u8; srcA[4] = 0x64u8
    srcA[5] = 0x19u8; srcA[6] = 0x00u8              // offset 25 > 20 bytes of history
    let rA = LZ4_decompress_generic(srcA, 20, dstA, 16, 48, false, 0, None<Array<UInt8>>, 0, 0)
    @Assert(rA == -8)
    // Main-path variant (srcSize 13 -> shortcut inactive): offset 21,
    // match = -1 -> checkOffset error at ip=7 -> -8.
    let dstA2 = Array<UInt8>(64, {i => if (i < 16) { 0xEEu8 } else { 0u8 }})
    let srcA2 = Array<UInt8>(13, {_ => 0u8})
    srcA2[0] = 0x40u8
    srcA2[1] = 0x61u8; srcA2[2] = 0x62u8; srcA2[3] = 0x63u8; srcA2[4] = 0x64u8
    srcA2[5] = 0x15u8; srcA2[6] = 0x00u8            // offset 21 > 20 bytes of history
    let rA2 = LZ4_decompress_generic(srcA2, 13, dstA2, 16, 48, false, 0, None<Array<UInt8>>, 0, 0)
    @Assert(rA2 == -8)
    // Large prefix (65535 bytes): the exemption legitimately applies and a
    // prefix-referencing match decodes through the shortcut's fast copy.
    let prefixSize: Int64 = 65535
    let dstB = Array<UInt8>(prefixSize + 64, {i => UInt8(i & 0xFF)})
    var srcB = Array<UInt8>(26, {_ => 0u8})
    srcB[0] = 0x40u8                                // litLen 4, matchLen 0 (+4)
    srcB[1] = 0x57u8; srcB[2] = 0x58u8; srcB[3] = 0x59u8; srcB[4] = 0x5Au8   // W X Y Z
    srcB[5] = 0xFFu8; srcB[6] = 0xFFu8              // offset 65535 -> match = prefix[4]
    srcB[7] = 0xF0u8; srcB[8] = 0x02u8              // last run: litLen 15+2 = 17
    for (i in 0..17) {
        srcB[9 + i] = UInt8(0x30 + (i % 10))        // '0'..'9' pattern
    }
    let rB = LZ4_decompress_generic(srcB, 26, dstB, prefixSize, 64, false, 0, None<Array<UInt8>>, 0, 0)
    @Assert(rB == 25)
    @Assert(dstB[prefixSize] == 0x57u8 && dstB[prefixSize + 3] == 0x5Au8)          // literals 1
    @Assert(dstB[prefixSize + 4] == 0x04u8 && dstB[prefixSize + 7] == 0x07u8)      // prefix[4..8)
    for (i in 0..17) {
        @Assert(dstB[prefixSize + 8 + i] == UInt8(0x30 + (i % 10)))                // literals 2
    }
}

/*-************************************
*  M3 Task 2: safe_partial + usingDict + bidirectional golden closure
**************************************/
// Shared dictionary provenance (manifest '#' comment line): one 64KB RDG
// dictionary (mp=0.5 lp=0.0 seed=99), independent of every row input. The C
// harness loads it via LZ4_loadDict on a fresh stream and compresses each
// dict-row input with LZ4_compress_fast_continue(accel=1).
let BLOCK_DICT_XXH32: UInt32 = 0x059edec2u32
let BLOCK_DICT_XXH64: UInt64 = 0xd41565bb0ecfa4e3u64

private func blockDictBuffer(): Array<UInt8> {
    let dict = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(dict, 65536, 0.5, 0.0, 99u32)
    return dict
}

// dict rows of corpus/block_golden_ref.txt (rows 264..279):
// (n, mpIndex, seed, size, xxh32, xxh64, inxxh32, inxxh64, fileRowIdx);
// -1 = digest-only (compressed size 65794 > 65536 artifact cap)
let BLOCK_DICT_REF: Array<(Int64, Int64, UInt32, Int32, UInt32, UInt64, UInt32, UInt64, Int64)> = [
    (255, 0, 0u32, 257, 0x42be5aa6u32, 0x1fb93d0dad1a834du64, 0x6e96b077u32, 0xefd4dc746ff90d2eu64, 264),
    (255, 0, 7u32, 257, 0x0ed29158u32, 0xb4f125c8c1816af3u64, 0x45fd394bu32, 0x7c8719724e691375u64, 265),
    (255, 2, 0u32, 11, 0x387b105fu32, 0x6ade35f444efe462u64, 0xcbe2766cu32, 0xd1074591b2fa8835u64, 266),
    (255, 2, 7u32, 11, 0x8ebfdc6du32, 0xf9f9a04a61934aaau64, 0xe9da7969u32, 0xe9e6f65ad9880591u64, 267),
    (4096, 0, 0u32, 4114, 0x754fae48u32, 0xb179757c99f97c27u64, 0xfc2fdd05u32, 0xd93027eb00db934au64, 268),
    (4096, 0, 7u32, 4114, 0x833d749cu32, 0xeacc7240615d52b9u64, 0x3b449358u32, 0x560614d60dbfda09u64, 269),
    (4096, 2, 0u32, 430, 0x7d74865au32, 0x69cf680a1dbbdcefu64, 0xf3a05cfbu32, 0x03cce69c58e99124u64, 270),
    (4096, 2, 7u32, 346, 0x30a3b241u32, 0x10b879caee3ec6e3u64, 0xf3fe2cedu32, 0x086503c70d062006u64, 271),
    (65536, 0, 0u32, 65794, 0x0a92397au32, 0x5c8462a7bf58a498u64, 0x00d020c6u32, 0xe5445c011d57719au64, -1),
    (65536, 0, 7u32, 65794, 0x97ac44b5u32, 0xe2811b109edf46c4u64, 0xf0915266u32, 0x63afd095c366d56cu64, -1),
    (65536, 2, 0u32, 8234, 0xc136ac72u32, 0x906c947bd934425du64, 0x7cf903fcu32, 0x05cbf98ef5fd4a64u64, 274),
    (65536, 2, 7u32, 6723, 0x7c9ce9adu32, 0x6742dc7714939a86u64, 0x99ba8de1u32, 0x3a798cd5ac65353fu64, 275),
    (65537, 1, 3u32, 33264, 0x8e344bd3u32, 0x33e51ce12311b1c1u64, 0xf41b4e18u32, 0xf2b3c896a454d62du64, 276),
    (131072, 2, 11u32, 21159, 0x3beac038u32, 0x9a80ebc174b2be56u64, 0x6d942ca2u32, 0x0b321ffc57f0e3a2u64, 277),
    (1, 3, 5u32, 2, 0xec56599fu32, 0xac2fbabfc9927380u64, 0xcf65b03eu32, 0xe934a84adb052768u64, 278),
    (0, 0, 0u32, 1, 0xcf65b03eu32, 0xe934a84adb052768u64, 0x02cc5d05u32, 0xef46db3751d8e999u64, 279),
]

@Test
func lz4DecompressUsingDictGoldenTest(): Unit {
    let dict = blockDictBuffer()
    // dictionary provenance: regenerated dict digests match the manifest comment
    @Assert(XXH32(dict, 65536, 0u32) == BLOCK_DICT_XXH32)
    @Assert(XXH64(dict, 65536, 0u64) == BLOCK_DICT_XXH64)
    var byteExact = 0
    var digestOnly = 0
    for ((n, mpIdx, seed, wantSize, want32, want64, wantIn32, wantIn64, fileRow) in BLOCK_DICT_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        // input digests close against the manifest v2 inxxh fields
        @Assert(XXH32(buf, n, 0u32) == wantIn32)
        @Assert(XXH64(buf, n, 0u64) == wantIn64)
        if (fileRow < 0) {
            // digest-only rows (mp=0.0, c=65794 > 65536): no artifact on disk
            digestOnly += 1
            continue
        }
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(wantSize))
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        // artifact bytes pinned by the C-side compressed digests
        @Assert(XXH32(u8art, Int64(wantSize), 0u32) == want32)
        @Assert(XXH64(u8art, Int64(wantSize), 0u64) == want64)
        let out = Array<UInt8>(n, {_ => 0u8})
        let r = LZ4_decompress_safe_usingDict(u8art, wantSize, out, Int32(n), dict, 65536)
        if (r != Int32(n)) {
            println("DICT n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed} row=${fileRow}: got ${r} want ${n}")
        }
        @Assert(r == Int32(n))
        var eq = true
        for (i in 0..n) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        if (!eq) { println("DICT BYTES differ row=${fileRow}") }
        @Assert(eq)
        byteExact += 1
    }
    @Assert(byteExact == 14)
    @Assert(digestOnly == 2)
    // dict-referencing block without the dictionary must fail (C probe:
    // partialnodict row=270 -> -134): offsets reach below the output start
    let art270 = readBlockArtifact(270)
    let u8art270 = Array<UInt8>(art270.size, {i => UInt8(art270[i])})
    let out270 = Array<UInt8>(4096, {_ => 0u8})
    @Assert(LZ4_decompress_safe(u8art270, 430, out270, 4096) == -134)
    // dictSize=0 routes to the plain noDict path (upstream L2739-2742)
    @Assert(LZ4_decompress_safe_usingDict(u8art270, 430, out270, 4096, dict, 0) == -134)
    println("dict golden: ${byteExact} byte-exact + ${digestOnly} digest-only rows")
}

// Partial probe constants (gen_golden.c stderr section): rows 64 / 112 / 248
// (plain default-mode artifacts) and dict row 270, targets {0,1,n/2,n-1,n},
// dstCapacity = n so the effective capacity is purely target-driven.
// (kind 0=plain 1=dict, n, mpIndex, seed, rowIdx, target, expectedRet)
let PARTIAL_PROBE_REF: Array<(Int64, Int64, Int64, UInt32, Int64, Int32, Int32)> = [
    (0, 255, 0, 0u32, 64, 0, 0),
    (0, 255, 0, 0u32, 64, 1, 1),
    (0, 255, 0, 0u32, 64, 127, 127),
    (0, 255, 0, 0u32, 64, 254, 254),
    (0, 255, 0, 0u32, 64, 255, 255),
    (0, 4096, 2, 0u32, 112, 0, 0),
    (0, 4096, 2, 0u32, 112, 1, 1),
    (0, 4096, 2, 0u32, 112, 2048, 2048),
    (0, 4096, 2, 0u32, 112, 4095, 4095),
    (0, 4096, 2, 0u32, 112, 4096, 4096),
    (0, 131072, 3, 0u32, 248, 0, 0),
    (0, 131072, 3, 0u32, 248, 1, 1),
    (0, 131072, 3, 0u32, 248, 65536, 65536),
    (0, 131072, 3, 0u32, 248, 131071, 131071),
    (0, 131072, 3, 0u32, 248, 131072, 131072),
    (1, 4096, 2, 0u32, 270, 0, 0),
    (1, 4096, 2, 0u32, 270, 1, 1),
    (1, 4096, 2, 0u32, 270, 2048, 2048),
    (1, 4096, 2, 0u32, 270, 4095, 4095),
    (1, 4096, 2, 0u32, 270, 4096, 4096),
]

@Test
func lz4DecompressSafePartialGoldenTest(): Unit {
    let dict = blockDictBuffer()
    var checked = 0
    for ((kind, n, mpIdx, seed, row, target, wantRet) in PARTIAL_PROBE_REF) {
        let art = readBlockArtifact(row)
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let out = Array<UInt8>(n, {_ => 0u8})
        let r = if (kind == 1) {
            LZ4_decompress_safe_partial_usingDict(u8art, Int32(art.size), out, Int32(n),
                target, dict, 65536)
        } else {
            LZ4_decompress_safe_partial(u8art, Int32(art.size), out, Int32(n), target)
        }
        if (r != wantRet) {
            println("PARTIAL row=${row} target=${target}: got ${r} want ${wantRet}")
        }
        @Assert(r == wantRet)
        // upstream partial semantics: early stop, actual production <= target
        @Assert(r <= target && r <= Int32(n))
        var eq = true
        for (i in 0..Int64(r)) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        if (!eq) { println("PARTIAL PREFIX differs row=${row} target=${target}") }
        @Assert(eq)
        checked += 1
    }
    @Assert(checked == 20)
    println("partial golden: ${checked}/20 probe rows exact (incl. 5 dict-partial)")
}

@Test
func lz4DecompressSafePartialSemanticsTest(): Unit {
    let dst = Array<UInt8>(64, {_ => 0u8})
    // literals-only block (token litLen=10 + 'a'..'j'), 11 bytes
    let litOnly = Array<UInt8>(11, {i => if (i == 0) { 0xA0u8 } else { UInt8(96 + i) }})
    // target beyond full content: decode stops at input end -> ret < target
    @Assert(LZ4_decompress_safe_partial(litOnly, 11, dst, 20, 20) == 10)
    for (i in 0..10) {
        @Assert(dst[i] == UInt8(97 + i))
    }
    // target cut mid-literals: clamp to oend = target (C probe B)
    @Assert(LZ4_decompress_safe_partial(litOnly, 11, dst, 20, 4) == 4)
    for (i in 0..4) {
        @Assert(dst[i] == UInt8(97 + i))
    }
    // dstCapacity < target: cap = MIN(target, dstCapacity) (C probe G)
    @Assert(LZ4_decompress_safe_partial(litOnly, 11, dst, 3, 20) == 3)
    // valid match block: 4 literals + offset-4 match(4) + 5 last literals
    // (13 out: "abcdabcdabcde"); targets cut mid-match (C probe C-series)
    let blk = Array<UInt8>(13, {_ => 0u8})
    blk[0] = 0x40u8
    blk[1] = 0x61u8; blk[2] = 0x62u8; blk[3] = 0x63u8; blk[4] = 0x64u8
    blk[5] = 0x04u8; blk[6] = 0x00u8
    blk[7] = 0x50u8
    blk[8] = 0x61u8; blk[9] = 0x62u8; blk[10] = 0x63u8; blk[11] = 0x64u8; blk[12] = 0x65u8
    // full decode is "abcdabcdabcde": 4 literals + overlap match + 5 literals
    let wantFull = Array<UInt8>(13, {i => if (i < 12) { UInt8(97 + i % 4) } else { 101u8 }})
    let targets: Array<Int32> = [0, 1, 6, 7, 12, 13]
    for (t in targets) {
        let r = LZ4_decompress_safe_partial(blk, 13, dst, 20, t)
        if (r != t) {
            println("PARTIAL-SEM target=${t}: got ${r} want ${t}")
        }
        @Assert(r == t)
        for (i in 0..Int64(r)) {
            @Assert(dst[i] == wantFull[i])
        }
    }
    // cap < target on the match block (C probe: cap5 ret 5)
    @Assert(LZ4_decompress_safe_partial(blk, 13, dst, 5, 10) == 5)
    // empty block token with target > 0 -> 0 (no content)
    let emptyBlock = Array<UInt8>(1, {_ => 0u8})
    @Assert(LZ4_decompress_safe_partial(emptyBlock, 1, dst, 64, 5) == 0)
    // target 0 -> immediate 0 (outputSize==0 partial special case, L2064)
    @Assert(LZ4_decompress_safe_partial(litOnly, 11, dst, 64, 0) == 0)
    // negative target / negative dstCapacity / empty input -> -1
    @Assert(LZ4_decompress_safe_partial(litOnly, 11, dst, 64, -3) == -1)
    @Assert(LZ4_decompress_safe_partial(litOnly, 11, dst, -1, 5) == -1)
    @Assert(LZ4_decompress_safe_partial(litOnly, 0, dst, 5, 5) == -1)
    // usingDict with dictSize=0 delegates to the noDict paths (L2739-2742,
    // L2754-2756): C probe D0 -> 13, PD0 -> 7
    let anyDict = Array<UInt8>(11, {_ => 0u8})
    @Assert(LZ4_decompress_safe_usingDict(blk, 13, dst, 20, anyDict, 0) == 13)
    @Assert(LZ4_decompress_safe_partial_usingDict(blk, 13, dst, 20, 7, anyDict, 0) == 7)
    // dictSize > dict.size: undefined in C (assert); defensive -1
    @Assert(LZ4_decompress_safe_usingDict(blk, 13, dst, 20, anyDict, 12) == -1)
    @Assert(LZ4_decompress_safe_partial_usingDict(blk, 13, dst, 20, 7, anyDict, 12) == -1)
    @Assert(LZ4_decompress_safe_usingDict(blk, 13, dst, 20, anyDict, -1) == -1)
}

// L3 input digests: manifest v2 inxxh32/inxxh64 of the 64 matrix inputs
// (one per (n, mp, seed); the 4 mode rows of an input share the fields).
// (n, mpIndex, seed, inxxh32, inxxh64)
let BLOCK_IN_REF: Array<(Int64, Int64, UInt32, UInt32, UInt64)> = [
    (0, 0, 0u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 0, 7u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 1, 0u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 1, 7u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 2, 0u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 2, 7u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 3, 0u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (0, 3, 7u32, 0x02cc5d05u32, 0xef46db3751d8e999u64),
    (1, 0, 0u32, 0x9608f5fbu32, 0x50bd57c8fab35779u64),
    (1, 0, 7u32, 0x28d0ed78u32, 0xf8108221c3d40e21u64),
    (1, 1, 0u32, 0x06e7e66fu32, 0x122ebd68645a7cf7u64),
    (1, 1, 7u32, 0xfa21d689u32, 0x2c3f836a5df75b04u64),
    (1, 2, 0u32, 0x9cec73c4u32, 0x26167c2af5162ca4u64),
    (1, 2, 7u32, 0x68fcf025u32, 0xad4662bb7caac864u64),
    (1, 3, 0u32, 0xcf65b03eu32, 0xe934a84adb052768u64),
    (1, 3, 7u32, 0xcf65b03eu32, 0xe934a84adb052768u64),
    (255, 0, 0u32, 0x6e96b077u32, 0xefd4dc746ff90d2eu64),
    (255, 0, 7u32, 0x45fd394bu32, 0x7c8719724e691375u64),
    (255, 1, 0u32, 0xf125f7b1u32, 0x42bbcae5695ca49eu64),
    (255, 1, 7u32, 0x2110dfcfu32, 0x28c09d2b78a828b9u64),
    (255, 2, 0u32, 0xcbe2766cu32, 0xd1074591b2fa8835u64),
    (255, 2, 7u32, 0xe9da7969u32, 0xe9e6f65ad9880591u64),
    (255, 3, 0u32, 0x769746c1u32, 0x5baf79c705ca1e7bu64),
    (255, 3, 7u32, 0x769746c1u32, 0x5baf79c705ca1e7bu64),
    (4096, 0, 0u32, 0xfc2fdd05u32, 0xd93027eb00db934au64),
    (4096, 0, 7u32, 0x3b449358u32, 0x560614d60dbfda09u64),
    (4096, 1, 0u32, 0x67fcb522u32, 0xc530a1f18ea87157u64),
    (4096, 1, 7u32, 0x11f9c7b1u32, 0x3f129fb9d09bd2f0u64),
    (4096, 2, 0u32, 0xf3a05cfbu32, 0x03cce69c58e99124u64),
    (4096, 2, 7u32, 0xf3fe2cedu32, 0x086503c70d062006u64),
    (4096, 3, 0u32, 0x475546f5u32, 0xac869b6f32d8bbdbu64),
    (4096, 3, 7u32, 0x475546f5u32, 0xac869b6f32d8bbdbu64),
    (65535, 0, 0u32, 0xacac7fa8u32, 0x97973365ddafb017u64),
    (65535, 0, 7u32, 0x0d21db5cu32, 0x6fcf4b749073d583u64),
    (65535, 1, 0u32, 0xf0bf1c6cu32, 0xf127d3849da6da49u64),
    (65535, 1, 7u32, 0x128bbb3eu32, 0xce89b0df55295419u64),
    (65535, 2, 0u32, 0x0bb6ca95u32, 0xbc83143838535470u64),
    (65535, 2, 7u32, 0x3d38c793u32, 0x196e3819440e484eu64),
    (65535, 3, 0u32, 0x705c5ed7u32, 0xbef1ace972e53997u64),
    (65535, 3, 7u32, 0x705c5ed7u32, 0xbef1ace972e53997u64),
    (65536, 0, 0u32, 0x00d020c6u32, 0xe5445c011d57719au64),
    (65536, 0, 7u32, 0xf0915266u32, 0x63afd095c366d56cu64),
    (65536, 1, 0u32, 0xc20f7bccu32, 0x197a59a7c9d2bd88u64),
    (65536, 1, 7u32, 0x93e70ff8u32, 0x834be9316bc7c3c5u64),
    (65536, 2, 0u32, 0x7cf903fcu32, 0x05cbf98ef5fd4a64u64),
    (65536, 2, 7u32, 0x99ba8de1u32, 0x3a798cd5ac65353fu64),
    (65536, 3, 0u32, 0x0f64e81cu32, 0x5983dda9f15715a4u64),
    (65536, 3, 7u32, 0x0f64e81cu32, 0x5983dda9f15715a4u64),
    (65537, 0, 0u32, 0x94b6c259u32, 0x8fcd923d28220cb1u64),
    (65537, 0, 7u32, 0xe43f0302u32, 0x022ba9266b995f9eu64),
    (65537, 1, 0u32, 0xeffc6527u32, 0xf31e6398ce4e2a55u64),
    (65537, 1, 7u32, 0x6cd9f06bu32, 0x42f5efd30f60f947u64),
    (65537, 2, 0u32, 0xb785f3dcu32, 0x6e16431cf522c012u64),
    (65537, 2, 7u32, 0x818d4a31u32, 0x3b688446e0b2b94eu64),
    (65537, 3, 0u32, 0xa4ae77cdu32, 0x9fa5da74f6ecb3f3u64),
    (65537, 3, 7u32, 0xa4ae77cdu32, 0x9fa5da74f6ecb3f3u64),
    (131072, 0, 0u32, 0x1498b8b4u32, 0x9ea2ebaf54626d76u64),
    (131072, 0, 7u32, 0x78bde30fu32, 0x1c029bd61e6499cau64),
    (131072, 1, 0u32, 0xd184759eu32, 0xc55a7b0a4dd34d71u64),
    (131072, 1, 7u32, 0x2c97344au32, 0x9c4153ebc8cfb2a3u64),
    (131072, 2, 0u32, 0xbf1377f2u32, 0x683af1c226081890u64),
    (131072, 2, 7u32, 0xd32b2e99u32, 0xda4a4d3650f8293cu64),
    (131072, 3, 0u32, 0xf986c077u32, 0xe12ecc387a955073u64),
    (131072, 3, 7u32, 0xf986c077u32, 0xe12ecc387a955073u64),
]

@Test
func lz4DecompressL3DigestClosureTest(): Unit {
    // Bidirectional digest closure: (a) our RDG regenerates the C inputs
    // byte-exactly (input digests == manifest v2 inxxh), (b) our
    // compress_default -> decompress_safe pipeline reproduces content whose
    // digests equal the C-recorded input digests. Covers every matrix input
    // incl. the 131072 rows that have no on-disk artifact.
    var closed = 0
    for ((n, mpIdx, seed, wantIn32, wantIn64) in BLOCK_IN_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let gotIn32 = XXH32(buf, n, 0u32)
        let gotIn64 = XXH64(buf, n, 0u64)
        if (gotIn32 != wantIn32 || gotIn64 != wantIn64) {
            println("IN-DIGEST n=${n} mp=${BLOCK_MPS[mpIdx]} seed=${seed}: got ${blkHex32(gotIn32)}/${blkHex64(gotIn64)} want ${blkHex32(wantIn32)}/${blkHex64(wantIn64)}")
        }
        @Assert(gotIn32 == wantIn32)
        @Assert(gotIn64 == wantIn64)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
        @Assert(c > 0)
        let out = Array<UInt8>(n, {_ => 0u8})
        let r = LZ4_decompress_safe(comp, c, out, Int32(n))
        @Assert(r == Int32(n))
        @Assert(XXH32(out, n, 0u32) == wantIn32)
        @Assert(XXH64(out, n, 0u64) == wantIn64)
        closed += 1
    }
    @Assert(closed == 64)
    println("L3 digest closure: ${closed}/64 inputs (compress->decompress digests == C-recorded)")
}

@Test
func lz4DecompressL2FullRoundtripTest(): Unit {
    // Full-matrix roundtrip over all 264 manifest rows: our compressor ->
    // our decompressor reproduces the input (dest rows: the consumed prefix;
    // tight rows: the full-bound encode that the size=0 retry starves).
    var rows = 0
    for ((n, mpIdx, seed, modeIdx, wantSize, _, _, _) in BLOCK_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = if (modeIdx == 0) {
            LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
        } else {
            LZ4_compress_fast(buf, Int32(n), comp, Int32(bound), if (modeIdx == 1) { 1 } else { 8 })
        }
        @Assert(c == wantSize)
        let out = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(comp, c, out, Int32(n)) == Int32(n))
        var eq = true
        for (i in 0..n) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        @Assert(eq)
        rows += 1
    }
    for ((n, mpIdx, seed, _, wantConsumed, _, _, _) in BLOCK_DEST_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let target = Int32(n * 3 / 4)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let (c, consumed) = LZ4_compress_destSize(buf, Int32(n), comp, target)
        @Assert(c >= 0)
        @Assert(consumed == wantConsumed)
        let out = Array<UInt8>(n, {_ => 0u8})
        if (c == 0) {
            // target<=0 failure rows (n=0: consumed 0; n=1: preset consumed=1):
            // empty compressed block -> -1 (L2068)
            @Assert(LZ4_decompress_safe(comp, 0, out, consumed) == -1)
            rows += 1
            continue
        }
        @Assert(LZ4_decompress_safe(comp, c, out, consumed) == consumed)
        var eq = true
        for (i in 0..Int64(consumed)) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        @Assert(eq)
        rows += 1
    }
    for ((n, mpIdx, seed) in BLOCK_TIGHT_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
        @Assert(c > 0)
        let out = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(comp, c, out, Int32(n)) == Int32(n))
        var eq = true
        for (i in 0..n) {
            if (out[i] != buf[i]) { eq = false; break }
        }
        @Assert(eq)
        rows += 1
    }
    @Assert(rows == 264)
    println("L2 roundtrip: ${rows}/264 rows byte-exact (192 default/fast + 64 dest + 8 tight)")
}
