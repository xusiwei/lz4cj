package lz4

import std.unittest.*

@Test
func lz4VersionTest(): Unit {
    @Assert(LZ4_versionNumber() == 11000)
    @Assert(LZ4_versionString() == "1.10.0")
    @Assert(LZ4_VERSION_MAJOR == 1 && LZ4_VERSION_MINOR == 10 && LZ4_VERSION_RELEASE == 0)
}
