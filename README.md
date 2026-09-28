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

共 21 项测试:版本与 compressBound、流状态、XXH32/XXH64(官方向量 + 流式)、datagen(C 交叉验证)、一站式块压缩 golden(256 行清单 + 125 行对抗性 destSize 用例,字节级精确比对)。

## 当前进度

- **M0(完成)**:cjpm 静态库工程、双工具链脚本、LICENSE、README。
- **M1(完成)**:XXH32 / XXH64(one-shot + 流式)、datagen 及 C 交叉验证。
- **M2(完成)**:一站式块压缩(`LZ4_compress_default` / `fast` / `fast_extState`(+fastReset)/ `destSize`)+ `compressBound` 与流状态;256 行 golden + 125 行对抗性 destSize 用例,C 交叉字节级验证。
- **M3(下一步)**:流式压缩(loadDict / continue / saveDict / usingExtDict)与解压。

压缩 API 已在 M2 对外提供;解压与流式接口在后续里程碑提供,路线图见 [docs/design.md](docs/design.md)。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
