# lz4cj

纯仓颉(Cangjie)实现的 LZ4 无损压缩库移植(无 FFI),接口对齐上游 [lz4](https://github.com/lz4/lz4) v1.10.0。设计文档见 [docs/design.md](docs/design.md)。

## 构建

需要 Cangjie LTS-1.0.5 或 STS-1.2.0 SDK(安装至 `~/sdk`,或按 `scripts/setup_env.sh` 内注释手动放置 tarball):

```bash
scripts/setup_env.sh           # 一次性:安装并自检两套 SDK
scripts/build_and_test.sh both # 双工具链构建 + 全量测试
```

`build_and_test.sh` 也接受 `lt`(LTS-1.0.5)/ `st`(STS-1.2.0)单工具链参数,缺省 `both`。

## 测试

共 117 项测试:版本与 compressBound、流状态、XXH32/XXH64(官方向量 + 流式)、datagen(C 交叉验证)、一站式块压缩 golden(256 行清单 + 125 行对抗性 destSize 用例,字节级精确比对)、块解压全家族 golden(清单 v2 共 300 行:解压 artifact 逐字节 + partial 探针 + dict/stream/ring/setdict 滚动解码)、safe/fast 差分(随机 + 合成流 + 损坏输入)、extDict 跨界拷贝对抗用例、流式压缩 golden 46 行(cont/savedict/dictfast/dictslow/attach/extdict/destext)、HC 高压缩 golden 70 行(levels 1-12 全采样三策略 + destSize + 流式 continue/saveDict/loadDict/attach)、Frame 压缩 golden 49 行(10 头编码 + 27 流式帧全参数交叉 + 8 一次性 + 2 CDict 一次性 + 2 Begin_usingDict 帧,清单共 475 数据行,含 usingDict+blockIndependent 字典丢弃怪癖钉值)、模糊测试(2000 解压种子 + 200 流式种子 + 300 HC 压缩种子:分层 mid/hashchain/opt 各 100,one-shot 往返 + 确定性 + 不足容量 + 流式迁移 + 滚动解码闭环;+ 120 frame 种子:一次性/流式链双场景 ×2 确定性重放、未压缩块插入与中途 flush、逐块解码闭环;`LZ4_SKIP_PERF=1` 可跳过性能冒烟)+ 闭环滚动往返 + 边界契约。

## golden 语料再生工作流

golden 语料(`corpus/`,清单 + artifacts,~5.4MB)**不入 git**(仓库策略,`git check-ignore corpus` 可证);克隆后本地再生:

```bash
scripts/gen_golden.sh   # 需要 cc 与 ~/lz4 检出 0774d055(编译上游 C 源生成)
```

脚本自带门检(总行 497 / 注释 22 / 各 mode 行数 / corpus 体积)。测试套件内嵌常量摘要断言(尺寸 + XXH32/64)**自足**——语料缺失时仍完整验证;artifact 存在时才做逐字节比对(全有或全无)。上游工作副本需保持检出基线 commit:

```bash
git -C ~/lz4 checkout 0774d055
```

## 当前进度

- **M0(完成)**:cjpm 静态库工程、双工具链脚本、LICENSE、README。
- **M1(完成)**:XXH32 / XXH64(one-shot + 流式)、datagen 及 C 交叉验证。
- **M2(完成)**:一站式块压缩(`LZ4_compress_default` / `fast` / `fast_extState`(+fastReset)/ `destSize`)+ `compressBound` 与流状态;256 行 golden + 125 行对抗性 destSize 用例,C 交叉字节级验证。
- **M3a(完成)**:块解压全家族(`LZ4_decompress_safe` / `safe_partial` / `safe_usingDict` / `safe_partial_usingDict` / `safe_continue` + 流式解码状态与 ring 尺寸契约);300 行 golden、safe/fast 双循环差分、2000+200 种子模糊测试;库源码行覆盖 98.4%。
- **M3b(完成)**:流式压缩全家(`createStream` / `freeStream` / `resetStream(+fast)` / `loadDict(+Slow)` / `attach_dictionary` / `compress_fast_continue` / `saveDict` / `destSize_extState`),真实 `prepareTable` 表保留语义,四字典模式压缩核心;golden 扩至 356 行(46 行新增逐字节)、闭环滚动往返、边界契约 C 探针钉值;库源码行覆盖 96.8%。**block 层(lz4.c 非弃用 API 全量)就此闭环**。
- **M4(完成)**:HC 高压缩全量(lz4hc.c 非弃用 17 函数):三策略核心 LZ4MID(lv1-2)/ hashChain(lv3-9)/ optimal(lv10-12)+ `favorDecompressionSpeed`,one-shot / extState(+fastReset)/ destSize / 流式 `loadDictHC` / `attach` / `continue(+destSize)` / `saveDictHC`;golden 扩至 426 数据行(70 行新增,levels 1-12 全采样逐字节)、C 探针 7 案例钉值、300 种子 HC 模糊测试(分层 100/100/100);库源码行覆盖 96.6%。**HC 层(lz4hc.c 非弃用 API 全量)就此闭环**。
- **M5(完成)**:Frame 压缩全量(lz4frame.c 压缩侧 21 函数):版本/错误/界限族、cctx 生命周期、`compressBegin`(+`_usingDict`/+`_usingCDict`)、`compressUpdate` / `uncompressedUpdate` / `flush` / `compressEnd`、一次性 `compressFrame`(+`_usingCDict`)、`LZ4F_CDict` 预消化字典;golden 扩至 475 数据行(49 行新增逐字节,含 fdt 字典丢弃怪癖 C 探针钉值)、120 种子 frame 模糊测试(双场景 + 确定性重放 + 逐块解码闭环);库源码行覆盖 96.4%。**frame 压缩侧就此闭环,frame 接口(压缩方向)对外提供**。
- **M6(下一步)**:Frame 解压(dctx 状态机、getFrameInfo、校验和、skippable)。

**移植基线**:上游 dev commit `0774d055`(2026-06-01,v1.10.0 发布线之上的官方修复线)。压缩输出与 v1.10.0 发布版逐字节一致(300 行 golden 双 ref 重验零差异);解压包含其后官方 OOB/边界修复,损坏输入行为更严格;详见 [docs/design.md](docs/design.md) 与 [docs/progress.md](docs/progress.md)。

一站式块压缩、块解压、流式压缩(字典/续压/attach)、HC 高压缩(级别 1-12、最优解析、HC 流式字典)与 frame 压缩(流式 + 一次性 + CDict)API 均已对外提供;frame 解压在 M6 提供,路线图见 [docs/design.md](docs/design.md)。

## API 对照摘要(frame 压缩侧)

与上游 `lz4frame.h`(0774d055)逐函数对应,承载差异如下:

| 差异点 | 上游 C | 仓颉 |
|---|---|---|
| 五枚举(blockSizeID/blockMode/contentChecksum/blockChecksum/frameType)与错误码 | C enum | **Int32 / Int64 常量族**(仓颉无 C 值枚举;成员名逐字,如 `LZ4F_max64KB`、`LZ4F_ERROR_dstMaxSize_tooSmall`) |
| 缓冲 + 指针入参 | `dstBuffer` / `srcBuffer` 裸指针 | **位置对** `(dstBuf, dstIdx)` / `(srcBuf, srcIdx)`;一次性族 `compressFrame` 源取整缓冲(无位置对,对齐上游单指针形态) |
| `LZ4F_createCompressionContext(&cctx, version)` 出参 | 双参 + 错误码 | **返回 `LZ4F_cctx`**(`version` 入参保留,仅存不校验,同上游 advanced 语义) |
| 可空指针(`preferencesPtr` 等) | `NULL` | `Option<T>`(`None` 代入 MEM_INIT 零值语义,非 INIT 默认) |
| `reserved[3]` 保留字段 | 结构体内存占位 | **省略**(默认值结构体 + 显式 init 等价覆盖 INIT 宏) |
| `LZ4F_compressBegin_usingDict` 字典语义 | 头文件注记"仅首块使用字典" | **实测怪癖如实钉住**:blockIndependent 帧字典被逐块 reset 整体丢弃(帧 == 无字典帧,C 探针验证);linked 帧字典全帧有效;需逐块字典请用 `compressFrame_usingCDict`/`Begin_usingCDict` |
| `LZ4F_createCDict` NULL/分配失败路径 | 返回 NULL | GC 下不可达,注释登记 |

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
