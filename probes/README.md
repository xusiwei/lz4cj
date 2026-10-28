# probes

C 侧钉值工具集:每个程序编译时链接**上游 lz4 C 源码**(`~/lz4` @0774d055,可用
`LZ4CJ_UPSTREAM` 覆盖),运行时对确定性输入打印尺寸/摘要/返回值。这些打印值被
硬编码进仓颉测试(`src/*_test.cj`)作为期望常量 —— 测试运行时因此不需要 C 工具链。
仅开发期使用:换上游基线、重推导钉值、再生 golden 语料时才需要编译运行它们。

所有探针 2026-10-28 自 `scripts/` 迁入(历史文档中的 `scripts/<name>.c` 路径即本目录)。

## 编译运行(通用模式)

```bash
cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests -I$HOME/lz4/programs \
   probes/<name>.c $HOME/lz4/tests/datagen.c $HOME/lz4/lib/{lz4,lz4hc,lz4frame,xxhash}.c \
   -o probes/<name>          # 按各文件头部构建行为准(并非都要链接全部源)
./probes/<name>
```

## 索引(探针 → 钉值内容 → 对应仓颉测试)

| 文件 | 钉值内容 | 对应仓颉侧 |
| --- | --- | --- |
| `gen_golden.c` | golden 生成器(2969 行):产出 `corpus/block_golden_ref.txt` 512 行清单 + block artifacts;由 `scripts/gen_golden.sh` 编排,**CI 每次运行** | 全部 golden 字节级比对用例 |
| `bench_probe.c` | C 性能对照:`src/bench_test.cj` 同输入同操作 best-of-3 MB/s,仓颉/C 比值表与 M8"差距结构性"裁定的依据 | `bench_test.cj` |
| `datagen_ref.c` | RDG 数据生成器交叉验证摘要(仓颉 `datagen.cj` 与上游逐字节一致的前提) | `datagen_test.cj` |
| `dest_probe.c` | 对抗性 destSize 的 matchCode 缩减分支(lz4.c L1198-1216) | `lz4_test.cj` `DEST_REDUCTION_REF` |
| `edge_probe.c` | 块流式边界:`fast_continue`/`saveDict`/`loadDict`/`attach`/`destSize_extState` | `lz4StreamingEdgeTest` |
| `span_probe.c` | 解压 extDict 跨界匹配拷贝(起于字典、延伸进当前块) | `lz4DecompressExtDictSpanningTest` |
| `probe_fastreset_reuse.c` | `fastReset` 脏表复用 vs 全新状态的差分搜索 | `extState_fastReset` 用例 |
| `probe_overlap.c` | dictEnd 重叠收缩分支(lz4.c L1744-52,golden 未钉) | 流式差分补充(ledger M7) |
| `hc_probe.c` | HC 流式边界:`HC_continue`/`loadDictHC`/`saveDictHC`/`resetStreamHC_fast` | `lz4hcStreamEdgeTest` |
| `hc_dest_probe.c` | HC destSize fillOutput 区制三档 target | `HC_DEST_OVERFLOW_REF` |
| `hc_search3_probe.c` | HC 难触达几何:`_Search3` sweep / fillOutput 钳制 / overlap<4 / opt 改价 | M7-T2 覆盖率定向用例 |
| `ctx_swap_probe.c` | Frame cctx 换型:一 cctx 跨 8 帧走遍 lz4frame.c L722-752 全部复用路径 | `lz4fCtxTypeSwapTest` |
| `frame_decode_probe.c` | Frame 解压字典前缀:指针邻接 vs 内容窗口判定三几何(M6 终审修复依据) | `lz4fDictPrefixedOutputTest` 等三个 |
| `large_probe.c` | >256KB 运行时矩阵(L_A~L_D)尺寸/XXH32/XXH64 钉值 | `large_test.cj` |
| `lz4file_probe.c` | lz4file 地面真值:4 prefs 变体分块写 + 读回 + 错误注入钉值 | `lz4file_test.cj` parity |

命名规律:`*_probe` = 行为探针(钉值事实来源)、`*_ref` = 摘要参考、
`gen_golden` = 语料生成器、`bench_probe` = 性能基线。
