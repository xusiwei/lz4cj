// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

import std.unittest.*

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
