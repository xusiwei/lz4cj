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

共 7 项测试,覆盖版本函数、XXH32/XXH64(官方向量 + 流式)与 datagen(192 组参数组合的 C 实现交叉验证,期望值固化于 `src/datagen_test.cj` / `corpus/datagen_ref.txt`)。

## 当前进度

- **M0(完成)**:cjpm 静态库工程、双工具链脚本、LICENSE、README。
- **M1(完成)**:XXH32 / XXH64(one-shot + 流式)、datagen 及 C 交叉验证。

API 尚未对外(压缩/解压在后续里程碑提供);路线图见 [docs/design.md](docs/design.md)。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。
