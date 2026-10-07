/* lz4file.cj —— lib/lz4file.c @ 0774d055 文件级便捷 API 移植(M9)。
   全部构筑于既有 LZ4F_* 之上;FILE* → std.fs.File(调用方持有文件生命
   周期,与 C 一致:readClose/writeClose 不关文件)。OUT 句柄参数 →
   (errorCode, Option<句柄>) 元组返回。ferror/短写 → FSException 捕获
   转 -io_read/-io_write;parameter_null/allocation_failed 在非空引用 +
   GC 模型下 N/A(设计 §4.5 lz4file 节偏离登记)。 */

package lz4

import std.fs.*

/*-************************************
*  Read file handle (lz4file.c L51-58)
**************************************/
/* C 堆分配 POD;仓颉类承载(GC 模型,§4.4 同 ruling)。构造仅经
   LZ4F_readOpen(internal init),对调用方不透明 = C 前置声明结构体。 */
public class LZ4_readFile_t {
    internal var dctxPtr: LZ4F_dctx
    internal var fp: File
    internal var srcBuf: Array<UInt8>
    internal var srcBufNext: Int64
    internal var srcBufSize: Int64
    internal var srcBufMaxSize: Int64

    internal init(fp: File) {
        this.fp = fp
        this.dctxPtr = LZ4F_createDecompressionContext(LZ4F_VERSION)
        this.srcBuf = Array<UInt8>(0, {_ => 0u8})
        this.srcBufNext = 0
        this.srcBufSize = 0
        this.srcBufMaxSize = 0
    }
}

/* lz4fReadAndParseHeader(lz4file.c L75-117):fread ≤ HEADER_SIZE_MAX;
   <11B → io_read;getFrameInfo 三元组(错误透传);getBlockSize 定
   srcBufMaxSize(防御:非正 → maxBlockSize_invalid,C L96 的 ==0 检查
   在 getFrameInfo 出口 blockSizeID∈{0,4..7} 下为防御死代码);余量
   (headerBuf 过读部分)拷入 srcBuf 续传。 */
internal func lz4fReadAndParseHeader(readFile: LZ4_readFile_t): Int64 {
    let headerBuf = Array<UInt8>(LZ4F_HEADER_SIZE_MAX, {_ => 0u8})
    let bytesRead: Int64 = try {
        readFile.fp.read(headerBuf)
    } catch (e: Exception) {
        return -LZ4F_ERROR_io_read                       /* ferror 等价物 */
    }
    if (bytesRead < LZ4F_HEADER_SIZE_MIN + LZ4F_ENDMARK_SIZE) {   /* L83 */
        return -LZ4F_ERROR_io_read
    }

    let (result, frameInfo, consumedSize) =
        LZ4F_getFrameInfo(readFile.dctxPtr, headerBuf, 0, bytesRead)
    if (LZ4F_isError(result)) {
        return result                                    /* L90-92 */
    }

    let blockSize = LZ4F_getBlockSize(frameInfo.blockSizeID)       /* L95 */
    if (blockSize <= 0) {
        return -LZ4F_ERROR_maxBlockSize_invalid          /* L96-98(防御) */
    }
    readFile.srcBufMaxSize = blockSize

    readFile.srcBuf = Array<UInt8>(readFile.srcBufMaxSize, {_ => 0u8})
    readFile.srcBufSize = bytesRead - consumedSize       /* L110 */
    if (readFile.srcBufSize > 0) {
        var i: Int64 = 0
        while (i < readFile.srcBufSize) {
            readFile.srcBuf[i] = headerBuf[consumedSize + i]
            i += 1
        }
    }
    readFile.srcBufNext = 0

    return LZ4F_OK_NoError
}

/* LZ4F_readOpen(lz4file.c L119-152):C 出参句柄 + calloc/create/parse
   三段;仓颉 internal init 承载分配与 dctx 创建(GC 无失败路),
   parse 失败 → (err, None)。fp/lz4fRead NULL 检查 N/A(偏离登记)。 */
public func LZ4F_readOpen(fp: File): (Int64, Option<LZ4_readFile_t>) {
    let readFile = LZ4_readFile_t(fp)
    let result = lz4fReadAndParseHeader(readFile)
    if (LZ4F_isError(result)) {
        return (result, Option<LZ4_readFile_t>.None)     /* freeAndNull → GC+None */
    }
    return (LZ4F_OK_NoError, Some(readFile))
}

/* LZ4F_readClose(lz4file.c L198-204):freeReadFileResources 的仓颉等价
   物 = freeDecompressionContext(返回 dStage,C lz4file 弃用)+ OK;
   malloc 段由 GC 承载。lz4fRead NULL 检查 N/A。 */
public func LZ4F_readClose(lz4fRead: LZ4_readFile_t): Int64 {
    let _ = LZ4F_freeDecompressionContext(lz4fRead.dctxPtr)
    return LZ4F_OK_NoError
}
