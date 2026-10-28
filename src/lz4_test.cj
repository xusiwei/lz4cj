// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

import std.unittest.*
import std.fs.*
import std.time.MonoTime
import std.env.getVariable

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
// Embedded from corpus/block_golden_ref.txt (probes/gen_golden.c, 256 rows;
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
// (probes/dest_probe.c: LZ4_compress_destSize on constant / periodic / LCG
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

/*-************************************
*  M3 Task 3: fast decode loop — safe/fast differential validation
**************************************/
// Knuth-style LCG for parameter sweeps (content still via RDG_genBuffer).
private func diffLcgNext(x: UInt64): UInt64 {
    return x * 6364136223846793005u64 + 1442695040888963407u64
}

// forced-safe decompression (LZ4_FAST_DEC_LOOP=0 build equivalent)
private func diffSafe(comp: Array<UInt8>, c: Int64, out: Array<UInt8>, n: Int64): Int64 {
    return LZ4_decompress_generic_forced(comp, c, out, 0, n, false, 0, None<Array<UInt8>>, 0, 0, true)
}

// forced-fast decompression (upstream x86-64/aarch64 default build: fast loop
// whenever oend-op >= FASTLOOP_SAFE_DISTANCE)
private func diffFast(comp: Array<UInt8>, c: Int64, out: Array<UInt8>, n: Int64): Int64 {
    return LZ4_decompress_generic_forced(comp, c, out, 0, n, false, 0, None<Array<UInt8>>, 0, 0, false)
}

private func diffSafeDict(comp: Array<UInt8>, c: Int64, out: Array<UInt8>, n: Int64,
        dict: Array<UInt8>, dictSize: Int64): Int64 {
    return LZ4_decompress_generic_forced(comp, c, out, 0, n, false, 0, Some(dict), 0, dictSize, true)
}

private func diffFastDict(comp: Array<UInt8>, c: Int64, out: Array<UInt8>, n: Int64,
        dict: Array<UInt8>, dictSize: Int64): Int64 {
    return LZ4_decompress_generic_forced(comp, c, out, 0, n, false, 0, Some(dict), 0, dictSize, false)
}

// 合成流编码器:序列(litLen 0..10, offset ∈ [1, min(65535, op+dictHist)],
// matchLen 4..15) + 尾部 ≥5 字面量(精确吃尽)。dictHist = 解码时可用的
// 输出前历史(in-block 前缀或外字典尺寸);仅要求流合法,输出无外部参考,
// 以 safe 路径(golden 已验证)为差分基准。
private func diffSynthStream(n: Int64, dictHist: Int64, r0: UInt64): (Array<UInt8>, Int64) {
    let bound = n + n / 255 + 64
    let comp = Array<UInt8>(bound, {_ => 0u8})
    var c: Int64 = 0
    var op: Int64 = 0
    var r = r0
    while (n - op > 40) {
        let litLen = Int64(r % 11u64)
        r = diffLcgNext(r)
        let ml = Int64(r % 12u64) + 4
        r = diffLcgNext(r)
        let histLim: Int64 = op + dictHist
        let maxOff: Int64 = if (histLim > 65535) { 65535 } else { histLim }
        if (maxOff < 1) {
            // 无历史:纯字面量步进
            let fill = if (n - op - 40 < 10) { n - op - 40 } else { 10 }
            comp[c] = UInt8(fill << 4)
            c += 1
            var i: Int64 = 0
            while (i < fill) {
                comp[c] = UInt8(r % 251u64)
                r = diffLcgNext(r)
                c += 1
                i += 1
            }
            op += fill
            continue
        }
        let off = Int64(r % UInt64(maxOff)) + 1
        r = diffLcgNext(r)
        comp[c] = UInt8((litLen << 4) | (ml - 4))
        c += 1
        var i: Int64 = 0
        while (i < litLen) {
            comp[c] = UInt8(r % 251u64)
            r = diffLcgNext(r)
            c += 1
            i += 1
        }
        comp[c] = UInt8(off % 256)
        comp[c + 1] = UInt8(off / 256)
        c += 2
        op += litLen + ml
    }
    // 尾部字面量 run(此处 last ≥ 16 ≥ LASTLITERALS)
    let last = n - op
    if (last >= 15) {
        var len = last - 15
        comp[c] = 0xF0u8
        c += 1
        while (len >= 255) {
            comp[c] = 255u8
            c += 1
            len -= 255
        }
        comp[c] = UInt8(len)
        c += 1
    } else {
        comp[c] = UInt8(last << 4)
        c += 1
    }
    var i: Int64 = 0
    while (i < last) {
        comp[c] = UInt8(r % 251u64)
        r = diffLcgNext(r)
        c += 1
        i += 1
    }
    return (comp, c)
}

@Test
func lz4DecompressDifferentialGoldenTest(): Unit {
    var rows = 0
    // 192 default/fast rows: on-disk artifact via both paths; digest-only rows
    // (no artifact) use our compress_default output as the stream.
    for ((n, mpIdx, seed, modeIdx, wantSize, _, _, fileRow) in BLOCK_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let u8: Array<UInt8>
        let c: Int64
        if (fileRow >= 0) {
            let art = readBlockArtifact(fileRow)
            @Assert(art.size == Int64(wantSize))
            u8 = Array<UInt8>(art.size, {i => UInt8(art[i])})
            c = Int64(wantSize)
        } else {
            let bound = Int64(LZ4_compressBound(Int32(n)))
            let comp = Array<UInt8>(bound, {_ => 0u8})
            let cc: Int32 = if (modeIdx == 0) {
                LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
            } else {
                LZ4_compress_fast(buf, Int32(n), comp, Int32(bound), if (modeIdx == 1) { 1 } else { 8 })
            }
            @Assert(cc == wantSize)
            u8 = comp
            c = Int64(cc)
        }
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        let rS = diffSafe(u8, c, outS, n)
        let rF = diffFast(u8, c, outF, n)
        if (rS != rF || rS != n) {
            println("DIFF row=${fileRow} n=${n} mode=${modeIdx}: safe=${rS} fast=${rF}")
        }
        @Assert(rS == rF && rS == n)
        var eq = true
        for (i in 0..n) {
            if (outS[i] != outF[i]) { eq = false; break }
        }
        if (!eq) { println("DIFF BYTES row=${fileRow} n=${n}") }
        @Assert(eq)
        rows += 1
    }
    // 64 dest rows: artifact (fileRow >= 0) decodes to the consumed prefix;
    // digest-only rows self-compress via LZ4_compress_destSize (L2 pattern)
    for ((n, mpIdx, seed, wantSize, wantConsumed, _, _, fileRow) in BLOCK_DEST_REF) {
        let u8: Array<UInt8>
        let c: Int64
        let expect: Int64
        if (fileRow >= 0) {
            let art = readBlockArtifact(fileRow)
            u8 = Array<UInt8>(art.size, {i => UInt8(art[i])})
            c = Int64(wantSize)
            expect = Int64(wantConsumed)
        } else {
            let buf = Array<UInt8>(n, {_ => 0u8})
            RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
            let target = Int32(n * 3 / 4)
            let bound = Int64(LZ4_compressBound(Int32(n)))
            let comp = Array<UInt8>(bound, {_ => 0u8})
            let (cc, consumed) = LZ4_compress_destSize(buf, Int32(n), comp, target)
            @Assert(cc >= 0)
            u8 = comp
            c = Int64(cc)
            expect = Int64(consumed)
        }
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        let rS = diffSafe(u8, c, outS, n)
        let rF = diffFast(u8, c, outF, n)
        if (wantSize == 0) {
            // empty artifacts: srcSize 0 -> both -1 (L2068)
            @Assert(rS == -1 && rF == -1)
        } else {
            if (rS != rF || rS != expect) {
                println("DIFF-DEST row=${fileRow} n=${n}: safe=${rS} fast=${rF} want=${expect}")
            }
            @Assert(rS == rF && rS == expect)
            var eq = true
            for (i in 0..expect) {
                if (outS[i] != outF[i]) { eq = false; break }
            }
            @Assert(eq)
        }
        rows += 1
    }
    // 8 tight rows: our full-bound encode (no artifact on disk)
    for ((n, mpIdx, seed) in BLOCK_TIGHT_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
        @Assert(c > 0)
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        let rS = diffSafe(comp, Int64(c), outS, n)
        let rF = diffFast(comp, Int64(c), outF, n)
        @Assert(rS == rF && rS == n)
        var eq = true
        for (i in 0..n) {
            if (outS[i] != outF[i]) { eq = false; break }
        }
        @Assert(eq)
        rows += 1
    }
    // 16 dict rows: 14 artifacts via forced extDict both paths; 2 digest-only
    // rows (no artifact) use our plain compress_default stream with the dict
    // attached (extDict instantiation active, stream never references it).
    let dict = blockDictBuffer()
    for ((n, mpIdx, seed, wantSize, _, _, _, _, fileRow) in BLOCK_DICT_REF) {
        let u8: Array<UInt8>
        let c: Int64
        if (fileRow >= 0) {
            let art = readBlockArtifact(fileRow)
            @Assert(art.size == Int64(wantSize))
            u8 = Array<UInt8>(art.size, {i => UInt8(art[i])})
            c = Int64(wantSize)
        } else {
            let buf = Array<UInt8>(n, {_ => 0u8})
            RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
            let bound = Int64(LZ4_compressBound(Int32(n)))
            let comp = Array<UInt8>(bound, {_ => 0u8})
            let cc = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
            @Assert(cc > 0)
            u8 = comp
            c = Int64(cc)
        }
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        let rS = diffSafeDict(u8, c, outS, n, dict, 65536)
        let rF = diffFastDict(u8, c, outF, n, dict, 65536)
        if (rS != rF || rS != n) {
            println("DIFF-DICT row=${fileRow} n=${n}: safe=${rS} fast=${rF}")
        }
        @Assert(rS == rF && rS == n)
        var eq = true
        for (i in 0..n) {
            if (outS[i] != outF[i]) { eq = false; break }
        }
        @Assert(eq)
        rows += 1
    }
    @Assert(rows == 280)
    // 20 partial probes: forced partial both paths, ret + prefix equality
    var partRows = 0
    for ((kind, n, _, _, row, target, _) in PARTIAL_PROBE_REF) {
        let art = readBlockArtifact(row)
        let u8 = Array<UInt8>(art.size, {i => UInt8(art[i])})
        let cap: Int64 = if (Int64(target) < n) { Int64(target) } else { n }
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        let rS: Int64 = if (kind == 1) {
            LZ4_decompress_generic_forced(u8, Int64(art.size), outS, 0, cap, true, 0, Some(dict), 0, 65536, true)
        } else {
            LZ4_decompress_generic_forced(u8, Int64(art.size), outS, 0, cap, true, 0, None<Array<UInt8>>, 0, 0, true)
        }
        let rF: Int64 = if (kind == 1) {
            LZ4_decompress_generic_forced(u8, Int64(art.size), outF, 0, cap, true, 0, Some(dict), 0, 65536, false)
        } else {
            LZ4_decompress_generic_forced(u8, Int64(art.size), outF, 0, cap, true, 0, None<Array<UInt8>>, 0, 0, false)
        }
        if (rS != rF) {
            println("DIFF-PARTIAL row=${row} target=${target}: safe=${rS} fast=${rF}")
        }
        @Assert(rS == rF)
        var eq = true
        for (i in 0..rS) {
            if (outS[i] != outF[i]) { eq = false; break }
        }
        @Assert(eq)
        partRows += 1
    }
    @Assert(partRows == 20)
    println("differential golden: ${rows}/280 manifest rows + ${partRows} partial probes safe==fast (byte-exact, ret-exact)")
}

@Test
func lz4DecompressDifferentialRandomTest(): Unit {
    var rng: UInt64 = 0x4D33536BEA15C9B7u64
    var plain = 0
    // 525 LCG cases: mp sweep 0.00..1.00 (21 values) x 25 sizes (1..64KB),
    // our compressor -> forced safe vs forced fast
    let sizes: Array<Int64> =
        [1, 2, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 127, 128, 255, 256, 511, 1000, 4095, 4096, 16384, 32768, 65535, 65536]
    for (mi in 0..21) {
        let mp = Float64(mi) * 0.05
        for (n in sizes) {
            rng = diffLcgNext(rng)
            let buf = Array<UInt8>(n, {_ => 0u8})
            RDG_genBuffer(buf, n, mp, 0.0, UInt32(rng % 4294967291u64))
            let bound = Int64(LZ4_compressBound(Int32(n)))
            let comp = Array<UInt8>(bound, {_ => 0u8})
            let c = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
            @Assert(c > 0)
            let outS = Array<UInt8>(n, {_ => 0u8})
            let outF = Array<UInt8>(n, {_ => 0u8})
            let rS = diffSafe(comp, Int64(c), outS, n)
            let rF = diffFast(comp, Int64(c), outF, n)
            if (rS != rF || rS != n) {
                println("DIFF-RND mp=${mp} n=${n}: safe=${rS} fast=${rF}")
            }
            @Assert(rS == rF && rS == n)
            var eq = true
            for (i in 0..n) {
                if (outS[i] != outF[i]) { eq = false; break }
            }
            @Assert(eq)
            plain += 1
        }
    }
    // patterned inputs: small-offset overlap matches (offset<16 fast path)
    let patSrcs: Array<Array<UInt8>> = [
        Array<UInt8>(4096, {_ => 0u8}),
        Array<UInt8>(1000, {_ => 0xAAu8}),
        Array<UInt8>(5000, {i => UInt8(i % 2)}),
        Array<UInt8>(3000, {i => UInt8(i % 3)}),
        Array<UInt8>(2000, {i => UInt8(i % 7)}),
        Array<UInt8>(65536, {i => UInt8(i % 17)}),
    ]
    for (buf in patSrcs) {
        let n = buf.size
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
        @Assert(c > 0)
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        @Assert(diffSafe(comp, Int64(c), outS, n) == n)
        @Assert(diffFast(comp, Int64(c), outF, n) == n)
        var eq = true
        for (i in 0..n) {
            if (outS[i] != outF[i]) { eq = false; break }
        }
        @Assert(eq)
        plain += 1
    }
    // 40 synthetic extDict streams (dict-referencing + in-block mixed matches)
    var synth = 0
    let dictSizes: Array<Int64> = [100, 65535, 65536, 70000]
    let synthNs: Array<Int64> = [200, 1000, 5000, 20000, 64000]
    for (dsz in dictSizes) {
        let dict = Array<UInt8>(dsz, {i => UInt8((i * 31 + 7) % 251)})
        for (n in synthNs) {
            rng = diffLcgNext(rng)
            let (comp, c) = diffSynthStream(n, dsz, rng)
            let outS = Array<UInt8>(n, {_ => 0u8})
            let outF = Array<UInt8>(n, {_ => 0u8})
            let rS = diffSafeDict(comp, c, outS, n, dict, dsz)
            let rF = diffFastDict(comp, c, outF, n, dict, dsz)
            if (rS != rF || rS != n) {
                println("DIFF-SYNTH dict=${dsz} n=${n}: safe=${rS} fast=${rF}")
            }
            @Assert(rS == rF && rS == n)
            var eq = true
            for (i in 0..n) {
                if (outS[i] != outF[i]) { eq = false; break }
            }
            @Assert(eq)
            synth += 1
        }
    }
    // 20 synthetic withPrefix64k cases: 65535-byte in-buffer prefix, offsets
    // span prefix and produced region (fast loop prefix exemption territory)
    var pref = 0
    let prefNs: Array<Int64> = [64, 100, 1000, 5000, 20000]
    for (n in prefNs) {
        for (_ in 0..4) {
            rng = diffLcgNext(rng)
            let (comp, c) = diffSynthStream(n, 65535, rng)
            let dstS = Array<UInt8>(65535 + n, {_ => 0u8})
            let dstF = Array<UInt8>(65535 + n, {_ => 0u8})
            for (i in 0..65535) {
                dstS[i] = UInt8((i * 13 + 5) % 251)
                dstF[i] = UInt8((i * 13 + 5) % 251)
            }
            let rS = LZ4_decompress_generic_forced(comp, c, dstS, 65535, n, false, 0,
                None<Array<UInt8>>, 0, 0, true)
            let rF = LZ4_decompress_generic_forced(comp, c, dstF, 65535, n, false, 0,
                None<Array<UInt8>>, 0, 0, false)
            if (rS != rF || rS != n) {
                println("DIFF-PREF n=${n}: safe=${rS} fast=${rF}")
            }
            @Assert(rS == rF && rS == n)
            var eq = true
            for (i in 0..Int64(n)) {
                if (dstS[65535 + i] != dstF[65535 + i]) { eq = false; break }
            }
            @Assert(eq)
            pref += 1
        }
    }
    // 40 random partial cases (random targets incl. sub-64 clamps)
    var part = 0
    for (_ in 0..40) {
        rng = diffLcgNext(rng)
        let mp = Float64(rng % 21u64) * 0.05
        rng = diffLcgNext(rng)
        let n = sizes[Int64(rng % 25u64)]
        rng = diffLcgNext(rng)
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, UInt32(rng % 4294967291u64))
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_default(buf, Int32(n), comp, Int32(bound))
        @Assert(c > 0)
        rng = diffLcgNext(rng)
        let target = Int64(rng % UInt64(n + 1))
        let outS = Array<UInt8>(n, {_ => 0u8})
        let outF = Array<UInt8>(n, {_ => 0u8})
        let rS = LZ4_decompress_generic_forced(comp, Int64(c), outS, 0, target, true, 0,
            None<Array<UInt8>>, 0, 0, true)
        let rF = LZ4_decompress_generic_forced(comp, Int64(c), outF, 0, target, true, 0,
            None<Array<UInt8>>, 0, 0, false)
        if (rS != rF) {
            println("DIFF-RNDPART n=${n} target=${target}: safe=${rS} fast=${rF}")
        }
        @Assert(rS == rF)
        var eq = true
        for (i in 0..rS) {
            if (outS[i] != outF[i]) { eq = false; break }
        }
        @Assert(eq)
        part += 1
    }
    @Assert(plain == 531)
    @Assert(synth == 20)
    @Assert(pref == 20)
    @Assert(part == 40)
    println("differential random: ${plain} plain + ${synth} extDict-synth + ${pref} prefix64k-synth + ${part} partial, all safe==fast")
}

@Test
func lz4DecompressDifferentialCorruptTest(): Unit {
    var rng: UInt64 = 0x5EED1F0CA7E57A11u64
    var cases = 0
    var neg = 0
    // bases: real artifacts (plain + dict) plus our-compressed patterned inputs
    let art64 = readBlockArtifact(64)
    let b64 = Array<UInt8>(art64.size, {i => UInt8(art64[i])})
    let art112 = readBlockArtifact(112)
    let b112 = Array<UInt8>(art112.size, {i => UInt8(art112[i])})
    let art270 = readBlockArtifact(270)
    let b270 = Array<UInt8>(art270.size, {i => UInt8(art270[i])})
    let dict = blockDictBuffer()
    // our-compressed bases
    let zbuf = Array<UInt8>(1000, {_ => 0u8})
    let zcomp = Array<UInt8>(Int64(LZ4_compressBound(1000)), {_ => 0u8})
    let zc = Int64(LZ4_compress_default(zbuf, 1000, zcomp, LZ4_compressBound(1000)))
    let rbuf = Array<UInt8>(5000, {_ => 0u8})
    RDG_genBuffer(rbuf, 5000, 0.9, 0.0, 5u32)
    let rcomp = Array<UInt8>(Int64(LZ4_compressBound(5000)), {_ => 0u8})
    let rc = Int64(LZ4_compress_default(rbuf, 5000, rcomp, LZ4_compressBound(5000)))
    // (stream, c, outN, isDict)
    let bases: Array<(Array<UInt8>, Int64, Int64, Bool)> = [
        (b64, art64.size, 255, false),
        (b112, art112.size, 4096, false),
        (b270, art270.size, 4096, true),
        (zcomp, zc, 1000, false),
        (rcomp, rc, 5000, false),
    ]
    for ((base, c, outN, isDict) in bases) {
        var ops = 0
        while (ops < 20) {
            rng = diffLcgNext(rng)
            let mod: Array<UInt8> = Array<UInt8>(c, {i => base[i]})
            var mc = c
            var kind = Int64(rng % 3u64)
            if (kind == 0) {
                // bit flip at a random position
                rng = diffLcgNext(rng)
                let pos = Int64(rng % UInt64(c))
                rng = diffLcgNext(rng)
                mod[pos] = mod[pos] ^ UInt8(1 << Int64(rng % 8u64))
            } else if (kind == 1) {
                // overwrite a byte with 0xFF
                rng = diffLcgNext(rng)
                let pos = Int64(rng % UInt64(c))
                mod[pos] = 0xFFu8
            } else {
                // truncation (keep >= 1 byte)
                rng = diffLcgNext(rng)
                mc = 1 + Int64(rng % UInt64(c - 1))
            }
            let outS = Array<UInt8>(outN, {_ => 0u8})
            let outF = Array<UInt8>(outN, {_ => 0u8})
            let rS: Int64 = if (isDict) {
                diffSafeDict(mod, mc, outS, outN, dict, 65536)
            } else {
                diffSafe(mod, mc, outS, outN)
            }
            let rF: Int64 = if (isDict) {
                diffFastDict(mod, mc, outF, outN, dict, 65536)
            } else {
                diffFast(mod, mc, outF, outN)
            }
            if (rS < 0 && rF < 0) {
                neg += 1
            } else {
                // both must accept identically (rare: corruption inside the
                // final literal payload can stay decodable)
                if (rS != rF) {
                    println("CORRUPT-DIVERGE c=${c} mc=${mc} kind=${kind}: safe=${rS} fast=${rF}")
                }
                @Assert(rS == rF && rS >= 0)
                var eq = true
                for (i in 0..rS) {
                    if (outS[i] != outF[i]) { eq = false; break }
                }
                @Assert(eq)
            }
            cases += 1
            ops += 1
        }
    }
    @Assert(cases == 100)
    @Assert(neg >= 30)
    println("differential corrupt: ${cases} cases (${neg} both-negative, ${cases - neg} identical-positive)")
}

/*-************************************
*  M3 Task 4: streaming decode family (continue + ring buffer)
**************************************/
// stream rows of corpus/block_golden_ref.txt (rows 280..287): 2 RDG buffers
// of 4x40960 bytes (mp=0.50 seed=101 / mp=0.90 seed=202) sliced into 8
// blocks, compressed C-side with one persistent stream so offsets cross
// block boundaries; decode rolls through a single 327680-byte buffer.
// (seq, size, ret, pre32, pre64, xxh32, xxh64, inxxh32, inxxh64, fileRowIdx)
let STREAM_REF: Array<(Int64, Int32, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, UInt64, Int64)> = [
    (0, 22944, 40960, 0x85cd4e41u32, 0xcb21ca1806189b47u64, 0xb896805du32, 0x0af182be98f1809bu64, 0x85cd4e41u32, 0xcb21ca1806189b47u64, 280),
    (1, 24221, 40960, 0xf741ec7eu32, 0x40f26586694162e5u64, 0x52bc8d79u32, 0x554d37c380412ec7u64, 0xd975001fu32, 0xc168a4034cac48e6u64, 281),
    (2, 24046, 40960, 0xce121972u32, 0x4ecdd71ac11a9e19u64, 0xecea7e10u32, 0xae31cff5d3257d42u64, 0xedc3640eu32, 0x5d0f7277edad9118u64, 282),
    (3, 25309, 40960, 0x176149b6u32, 0xcd6358b71d648628u64, 0x8e083202u32, 0x2c6fe8c63653acbeu64, 0x8407078bu32, 0xfff3957384e47dcau64, 283),
    (4, 4190, 40960, 0x34843684u32, 0xece2c7afcaebf8d4u64, 0xa1213195u32, 0xc38983712fa5cc90u64, 0xa8d80f33u32, 0xfce4402ca6ecf103u64, 284),
    (5, 6364, 40960, 0xc3359c76u32, 0xfe6152f56fa03437u64, 0xdc4f4c34u32, 0x525545fbca12d0a9u64, 0x6c078d2cu32, 0x906f4564a7180cdbu64, 285),
    (6, 7863, 40960, 0x29eae430u32, 0x7ac43abe9bd9f688u64, 0x1cb725eau32, 0x0dff848db1134d53u64, 0x5dee2a46u32, 0xcfa93b28369fd30eu64, 286),
    (7, 7976, 40960, 0xa00350d4u32, 0x2b7da5ba705302ddu64, 0x304852f9u32, 0x89c36503e7c3bed4u64, 0xf227e642u32, 0xbacc3c598ddf80dau64, 287),
]

private func streamSourceBuffer(half: Int64): Array<UInt8> {
    let buf = Array<UInt8>(4 * 40960, {_ => 0u8})
    if (half == 0) {
        RDG_genBuffer(buf, 4 * 40960, 0.5, 0.0, 101u32)
    } else {
        RDG_genBuffer(buf, 4 * 40960, 0.9, 0.0, 202u32)
    }
    return buf
}

// digest of buf[off, off+len) via the streaming states (one-shot XXH32/64
// have no offset parameter)
private func sliceXXH32(buf: Array<UInt8>, off: Int64, len: Int64): UInt32 {
    let st = XXH32_createState()
    XXH32_reset(st, 0u32)
    XXH32_update(st, buf, len, offset: off)
    let h = XXH32_digest(st)
    XXH32_freeState(st)
    return h
}

private func sliceXXH64(buf: Array<UInt8>, off: Int64, len: Int64): UInt64 {
    let st = XXH64_createState()
    XXH64_reset(st, 0u64)
    XXH64_update(st, buf, len, offset: off)
    let h = XXH64_digest(st)
    XXH64_freeState(st)
    return h
}

@Test
func lz4DecompressSafeContinueGoldenTest(): Unit {
    let dst = Array<UInt8>(8 * 40960, {_ => 0u8})
    // generate each 4-block source half once (RDG regeneration is
    // deterministic; hoisted out of the row loop)
    let srcHalves = [streamSourceBuffer(0), streamSourceBuffer(1)]
    let sd = LZ4_createStreamDecode()
    var pos: Int64 = 0
    for ((seq, wantSize, wantRet, wantPre32, wantPre64, want32, want64, wantIn32, wantIn64, fileRow) in STREAM_REF) {
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(wantSize))
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        // artifact + slice provenance pinned by the C-side digests
        @Assert(XXH32(u8art, Int64(wantSize), 0u32) == want32)
        @Assert(XXH64(u8art, Int64(wantSize), 0u64) == want64)
        let srcBuf = srcHalves[seq / 4]
        let sliceOff = (seq % 4) * 40960
        @Assert(sliceXXH32(srcBuf, sliceOff, 40960) == wantIn32)
        @Assert(sliceXXH64(srcBuf, sliceOff, 40960) == wantIn64)
        let r = LZ4_decompress_safe_continue(sd, u8art, wantSize, dst, pos, 40960)
        if (r != wantRet) {
            println("STREAM seq=${seq}: got ${r} want ${wantRet}")
        }
        @Assert(r == wantRet)
        // decoded block bytes byte-exact against the regenerated slice
        var eq = true
        var i = sliceOff
        while (i < sliceOff + 40960) {
            if (dst[pos + (i - sliceOff)] != srcBuf[i]) { eq = false; break }
            i += 1
        }
        if (!eq) { println("STREAM BYTES differ seq=${seq}") }
        @Assert(eq)
        pos += Int64(r)
        // rolling-buffer content pinned by the cumulative prefix digests
        @Assert(XXH32(dst, pos, 0u32) == wantPre32)
        @Assert(XXH64(dst, pos, 0u64) == wantPre64)
    }
    @Assert(LZ4_freeStreamDecode(sd) == 0)
    println("stream golden: 8 continue blocks rolled byte-exact, prefix digests closed")
}

// ring rows (rows 288..297): one RDG buffer of 10x16384 bytes
// (mp=0.50 seed=303); ring buffer sized by LZ4_decoderRingBufferSize(16384)
// = 81934. Lap: seq 0-4 at pos 0/16K/32K/48K/64K (prefix graduates
// smallPrefix -> withPrefix64k), 14 bytes left < 16384 -> seq 5 wraps to 0
// (extDict swap), seq 6-9 roll with small prefix + extDict (doubleDict).
// (seq, pos, size, xxh32, xxh64, inxxh32, inxxh64, fileRowIdx)
let RING_REF: Array<(Int64, Int64, Int32, UInt32, UInt64, UInt32, UInt64, Int64)> = [
    (0, 0, 8616, 0x71b21677u32, 0xa0254e3979d27fcau64, 0x054b5473u32, 0x3dfb491179367e10u64, 288),
    (1, 16384, 8554, 0xce3c9b71u32, 0x9cb08d10f42ccac3u64, 0x14bf68d7u32, 0xcff3b0f832df047bu64, 289),
    (2, 32768, 8939, 0x4e2b3c3bu32, 0x8eb750a364523d6fu64, 0xb6b03f43u32, 0xe6472fc4869ef87eu64, 290),
    (3, 49152, 10521, 0x0172bc10u32, 0xc8df68dd96c0219cu64, 0x6ea45548u32, 0x00a0db85fdc1ac08u64, 291),
    (4, 65536, 9044, 0xd4b2b7f5u32, 0x7f209f93eb945a87u64, 0xf0c401e7u32, 0xdf91222b4dea3939u64, 292),
    (5, 0, 9581, 0x4f6c1ec8u32, 0x222924eb3111679du64, 0x971cf0e1u32, 0x1047edba29074b7eu64, 293),
    (6, 16384, 9839, 0x2d6d3cfcu32, 0x8ef42ff1a4f0b34du64, 0xb8877179u32, 0x4fe3389c7ebedb23u64, 294),
    (7, 32768, 8357, 0x8269bcc9u32, 0x045006ad21120a38u64, 0x01d3ad17u32, 0xc9aca01d3a3b5c41u64, 295),
    (8, 49152, 10473, 0x2dabe9b6u32, 0x48f14654819794d0u64, 0x46819214u32, 0x40d34583c4a0a887u64, 296),
    (9, 65536, 9206, 0x63c4a85du32, 0x36c53f760f254da6u64, 0x4e0016f8u32, 0xa68d7d43a7714747u64, 297),
]

@Test
func lz4DecompressRingBufferGoldenTest(): Unit {
    // ring size contract (upstream lz4.c L2634-2640)
    @Assert(LZ4_decoderRingBufferSize(16384) == 81934)
    let ringSize: Int64 = Int64(LZ4_decoderRingBufferSize(16384))
    let ring = Array<UInt8>(ringSize, {_ => 0u8})
    let src = Array<UInt8>(10 * 16384, {_ => 0u8})
    RDG_genBuffer(src, 10 * 16384, 0.5, 0.0, 303u32)
    let sd = LZ4_createStreamDecode()
    var pos: Int64 = 0
    for ((seq, wantPos, wantSize, want32, want64, wantIn32, wantIn64, fileRow) in RING_REF) {
        if (ringSize - pos < 16384) { pos = 0 }
        @Assert(pos == wantPos)   // exact wrap schedule from the C harness
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(wantSize))
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        @Assert(XXH32(u8art, Int64(wantSize), 0u32) == want32)
        @Assert(XXH64(u8art, Int64(wantSize), 0u64) == want64)
        let sliceOff = seq * 16384
        @Assert(sliceXXH32(src, sliceOff, 16384) == wantIn32)
        @Assert(sliceXXH64(src, sliceOff, 16384) == wantIn64)
        let r = LZ4_decompress_safe_continue(sd, u8art, wantSize, ring, pos, 16384)
        if (r != 16384) {
            println("RING seq=${seq}: got ${r}")
        }
        @Assert(r == 16384)
        var eq = true
        var i = sliceOff
        while (i < sliceOff + 16384) {
            if (ring[pos + (i - sliceOff)] != src[i]) { eq = false; break }
            i += 1
        }
        if (!eq) { println("RING BYTES differ seq=${seq} pos=${pos}") }
        @Assert(eq)
        pos += Int64(r)
    }
    @Assert(LZ4_freeStreamDecode(sd) == 0)
    println("ring golden: 10 blocks across the 64KB boundary + wrap, byte-exact")
}

// setdict rows (rows 298..299): LZ4_setStreamDecode external dictionary
// (dict = RDG(65536, mp=0.50, seed=77)); source = RDG(81920, mp=0.90,
// seed=88) in 2 blocks of 40960. Block 0 decodes into a FRESH buffer
// (prefixEnd=dict end != dest -> extDict swap -> forceExtDict); block 1
// rolls at dstIdx=40960 with extDictSize!=0 and small prefix -> doubleDict.
let SETDICT_DICT_XXH32: UInt32 = 0x7b19c37du32
let SETDICT_DICT_XXH64: UInt64 = 0x59f6b3f3a2fd2c1au64
// (seq, size, ret, pre32, pre64, xxh32, xxh64, inxxh32, inxxh64, fileRowIdx)
let SETDICT_REF: Array<(Int64, Int32, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, UInt64, Int64)> = [
    (0, 3282, 40960, 0x37258e24u32, 0x0858de551feab56au64, 0xda449cfeu32, 0xa54faa19002ead7fu64, 0x37258e24u32, 0x0858de551feab56au64, 298),
    (1, 7355, 40960, 0x73868952u32, 0x09453aa6fd5934bfu64, 0x4b0cabe3u32, 0x1ad2592f0285a4a9u64, 0x2d99ba2du32, 0x27c0ef47d69a6136u64, 299),
]

@Test
func lz4DecompressSetStreamDecodeGoldenTest(): Unit {
    let dict = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(dict, 65536, 0.5, 0.0, 77u32)
    @Assert(XXH32(dict, 65536, 0u32) == SETDICT_DICT_XXH32)
    @Assert(XXH64(dict, 65536, 0u64) == SETDICT_DICT_XXH64)
    let src = Array<UInt8>(81920, {_ => 0u8})
    RDG_genBuffer(src, 81920, 0.9, 0.0, 88u32)
    let dst = Array<UInt8>(81920, {_ => 0u8})
    let sd = LZ4_createStreamDecode()
    // external dictionary injection; invalid sizes are rejected (C: caller
    // error / UB, defended here -> 0), dictSize=0 is legal (no dictionary)
    @Assert(LZ4_setStreamDecode(sd, dict, 65536) == 1)
    @Assert(LZ4_setStreamDecode(sd, dict, -1) == 0)
    @Assert(LZ4_setStreamDecode(sd, dict, 65537) == 0)
    @Assert(LZ4_setStreamDecode(sd, dict, 0) == 1)
    // re-inject the real dictionary after the probes above
    @Assert(LZ4_setStreamDecode(sd, dict, 65536) == 1)
    var pos: Int64 = 0
    for ((seq, wantSize, wantRet, wantPre32, wantPre64, want32, want64, wantIn32, wantIn64, fileRow) in SETDICT_REF) {
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(wantSize))
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        @Assert(XXH32(u8art, Int64(wantSize), 0u32) == want32)
        @Assert(XXH64(u8art, Int64(wantSize), 0u64) == want64)
        let sliceOff = seq * 40960
        @Assert(sliceXXH32(src, sliceOff, 40960) == wantIn32)
        @Assert(sliceXXH64(src, sliceOff, 40960) == wantIn64)
        let r = LZ4_decompress_safe_continue(sd, u8art, wantSize, dst, pos, 40960)
        if (r != wantRet) {
            println("SETDICT seq=${seq}: got ${r} want ${wantRet}")
        }
        @Assert(r == wantRet)
        var eq = true
        var i = sliceOff
        while (i < sliceOff + 40960) {
            if (dst[pos + (i - sliceOff)] != src[i]) { eq = false; break }
            i += 1
        }
        if (!eq) { println("SETDICT BYTES differ seq=${seq}") }
        @Assert(eq)
        pos += Int64(r)
        @Assert(XXH32(dst, pos, 0u32) == wantPre32)
        @Assert(XXH64(dst, pos, 0u64) == wantPre64)
    }
    @Assert(LZ4_freeStreamDecode(sd) == 0)
    println("setdict golden: fresh-buffer forceExtDict + rolling doubleDict byte-exact")
}

@Test
func lz4DecompressContinueErrorTest(): Unit {
    // decoderRingBufferSize edges (lz4.c L2634-2640)
    @Assert(LZ4_decoderRingBufferSize(-1) == 0)
    @Assert(LZ4_decoderRingBufferSize(0) == 65536 + 14 + 16)
    @Assert(LZ4_decoderRingBufferSize(15) == 65536 + 14 + 16)
    @Assert(LZ4_decoderRingBufferSize(16) == 65536 + 14 + 16)
    @Assert(LZ4_decoderRingBufferSize(LZ4_MAX_INPUT_SIZE) == 65536 + 14 + LZ4_MAX_INPUT_SIZE)
    @Assert(LZ4_decoderRingBufferSize(LZ4_MAX_INPUT_SIZE + 1) == 0)
    // entry validation on continue: negative sizes -> -1 before any state use
    let sd = LZ4_createStreamDecode()
    let src = Array<UInt8>(64, {_ => 0u8})
    let dst = Array<UInt8>(256, {_ => 0u8})
    @Assert(LZ4_decompress_safe_continue(sd, src, -1, dst, 0, 64) == -1)
    @Assert(LZ4_decompress_safe_continue(sd, src, 64, dst, 0, -1) == -1)
    @Assert(LZ4_decompress_safe_continue(sd, src, 64, dst, -1, 64) == -1)
    // a failed first block (empty input) must return negative and leave the
    // state usable as "first call" (C: result <= 0 returned as-is, state
    // untouched while prefixSize == 0)
    @Assert(LZ4_decompress_safe_continue(sd, src, 0, dst, 0, 64) == -1)
    // corrupt middle block: replay the golden stream but flip bytes inside
    // the seq=3 artifact; the decode must go negative (error propagation),
    // and per C semantics the state is then undefined - no reuse afterwards
    let dst2 = Array<UInt8>(8 * 40960, {_ => 0u8})
    var pos: Int64 = 0
    for ((seq, wantSize, _, _, _, _, _, _, _, fileRow) in STREAM_REF) {
        let art = readBlockArtifact(fileRow)
        let u8art = Array<UInt8>(art.size, {i => UInt8(art[i])})
        if (seq == 3) {
            u8art[Int64(wantSize) / 2] = u8art[Int64(wantSize) / 2] ^ 0xFFu8
            let r = LZ4_decompress_safe_continue(sd, u8art, wantSize, dst2, pos, 40960)
            if (r >= 0) { println("CORRUPT STREAM seq=3: got ${r}") }
            @Assert(r < 0)
            break
        }
        let r = LZ4_decompress_safe_continue(sd, u8art, wantSize, dst2, pos, 40960)
        @Assert(r == 40960)
        pos += 40960
    }
    @Assert(LZ4_freeStreamDecode(sd) == 0)
    println("continue error propagation: corrupt middle block -> negative")
}

@Test
func lz4DecompressPerfSmokeTest(): Unit {
    // opt-out hook for the ~1.5GB decode workload (default: run)
    if (let Some(_) <- getVariable("LZ4_SKIP_PERF")) {
        println("perf smoke: LZ4_SKIP_PERF set, skipped")
        return
    }
    // 4MB datagen corpora, forced-safe vs forced-fast (dispatch build), no gate
    let n: Int64 = 4 * 1024 * 1024
    let mps: Array<Float64> = [0.0, 0.5, 1.0]
    for (mp in mps) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, 42u32)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let comp = Array<UInt8>(bound, {_ => 0u8})
        let c = Int64(LZ4_compress_default(buf, Int32(n), comp, Int32(bound)))
        @Assert(c > 0)
        // correctness gate before timing
        let chk = Array<UInt8>(n, {_ => 0u8})
        @Assert(diffFast(comp, c, chk, n) == n)
        var eq = true
        for (i in 0..n) {
            if (chk[i] != buf[i]) { eq = false; break }
        }
        @Assert(eq)
        // timing: best-of-2 rounds x 12 iterations per path
        let iters: Int64 = 12
        var bestS: Float64 = 0.0
        var bestF: Float64 = 0.0
        for (_ in 0..2) {
            let outS = Array<UInt8>(n, {_ => 0u8})
            let t0 = MonoTime.now()
            var i: Int64 = 0
            while (i < iters) {
                LZ4_decompress_generic_forced(comp, c, outS, 0, n, false, 0,
                    None<Array<UInt8>>, 0, 0, true)
                i += 1
            }
            let dt = (MonoTime.now() - t0).toNanoseconds()
            let mbs = Float64(n * iters) / Float64(dt) * 1000000000.0 / 1048576.0
            if (mbs > bestS) { bestS = mbs }
            let outF = Array<UInt8>(n, {_ => 0u8})
            let t1 = MonoTime.now()
            i = 0
            while (i < iters) {
                LZ4_decompress_generic_forced(comp, c, outF, 0, n, false, 0,
                    None<Array<UInt8>>, 0, 0, false)
                i += 1
            }
            let dt2 = (MonoTime.now() - t1).toNanoseconds()
            let mbs2 = Float64(n * iters) / Float64(dt2) * 1000000000.0 / 1048576.0
            if (mbs2 > bestF) { bestF = mbs2 }
        }
        println("perf smoke mp=${mp} n=4MB c=${c}: safe=${bestS} MB/s, fast=${bestF} MB/s")
    }
}

/*-************************************
*  M3 Task 5: extDict boundary-spanning match copies (C-probe pinned)
**************************************/
// Handcrafted streams against dict "ABCDEFGH" exercising the match that
// starts in the external dictionary and stretches into the current block
// (lz4.c L2199-2208 fast / L2389-2403 safe): sequence = 2 literals,
// offset 4 (match = 2 bytes before lowPrefix -> dict[6]), matchLen 5/8,
// tail "12345". Expected outputs/returns pinned by an upstream-C probe
// (commit 0774d055): full "xyGHxyG12345" (ml=5) / "xyGHxyGHxy12345"
// (ml=8, overlap byte-copy since restSize 6 > op-lowPrefix 4); partial
// targets clamp mid-match; cap 12/13 leave < MFLIMIT output margin so a
// non-final literals run fails last-run validation (-2); ml=8 at cap 14
// violates the match restriction op+length > oend-LASTLITERALS (-6).
private func spanStream(mlNibble: UInt8): Array<UInt8> {
    let s = Array<UInt8>(11, {_ => 0u8})
    s[0] = (2u8 << 4) | mlNibble                                // litLen 2, ml 4+nib
    s[1] = 0x78u8; s[2] = 0x79u8                                // 'x','y'
    s[3] = 0x04u8; s[4] = 0x00u8                                // offset 4
    s[5] = 0x50u8                                               // last lits: 5
    for (i in 0..5) { s[6 + i] = UInt8(49 + i) }                // "12345"
    return s
}

private func spanDecode(dict: Array<UInt8>, s: Array<UInt8>, n: Int64, cap: Int32): (Int32, Array<UInt8>) {
    let d = Array<UInt8>(Int64(cap), {_ => 0u8})
    let r = LZ4_decompress_safe_usingDict(s, Int32(n), d, cap, dict, 8)
    return (r, d)
}

@Test
func lz4DecompressExtDictSpanningTest(): Unit {
    let dict = Array<UInt8>(8, {i => UInt8(65 + i)})            // "ABCDEFGH"
    let s5 = spanStream(1u8)                                    // ml = 5
    let s8 = spanStream(4u8)                                    // ml = 8
    // "xyGHxyG12345" / "xyGHxyGHxy12345"
    let want5: Array<UInt8> = [0x78u8, 0x79u8, 0x47u8, 0x48u8, 0x78u8, 0x79u8, 0x47u8,
        0x31u8, 0x32u8, 0x33u8, 0x34u8, 0x35u8]
    let want8: Array<UInt8> = [0x78u8, 0x79u8, 0x47u8, 0x48u8, 0x78u8, 0x79u8, 0x47u8,
        0x48u8, 0x78u8, 0x79u8, 0x31u8, 0x32u8, 0x33u8, 0x34u8, 0x35u8]
    // fast loop (cap >= 64), safe loop (cap 14..63), and the minimal-margin
    // safe case: identical outputs on both spanning-copy variants
    let caps: Array<Int32> = [128, 63, 14]
    for (cap in caps) {
        let (r5, d5) = spanDecode(dict, s5, 11, cap)
        if (r5 != 12) { println("SPAN5 cap=${cap}: got ${r5}") }
        @Assert(r5 == 12)
        for (i in 0..12) { @Assert(d5[i] == want5[i]) }
    }
    let caps8: Array<Int32> = [128, 31]
    for (cap in caps8) {
        let (r8, d8) = spanDecode(dict, s8, 11, cap)
        if (r8 != 15) { println("SPAN8 cap=${cap}: got ${r8}") }
        @Assert(r8 == 15)
        for (i in 0..15) { @Assert(d8[i] == want8[i]) }
    }
    // must-be-last-run input rule: oend-MFLIMIT margin violated at literals
    @Assert(spanDecode(dict, s5, 11, 13)[0] == -2)
    @Assert(spanDecode(dict, s5, 11, 12)[0] == -2)
    // match-restriction error: ml=8 needs op+len 10 <= oend-5 at cap 14
    @Assert(spanDecode(dict, s8, 11, 14)[0] == -6)
    // short-tail stream (< LASTLITERALS after match) -> -2 at any capacity
    let bad = Array<UInt8>(9, {_ => 0u8})
    bad[0] = 0x21u8; bad[1] = 0x78u8; bad[2] = 0x79u8
    bad[3] = 0x04u8; bad[4] = 0x00u8
    bad[5] = 0x30u8; bad[6] = 0x31u8; bad[7] = 0x32u8; bad[8] = 0x33u8
    @Assert(LZ4_decompress_safe_usingDict(bad, 9, Array<UInt8>(72, {_ => 0u8}), 72, dict, 8) == -2)
    // partial + extDict: target clamps mid-match (length = min(ml, oend-op))
    let p = Array<UInt8>(128, {_ => 0u8})
    @Assert(LZ4_decompress_safe_partial_usingDict(s8, 11, p, 128, 6, dict, 8) == 6)
    @Assert(p[0] == 0x78u8 && p[1] == 0x79u8 && p[2] == 0x47u8 && p[3] == 0x48u8 &&
        p[4] == 0x78u8 && p[5] == 0x79u8)                       // "xyGHxy"
    @Assert(LZ4_decompress_safe_partial_usingDict(s5, 11, p, 128, 4, dict, 8) == 4)
    @Assert(p[2] == 0x47u8 && p[3] == 0x48u8)                   // "xyGH"
    // first-sequence spanning match with op == 0 (restSize 6 > op 2): the
    // overlap byte-copy inside the fast loop's extDict branch (L2203-2206).
    // Stream: token(litLen 0, ml 8), offset 2, tail 0xF0/ext 25 + 40 lits.
    let v3 = Array<UInt8>(45, {_ => 0u8})
    v3[0] = 0x04u8
    v3[1] = 0x02u8; v3[2] = 0x00u8
    v3[3] = 0xF0u8; v3[4] = 25u8
    for (i in 0..40) { v3[5 + i] = UInt8(97 + (i % 26)) }
    // "GHGHGHGH" + 'a'..'z' + 'a'..'n'
    let wantV3: Array<UInt8> = Array<UInt8>(48, {i =>
        if (i < 8) { UInt8(71 + (i % 2)) } else { UInt8(97 + ((i - 8) % 26)) }})
    let capsV3: Array<Int32> = [128, 63]
    for (cap in capsV3) {
        let (rv, dv) = spanDecode(dict, v3, 45, cap)
        if (rv != 48) { println("SPANV3 cap=${cap}: got ${rv}") }
        @Assert(rv == 48)
        for (i in 0..48) { @Assert(dv[i] == wantV3[i]) }
    }
    // 48 bytes cannot fit cap 31: error at the last-run stage
    @Assert(spanDecode(dict, v3, 45, 31)[0] < 0)
    // entry validation on the dict/partial variants (defensive -1)
    let d = Array<UInt8>(16, {_ => 0u8})
    @Assert(LZ4_decompress_safe_partial(s5, -1, d, 16, 8) == -1)
    @Assert(LZ4_decompress_safe_usingDict(s5, -1, d, 16, dict, 8) == -1)
    @Assert(LZ4_decompress_safe_usingDict(s5, 11, d, -1, dict, 8) == -1)
    @Assert(LZ4_decompress_safe_partial_usingDict(s5, -1, d, 16, 8, dict, 8) == -1)
    println("extDict spanning: fast/safe loops + partial clamp + errors pinned")
}

/*-************************************
*  M3b Task 1: streaming state family + real prepareTable
**************************************/
// fastreset rows of corpus/block_golden_ref.txt (rows 300..309): 5 same-stream
// 2-block scenarios via LZ4_compress_fast_extState_fastReset (accel=1,
// dstCapacity=compressBound => notLimited). seq=0 runs on a fresh stream
// (clearedTable) => byte-equal to default mode (regression anchor, also
// hard-verified C-side); seq=1 runs on the dirty table: byU16 reuse
// (scenarios 0/1: dictSmall candidate rejection) or full reset per
// LZ4_prepareTable conditions (inputSize>=4KB / 0xFFFF overflow / type
// switch). off/tt = post-compress C state (currentOffset/tableType): reuse
// accumulates off (301: 2048+2048, 303: 200+3000), reset restarts it; the
// OUTPUT is always fresh-identical for this API (empty/zero hash slots can
// never yield an accepted candidate in either mode => dictSmall rejection is
// output-neutral), so off/tt is what discriminates the real prepareTable
// path from full re-init. Blocks are self-contained; each row round-trips
// standalone.
// (n, mp, seed, seq, size, xxh32, xxh64, off, tt, fileRowIdx)
let FASTRESET_REF: Array<(Int64, Float64, UInt32, Int64, Int32, UInt32, UInt64, UInt32, Int32, Int64)> = [
    (2048, 0.5, 401u32, 0, 245, 0x79f2f5c2u32, 0xb04cc6d2fe07cab4u64, 2048u32, 3, 300),
    (2048, 0.9, 402u32, 1, 269, 0x86da8958u32, 0xfeef48dd2b8947adu64, 4096u32, 3, 301),
    (200, 1.0, 403u32, 0, 11, 0x7e995678u32, 0x23f8c73f45824688u64, 200u32, 3, 302),
    (3000, 0.5, 404u32, 1, 1687, 0x80098d4fu32, 0x7ffa125d2e2e2614u64, 3200u32, 3, 303),
    (1024, 0.9, 405u32, 0, 122, 0x0d3d37efu32, 0x61ca7f6297714bffu64, 1024u32, 3, 304),
    (4096, 0.0, 406u32, 1, 4114, 0xb46053f8u32, 0x67ff9eca3546d736u64, 4096u32, 3, 305),
    (40000, 0.9, 407u32, 0, 4602, 0xb6ac7687u32, 0x3862d95ca1eed5eeu64, 40000u32, 3, 306),
    (40000, 0.5, 408u32, 1, 21787, 0x73f2f1eeu32, 0xc95a9858d8838cb1u64, 40000u32, 3, 307),
    (65547, 0.9, 409u32, 0, 6254, 0x29bfa032u32, 0x1abb56a0104e3eedu64, 65547u32, 2, 308),
    (2048, 0.5, 410u32, 1, 1588, 0xc3d2274au32, 0xaaf6504ed6a5e26bu64, 2048u32, 3, 309),
]

@Test
func lz4CompressFastResetGoldenTest(): Unit {
    var checked = 0
    var anchors = 0
    var fileCompared = 0
    // one stream per scenario; fresh stream == LZ4_createStream semantics
    // (allocation + initStream), exercised via the constructor here
    var st: Option<LZ4_stream_t> = None
    for ((n, mp, seed, seq, wantSize, want32, want64, wantOff, wantTt, fileRow) in FASTRESET_REF) {
        if (seq == 0) {
            let s = LZ4_stream_t()
            @Assert(LZ4_initStream(s) == 0)
            st = Some(s)
        }
        let stream = st.getOrThrow()
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, mp, 0.0, seed)
        let bound = Int64(LZ4_compressBound(Int32(n)))
        let out = Array<UInt8>(bound, {_ => 0u8})
        let c = LZ4_compress_fast_extState_fastReset(stream, buf, Int32(n), out, Int32(bound), 1)
        if (c != wantSize) {
            println("FASTRESET n=${n} mp=${mp} seed=${seed} seq=${seq}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        // post-compress state must match the C snapshot (reuse vs reset)
        if (stream.currentOffset != wantOff || stream.tableType != wantTt) {
            println("STATE n=${n} seq=${seq}: got off=${stream.currentOffset} tt=${stream.tableType} want off=${wantOff} tt=${wantTt}")
        }
        @Assert(stream.currentOffset == wantOff)
        @Assert(stream.tableType == wantTt)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DIGEST n=${n} mp=${mp} seed=${seed} seq=${seq} size=${c}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (seq == 0) {
            // regression anchor: fresh-state fastReset == plain default mode
            let ref = Array<UInt8>(bound, {_ => 0u8})
            let d = LZ4_compress_default(buf, Int32(n), ref, Int32(bound))
            @Assert(d == c)
            var eq = d == c
            for (i in 0..Int64(c)) {
                if (ref[i] != out[i]) { eq = false; break }
            }
            if (!eq) { println("ANCHOR n=${n} mp=${mp} seed=${seed}: fastReset != default") }
            @Assert(eq)
            anchors += 1
        }
        // self-containment: standalone decode must round-trip (dictSmall
        // rejects stale candidates => no cross-block offsets)
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, Int32(c), dec, Int32(n)) == Int32(n))
        var rt = true
        for (i in 0..n) {
            if (dec[i] != buf[i]) { rt = false; break }
        }
        @Assert(rt)
        // byte-exact comparison against the C-generated artifact
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(c))
        var eq = art.size == Int64(c)
        for (i in 0..Int64(c)) {
            if (UInt8(art[i]) != out[i]) { eq = false; break }
        }
        if (!eq) { println("BYTES differ n=${n} seq=${seq} row=${fileRow}") }
        @Assert(eq)
        fileCompared += 1
        checked += 1
    }
    @Assert(checked == 10)
    @Assert(anchors == 5)
    @Assert(fileCompared == 10)
    println("fastreset golden: ${checked}/10 rows exact (${anchors} fresh-state anchors = default mode)")
}

// helper: mark the table dirty with sentinels and verify
private func dirtyTable(st: LZ4_stream_t): Unit {
    st.hashTable[0] = 0xDEADBEEFu32
    st.hashTable[1] = 0xCAFEBABEu32
    st.hashTable[16383] = 0x0BADF00Du32
}

private func tableIsZero(st: LZ4_stream_t): Bool {
    for (i in 0..st.hashTable.size) {
        if (st.hashTable[i] != 0u32) { return false }
    }
    return true
}

private func tableIsDirty(st: LZ4_stream_t): Bool {
    return st.hashTable[0] == 0xDEADBEEFu32 && st.hashTable[16383] == 0x0BADF00Du32
}

// helper: set all dictionary fields non-trivial
private func dirtyDict(st: LZ4_stream_t): Unit {
    st.dictBuf = Some(Array<UInt8>(8, {_ => 7u8}))
    st.dictStartIdx = 5
    st.dictSize = 100
    st.dictCtx = Some(LZ4_stream_t())
}

private func dictIsClear(st: LZ4_stream_t): Bool {
    return st.dictBuf.isNone() && st.dictStartIdx == 0 && st.dictSize == 0 && st.dictCtx.isNone()
}

@Test
func lz4PrepareTableTest(): Unit {
    // upstream tableType_t enum (lz4.c L726: {clearedTable=0, byPtr, byU32, byU16})
    @Assert(LZ4_TABLE_CLEARED == 0 && LZ4_TABLE_BYPTR == 1 && LZ4_TABLE_BYU32 == 2 && LZ4_TABLE_BYU16 == 3)

    // condition 1: tableType mismatch (L902) -> reset
    let st = LZ4_stream_t()
    dirtyTable(st)
    st.currentOffset = 100u32
    st.tableType = LZ4_TABLE_BYU16
    LZ4_prepareTable(st, 50, LZ4_TABLE_BYU32)
    @Assert(tableIsZero(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)

    // condition 2: byU16 currentOffset+inputSize >= 0xFFFF (L903) -> reset
    dirtyTable(st)
    st.currentOffset = 60000u32
    st.tableType = LZ4_TABLE_BYU16
    LZ4_prepareTable(st, 10000, LZ4_TABLE_BYU16)
    @Assert(tableIsZero(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)
    // ... and the non-trigger: small offset + small input reuses (no 64KB gap for byU16)
    dirtyTable(st)
    st.currentOffset = 100u32
    st.tableType = LZ4_TABLE_BYU16
    LZ4_prepareTable(st, 200, LZ4_TABLE_BYU16)
    @Assert(tableIsDirty(st) && st.currentOffset == 100u32 && st.tableType == LZ4_TABLE_BYU16)

    // condition 3: byU32 currentOffset > 1 GB (L904) -> reset
    dirtyTable(st)
    st.currentOffset = 0x40000001u32
    st.tableType = LZ4_TABLE_BYU32
    LZ4_prepareTable(st, 100, LZ4_TABLE_BYU32)
    @Assert(tableIsZero(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)
    // boundary: currentOffset == 1 GB is NOT > 1 GB -> reuse + 64KB gap (L918-920)
    dirtyTable(st)
    st.currentOffset = 0x40000000u32
    st.tableType = LZ4_TABLE_BYU32
    LZ4_prepareTable(st, 100, LZ4_TABLE_BYU32)
    @Assert(tableIsDirty(st) && st.currentOffset == 0x40010000u32 && st.tableType == LZ4_TABLE_BYU32)

    // condition 4: requested tableType == byPtr (L905) -> reset (term kept for
    // fidelity; our 64-bit core never requests byPtr)
    dirtyTable(st)
    st.currentOffset = 10u32
    st.tableType = LZ4_TABLE_BYU16
    LZ4_prepareTable(st, 10, LZ4_TABLE_BYPTR)
    @Assert(tableIsZero(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)

    // condition 5: inputSize >= 4 KB (L906) -> reset
    dirtyTable(st)
    st.currentOffset = 10u32
    st.tableType = LZ4_TABLE_BYU16
    LZ4_prepareTable(st, 4096, LZ4_TABLE_BYU16)
    @Assert(tableIsZero(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)
    // non-trigger: 4095 reuses
    dirtyTable(st)
    st.currentOffset = 10u32
    st.tableType = LZ4_TABLE_BYU16
    LZ4_prepareTable(st, 4095, LZ4_TABLE_BYU16)
    @Assert(tableIsDirty(st) && st.currentOffset == 10u32 && st.tableType == LZ4_TABLE_BYU16)

    // clearedTable passthrough (L900): tableType == clearedTable skips the
    // reset block entirely (C trusts the marker; a dirty table stays dirty)
    dirtyTable(st)
    st.currentOffset = 0u32
    st.tableType = LZ4_TABLE_CLEARED
    LZ4_prepareTable(st, 100, LZ4_TABLE_BYU16)
    @Assert(tableIsDirty(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)

    // 64KB gap only for byU32 with currentOffset != 0 (L918-920): reset path
    // leaves currentOffset 0 -> no gap
    dirtyTable(st)
    st.currentOffset = 5000u32
    st.tableType = LZ4_TABLE_BYU32
    LZ4_prepareTable(st, 5000, LZ4_TABLE_BYU32)   // inputSize >= 4KB -> reset
    @Assert(st.currentOffset == 0u32)             // no gap after reset

    // dictionary history cleared unconditionally (L924-926), reset and reuse paths
    dirtyTable(st)
    st.currentOffset = 100u32
    st.tableType = LZ4_TABLE_BYU16
    dirtyDict(st)
    LZ4_prepareTable(st, 200, LZ4_TABLE_BYU16)    // reuse path
    @Assert(dictIsClear(st))
    dirtyTable(st)
    st.currentOffset = 10u32
    st.tableType = LZ4_TABLE_BYU16
    dirtyDict(st)
    LZ4_prepareTable(st, 4096, LZ4_TABLE_BYU16)   // reset path
    @Assert(dictIsClear(st))
    st.currentOffset = 0u32
    st.tableType = LZ4_TABLE_CLEARED
    dirtyDict(st)
    LZ4_prepareTable(st, 100, LZ4_TABLE_BYU16)    // cleared passthrough
    @Assert(dictIsClear(st))
    println("prepareTable: 5 reset conditions + reuse/gap/dict-clear pinned")
}

@Test
func lz4ResetStreamTest(): Unit {
    // LZ4_resetStream (L1573-1577): MEM_INIT of the whole internal state =
    // full re-init semantics (== initStream)
    let st = LZ4_stream_t()
    dirtyTable(st)
    st.currentOffset = 12345u32
    st.tableType = LZ4_TABLE_BYU16
    dirtyDict(st)
    LZ4_resetStream(st)
    @Assert(tableIsZero(st) && st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED)
    @Assert(dictIsClear(st))

    // LZ4_resetStream_fast (L1579-1580) = LZ4_prepareTable(ctx, 0, byU32):
    // on a byU32 state with small currentOffset it REUSES the table and
    // adds the 64KB gap (it is NOT a full reset)
    let st2 = LZ4_stream_t()
    dirtyTable(st2)
    st2.currentOffset = 100u32
    st2.tableType = LZ4_TABLE_BYU32
    dirtyDict(st2)
    LZ4_resetStream_fast(st2)
    @Assert(tableIsDirty(st2) && st2.currentOffset == 100u32 + 65536u32 && st2.tableType == LZ4_TABLE_BYU32)
    @Assert(dictIsClear(st2))

    // on a byU16 state the byU32 request mismatches -> full reset
    dirtyTable(st2)
    st2.currentOffset = 100u32
    st2.tableType = LZ4_TABLE_BYU16
    LZ4_resetStream_fast(st2)
    @Assert(tableIsZero(st2) && st2.currentOffset == 0u32 && st2.tableType == LZ4_TABLE_CLEARED)

    // on a FRESH state both variants are equivalent (all fields stay zero)
    let st3 = LZ4_stream_t()
    LZ4_resetStream_fast(st3)
    @Assert(tableIsZero(st3) && st3.currentOffset == 0u32 && st3.tableType == LZ4_TABLE_CLEARED)
    @Assert(dictIsClear(st3))
    let st4 = LZ4_stream_t()
    LZ4_resetStream(st4)
    @Assert(tableIsZero(st4) && st4.currentOffset == 0u32 && st4.tableType == LZ4_TABLE_CLEARED)
    println("resetStream: full re-init vs prepareTable(0, byU32) semantics pinned")
}

@Test
func lz4CreateFreeStreamTest(): Unit {
    // LZ4_createStream (L1540-1549): allocation + initStream -> fresh state
    let s = LZ4_createStream()
    @Assert(tableIsZero(s) && s.currentOffset == 0u32 && s.tableType == LZ4_TABLE_CLEARED)
    @Assert(dictIsClear(s))
    // smoke: compress through the created stream (fastReset then plain)
    let buf = Array<UInt8>(512, {_ => 0u8})
    RDG_genBuffer(buf, 512, 0.9, 0.0, 501u32)
    let bound = Int64(LZ4_compressBound(512))
    let out = Array<UInt8>(bound, {_ => 0u8})
    let c1 = LZ4_compress_fast_extState_fastReset(s, buf, 512, out, Int32(bound), 1)
    @Assert(c1 > 0)
    @Assert(s.currentOffset == 512u32 && s.tableType == LZ4_TABLE_BYU16)
    // LZ4_freeStream (L1584-1591): returns 0 (C frees; Cangjie GC reclaims)
    @Assert(LZ4_freeStream(s) == 0)
    println("createStream/freeStream smoke: fresh state + roundtrip + free=0")
}

/*-************************************
*  M3b Tasks 2-4: streaming compression golden + roundtrip + edges
**************************************/
/* Rows 310..356 of corpus/block_golden_ref.txt: 46 streaming-compression
   rows (7 cont + 1 cont0 anchor + 6 savedict + 8 dictfast + 8 dictslow +
   4 attach + 6 extdict + 6 destext), generated by probes/gen_golden.c.
   Buffer geometries replicate the manifest # comments; every compress uses
   accel=1 and dstCapacity=compressBound => notLimited. off=/tt= pin the
   post-call C state: continue/loadDict rows are always byU32 (tt=2) since
   streaming may carry dictionaries, which requires 32-bit offsets
   (upstream lz4.c streaming section preamble). */

// RDG has no offset parameter; generation is a sequential stream, so
// generate-then-copy reproduces C's in-place region generation exactly
// (the same prefix property the seed=99 dict-sharing rows rely on).
private func rdgRegion(dst: Array<UInt8>, off: Int64, len: Int64, mp: Float64, seed: UInt32): Unit {
    let tmp = Array<UInt8>(len, {_ => 0u8})
    RDG_genBuffer(tmp, len, mp, 0.0, seed)
    var i: Int64 = 0
    while (i < len) {
        dst[off + i] = tmp[i]
        i += 1
    }
}

// cont geometry (manifest line 315): blocks 0-5 = 40960 each (0-2 from the
// seed-501 mp=0.50 region, 3-5 from seed-502 mp=0.90), block 6 = 16384
// (seed-503 mp=0.50 tail). Returns (srcIdx, n, mp, seed).
private func contBlockInfo(seq: Int64): (Int64, Int64, Float64, UInt32) {
    if (seq < 6) {
        return (seq * 40960, 40960, if (seq < 3) { 0.50 } else { 0.90 }, UInt32(501 + seq / 3))
    }
    return (245760, 16384, 0.50, 503u32)
}

private func contSourceBuffer(): Array<UInt8> {
    let buf = Array<UInt8>(262144, {_ => 0u8})
    rdgRegion(buf, 0, 122880, 0.50, 501u32)
    rdgRegion(buf, 122880, 122880, 0.90, 502u32)
    rdgRegion(buf, 245760, 16384, 0.50, 503u32)
    return buf
}

// (seq, size, xxh32, xxh64, inxxh32, inxxh64, off, fileRowIdx)
let CONT_REF: Array<(Int64, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, Int64)> = [
    (0, 20143, 0x0d711d17u32, 0xb8c605e29392a2f0u64, 0x1d4fdcfeu32, 0x57f20e3137dcc4f5u64, 40960u32, 310),
    (1, 26011, 0xc6dfc6d4u32, 0x508cce362fb6d4cdu64, 0xf24c3394u32, 0x1666d0d299a4db1du64, 81920u32, 311),
    (2, 26215, 0x9efd201fu32, 0x724838d39f15d582u64, 0xad23e199u32, 0xcdcaeaeea1a8b6e9u64, 122880u32, 312),
    (3, 6796, 0x3e27e37eu32, 0x824923ade96fcad9u64, 0x8ecd4ec7u32, 0x4b6a1a182a8c5858u64, 163840u32, 313),
    (4, 6389, 0x5ca1e4f8u32, 0xdcdbd7af79c36406u64, 0x2ece46b7u32, 0x2e4f6b09bbe8adfcu64, 204800u32, 314),
    (5, 7941, 0x341be888u32, 0xf3c733727577bc7eu64, 0x0c35e453u32, 0x9b53b754ee032115u64, 245760u32, 315),
    (6, 8864, 0x936c2210u32, 0x970f84a4345a61b0u64, 0x940216dfu32, 0x5e455b7c6a774e31u64, 262144u32, 316),
]

@Test
func lz4CompressContinueGoldenTest(): Unit {
    let buf = contSourceBuffer()
    // stack stream (LZ4_initStream) per the manifest geometry
    let stream = LZ4_stream_t()
    @Assert(LZ4_initStream(stream) == 0)
    let bound = LZ4_compressBound(40960)
    let out = Array<UInt8>(Int64(bound), {_ => 0u8})
    var checked = 0
    var fileCompared = 0
    var firstSize: Int32 = 0
    for ((seq, wantSize, want32, want64, wantIn32, wantIn64, wantOff, fileRow) in CONT_REF) {
        let (off0, n, _, _) = contBlockInfo(seq)
        // slice provenance pinned by the C-side input digests
        @Assert(sliceXXH32(buf, off0, n) == wantIn32)
        @Assert(sliceXXH64(buf, off0, n) == wantIn64)
        let c = LZ4_compress_fast_continue(stream, buf, off0, Int32(n), out, bound, 1)
        if (c != wantSize) {
            println("CONT seq=${seq}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("CONT DIGEST seq=${seq}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        // post-call state: prefix mode accumulates currentOffset and dictSize
        if (stream.currentOffset != wantOff) {
            println("CONT STATE seq=${seq}: off=${stream.currentOffset} want ${wantOff}")
        }
        @Assert(stream.currentOffset == wantOff)
        @Assert(stream.tableType == LZ4_TABLE_BYU32)
        @Assert(stream.dictSize == off0 + n)
        // byte-exact comparison against the C-generated artifact
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(c))
        var eq = art.size == Int64(c)
        for (i in 0..Int64(c)) {
            if (UInt8(art[i]) != out[i]) { eq = false; break }
        }
        if (!eq) { println("CONT BYTES differ seq=${seq} row=${fileRow}") }
        @Assert(eq)
        fileCompared += 1
        if (seq == 0) { firstSize = c }
        checked += 1
    }
    @Assert(checked == 7)
    @Assert(fileCompared == 7)
    /* cont0 anchor (row 317): the same block 0 through LZ4_compress_default.
       Divergence note (manifest line 315 / gen_golden.c): a fresh-stream
       continue always compresses byU32 (streaming must assume dictionaries,
       which need 32-bit offsets), while one-shot default picks byU16 below
       the 64 KB limit - two legal encodings of the same block that come out
       different (20143 continue-byU32 vs 19452 default-byU16 here); each
       recorded row pins its own encoder path. */
    let ref = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c0 = LZ4_compress_default(buf, 40960, ref, bound)
    if (c0 != 19452) { println("CONT0: got ${c0} want 19452") }
    @Assert(c0 == 19452)
    @Assert(firstSize == 20143 && c0 != firstSize)   // byU32-vs-byU16 divergence pinned
    @Assert(XXH32(ref, Int64(c0), 0u32) == 0x9f3b56aeu32)
    @Assert(XXH64(ref, Int64(c0), 0u64) == 0xc7261a033ab3bed1u64)
    let art0 = readBlockArtifact(317)
    @Assert(art0.size == Int64(c0))
    var eq0 = art0.size == Int64(c0)
    for (i in 0..Int64(c0)) {
        if (UInt8(art0[i]) != ref[i]) { eq0 = false; break }
    }
    @Assert(eq0)
    println("cont golden: 7 rolling blocks byte-exact + cont0 byU16 anchor (continue byU32 divergence pinned)")
}

// (seq, size, xxh32, xxh64, inxxh32, inxxh64, off, fileRowIdx, saveRetAfter)
// saveRetAfter: LZ4_saveDict(safe, 65536) return after this block (-1 = none)
let SAVEDICT_REF: Array<(Int64, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, Int64, Int32)> = [
    (0, 5477, 0x88d9fbd3u32, 0xbe613fd74041a3c6u64, 0x806da343u32, 0x9c8b7bcbbd2065d8u64, 40960u32, 318, 40960),
    (1, 8701, 0x4e3ba695u32, 0x98817a0156de196bu64, 0x1ddf8fabu32, 0x30c008e7a3cceef9u64, 81920u32, 319, -1),
    (2, 7145, 0xfaffbf31u32, 0x1c34bed6d3269658u64, 0x45c1b0acu32, 0x98ee089a059b1d05u64, 122880u32, 320, -1),
    (3, 8724, 0x84bb93e5u32, 0xec70e0e05832569eu64, 0xfdf9c837u32, 0xcda107622476a275u64, 163840u32, 321, 65536),
    (4, 8666, 0x43251223u32, 0xdbc6968c2b7034a5u64, 0x19de378fu32, 0xe09f3f66fb61ad23u64, 204800u32, 322, -1),
    (5, 8530, 0xa018b547u32, 0x321838e1a0673eb5u64, 0xb005e7c3u32, 0xfc11cf96941ce939u64, 245760u32, 323, -1),
]

@Test
func lz4SaveDictGoldenTest(): Unit {
    let buf = Array<UInt8>(245760, {_ => 0u8})
    RDG_genBuffer(buf, 245760, 0.90, 0.0, 601u32)
    let safe = Array<UInt8>(65536, {_ => 0u8})
    let stream = LZ4_stream_t()
    @Assert(LZ4_initStream(stream) == 0)
    let bound = LZ4_compressBound(40960)
    let out = Array<UInt8>(Int64(bound), {_ => 0u8})
    var checked = 0
    var saved = 0
    for ((seq, wantSize, want32, want64, wantIn32, wantIn64, wantOff, fileRow, saveRet) in SAVEDICT_REF) {
        let off0 = seq * 40960
        @Assert(sliceXXH32(buf, off0, 40960) == wantIn32)
        @Assert(sliceXXH64(buf, off0, 40960) == wantIn64)
        let c = LZ4_compress_fast_continue(stream, buf, off0, 40960, out, bound, 1)
        if (c != wantSize) {
            println("SAVEDICT seq=${seq}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("SAVEDICT DIGEST seq=${seq}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (stream.currentOffset != wantOff) {
            println("SAVEDICT STATE seq=${seq}: off=${stream.currentOffset} want ${wantOff}")
        }
        @Assert(stream.currentOffset == wantOff)
        @Assert(stream.tableType == LZ4_TABLE_BYU32)
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(c))
        var eq = art.size == Int64(c)
        for (i in 0..Int64(c)) {
            if (UInt8(art[i]) != out[i]) { eq = false; break }
        }
        if (!eq) { println("SAVEDICT BYTES differ seq=${seq} row=${fileRow}") }
        @Assert(eq)
        checked += 1
        if (saveRet >= 0) {
            /* relocation: history copied into safeBuffer, state re-pointed.
               seq=0: only 40960 bytes of history exist -> history-limited;
               seq=3: dictSize has accumulated to 122880 -> 64KB-capped. */
            let s = LZ4_saveDict(stream, safe, 65536)
            if (s != saveRet) {
                println("SAVEDICT save seq=${seq}: got ${s} want ${saveRet}")
            }
            @Assert(s == saveRet)
            @Assert(stream.dictSize == Int64(saveRet))
            @Assert(stream.dictStartIdx == 0)
            // saveDict preserves off/tt (manifest note)
            @Assert(stream.currentOffset == wantOff && stream.tableType == LZ4_TABLE_BYU32)
            // relocated content = last saveRet bytes of the compressed history
            let histEnd = (seq + 1) * 40960
            var seq_ = true
            for (i in 0..Int64(saveRet)) {
                if (safe[i] != buf[histEnd - Int64(saveRet) + i]) { seq_ = false; break }
            }
            if (!seq_) { println("SAVEDICT content differ seq=${seq}") }
            @Assert(seq_)
            saved += 1
        }
    }
    @Assert(checked == 6)
    @Assert(saved == 2)
    println("savedict golden: 6 blocks byte-exact across 2 relocations (ret 40960 history-limited / 65536 64KB-capped)")
}

// dictfast + dictslow rows (manifest lines 331/340): dict = RDG(65536,
// mp=0.50, seed=99) (xxh pins below); per-row fresh stream + loadDict vs
// loadDictSlow, all rows take usingExtDict byU32 noDictIssue (dictSize 64KB).
// dictslow artifacts sit exactly 8 manifest rows after the dictfast ones
// (324..331 vs 332..339); size > 65536 rows have no artifact (-1).
// The (4096,0.50,99) input IS the dictionary's own first 4096 bytes (RDG
// is a streaming generator), real shared content where the fast (every 3rd
// position, overwriting) and slow (+1-byte non-overwriting pass) table
// fills pick different candidates - yet the final encodings coincide here.
// (n, mpIdx, seed, size, xxh32, xxh64, inxxh32, inxxh64, off, fileFastRowIdx)
let DICT_REF: Array<(Int64, Int64, UInt32, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, Int64)> = [
    (255, 0, 0u32, 257, 0x42be5aa6u32, 0x1fb93d0dad1a834du64, 0x6e96b077u32, 0xefd4dc746ff90d2eu64, 65791u32, 324),
    (255, 2, 7u32, 11, 0x8ebfdc6du32, 0xf9f9a04a61934aaau64, 0xe9da7969u32, 0xe9e6f65ad9880591u64, 65791u32, 325),
    (4096, 0, 7u32, 4114, 0x833d749cu32, 0xeacc7240615d52b9u64, 0x3b449358u32, 0x560614d60dbfda09u64, 69632u32, 326),
    (4096, 2, 0u32, 430, 0x7d74865au32, 0x69cf680a1dbbdcefu64, 0xf3a05cfbu32, 0x03cce69c58e99124u64, 69632u32, 327),
    (65536, 0, 0u32, 65794, 0x0a92397au32, 0x5c8462a7bf58a498u64, 0x00d020c6u32, 0xe5445c011d57719au64, 131072u32, -1),
    (65536, 2, 7u32, 6723, 0x7c9ce9adu32, 0x6742dc7714939a86u64, 0x99ba8de1u32, 0x3a798cd5ac65353fu64, 131072u32, 329),
    (65537, 1, 3u32, 33264, 0x8e344bd3u32, 0x33e51ce12311b1c1u64, 0xf41b4e18u32, 0xf2b3c896a454d62du64, 131073u32, 330),
    (4096, 1, 99u32, 1122, 0xfa460b8au32, 0x83e22ee94aff90cbu64, 0x7085c0eeu32, 0xebba4e70ddd088c4u64, 69632u32, 331),
]

private func lz4DictGoldenCheck(slow: Bool, tag: String): Unit {
    let dict = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(dict, 65536, 0.5, 0.0, 99u32)
    // dict provenance pinned by the manifest xxh values
    @Assert(XXH32(dict, 65536, 0u32) == 0x059edec2u32)
    @Assert(XXH64(dict, 65536, 0u64) == 0xd41565bb0ecfa4e3u64)
    var checked = 0
    var fileCompared = 0
    for ((n, mpIdx, seed, wantSize, want32, want64, wantIn32, wantIn64, wantOff, fileRowFast) in DICT_REF) {
        let fileRow = if (fileRowFast == -1) { -1 } else if (slow) { fileRowFast + 8 } else { fileRowFast }
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        @Assert(XXH32(buf, n, 0u32) == wantIn32)
        @Assert(XXH64(buf, n, 0u64) == wantIn64)
        // per-row fresh stream + loadDict
        let st = LZ4_createStream()
        let ld = if (slow) {
            LZ4_loadDictSlow(st, dict, 65536)
        } else {
            LZ4_loadDict(st, dict, 65536)
        }
        if (ld != 65536) { println("${tag} n=${n}: loadDict ${ld}") }
        @Assert(ld == 65536)
        @Assert(st.currentOffset == 65536u32 && st.tableType == LZ4_TABLE_BYU32 && st.dictSize == 65536)
        let bound = LZ4_compressBound(Int32(n))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        let c = LZ4_compress_fast_continue(st, buf, 0, Int32(n), out, bound, 1)
        if (c != wantSize) {
            println("${tag} n=${n} seed=${seed}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("${tag} DIGEST n=${n} seed=${seed}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        // post-call state: currentOffset = 64KB(loadDict) + n, dictionary
        // re-pointed at the consumed source block
        if (st.currentOffset != wantOff) {
            println("${tag} STATE n=${n}: off=${st.currentOffset} want ${wantOff}")
        }
        @Assert(st.currentOffset == wantOff)
        @Assert(st.tableType == LZ4_TABLE_BYU32)
        @Assert(st.dictSize == n && st.dictStartIdx == 0)
        if (fileRow >= 0) {
            let art = readBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            var eq = art.size == Int64(c)
            for (i in 0..Int64(c)) {
                if (UInt8(art[i]) != out[i]) { eq = false; break }
            }
            if (!eq) { println("${tag} BYTES differ n=${n} row=${fileRow}") }
            @Assert(eq)
            fileCompared += 1
        }
        checked += 1
    }
    @Assert(checked == 8)
    @Assert(fileCompared == 7)
    println("${tag} golden: 8 rows byte-exact (${fileCompared} artifacts; inputs independent of dict share no matches)")
}

@Test
func lz4LoadDictFastGoldenTest(): Unit {
    lz4DictGoldenCheck(false, "dictfast")
}

@Test
func lz4LoadDictSlowGoldenTest(): Unit {
    lz4DictGoldenCheck(true, "dictslow")
}

// attach rows (manifest line 349): dict stream A (loadDict) + fresh working
// stream B + LZ4_attach_dictionary(B, A) (bumps B->currentOffset to 64KB,
// hangs A as B->dictCtx); continue on B. inputSize<=4096 -> usingDictCtx
// (B's own table + dictCtx fallback; rows 0-1), >4096 -> whole dictCtx
// state copied into B then usingExtDict, one table only (rows 2-3).
// (n, mpIdx, seed, size, xxh32, xxh64, inxxh32, inxxh64, off, fileRowIdx)
let ATTACH_REF: Array<(Int64, Int64, UInt32, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, Int64)> = [
    (255, 2, 0u32, 11, 0x387b105fu32, 0x6ade35f444efe462u64, 0xcbe2766cu32, 0xd1074591b2fa8835u64, 65791u32, 340),
    (4096, 0, 7u32, 4114, 0x833d749cu32, 0xeacc7240615d52b9u64, 0x3b449358u32, 0x560614d60dbfda09u64, 69632u32, 341),
    (4097, 1, 3u32, 2772, 0xdd1f8842u32, 0x6f1eb699fce1930bu64, 0x324bf5e7u32, 0xbfbb9c11c66935b2u64, 69633u32, 342),
    (65536, 0, 0u32, 65794, 0x0a92397au32, 0x5c8462a7bf58a498u64, 0x00d020c6u32, 0xe5445c011d57719au64, 131072u32, -1),
]

@Test
func lz4AttachDictGoldenTest(): Unit {
    let dict = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(dict, 65536, 0.5, 0.0, 99u32)
    @Assert(XXH32(dict, 65536, 0u32) == 0x059edec2u32)
    @Assert(XXH64(dict, 65536, 0u64) == 0xd41565bb0ecfa4e3u64)
    var checked = 0
    var fileCompared = 0
    var dictCtxRows = 0
    var copyRows = 0
    for ((n, mpIdx, seed, wantSize, want32, want64, wantIn32, wantIn64, wantOff, fileRow) in ATTACH_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        @Assert(XXH32(buf, n, 0u32) == wantIn32)
        @Assert(XXH64(buf, n, 0u64) == wantIn64)
        let dstream = LZ4_createStream()
        @Assert(LZ4_loadDict(dstream, dict, 65536) == 65536)
        let wstream = LZ4_createStream()
        LZ4_attach_dictionary(wstream, dstream)
        // attach contract: offset bumped to 64KB, dictCtx hung
        @Assert(wstream.currentOffset == 65536u32 && wstream.dictCtx.isSome())
        let bound = LZ4_compressBound(Int32(n))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        let c = LZ4_compress_fast_continue(wstream, buf, 0, Int32(n), out, bound, 1)
        if (c != wantSize) {
            println("ATTACH n=${n} seed=${seed}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("ATTACH DIGEST n=${n} seed=${seed}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (wstream.currentOffset != wantOff) {
            println("ATTACH STATE n=${n}: off=${wstream.currentOffset} want ${wantOff}")
        }
        @Assert(wstream.currentOffset == wantOff)
        @Assert(wstream.tableType == LZ4_TABLE_BYU32)
        @Assert(wstream.dictSize == n && wstream.dictStartIdx == 0)
        if (n <= 4096) {
            dictCtxRows += 1     // usingDictCtx: B's table + dictCtx fallback
        } else {
            copyRows += 1        // dictCtx state copy + usingExtDict
        }
        if (fileRow >= 0) {
            let art = readBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            var eq = art.size == Int64(c)
            for (i in 0..Int64(c)) {
                if (UInt8(art[i]) != out[i]) { eq = false; break }
            }
            if (!eq) { println("ATTACH BYTES differ n=${n} row=${fileRow}") }
            @Assert(eq)
            fileCompared += 1
        }
        checked += 1
    }
    @Assert(checked == 4)
    @Assert(fileCompared == 3)
    @Assert(dictCtxRows == 2 && copyRows == 2)
    println("attach golden: 4 rows byte-exact (2 usingDictCtx + 2 table-copy usingExtDict)")
}

// extdict rows (manifest line 354): twin buffers with identical RDG content
// per scenario; the block source zig-zags A/B/A so every block after the
// first takes usingExtDict with the dictionary living in the OTHER
// allocation (dictEnd never equals source). scen0: seed=711 mp=0.90,
// 3x40960 (seq 0-2); scen1: seed=712 mp=0.50, 3x65536 (seq 3-5).
// (seq, size, xxh32, xxh64, inxxh32, inxxh64, off, fileRowIdx)
let EXTDICT_REF: Array<(Int64, Int32, UInt32, UInt64, UInt32, UInt64, UInt32, Int64)> = [
    (0, 5536, 0x84ab5fffu32, 0xd880f670e6b2bbf7u64, 0xfc9157d5u32, 0x31ca4729b9c01c1fu64, 40960u32, 344),
    (1, 6513, 0x6a451de6u32, 0xe3bd26a1a9377a36u64, 0x9a36eb47u32, 0x2f9ad61527444543u64, 81920u32, 345),
    (2, 7519, 0x66c8e661u32, 0x19680b7567db384du64, 0x75eb1f42u32, 0x0077e0083574567bu64, 122880u32, 346),
    (3, 36707, 0x0b84822cu32, 0x5363303bdbc4f945u64, 0x787c0118u32, 0xa29be2f252fface4u64, 65536u32, 347),
    (4, 41567, 0xc920f69fu32, 0xa108b5398af270f8u64, 0x07341a6eu32, 0xaf8a3215a40c0cabu64, 131072u32, 348),
    (5, 42910, 0xd13915a7u32, 0xd5ebaae3e88dc073u64, 0xd018602eu32, 0x55db4ba83898e211u64, 196608u32, 349),
]

@Test
func lz4ExtDictGoldenTest(): Unit {
    var checked = 0
    var fileCompared = 0
    var cs: Option<LZ4_stream_t> = None
    var bufs: Option<Array<Array<UInt8>>> = None
    for ((seq, wantSize, want32, want64, wantIn32, wantIn64, wantOff, fileRow) in EXTDICT_REF) {
        let scen: Int64 = seq / 3
        let k: Int64 = seq % 3
        let block: Int64 = if (scen == 0) { 40960 } else { 65536 }
        let mp: Float64 = if (scen == 0) { 0.90 } else { 0.50 }
        let seed: UInt32 = if (scen == 0) { 711u32 } else { 712u32 }
        if (k == 0) {
            // fresh stream + twin buffers per scenario
            let s = LZ4_createStream()
            let total = 3 * block
            let twins = [Array<UInt8>(total, {_ => 0u8}), Array<UInt8>(total, {_ => 0u8})]
            RDG_genBuffer(twins[0], total, mp, 0.0, seed)
            RDG_genBuffer(twins[1], total, mp, 0.0, seed)
            cs = Some(s)
            bufs = Some(twins)
        }
        let stream = cs.getOrThrow()
        let twins = bufs.getOrThrow()
        let src = twins[k % 2]          // zig-zag A/B/A: cross-buffer extDict
        let off0 = k * block
        @Assert(sliceXXH32(src, off0, block) == wantIn32)
        @Assert(sliceXXH64(src, off0, block) == wantIn64)
        let bound = LZ4_compressBound(Int32(block))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        let c = LZ4_compress_fast_continue(stream, src, off0, Int32(block), out, bound, 1)
        if (c != wantSize) {
            println("EXTDICT seq=${seq}: got ${c} want ${wantSize}")
        }
        @Assert(c == wantSize)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("EXTDICT DIGEST seq=${seq}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        if (stream.currentOffset != wantOff) {
            println("EXTDICT STATE seq=${seq}: off=${stream.currentOffset} want ${wantOff}")
        }
        @Assert(stream.currentOffset == wantOff)
        @Assert(stream.tableType == LZ4_TABLE_BYU32)
        @Assert(stream.dictSize == block && stream.dictStartIdx == off0)
        let art = readBlockArtifact(fileRow)
        @Assert(art.size == Int64(c))
        var eq = art.size == Int64(c)
        for (i in 0..Int64(c)) {
            if (UInt8(art[i]) != out[i]) { eq = false; break }
        }
        if (!eq) { println("EXTDICT BYTES differ seq=${seq} row=${fileRow}") }
        @Assert(eq)
        fileCompared += 1
        checked += 1
    }
    @Assert(checked == 6)
    @Assert(fileCompared == 6)
    println("extdict golden: 6 zig-zag blocks byte-exact (cross-buffer references forced)")
}

// destext rows (manifest line 361): LZ4_compress_destSize_extState(accel=1)
// with ONE shared stream state - the wrapper re-initializes on exit
// (lz4.c L1510), so later rows reuse a state a port skipping the cleanup
// would leave dirty. Per input two rows: tg = n*3/2 >= compressBound =>
// extState delegation (*srcSizePtr untouched => consumed = n, output
// byte-identical to plain default compression); tg = n*3/4 => real
// fillOutput (consumed <= n; whole input below target => all consumed).
// (n, mpIdx, seed, tg, size, consumed, xxh32, xxh64, fileRowIdx)
let DESTEXT_REF: Array<(Int64, Int64, UInt32, Int32, Int32, Int32, UInt32, UInt64, Int64)> = [
    (4096, 0, 801u32, 6144, 4114, 4096, 0x08f85529u32, 0x7e6690e991374e52u64, 350),
    (4096, 0, 801u32, 3072, 3072, 3059, 0x3e3f296bu32, 0x8db760879ba4fa73u64, 351),
    (65536, 1, 802u32, 98304, 33368, 65536, 0xfdb4005au32, 0x22fad74ef55e859fu64, 352),
    (65536, 1, 802u32, 49152, 33368, 65536, 0xfdb4005au32, 0x22fad74ef55e859fu64, 353),
    (131072, 0, 803u32, 196608, 131587, 131072, 0x78410cbau32, 0x7f6ee26b91cadbecu64, -1),
    (131072, 0, 803u32, 98304, 98304, 97919, 0xe202c7aeu32, 0x7bdc460baac80596u64, -1),
]

@Test
func lz4DestSizeExtStateGoldenTest(): Unit {
    let st = LZ4_createStream()      // ONE shared state for all 6 rows
    var checked = 0
    var delegations = 0
    var fills = 0
    var fileCompared = 0
    for ((n, mpIdx, seed, tg, wantSize, wantConsumed, want32, want64, fileRow) in DESTEXT_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = LZ4_compressBound(Int32(n))
        let cap: Int32 = if (tg > bound) { tg } else { bound }
        let out = Array<UInt8>(Int64(cap) + 16, {_ => 0u8})
        let (c, consumed) = LZ4_compress_destSize_extState(st, buf, Int32(n), out, tg, 1)
        if (c != wantSize || consumed != wantConsumed) {
            println("DESTEXT n=${n} tg=${tg}: got (${c}, ${consumed}) want (${wantSize}, ${wantConsumed})")
        }
        @Assert(c == wantSize)
        @Assert(consumed == wantConsumed)
        let got32 = XXH32(out, Int64(c), 0u32)
        let got64 = XXH64(out, Int64(c), 0u64)
        if (got32 != want32 || got64 != want64) {
            println("DESTEXT DIGEST n=${n} tg=${tg}: got ${blkHex32(got32)}/${blkHex64(got64)} want ${blkHex32(want32)}/${blkHex64(want64)}")
        }
        @Assert(got32 == want32)
        @Assert(got64 == want64)
        // exit-cleanliness pin (lz4.c L1510): every call leaves a reusable state
        @Assert(st.currentOffset == 0u32 && st.tableType == LZ4_TABLE_CLEARED && dictIsClear(st))
        // fillOutput emits a complete block of exactly the consumed prefix
        let dec = Array<UInt8>(n, {_ => 0u8})
        @Assert(LZ4_decompress_safe(out, c, dec, consumed) == consumed)
        var eq = true
        for (i in 0..Int64(consumed)) {
            if (dec[i] != buf[i]) { eq = false; break }
        }
        if (!eq) { println("DESTEXT prefix decode differs n=${n} tg=${tg}") }
        @Assert(eq)
        if (Int64(tg) >= Int64(bound)) {
            // delegation: srcSizePtr untouched (consumed == n) and output
            // byte-identical to plain default compression of the same input
            delegations += 1
            @Assert(consumed == Int32(n))
            let ref = Array<UInt8>(Int64(cap) + 16, {_ => 0u8})
            let d = LZ4_compress_default(buf, Int32(n), ref, bound)
            @Assert(d == c)
            var eqd = d == c
            for (i in 0..Int64(c)) {
                if (ref[i] != out[i]) { eqd = false; break }
            }
            if (!eqd) { println("DESTEXT delegation != default n=${n}") }
            @Assert(eqd)
        } else {
            // real fillOutput: target reached (or input exhausted below it)
            fills += 1
            @Assert(c <= tg)
            @Assert(consumed <= Int32(n))
        }
        if (fileRow >= 0) {
            let art = readBlockArtifact(fileRow)
            @Assert(art.size == Int64(c))
            var eqa = art.size == Int64(c)
            for (i in 0..Int64(c)) {
                if (UInt8(art[i]) != out[i]) { eqa = false; break }
            }
            if (!eqa) { println("DESTEXT BYTES differ n=${n} tg=${tg} row=${fileRow}") }
            @Assert(eqa)
            fileCompared += 1
        }
        checked += 1
    }
    @Assert(checked == 6)
    @Assert(delegations == 3 && fills == 3)
    @Assert(fileCompared == 4)
    println("destext golden: 6 rows exact on one shared stream (3 delegations + 3 fillOutput, state cleaned between calls)")
}

/*-************************************
*  M3b Task 3: closed-loop streaming roundtrips
**************************************/
// cont geometry: Cangjie continue sequences decoded by the Cangjie
// LZ4_decompress_safe_continue at the same buffer positions
private func rtCont(): Int64 {
    let buf = contSourceBuffer()
    let cs = LZ4_stream_t()
    @Assert(LZ4_initStream(cs) == 0)
    let sd = LZ4_createStreamDecode()
    let dst = Array<UInt8>(262144, {_ => 0u8})
    var blocks: Int64 = 0
    for (k in 0..7) {
        let (off0, n, _, _) = contBlockInfo(k)
        let bound = LZ4_compressBound(Int32(n))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        let c = LZ4_compress_fast_continue(cs, buf, off0, Int32(n), out, bound, 1)
        @Assert(c > 0)
        let r = LZ4_decompress_safe_continue(sd, out, c, dst, off0, Int32(n))
        if (r != Int32(n)) { println("RT-CONT k=${k}: decode ${r}") }
        @Assert(r == Int32(n))
        var eq = true
        var i: Int64 = 0
        while (i < n) {
            if (dst[off0 + i] != buf[off0 + i]) { eq = false; break }
            i += 1
        }
        if (!eq) { println("RT-CONT k=${k}: bytes differ") }
        @Assert(eq)
        blocks += 1
    }
    @Assert(LZ4_freeStreamDecode(sd) == 0)
    return blocks
}

// savedict geometry: the dictionary relocations are invisible to the
// decoder (identical content), so rolling continue-decode still closes
private func rtSavedict(): Int64 {
    let buf = Array<UInt8>(245760, {_ => 0u8})
    RDG_genBuffer(buf, 245760, 0.90, 0.0, 601u32)
    let safe = Array<UInt8>(65536, {_ => 0u8})
    let cs = LZ4_createStream()
    let sd = LZ4_createStreamDecode()
    let dst = Array<UInt8>(245760, {_ => 0u8})
    let bound = LZ4_compressBound(40960)
    let out = Array<UInt8>(Int64(bound), {_ => 0u8})
    var blocks: Int64 = 0
    for (k in 0..6) {
        let off0 = k * 40960
        let c = LZ4_compress_fast_continue(cs, buf, off0, 40960, out, bound, 1)
        @Assert(c > 0)
        let r = LZ4_decompress_safe_continue(sd, out, c, dst, off0, 40960)
        if (r != 40960) { println("RT-SAVEDICT k=${k}: decode ${r}") }
        @Assert(r == 40960)
        var eq = true
        var i: Int64 = 0
        while (i < 40960) {
            if (dst[off0 + i] != buf[off0 + i]) { eq = false; break }
            i += 1
        }
        if (!eq) { println("RT-SAVEDICT k=${k}: bytes differ") }
        @Assert(eq)
        blocks += 1
        if (k == 0 || k == 3) {
            let expect: Int32 = if (k == 0) { 40960 } else { 65536 }
            @Assert(LZ4_saveDict(cs, safe, 65536) == expect)
        }
    }
    @Assert(LZ4_freeStreamDecode(sd) == 0)
    return blocks
}

// extdict twin zig-zag: decoder rolls through one linear dst twin
private func rtExtdict(): Int64 {
    var blocks: Int64 = 0
    for (scen in 0..2) {
        let block: Int64 = if (scen == 0) { 40960 } else { 65536 }
        let total = 3 * block
        let mp: Float64 = if (scen == 0) { 0.90 } else { 0.50 }
        let seed: UInt32 = if (scen == 0) { 711u32 } else { 712u32 }
        let twins = [Array<UInt8>(total, {_ => 0u8}), Array<UInt8>(total, {_ => 0u8})]
        RDG_genBuffer(twins[0], total, mp, 0.0, seed)
        RDG_genBuffer(twins[1], total, mp, 0.0, seed)
        let cs = LZ4_createStream()
        let sd = LZ4_createStreamDecode()
        let dst = Array<UInt8>(total, {_ => 0u8})
        let bound = LZ4_compressBound(Int32(block))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        for (k in 0..3) {
            let src = twins[k % 2]
            let off0 = k * block
            let c = LZ4_compress_fast_continue(cs, src, off0, Int32(block), out, bound, 1)
            @Assert(c > 0)
            let r = LZ4_decompress_safe_continue(sd, out, c, dst, off0, Int32(block))
            if (r != Int32(block)) { println("RT-EXTDICT scen=${scen} k=${k}: decode ${r}") }
            @Assert(r == Int32(block))
            var eq = true
            var i: Int64 = 0
            while (i < block) {
                if (dst[off0 + i] != src[off0 + i]) { eq = false; break }
                i += 1
            }
            if (!eq) { println("RT-EXTDICT scen=${scen} k=${k}: bytes differ") }
            @Assert(eq)
            blocks += 1
        }
    }
    return blocks
}

// loadDict (fast + slow) and attach compressions decoded by
// LZ4_decompress_safe_usingDict
private func rtDictModes(): Int64 {
    let dict = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(dict, 65536, 0.5, 0.0, 99u32)
    var cases: Int64 = 0
    for ((n, mpIdx, seed, _, _, _, _, _, _, _) in DICT_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = LZ4_compressBound(Int32(n))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        let dst = Array<UInt8>(n, {_ => 0u8})
        for (slow in [false, true]) {
            let st = LZ4_createStream()
            let ld = if (slow) {
                LZ4_loadDictSlow(st, dict, 65536)
            } else {
                LZ4_loadDict(st, dict, 65536)
            }
            @Assert(ld == 65536)
            let c = LZ4_compress_fast_continue(st, buf, 0, Int32(n), out, bound, 1)
            @Assert(c > 0)
            let r = LZ4_decompress_safe_usingDict(out, c, dst, Int32(n), dict, 65536)
            if (r != Int32(n)) { println("RT-DICT n=${n} slow=${slow}: decode ${r}") }
            @Assert(r == Int32(n))
            var eq = true
            for (i in 0..n) {
                if (dst[i] != buf[i]) { eq = false; break }
            }
            if (!eq) { println("RT-DICT n=${n} slow=${slow}: bytes differ") }
            @Assert(eq)
            cases += 1
        }
    }
    for ((n, mpIdx, seed, _, _, _, _, _, _, _) in ATTACH_REF) {
        let buf = Array<UInt8>(n, {_ => 0u8})
        RDG_genBuffer(buf, n, BLOCK_MPS[mpIdx], 0.0, seed)
        let bound = LZ4_compressBound(Int32(n))
        let out = Array<UInt8>(Int64(bound), {_ => 0u8})
        let dst = Array<UInt8>(n, {_ => 0u8})
        let dstream = LZ4_createStream()
        @Assert(LZ4_loadDict(dstream, dict, 65536) == 65536)
        let wstream = LZ4_createStream()
        LZ4_attach_dictionary(wstream, dstream)
        let c = LZ4_compress_fast_continue(wstream, buf, 0, Int32(n), out, bound, 1)
        @Assert(c > 0)
        let r = LZ4_decompress_safe_usingDict(out, c, dst, Int32(n), dict, 65536)
        if (r != Int32(n)) { println("RT-ATTACH n=${n}: decode ${r}") }
        @Assert(r == Int32(n))
        var eq = true
        for (i in 0..n) {
            if (dst[i] != buf[i]) { eq = false; break }
        }
        if (!eq) { println("RT-ATTACH n=${n}: bytes differ") }
        @Assert(eq)
        cases += 1
    }
    return cases
}

@Test
func lz4StreamingRoundtripTest(): Unit {
    let contBlocks = rtCont()
    let savedictBlocks = rtSavedict()
    let extdictBlocks = rtExtdict()
    let dictCases = rtDictModes()
    @Assert(contBlocks == 7)
    @Assert(savedictBlocks == 6)
    @Assert(extdictBlocks == 6)
    @Assert(dictCases == 20)   // 8 dictfast + 8 dictslow + 4 attach
    println("streaming roundtrips: ${contBlocks} cont + ${savedictBlocks} savedict + ${extdictBlocks} extdict blocks + ${dictCases} dict/attach cases closed")
}

/*-************************************
*  M3b Task 4: streaming compression edges / error contracts
**************************************/
@Test
func lz4StreamingEdgeTest(): Unit {
    // 1) continue with insufficient dstCapacity -> 0 (limitedOutput); C
    //    leaves the stream broken (lz4.h contract), reset before reuse
    let buf = Array<UInt8>(40960, {_ => 0u8})
    RDG_genBuffer(buf, 40960, 0.5, 0.0, 501u32)
    let st = LZ4_createStream()
    let small = Array<UInt8>(64, {_ => 0u8})
    @Assert(LZ4_compress_fast_continue(st, buf, 0, 40960, small, 64, 1) == 0)
    LZ4_resetStream(st)
    let bound = LZ4_compressBound(40960)
    let out = Array<UInt8>(Int64(bound), {_ => 0u8})
    let c = LZ4_compress_fast_continue(st, buf, 0, 40960, out, bound, 1)
    @Assert(c == 20143)   // == golden cont seq=0 after the reset
    // block-position contract of the (srcBuf, srcIdx) pair (C: caller
    // pointer contract; here a defensive 0)
    @Assert(LZ4_compress_fast_continue(st, buf, 1, 40960, out, bound, 1) == 0)
    @Assert(LZ4_compress_fast_continue(st, buf, -1, 40960, out, bound, 1) == 0)
    @Assert(LZ4_compress_fast_continue(st, buf, 0, -1, out, bound, 1) == 0)

    // 2) saveDict return semantics (C-probed): fresh stream -> 0;
    //    dictSize=0 -> 0; dictSize=-1 -> 0 (unsigned clamp then
    //    history-limited); history shorter than request -> history length
    let safe = Array<UInt8>(65536, {_ => 0u8})
    let fresh = LZ4_createStream()
    @Assert(LZ4_saveDict(fresh, safe, 65536) == 0)
    @Assert(LZ4_saveDict(fresh, safe, 0) == 0)
    @Assert(LZ4_saveDict(fresh, safe, -1) == 0)
    let st2 = LZ4_createStream()
    let b2 = Array<UInt8>(1000, {_ => 0u8})
    RDG_genBuffer(b2, 1000, 0.5, 0.0, 9u32)
    let bound2 = LZ4_compressBound(1000)
    let o2 = Array<UInt8>(Int64(bound2), {_ => 0u8})
    @Assert(LZ4_compress_fast_continue(st2, b2, 0, 1000, o2, bound2, 1) > 0)
    @Assert(LZ4_saveDict(st2, safe, 65536) == 1000)   // history-limited
    var eq = true
    for (i in 0..1000) {
        if (safe[i] != b2[i]) { eq = false; break }
    }
    @Assert(eq)
    // (64KB-capped return is covered by the savedict golden seq=3 save)

    // 3) loadDict early exits: dictSize < HASH_UNIT(8) -> 0, AFTER the
    //    reset + 64KB offset bump (C lz4.c L1612-1622); full reload then
    //    still returns dictSize. Oversize is C-UB, defended as 0 here.
    let dict = Array<UInt8>(65536, {_ => 0u8})
    RDG_genBuffer(dict, 65536, 0.5, 0.0, 99u32)
    let st3 = LZ4_createStream()
    @Assert(LZ4_loadDict(st3, dict, 7) == 0)
    @Assert(st3.currentOffset == 65536u32 && st3.dictSize == 0 && st3.dictBuf.isNone())
    @Assert(LZ4_loadDict(st3, dict, 0) == 0)
    @Assert(LZ4_loadDict(st3, dict, 65536) == 65536)
    @Assert(LZ4_loadDict(st3, dict, 65537) == 0)

    // 4) attach fallback: a dictionary stream without loadDict does not
    //    attach (upstream L1688-1690 "don't attach an empty dictionary");
    //    only the currentOffset bump happens, and the output is
    //    byte-identical to a plain fresh-stream continue (C-probed)
    let w = LZ4_createStream()
    let d = LZ4_createStream()
    LZ4_attach_dictionary(w, d)
    @Assert(w.currentOffset == 65536u32)
    @Assert(w.dictCtx.isNone())
    let ab = Array<UInt8>(255, {_ => 0u8})
    RDG_genBuffer(ab, 255, 0.9, 0.0, 0u32)
    let boundA = LZ4_compressBound(255)
    let oA = Array<UInt8>(Int64(boundA), {_ => 0u8})
    let cA = LZ4_compress_fast_continue(w, ab, 0, 255, oA, boundA, 1)
    let p = LZ4_createStream()
    let oP = Array<UInt8>(Int64(boundA), {_ => 0u8})
    let cP = LZ4_compress_fast_continue(p, ab, 0, 255, oP, boundA, 1)
    @Assert(cA == cP && cA > 0)
    var eqa = cA == cP
    for (i in 0..Int64(cA)) {
        if (oA[i] != oP[i]) { eqa = false; break }
    }
    @Assert(eqa)
    // and decodes standalone (no dictionary involved)
    let dA = Array<UInt8>(255, {_ => 0u8})
    @Assert(LZ4_decompress_safe(oA, cA, dA, 255) == 255)
    var eqd = true
    for (i in 0..255) {
        if (dA[i] != ab[i]) { eqd = false; break }
    }
    @Assert(eqd)
    println("streaming edges: tight-cap 0 + position guards, saveDict 0/0/0/1000, loadDict early-exits, attach-empty fallback pinned")
}

/*-************************************
*  M3b final review fix: two-sentinel same-buffer probe
**************************************/
// Direct pins of the internal lz4SameBuffer: same allocation -> true with
// contents restored by the probe; distinct allocations -> false even with
// EQUAL contents (twins), and specifically in the corner where the old
// single-sentinel probe would have returned true (dict[0]=0x00 so the old
// sentinel save^0xFF = 0xFF equals src[0] -> single read "visible").
@Test
func lz4SameBufferProbeTest(): Unit {
    // 1) same allocation: the array paired with itself
    let a = Array<UInt8>(64, {i => UInt8(i % 251)})
    @Assert(lz4SameBuffer(a, a))
    var restored = true
    for (i in 0..64) {
        if (a[i] != UInt8(i % 251)) { restored = false; break }
    }
    @Assert(restored)
    // 2) distinct Arrays with EQUAL contents -> false (twin buffers)
    let t1 = Array<UInt8>(64, {_ => 0x5Au8})
    let t2 = Array<UInt8>(64, {_ => 0x5Au8})
    @Assert(!lz4SameBuffer(t1, t2))
    // 3) the exact single-sentinel false-positive corner: distinct
    //    buffers, dict all 0x00 (save=0x00 -> old sentinel 0xFF), src
    //    0xFF-led -> old probe read back "visible"; the second sentinel
    //    save^0xAA = 0xAA cannot also match a constant src[0]=0xFF
    let dict = Array<UInt8>(64, {_ => 0x00u8})
    let src = Array<UInt8>(64, {_ => 0xFFu8})
    @Assert(!lz4SameBuffer(dict, src))
    // and symmetrically with the roles swapped (src-led probe)
    @Assert(!lz4SameBuffer(src, dict))
    // guards: size mismatch and empty buffers -> false
    @Assert(!lz4SameBuffer(Array<UInt8>(8, {_ => 1u8}), Array<UInt8>(9, {_ => 1u8})))
    @Assert(!lz4SameBuffer(Array<UInt8>(0, {_ => 0u8}), Array<UInt8>(0, {_ => 0u8})))
    println("same-buffer probe: alias true (contents restored), twins false, complementary single-sentinel corner false")
}

/*-************************************
*  M7 Task 1: overlap-shrink branch pin (stream continue)
**************************************/
// probes/probe_overlap.c pass-2 geometry replayed in-suite (the probe
// was C-differential-only, ledger M7): after the 7 golden rolling
// blocks (same RDG 501/502/503 buffer), block 0 is compressed AGAIN
// with the accumulated dict still spanning [0,262144) - the source
// lies inside the dictionary, so lz4.c L1744-1752 shrinks it to the
// 64KB window [196608,262144) before the extdict run (lz4.cj L1176-
// 1187 branch body, suite-unpinned until now). Pins: pass2 c=20106
// xxh32=55883273 (probe_overlap.c @ 0774d055 / CHANGELOG 0.4.0
// differential provenance), decode closed against a copy of the exact
// 64KB window, and the post-call L1788-89 extdict aftermath state.
@Test
func lz4StreamOverlapShrinkTest(): Unit {
    let buf = contSourceBuffer()
    let cs = LZ4_createStream()
    let bound = LZ4_compressBound(40960)
    let out = Array<UInt8>(Int64(bound), {_ => 0u8})
    // pass 1: the 7 rolling blocks, identical geometry to the golden
    // cont section (probe re-prints the CONT_REF sizes/digests)
    for (k in 0..7) {
        let (off0, n, _, _) = contBlockInfo(k)
        let c1 = LZ4_compress_fast_continue(cs, buf, off0, Int32(n), out, bound, 1)
        @Assert(c1 > 0)
    }
    // pre-shrink state: dict covers the whole buffer
    @Assert(cs.dictStartIdx == 0 && cs.dictSize == 262144)
    // pass 2: block 0 again -> sourceEnd(40960) inside the dict span
    // -> shrink branch body (dictSize 221184 clamped to 65536,
    // dictStartIdx 196608), extdict run against that window
    let c = LZ4_compress_fast_continue(cs, buf, 0, 40960, out, bound, 1)
    if (c != 20106) { println("OVERLAP: got ${c} want 20106") }
    @Assert(c == 20106)
    @Assert(XXH32(out, Int64(c), 0u32) == 0x55883273u32)
    // post-call state: L1788-89 extdict aftermath (dictionary = this
    // source, dictSize = input size; the shrunken window was internal
    // to this call only)
    @Assert(cs.dictStartIdx == 0 && cs.dictSize == 40960)
    // decode closure with the exact 64KB window the encoder kept
    let win = Array<UInt8>(65536, {i => buf[196608 + i]})
    let d = Array<UInt8>(40960, {_ => 0u8})
    @Assert(LZ4_decompress_safe_usingDict(out, c, d, 40960, win, 65536) == 40960)
    var eq = true
    for (i in 0..40960) {
        if (d[i] != buf[i]) { eq = false; break }
    }
    if (!eq) { println("OVERLAP decode: bytes differ") }
    @Assert(eq)
    /* pass 3 (probe pass-3): fresh stream replays pass-1, then a
       4-byte block at 262139 whose end lands 1 byte below dictEnd
       (262144) -> shrink computes dictSize=1 -> <4 discard arm (lz4.c
       L1749-50, lz4.cj L1183-1184); dictSize=0 -> plain literals,
       closes with plain safe decode. Pins: c=5 xxh32=b66095df. */
    let cs2 = LZ4_createStream()
    for (k in 0..7) {
        let (off0, n, _, _) = contBlockInfo(k)
        let c2 = LZ4_compress_fast_continue(cs2, buf, off0, Int32(n), out, bound, 1)
        @Assert(c2 > 0)
    }
    @Assert(cs2.dictStartIdx == 0 && cs2.dictSize == 262144)
    let c3 = LZ4_compress_fast_continue(cs2, buf, 262139, 4, out, bound, 1)
    @Assert(c3 == 5)
    @Assert(XXH32(out, Int64(c3), 0u32) == 0xb66095dfu32)
    @Assert(cs2.dictStartIdx == 262139 && cs2.dictSize == 4)   // L1788-89 aftermath
    let d3 = Array<UInt8>(4, {_ => 0u8})
    @Assert(LZ4_decompress_safe(out, c3, d3, 4) == 4)
    @Assert(d3[0] == buf[262139] && d3[1] == buf[262140] && d3[2] == buf[262141] && d3[3] == buf[262142])
    println("overlap-shrink: pass2 c=20106 xxh32=55883273 pinned, 64KB-window decode exact; pass3 discard arm c=5 pinned")
}
