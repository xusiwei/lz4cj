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

共 44 项测试:版本与 compressBound、流状态、XXH32/XXH64(官方向量 + 流式)、datagen(C 交叉验证)、一站式块压缩 golden(256 行清单 + 125 行对抗性 destSize 用例,字节级精确比对)、块解压全家族 golden(清单 v2 共 300 行:解压 artifact 逐字节 + partial 探针 + dict/stream/ring/setdict 滚动解码)、safe/fast 差分(随机 + 合成流 + 损坏输入)、extDict 跨界拷贝对抗用例、模糊测试(2000 解压种子 + 200 流式种子;`LZ4_SKIP_PERF=1` 可跳过性能冒烟)。

## 当前进度

- **M0(完成)**:cjpm 静态库工程、双工具链脚本、LICENSE、README。
- **M1(完成)**:XXH32 / XXH64(one-shot + 流式)、datagen 及 C 交叉验证。
- **M2(完成)**:一站式块压缩(`LZ4_compress_default` / `fast` / `fast_extState`(+fastReset)/ `destSize`)+ `compressBound` 与流状态;256 行 golden + 125 行对抗性 destSize 用例,C 交叉字节级验证。
- **M3a(完成)**:块解压全家族(`LZ4_decompress_safe` / `safe_partial` / `safe_usingDict` / `safe_partial_usingDict` / `safe_continue` + 流式解码状态与 ring 尺寸契约);300 行 golden、safe/fast 双循环差分、2000+200 种子模糊测试;库源码行覆盖 98.4%。
- **M3b(下一步)**:流式压缩(loadDict / continue / saveDict / usingExtDict)。

压缩与块解压 API 均已对外提供;流式压缩接口在后续里程碑提供,路线图见 [docs/design.md](docs/design.md)。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
