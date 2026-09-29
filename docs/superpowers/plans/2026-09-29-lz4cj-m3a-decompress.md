# lz4cj M3a 实现计划(block 解压全家 + 双向 golden + fast/safe 差分 + 流式解码 + 模糊测试)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移植 LZ4 block 解压全部非弃用 API(safe/partial/usingDict/流式 continue 家族),以 M2 golden 语料完成**双向交叉验证**(C 压→仓颉解压 == 原始输入;仓颉压→仓颉解压往返),fast/safe 差分与损坏输入模糊测试全绿,双工具链通过。

**Architecture:** 解压核心对照上游 `LZ4_decompress_generic`(lz4.c:2022)移植为参数化仓颉函数(partialDecoding/dict directive/前缀位置全部显式参数);前缀/字典场景用"整缓冲 + 位置索引"模型(前缀即 dstIdx 之前的同缓冲字节,外字典为独立 Array);safe 路径先行作正确性基准,fast 路径(wildCopy 快循环)以差分测试保障。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm、cc(C 侧 continue golden)、std.unittest。

**Spec:** `docs/design.md`(§4.5 解压 API 清单、§5.3、§8 测试分层 L2-L4;M3 验收:"L2 往返 + L3 双向 + L4 模糊;双绿")。M3b(流式压缩)另行计划。

## Global Constraints

- 同一套源码在 LTS-1.0.5 与 STS-1.2.0 下编译、测试全绿;每任务收尾 `scripts/build_and_test.sh both`。
- `compile-option = "--int-overflow=wrapping -O2"` 不得移除。
- API 命名与 C 逐字一致,公开函数 `public`;缓冲参数顺序沿 (src, srcSize, dst, ...) 风格。
- 指针三律(沿 M2):公开 API 入口一个 `unsafe{}` 域内 acquire→操作→release;域内不分配;越界保护只靠移植自 C 的显式检查。
- **错误语义逐字**:解压错误返回 `-(ipIndex) - 1`(ip 为解析失败处的输入内偏移,lz4.c:2462);输入校验错误返回 -1(lz4.c:2033/2046);成功返回输出字节数。v1.10 的 lz4.h **没有** LZ4_errorCodes 枚举(设计文档 §4.7 的表述有误,T1 修正文档:负位置编码即上游语义)。
- 上游参照 `~/lz4/lib/lz4.c`:decompress_generic L2022-2465、safe L2470、safe_partial L2477-2484(dstCapacity=MIN(target,capacity))、withPrefix64k/withSmallPrefix/usingDict 变体 L2497-2570、streamDecode 家族 L2594-2650+(setStreamDecode L2608、decoderRingBufferSize L2634(最小 16,公式 65536+14+maxBlockSize)、continue L2650+ 三场景:首块→普通 safe;prefixEnd==dest 滚动→withPrefix64k/withSmallPrefix;否则→外字典换向)。
- 不移植:`LZ4_decompress_fast` 家族(设计 §4.6 显式排除,上游 L2487-2495)。
- golden 期望值嵌入测试常量(M1/M2 先例);corpus 文件入库。
- fuzz 默认 2000 随机种子循环(时长可接受;若超 60s 降到 500 并记录)。
- 提交信息:`M3: ...` 前缀。

---

### Task 1: 解压核心 safe 路径 + LZ4_decompress_safe + M2 遗留批次

**Files:**
- Modify: `src/lz4.cj`(追加解压实现)
- Modify: `src/lz4_test.cj`(追加测试)
- Modify: `scripts/gen_golden.c`、`corpus/`(tight-capacity 行)
- Modify: `docs/design.md`(§4.7 错误语义修正)

**Interfaces:**
- Consumes: common.cj 的 `LZ4_readLE16/32`、`LZ4_memcpyPtr`、`LZ4_wildCopy8`
- Produces:
  - `public func LZ4_decompress_safe(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32): Int32`
  - internal 解压核心(为 T2/T3/T4 扩展参数化):
    ```cangjie
    /* 对照 lz4.c:2022-2465。前缀/外字典以 (buf, idx) 位置模型表达:
       dstArr[dstIdx..) 为输出区;lowPrefixIdx 为同缓冲内前缀起点(≤dstIdx);
       dictArr/dictStartIdx/dictSize 表达外字典(nil 时无)。 */
    internal func LZ4_decompress_generic(
        srcArr: Array<UInt8>, srcSize: Int64,
        dstArr: Array<UInt8>, dstIdx: Int64, outputSize: Int64,
        partialDecoding: Bool,
        lowPrefixIdx: Int64,
        dictArr: Option<Array<UInt8>>, dictStartIdx: Int64, dictSize: Int64): Int64
    ```

- [ ] **Step 1: 失败测试** — 追加:
  - M2 golden 产物解压:取 `block_golden_ref.txt` 的 default/fast1/fast8/dest 全部 256 行,读对应 artifact(无 artifact 的大输入跳过,由 T2 的 digest 路径补),`LZ4_decompress_safe(artifact, size, out, n) == n` 且 out[0..n) == 原始 datagen 输入(逐字节)——**这就是 L3 双向的前半**
  - 错误语义:构造截断/损坏 token 输入,断言返回负值;空 srcSize=0 → -1;outputSize=0 且 srcSize==1 且 src[0]==0 → 0
  - 仓颉往返冒烟:`LZ4_compress_default` → `LZ4_decompress_safe` == 原输入(3 组小输入)
- [ ] **Step 2: RED 确认**
- [ ] **Step 3: 实现核心 safe 路径** — 对照 L2022-2465 移植(本任务先移植 **safe 循环**与全部错误出口;fast 循环 L2079-2260 区段 T3 再加):特例分支(L2051-2057)、token 解析、literal 拷贝(含 `LZ4_memcpyPtr` 与 wildCopy 边界条件——safe 路径 literal 用精确拷贝)、match 偏移校验(`offset > 0 && match >= lowPrefixIdx`)、`_output_error: return -(ip) - 1`、成功返回 op 字节数;`LZ4_decompress_safe` 包装(acquire src+dst,lowPrefixIdx=dstIdx=0,无字典)
- [ ] **Step 4: GREEN(双工具链)** — 全部既有 21 测试 + 新测试绿
- [ ] **Step 5: M2 遗留批次**:
  - lz4.cj 两处注释里程碑修正(M5/M4+ → M3)
  - gen_golden.c 增加 tight-capacity 行:新 mode `tight`(default 压缩后 dstCapacity=返回值-1 → C 返回 0 的行,记录 `size=0`),8-10 行即可,更新 manifest 并入库
  - design.md §4.7:错误码表述改为"负位置编码 `-(ip偏移)-1`,与上游 lz4.c:2462 一致;输入校验错误 -1"
- [ ] **Step 6: Commit** `M3: decompress safe core with golden decompression and error semantics`

---

### Task 2: safe_partial + usingDict 变体 + 双向 golden 收口

**Files:** src/lz4.cj、src/lz4_test.cj

**Interfaces:**
- Produces:
  - `public func LZ4_decompress_safe_partial(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, targetOutputSize: Int32): Int32`
  - `public func LZ4_decompress_safe_usingDict(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, dict: Array<UInt8>, dictSize: Int32): Int32`
  - `public func LZ4_decompress_safe_partial_usingDict(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, targetOutputSize: Int32, dict: Array<UInt8>, dictSize: Int32): Int32`

- [ ] **Step 1: 失败测试**:
  - partial 语义(L2477-2484 + generic 内 partialDecoding 分支):target ∈ {0,1,n/2,n-1,n} 对 golden 产物解压,断言返回 == min(target, 完整长度) 且前缀正确(上游 partial 语义:尽早停止,返回实际产出 ≤ target)
  - usingDict:构造 64KB 字典场景——仓颉侧用 `LZ4_loadDict` 不可用(M3b),改用**直接法**:输入 = dict 数据压缩时引用 dict → 由 C 侧生成(见 Step 2)
  - **L3 双向收口**:大输入(131072)digest 路径——仓颉解压后对输出算 XXH32/64 与原始输入 digest 比对;仓颉压→仓颉解压全矩阵往返(L2)
- [ ] **Step 2: C 侧字典 golden 扩展** — gen_golden.c 增 mode `dict`:64KB 随机字典(固定 seed 独立生成)前置引用压缩(C 侧用 `LZ4_loadDict` + `LZ4_compress_fast_continue` 生成引用字典的块),产物入库;仓颉侧 `decompress_safe_usingDict` 解压 == 原始
- [ ] **Step 3: 实现** — partialDecoding 分支(generic 内 early-stop 逻辑对照上游 partial_decode 路径)与 usingDict 包装(dictArr=Some(dict),dictStartIdx=0)
- [ ] **Step 4: GREEN(双工具链)+ Commit** `M3: safe_partial and usingDict with bidirectional golden`

---

### Task 3: fast 解压路径 + safe/fast 差分测试

**Files:** src/lz4.cj、src/lz4_test.cj

**Interfaces:**
- Produces: 解压核心内的 fast 循环(LZ4_FAST_DEC_LOOP 区段 L2079-2260:shortcut 判定 `shortiend/shortoend`、32 字节可靠拷贝、match 8/16/32 粗对齐比较、wildCopy 尾部);对外签名不变(核心内部按 `oend-op >= FASTLOOP_SAFE_DISTANCE` 分派,与上游一致)

- [ ] **Step 1: 差分测试(先写)** — 对 golden 全部产物 + 随机语料(≥ 500 组 LCG 随机输入,含各种 literal/match 密度):分别强制走 safe 与 fast 路径(internal 参数或临时开关),断言输出**逐字节一致**且返回值一致;损坏输入两路都必须报负值(相同或均为负)
- [ ] **Step 2: 实现 fast 循环** — 对照 L2079-2260:`LZ4_wildCopy8` 步进、`LZ4_dec64` 等价(64 位读比较)、literal/match 的 shortcut 分支、尾部 `< LASTLITERALS` 精确收尾;保持错误出口语义一致
- [ ] **Step 3: GREEN(双工具链)+ 性能冒烟** — 记录 4MB 语料解压吞吐(仅供 CHANGELOG 记录,无门槛)
- [ ] **Step 4: Commit** `M3: fast decode loop with safe/fast differential validation`

---

### Task 4: 流式解码家族(continue + 环缓冲)

**Files:** src/lz4.cj、src/lz4_test.cj、scripts/gen_golden.c、corpus/

**Interfaces:**
- Produces(签名适配"整缓冲+位置"模型,沿 offset! 惯例注册到 design §4.3 第 4 条规则):
  - `public class LZ4_streamDecode_t`(internal 字段:prefixSize、extDictSize、prefixEndBuf: Array/Option、prefixEndIdx、externalBuf: Option<Array>、externalStartIdx——以"缓冲引用+索引"表达 C 的 prefixEnd/externalDict 指针)
  - `public func LZ4_createStreamDecode(): LZ4_streamDecode_t`、`public func LZ4_freeStreamDecode(s: LZ4_streamDecode_t): Int32`
  - `public func LZ4_setStreamDecode(s: LZ4_streamDecode_t, dict: Array<UInt8>, dictSize: Int32): Int32`(外部字典注入,C L2608)
  - `public func LZ4_decoderRingBufferSize(maxBlockSize: Int32): Int32`(C L2634:maxBlockSize<0 或 >MAX→0;<16 提到 16;返回 65536+14+maxBlockSize)
  - `public func LZ4_decompress_safe_continue(s: LZ4_streamDecode_t, src: Array<UInt8>, srcSize: Int32, dstBuf: Array<UInt8>, dstIdx: Int64, maxOutputSize: Int32): Int32`(滚动场景要求 dstBuf[dstIdx-前缀, dstIdx) 为已解码内容)

- [ ] **Step 1: C golden(continue 序列)** — gen_golden.c 增 `stream` 模式:单一大缓冲内连续解码 K=8 块(块间 continue,C 的 rolling 场景),记录每块返回值 + 最终整体 XXH32/64;另加 setStreamDecode 外字典场景 2 组
- [ ] **Step 2: 失败测试** — 仓颉侧同缓冲同位置复现:逐块 `decompress_safe_continue`,返回值与 manifest 精确一致、整体 digest 一致;环缓冲语义测试(用 `LZ4_decoderRingBufferSize` 尺寸的缓冲,块大小 16KB,滑窗跨 64KB 边界);setStreamDecode 字典注入往返
- [ ] **Step 3: 实现** — continue 三场景分发对照 C L2650-2720:首块(prefixSize==0)→safe;滚动(prefixEnd 命中同缓冲同位置)→withPrefix64k(≥64KB-1)/withSmallPrefix;否则外字典换向(externalBuf 指向前一缓冲段);`withSmallPrefix` 内部即 generic 的 (lowPrefixIdx=dstIdx-prefixSize) 调用形参化,无需独立函数
- [ ] **Step 4: GREEN(双工具链)+ Commit** `M3: streaming decode family with rolling-buffer golden`

---

### Task 5: L4 模糊测试 + M3a 收尾

**Files:** src/lz4_test.cj(或新 src/fuzz_test.cj)、CHANGELOG.md、README.md

- [ ] **Step 1: 模糊套件** `fuzzDecompressTest`:
  - 2000 种子循环:LCG 生成随机输入(0-4KB)→ 仓颉压缩 → 随机变换(位翻转 1-8 处/截断 1-16 字节/长度字段篡改/随机垃圾)→ `LZ4_decompress_safe(_partial)`:断言结果二值化——正数且输出与可能的原输入一致(无变换时)或负值;**绝不越界异常逃逸**(catch 全部异常视为失败)
  - continue 场景模糊:流式序列中途损坏 → 负值或状态可控
- [ ] **Step 2: 全量门禁双绿**;统计:L2 往返矩阵数、L3 行数(256+tight+dict+stream)、L4 种子数
- [ ] **Step 3: 覆盖率** — cjcov 报告,库源码目标 ≥93%,未覆盖行逐条解释(防御分支)
- [ ] **Step 4: CHANGELOG(M3a 节)/README 进度**;Commit `M3: fuzz suite and milestone wrap-up`

---

## Self-Review 记录

- 规格覆盖:M3 验收三项分任务落位——L2 往返(T2)、L3 双向(T1 C压→仓颉解,T2 收口+dict/T4 stream)、L4 模糊(T5);差分(T3)为设计 §5.3 硬要求。M2 遗留(注释/tight 行)并入 T1。流式压缩(prepareTable 义务)明确属 M3b,不在本计划。
- 类型一致性:解压签名统一 (src, srcSize, dst, dstCapacity, ...);continue 用 (dstBuf, dstIdx) 位置模型,与 generic 的 lowPrefixIdx 参数贯通;错误返回 Int32 负位置编码。
- 已知风险:①partial 的 early-stop 语义边界(target==0/输出已满)以 C golden 锚定;②fast 循环的 shortcut 判定(shortiend/shortoend)是差分重点;③continue 的 prefixEnd "同缓冲同位置"判定在仓颉侧需引用相等性(Array 引用 ==)+索引相等,等价 C 指针相等。
