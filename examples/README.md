# examples

独立 cjpm 可执行工程集合:每个子目录自带 `cjpm.toml`(`output-type = "executable"`)
与 `src/main.cj`,从仓库根 `cjpm build` / `cjpm run` 即可单独构建运行。

## 运行前置

```bash
scripts/download_sdk.sh                 # 一次性:安装 SDK 到 ~/.local
source scripts/setup_env.sh lts         # 或 sts;然后:
cd examples/<name> && cjpm run
```

## 目录

| 工程 | 演示内容 |
| --- | --- |
| `downstream_smoke/` | **库消费示例**:以 path 依赖引用本仓库,block / HC / frame / lz4file 四路压缩-解压逐字节往返 + 尺寸钉值(`c=517 hc=517 fc=532 lf=532`);`scripts/verify_downstream.sh` 下游验收即运行本例 |
| `arr_probe/` | cjc windows-x64 数组越界检查异常探针:对 `Array<UInt8>(8+sz)` 连续常量下标写的伪越界测绘(见 [report/windows_test_findings.md](../report/)) |
| `oob_repro/` | cjc windows-x64 `-O2` 伪越界误编译的独立复现尝试(单文件形状不复现,保留作形状文档与工具链修复后的对照) |
| `gc_stale_repro/` | GC 陈旧读复现程序(M7-T6 #47,双工具链 10 轮零观测关闭;复发时以此为起点) |

探针类工程(`arr_probe`/`oob_repro`)的被探测存储/比较序列**逐字保留**原样 ——
这些代码的形状就是探针的载荷,重构会使其失去意义;函数化仅限外围。
