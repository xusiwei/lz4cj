# lz4cj

[![CI](https://github.com/xusiwei/lz4cj/actions/workflows/ci.yml/badge.svg)](https://github.com/xusiwei/lz4cj/actions/workflows/ci.yml)

[LZ4](https://github.com/lz4/lz4) 无损压缩库的 [Cangjie](https://cangjie-lang.org/) 移植版(纯仓颉实现,无 FFI/跨语言绑定)。

本移植将上游 lz4(v1.10.0 发布线之上的官方修复版)的`lz4.c` / `lz4hc.c` / `lz4frame.c` / `lz4file.h` 非弃用 API 以 Cangjie 语言全部重新实现,
对外接口命名与 C 头文件**逐字一致**,确定性条件下压缩输出与 C 版本**逐字节一致**。
项目以 `cjpm` 静态库形式发布,可被任意 Cangjie 工程以本地 path 依赖引入。
设计文档见 [docs/design.md](docs/design.md),逐函数移植进度见 [docs/progress.md](docs/progress.md)。

## 简介

LZ4 是无损压缩算法,单核压缩速度超过 500 MB/s,并可在多核 CPU 上扩展。
它还配备极其快速的解码器,单核速度可达数 GB/s,在多核系统上通常能触及内存带宽上限。

压缩速度可动态调节:通过选择"加速度"(acceleration)因子,以压缩率换取更快的速度;
另一端则提供高压缩率衍生版本 LZ4_HC,以 CPU 时间换取更高的压缩比。
所有版本具有相同的解压速度。

LZ4 同时兼容字典压缩(在 API 与 CLI 两个层面):任何输入文件均可作为字典使用
(仅使用其末尾 64KB);该能力可与 Zstandard 字典构建器结合,大幅提升小文件的压缩性能。

LZ4 库以 BSD 2-Clause 许可证作为开源软件发布。

> 以上译自上游 [README](https://github.com/lz4/lz4/blob/0774d055/README.md)(基线 commit 0774d055)。

本移植的覆盖范围(上游 C 库全部公开层,非弃用 API 全量):

| 上游头文件 | 层 | 内容 |
| --- | --- | --- |
| `lz4.h` | 块压缩/解压 | 一站式压缩(`default`/`fast`/`extState`/`destSize`)、解压全家族(`safe`/`partial`/`usingDict`)、流式压缩(`loadDict`/`attach`/`continue`/`saveDict`)、流式解码(`StreamDecode` 族) |
| `lz4hc.h` | HC 高压缩 | 级别 1-12 三策略(LZ4MID / hashChain / optimal)+ `favorDecompressionSpeed` + HC 流式(`loadDictHC`/`attach`/`continue`/`saveDictHC`) |
| `lz4frame.h` | Frame 格式 | 压缩 + 解压全量:一次性 `compressFrame`、流式 Begin/Update/Flush/End、`CDict` 预消化字典、dctx 分片续传 |
| `lz4file.h` | 文件级便捷 API | `readOpen`/`read`/`readClose` + `writeOpen`/`write`/`writeClose`(`std.fs.File` 映射) |
| `xxhash.h` | 校验和 | XXH32 / XXH64(one-shot + 流式);frame 实际仅用 XXH32,内部实现不对外发布 |

**移植基线**:上游 dev commit `0774d055`(2026-06-01,v1.10.0 发布线之上的官方修复线)。
压缩输出与 v1.10.0 发布版逐字节一致(300 行 golden 双 ref 重验零差异);解压包含其后官方
OOB/边界修复,损坏输入行为更严格;详见 [docs/design.md](docs/design.md)。

**移植状态**:全部里程碑 M0-M9 完成,block / HC / frame(压缩 + 解压)/ lz4file 各层相继闭环,
库源码行覆盖 96%+,共 179 项测试。逐里程碑明细见 [docs/progress.md](docs/progress.md)。

格式规格参考:

- LZ4 Block format:<https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md>
- LZ4 Frame format:<https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md>

## API对照

所有接口位于包 `lz4`(`import lz4.*`),命名与对应 C 头文件完全一致,共 80 个函数 + 常量族。
C 的枚举与错误码在仓颉侧为 **Int32 / Int64 常量族**(仓颉无 C 值枚举),成员名逐字
(如 `LZ4F_max64KB`、`LZ4F_ERROR_dstMaxSize_tooSmall`)。

> **指针语义说明**:C 裸指针参数按 [docs/design.md](docs/design.md) §4.3 规则承载:
> in/out 指针 → **元组返回**(如 `(ret, srcConsumed)`);滚动/流式续用指针 → **位置对** `(buf, idx)`;
> 可空结构体指针 → `Option<T>`(`None` 代入零值语义);`XXH*_update` 偏移 → 具名必传参数 `offset!: Int64`。

### 块压缩/解压 + 流式(`lz4.h`)

```cangjie
// 版本与界限
func LZ4_versionNumber(): Int32
func LZ4_versionString(): String
func LZ4_compressBound(inputSize: Int32): Int32

// 一站式压缩
func LZ4_compress_default(src: Array<UInt8>, srcSize: Int32,
                          dst: Array<UInt8>, dstCapacity: Int32): Int32
func LZ4_compress_fast(src: Array<UInt8>, srcSize: Int32,
                       dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32
func LZ4_compress_fast_extState(state: LZ4_stream_t, ...): Int32        // + _fastReset 变体
func LZ4_compress_destSize(...): (Int32, Int32)   // 元组 (ret, srcConsumed),C 的 srcSizePtr 出参

// 解压(LZ4_decompress_fast 族不提供,见下方差异表)
func LZ4_decompress_safe(src: Array<UInt8>, srcSize: Int32,
                         dst: Array<UInt8>, dstCapacity: Int32): Int32
func LZ4_decompress_safe_partial(...)             // + _usingDict / _partial_usingDict 变体

// 流式压缩
func LZ4_createStream(): LZ4_stream_t
func LZ4_loadDict(dictState: LZ4_stream_t, dictionary: Array<UInt8>, dictSize: Int32): Int32
func LZ4_attach_dictionary(workingStream: LZ4_stream_t, dictionaryStream: LZ4_stream_t): Unit
func LZ4_compress_fast_continue(state: LZ4_stream_t, srcBuf: Array<UInt8>, srcIdx: Int64, ...): Int32
func LZ4_saveDict(state: LZ4_stream_t, safeBuffer: Array<UInt8>, dictSize: Int32): Int32

// 流式解码
func LZ4_createStreamDecode(): LZ4_streamDecode_t
func LZ4_setStreamDecode(s: LZ4_streamDecode_t, dict: Array<UInt8>, dictSize: Int32): Int32
func LZ4_decompress_safe_continue(s: LZ4_streamDecode_t, src: Array<UInt8>, ...): Int32
```

### HC 高压缩(`lz4hc.h`)

```cangjie
// 级别常量:LZ4HC_CLEVEL_MIN / DEFAULT / OPT_MIN / MAX
func LZ4_compress_HC(src: Array<UInt8>, srcSize: Int32,
                     dst: Array<UInt8>, dstCapacity: Int32, compressionLevel: Int32): Int32
func LZ4_compress_HC_extStateHC(stateHC: LZ4_streamHC_t, ...): Int32    // + _fastReset 变体
func LZ4_compress_HC_destSize(...): (Int32, Int32)                      // 元组 (ret, srcConsumed)

// HC 流式状态族
func LZ4_createStreamHC(): LZ4_streamHC_t
func LZ4_resetStreamHC(s: LZ4_streamHC_t, compressionLevel: Int32): Unit   // + _fast 变体
func LZ4_setCompressionLevel(s: LZ4_streamHC_t, compressionLevel: Int32): Unit
func LZ4_favorDecompressionSpeed(s: LZ4_streamHC_t, favor: Int32): Unit
func LZ4_loadDictHC(state: LZ4_streamHC_t, dictionary: Array<UInt8>, dictSize: Int32): Int32
func LZ4_attach_HC_dictionary(workingStream: LZ4_streamHC_t, dictionaryStream: LZ4_streamHC_t): Unit
func LZ4_compress_HC_continue(state: LZ4_streamHC_t, ...): Int32          // + _destSize 元组变体
func LZ4_saveDictHC(state: LZ4_streamHC_t, safeBuffer: Array<UInt8>, dictSize: Int32): Int32
```

### Frame 压缩/解压(`lz4frame.h`)

```cangjie
// 版本/错误/界限族:LZ4F_isError / getErrorName / getErrorCode / getVersion /
//                  compressionLevel_max / getBlockSize / compressFrameBound / compressBound

// 压缩:流式
func LZ4F_createCompressionContext(version: UInt32): LZ4F_cctx   // 出参句柄改为返回值
func LZ4F_compressBegin(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, dstIdx: Int64, ...): Int64
func LZ4F_compressBegin_usingDict(...)                            // + _usingCDict 变体
func LZ4F_compressUpdate(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, ...): Int64
func LZ4F_uncompressedUpdate(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, ...): Int64
func LZ4F_flush(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, ...): Int64
func LZ4F_compressEnd(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, ...): Int64

// 压缩:一次性与 CDict
func LZ4F_compressFrame(dstBuf: Array<UInt8>, dstIdx: Int64, ...): Int64   // + _usingCDict 变体
func LZ4F_createCDict(dictBuffer: Array<UInt8>, dictSize: Int64): LZ4F_CDict

// 解压
func LZ4F_createDecompressionContext(version: UInt32): LZ4F_dctx
func LZ4F_headerSize(srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64): Int64
func LZ4F_getFrameInfo(dctx: LZ4F_dctx, ...): (Int64, LZ4F_frameInfo_t, Int64)   // (code, frameInfo, srcConsumed)
func LZ4F_decompress(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64, ...): (Int64, Int64, Int64)
// 元组 (ret, srcConsumed, dstWritten);ret 为 0 表帧完成,正值表下次调用建议字节数 hint
```

### 文件级便捷 API(`lz4file.h`)

```cangjie
// std.fs.File 为载体,调用方持有文件生命周期(readClose/writeClose 不关文件,与 C 一致)
func LZ4F_readOpen(fp: File): (Int64, Option<LZ4_readFile_t>)     // 失败返回 None 句柄
func LZ4F_read(lz4fRead: LZ4_readFile_t, buf: Array<UInt8>, size!: Int64): Int64
func LZ4F_readClose(lz4fRead: LZ4_readFile_t): Int64

func LZ4F_writeOpen(fp: File, preferencesPtr: Option<LZ4F_preferences_t>): (Int64, Option<LZ4_writeFile_t>)
func LZ4F_write(lz4fWrite: LZ4_writeFile_t, buf: Array<UInt8>, size!: Int64): Int64
func LZ4F_writeClose(lz4fWrite: LZ4_writeFile_t): Int64   // 成功返回 compressEnd 尾块字节数(≥4,与 C 一致)
```

### xxhash(`xxhash.h`)

XXH32 / XXH64(one-shot + 流式)按上游结构实现,官方向量验证;可见性为 `internal`
(frame 仅用 XXH32;XXH64 备用不发布,`freeState` 归零语义偏离登记)。

### 与上游 C 的承载差异

block 压缩/解压/流式 + xxhash(上游 `lz4.h` / `xxhash.h`,0774d055)承载差异如下:

| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| in/out 指针参数 | `LZ4_compress_destSize` 的 `srcSizePtr` | 元组返回 `(ret, srcConsumed)`(design §4.3 规则 1) |
| 滚动/流式续用指针 | 裸指针前移 | 位置对 `(buf, idx)`:`LZ4_decompress_safe_continue(dstBuf, dstIdx)`、`LZ4_compress_fast_continue(srcBuf, srcIdx)`(§4.3 规则 4) |
| 可空结构体指针 | `preferencesPtr` 等 NULL | `Option<T>`(None 代入零值语义,§4.3 规则 2) |
| `XXH*_update` 偏移 | 指针前移 | 具名必传参数 `offset!: Int64`(§4.3 规则 3) |
| `LZ4_decompress_fast` 族 | 不校验输入边界的快路径 | **不提供**(仓颉安全模型无忠实等价物;用 `LZ4_decompress_safe`,ASAN 实证 fast 路径合法输入 OOB) |
| 指针相等分派 | `prefixEnd == dest` 等 | 解压侧内容窗口谓词(限定等价性,窄分歧角登记 §4.3)/ 压缩侧 `lz4SameBuffer` 分配同一性判定(严格一致) |
| 错误码 | 负位置编码 | 同 C 语义:解析失败 `-(ip)-1`,尺寸校验 -1(§4.7) |
| xxhash 可见性 | 公开头文件 | `internal`(frame 仅用 XXH32;XXH64 备用不发布,`freeState` 归零语义偏离登记) |
| 状态原语 | `void* state` 裸缓冲 | 状态类实例;`LZ4_sizeofState`/`STREAMSIZE` 保留信息性常量(§4.4) |

HC(上游 `lz4hc.h`)承载差异如下:

| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| `LZ4_compress_HC_extStateHC(void* stateHC, ...)` | 用户提供裸缓冲当状态 | 参数类型为 `LZ4_streamHC_t` 状态类(§4.4) |
| `LZ4_compress_HC_destSize` 的 `srcSizePtr` | in/out 指针 | 元组返回 `(ret, srcConsumed)`;`LZ4_compress_HC_continue_destSize` 同式 |
| 级别常量 | 宏 `LZ4HC_CLEVEL_*` | Int32 常量族(成员名逐字) |
| 弃用块(lz4hc.c L2196-2255) | `LZ4_DEPRECATED` | 不移植(§4.6) |

frame(上游 `lz4frame.h`,0774d055)逐函数对应,承载差异如下:

| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| 五枚举(blockSizeID/blockMode/contentChecksum/blockChecksum/frameType)与错误码 | C enum | **Int32 / Int64 常量族**(仓颉无 C 值枚举;成员名逐字,如 `LZ4F_max64KB`、`LZ4F_ERROR_dstMaxSize_tooSmall`) |
| 缓冲 + 指针入参 | `dstBuffer` / `srcBuffer` 裸指针 | **位置对** `(dstBuf, dstIdx)` / `(srcBuf, srcIdx)`;一次性族 `compressFrame` 源取整缓冲(无位置对,对齐上游单指针形态) |
| `LZ4F_createCompressionContext(&cctx, version)` / `LZ4F_createDecompressionContext(&dctx, version)` 出参 | 双参 + 错误码 | **返回 `LZ4F_cctx` / `LZ4F_dctx`**(`version` 入参保留,仅存不校验,同上游 advanced 语义) |
| `LZ4F_freeDecompressionContext(dctxPtr)` | 释放并返回错误码 | **返回释放时 `dStage`**(C 语义;堆释放由 GC 承载) |
| 可空指针(`preferencesPtr` / `dOptPtr` 等) | `NULL` | `Option<T>`(`None` 代入 MEM_INIT 零值语义,非 INIT 默认) |
| `reserved[3]` 保留字段(compressOptions / decompressOptions) | 结构体内存占位 | **省略**(默认值结构体 + 显式 init 等价覆盖 INIT 宏) |
| `LZ4F_decompress(dctx, dstBuffer, dstSizePtr, srcBuffer, srcSizePtr, dOptPtr)` 返回码 + 双出参 | 单返回值 + 出参 | **元组 `(ret, srcConsumed, dstWritten)`**(design §4.3 规则 1;错误契约恒 `(code, 0, 0)`,`ret` 为 0 表帧完成、正值表下次调用建议字节数 hint);`LZ4F_getFrameInfo` 同式元组 `(code, frameInfo, srcConsumed)` |
| dst NULL(C `dstBuffer==NULL, *dstSizePtr==0`) | NULL 守卫 | **空数组 + `dstCapacity=0`**(全部 NULL 守卫在容量 0 算术下自然归零,无特判分支) |
| `LZ4F_compressBegin_usingDict` 字典语义 | 头文件注记"仅首块使用字典" | **实测怪癖如实钉住**:blockIndependent 帧字典被逐块 reset 整体丢弃(帧 == 无字典帧,C 探针验证);linked 帧字典全帧有效;需逐块字典请用 `compressFrame_usingCDict`/`Begin_usingCDict` |
| `LZ4F_createCDict` NULL/分配失败路径 | 返回 NULL | GC 下不可达,注释登记 |
| `LZ4F_isSkippedFrame` / `LZ4F_decompress_usingCDict`(解压侧) | **上游 0774d055 不存在**(设计 §4.5 原清单误记,已订正) | 不移植;skippable 判定经 `getFrameInfo` 返回的 `frameInfo.frameType == LZ4F_skippableFrame` 表达 |
| mid-src 压缩块解码 | `LZ4_decompress_safe_usingDict(selectedIn, ...)` 原位解码 | `LZ4_decompress_generic` 无 src 位置参数 → **经 tmpIn 暂存一次再从索引 0 解码**(字节相同 ⇒ 输出等价,仅性能差异;偏差登记) |
| `LZ4F_getFrameInfo` 错误路径的 `*frameInfoPtr` | C 错误时不写 out 参(保持调用方原值) | **错误时也返回 dctx.frameInfo 拷贝**(仓颉无 out 参,元组第二元恒有值;Cangjie 侧不可观测差异 —— 调用方无从区分"未写"与"写了同值",登记) |
| updateDict 调用条件 | C 在 `dstPtr==NULL` 时整段跳过 flushOut/copyDirect(含 `LZ4F_updateDict` 调用;`dstPtr!=NULL` 而 sizeToCopy==0 时仍调用) | **空数组 + 容量 0 映射下 flushOut/copyDirect 仍以 dstSize=0 调用 updateDict**(NULL 守卫算术归零路径直落;dstSize=0 下各分支为不动式,状态等价,登记) |

lz4file(上游 `lz4file.h`,0774d055)承载差异如下:

| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| `FILE*` 文件入参 | C stdio `FILE*` | **`std.fs.File`**(调用方持有文件生命周期;`LZ4F_readClose`/`writeClose` 不关文件,与 C 一致) |
| `LZ4F_readOpen`/`LZ4F_writeOpen` 的 OUT 句柄出参 | 双参 + 错误码 | **元组 `(code, Option<句柄>)`**(design §4.3 规则 1;失败返 `None` 句柄,freeAndNull → GC) |
| `LZ4F_read`/`LZ4F_write` 的 `size` | 位置参数 | **具名必传参数 `size!: Int64`** |
| `ferror`/`fwrite` 计数检测 | 返回计数比对 + ferror | **`FSException` 捕获转 `-io_read`/`-io_write`**(`File.write` 返 Unit,短写-成功情形无表示,登记) |
| `parameter_null`/`allocation_failed` 路径 | NULL/分配失败早退 | 非空引用 + GC 模型下 **N/A**(登记) |
| 无效 blockSizeID 的 `LZ4F_writeOpen` | **实测意外成功**:`getBlockSize(2)=(size_t)-2` 回绕绕过 `==0` 守卫,compressBound 回绕得小容量,写出 BD=0x20 无效帧头(探针 `e badbs: 0`) | **`blockSize <= 0` 早退 `-LZ4F_ERROR_maxBlockSize_invalid`**,拒绝依赖 size_t 回绕的非法配置,严于上游(偏离登记) |
| `LZ4F_writeClose` 返回值 | compressEnd 尾块字节数(≥4,头文件未文档化,以代码为准) | 同 C(成功 ≥4;粘滞错误路径跳过 End 返回 OK) |

### 函数清单概览

按层分组计数,总计 **80 函数 + 常量族**;各组计数与总数均只计函数,常量族不计入;
逐函数清单见 [docs/progress.md](docs/progress.md):

| 分组 | 内容 |
|---|---|
| 版本族 2 | `LZ4_versionNumber` / `LZ4_versionString` |
| compressBound 族 | `LZ4_compressBound` |
| 压缩 6 | `LZ4_compress_default` / `compress_fast` / `fast_extState`(+`fastReset`)/ `destSize` / `destSize_extState` |
| 解压 4 | `LZ4_decompress_safe` / `safe_partial` / `safe_usingDict` / `safe_partial_usingDict` |
| 流式解码 5 | `LZ4_createStreamDecode` / `freeStreamDecode` / `setStreamDecode` / `decoderRingBufferSize` / `decompress_safe_continue` |
| 流式压缩 10 | `LZ4_createStream` / `freeStream` / `resetStream`(+`fast`)/ `loadDict`(+`Slow`)/ `attach_dictionary` / `compress_fast_continue` / `saveDict` + `initStream`(归状态原语) |
| stream 状态原语 1(函数) + 1(常量) | `LZ4_sizeofState`(函数) / `LZ4_STREAMSIZE`(信息性常量,不计入函数计数,§4.4) |
| HC 17 + 常量族 | one-shot `compress_HC` / `extStateHC`(+`fastReset`)/ `destSize`、`sizeofStateHC`;状态族 `createStreamHC` / `freeStreamHC` / `initStreamHC` / `resetStreamHC`(+`fast`)/ `setCompressionLevel` / `favorDecompressionSpeed`;流式 `loadDictHC` / `attach_HC_dictionary` / `compress_HC_continue`(+`destSize`)/ `saveDictHC`;+ `LZ4HC_CLEVEL_{MIN,DEFAULT,OPT_MIN,MAX}` |
| frame 压缩 21 | 版本/错误 5、界限 3、cctx 生命周期 2、`compressBegin` 族 3、Update 族 4(`compressUpdate` / `uncompressedUpdate` / `flush` / `compressEnd`)、一次性 2、`LZ4F_CDict` 2 |
| frame 解压 7 | dctx 生命周期 3(`create` / `free` / `resetDecompressionContext`)、查询 2(`headerSize` / `getFrameInfo`)、解压 2(`decompress` / `decompress_usingDict`) |
| lz4file 6 + 2 句柄类 | 读 3(`LZ4F_readOpen` / `read` / `readClose`)+ 写 3(`LZ4F_writeOpen` / `write` / `writeClose`);句柄类 `LZ4_readFile_t` / `LZ4_writeFile_t` 不计入函数计数(M9 增补) |
| 常量族 | frame 错误码 24(Int64)、五枚举 Int32 常量族(blockSizeID/blockMode/contentChecksum/blockChecksum/frameType)、`dstage_*` 内部常量族等 |

## 用法示例

下游工程以本地 path 依赖引入,`cjpm.toml`:

```toml
[dependencies]
  lz4 = { path = "<lz4cj 路径>" }
```

库为单包 `lz4`(模块 `lz4cj` 下唯一包),下游源文件 `import lz4.*`,且下游自身需有
`package <下游包名>` 声明。最小往返示例(block 段,同 [examples/downstream_smoke](examples/downstream_smoke/)):

```cangjie
package lz4_ds_smoke

import lz4.*

main() {
    let n: Int32 = 65536
    let src = Array<UInt8>(Int64(n), { i => UInt8((i * 31 + 7) % 251) })
    let bound = LZ4_compressBound(n)
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
    let c = LZ4_compress_default(src, n, dst, bound)
    if (c <= 0) { println("block compress FAILED"); return 1 }
    let back = Array<UInt8>(Int64(n), { _ => 0u8 })
    let d = LZ4_decompress_safe(dst, c, back, n)
    if (d != n) { println("block decompress FAILED"); return 1 }
    for (i in 0..Int64(n)) { if (src[i] != back[i]) { println("block roundtrip MISMATCH"); return 1 } }
    return 0
}
```

lz4file 文件级便捷 API 以 `std.fs.File` 为载体,**调用方持有文件生命周期**
(`readClose`/`writeClose` 不关文件,与 C 一致),`size` 为具名参数,open 族返回
`(errorCode, Option<句柄>)` 元组:

```cangjie
import std.fs.*
import lz4.*

// compress a file
let wf = File("data.lz4", OpenMode.Write)
let (wcode, wh) = LZ4F_writeOpen(wf, None<LZ4F_preferences_t>)
if (!LZ4F_isError(wcode)) {
    let w = wh.getOrThrow()
    LZ4F_write(w, rawData, size: rawData.size)
    LZ4F_writeClose(w)   // 成功返回 compressEnd 尾块字节数(≥4,与 C 一致)
}
wf.close()               // 文件由调用方关闭

// decompress a file
let rf = File("data.lz4", OpenMode.Read)
let (rcode, rh) = LZ4F_readOpen(rf)
if (!LZ4F_isError(rcode)) {
    let r = rh.getOrThrow()
    let out = Array<UInt8>(rawData.size, { _ => 0u8 })
    LZ4F_read(r, out, size: rawData.size)
    LZ4F_readClose(r)
}
rf.close()
```

验收脚本 `scripts/verify_downstream.sh [lt|st|both]`(缺省 `both`):临时下游 executable
经本地 path 依赖构建运行,做块 / HC / frame / lz4file 四路压缩-解压逐字节往返 + 钉值断言
(M8 验收 + M9 扩容 lz4file 路径,双工具链 PASS)。注:中心仓发布暂未接入,后续可经
`cangjie-repo.toml` 补充(设计 §9 非 MVP)。

## 构建与测试

### 环境说明

- Cangjie 工具链(cjnative)与构建工具 `cjpm`

本项目已通过以下两个版本工具链的构建与全部测试验证:

| 版本 | 渠道 |
| ---- | ---- |
| LTS-1.0.5 | LTS(长期支持版) |
| STS-1.2.0 | STS(短期支持版) |

构建脚本按 `scripts/cjenv.sh` 的规则定位 SDK(与平台无关):优先环境变量
`LZ4CJ_SDK_105` / `LZ4CJ_SDK_120`(指向含 `envsetup.sh` 或 `cangjie/envsetup.sh` 的
SDK 根目录,Windows 反斜杠路径亦可),回退 `~/.local/cangjie-<lts|sts>-<ver>`
(`scripts/download_sdk.sh` 安装的布局,链接切换由 `scripts/setup_env.sh` 负责),
最后回退旧布局 `~/sdk/cangjie-<ver>`。

> **注意**:不同版本工具链生成的编译中间文件二进制不兼容。切换工具链版本后,
> 请先 `cjpm clean` 清理之前工具链的中间产物再重新构建。

### 构建命令

```bash
scripts/download_sdk.sh          # 一次性:下载两套 SDK 到 ~/.local(Linux/macOS/Windows Git Bash)
source scripts/setup_env.sh lts  # 切换 ~/.local/cangjie-sdk 链接到 LTS 并导出环境(或 sts)
scripts/build_and_test.sh both   # 双工具链构建 + 全量测试 + fuzz 基准
```

`download_sdk.sh` 内嵌 cangjie-lang.cn 官方直链与 sha256 校验,支持
`lts` / `sts` / `both` 参数,已安装的渠道自动跳过(幂等)。
`setup_env.sh` 通过 `~/.local/cangjie-sdk -> cangjie-<lts|sts>-<ver>` 链接实现版本切换
(Windows 上为 junction),PATH 导入目录跨版本稳定;重复 source 自动清理旧工具链路径。
`build_and_test.sh` 也接受 `lt`(LTS-1.0.5)/ `st`(STS-1.2.0)单工具链参数,缺省 `both`;
第二参数 `test-only` 可跳过 `cjpm bench`(CI PR 门禁用,基准留给 nightly)。
若已在环境中 source 过 SDK 的 `envsetup.sh`,也可直接 `cjpm build` / `cjpm test` / `cjpm bench`。

`cjpm.toml` 中 `compile-option = "--int-overflow=wrapping ..."` 是正确性的硬性要求:
LZ4 哈希函数依赖 32 位乘法回绕语义(如 `(seq * 2654435761) >> shift`),
Cangjie 默认的溢出检查会在热点路径触发运行时异常,必须关闭。

### CI(GitHub Actions)

[.github/workflows/](.github/workflows/) 下两个流水线(仓库 push 到 GitHub 后生效):

| 流水线 | 触发 | 内容 |
| --- | --- | --- |
| `ci.yml` | 每个 PR / push main | Linux 双变体矩阵 {lt, st}:SDK 安装(actions/cache 缓存 `~/.local`)→ golden 语料再生 → `cjpm build/test`(test-only)→ 下游依赖冒烟 → e2e 双工具交叉验证 |
| `bench.yml` | 每晚 02:00(北京时间)/ 手动 | 双工具链 `cjpm bench` fuzz 种子扫描 + 吞吐冒烟,结果写入 run summary 与 artifacts(按设计定位为数量级监视,非回归门禁) |

SDK 由 `scripts/download_sdk.sh` 从官网直链下载并校验 sha256 后经缓存复用。
**Windows 变体暂缓**(2026-10-28):cjc `-O2` windows-x64 误编译与运行时非确定性活锁
两项工具链缺陷使格子结构性红灯(详见 [report/windows_test_findings.md](report/),重跑即过/`-O0` 可绕),
待上游修复后加回 `windows-latest` 矩阵行。macOS(macos-15/arm64)为后续扩展项,
`download_sdk.sh` 的 mac-aarch64 包条目与 `run_e2e.sh` 的 `gtimeout` 回退已预置。

### golden 语料再生

golden 语料(`corpus/`,清单 + artifacts,~5.4MB)**不入 git**(仓库策略,
`git check-ignore corpus` 可证);克隆后本地再生:

```bash
scripts/gen_golden.sh   # 编译上游 C 源生成;Linux/macOS 与 Windows(Git Bash + MinGW gcc)均可
```

脚本路径无关:上游 lz4 源码位置取 `LZ4CJ_UPSTREAM`(缺省 `~/lz4`),C 编译器取 `CC`
(缺省 cc→gcc→clang 自动回退);Windows/MinGW 下自动加 `-D__USE_MINGW_ANSI_STDIO=1`
(msvcrt printf 不支持 `%zu`)并在生成后清理 stdout 文本模式引入的 CR。
上游源码获取与检出基线 commit(golden 与上游逐字节一致性的锚点,不可换用其他版本):

```bash
git clone https://github.com/lz4/lz4 ~/lz4   # 网络受限时可用 GitHub 代理前缀
git -C ~/lz4 checkout 0774d055
```

脚本自带门检(总行 512 / 注释 23 / 各 mode 行数 / corpus 体积)。测试套件内嵌常量摘要
断言(尺寸 + XXH32/64)**自足**——语料缺失时仍完整验证;artifact 存在时才做逐字节比对
(全有或全无)。

### 单元测试

```bash
cjpm test           # 运行 174 个单元/钉值/golden 用例
cjpm bench          # fuzz 种子扫描基准(5 个,@Test @Bench 顶层组合标注)
```

测试分两段执行:`cjpm test`(单元/钉值/golden)与 `cjpm bench`(长跑型种子扫描不占
测试门槛,由 bench 框架多次执行并产出计时表;可加 `--filter fuzzDecompressBench` 过滤)。
共 179 项测试,覆盖:

- 版本与 compressBound、流状态、XXH32/XXH64(官方向量 + 流式)、datagen(C 交叉验证)
- golden 字节级钉值:一站式块压缩(256 行 + 125 行对抗性 destSize)、块解压(清单 v2 共 300 行)、
  流式压缩(46 行,cont/savedict/dictfast/dictslow/attach/extdict/destext)、
  HC(70 行,levels 1-12 全采样三策略)、frame 压缩(49 行,10 头编码 + 27 流式全参数交叉 +
  CDict + usingDict 帧)、frame 解压 fdmp C 探针(14 行;清单共 489 数据行)、lz4file(23 项)
- 语义与对抗:safe/fast 差分(随机 + 合成流 + 损坏输入)、extDict 跨界拷贝、
  分片续传矩阵(27 行 × 7 变体)、stableDst/skipChecksums/skippable/拼接语义、
  覆盖率门禁定向用例、闭环滚动往返 + 边界契约
- 模糊测试:3000 解压 + 320 流式 + 420 HC + 240 frame 压缩 + 300 frame 解压种子
  (确定性重放 + 逐块解码闭环;`LZ4_SKIP_PERF=1` 可跳过性能冒烟)

### 基准测试

性能基线(`scripts/bench_probe.c` C 侧,上游 0774d055;`src/bench_test.cj` 仓颉侧,
`LZ4_SKIP_BENCH=1` 可跳过)同输入同口径 best-of-3 对照:仓颉/C 比值 0.02-0.6x
(差距结构性:数组安全层/GC/调用开销 vs C 裸内存 + SIMD;详见 CHANGELOG 0.8.0 基线表)。

**M8 §2.2 裁定(2026-10-03)**:差距结构性,单点微调预期收益远小于差距且危及
"压缩输出与 C 逐字节一致"保真资产,裁定不做性能优化,库源码冻结;
非回归监控沿用 `benchAllTest`。

### 端到端交叉验证(e2e)

[e2e/](e2e/README.md) 内含两个契约一致的命令行文件压缩/解压工具(`-c/-d -i/-o`):
`cli-c`(上游 lz4 C 库,CMake 跨平台)与 `cli-cj`(本仓颉实现,独立 cjpm executable 模块
path 依赖仓库根)。`e2e/run_e2e.sh` 生成用例并跑全矩阵:C/仓颉压缩输出**逐字节一致**、
四方向压缩-解压往返、损坏/截断/尾随字节错误注入双工具拒绝,双工具链各跑一遍。

## 项目结构

```
lz4cj/
├── cjpm.toml                  # 包定义(name=lz4, static, --int-overflow=wrapping)
├── CHANGELOG.md               # 变更记录
├── LICENSE                    # BSD 2-Clause(含上游版权声明)
├── README.md                  # 本文件
├── docs/
│   ├── design.md              # 设计文档(移植规则、API 对照、偏离登记)
│   └── progress.md            # 逐函数移植进度与里程碑明细
├── src/
│   ├── lz4.cj                 # 块压缩/解压 + 流式(lz4.c)
│   ├── lz4hc.cj               # HC 高压缩(lz4hc.c)
│   ├── lz4frame.cj            # Frame 压缩侧(lz4frame.c)
│   ├── lz4frame_decode.cj     # Frame 解压侧(lz4frame.c)
│   ├── lz4file.cj             # 文件级便捷 API(lz4file.h)
│   ├── xxhash.cj              # XXH32/XXH64(internal)
│   ├── common.cj              # 共享辅助
│   ├── datagen.cj             # 测试数据生成(datagen.c,与 C 交叉验证)
│   ├── *_test.cj              # 单元/钉值/golden 测试(8 个)
│   ├── large_test.cj          # >256KB 运行时矩阵(large_probe 钉值)
│   ├── fuzz_test.cj           # fuzz 种子扫描(@Test @Bench)
│   └── bench_test.cj          # 性能冒烟(@Bench)
├── scripts/                   # 仅 .sh 工作流脚本(编排层)
│   ├── download_sdk.sh        # SDK 下载安装(官网直链 + sha256,~/.local 布局)
│   ├── setup_env.sh           # SDK 链接切换器(~/.local/cangjie-sdk,lts/sts)
│   ├── build_and_test.sh      # 双工具链构建 + 测试总控
│   ├── cjenv.sh               # SDK 定位规则
│   ├── verify_downstream.sh   # 下游 path 依赖验收(跑 examples/downstream_smoke)
│   └── gen_golden.sh          # golden 语料再生总控(编排 probes/gen_golden.c)
├── probes/                    # C 侧钉值工具(链接上游 0774d055 编译,见 probes/README.md)
│   ├── gen_golden.c           # golden 生成器(CI 每次运行)
│   └── *_probe.c / *_ref.c    # 行为探针 14 个(钉值事实来源 → 仓颉测试常量)
├── examples/                  # 独立 cjpm 可执行工程(每个自带 cjpm.toml,见 examples/README.md)
│   ├── downstream_smoke/      # 库消费示例:四路往返 + 钉值(verify_downstream 引用)
│   ├── arr_probe/             # cjc windows 数组越界检查异常探针
│   ├── oob_repro/             # cjc windows 伪越界误编译复现尝试(形状文档)
│   └── gc_stale_repro/        # GC 陈旧读复现程序(M7-T6,零观测关闭)
├── e2e/                       # 端到端交叉验证(cli-c + cli-cj + run_e2e.sh)
├── corpus/                    # golden 语料(不入 git,scripts/gen_golden.sh 再生)
└── report/                    # 构建/测试日志(生成产物)
```

## 许可证

本移植遵循上游 LZ4 的 BSD 2-Clause 许可证(单许可证,与上游一致):

- **BSD 2-Clause License**

LICENSE 文件含双重版权声明:本移植(lz4cj contributors, 2026)与上游
(Yann Collet, 2011-2024, <https://github.com/lz4/lz4>)。许可证全文见 [LICENSE](LICENSE)。

## 链接

- 上游 C 实现(Yann Collet / lz4 组织):<https://github.com/lz4/lz4>
- 本移植仓库:<https://github.com/xusiwei/lz4cj>
- 格式规范(上游基线 0774d055 原文 + 中文译本):
  [块格式](docs/lz4_Block_format.md) · [块格式(中文)](docs/lz4_Block_format_zh.md) ·
  [帧格式](docs/lz4_Frame_format.md) · [帧格式(中文)](docs/lz4_Frame_format_zh.md)
- 设计文档:[docs/design.md](docs/design.md) · 移植进度:[docs/progress.md](docs/progress.md)
- 端到端交叉验证:[e2e/README.md](e2e/README.md)
- 示例工程:[examples/README.md](examples/README.md)
- 变更记录:[CHANGELOG.md](CHANGELOG.md)
- 演示视频:[Bilibili 视频合集](https://space.bilibili.com/121420235/lists/9271654)
- LZ4 其他语言移植列表见 [LZ4 Homepage](http://www.lz4.org)
