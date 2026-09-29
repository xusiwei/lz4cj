# lz4cj M3b 实现计划(流式压缩:prepareTable + continue + saveDict + loadDict/attach)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移植 LZ4 流式压缩全家(prepareTable 真实表保留语义、compress_fast_continue 三场景、saveDict、loadDict/fast/Slow、attach_dictionary、destSize_extState),压缩输出与 C golden 逐字节一致且全部经 M3a 解压器闭环往返,双工具链全绿。完成后 block 层 100% 闭环。

**Architecture:** LZ4_stream_t 以 (缓冲引用, 索引) 对补齐字典字段(与 §4.3 规则 4 同构);压缩核心扩展 withPrefix64k/usingExtDict/usingDictCtx/dictIssue 分支(对照上游 L939-1340 未移植部分);表复用语义按 prepareTable(L893)逐条件移植。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm、cc(C golden/探针)、std.unittest。

**Spec:** `docs/design.md`(§4.5 流式压缩清单、§5.2、§10 M3;§4.3 规则 2/4)。台账关联:`docs/progress.md` 遗留事项 M3b 归属 4 项。

## Global Constraints

- 同一套源码在 LTS-1.0.5 与 STS-1.2.0 下编译、测试全绿;每任务收尾 `scripts/build_and_test.sh both`。
- `compile-option = "--int-overflow=wrapping -O2"` 不得移除;指针三律(单 unsafe 域 acquire→操作→release、域内不分配、显式边界检查)。
- API 命名与 C 逐字一致;错误/返回语义逐字(压缩失败 0)。
- 上游参照 `~/lz4`(commit 0774d055):LZ4_prepareTable L893-937、destSize_extState L1490-1506、createStream L1540、resetStream/resetStream_fast L1540-1584 区段、freeStream L1584、loadDict_internal L1596-1659(_ld_fast/_ld_slow)、loadDict L1659、loadDictSlow L1662、attach_dictionary L1667-1714、compress_fast_continue L1716-1820、saveDict L1823-1840;核心字典分支 LZ4_compress_generic_validated L939-1340(withPrefix64k 前缀延续、usingExtDict 双段匹配、usingDictCtx、dictSmall/dictIssue)。
- 字典状态模型(ruling,沿 §4.3 规则 4 同构):`dictBuf: Option<Array<UInt8>> + dictStartIdx/dictSize`;上游 loadDict 不拷贝用户缓冲(仅记指针),本移植记 (引用, 索引),调用方保证缓冲存活期间使用——与 C 生命周期契约一致,注释说明。
- 保真度关键点(design 附录 12 全部适用,另加):prepareTable 的 5 个复用/清表条件逐条;continue 三场景判定顺序;withPrefix64k 的 base=currentOffset 虚拟寻址;usingExtDict 的 match 跨段拷贝(字典尾→块内);dictSmall(字典 < 64KB 且与 src 不连续)分支;loadDict 的 end-start 位置入表方式(_ld_slow 的逐位置 vs _ld_fast 的哈希策略——读上游实现为准);attach 的 dictCtx 只读挂接与 tableType 兼容条件。
- golden 期望值嵌入测试常量(先例);新 C 探针脚本一律入库 `scripts/`(台账义务)。
- 提交信息:`M3b: ...` 前缀;每任务收尾更新本计划勾选,最终任务更新 `docs/progress.md`(新维护规则)。

---

### Task 1: 流式状态家族 + prepareTable 真实语义 + 文档批次

**Files:** src/lz4.cj、src/lz4_test.cj、scripts/gen_golden.c(扩展)、corpus/、docs/design.md

**Interfaces:**
- Produces:
  - `public func LZ4_createStream(): LZ4_stream_t`、`public func LZ4_freeStream(s: LZ4_stream_t): Int32`(0)
  - `public func LZ4_resetStream(s: LZ4_stream_t): Unit`、`public func LZ4_resetStream_fast(s: LZ4_stream_t): Unit`
  - `internal func LZ4_prepareTable(state: LZ4_stream_t, inputSize: Int64, tableType: Int32): Unit`
  - `LZ4_stream_t` 补字段:`dictBuf: Option<Array<UInt8>>`、`dictStartIdx: Int64`、`dictSize: Int64`、`dictCtx: Option<LZ4_stream_t>`(T3 用,先留位)
  - tableType 常量族补 `clearedTable=0`(现有 byU32=2/byU16=3)
- Consumes: 现有 LZ4_initStream/state 字段

- [ ] **Step 1: 失败测试**:
  - prepareTable 条件表(单测直接调 internal):5 个分支各自触发/不触发(表类型切换、byU16 溢出 0xFFFF、byU32 >1GB 模拟值、inputSize>=4KB、clearedTable 直通),断言清表/复用后字段状态
  - resetStream/resetStream_fast:弄脏状态后字段归零;fast 版与 full 版在全新状态等价
  - createStream/freeStream 冒烟
  - golden(C 侧):`fastreset` 模式——同 stream 连续两次压缩(第二次走 prepareTable 复用),产物与返回值入库;仓颉侧经 `LZ4_compress_fast_extState_fastReset` 复现逐字节(C 侧等价 API:`LZ4_compress_fast_extState_fastReset` 连续同 state 调用)
- [ ] **Step 2: RED → 实现**(对照 L893-937 逐条件;resetStream=LZ4_initStream 语义,resetStream_fast=prepareTable(0,byU32) 对照 L1575-1580)→ fastReset 公开函数改走 prepareTable 路径(删 M2 的等价注释与委托,履行登记义务)
- [ ] **Step 3: GREEN(双工具链,44+新增)** 
- [ ] **Step 4: 文档批次**(台账):design §4.3 规则 2 "默认 0" 措辞改为"必传具名参数(现仓颉具名参数无默认值语法,调用方显式传 0)";§4.5 M2 清单补记 `LZ4_compress_destSize_extState`(标注 M3b-T4 落地,ruling);§4.4 LZ4_stream_t 行更新(字典字段已补)
- [ ] **Step 5: Commit** `M3b: stream state family with real prepareTable semantics`

---

### Task 2: compress_fast_continue 主路径(withPrefix64k)+ saveDict

**Files:** src/lz4.cj、src/lz4_test.cj、scripts/gen_golden.c、corpus/

**Interfaces:**
- Produces:
  - `public func LZ4_compress_fast_continue(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32`
  - `public func LZ4_saveDict(state: LZ4_stream_t, safeBuffer: Array<UInt8>, dictSize: Int32): Int32`
  - 压缩核心扩展:withPrefix64k 模式(base = src 指针 - currentOffset 的虚拟寻址:索引模型下 = `matchIndex 相对 0 的绝对索引,表存 absolute index(0 基 + currentOffset 偏移)`)与 dictSmall 分支
- Consumes: T1 的 prepareTable/字典字段

- [ ] **Step 1: C golden 扩展**:`cont` 模式——同一大缓冲内 K=6 块连续压缩(rolling,块间 continue,前缀同缓冲)、`savedict` 模式——块间 saveDict 迁移到 safeBuffer 后续压(usingExtDict 路径);产物/返回值/输入摘要入库
- [ ] **Step 2: 失败测试**:golden 逐字节复现;**闭环往返**(仓颉压缩 → 仓颉 `decompress_safe_continue` 同缓冲滚动解压 == 原始);saveDict 返回值(实际保存 min(dictSize, 可用))与迁移后续压正确性;错误传播(容量不足 → 0)
- [ ] **Step 3: 实现**:continue 三场景分发(对照 L1716-1820:dictSize==0 且前缀同缓冲 → withPrefix64k;字典存在 → usingExtDict;小字典 → dictSmall),状态更新(dictionary/dictSize/当前块位置),saveDict(拷贝 + 状态改指 safeBuffer)
- [ ] **Step 4: GREEN(双工具链)+ Commit** `M3b: compress_fast_continue with withPrefix64k and saveDict`

---

### Task 3: loadDict 家族 + attach_dictionary + usingExtDict/usingDictCtx 核心

**Files:** src/lz4.cj、src/lz4_test.cj、scripts/gen_golden.c、corpus/

**Interfaces:**
- Produces:
  - `public func LZ4_loadDict(dictState: LZ4_stream_t, dictionary: Array<UInt8>, dictSize: Int32): Int32`
  - `public func LZ4_loadDictSlow(dictState: LZ4_stream_t, dictionary: Array<UInt8>, dictSize: Int32): Int32`
  - `public func LZ4_attach_dictionary(workingStream: LZ4_stream_t, dictionaryStream: LZ4_stream_t): Unit`
  - 核心扩展:usingExtDict(match 跨段拷贝:字典尾→块内,L1110-1180 对照)与 usingDictCtx(只读 dictCtx 表查询)

- [ ] **Step 1: C golden 扩展**:`dict` 模式升级——loadDict(fast)与 loadDictSlow 各 8 行(压缩产物可能不同,分别入库);`attach` 模式 4 行(字典流 + 工作流续压);`extdict` 模式 6 行(块缓冲迁移触发 usingExtDict 段跨界引用)
- [ ] **Step 2: 失败测试**:golden 逐字节;闭环往返(usingDict 解压侧闭环);loadDict 返回值 == dictSize;attach 条件不满足时的降级行为(对照 L1667-1714 的兼容性检查)
- [ ] **Step 3: 实现**:loadDict_internal(对照 L1596-1659:字典内容按位置入表、currentOffset=dictSize、_ld_fast/_ld_slow 差异——读上游为准),attach(dictCtx 挂接 + 兼容条件),核心三分支
- [ ] **Step 4: GREEN(双工具链)+ Commit** `M3b: loadDict family, attach_dictionary and extDict core`

---

### Task 4: destSize_extState + 探针入库 + M3b 收尾

**Files:** src/lz4.cj、src/lz4_test.cj、scripts/、docs/progress.md、CHANGELOG.md、README.md

- [ ] **Step 1: `LZ4_compress_destSize_extState(state, src, srcSize, dst, targetDstSize, acceleration): (Int32, Int32)`**——公开包装(对照 L1490-1506:target ≥ compressBound 委托 extState 普通路径且 srcSizePtr 不动 → 返回 (c, srcSize);否则 fillOutput + extState 状态);golden `destext` 模式 6 行(含表复用场景)
- [ ] **Step 2: 探针入库清理**(台账):本里程碑全部新 C 探针(gen_golden 扩展之外独立小探针)以 `scripts/*.c` 入库并带构建注释;评估补 M3a 的 spanning 探针(若 /tmp 已失则重建脚本入库)
- [ ] **Step 3: 台账处置**:`#` 行解析守卫——若本里程碑测试仍嵌常量不解析 manifest,将该台账项重归属 M5/M6(帧测试若解析)或关闭并注明;在 progress.md 勾销/转移
- [ ] **Step 4: 全量门禁 + 覆盖率**(目标库源码 ≥97%)+ **docs/progress.md 更新**(首个执行新维护规则:完成表加 M3b 行、台账勾销、下一步 M4)+ CHANGELOG 0.4.0 + README 进度
- [ ] **Step 5: Commit** `M3b: destSize_extState, probe provenance and milestone wrap-up`

---

## Self-Review 记录

- 规格覆盖:设计 §4.5 流式压缩 10 函数全部有任务承接(create/free/reset(+fast)/loadDict/Slow/attach/continue/saveDict + destSize_extState);M2 登记义务(prepareTable)落 T1;台账 M3b 4 项(§4.3 措辞/清单补记/探针入库/# 行守卫)分别落 T1/T4。
- 类型一致性:continue/saveDict/loadDict/attach 签名与 (src, srcSize, dst, dstCapacity) 风格一致;字典 (buf, idx) 模型与 §4.3 规则 4 同构;destSize_extState 沿 §4.3 元组规则。
- 已知风险:①loadDict_fast/slow 的入表策略差异必须读上游实现细节,勿凭记忆;②usingExtDict 跨段拷贝是解压侧已验证逻辑的压缩镜像,但表项 stale 判定(base/dictBase 区间)易错,golden 覆盖;③fastReset 真实化后 M2 的 256 行 golden 必须仍然全绿(全新状态路径不受影响)。
