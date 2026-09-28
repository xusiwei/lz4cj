# lz4cj M2 实现计划(block 压缩:noDict one-shot + destSize + golden 交叉验证)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移植 LZ4 block 压缩的 one-shot 全路径(LZ4_compress_default/fast/extState 家族 + LZ4_compress_destSize),压缩输出与 C 实现对同一语料**逐字节一致**(≤64KB)/摘要一致(>64KB),双工具链全绿。

**Architecture:** 热路径用 `acquireArrayRawData`→`CPointer`→`releaseArrayRawData` 的 unsafe 惯用法(spike 已验证);上游 `LZ4_compress_generic_validated` 宏多态拆为显式仓颉函数;位置一律用 Int64 索引(相对 src 基指针),哈希表存 0 基索引;C 参考程序产出 golden 期望值。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm、cc(C golden harness)、std.unittest。

**Spec:** `docs/design.md`(第 4、5.1、5.2、6、8.2 节;M2 验收:"压缩输出与 C golden 逐字节/摘要一致(L3 单向);Bound 单测;双绿")。

## Global Constraints

- 同一套源码在 LTS-1.0.5 与 STS-1.2.0 下编译、测试全绿;每任务收尾 `scripts/build_and_test.sh both`。
- `compile-option = "--int-overflow=wrapping -O2"` 不得移除。
- API 命名与 C 逐字一致,公开函数 `public`;类型映射与签名调整按 design §4.2/4.3(int→Int32、in/out 指针→元组、offset! 惯例)。
- 无第三方依赖、无 FFI(CPointer/acquire 是 std.core 原生 API,不算 FFI)。
- 每个新增源文件头部带 4 行版权注释(样式同 src/lz4.cj)。
- 上游参照 `~/lz4/lib/lz4.c`(commit 0774d055)。关键行号:LZ4_count L689、LZ4_64Klimit L719、LZ4_skipTrigger L720、LZ4_compressBound L760、LZ4_hashPosition L806、put/getPosition L841-889、LZ4_compress_generic_validated L939-1340、one-shot 入口 L1399-1456、LZ4_compress_destSize 见 L1460 附近。
- 指针惯用法(已双工具链 spike 验证,必须遵守):
  ```cangjie
  unsafe {
      let h = acquireArrayRawData<UInt8>(arr)
      let p = h.pointer                      // CPointer<UInt8>
      let v = (p + i).read()                 // 字节
      let w32 = CPointer<UInt32>(p + i).read()   // 非对齐 u32(重解释构造)
      CPointer<UInt32>(p + i).write(x)           // 非对齐写
      releaseArrayRawData<UInt8>(h)
  }
  ```
  `acquire/release/read/write/+/CPointer<T>(p)` 全部只在 `unsafe {}` 域内使用;unsafe 域内不分配对象;**越界保护完全依赖移植自 C 的显式边界检查**(ip<ilimit、op<olimit 等),不依赖数组越界异常。
- src/dst 必须走指针;hashTable 允许安全 `Array<UInt32>` 索引(单点访问,-O2 可接受;M7 bench 再决定是否优化)。
- 保真度关键点(design 附录 12 第 1-5 条)是移植与自审清单:哈希 `((seq*2654435761u32) >> (32-hashLog))`、searchMatchNb 步进与 `LZ4_skipTrigger=6`、LZ4_count 的双向扩展与 8 字节粗对齐、token 编码与 MFLIMIT、表项 0 基索引写入时机。
- 提交信息:`M2: ...` 前缀。

---

### Task 1: common.cj 指针工具层 + 前置批次(文档同步、xxhash 补测)

**Files:**
- Create: `src/common.cj`、`src/common_test.cj`
- Modify: `src/xxhash_test.cj`(追加小输入流式 digest 测试)
- Modify: `docs/design.md`(§5.1/§6.1 术语同步)

**Interfaces:**
- Consumes: 无(独立于现有代码)
- Produces(全部 `internal`,函数体内部以 `unsafe { }` 封装,可被安全代码调用):
  - `func LZ4_readLE16(p: CPointer<UInt8>, i: Int64): UInt16`
  - `func LZ4_readLE32(p: CPointer<UInt8>, i: Int64): UInt32`
  - `func LZ4_readLE64(p: CPointer<UInt8>, i: Int64): UInt64`
  - `func LZ4_writeLE16(p: CPointer<UInt8>, i: Int64, v: UInt16)`
  - `func LZ4_writeLE32(p: CPointer<UInt8>, i: Int64, v: UInt32)`
  - `func LZ4_writeLE64(p: CPointer<UInt8>, i: Int64, v: UInt64)`
  - `func LZ4_wildCopy8(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64)`(8 字节步进,允许 op 尾部越界 len 内的余量——语义同上游;M2 压缩不用,为 M3 预备并测试)
  - `func LZ4_memcpyPtr(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64)`(逐字节精确拷贝)

- [ ] **Step 1: 写失败测试 src/common_test.cj**

```cangjie
// (4 行版权头,同 src/lz4.cj 样式)
package lz4

import std.unittest.*

@Test
func commonPtrIOTest(): Unit {
    let arr = Array<UInt8>(64, {i => UInt8(i)})
    let dst = Array<UInt8>(64, {_ => 0u8})
    unsafe {
        let h = acquireArrayRawData<UInt8>(arr)
        let p = h.pointer
        @Assert(LZ4_readLE16(p, 3) == 0x0403u16)
        @Assert(LZ4_readLE32(p, 3) == 0x06050403u32)
        @Assert(LZ4_readLE64(p, 5) == 0x0C0B0A0908070605u64)
        releaseArrayRawData<UInt8>(h)
        let dh = acquireArrayRawData<UInt8>(dst)
        let d = dh.pointer
        LZ4_writeLE32(d, 1, 0xDEADBEEFu32)
        @Assert(dst[1] == 0xEFu8 && dst[2] == 0xBEu8 && dst[3] == 0xADu8 && dst[4] == 0xDEu8)
        LZ4_writeLE64(d, 8, 0x0123456789ABCDEFu64)
        @Assert(dst[8] == 0xEFu8 && dst[15] == 0x01u8)
        LZ4_writeLE16(d, 20, 0xBEEFu16)
        @Assert(dst[20] == 0xEFu8 && dst[21] == 0xBEu8)
        releaseArrayRawData<UInt8>(dh)
    }
}

@Test
func commonCopyTest(): Unit {
    let src = Array<UInt8>(40, {i => UInt8(i + 100)})
    let dst = Array<UInt8>(48, {_ => 0u8})
    unsafe {
        let sh = acquireArrayRawData<UInt8>(src)
        let dh = acquireArrayRawData<UInt8>(dst)
        LZ4_memcpyPtr(dh.pointer, 4, sh.pointer, 0, 40)
        releaseArrayRawData<UInt8>(sh)
        releaseArrayRawData<UInt8>(dh)
    }
    for (i in 0..40) {
        @Assert(dst[i + 4] == UInt8(i + 100))
    }
}
```

- [ ] **Step 2: RED 确认** — `bash -c 'source ~/sdk/cangjie-1.0.5/envsetup.sh && cjpm test'`,期望 `LZ4_readLE16` 未定义。

- [ ] **Step 3: 写 src/common.cj**

```cangjie
// (版权头 + 说明:对应上游 lz4.c 的 MEM_*/LZ4_read*/LZ4_write* 宏族)
package lz4

internal func LZ4_readLE16(p: CPointer<UInt8>, i: Int64): UInt16 {
    return unsafe { CPointer<UInt16>(p + i).read() }
}

internal func LZ4_readLE32(p: CPointer<UInt8>, i: Int64): UInt32 {
    return unsafe { CPointer<UInt32>(p + i).read() }
}

internal func LZ4_readLE64(p: CPointer<UInt8>, i: Int64): UInt64 {
    return unsafe { CPointer<UInt64>(p + i).read() }
}

internal func LZ4_writeLE16(p: CPointer<UInt8>, i: Int64, v: UInt16): Unit {
    unsafe { CPointer<UInt16>(p + i).write(v) }
}

internal func LZ4_writeLE32(p: CPointer<UInt8>, i: Int64, v: UInt32): Unit {
    unsafe { CPointer<UInt32>(p + i).write(v) }
}

internal func LZ4_writeLE64(p: CPointer<UInt8>, i: Int64, v: UInt64): Unit {
    unsafe { CPointer<UInt64>(p + i).write(v) }
}

internal func LZ4_memcpyPtr(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64): Unit {
    unsafe {
        var k: Int64 = 0
        while (k < len) {
            (op + oi + k).write((ip + ii + k).read())
            k += 1
        }
    }
}

/* 上游 LZ4_wildCopy8:8 字节步进,最后一步可能越过 oi+len(至多 7 字节),
   调用方必须保证 dst 有 8 字节安全余量(M3 解压热路径)。 */
internal func LZ4_wildCopy8(op: CPointer<UInt8>, oi: Int64, ip: CPointer<UInt8>, ii: Int64, len: Int64): Unit {
    unsafe {
        var k: Int64 = 0
        while (k < len) {
            CPointer<UInt64>(op + oi + k).write(CPointer<UInt64>(ip + ii + k).read())
            k += 8
        }
    }
}
```

- [ ] **Step 4: GREEN(双工具链)** — `scripts/build_and_test.sh both`,新增 2 测试 + 既有 9 测试全绿(共 11)。

- [ ] **Step 5: xxhash 小输入流式 digest 补测**(清 M1 审查 deferred minor,覆盖率闭到 100%)

在 `src/xxhash_test.cj` 追加:

```cangjie
@Test
func xxhStreamingSmallInputTest(): Unit {
    // total_len < 16 的流式路径(v3 未轮转,digest 走 v3+PRIME5 分支)
    let a = "a".toArray()
    let hello = "Hello, world!".toArray()   // 13 字节,分块 5+8
    let st = XXH32_createState()
    @Assert(XXH32_reset(st, 0u32) == 0)
    @Assert(XXH32_update(st, a, 1) == 0)
    @Assert(XXH32_digest(st) == XXH32(a, 1, 0u32))
    @Assert(XXH32_reset(st, 0u32) == 0)
    @Assert(XXH32_update(st, hello, 5) == 0)
    @Assert(XXH32_update(st, hello, 8, offset: 5) == 0)
    @Assert(XXH32_digest(st) == XXH32(hello, 13, 0u32))
    let st64 = XXH64_createState()
    @Assert(XXH64_reset(st64, 0u64) == 0)
    @Assert(XXH64_update(st64, hello, 7) == 0)
    @Assert(XXH64_update(st64, hello, 6, offset: 7) == 0)
    @Assert(XXH64_digest(st64) == XXH64(hello, 13, 0u64))
}
```

- [ ] **Step 6: design.md 术语同步** — §5.1 与 §6.1 中 "UnsafePointer<UInt8>" 的表述替换为已验证的惯用法:`acquireArrayRawData`/`CPointer<UInt8>`/`releaseArrayRawData`,并在 §6.1 规则里补一条"acquire→操作→release 必须在同一 `unsafe {}` 域内完成,域内不做对象分配"。(脚注要求偏离回写。)

- [ ] **Step 7: Commit**

```bash
git add src/common.cj src/common_test.cj src/xxhash_test.cj docs/design.md
git commit -m "M2: pointer primitives in common.cj, doc sync, xxhash small-input test"
```

---

### Task 2: 压缩基础设施(Bound + 流状态 + golden 基建)

**Files:**
- Modify: `src/lz4.cj`(追加)
- Create: `src/lz4_test.cj` 中追加测试
- Create: `scripts/gen_golden.c`、`scripts/gen_golden.sh`
- Create: `corpus/block_golden_ref.txt`(生成产物,入库)

**Interfaces:**
- Consumes: 无新依赖
- Produces:
  - `public func LZ4_compressBound(inputSize: Int32): Int32`(公式:`inputSize + inputSize/255 + 16`;`inputSize < 0 || inputSize > LZ4_MAX_INPUT_SIZE` 返回 0)
  - `public const LZ4_MAX_INPUT_SIZE: Int32 = 0x7E000000`(上游 lz4.h:214;原文 0x7EFFFFF 为笔误,Task 2 已按 C 侧核实修正)
  - `public const LZ4_STREAMSIZE: Int32 = 16416`(信息性,见设计 §4.4)
  - `public class LZ4_stream_t`(internal 字段:`hashTable: Array<UInt32>` 大小 16384、`currentOffset: UInt32 = 0`、`tableType: Int32 = 0`、字典字段留位 `dictCtx`/`dictionary`/`dictSize` 可先缺省)
  - `public func LZ4_sizeofState(): Int32`(返回 LZ4_STREAMSIZE)
  - `public func LZ4_initStream(state: LZ4_stream_t): Int32`(哈希表清零、currentOffset=0;返回 0)

- [ ] **Step 1: 追加失败测试**

```cangjie
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
}

@Test
func lz4StreamStateTest(): Unit {
    let st = LZ4_stream_t()
    @Assert(LZ4_initStream(st) == 0)
    @Assert(st.currentOffset == 0u32)
    @Assert(st.hashTable.size == 16384)
    @Assert(st.hashTable[0] == 0u32 && st.hashTable[16383] == 0u32)
    @Assert(LZ4_sizeofState() == LZ4_STREAMSIZE)
}
```

(期望值 272/273/65809 由 C 侧 `LZ4_compressBound` 预先核实后再定稿——gen_golden 先行,见 Step 3。)

- [ ] **Step 2: RED → 实现到 GREEN** — 在 src/lz4.cj 追加上述接口(数值常量与 C 一致);`scripts/build_and_test.sh both`。

- [ ] **Step 3: golden 基建**

`scripts/gen_golden.c`:链接 `~/lz4/lib/lz4.c` + `xxhash.c` + `~/lz4/tests/datagen.c`(编译参照 datagen_ref 的注释:`-I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs`)。逻辑:

```c
// matrix: sizes {0,1,255,4096,65535,65536,65537,131072}
//        mp {0.0,0.5,0.9,1.0} x lp {0.0} x seeds {0,7}
// modes: default / fast1 (acceleration=1) / fast8 (acceleration=8) / dest (destSize, target=n*3/4)
// for each (n, mp, seed):
//   buf = malloc(max(n,1)); RDG_genBuffer(buf, n, mp, 0.0, seed);
//   default: c = LZ4_compress_default(buf, out, n, LZ4_compressBound(n));
//   fast1/fast8: c = LZ4_compress_fast(buf, out, n, bound, acc);
//   dest: target = n*3/4; consumed=n; c = LZ4_compress_destSize(buf, out, &consumed, target);
//   每 8 字节翻转一个 bit 的 corrupt 变体留给 M3(解压侧测试),本任务不需要
//   printf("n=%ld mp=%.2f seed=%u mode=%s size=%d xxh32=%08x xxh64=%016llx\n", ...)
//   其中 dest 行额外打印 consumed=%d;size<=65536 的行后跟一行 "  file=block/<hash>.lz4" 并写文件
```

`scripts/gen_golden.sh`:编译 gen_golden.c,`mkdir -p corpus/block`,运行输出 tee 到 `corpus/block_golden_ref.txt`。

- [ ] **Step 4: 运行生成 golden**

Run: `scripts/gen_golden.sh`
Expected: `corpus/block_golden_ref.txt` 256 行(64 组输入 × 4 模式),`corpus/block/` 下若干 ≤64KB 的压缩产物文件;入库。

- [ ] **Step 5: Commit**

```bash
git add src/lz4.cj src/lz4_test.cj scripts/gen_golden.c scripts/gen_golden.sh corpus/
git commit -m "M2: compressBound, stream state, golden harness baseline"
```

---

### Task 3: noDict one-shot 压缩完整路径(byU16 + byU32)+ golden 逐字节验证

**Files:**
- Modify: `src/lz4.cj`(压缩主实现)
- Modify: `src/lz4_test.cj`(golden 测试)

**Interfaces:**
- Consumes: Task 1 的 `LZ4_readLE*`/`LZ4_writeLE*`/`LZ4_memcpyPtr`;Task 2 的 `LZ4_stream_t`/`LZ4_initStream`/`LZ4_compressBound`
- Produces:
  - `public func LZ4_compress_default(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32): Int32`
  - `public func LZ4_compress_fast(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32`
  - `public func LZ4_compress_fast_extState(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32`
  - `public func LZ4_compress_fast_extState_fastReset(state: LZ4_stream_t, src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, dstCapacity: Int32, acceleration: Int32): Int32`
  - internal: `LZ4_count`、`LZ4_hashPosition`、`LZ4_compress_generic_noDict`(见下)
  - 注意:缓冲参数顺序沿上游 (src, srcSize, dst, dstCapacity)——与 M1 的 XXH32(input, len, seed) 一致风格,数组在前、长度随后。

- [ ] **Step 1: 移植内部原语(对照上游逐行)**

  - `LZ4_count`(L689-717):`pIn/pMatch` 两个基指针 + Int64 索引;向后扩展(8 字节粗对齐循环后逐字节)、向前扩展、上限 `pInLimit`;返回匹配长度。
  - `LZ4_hashPosition`(L806-815):`byU16` 用 hashLog=`LZ4_HASHLOG+1`、`byU32` 用 `LZ4_HASHLOG`(从上游源码取常量与移位公式,常量 `LZ4_HASHLOG` 依 `LZ4_MEMORY_USAGE=14` 得 12)。
  - 常量:`MINMATCH=4`、`MFLIMIT=12`、`LASTLITERALS=5`、`LZ4_skipTrigger=6`、`LZ4_64Klimit=65538`(64KB+MFLIMIT-1,L719)。

- [ ] **Step 2: 移植压缩主循环(核心任务)**

对照 `LZ4_compress_generic_validated`(L939-1340)中的 **noDict + notLimited/limitedOutput + byU16/byU32** 组合,拆为仓颉函数:

```cangjie
/* 参数化:byU16: Bool, limitedOutput: Bool —— 以两个 Bool 显式分支替代 C 的
   const 参数宏展开;语义逐行对照 L990-1200(noDict 路径):
   base = src 基指针;ip/op 为 Int64 索引;hashTable 存 0 基 UInt32/UInt16 索引
   (byU16 表项截断为 UInt16,再读回时零扩展)。 */
internal func LZ4_compress_generic_noDict(
        state: LZ4_stream_t, src: CPointer<UInt8>, n: Int64,
        dst: CPointer<UInt8>, dstCapacity: Int64,
        byU16: Bool, limitedOutput: Bool, acceleration: Int64): Int64
```

骨架要点(逐条对照上游):
1. 入参校验:`n >= LZ4_64Klimit` 时必须 byU16=false;`acceleration < 1` 视为 1。
2. `ip=0` 起步:首位置入表(L1014-1020);`forwardH = hashPosition(ip+1)`。
3. 主循环 `_next_match`(L1028-1200):`searchMatchNb = acceleration << LZ4_skipTrigger` 起步(L1032);`step = searchMatchNb++ >> LZ4_skipTrigger`;尝试 `match = table[h]`;`forwardIp = ip + step`;`ip < matchLimit(n-MFLIMIT)` 条件;literal 尝试、`LZ4_count` 确认(>=MINMATCH 才算命中)、continue 尝试(`LZ4_count(ip+MINMATCH, match+MINMATCH) > 0` 时换更长 match,L1085-1100 区段)。
4. token 编码:`op` 写 token、literal 长度扩展字节(每 255 进位)、`LZ4_memcpyPtr` 拷 literal、写 match offset(UInt16 LE)、`LZ4_count` 全长、match length 扩展字节;**MFLIMIT/最后 5 字节 literal 规则**(L1180-1210 的最后 token 处理:ip <= iend-LASTLITERALS 时才继续找 match;最后 token 后 literal 拷贝)。
5. limitedOutput 分支:每个 literal/match 写入前检查 `op + needed <= oend`,否则返回 0(对照 limitedOutput 宏)。
6. 表项更新:每个位置 `LZ4_putPositionOnHash` 对应的索引写入(byU16 写 UInt16 截断)。
7. 返回:成功 `op`(写入字节数 Int32)。

**验收基准就是 golden——语义差异无处可藏。** 实现时对上游逐行注释行号,自审对照 design 附录 12 第 1-5 条。

- [ ] **Step 3: wire 公开 API**

- `LZ4_compress_fast_extState`:校验 → `initStream` → 选表(srcSize < LZ4_64Klimit → byU16)→ acquire src/dst 两个数组 → 调 `LZ4_compress_generic_noDict` → release → 返回。
- `_fastReset`:不重置表(上游 `fastReset` 语义:LZ4_initStream 不调用,依赖 tableType 检查)——对照上游 L1425-1460 的分支移植;M2 内 fastReset 与普通版行为可暂一致(表复用正确性属流式范畴,golden 用新 state),在代码注释注明。
- `LZ4_compress_default`/`LZ4_compress_fast`:构造临时 `LZ4_stream_t` 后走 extState。

- [ ] **Step 4: golden 测试(逐字节/摘要)**

`src/lz4_test.cj` 追加:

```cangjie
@Test
func lz4CompressGoldenTest(): Unit {
    // 解析 corpus/block_golden_ref.txt(格式 Task 2 Step 3 定义)
    // 对每行:n/mp/seed → RDG_genBuffer 生成输入 → 按 mode 调对应 API
    //   size <= 65536 且有 file= 的行:读 corpus/block/<name> 文件,与仓颉输出逐字节比对
    //   其余行:XXH32/XXH64(自己的 internal 实现)对仓颉输出算摘要,与 xxh32/xxh64 字段比对
    // dest 行跳过(Task 4 接入),default/fast1/fast8 全比对
    // 断言总数 == 192(64×3)
}
```

期望值以嵌入常量方式(沿 M1 datagen 测试先例),由 gen_golden.sh 输出转换。

- [ ] **Step 5: 调试循环到 GREEN(双工具链)** — 不匹配时二分定位:先用 n=255 单输入对比 C 字节流(在 gen_golden.c 加 `-DDEBUG_DUMP` 转储十六进制),逐 token 对照;修复后跑全矩阵。

- [ ] **Step 6: 单元补充** — `LZ4_compress_default(empty,0)` 返回 1 且 dst[0]==0(token 全零);随机不可压缩输入 + dstCapacity 不足 → 返回 0;`LZ4_compressBound` 容量刚好时成功。

- [ ] **Step 7: Commit**

```bash
git add src/lz4.cj src/lz4_test.cj
git commit -m "M2: noDict one-shot compression with golden byte-exact validation"
```

---

### Task 4: LZ4_compress_destSize(fillOutput 模式)

**Files:**
- Modify: `src/lz4.cj`、`src/lz4_test.cj`

**Interfaces:**
- Produces: `public func LZ4_compress_destSize(src: Array<UInt8>, srcSize: Int32, dst: Array<UInt8>, targetDstSize: Int32): (Int32, Int32)`(返回 `(压缩字节数, srcConsumed)`,design §4.3 元组规则;失败返回 `(0, srcSize)`)

- [ ] **Step 1: 失败测试** — golden 的 dest 行接入 `lz4CompressGoldenTest`(或独立 `lz4CompressDestSizeGoldenTest`):逐字节/摘要比对 + `consumed` 字段精确相等;断言 64 行。

- [ ] **Step 2: 移植** — 对照上游 `LZ4_compress_destSize`(L1460 附近入口)及其调用的 `outputDirective == fillOutput` 分支(L939 主函数内 `fillOutput` 相关段):从尾向头的解码式确认(`lastRun` 反推)、`ipLimit` 前移、inputConsumed 写出。签名包装为元组返回。

- [ ] **Step 3: GREEN(双工具链)+ Commit**

```bash
git add src/lz4.cj src/lz4_test.cj
git commit -m "M2: LZ4_compress_destSize with golden validation"
```

---

### Task 5: M2 收尾(全矩阵 + 覆盖率 + 文档)

- [ ] **Step 1**: `scripts/build_and_test.sh both` 全绿(预计 17+ 测试:11 基线 + bound/state 2 + golden 2 + 补充若干);统计 golden 覆盖用例数(256)。
- [ ] **Step 2**: 覆盖率:`cjpm clean && cjpm test --coverage && cjcov --html-details --output=report`,记录 src/lz4.cj、src/common.cj 覆盖率数字到 CHANGELOG(目标:库源码 ≥90%,未覆盖行需可解释为防御分支)。
- [ ] **Step 3**: README 进度更新(M2 完成)、CHANGELOG 追加。
- [ ] **Step 4**: Commit `M2: wrap up milestone with coverage report and docs`。

---

## Self-Review 记录

- 规格覆盖:M2 验收三项(L3 单向 golden、Bound 单测、双绿)分别落在 Task 3/4、Task 2、每任务收尾;design §4.5 的 M2 范围 API(default/fast/extState×2/destSize/Bound/sizeofState/initStream)全部有任务承接。流式(loadDict/continue/saveDict)与 usingExtDict 明确不在本计划(M3)。
- 类型一致性:缓冲参数顺序统一 (src, srcSize, dst, dstCapacity[, acceleration]);destSize 元组返回与 design §4.3 一致;common.cj 的 (p, i) 索引风格与 unsafe 惯用法一致。
- 已知风险:①byU16 表项的 UInt16 截断/零扩展——golden 全覆盖兜底;②fastReset 在无流式场景下与普通版行为等价的论断(golden 全部用新 state)已在代码注释;③fillOutput 分支最复杂,放在 golden 已验证主路径之后的独立任务。
