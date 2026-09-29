# LZ4 仓颉移植设计文档

## 1. 背景与目标

[LZ4](https://github.com/lz4/lz4) 是广泛使用的高性能无损压缩库,以极快的压缩/解压速度著称。上游以 C 语言实现(本移植基于上游 dev 分支 commit `0774d055`,版本 1.10.0)。

本项目将 LZ4 核心库以**仓颉语言完整重写**(非 FFI/跨语言绑定),目标:

1. **格式与语义等价**:压缩输出、解压行为、帧格式与 C 实现一致;在确定性条件下,压缩输出与 C 版**逐字节一致**(作为移植保真度的强校验)。
2. **双版本通过**:同一套源码在仓颉 **LTS-1.0.5** 与 **STS-1.2.0** 两套工具链下均可编译并通过全部测试。
3. **API 命名与 C 头文件逐字一致**:降低对照移植、代码审查与上游升级的成本。
4. **正确性优先,热点优化**:主体代码保证正确性与可读性,热路径(哈希查找、序列复制)允许 `CPointer` 手工优化。

## 2. 范围与非目标

### 2.1 移植范围

| 上游文件 | 行数 | 内容 | 移植决策 |
|---|---|---|---|
| `lib/lz4.c` + `lz4.h` | 2848 | block 级压缩/解压、流式状态、字典 | 移植(非弃用 API 全量) |
| `lib/lz4hc.c` + `lz4hc.h` | 2255 | 高压缩模式(链表/二叉树/最优解析) | 移植(非弃用 API 全量) |
| `lib/lz4frame.c` + `lz4frame.h` | 2167 | LZ4 Frame 格式(v1.0 规格) | 移植(非弃用、非多线程 API 全量) |
| `lib/xxhash.c` + `xxhash.h` | 1030 | 校验和依赖 | **按上游结构实现 XXH32 与 XXH64 两套接口**(frame 实际只使用 XXH32;XXH64 一并实现备用,不采用泛型合并,理由见 5.6) |
| `lib/lz4file.c` + `lz4file.h` | 362 | 文件级便捷 API | 不移植(可后续增补) |
| `programs/`(CLI)、XXH64/XXH3 | — | 命令行工具、其余哈希算法 | 不移植 |

### 2.2 非目标

- 不追求与 C 版 ABI 二进制兼容(仓颉堆对象模型与 C 内存布局不同,无必要)。
- 不支持 frame 多线程压缩(上游此版本头文件未暴露该 API)。
- 不做跨语言互操作封装(明确要求纯仓颉重写)。
- 基准测试与性能调优仅做到"明显劣化时定位并优化热点",不设量化指标。

## 3. 总体结构

### 3.1 包与目录布局

单 `cjpm` 模块、单包 `lz4`,输出静态库。文件与上游 C 源一一对应,便于逐文件对照移植与审查:

```
lz4cj/
├── cjpm.toml
├── LICENSE                  # BSD-2-Clause(含上游版权声明)
├── README.md / CHANGELOG.md
├── docs/
│   └── design.md            # 本文档
├── scripts/                 # 构建 / 测试 / golden 生成脚本
│   ├── setup_env.sh         # 解压/安装两套 SDK,放置 envsetup
│   ├── build_and_test.sh    # lt | st | both:source 对应 envsetup 后执行 cjpm build + test
│   ├── gen_golden.c         # C 侧 golden 生成 harness(直连 ~/lz4/lib 源码编译)
│   └── gen_golden.sh        # 编译并运行 harness,产出 golden 语料
├── corpus/                  # golden 数据(入库,二进制,总量控制在 ~8MB 内)
│   └── manifest.toml        # 用例清单:输入指纹 × 参数 × 期望输出文件
└── src/
    ├── common.cj            # MEM_* 等价工具:非对齐读写、wildCopy、批量拷贝
    ├── lz4.cj               # block 压缩/解压(对应 lz4.c)
    ├── lz4_stream.cj        # LZ4_stream_t / LZ4_streamDecode_t 状态与流式 API
    ├── lz4hc.cj             # 高压缩模式(对应 lz4hc.c)
    ├── lz4frame.cj          # frame 压缩(对应 lz4frame.c 压缩侧)
    ├── lz4frame_decode.cj   # frame 解压 + getFrameInfo(对应解压侧)
    ├── xxhash.cj             # XXH32/XXH64 两套实现,结构与上游 xxhash.c 同构(internal)
    ├── datagen.cj            # 上游 datagen 输出兼容的可复现语料生成器(internal,测试支撑;重实现并标注算法来源)
    ├── xxhash_test.cj        # 测试统一置于包根(与库同包,可访问 internal 成员)
    ├── datagen_test.cj
    ├── lz4_test.cj
    ├── lz4hc_test.cj
    ├── lz4frame_test.cj
    ├── golden_test.cj       # golden 交叉验证(解压比对 + 压缩逐字节比对)
    └── fuzz_test.cj         # 随机种子模糊往返测试(运行时生成,不依赖 C)
```

### 3.2 cjpm.toml 要点

```toml
[package]
  cjc-version = "1.0.5"        # 以 LTS 为基线;若 STS 校验策略不同,在发布分支微调
  name = "lz4"
  description = "Cangjie port of the LZ4 lossless compression library"
  version = "1.0.0"
  output-type = "static"
  compile-option = "--int-overflow=wrapping -O2"
  include = ["src/**/*.cj", "docs/design.md", "README.md", "LICENSE"]
  exclude = ["src/**/*_test.cj", "scripts/**", "corpus/**"]
  license = ["BSD-2-Clause"]
```

两个编译选项均为**硬性要求**:

- `--int-overflow=wrapping`:LZ4 哈希函数依赖 32 位乘法回绕(如 `(seq * 2654435761) >> shift`),默认溢出检查语义会使热点路径抛出异常或拖慢性能;
- `-O2`:仓颉编译器默认 `-O0`,实测即使不含任何泛型的手写热循环,-O0→-O2 也有 **7~23 倍**差距(2M 轮哈希微基准 42ms→6ms,4MB digest 508ms→22ms)。压缩库的热路径(哈希查找、序列复制)必须依赖 `-O2`。

## 4. API 设计

### 4.1 命名与映射原则

- 函数名、类型名、常量名、枚举成员名与 C 头文件**逐字一致**(如 `LZ4_compress_default`、`LZ4F_preferences_t`、`LZ4F_max64KB`)。
- 仓颉标识符规则允许此类命名(下划线、大小写字母、数字)。
- 对偏离 C 签名的必要调整(见 4.3),在 README 的 API 对照表中逐条登记。

### 4.2 类型映射表

| C 类型 | 仓颉类型 | 说明 |
|---|---|---|
| `int` | `Int32` | block API 长度、返回值 |
| `unsigned` | `UInt32` | |
| `size_t` | `Int64` | frame API 长度、返回值(约定非负) |
| `LZ4F_errorCode_t` | `Int64` | 即 size_t,负值模式保持 |
| `const char*/BYTE* src` + 长度 | `Array<UInt8>` + 显式 size 参数 | 调用方负责长度;空数组等价 `NULL+0` |
| `char* dst` + 容量 | `Array<UInt8>` + 显式 capacity 参数 | 不以 0 结尾,与 C 一致 |
| `void* state`(opaque 状态) | 对应状态类实例 | 见 4.4 |
| `const LZ4F_preferences_t*`(可 NULL) | `Option<LZ4F_preferences_t>` | None 等价 NULL,取默认值 |
| `int* srcSizePtr`(in/out 参数) | 并入返回值元组 | 见 4.3 |
| `const char*`(版本/错误名) | `String` | |

### 4.3 签名调整规则(共三条,全局统一)

1. **in/out 指针参数 → 返回值元组**。仓颉无引用参数,受影响函数:
   - `LZ4_compress_destSize(src, dst, srcSizePtr, targetDstSize)` → 返回 `(ret: Int32, srcConsumed: Int32)`
   - `LZ4F_getFrameInfo(dctx, src, srcSizePtr)` → 返回 `(code: Int64, frameInfo: LZ4F_frameInfo_t, srcConsumed: Int64)`
   - `LZ4F_decompress(dctx, dst, src, srcSizePtr, dOptPtr)` → 返回 `(ret: Int64, srcConsumed: Int64, dstWritten: Int64)`
2. **可 NULL 的结构体指针 → `Option<T>`**;其余指针一律映射为非空 `Array<UInt8>` 或类实例。
3. **C 指针前移 → 具名可选参数 `offset!: Int64`(默认 0)**:用于 `XXH*_update` 等需要从缓冲中部继续的场景;后续 frame/流式 API 沿用此惯例。

### 4.4 状态对象模型

C 侧 opaque 上下文(堆分配 + 内部字段经由 `void*` 别名访问)统一映射为仓颉 `class`,字段与上游结构体逐字段对应,无需复刻 C 的内存布局与对齐:

| C 类型 | 仓颉类 | 内部对应 |
|---|---|---|
| `LZ4_stream_t`(hashTable[16384] + 字典区 + tableType) | `public class LZ4_stream_t` | `lz4.cj` |
| `LZ4_streamDecode_t`(字典环缓冲) | `public class LZ4_streamDecode_t` | `lz4_stream.cj` |
| `LZ4_streamHC_t`(chainTable + next 优化区) | `public class LZ4_streamHC_t` | `lz4hc.cj` |
| `LZ4F_cctx` / `LZ4F_dctx` | `public class LZ4F_cctx` / `LZ4F_dctx` | `lz4frame*.cj` |
| `LZ4F_CDict` | `public class LZ4F_CDict` | `lz4frame.cj` |

C 中"用户提供裸缓冲当状态"的 API(`LZ4_compress_fast_extState(void* state, ...)`、`LZ4_compress_HC_extStateHC(void* stateHC, ...)`)在仓颉中参数类型改为对应状态类;`LZ4_sizeofState`/`LZ4_sizeofStateHC` 保留,返回信息性常量(与 `LZ4_STREAMSIZE` 等一致),供 API 对照完整性与容量预估。

### 4.5 移植 API 清单

**block 压缩/解压(`lz4.h`,非弃用全量)**:

- 版本:`LZ4_versionNumber`、`LZ4_versionString`
- 简单压缩:`LZ4_compress_default`、`LZ4_compress_fast`、`LZ4_compress_fast_extState`、`LZ4_compress_fast_extState_fastReset`、`LZ4_compress_destSize`、`LZ4_compressBound`
- 解压:`LZ4_decompress_safe`、`LZ4_decompress_safe_partial`、`LZ4_decompress_safe_usingDict`、`LZ4_decompress_safe_partial_usingDict`
- 流式压缩:`LZ4_createStream`、`LZ4_freeStream`、`LZ4_resetStream`、`LZ4_resetStream_fast`、`LZ4_initStream`、`LZ4_loadDict`、`LZ4_loadDictSlow`、`LZ4_attach_dictionary`、`LZ4_compress_fast_continue`、`LZ4_saveDict`
- 流式解压:`LZ4_createStreamDecode`、`LZ4_freeStreamDecode`、`LZ4_setStreamDecode`、`LZ4_decoderRingBufferSize`、`LZ4_decompress_safe_continue`
- 常量:`LZ4_MEMORY_USAGE`、`LZ4_HASHLOG`、`LZ4_STREAMSIZE`、`LZ4_VERSION_MAJOR/MINOR/RELEASE`、`LZ4_DECODER_RING_BUFFER_SIZE`(以函数/常量形式提供)

**HC(`lz4hc.h`,非弃用全量)**:

- `LZ4_compress_HC`、`LZ4_compress_HC_extStateHC`、`LZ4_compress_HC_extStateHC_reset`、`LZ4_sizeofStateHC`
- 流式:`LZ4_createStreamHC`、`LZ4_freeStreamHC`、`LZ4_resetStreamHC`、`LZ4_resetStreamHC_fast`、`LZ4_loadDictHC`、`LZ4_compress_HC_continue`、`LZ4_saveDictHC`、`LZ4_attach_HC_dictionary`、`LZ4_setCompressionLevel`、`LZ4_favorDecompressionSpeed`
- 常量:`LZ4HC_CLEVEL_MAX(12)`、`LZ4HC_CLEVEL_DEFAULT`、`LZ4HC_CLEVEL_OPT_MIN`

**frame(`lz4frame.h`)**:

- 类型:`LZ4F_preferences_t`、`LZ4F_frameInfo_t`、`LZ4F_compressOptions_t`、`LZ4F_decompressOptions_t`、`LZ4F_errorCodes`(枚举 + 数值互转辅助)
- 枚举:`LZ4F_blockSizeID_t`、`LZ4F_blockMode_t`、`LZ4F_contentChecksum_t`、`LZ4F_blockChecksum_t`、`LZ4F_frameType_t`(成员名逐字:`LZ4F_max64KB`…、`LZ4F_blockLinked/blockIndependent`、`LZ4F_noContentChecksum/contentChecksumEnabled`、`LZ4F_noBlockChecksum/blockChecksumEnabled`、`LZ4F_frame/skippableFrame`)
- 版本/错误:`LZ4F_getVersion`、`LZ4F_isError`、`LZ4F_getErrorName`、`LZ4F_getErrorCode`、`LZ4F_compressionLevel_max`
- 一次性:`LZ4F_compressFrame`、`LZ4F_compressFrameBound`、`LZ4F_compressFrame_usingCDict`
- 流式压缩:`LZ4F_createCompressionContext`、`LZ4F_freeCompressionContext`、`LZ4F_compressBegin`、`LZ4F_compressBegin_usingCDict`、`LZ4F_compressUpdate`、`LZ4F_uncompressedUpdate`、`LZ4F_flush`、`LZ4F_compressEnd`、`LZ4F_compressBound`
- 字典:`LZ4F_createCDict`、`LZ4F_freeCDict`
- 解压:`LZ4F_createDecompressionContext`、`LZ4F_freeDecompressionContext`、`LZ4F_resetDecompressionContext`、`LZ4F_headerSize`、`LZ4F_getFrameInfo`、`LZ4F_decompress`、`LZ4F_decompress_usingDict`、`LZ4F_decompress_usingCDict`、`LZ4F_isSkippedFrame`、`LZ4F_getBlockSize`

**xxhash(`xxhash.h` 子集,`internal` 可见性)**:`XXH32`、`XXH32_createState`、`XXH32_freeState`、`XXH32_reset`、`XXH32_update`、`XXH32_digest`(frame 所需);`XXH64` 同族接口一并实现(结构与上游逐函数对应,见 5.6),暂不对外发布,未来如需暴露为独立改动。XXH3/XXH128 不在范围。

**语义偏离登记:`XXH32_freeState` / `XXH64_freeState`**。C 版为 `XXH_free(ptr)` 释放堆内存;仓颉由 GC 管理生命周期,故实现为**归零复原**——所有字段(含 mem 缓冲)置回构造初值,返回 0。与 `reset` 的区别:`reset(state, seed)` 是复用入口(按 seed 初始化 v1-v4,不清 mem);`freeState` 是"释放"语义的仓颉等价物(状态不可再直接使用,须先 reset)。上游 `lz4frame.c` 内嵌 state 按值使用、从不调用 create/freeState,故此偏离无兼容性影响。

### 4.6 显式不移植清单(及理由)

| C API | 理由 |
|---|---|
| `LZ4_compress`、`LZ4_compress_limitedOutput`、`LZ4_compress_withState`、`LZ4_compress_continue`、`LZ4_uncompress`、`LZ4_uncompress_unknownOutputSize`、`LZ4_create`、`LZ4_sizeofStreamState`、`LZ4_resetStreamState`、`LZ4_slideInputBuffer` 等全部 `LZ4_DEPRECATED` 项 | 上游已标记弃用,新库不应暴露 |
| `LZ4_decompress_fast`、`LZ4_decompress_fast_usingDict` | 语义上"不校验输入边界、不要求已知压缩长度",在仓颉安全模型下无忠实等价物;且无法仅凭 `originalSize` 安全别名到 `LZ4_decompress_safe`。不提供,README 注明用 `LZ4_decompress_safe` |
| `lz4file.h` 全部 | 范围裁剪,基于 `LZ4F_*` 可直接实现,后续版本可增补 |
| `XXH64`、`XXH3`、`XXH128` | `lz4frame.c` 未使用 |

### 4.7 错误处理

- **block 侧**:保持 C 语义——压缩返回 0(失败/容量不足);解压错误为负位置编码 `-(ip 偏移)-1`(ip 为解析失败时的输入位置,与上游 lz4.c:2462 的 `_output_error` 出口一致),输入尺寸校验错误返回 -1(lz4.c:2035/2068)。上游 `LZ4_errorCodes` 枚举仅服务于 `LZ4_getErrorString` 等 CLI 辅助函数,并非 `LZ4_decompress_safe` 返回值语义,不移植。
- **frame 侧**:保持 C 的 size_t 数值错误码模式——`LZ4F_errorCode_t = Int64`,错误值为负;`LZ4F_isError(code)`、`LZ4F_getErrorCode`、`LZ4F_getErrorName` 可用性与 C 一致。**不**改用异常/Option,保持逐字 API 契约;调用方按 C 习惯先查 `LZ4F_isError`。
- 仓颉异常仅用于防御性断言内部不变量(理论上不可达路径),文档注明。

## 5. 核心模块设计

### 5.1 common.cj —— 内存访问工具层

对应 C 侧 `MEM_*` 宏族,是保真度与性能的基石:

- **非对齐读写**:`MEM_read16/32/64`、`MEM_write16/32/64` → 经 `acquireArrayRawData` 取得 `CPointer<UInt8>` 后,按偏移构出 `CPointer<UInt32/UInt64>` 再 `read()/write()`,用毕 `releaseArrayRawData` 归还。目标平台(x86_64/aarch64)非对齐访问与 C `memcpy` 语义等价;**回退预案**:若某平台出现对齐故障,切换为按字节组装实现,接口不变。
- **序列复制**:
  - `LZ4_wildCopy8`:8 字节步进的"野复制"(允许写越界到 `dst+8` 内的安全余量),照搬 C 的循环结构与步长;
  - `LZ4_memcpy_using_offset`:解压热路径的交叠复制(`src` 与 `dst` 固定偏移),照搬 C 的分支逻辑(offset<8 的特殊表、>=8 的 8 字节步进);
  - `LZ4_safeCopy`:按 `copySize` 精确复制,用于块尾。
- 所有工具函数**不进行**数组下标越界检查;调用处承担边界责任(与 C 一致,见第 6 节)。

### 5.2 lz4.cj —— block 压缩

C 侧 `LZ4_compress_generic` 是一个多态宏展开的状态机(字典模式 × acceleration × tableType 组合)。移植策略:

- 按字典模式拆分为显式函数:`withPrefix64k`、`usingExtDict`、`noDict` 三条主路径(与上游宏参数一一对应),共享 token 编码与哈希工具。
- **保真度关键点**(压缩输出逐字节一致的充要条件,评审与测试对照清单):
  1. 位置哈希:`((sequence * 2654435761) >> (MINMATCH*8 - LTS))`,UInt32 回绕;
  2. 候选查找顺序:仅探测哈希表单一槽位,`searchMatchNb` 步进 `(searchMatchNb >> LZ4_skipTrigger32)`、步长 `step = (searchMatchNb++ >> acceleration)`;
  3. 匹配确认:`LZ4_count` 先向后扩展(每次 8 字节粗对齐再精比)再向前扩展,方向与粗化粒度不可变;
  4. token 编码:literal 长度 0–255、扩展字节、`MFLIMIT/oend` 停止条件、最后 5 字节 literal 规则;
  5. 表项更新时机与内容(`current`、`base`、`dictBase`、`tableType` 16/32 位区分)。
- 流式与字典:`LZ4_compress_fast_continue` 的前缀延续/外部字典切换逻辑(`dictSmall`、`lowLimit/dictLimit` 区间判断)逐分支移植。
- HC 之外的 `acceleration` 参数语义(默认 1,越大越快越弱)照搬。

### 5.3 block 解压(lz4.cj + lz4_stream.cj)

- `LZ4_decompress_safe` 系列:先移植**safe 完整版**(逐 token 显式边界检查,错误语义逐字对齐上游:负位置编码 `-(ip)-1`,尺寸校验错误 -1),作为正确性基准;
- 再移植 fast 路径(以 `LZ4_wildCopy8` 为主体的快循环 + 尾部 `LZ4_safeCopy` 精确收尾),通过"fast 与 safe 输出必须一致"的差分测试保障;
- `LZ4_decompress_safe_partial`:按 targetOutputSize 提前终止的分支逻辑照搬;
- 流式解码:`LZ4_streamDecode_t` 维护 64KB+ 环缓冲字典,`LZ4_decompress_safe_continue` 的字典内容判定(前缀在外部字典/环缓冲内/混合)逐分支移植;
- `LZ4_setStreamDecode` 支持外部字典注入。

### 5.4 lz4hc.cj —— 高压缩模式

- 移植完整级别区间 `1..12`:
  - `clevel < LZ4HC_CLEVEL_OPT_MIN(10)`:贪心 + 可选 lazy 匹配(`nbAttempts` 随级别变化表照搬);
  - `>= 10`:最优解析(`LZ4HC_compress_optimal` 的代价数组回溯,`favorDecompressionSpeed` 分支照搬);
- 匹配查找:链表(`chainTable`)+ 高级别切换二叉树(`LZ4HC_BinTree`),`deriving` 哈希 `LZ4HC_hashPtr` 照搬;
- `LZ4_compress_HC_destSize` 的目标尺寸反推逻辑照搬;
- HC 确定性同样受第 5.2 节保真点约束(golden 测试覆盖 levels 2/4/9/12)。

### 5.5 lz4frame*.cj —— Frame 格式

**格式规格(v1.0 frame,小端)**:魔数 `0x184D2204`;FLG(version=01/块独立/块校验和/内容校验和/内容长度/字典ID 标志)+ BD(块大小 64KB–4MB)+ 可选 contentSize(8B)/dictID(4B)+ HC(头校验和 `(XXH32(头,seed=0) >> 8) & 0xFF`);数据块(4B 压缩长度,最高位=未压缩块标志)+ 可选块校验和(XXH32);`0x00000000` 结束标记 + 可选内容校验和(XXH32,含所有解压后数据);skippable 帧 `0x184D2A50–5F`。

**压缩侧状态机**(`LZ4F_cctx`,`dStage` 等价物):
- `compressBegin`:头编码与偏好归一化(`LZ4F_preferences_t` 中 0 值取默认的规则照搬);
- `compressUpdate`:`stableSrc` 优化分支(输入可直接引用 vs 拷入内部缓冲)、autoFlush 与否的缓冲策略、linked 模式下复用 `LZ4_stream_t`/`LZ4_streamHC_t`、独立块模式每块重置;
- `compressEnd/flush`:结束标记与内容校验和;`uncompressedUpdate` 仅块独立模式可用;
- `LZ4F_CDict`:字典预处理(构建 `LZ4_stream_t` 状态),linked 模式直接续用;
- 头部缓冲区(`tmpBuff`)复用逻辑照搬,注意 `stableSrc` 下内部缓冲与源缓冲的指针语义在仓颉中的等价物(用引用相等性/标志位显式建模,不依赖指针比较)。

**解压侧状态机**(`LZ4F_dctx`,stage 枚举照搬):`getFrameHeader` → 逐块 `decodeBlock` → `getBlockChecksum/contentChecksum` → `dstage_getSuffix`;`LZ4F_decompress` 的分片输入/分片输出续传语义(任意切分点可恢复)、`nextSrcSizeHint` 返回值语义、`stableDst`/`skipChecksums` 选项、skippable 帧跳过、帧拼接(上一帧完成后可继续解析下一帧)全部照搬。这是**复杂度最高**的模块,测试权重最高。

### 5.6 xxhash.cj —— XXH32/XXH64(与上游同构的两套实现)

按上游 `xxhash.c` 结构逐函数移植 XXH32 与 XXH64 两个家族(one-shot + 流式 state:PRIME 常量、round/mergeRound/avalanche/finalize 的 switch-fallthrough 尾部处理),两套实现相互独立、不抽公共泛型核。流式 state(`XXH32_state_t`/`XXH64_state_t`:total_len + 累加器 + 16/32B 内部缓冲)照搬。`internal` 可见性,frame 仅使用 XXH32。

验证:官方测试向量(空串 `0x02CC5D05` / `0xEF46DB3751D8E999` 等)+ 与 C 实现交叉比对。

**设计决策记录:不采用泛型合并 32/64**(经 LTS-1.0.5 / STS-1.2.0 双工具链实验):

- 仓颉接口泛型经 F 有界建模(`interface XxhWord<W>` + `extend UInt32/UInt64`)可表达共享核,输出与手写版完全一致;
- 但性能上泛型**最好情况仅打平**:`-O2` 下(启用 CHIR 内联+去虚化)与手写特化计时一致;默认 `-O0` 下走装箱 + 运行时方法表分派,实测慢 3~35 倍;
- 即泛型只省代码、不提升性能,且把性能押在优化器行为上;叠加本项目"逐字对照移植、便于评审与上游同步"原则,选择两套独立实现;
- 附带约束备忘(如未来重议泛型方案需知):接口成员签名不可用 `Self`;接口静态成员不可依赖接口泛型参数;约束写 `where W <: Iface<W>`;泛型 outline 副本会留在二进制中(仅体积开销)。

## 6. 内存与性能策略

### 6.1 安全域与 unsafe 域分界

| 层 | 实现 | 理由 |
|---|---|---|
| 公开 API 入口、参数校验、frame 装配、状态管理、头/尾编码 | `Array<UInt8>` 安全索引 | 冷路径,可读性与防御性优先 |
| block/HC/解压的内层循环、哈希表访问、序列复制、校验和更新 | `CPointer<UInt8>` 手工寻址 | 热路径;越界检查开销显著 |

规则:
- 进入热路径前,一次 `Array<UInt8>` → `CPointer<UInt8>` 转换(`acquireArrayRawData` 取裸指针,用毕 `releaseArrayRawData` 归还);
- **acquire → 操作 → release 必须在同一 `unsafe {}` 域内完成,域内不做对象分配**(期间 GC 不移动对象,裸指针保持有效);
- unsafe 域内**照搬 C 的显式边界检查**(`ip < ilimit`、`op < oend`、`lowLimit/dictLimit` 区间判断),**不**依赖仓颉数组越界异常兜底——C 代码本身就是全量边界受控的,逐条对应移植即可;
- 每个进入 unsafe 的函数在注释中标注前置条件(指针有效范围),格式统一,便于评审。

### 6.2 整数语义

- 包级 `--int-overflow=wrapping`,统一 C 风格回绕;
- 哈希乘法、`LZ4_count` 粗对齐、HC 代价计算等按 UInt32/Int32 原类型逐表达式对应,不做"优化性"改写(如合并运算、更改求值宽度);
- 移植时逐处核对 C 表达式的整数提升规则(int vs unsigned),必要时显式标注仓颉侧类型。

### 6.3 性能验证手段

- `src/test/bench_test.cj`:内置语料的压缩/解压吞吐粗测(非回归门槛,用于发现数量级劣化);
- 若出现劣化:优先检查 unsafe 域泄漏(误用安全索引)、多余拷贝(frame 装配路径)、GC 压力(热路径分配);
- 特别关注:`-O2` 缺失或被移除(默认 -O0 下热循环有 7~23 倍差距,`compile-option` 已在 cjpm.toml 固定,不得移除;工具链升级时跑 bench 确认未退化)。

## 7. 双版本兼容策略(LTS-1.0.5 / STS-1.2.0)

### 7.1 代码约束

- 源码约束在两版本**共同语言子集**:以 1.0.5 可用特性为基线开发;1.2.0 新增 stdlib API 与语法糖一律不用;
- 规避已知分歧面:不使用版本敏感的宏/条件编译,不依赖 stdlib 中 1.2.0 才引入的容器/算法接口;
- 若开发中发现某能力仅在 1.2.0 存在:在 main 中用保守写法实现,并在 CHANGELOG 记录待简化点。

### 7.2 验证流程(每个里程碑收尾必须执行)

`scripts/build_and_test.sh both` 依次:

1. `source` LTS envsetup → `cjpm build && cjpm test`(全量);
2. 新 shell `source` STS envsetup → 同上;
3. 两侧输出(含测试统计)存档到 `report/`(不入库)。

任何单侧失败即里程碑不通过。

### 7.3 环境准备

- STS-1.2.0:解压 `~/cangjie-sdk-linux-x64-1.2.0.tar.gz` 至 `~/sdk/cangjie-1.2.0`,放置对应 envsetup;
- LTS-1.0.5:下载官方 1.0.5 SDK 安装包解压至 `~/sdk/cangjie-1.0.5` 并放置 envsetup(脚本自动尝试下载,无网络时人工放置后重跑);
- `scripts/setup_env.sh` 负责上述安装与 `cjpm --version` 自检。

### 7.4 分支与发布模型

- `main`:日常开发,以 LTS 为准;
- `lz4_lt_1.0.5` / `lz4_st_1.2.0`:发布分支,分别用对应工具链出制品;逻辑尽量冻结,只做版本适配微调(如 cjc-version 字段)。

## 8. 测试设计

### 8.1 分层

| 层 | 内容 | 目标 |
|---|---|---|
| L1 单元测试 | xxhash 向量、compressBound/边界数学、token 编码、工具函数 | 快速定位 |
| L2 往返测试 | 全 API 矩阵压缩→解压 byte 相等;`datagen` 语料 + 精心构造的边界输入 | 语义正确 |
| L3 golden 交叉验证 | C 版产出的压缩数据 ↔ 仓颉解压;仓颉压缩输出 ↔ C 版期望输出**逐字节比对** | 移植保真度 |
| L4 模糊测试 | 随机种子循环:随机数据/随机切分流式喂入/随机参数,往返断言;损坏输入下 `decompress_safe` 必须报错不崩溃 | 健壮性 |
| L5 双工具链 | L1–L4 在 1.0.5 与 1.2.0 下全绿 | 兼容目标 |

### 8.2 golden 语料设计

**生成方式**:`scripts/gen_golden.sh` 编译 `gen_golden.c`(链接 `~/lz4/lib` 源码),以与仓颉侧 `datagen.cj` **完全相同的 PRNG 序列**生成输入(移植上游 `datagen.c` 的 `RDG_genBuffer`,固定 seed),压缩后连同 manifest 写入 `corpus/` 入库。

**输入语料(15 类,单件 ≤ 256KB,原始输入只存一份)**:空、1B、16B、255B(literal 边界)、256B、64KB±1(块边界)、256KB 高重复、256KB 文本、256KB 随机(不可压缩)、字典友好模式(共享前缀)、长匹配游程、交替块、全零、CRC 式短记录、混合。

**体积控制**:输入文件与压缩产物入库;压缩产物 ≤ 64KB 的存原件用于逐字节比对,超过的只存摘要(SHA-256,由 C 侧 harness 一并写入 manifest,仓颉侧计算摘要比对——确定性校验强度等价,仅省体积);corpus 总量控制在 **8MB** 内。

**参数矩阵(约 200 个用例)**:

| 维度 | 取值 |
|---|---|
| block 压缩 | `compress_default`、`fast(acc=1/8)`、`destSize` |
| HC | levels 2/4/9/12,`favorDecompressionSpeed` 0/1 |
| frame blockSize | 64KB/256KB/1MB/4MB |
| blockMode | linked/independent |
| contentChecksum | 0/1 |
| blockChecksum | 0/1 |
| contentSize | 已知/未知 |
| dictID | 0/非 0 |
| 字典 | 无/64B/64KB |
| 压缩层级 | 0(fast)/3/9/12 |
| 大于 256KB 输入 | 运行时 datagen 生成,仅往返 + C 侧哈希比对(不入库) |

**校验内容**:①仓颉解压 golden → 与原始输入逐字节一致;②仓颉压缩(同参数)→ 与 golden 逐字节一致;③frame 侧额外校验仓颉产物可被 C `lz4` CLI 解压(CI 中若 CLI 不可用则跳过)。

### 8.3 测试细节要求

- `LZ4F_decompress` 的分片续传:对每个 golden frame 用 1B/7B/随机步长切分输入流解压,结果必须与整段解压一致(上游 frametest 的核心坑位);
- `LZ4_decompress_safe_partial`:targetOutputSize ∈ {0, 1, n-1, n} 全采样;
- 损坏输入:翻转 token 字节、截断、长度溢出构造,断言负错误码而非异常逃逸;
- 流式压缩跨块续用:`compress_continue` 连续 3 次以上,字典滑窗跨越 64KB 边界。

## 9. 工程与构建

- 构建系统:`cjpm`(两版本均自带);模块 `lz4cj`,包名 `lz4`;
- 提交规范:小步提交,每个提交须在双工具链下构建通过;
- 文档:README(API 对照表、与 C 差异清单、使用示例)、CHANGELOG(里程碑粒度)、本设计文档;
- 许可:上游 BSD-2-Clause,保留版权与免责声明;仓颉侧新增文件同样以 BSD-2-Clause 发布,文件头注明上游对应文件与 commit;
- 发布到仓颉中心仓时补充 `cangjie-repo.toml`(非 MVP 要求)。

## 10. 里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| M0 脚手架 | cjpm 工程与目录、scripts、双 SDK 环境、空模块 CI 脚本跑通 | `build_and_test.sh both` 在空实现+冒烟测试下双绿 |
| M1 xxhash | XXH32/XXH64 两套实现 + 流式 state | 官方向量 + C 交叉全过 |
| M2 block 压缩 | 压缩主路径、extState、Bound;golden 生成脚本 | 压缩输出与 C golden 逐字节/摘要一致(L3 单向);Bound 单测;双绿 |
| M3 block 解压 | safe/partial/dict、流式两端、fast 路径差分 | L2 往返 + L3 双向 + L4 模糊;双绿 |
| M4 HC | 全级别、optimal、流式、字典、destSize | L2/L3(HC 子集,往返 + golden);双绿 |
| M5 frame 压缩 | cctx 全 API、CDict | frame 压缩产物与 C golden 一致(L3 单向);头部编码单测;双绿 |
| M6 frame 解压 | dctx 全 API、续传、getFrameInfo、skippable 解析 | L2 往返 + L3 双向 + L4;双绿 |
| M7 收尾测试 | golden 全矩阵、fuzz 加压、bench | 全部测试双绿,golden ≥ 200 用例 |
| M8 发布 | README/CHANGELOG、发布分支、(可选)中心仓 | 双制品可被下游 cjpm 依赖引用成功 |

依赖顺序:M1 → M2 → M3 → M4,frame(M5、M6)依赖 M2–M4;M5 与 M6 之间解压侧可先行开发但验收需压缩侧就绪。

## 11. 风险与对策

| # | 风险 | 等级 | 对策 |
|---|---|---|---|
| R1 | `LZ4_wildCopy8`/交叠复制/非对齐访问的 unsafe 实现引入越界或语义偏差 | 高 | 先移植 safe 版做基准;fast 与 safe 差分测试;fuzz 覆盖;unsafe 前置条件注释 + 评审清单 |
| R2 | 压缩输出与 C 不一致(保真度破坏) | 高 | 第 5.2 节保真点清单作为移植与评审对照;golden 逐字节比对尽早介入(M2 起) |
| R3 | 双工具链行为差异(stdlib/优化语义)导致单侧失败 | 中 | 共同子集约束;每里程碑双跑;分歧点记录并保守实现 |
| R4 | `--int-overflow=wrapping` 下潜在的 Int32 有符号溢出 UB 点(C 侧本为有符号运算处) | 中 | 移植时逐表达式核对 C 类型提升;对 C 侧保证不溢出的表达式照搬即可,存疑处加断言 |
| R5 | frame 解压状态机续传语义复杂,分片边界处理出错 | 高 | 8.3 的随机切分测试;上游 frametest 坑位用例清单化移植 |
| R6 | GC/安全索引混入热路径导致性能不可接受 | 中 | unsafe 域边界清晰;bench 监控数量级 |
| R7 | 1.0.5 SDK 无法联网获取 | 低 | setup 脚本支持本地包放置;文档注明手工路径 |
| R8 | HC 最优解析器回溯逻辑移植错误 | 中 | levels 全采样 golden;代价函数单元测试 |

## 12. 附录:保真度关键点核对清单(移植评审用)

压缩输出与 C 逐字节一致的必要条件,评审每个压缩侧提交时逐项核对:

1. 哈希输入恰为位置起 `MINMATCH(4)` 字节小端序列,乘法常数 `2654435761`,移位量随 `tableType`(16/32 位表)区分;
2. `searchMatchNb` 步进序列与 acceleration 的映射关系(含 `LZ4_skipTrigger32 = 6` 跳过触发);
3. `LZ4_count` 的 8 字节粗对齐比较与回退逐字节比较的精确边界;
4. literal/match token 的进位规则与最后 5 字节(`MFLIMIT`)强制 literal;
5. 哈希表写入时机(每个 literal 位置/仅匹配位置/仅部分位置的上游差异需逐模式对应);
6. 字典模式下 `prefixStart`/`virtualStart`/`dictEnd` 指针三元组的等价区间运算;
7. HC:链表长度上限 `MAX_DISTANCE`、`nbAttempts` 级别表、lazy 二次确认条件、最优解析的代价并列时的选择顺序;
8. frame:头部标志位编码顺序、HC 校验和公式、块长度高位的未压缩标志、autoFlush 下缓冲刷新点。

---

*本文档基于上游 lz4 commit `0774d055`(v1.10.0 dev)与仓颉 LTS-1.0.5 / STS-1.2.0 工具链现状编写,作为 `lz4cj` 项目的开发基线;实现过程中的有意偏离须回写本文档并在 PR 中说明。*
