# e2e 端到端交叉验证

用两个契约完全相同的命令行 LZ4 帧压缩/解压工具,对 `lz4cj` 仓颉移植与
上游 lz4 C 库做真实文件级的端到端交叉验证:

```
e2e/
├── cli-c/     C 参照工具:CMake FetchContent 集成上游 lz4 基线 0774d055
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
  -c  压缩(lz4file:writeOpen/write/writeClose,默认 preferences 等价)
  -d  解压(流式解压:C 侧输出缓冲按需倍增;仓颉侧固定窗口滚动写盘)
退出码:0 成功;1 运行错误(I/O、损坏/截断帧、帧后尾随字节);2 用法错误
```

压缩两侧均走 lz4file 写路径,并显式复刻 `LZ4F_compressFrame(NULL)` 的
prefs 自动改写(lz4frame.c L443-453:默认 blockSizeID=max64KB;输入 ≤ 单块
时 blockMode=blockIndependent)。原因:compressFrame(整块稳定源,prefix
模式)与 lz4file 分块写(stableSrc=0,extDict 模式)在跨块匹配上会合法地
选出不同匹配——上游 C 两条路径本身不逐字节一致(137MB 实测分歧于
134,286 字节处);两 twin 同走 lz4file 路径后字节一致性由构造保证。

仓颉侧解压不直接用 `LZ4F_read`:lz4file 读侧无法区分「干净收帧」与
「截断」(两者都返回短读),而本契约要求拒绝截断帧;故用窗口化
`LZ4F_decompress` 循环(即 LZ4F_read 的内部结构 + 帧完成/尾随检测信号)。

内存模型:仓颉侧恒定占用,与文件大小无关(压缩喂入 4MB 窗 + lz4file
64KB 块缓冲;解压 256KB/1MB 双窗),实测 137MB 输入压缩峰值 ~170MB /
解压 ~53MB 工作集(默认 256MiB 运行时堆下运行,活集仅几 MB,其余为可
回收的 GC 堆增长)。旧版全量缓冲布局(readFrom + 4× 预估)在 ~137MB 输入
上必触仓颉运行时默认堆上限而 OOM。

## 运行

```bash
export LZ4CJ_SDK_105=... LZ4CJ_SDK_120=...   # Windows/自定义 SDK 位置(可选)
export LZ4CJ_UPSTREAM=~/lz4                  # 可选:本地源码覆盖 FetchContent 下载
e2e/run_e2e.sh            # [lt|st|both],缺省 both
```

前置:cmake + ninja(或默认生成器)、SDK 经 `scripts/cjenv.sh` 解析。
单独配置 CMake 时默认从 GitHub 获取固定的上游提交 `0774d055`；
`run_e2e.sh` 优先使用 `LZ4CJ_UPSTREAM`，其次使用已存在的 `~/lz4`，
否则由 FetchContent 下载。使用本地检出时，脚本通过
`FETCHCONTENT_SOURCE_DIR_LZ4` 覆盖下载，可离线构建。手动配置 C 工具时也可直接传入
`-DFETCHCONTENT_SOURCE_DIR_LZ4=<lz4 检出的绝对路径>`。

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
