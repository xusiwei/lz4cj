# lz4cj 进度追踪

> **维护规则**:每个里程碑收尾任务同步更新本文件(完成态 + 证据数字 + 台账勾销)。
> 权威路线图见 [docs/design.md](design.md)(§10 里程碑表);本文件是其活状态视图。

## 基线(2026-09-29 确证)

- 上游 dev commit `0774d055`(2026-06-01)= v1.10.0 发布线(2024-07)之上的官方修复线,未进任何 release tag;dev 版本宏自报 1.10.0,`LZ4_versionString()` 返回 "1.10.0" 与上游 dev 一致
- **压缩输出与 v1.10.0 逐字节一致**(实证:独立 worktree 重编 harness,manifest 304/304、artifacts 264/264、partial 探针全同)
- 解压含 v1.10.0 后官方修复(OOB 读/循环边界/match limit):合法输入输出一致,损坏输入更严格(v1.10.0 为 OOB 读 UB,不复刻)
- HC(M4)/frame(M5/M6)按同一 commit 移植,单线基线;~/lz4 工作副本保持检出 0774d055
- 需 v1.10.0 对照时:`git -C ~/lz4 worktree add ~/lz4-v1100 v1.10.0`(用后可删)

## 已完成(44/44 测试,LTS-1.0.5 + STS-1.2.0 双绿;库源码行覆盖 98.35%)

| 里程碑 | 内容 | 验证证据 | 提交区间 |
|---|---|---|---|
| M0 | cjpm 工程、双工具链脚本(setup_env/build_and_test)、LICENSE/README | 冒烟双绿 | d4a932b..6672509 |
| M1 | XXH32/64(one-shot+流式,freeState 归零语义)、datagen 输出兼容 | 官方向量 + C 交叉 192/192 | f38ca87..27f3bb4(含 2eaa925) |
| M2 | block 压缩:default/fast/extState(+fastReset)/destSize(元组)、compressBound、stream 状态、指针工具层(common.cj) | golden 256+125,与 C 逐字节 222;对抗探针 125/125 | 211f212..2d894c6 |
| M3a | block 解压全家族:safe+fast 双路、partial、usingDict、流式解码(continue/环缓冲/setStreamDecode) | L2 往返 264;差分 ~900 组;fuzz 2200 种子零异常 | 49e954b..e874a38 |
| 基线确证 | dev@0774d055 显式化 + v1.10.0 等价实证 + 本文件建立 | manifest 304/304 双 ref 全同 | 7e868c3..(本提交) |

**已就绪公开 API(19 函数 + 常量族)**:版本族、compressBound 族、压缩 5、解压 4、流式解码 5、stream 状态原语(initStream/sizeofState/STREAMSIZE)。

## 剩余(依赖顺序)

1. **M3b 流式压缩**(~4 任务):`LZ4_prepareTable` 真实表保留语义(M2 登记义务,fastReset 真实化)→ withPrefix64k/usingExtDict 进压缩核心 → `LZ4_createStream/freeStream/resetStream(+fast)/loadDict(+Slow)/attach_dictionary/compress_fast_continue/saveDict` → 字典/续压 golden + 往返
2. **M4 HC 高压缩**(~5-6 任务,lz4hc.c 2255 行,剩余工作量大头):链表匹配、级别 1-12、二叉树、最优解析(≥10)、favorDecompressionSpeed、destSize、流式 + 字典 + attach、levels 全采样 golden
3. **M5 Frame 压缩**(~4 任务):cctx 状态机、preferences 归一化、compressFrame(+CDict)、Begin/Update/uncompressedUpdate/Flush/End、头编码(XXH32)
4. **M6 Frame 解压**(~4-5 任务,复杂度最高):dctx 分片续传状态机、getFrameInfo、块+内容校验和、skippable、帧拼接、随机切分测试(上游 frametest 坑位清单化)
5. **M7 收尾测试**(~2-3 任务):golden 全矩阵扩至设计规格(~200 用例全参数交叉,补 tight-capacity 压缩行)、fuzz 加压、bench(fast 路径字面密集 0.85x 复评 + 热点优化)
6. **M8 发布**(~2 任务):README API 对照表/差异清单、CHANGELOG、发布分支 `lz4_lt_1.0.5`/`lz4_st_1.2.0`、可选中心仓(cangjie-repo.toml)

## 遗留事项台账(归属里程碑)

- [ ] manifest `#` 行解析侧守卫(gen_golden.sh 已校验恰好 4 条;仓颉测试目前嵌常量不解析)→ **M3b 消费者要求**
- [x] ~~`LZ4_compress_destSize_extState` 归属确认:lz4.h 公开 API(两 ref 均有),设计 §4.5 M2 清单漏记~~(M3b-T1 回写 §4.5:纳入 M3b-T4 落地)
- [ ] spanning/dest 对抗探针脚本入库(现仅嵌入常量,脚本在 /tmp 已失)→ **M3b 下次需要 C 探针时一并补**
- [x] ~~design.md §4.3 "默认 0" 措辞精确化:`offset!` 实为必传具名参数,无默认值~~(M3b-T1 文档批次;注:台账原记"规则 2",实际位于 §4.3 规则 3)
- [ ] RDG_genBuffer 等测试支撑代码位于 src/ 导致 lib 构建 unused 警告(结构性)→ **M8 发布前评估**(移 *_test.cj 约定或保持)
- [ ] fast 解压路径字面密集输入 ~0.85x(指针循环 wildCopy 未继承 C SIMD 优势)→ **M7 bench 复评**,劣化再优化
- [x] ~~CHANGELOG M3a 计时笔误~~(0.3.1 条目修正)
- [x] ~~wildCopy8 do-while 语义审计~~(M3a T3 审结:调用点等价,helper 已对齐上游)

## 待决事项

- ~/lz4 的 v1.10.0 worktree 是否常设保留(默认不留,按需 `git worktree add` 重建;见"基线"节命令)
- 帧格式 multithread(numThreads)上游此版本未暴露,无需决策;XXH64 对外暴露与否(M1 定为暂不,如需求出现重议)

## 下一步

M3b 流式压缩:写计划(含上表 M3b 条目 + 台账中 M3b 归属项)→ 子代理驱动执行(既定模式)。
