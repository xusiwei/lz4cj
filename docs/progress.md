# lz4cj 进度追踪

> **维护规则**:每个里程碑收尾任务同步更新本文件(完成态 + 证据数字 + 台账勾销)。
> 权威路线图见 [docs/design.md](design.md)(§10 里程碑表);本文件是其活状态视图。

## 基线(2026-09-29 确证)

- 上游 dev commit `0774d055`(2026-06-01)= v1.10.0 发布线(2024-07)之上的官方修复线,未进任何 release tag;dev 版本宏自报 1.10.0,`LZ4_versionString()` 返回 "1.10.0" 与上游 dev 一致
- **压缩输出与 v1.10.0 逐字节一致**(实证:独立 worktree 重编 harness,manifest 304/304、artifacts 264/264、partial 探针全同)
- 解压含 v1.10.0 后官方修复(OOB 读/循环边界/match limit):合法输入输出一致,损坏输入更严格(v1.10.0 为 OOB 读 UB,不复刻)
- HC(M4)/frame(M5/M6)按同一 commit 移植,单线基线;~/lz4 工作副本保持检出 0774d055
- 需 v1.10.0 对照时:`git -C ~/lz4 worktree add ~/lz4-v1100 v1.10.0`(用后可删)

## 已完成(93/93 测试,LTS-1.0.5 + STS-1.2.0 双绿;库源码行覆盖 96.60%)

| 里程碑 | 内容 | 验证证据 | 提交区间 |
|---|---|---|---|
| M0 | cjpm 工程、双工具链脚本(setup_env/build_and_test)、LICENSE/README | 冒烟双绿 | d4a932b..6672509 |
| M1 | XXH32/64(one-shot+流式,freeState 归零语义)、datagen 输出兼容 | 官方向量 + C 交叉 192/192 | f38ca87..27f3bb4(含 2eaa925) |
| M2 | block 压缩:default/fast/extState(+fastReset)/destSize(元组)、compressBound、stream 状态、指针工具层(common.cj) | golden 256+125,与 C 逐字节 222;对抗探针 125/125 | 211f212..2d894c6 |
| M3a | block 解压全家族:safe+fast 双路、partial、usingDict、流式解码(continue/环缓冲/setStreamDecode) | L2 往返 264;差分 ~900 组;fuzz 2200 种子零异常 | 49e954b..e874a38 |
| 基线确证 | dev@0774d055 显式化 + v1.10.0 等价实证 + 本文件建立 | manifest 304/304 双 ref 全同 | 7e868c3..61f08be |
| M3b | 流式压缩全家:`prepareTable` 真实表保留语义、withPrefix64k/usingExtDict/usingDictCtx 三态压缩核心、create/free/reset(+fast)/loadDict(+Slow)/attach_dictionary/compress_fast_continue/saveDict/destSize_extState | golden 新 46 行(总 356)双工具链逐字节;闭环往返(cont/savedict/extdict/dict/attach);边界 C 探针钉值;57/57 双绿;库覆盖 96.81% | 10118fe..98a4273(收尾本次提交) |
| M4 | HC 高压缩全量(lz4hc.c 非弃用 API):三策略核心 LZ4MID(lv1-2)/hashChain(lv3-9)/optimal(lv10-12)+ favorDecompressionSpeed,状态族 + one-shot(extState/fastReset)+ destSize + 流式 loadDictHC/attach/continue(+destSize)/saveDictHC,levels 1-12 全采样 | 93/93 双绿;golden 新 70 行(总 426 数据行/443 清单行)双工具链逐字节 + C 探针钉值(含 row-420 修复后再生成);fuzz HC 300 种子(分层 mid/hc/opt 各 100,零异常);库覆盖 96.60% | 871c6f6..HEAD(收尾本次提交) |

**已就绪公开 API(46 函数 + 常量族)**:版本族、compressBound 族、压缩 6(default/fast/extState/fastReset/destSize/destSize_extState)、解压 4、流式解码 5、流式压缩 10(create/free/reset/resetFast/loadDict/loadDictSlow/attach/continue/saveDict + initStream 归状态原语)、stream 状态原语(sizeofState/STREAMSIZE)、HC 17(compress_HC/extStateHC(+fastReset)/destSize、sizeofStateHC、create/free/init/reset(+fast)/setCompressionLevel/favorDecompressionSpeed、loadDictHC/attach/compress_HC_continue/continue_destSize/saveDictHC)+ LZ4HC_CLEVEL_{MIN,DEFAULT,OPT_MIN,MAX} 常量族。**HC 层(lz4hc.c 非弃用 API 全量)就此闭环**,M5 起 frame。

## 剩余(依赖顺序)

1. **M5 Frame 压缩**(~4 任务):cctx 状态机、preferences 归一化、compressFrame(+CDict)、Begin/Update/uncompressedUpdate/Flush/End、头编码(XXH32)
2. **M6 Frame 解压**(~4-5 任务,复杂度最高):dctx 分片续传状态机、getFrameInfo、块+内容校验和、skippable、帧拼接、随机切分测试(上游 frametest 坑位清单化)
3. **M7 收尾测试**(~2-3 任务):golden 全矩阵扩至设计规格(~200 用例全参数交叉,补 tight-capacity 压缩行 + overlap-shrink 套件用例 + lz4hc.cj 34 个可达未覆盖行,见台账)、fuzz 加压、bench(fast 路径字面密集 0.85x 复评 + 热点优化)
4. **M8 发布**(~2 任务):README API 对照表/差异清单、CHANGELOG、发布分支 `lz4_lt_1.0.5`/`lz4_st_1.2.0`、可选中心仓(cangjie-repo.toml)

## 遗留事项台账(归属里程碑)

- [x] ~~manifest `#` 行解析侧守卫(gen_golden.sh 已校验恰好 4 条;仓颉测试目前嵌常量不解析)~~(M3b 收尾查证关闭:src/lz4_test.cj 全量嵌常量、无任何 manifest 解析代码,M2/M3a/M3b 三代 356 行 golden 一贯此模式;`#` 行计数已由 gen_golden.sh 门控(现恰 11 条,含每节出处注释);若 M5/M6 帧测试引入 manifest 解析,按 gen_golden.sh 注释的 `#` 语义重开)
- [x] ~~`LZ4_compress_destSize_extState` 归属确认:lz4.h 公开 API(两 ref 均有),设计 §4.5 M2 清单漏记~~(M3b-T1 回写 §4.5:纳入 M3b-T4 落地)
- [x] ~~spanning/dest 对抗探针脚本入库(现仅嵌入常量,脚本在 /tmp 已失)~~(M3b 收尾勾销:dest_probe.c M2 已入库;M3a spanning 探针重建入库 scripts/span_probe.c——合并 /tmp 碎片为 lz4DecompressExtDictSpanningTest 全部钉住案例,对上游 0774d055 重编译验证 14/14 输出一致;M3b 新探针一并入库:scripts/edge_probe.c(lz4StreamingEdgeTest 边界语义源)+ scripts/probe_overlap.c(overlap-shrink 差分),均重编译运行验证与报告值一致)
- [x] ~~design.md §4.3 "默认 0" 措辞精确化:`offset!` 实为必传具名参数,无默认值~~(M3b-T1 文档批次;注:台账原记"规则 2",实际位于 §4.3 规则 3)
- [ ] `compress_fast_continue` 输入/字典重叠收缩分支体(lz4.cj L1147-1154,上游 L1744-1752)套件未覆盖:C 差分已验(scripts/probe_overlap.c:pass2 c=20106 xxh=55883273 + 解码闭合)但未入测试/golden → **M7 收尾测试**(golden 加一行或直接断言)
- [ ] lz4hc.cj 34 个可达未覆盖行(M4 收尾 cjcov 复核,库覆盖 96.60% 之下仅存的可达缺口):opt 解析器 _Search3 区域 22 行(三序列合并挤压校正 L807/L873-874/L906-915 + 四处 encodeSequence 缓冲不足出口 L834-839/L854-855/L881-886/L925-930,需 lv10-12 紧容量/fillOutput 中途溢出或特定重复几何)、InsertAndGetWiderMatch 的 dictCtx countBack 回扩 L1046、fillOutput 深度钳制 2 行(MID L1358 / hashChain L1739)、optimal_t 字面量改价 L1629、overlap-shrink 后 dict<4 丢弃 L2360-2361 → **M7 收尾测试**(fuzz 加压或定向用例;其余 17 个未覆盖行为防御/不可达类,已在 CHANGELOG 0.5.0 归类)
- [ ] virgin-attach(dictCtx 前缀为空)→ noDictCtx 回退(lz4hc.cj L1988-1992):上游该路径 NULL 解引用为 UB/崩溃,仓颉防御性回退不复刻,输出无对照基准 —— 裁定登记(CHANGELOG 0.5.0 已归类)
- [ ] RDG_genBuffer 等测试支撑代码位于 src/ 导致 lib 构建 unused 警告(结构性)→ **M8 发布前评估**(移 *_test.cj 约定或保持)
- [ ] fast 解压路径字面密集输入 ~0.85x(指针循环 wildCopy 未继承 C SIMD 优势)→ **M7 bench 复评**,劣化再优化
- [x] ~~CHANGELOG M3a 计时笔误~~(0.3.1 条目修正)
- [x] ~~wildCopy8 do-while 语义审计~~(M3a T3 审结:调用点等价,helper 已对齐上游)

## 待决事项

- ~/lz4 的 v1.10.0 worktree 是否常设保留(默认不留,按需 `git worktree add` 重建;见"基线"节命令)
- 帧格式 multithread(numThreads)上游此版本未暴露,无需决策;XXH64 对外暴露与否(M1 定为暂不,如需求出现重议)

## 下一步

M5 Frame 压缩:写计划(lz4frame.c 压缩侧任务分解)→ 子代理驱动执行(既定模式)。
