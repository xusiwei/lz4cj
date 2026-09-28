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

/*-************************************
*  Constants
**************************************/
public const LZ4_MAX_INPUT_SIZE: Int32 = 0x7E000000
public const LZ4_STREAMSIZE: Int32 = 16416

/*-************************************
*  Compression bound
**************************************/
public func LZ4_compressBound(inputSize: Int32): Int32 {
    if (inputSize < 0 || inputSize > LZ4_MAX_INPUT_SIZE) {
        return 0
    }
    return inputSize + inputSize / 255 + 16
}

/*-************************************
*  Streaming state
**************************************/
/* 上游为裸缓冲 + memset 的流状态;仓颉侧改为类承载(设计 §4.4),
   LZ4_STREAMSIZE/LZ4_sizeofState 保留为信息性常量。
   字典字段(dictCtx/dictionary/dictSize)留待 M5 补齐。 */
public class LZ4_stream_t {
    internal var hashTable: Array<UInt32> = Array<UInt32>(16384, {_ => 0u32})
    internal var currentOffset: UInt32 = 0u32
    internal var tableType: Int32 = 0
}

public func LZ4_sizeofState(): Int32 {
    return LZ4_STREAMSIZE
}

public func LZ4_initStream(state: LZ4_stream_t): Int32 {
    var i: Int64 = 0
    while (i < state.hashTable.size) {
        state.hashTable[i] = 0u32
        i += 1
    }
    state.currentOffset = 0u32
    state.tableType = 0
    return 0
}
