# lz4cj M8 实现计划(发布:版本定稿 + 零警告构建 + 下游依赖验收 + 文档收尾 + 发布分支)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 兑现设计 §10 M8 验收标准"双制品可被下游 cjpm 依赖引用成功":cjpm.toml 版本/元数据定稿、lib 构建零警告(`-Woff` 抑制 + 裁定登记)、下游依赖验收脚本(本地 path 依赖 + 双工具链冒烟)、README API 对照表/使用示例/性能裁定、CHANGELOG 0.9.0、design/progress 收尾、发布分支 `lz4_lt_1.0.5` / `lz4_st_1.2.0` 与 tag `v0.9.0-lt` / `v0.9.0-st`。

**Architecture:** 纯发布工程里程碑:**库源码零改动**(`src/*.cj` 全部冻结 —— 性能 §2.2 书面裁定结案:差距结构性,不做单点优化,保持"库源码与 M6 收官逐字节一致"资产)。所有变更限于 cjpm.toml、scripts/ 新脚本、四份文档、git 分支/tag。下游验收采用 cjpm 本地 path 依赖机制(已实证:`[dependencies] lz4 = { path = "<repo>" }` + `import lz4.*` 单包形态,下游包名任意但须与 `package <name>` 声明一致)。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm(path 依赖 + 静态库制品 `target/release/lz4/liblz4.a` + `lz4.cjo`)、bash。

**Spec:** `docs/design.md`(§2.2 性能非目标条款、§7.4 分支与发布模型、§9 工程与构建之 README 要求、§10 M8 行)。关联:`docs/progress.md` L33(M8 分解)、L49(unused 警告台账)。

**裁定基线(2026-10-03,用户批准):** 性能 §2.2 书面裁定结案(源码冻结);中心仓暂不接入;版本号 0.9.0(CHANGELOG 条目 + cjpm.toml version 对齐;1.0.0 留给后续);23 条 lib 构建警告以 `-Woff` 抑制 + CHANGELOG 归类裁定。

## Global Constraints

- **库源码冻结**:`src/*.cj` 任何文件不得修改(任务完成判据含 `git diff --stat` 无 src/ 条目;唯一例外:无)。
- **测试基线不变**:`scripts/build_and_test.sh both` 双工具链各 156/156 全绿;golden 清单数字不变(512 行/489 数据行);不新增/删除测试。
- **警告抑制语法(已实证)**:`-Woff unused -Woff parser` 重复标志形式;逗号合并(`-Woff unused,parser`)cjc 报 `invalid value`,禁止使用。双工具链均接受、lib 构建零警告。
- **下游依赖机制(已实证)**:下游 `[dependencies]` 写 `lz4 = { path = "<仓库绝对路径>" }`;下游源文件需 `package <下游包名>` 声明 + `import lz4.*`(库为单包 `lz4`,`import lz4.lz4` 形态错误)。
- **smoke 钉值(已实证,LTS/STS 同值)**:65536 字节 `(i*31+7)%251` 周期输入 → block default c=517、HC lv9 hc=517、frame 一次性 fc=532。
- **版本号统一 0.9.0**:cjpm.toml `version = "0.9.0"`、CHANGELOG 条目 `## 0.9.0 (M8)`、tag `v0.9.0-lt` / `v0.9.0-st`。
- **不推送远端**:不 `git push`;中心仓(`cangjie-repo.toml`)不接入。远端 origin = `git@atomgit.com:xusiwei1236/lz4cj.git`。
- **cjc-version 策略**:main 保持 `"1.0.5"`(双工具链基线,设计 §3.2);st 分支微调为 `"1.2.0"`(设计 §7.4 预期调整;LTS 亦接受该值,但 st 分支仅 STS 验证)。
- **cjpm 增量缓存异常处置**:遇 `DataModelException` / `loadDepIncrementalCache` 崩溃 → `rm -rf target` 后重试(2026-10-03 已遇一次,清缓存即恢复)。
- 提交信息 `M8: ...` 前缀;main 直提交流程(M0-M7 既定);每任务收尾勾选本计划。
- 环境:SDK 位于 `~/sdk/cangjie-1.0.5` 与 `~/sdk/cangjie-1.2.0`,envsetup 分别 `source ~/sdk/cangjie-1.0.5/envsetup.sh` / `~/sdk/cangjie-1.2.0/envsetup.sh`。

---

### Task 1: 发布工程 —— cjpm.toml 定稿 + 下游依赖验收脚本

**Files:**
- Modify: `cjpm.toml`(version、compile-option、repository 三处)
- Create: `scripts/downstream_smoke.cj`(下游冒烟源,包名 `lz4_ds_smoke`)
- Create: `scripts/verify_downstream.sh`(可执行,`chmod +x`)

**Interfaces:**
- Consumes: 公开 API `LZ4_compressBound` / `LZ4_compress_default` / `LZ4_decompress_safe` / `LZ4_compress_HC` / `LZ4F_compressFrameBound` / `LZ4F_compressFrame` / `LZ4F_isError` / `LZ4F_getErrorName` / `LZ4F_createDecompressionContext` / `LZ4F_decompress`(签名见 src/lz4.cj:851,1803、src/lz4hc.cj:2039、src/lz4frame.cj:128,133,239,1114、src/lz4frame_decode.cj:88,1069)
- Produces: `scripts/verify_downstream.sh [lt|st|both]`(Task 3 复用,分支验收门);零警告构建配置(Task 2 文档引用)

- [ ] **Step 1: cjpm.toml 三处定稿**

改 `version = "1.0.0"` → `version = "0.9.0"`;`compile-option = "--int-overflow=wrapping -O2"` → `compile-option = "--int-overflow=wrapping -O2 -Woff unused -Woff parser"`;`repository = ["https://example.com/lz4cj"]` → `repository = ["https://atomgit.com/xusiwei1236/lz4cj"]`。其余字段不动。

- [ ] **Step 2: 写入 scripts/downstream_smoke.cj**(逐字使用已验证版本)

```cangjie
package lz4_ds_smoke

/* M8 下游依赖验收冒烟(设计 §10 验收标准):本地 path 依赖消费 lz4 制品,
   块 default / HC lv9 / frame 一次性三路压缩-解压逐字节往返 + 钉值断言。
   钉值为 2026-10-03 双工具链实证(LTS/STS 同值):c=517 hc=517 fc=532。 */

import lz4.*

main() {
    let n: Int32 = 65536
    let src = Array<UInt8>(Int64(n), { i => UInt8((i * 31 + 7) % 251) })
    // block
    let bound = LZ4_compressBound(n)
    let dst = Array<UInt8>(Int64(bound), { _ => 0u8 })
    let c = LZ4_compress_default(src, n, dst, bound)
    if (c <= 0) { println("block compress FAILED"); return 1 }
    let back = Array<UInt8>(Int64(n), { _ => 0u8 })
    let d = LZ4_decompress_safe(dst, c, back, n)
    if (d != n) { println("block decompress FAILED"); return 1 }
    for (i in 0..Int64(n)) { if (src[i] != back[i]) { println("block roundtrip MISMATCH"); return 1 } }
    if (c != 517) { println("block pin FAILED c=${c}"); return 1 }
    // HC
    let chc = LZ4_compress_HC(src, n, dst, bound, 9)
    if (chc <= 0) { println("HC compress FAILED"); return 1 }
    let d2 = LZ4_decompress_safe(dst, chc, back, n)
    if (d2 != n) { println("HC decompress FAILED"); return 1 }
    if (chc != 517) { println("HC pin FAILED hc=${chc}"); return 1 }
    // frame one-shot
    let fn: Int64 = 65536
    let fbound = LZ4F_compressFrameBound(fn, None<LZ4F_preferences_t>)
    let fdst = Array<UInt8>(fbound, { _ => 0u8 })
    let fc = LZ4F_compressFrame(fdst, 0, fbound, src, fn, None<LZ4F_preferences_t>)
    if (LZ4F_isError(fc)) { println("frame compress FAILED: ${LZ4F_getErrorName(fc)}"); return 1 }
    let fback = Array<UInt8>(fn, { _ => 0u8 })
    let dctx = LZ4F_createDecompressionContext(100)
    let (ret, _, written) = LZ4F_decompress(dctx, fback, 0, fn, fdst, 0, fc, None<LZ4F_decompressOptions_t>)
    if (ret != 0 || written != fn) { println("frame decompress FAILED ret=${ret} written=${written}"); return 1 }
    for (i in 0..fn) { if (src[i] != fback[i]) { println("frame roundtrip MISMATCH"); return 1 } }
    if (fc != 532) { println("frame pin FAILED fc=${fc}"); return 1 }
    println("DOWNSTREAM_SMOKE_OK c=${c} hc=${chc} fc=${fc}")
    return 0
}
```

注意:该文件位于 scripts/,不在 src/ 编译范围(cjpm.toml `exclude` 含 `scripts/**`),不参与本仓库构建。

- [ ] **Step 3: 写入 scripts/verify_downstream.sh**(逐字使用,`chmod +x`)

```bash
#!/usr/bin/env bash
# Usage: scripts/verify_downstream.sh [lt|st|both]  (default: both)
# M8 验收(设计 §10):双制品可被下游 cjpm 依赖引用成功。
# 机制:临时下游 executable 工程,path 依赖引用本仓库,跑 scripts/downstream_smoke.cj
# 冒烟(块/HC/frame 三路往返 + 钉值);每工具链各建各跑各清理。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-both}"
EXPECT="DOWNSTREAM_SMOKE_OK c=517 hc=517 fc=532"

run_one() {
    local tag="$1" setup="$2" tmp out
    tmp="$(mktemp -d /tmp/lz4_ds_smoke.XXXXXX)"
    mkdir -p "$tmp/src"
    cat > "$tmp/cjpm.toml" <<EOF
[package]
  cjc-version = "1.0.5"
  name = "lz4_ds_smoke"
  description = "lz4cj downstream dependency smoke (generated)"
  version = "0.1.0"
  output-type = "executable"

[dependencies]
  lz4 = { path = "$ROOT" }
EOF
    cp "$ROOT/scripts/downstream_smoke.cj" "$tmp/src/main.cj"
    echo "=== [$tag] downstream dependency smoke ==="
    if ! out="$(bash -c "source '$setup' && cd '$tmp' && cjpm run" 2>&1)"; then
        printf '%s\n' "$out"
        echo "[$tag] FAILED: cjpm run error"
        rm -rf "$tmp"
        exit 1
    fi
    printf '%s\n' "$out" | tail -3
    if ! printf '%s\n' "$out" | grep -qF "$EXPECT"; then
        echo "[$tag] FAILED: expected \"$EXPECT\""
        rm -rf "$tmp"
        exit 1
    fi
    echo "[$tag] PASS"
    rm -rf "$tmp"
}

case "$MODE" in
    lt)   run_one lt "$HOME/sdk/cangjie-1.0.5/envsetup.sh" ;;
    st)   run_one st "$HOME/sdk/cangjie-1.2.0/envsetup.sh" ;;
    both) run_one lt "$HOME/sdk/cangjie-1.0.5/envsetup.sh"
          run_one st "$HOME/sdk/cangjie-1.2.0/envsetup.sh" ;;
    *)    echo "usage: $0 [lt|st|both]"; exit 1 ;;
esac
```

- [ ] **Step 4: 验收脚本双跑**

Run: `scripts/verify_downstream.sh both`
Expected: `[lt] PASS` 与 `[st] PASS`(各打印 DOWNSTREAM_SMOKE_OK 行)。遇 cjpm `DataModelException` → `rm -rf target` 重试(全局约束)。

- [ ] **Step 5: 零警告 + 全量回归**

Run: `rm -rf target && source ~/sdk/cangjie-1.0.5/envsetup.sh && cjpm build 2>&1 | grep -c warning;` 同式 STS 一遍 → 两侧均 0;然后 `scripts/build_and_test.sh both` → 两侧 156/156 通过。

- [ ] **Step 6: Commit**

```bash
git add cjpm.toml scripts/downstream_smoke.cj scripts/verify_downstream.sh
git commit -m "M8: release engineering - version 0.9.0, warning-clean build, downstream verification"
```

---

### Task 2: 文档定稿 —— README 对照表/使用示例/性能裁定 + CHANGELOG 0.9.0 + 收尾

**Files:**
- Modify: `README.md`(使用示例节、API 对照表补全、进度节、性能节)
- Modify: `CHANGELOG.md`(顶部新增 0.9.0 条目)
- Modify: `docs/design.md`(§10 M8 行勾选)
- Modify: `docs/progress.md`(M8 行、台账勾销、剩余/下一步清空)

**Interfaces:**
- Consumes: Task 1 的 `-Woff` 配置、verify_downstream.sh、smoke 钉值(c=517/hc=517/fc=532);M7 性能基线表(CHANGELOG 0.8.0);progress.md L29 的 74 函数清单(README 函数分组表的数据源);README 既有 frame 侧差异表(保留)
- Produces: Task 3 分支/tag 的文档依据(CHANGELOG 0.9.0 条目中分支/tag 命名)

- [ ] **Step 1: README 使用示例节**(插在"## 构建"节之后,新节 `## 使用(下游依赖)`)

内容要点(中文,与 README 现行风格一致):
1. 本地 path 依赖示例 cjpm.toml 片段(`[dependencies]` 下 `lz4 = { path = "<lz4cj 路径>" }`);说明仓颉侧导入形态:库为单包 `lz4`,源文件 `import lz4.*`,下游自身需 `package <下游包名>` 声明;
2. 最小示例代码(约 12 行,取 scripts/downstream_smoke.cj 的 block 段:`LZ4_compressBound` → `LZ4_compress_default` → `LZ4_decompress_safe` 往返断言);
3. 验收脚本说明:`scripts/verify_downstream.sh [lt|st|both]`(M8 验收:块/HC/frame 三路往返 + 钉值);
4. 注记:中心仓发布暂未接入,后续可经 `cangjie-repo.toml` 补充。

- [ ] **Step 2: README API 对照表补全**

将现有 `## API 对照摘要(frame 压缩侧 + 解压侧)` 改为 `## API 对照摘要`,frame 表保留为第三张表,前面新增两张:

**表 1(block 压缩/解压/流式 + xxhash,上游 lz4.h/xxhash.h)差异行**:
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

**表 2(HC,上游 lz4hc.h)差异行**:
| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| `LZ4_compress_HC_extStateHC(void* stateHC, ...)` | 用户提供裸缓冲当状态 | 参数类型为 `LZ4_streamHC_t` 状态类(§4.4) |
| `LZ4_compress_HC_destSize` 的 `srcSizePtr` | in/out 指针 | 元组返回 `(ret, srcConsumed)`;`LZ4_compress_HC_continue_destSize` 同式 |
| 级别常量 | 宏 `LZ4HC_CLEVEL_*` | Int32 常量族(成员名逐字) |
| 弃用块(lz4hc.c L2196-2255) | `LZ4_DEPRECATED` | 不移植(§4.6) |

**函数清单概览表**(数据源 progress.md L29,按层给分组计数):版本族 2、compressBound 族、压缩 6、解压 4、流式解码 5、流式压缩 10、stream 状态原语 2、HC 17 + 常量族、frame 压缩 21、frame 解压 7、常量族(错误码 24、五枚举 Int32 族、dstage_* 等)—— 总计 **74 函数 + 常量族**,注明"逐函数清单见 docs/progress.md"。

- [ ] **Step 3: README 性能节 + 进度节收尾**

1. `## 性能基线(M7)` 节末追加一段:**M8 §2.2 裁定(2026-10-03)**:差距结构性(数组安全层/GC/调用开销 vs C 裸内存 + SIMD memcpy),单点微调预期收益远小于差距且危及"压缩输出与 C 逐字节一致"保真资产,裁定不做性能优化,库源码冻结;非回归监控沿用 `benchAllTest`(LZ4_SKIP_BENCH=1 可跳)。
2. `## 当前进度`:修正 M7 行为 `**M7(完成)**`;新增 `**M8(完成)**` 行:cjpm.toml 0.9.0 定稿 + 零警告构建(`-Woff unused -Woff parser`)、下游依赖验收脚本(双工具链 PASS)、性能 §2.2 书面裁定结案、README API 对照表/使用示例补全、发布分支 `lz4_lt_1.0.5` / `lz4_st_1.2.0` 与 tag `v0.9.0-lt` / `v0.9.0-st`。

- [ ] **Step 4: CHANGELOG 0.9.0 条目**(顶部插入,要点)

```markdown
## 0.9.0 (M8)

- 发布里程碑:cjpm.toml `version` 1.0.0→0.9.0(与 CHANGELOG 序列对齐)、`repository` 订正为 atomgit.com/xusiwei1236/lz4cj;`compile-option` 追加 `-Woff unused -Woff parser`(重复标志形式;逗号合并 cjc 拒绝,实证)—— 23 条 lib 构建警告清零,归类裁定:10 unused function(XXH64 全族 6 + XXH32_createState/freeState + RDG_genBuffer + LZ4_writeLE64 = 设计明定的备用/internal/测试支撑库成员)、5 unused variable(free 族 API 在 GC 语义下参数不用,逐字签名所迫)、7 parser(多行表达式行首二元运算符排版风格);库源码零改动
- 下游依赖验收(设计 §10 M8 验收标准):`scripts/verify_downstream.sh` + `scripts/downstream_smoke.cj` —— 临时下游 executable 经本地 path 依赖(`lz4 = { path = ... }`;单包 `import lz4.*`)构建运行,block default / HC lv9 / frame 一次性三路压缩-解压逐字节往返 + 钉值(c=517 / hc=517 / fc=532,LTS/STS 同值实证);lt|st|both 三模式,双工具链 PASS
- 性能整体评估 §2.2 结案(书面裁定):M7 基线(仓颉/C 0.02-0.6x,字面密集 safe 解压 0.024x)判定差距结构性 —— Array 安全层/GC/调用开销 vs C 裸内存 + memcpy→SIMD;单点微调预期收益 << 差距且危及字节保真资产;裁定 M8 不做性能优化,库源码与 M6 收官逐字节一致延续;后续如重议,以 `benchAllTest` 与 `scripts/bench_probe.c` 基线表为起点
- 发布分支与 tag:main → `lz4_lt_1.0.5`(cjc-version "1.0.5")/ `lz4_st_1.2.0`(cjc-version "1.2.0",设计 §7.4 预期微调);tag `v0.9.0-lt` / `v0.9.0-st`;未推送远端。中心仓(`cangjie-repo.toml`)裁定暂不接入(设计明定非 MVP;需求出现时以本地 path 依赖机制为过渡)
- 文档:README 新增使用示例(下游依赖)节、API 对照表补全(block/流式/xxhash + HC 两张差异表 + 74 函数分组概览)、性能节 M8 裁定、进度节 M7/M8 收尾;design.md §10 M8 行勾选;progress.md M8 行 + 台账勾销(unused 警告项裁定闭合)+ 剩余/下一步清空
- 验收:`scripts/build_and_test.sh both` 156/156 双绿;lib 构建零警告(双工具链);`scripts/verify_downstream.sh both` PASS
```

- [ ] **Step 5: design.md §10 M8 行勾选**

`| M8 发布 | README/CHANGELOG、发布分支、(可选)中心仓 | 双制品可被下游 cjpm 依赖引用成功 |` 验收标准单元格追加 `✅ 达成(verify_downstream 双 PASS;中心仓按裁定暂不接入,留待需求)`。其余节不动(§7.4 分支模型已被 Task 3 兑现,无需改写)。

- [ ] **Step 6: progress.md 收尾**

1. "已完成"表追加 M8 行(内容同 CHANGELOG 0.9.0 要点,证据列:双绿 156/156、零警告、verify_downstream both PASS、分支/tag 落地);
2. "剩余(依赖顺序)"节:替换为"(无 —— 路线图 M0-M8 全部完成)";
3. 台账 L49 unused 警告项勾销:`[x] ~~RDG_genBuffer 等 unused 警告~~(M8 裁定:-Woff unused/parser 抑制 + 归类登记,库源码零改动;见 CHANGELOG 0.9.0)`;
4. "待决事项"追加一行:中心仓接入(M8 裁定暂不;需求出现时补 cangjie-repo.toml + 发布流程);
5. "下一步"节替换为:`路线图全部完成(M0-M8)。可选后续:中心仓发布、lz4file API 增补(§4.6 裁剪项)、上游同步(dev > 0774d055 时)。`

- [ ] **Step 7: 回归 + Commit**

Run: `scripts/build_and_test.sh both` → 156/156(纯文档改动,守恒检查)。
Commit: `M8: documentation - README API tables and usage, CHANGELOG 0.9.0, milestone closeout`

---

### Task 3: 发布分支 + 双制品验收 + tag

**Files:**
- Create: git 分支 `lz4_lt_1.0.5`、`lz4_st_1.2.0`;tag `v0.9.0-lt`、`v0.9.0-st`
- Modify: `cjpm.toml`(仅 lz4_st_1.2.0 分支上:cjc-version "1.0.5"→"1.2.0")

**Interfaces:**
- Consumes: Task 1 `scripts/verify_downstream.sh`;Task 2 后的 main HEAD(文档收尾完毕)
- Produces: 双发布分支 + 双 tag(里程碑最终交付物;不推送远端)

- [ ] **Step 1: 前置确认**

Run: `git status`(main 干净)、`git log --oneline -3`(Task 1/2 提交在列)。main 的 HEAD 即发布基线。

- [ ] **Step 2: lt 分支 + 验收 + tag**

```bash
git branch lz4_lt_1.0.5 main
git checkout lz4_lt_1.0.5
scripts/build_and_test.sh lt          # 156/156
scripts/verify_downstream.sh lt       # [lt] PASS
ls target/release/lz4/                # 断言 liblz4.a 与 lz4.cjo 存在(双制品)
git tag -a v0.9.0-lt -m "lz4cj 0.9.0 LTS-1.0.5 release (upstream lz4 0774d055)"
```

- [ ] **Step 3: st 分支 + cjc-version 微调 + 验收 + tag**

```bash
git checkout -b lz4_st_1.2.0 main
# cjpm.toml: cjc-version "1.0.5" -> "1.2.0"(设计 §7.4 版本适配微调;仅此一处)
scripts/build_and_test.sh st          # 156/156
scripts/verify_downstream.sh st       # [st] PASS
ls target/release/lz4/                # 断言双制品存在
git add cjpm.toml && git commit -m "M8: st release branch - cjc-version 1.2.0"
git tag -a v0.9.0-st -m "lz4cj 0.9.0 STS-1.2.0 release (upstream lz4 0774d055)"
```

- [ ] **Step 4: 回 main + 终态核对(不 push)**

```bash
git checkout main
git branch -a && git tag -l           # 断言:两分支两 tag 存在
git log --oneline lz4_st_1.2.0 -1     # st 分支含 cjc-version 提交;lt 分支 == main HEAD
```

**禁止**:`git push` / 任何远端操作(需用户明示)。
