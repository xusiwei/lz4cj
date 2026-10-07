# e2e 端到端交叉验证

用两个契约完全相同的命令行 LZ4 帧压缩/解压工具,对 `lz4cj` 仓颉移植与
上游 lz4 C 库做真实文件级的端到端交叉验证:

```
e2e/
├── cli-c/     C 参照工具:上游 lz4 C 源码基线 0774d055 就地编译(CMake 跨平台)
├── cli-cj/    仓颉工具:独立 cjpm executable 模块,path 依赖仓库根(../..)
└── run_e2e.sh 总控:建双工具 → 生成用例 → 跑全矩阵 → 汇总
```

两个 cjpm 模块能否共存于一个仓库?可以——单模块 `output-type` 二选一,
但本套采用"独立小模块 + path 依赖"(即 `scripts/verify_downstream.sh` 已
实证的机制),父仓库 `include` 仅覆盖 `src/**`,互不干扰(实测父仓库
`cjpm test` 用例数不变)。

## 工具契约(两侧逐字一致)

```
lz4cli / lz4cli-cj  -c|-d  -i <输入>  -o <输出>
  -c  压缩(LZ4F_compressFrame,默认 preferences)
  -d  解压(流式 LZ4F_decompress,输出缓冲按需倍增)
退出码:0 成功;1 运行错误(I/O、损坏/截断帧、帧后尾随字节);2 用法错误
```

## 运行

```bash
export LZ4CJ_SDK_105=... LZ4CJ_SDK_120=...   # Windows/自定义 SDK 位置(可选)
export LZ4CJ_UPSTREAM=~/lz4                  # 上游源码位置(缺省 ~/lz4,可选)
e2e/run_e2e.sh            # [lt|st|both],缺省 both
```

前置:cmake + ninja(或默认生成器)、上游 lz4 检出 0774d055(同
`scripts/gen_golden.sh` 的定位规则)、SDK 经 `scripts/cjenv.sh` 解析。

## 验证矩阵(每工具链 × 每用例)

用例:空文件 / 1 字节 / 64KB 全零 / 源码文本 / 256KB 随机(不可压)/ 1MB 混合。

1. C 与仓颉的**压缩输出逐字节一致**(帧保真,默认 preferences)
2. C 压 → C 解 == 原文件(参照自洽)
3. 仓颉压 → 仓颉解 == 原文件(移植自洽)
4. C 压 → 仓颉解 == 原文件(交叉)
5. 仓颉压 → C 解 == 原文件(交叉)
6. 双方均拒绝:魔数损坏 / 帧截断 / 帧后尾随字节 / 输入缺失(非零退出)

每次工具调用带 300s 超时(Windows x64 运行时非确定性活锁的兜底,
见仓库 report/windows_test_findings.md;超时按失败计,重跑即可)。
Windows 实测(LTS 1.0.5 + STS 1.2.0):PASS=148 / FAIL=0。
