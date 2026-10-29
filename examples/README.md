# examples

独立 cjpm 可执行工程集合:每个子目录自带 `cjpm.toml`(`output-type = "executable"`)
与 `src/main.cj`,进入目录 `cjpm run` 即可构建运行。需要先装好 SDK:

```bash
scripts/download_sdk.sh                 # 一次性:安装 SDK 到 ~/.local
source scripts/setup_env.sh lts         # 或 sts;然后:
cd examples/<name> && cjpm run
```

> 注意:切换工具链版本后先 `cjpm clean` 再运行(两版工具链的中间产物二进制不兼容)。

## 用法示例(10 个,移植自上游)

对齐上游 lz4 仓库 `examples/` 的全部示例程序,按 API 层次渐进排列。上游示例
整体为 GPL-2 许可,本目录全部为**概念重实现**(对同名 API 以仓颉重新组织,
代码文本独立,许可随本仓库 BSD-2);与上游的刻意差异(无 argv、确定性内存
输入、自动校验)见各文件头部说明。

| 工程 | API 层 | 上游原型 | 演示内容 |
| --- | --- | --- | --- |
| `print_version` | 版本 | print_version.c | 库的 "hello world":版本号查询 |
| `simple_buffer` | 块基础 | simple_buffer.c(BSD-2) | 内存中一次 `compress_default` → `decompress_safe` 往返 |
| `bench_functions` | 块进阶 | bench_functions.c(BSD-2) | 调用栈族 `default`/`fast`/`extState` 同输出校验 + 计时 |
| `block_streaming_double_buffer` | 块流式 | blockStreaming_doubleBuffer.c | 双缓冲续压/续解,跨块匹配共享 64KB 窗口 |
| `block_streaming_line_by_line` | 块流式 | blockStreaming_lineByLine.c | 逐记录压缩(u16 长度前缀),共享历史的尺寸收益对照 |
| `block_streaming_ring_buffer` | 块流式 | blockStreaming_ringBuffer.c | 环形缓冲 + 回卷前 `LZ4_saveDict` 保存历史 |
| `streaming_hc_ring_buffer` | HC 流式 | streamingHC_ringBuffer.c | `HC_continue` + 环形缓冲 + `saveDictHC`(解码器与普通块相同) |
| `dictionary_random_access` | 字典 | dictionaryRandomAccess.c | 字典预载逐块压缩 + 跳转表容器 + 任意区间按块随机解压 |
| `frame_compress` | Frame 流式 | frameCompress.c | 文件→文件有界内存:Begin/分块 Update/End + hint 驱动解压循环 |
| `file_compress` | lz4file | fileCompress.c | 像普通文件一样读写压缩文件(标准 LZ4 帧,魔数校验) |

## 验收冒烟与工具链探针(4 个,非教学示例)

| 工程 | 性质 |
| --- | --- |
| `downstream_smoke` | 库消费示例 + **CI 验收资产**:`scripts/verify_downstream.sh` 以其输出行为断言(block/HC/frame/lz4file 四路往返 + 钉值) |
| `arr_probe` | cjc windows-x64 数组伪越界探针(被探测的存储序列逐字保留,勿重构;见 report/windows_test_findings.md) |
| `oob_repro` | cjc windows 误编译独立复现尝试(单文件形状不复现,作形状文档;compile-option 钉 -O2) |
| `gc_stale_repro` | GC 陈旧读复现程序(M7-T6 调查,双工具链 10 轮零观测关闭;复发时以此为起点) |
