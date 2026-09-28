// Cangjie port of LZ4 (https://github.com/lz4/lz4), upstream commit 0774d055.
// Upstream: Copyright (c) 2011-2024, Yann Collet, BSD-2-Clause.
// Port: Copyright (c) 2026, lz4cj contributors, BSD-2-Clause.
// See LICENSE for full text.

package lz4

/*-************************************
*  Version
**************************************/
public const LZ4_VERSION_MAJOR: Int32 = 1
public const LZ4_VERSION_MINOR: Int32 = 10
public const LZ4_VERSION_RELEASE: Int32 = 0

public func LZ4_versionNumber(): Int32 {
    return LZ4_VERSION_MAJOR * 100 * 100 + LZ4_VERSION_MINOR * 100 + LZ4_VERSION_RELEASE
}

public func LZ4_versionString(): String {
    return "${LZ4_VERSION_MAJOR}.${LZ4_VERSION_MINOR}.${LZ4_VERSION_RELEASE}"
}
