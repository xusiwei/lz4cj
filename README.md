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

共 57 项测试:版本与 compressBound、流状态、XXH32/XXH64(官方向量 + 流式)、datagen(C 交叉验证)、一站式块压缩 golden(256 行清单 + 125 行对抗性 destSize 用例,字节级精确比对)、块解压全家族 golden(清单 v2 共 300 行:解压 artifact 逐字节 + partial 探针 + dict/stream/ring/setdict 滚动解码)、safe/fast 差分(随机 + 合成流 + 损坏输入)、extDict 跨界拷贝对抗用例、模糊测试(2000 解压种子 + 200 流式种子;`LZ4_SKIP_PERF=1` 可跳过性能冒烟)、流式压缩 golden 46 行(cont/savedict/dictfast/dictslow/attach/extdict/destext,清单扩至 356 行)+ 闭环滚动往返 + 边界契约。

## 当前进度

- **M0(完成)**:cjpm 静态库工程、双工具链脚本、LICENSE、README。
- **M1(完成)**:XXH32 / XXH64(one-shot + 流式)、datagen 及 C 交叉验证。
- **M2(完成)**:一站式块压缩(`LZ4_compress_default` / `fast` / `fast_extState`(+fastReset)/ `destSize`)+ `compressBound` 与流状态;256 行 golden + 125 行对抗性 destSize 用例,C 交叉字节级验证。
- **M3a(完成)**:块解压全家族(`LZ4_decompress_safe` / `safe_partial` / `safe_usingDict` / `safe_partial_usingDict` / `safe_continue` + 流式解码状态与 ring 尺寸契约);300 行 golden、safe/fast 双循环差分、2000+200 种子模糊测试;库源码行覆盖 98.4%。
- **M3b(完成)**:流式压缩全家(`createStream` / `freeStream` / `resetStream(+fast)` / `loadDict(+Slow)` / `attach_dictionary` / `compress_fast_continue` / `saveDict` / `destSize_extState`),真实 `prepareTable` 表保留语义,四字典模式压缩核心;golden 扩至 356 行(46 行新增逐字节)、闭环滚动往返、边界契约 C 探针钉值;库源码行覆盖 96.8%。**block 层(lz4.c 非弃用 API 全量)就此闭环**。
- **M4(下一步)**:HC 高压缩(lz4hc.c,级别 1-12 + 最优解析 + 流式)。

**移植基线**:上游 dev commit `0774d055`(2026-06-01,v1.10.0 发布线之上的官方修复线)。压缩输出与 v1.10.0 发布版逐字节一致(300 行 golden 双 ref 重验零差异);解压包含其后官方 OOB/边界修复,损坏输入行为更严格;详见 [docs/design.md](docs/design.md) 与 [docs/progress.md](docs/progress.md)。

一站式块压缩、块解压与流式压缩(字典/续压/attach)API 均已对外提供;HC 与 frame 接口在后续里程碑提供,路线图见 [docs/design.md](docs/design.md)。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
