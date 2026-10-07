# lz4cj

纯仓颉(Cangjie)实现的 LZ4 无损压缩库移植(无 FFI),接口对齐上游 [lz4](https://github.com/lz4/lz4) v1.10.0。设计文档见 [docs/design.md](docs/design.md)。演示视频见 [Bilibili 视频合集](https://space.bilibili.com/121420235/lists/9271654)。

## 构建

需要 Cangjie LTS-1.0.5 或 STS-1.2.0 SDK。脚本按 `scripts/cjenv.sh` 的规则定位 SDK(与平台无关):优先环境变量 `LZ4CJ_SDK_105` / `LZ4CJ_SDK_120`(指向含 `envsetup.sh` 或 `cangjie/envsetup.sh` 的 SDK 根目录,Windows 反斜杠路径亦可),回退 `~/sdk/cangjie-<ver>`(可用 `scripts/setup_env.sh` 在 Linux 上一键安装):

```bash
scripts/setup_env.sh           # 一次性:安装并自检两套 SDK
scripts/build_and_test.sh both # 双工具链构建 + 全量测试 + fuzz 基准
```

`build_and_test.sh` 也接受 `lt`(LTS-1.0.5)/ `st`(STS-1.2.0)单工具链参数,缺省 `both`。

测试分两段执行:`cjpm test`(单元/钉值/golden 用例,174 个)与 `cjpm bench`(fuzz 种子扫描 5 个,`@Test @Bench` 顶层组合标注,`fuzz_test.cj` —— 长跑型种子扫描不占测试门槛,由 bench 框架多次执行并产出计时表)。单独运行:`cjpm test` / `cjpm bench`,bench 可加 `--filter fuzzDecompressBench` 等过滤单个基准。

## 端到端交叉验证(e2e)

[e2e/](e2e/README.md) 内含两个契约一致的命令行文件压缩/解压工具(`-c/-d -i/-o`):`cli-c`(上游 lz4 C 库,CMake 跨平台)与 `cli-cj`(本仓颉实现,独立 cjpm executable 模块 path 依赖仓库根)。`e2e/run_e2e.sh` 生成用例并跑全矩阵:C/仓颉压缩输出**逐字节一致**、四方向压缩-解压往返、损坏/截断/尾随字节错误注入双工具拒绝,双工具链各跑一遍。

## 使用(下游依赖)

下游工程以本地 path 依赖引入,`cjpm.toml`:

```toml
[dependencies]
  lz4 = { path = "<lz4cj 路径>" }
```

库为单包 `lz4`(模块 `lz4cj` 下唯一包),下游源文件 `import lz4.*`,且下游自身需有 `package <下游包名>` 声明。最小往返示例(block 段,同 `scripts/downstream_smoke.cj`):

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

验收脚本 `scripts/verify_downstream.sh [lt|st|both]`(缺省 `both`):临时下游 executable 经本地 path 依赖构建运行,做块 / HC / frame / lz4file 四路压缩-解压逐字节往返 + 钉值断言(M8 验收 + M9 扩容 lz4file 路径,双工具链 PASS)。注:中心仓发布暂未接入,后续可经 `cangjie-repo.toml` 补充(设计 §9 非 MVP)。

lz4file 文件级便捷 API(M9,上游 `lz4file.h` 全量)以 `std.fs.File` 为载体,**调用方持有文件生命周期**(`readClose`/`writeClose` 不关文件,与 C 一致),`size` 为具名参数,open 族返回 `(errorCode, Option<句柄>)` 元组:

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

## 测试

共 179 项测试(cjpm test 174 + bench 5;M7:三侧定向覆盖 + >256KB 运行时矩阵 large_probe 18 钉值行 + bench 基线,残行不可达裁定见 CHANGELOG 0.8.0;M9:+23 lz4file):版本与 compressBound、流状态、XXH32/XXH64(官方向量 + 流式)、datagen(C 交叉验证)、一站式块压缩 golden(256 行清单 + 125 行对抗性 destSize 用例,字节级精确比对)、块解压全家族 golden(清单 v2 共 300 行:解压 artifact 逐字节 + partial 探针 + dict/stream/ring/setdict 滚动解码)、safe/fast 差分(随机 + 合成流 + 损坏输入)、extDict 跨界拷贝对抗用例、流式压缩 golden 46 行(cont/savedict/dictfast/dictslow/attach/extdict/destext)、HC 高压缩 golden 70 行(levels 1-12 全采样三策略 + destSize + 流式 continue/saveDict/loadDict/attach)、Frame 压缩 golden 49 行(10 头编码 + 27 流式帧全参数交叉 + 8 一次性 + 2 CDict 一次性 + 2 Begin_usingDict 帧,含 usingDict+blockIndependent 字典丢弃怪癖钉值)、Frame 解压 golden 14 行 fdmp C 解压探针(getFrameInfo 三岔、分片续传 hint 三元组、skippable、拼接、dict 双钉、错误码族;清单共 489 数据行)+ 分片续传矩阵(27 行 × 7 变体:固定/LCG 切分 × 容量阶梯 + dstIdx 位置对)+ stableDst/skipChecksums(含上游"skip 不屏蔽压缩块校验"怪癖钉值)/skippable/拼接语义 + 前缀谓词分配同一性回归(字典前缀输出 / 内容等值换缓冲 / 异值对照,C 探针 scripts/frame_decode_probe.c 钉值)+ 覆盖率门禁定向用例(多缓冲 updateDict 分支、块校验和分片暂存、skippable 头分片怪癖等)、lz4file 23 项(readOpen 6:正常打开/短文件/空文件/坏魔数/坏头校验和/skippable 前缀;read 7:整读/分块/逐字节/4MB 块上限/空帧/零尺寸/截断部分读;write 7:默认与变体 prefs/None prefs/多次小写/非法 blockSizeID(上游实测意外成功,仓颉 -2 早退严于上游)/空输入/writeClose 粘滞错误;探针 parity 3:与上游 0774d055 写侧四变体文件字节级一致钉值)、模糊测试(3000 解压种子 + 320 流式种子 + 420 HC 压缩种子:分层 mid/hashchain/opt 各 140,one-shot 往返 + 确定性 + 不足容量 + 流式迁移 + 滚动解码闭环;+ 240 frame 压缩种子(压缩侧 LCG 奇偶锁已修):一次性/流式链双场景 ×2 确定性重放、未压缩块插入与中途 flush、逐块解码闭环;+ 300 frame 解压种子:随机切分 × 容量阶梯 {0, 小, maxBlockSize, n} + 2-4 帧拼接混 skippable + 损坏三型零异常,场景 A ×2 逐字节确定性重放;`LZ4_SKIP_PERF=1` 可跳过性能冒烟)+ 闭环滚动往返 + 边界契约。

## golden 语料再生工作流

golden 语料(`corpus/`,清单 + artifacts,~5.4MB)**不入 git**(仓库策略,`git check-ignore corpus` 可证);克隆后本地再生:

```bash
scripts/gen_golden.sh   # 编译上游 C 源生成;Linux/macOS 与 Windows(Git Bash + MinGW gcc)均可
```

脚本路径无关:上游 lz4 源码位置取 `LZ4CJ_UPSTREAM`(缺省 `~/lz4`),C 编译器取 `CC`(缺省 cc→gcc→clang 自动回退);Windows/MinGW 下自动加 `-D__USE_MINGW_ANSI_STDIO=1`(msvcrt printf 不支持 `%zu`)并在生成后清理 stdout 文本模式引入的 CR。上游源码获取与检出基线 commit(Golden 与上游逐字节一致性的锚点,不可换用其他版本):

```bash
git clone https://github.com/lz4/lz4 ~/lz4   # 网络受限时可用 GitHub 代理前缀
git -C ~/lz4 checkout 0774d055
```

脚本自带门检(总行 512 / 注释 23 / 各 mode 行数 / corpus 体积)。测试套件内嵌常量摘要断言(尺寸 + XXH32/64)**自足**——语料缺失时仍完整验证;artifact 存在时才做逐字节比对(全有或全无)。

## 性能基线(M7)

`scripts/bench_probe.c`(C,上游 0774d055)与 `src/bench_test.cj`(仓颉,`LZ4_SKIP_BENCH=1` 可跳过)同输入同口径 best-of-3 对照:仓颉/C 比值 0.02-0.6x(差距结构性:数组安全层/GC/调用开销 vs C 裸内存 + SIMD;详见 CHANGELOG 0.8.0 基线表);非回归门槛,用于数量级劣化监控。

**M8 §2.2 裁定(2026-10-03)**:差距结构性(数组安全层/GC/调用开销 vs C 裸内存 + SIMD memcpy),单点微调预期收益远小于差距且危及"压缩输出与 C 逐字节一致"保真资产,裁定不做性能优化,库源码冻结;非回归监控沿用 `benchAllTest`(`LZ4_SKIP_BENCH=1` 可跳)。

## 当前进度

- **M0(完成)**:cjpm 静态库工程、双工具链脚本、LICENSE、README。
- **M1(完成)**:XXH32 / XXH64(one-shot + 流式)、datagen 及 C 交叉验证。
- **M2(完成)**:一站式块压缩(`LZ4_compress_default` / `fast` / `fast_extState`(+fastReset)/ `destSize`)+ `compressBound` 与流状态;256 行 golden + 125 行对抗性 destSize 用例,C 交叉字节级验证。
- **M3a(完成)**:块解压全家族(`LZ4_decompress_safe` / `safe_partial` / `safe_usingDict` / `safe_partial_usingDict` / `safe_continue` + 流式解码状态与 ring 尺寸契约);300 行 golden、safe/fast 双循环差分、2000+200 种子模糊测试;库源码行覆盖 98.4%。
- **M3b(完成)**:流式压缩全家(`createStream` / `freeStream` / `resetStream(+fast)` / `loadDict(+Slow)` / `attach_dictionary` / `compress_fast_continue` / `saveDict` / `destSize_extState`),真实 `prepareTable` 表保留语义,四字典模式压缩核心;golden 扩至 356 行(46 行新增逐字节)、闭环滚动往返、边界契约 C 探针钉值;库源码行覆盖 96.8%。**block 层(lz4.c 非弃用 API 全量)就此闭环**。
- **M4(完成)**:HC 高压缩全量(lz4hc.c 非弃用 17 函数):三策略核心 LZ4MID(lv1-2)/ hashChain(lv3-9)/ optimal(lv10-12)+ `favorDecompressionSpeed`,one-shot / extState(+fastReset)/ destSize / 流式 `loadDictHC` / `attach` / `continue(+destSize)` / `saveDictHC`;golden 扩至 426 数据行(70 行新增,levels 1-12 全采样逐字节)、C 探针 7 案例钉值、300 种子 HC 模糊测试(分层 100/100/100);库源码行覆盖 96.6%。**HC 层(lz4hc.c 非弃用 API 全量)就此闭环**。
- **M5(完成)**:Frame 压缩全量(lz4frame.c 压缩侧 21 函数):版本/错误/界限族、cctx 生命周期、`compressBegin`(+`_usingDict`/+`_usingCDict`)、`compressUpdate` / `uncompressedUpdate` / `flush` / `compressEnd`、一次性 `compressFrame`(+`_usingCDict`)、`LZ4F_CDict` 预消化字典;golden 扩至 475 数据行(49 行新增逐字节,含 fdt 字典丢弃怪癖 C 探针钉值)、120 种子 frame 模糊测试(双场景 + 确定性重放 + 逐块解码闭环);库源码行覆盖 96.4%。**frame 压缩侧就此闭环,frame 接口(压缩方向)对外提供**。
- **M6(完成)**:Frame 解压全量(lz4frame.c 解压侧 7 函数):dctx 生命周期 `create/free/resetDecompressionContext`、`headerSize`、`getFrameInfo`、`decompress` / `decompress_usingDict`;14-stage 分片续传状态机(随机切分 × 容量阶梯 + 位置对全矩阵)、块/内容校验和、skippable、帧拼接;fdmp C 解压探针 golden 14 行(清单扩至 489 数据行)、150 种子 frame 解压模糊测试(随机切分/拼接/损坏三型,场景 A ×2 确定性重放);覆盖率门禁定向用例 5 个;终审修复:前缀谓词改分配同一性(双哨兵探针,内容窗口谓词在字典前缀输出几何假阳性)+ 三回归与 C 探针;库源码行覆盖 96.5%。**frame 层(压缩 + 解压)双向闭环,lz4frame API 全量对外提供**。
- **M7(完成)**:收尾测试(golden 全矩阵扩容、三文件可达未覆盖行、fuzz 加压、bench 复评)。
- **M8(完成)**:cjpm.toml 0.9.0 定稿 + 零警告构建(`-Woff unused -Woff parser`)、下游依赖验收脚本(双工具链 PASS)、性能 §2.2 书面裁定结案、README API 对照表/使用示例补全、发布分支 `lz4_lt_1.0.5` / `lz4_st_1.2.0` 与 tag `v0.9.0-lt` / `v0.9.0-st`。
- **M9(完成)**:lz4file 文件级便捷 API 全量(读 `LZ4F_readOpen` / `read` / `readClose` + 写 `LZ4F_writeOpen` / `write` / `writeClose` + `LZ4_readFile_t` / `LZ4_writeFile_t` 句柄,原范围裁剪项回填):`std.fs.File` 映射、偏离登记 6 条(含无效 blockSizeID writeOpen 上游实测意外成功 —— size_t 回绕写无效帧头,仓颉 -2 早退严于上游)、`writeClose` 尾块字节数语义;上游探针钉值 + 写侧四变体字节级 parity(114579/5c8321a4 等);文档 0.10.0 定稿 + 下游冒烟扩容 lz4file 路径(lf=532)。

**移植基线**:上游 dev commit `0774d055`(2026-06-01,v1.10.0 发布线之上的官方修复线)。压缩输出与 v1.10.0 发布版逐字节一致(300 行 golden 双 ref 重验零差异);解压包含其后官方 OOB/边界修复,损坏输入行为更严格;详见 [docs/design.md](docs/design.md) 与 [docs/progress.md](docs/progress.md)。

一站式块压缩、块解压、流式压缩(字典/续压/attach)、HC 高压缩(级别 1-12、最优解析、HC 流式字典)、frame 压缩/解压(流式 + 一次性 + CDict + dctx 分片续传)与 lz4file 文件级读写(句柄 + `std.fs.File`)API 均已对外提供;路线图见 [docs/design.md](docs/design.md)。

## API 对照摘要

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

lz4file(上游 `lz4file.h`,0774d055;M9 增补,原范围裁剪项回填)承载差异如下:

| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| `FILE*` 文件入参 | C stdio `FILE*` | **`std.fs.File`**(调用方持有文件生命周期;`LZ4F_readClose`/`writeClose` 不关文件,与 C 一致) |
| `LZ4F_readOpen`/`LZ4F_writeOpen` 的 OUT 句柄出参 | 双参 + 错误码 | **元组 `(code, Option<句柄>)`**(design §4.3 规则 1;失败返 `None` 句柄,freeAndNull → GC) |
| `LZ4F_read`/`LZ4F_write` 的 `size` | 位置参数 | **具名必传参数 `size!: Int64`** |
| `ferror`/`fwrite` 计数检测 | 返回计数比对 + ferror | **`FSException` 捕获转 `-io_read`/`-io_write`**(`File.write` 返 Unit,短写-成功情形无表示,登记) |
| `parameter_null`/`allocation_failed` 路径 | NULL/分配失败早退 | 非空引用 + GC 模型下 **N/A**(登记) |
| 无效 blockSizeID 的 `LZ4F_writeOpen` | **实测意外成功**:`getBlockSize(2)=(size_t)-2` 回绕绕过 `==0` 守卫,compressBound 回绕得小容量,写出 BD=0x20 无效帧头(探针 `e badbs: 0`) | **`blockSize <= 0` 早退 `-LZ4F_ERROR_maxBlockSize_invalid`**,拒绝依赖 size_t 回绕的非法配置,严于上游(偏离登记) |
| `LZ4F_writeClose` 返回值 | compressEnd 尾块字节数(≥4,头文件未文档化,以代码为准) | 同 C(成功 ≥4;粘滞错误路径跳过 End 返回 OK) |

函数清单概览(按层分组计数,总计 **80 函数 + 常量族**;各组计数与总数均只计函数,常量族不计入;逐函数清单见 [docs/progress.md](docs/progress.md)):

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

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
