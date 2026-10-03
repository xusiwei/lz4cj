# lz4cj 进度追踪

> **维护规则**:每个里程碑收尾任务同步更新本文件(完成态 + 证据数字 + 台账勾销)。
> 权威路线图见 [docs/design.md](design.md)(§10 里程碑表);本文件是其活状态视图。

## 基线(2026-09-29 确证)

- 上游 dev commit `0774d055`(2026-06-01)= v1.10.0 发布线(2024-07)之上的官方修复线,未进任何 release tag;dev 版本宏自报 1.10.0,`LZ4_versionString()` 返回 "1.10.0" 与上游 dev 一致
- **压缩输出与 v1.10.0 逐字节一致**(实证:独立 worktree 重编 harness,manifest 304/304、artifacts 264/264、partial 探针全同)
- 解压含 v1.10.0 后官方修复(OOB 读/循环边界/match limit):合法输入输出一致,损坏输入更严格(v1.10.0 为 OOB 读 UB,不复刻)
- HC(M4)/frame(M5/M6)按同一 commit 移植,单线基线;~/lz4 工作副本保持检出 0774d055
- 需 v1.10.0 对照时:`git -C ~/lz4 worktree add ~/lz4-v1100 v1.10.0`(用后可删)

## 已完成(156/156 测试,LTS-1.0.5 + STS-1.2.0 双绿;库源码行覆盖 97.44%)

| 里程碑 | 内容 | 验证证据 | 提交区间 |
|---|---|---|---|
| M0 | cjpm 工程、双工具链脚本(setup_env/build_and_test)、LICENSE/README | 冒烟双绿 | d4a932b..6672509 |
| M1 | XXH32/64(one-shot+流式,freeState 归零语义)、datagen 输出兼容 | 官方向量 + C 交叉 192/192 | f38ca87..27f3bb4(含 2eaa925) |
| M2 | block 压缩:default/fast/extState(+fastReset)/destSize(元组)、compressBound、stream 状态、指针工具层(common.cj) | golden 256+125,与 C 逐字节 222;对抗探针 125/125 | 211f212..2d894c6 |
| M3a | block 解压全家族:safe+fast 双路、partial、usingDict、流式解码(continue/环缓冲/setStreamDecode) | L2 往返 264;差分 ~900 组;fuzz 2200 种子零异常 | 49e954b..e874a38 |
| 基线确证 | dev@0774d055 显式化 + v1.10.0 等价实证 + 本文件建立 | manifest 304/304 双 ref 全同 | 7e868c3..61f08be |
| M3b | 流式压缩全家:`prepareTable` 真实表保留语义、withPrefix64k/usingExtDict/usingDictCtx 三态压缩核心、create/free/reset(+fast)/loadDict(+Slow)/attach_dictionary/compress_fast_continue/saveDict/destSize_extState | golden 新 46 行(总 356)双工具链逐字节;闭环往返(cont/savedict/extdict/dict/attach);边界 C 探针钉值;57/57 双绿;库覆盖 96.81% | 10118fe..98a4273(收尾本次提交) |
| M4 | HC 高压缩全量(lz4hc.c 非弃用 API):三策略核心 LZ4MID(lv1-2)/hashChain(lv3-9)/optimal(lv10-12)+ favorDecompressionSpeed,状态族 + one-shot(extState/fastReset)+ destSize + 流式 loadDictHC/attach/continue(+destSize)/saveDictHC,levels 1-12 全采样 | 93/93 双绿;golden 新 70 行(总 426 数据行/443 清单行)双工具链逐字节 + C 探针钉值(含 row-420 修复后再生成);fuzz HC 300 种子(分层 mid/hc/opt 各 100,零异常);库覆盖 96.60% | 871c6f6..a027b16 |
| M5 | Frame 压缩全量(lz4frame.c 压缩侧):版本/错误族、getBlockSize、compressFrameBound/compressBound、cctx 生命周期、compressBegin(含 usingDict/usingCDict)、compressUpdate/uncompressedUpdate/flush/compressEnd、一次性族 compressFrame/compressFrame_usingCDict、LZ4F_CDict 预消化字典(createCDict/freeCDict),五枚举以 Int32 常量族承载 | 117/117 双绿;golden 新 49 行(10 frhdr + 27 frame + 8 f1s + 2 fcd + 2 fdt,清单 497 行/475 数据行/22 注释)双工具链逐字节 + digest/artifact 优雅降级(corpus 政策:不入 git,gen_golden.sh 再生);f1s↔frame 行间巧合交叉钉值 + fdt row2 钉住 usingDict+blockIndependent 字典整体丢弃怪癖(C 探针 2026-10-02:帧 == 无字典帧,严于头文件"仅首块"文档);fuzz frame 120 种子(一次性 + 流式链 ×2 确定性重放,未压缩块插入 + 中途 flush,容量恒 compressFrameBound,规划器先验块数模拟 + 探针降级保证非错误);库覆盖 96.43%(lz4frame.cj 472/495,23 未覆盖行归类见台账) | 103ba46..23c2e13 |
| M7 | 收尾测试:压缩/HC/解压三侧定向覆盖(overlap-shrink 套件钉值、换型分支白盒+探针、紧容量错误契约、HC _Search3 出口/钳制/改价族、dictInTmp 容量保全、flushOut/join copySize 钳制族)、>256KB 运行时矩阵(large_probe 18 钉值行,设计 §8.2 末行补齐,frame 压缩侧最大输入 150000→1048576)、fuzz 加压(LCG 奇偶锁修复对齐 M6 范式 + 五测试种子 3000/320/420/240/300)、bench 基线(bench_probe/benchAllTest,0.85x 复评不可复现裁定 + 实测比值表 0.02-0.6x 入档)、两项调查关闭(cjcov 跨会话行归因漂移=会话内确定;GC 陈旧读 10 轮零复现,复现程序入库) | 156/156 双绿;库覆盖 97.44%(3866/3968,同会话口径):common/xxhash/datagen 100%、lz4.cj 96.12%、lz4hc.cj 97.38%、lz4frame.cj 96.79%、lz4frame_decode.cj 98.42%;残行终版归类(代数/经验不可达 22+5、防御、>1GB 内存裁定)见 CHANGELOG 0.8.0 | 7433760..852ea90(含裁定) |
| M6 | Frame 解压全量(lz4frame.c 解压侧):LZ4F_dctx 14-stage 分片续传状态机(decodeHeader/updateDict/尾部历史保存)、create/free/resetDecompressionContext、headerSize、getFrameInfo、decompress/decompress_usingDict、skippable 跳帧、块/内容校验和、帧拼接;指针语义按 §4.4 翻译表承载(dict/tmpOut 引用对 + dictInTmp 标记;前缀谓词终审修复:内容窗口 → 分配同一性双哨兵探针 —— 字典前缀输出几何下内容谓词假阳性致外来数组延展越界,updateDict 首两分支改 C L1563-1569 同构) | 141/141 双绿(终审修复 +3 回归:字典前缀输出/内容等值换缓冲/异值对照,探针 scripts/frame_decode_probe.c 对上游钉值;RED→GREEN 证据留档);golden 14 行 fdmp C 解压探针(清单 512 行/489 数据行/23 注释:getFrameInfo 三岔探针、分片续传 hint 三元组 ×3、skippable ×2、拼接、dict 双钉、错误码族 ×3,含 skipChecksums 不屏蔽压缩块校验的上游怪癖钉值);分片续传矩阵(27 行 × 7 变体:1B/7B/997B/LCG 切分 × 容量 n/10/1000 + dstIdx=4096 位置对)+ stableDst 兑现 + skipChecksums 粘滞 + skippable 8 组合 + 4 帧拼接;fuzz frame decode 150 种子(随机切分 × 容量阶梯 {0,小,maxBlockSize,n} + 2-4 帧拼接混 skippable + 损坏三型,四类终态存在性断言(实测 22/75/50/3),场景 A ×2 逐字节确定性重放;LCG 连续奇偶锁定的比特色散修复:bm/ccs/bcs/af 取一字 nibble、布尔改奇模数);覆盖门禁定向用例 5 个(分片坏头/getFrameInfo 错误岔/BD 保留位、raw csz、块 CRC 分片暂存、skippable getSFrameSize 不足路、多缓冲 updateDict 三分支 + flushOut 尾部保存 + 双截尾);库覆盖 96.52%(lz4frame_decode.cj 611/627,16 未覆盖行归类见台账) | dd163ca..HEAD(含终审修复) |
| M8 | 发布:cjpm.toml 0.9.0 定稿(`version` 1.0.0→0.9.0 与 CHANGELOG 序列对齐、`repository` 订正 atomgit.com/xusiwei1236/lz4cj)+ `-Woff unused -Woff parser` 零警告构建(23 条 lib 警告清零,归类裁定:10 unused function + 5 unused variable + 7 parser,库源码零改动)、下游依赖验收(verify_downstream.sh + downstream_smoke.cj:本地 path 依赖临时下游 executable,block/HC/frame 三路往返 + 钉值 c=517/hc=517/fc=532)、性能 §2.2 书面裁定结案(差距结构性,不做优化,库源码冻结;benchAllTest 非回归监控)、文档定稿(README 使用示例节/API 对照表补全/性能裁定/进度收尾、CHANGELOG 0.9.0、design §10 M8 勾选、progress 收尾)、中心仓裁定暂不接入(非 MVP,path 依赖过渡)、发布分支 `lz4_lt_1.0.5` / `lz4_st_1.2.0` + tag `v0.9.0-lt` / `v0.9.0-st` | 156/156 双绿;lib 构建零警告(双工具链);verify_downstream both PASS(钉值 LTS/STS 同值);分支/tag 落地 | b99a767..HEAD(收尾本次提交) |

**已就绪公开 API(74 函数 + 常量族)**:版本族、compressBound 族、压缩 6(default/fast/extState/fastReset/destSize/destSize_extState)、解压 4、流式解码 5、流式压缩 10(create/free/reset/resetFast/loadDict/loadDictSlow/attach/continue/saveDict + initStream 归状态原语)、stream 状态原语(sizeofState/STREAMSIZE)、HC 17(compress_HC/extStateHC(+fastReset)/destSize、sizeofStateHC、create/free/init/reset(+fast)/setCompressionLevel/favorDecompressionSpeed、loadDictHC/attach/compress_HC_continue/continue_destSize/saveDictHC)+ LZ4HC_CLEVEL_{MIN,DEFAULT,OPT_MIN,MAX} 常量族、**frame 压缩 21**(版本/错误 5:isError/getErrorName/getErrorCode/getVersion/compressionLevel_max;界限 3:getBlockSize/compressFrameBound/compressBound;cctx 生命周期 2:create/freeCompressionContext;Begin 族 3:compressBegin(+usingDict/+usingCDict);Update 族 4:compressUpdate/uncompressedUpdate/flush/compressEnd;一次性 2:compressFrame/compressFrame_usingCDict;CDict 2:createCDict/freeCDict)+ **frame 解压 7**(dctx 生命周期 3:create/free/resetDecompressionContext;查询 2:headerSize/getFrameInfo;解压 2:decompress/decompress_usingDict)+ LZ4F_decompressOptions_t(stableDst/skipChecksums,reserved 省略)、LZ4F_MIN_SIZE_TO_KNOW_HEADER_LENGTH=5、dstage_* 内部常量族(0..14)、LZ4F_{VERSION,MAGICNUMBER,HEADER_SIZE_MAX,BLOCK_HEADER_SIZE,BLOCK_CHECKSUM_SIZE}、错误码 24 常量族与 blockSizeID/blockMode/contentChecksumFlag/blockChecksumFlag/frameType 五枚举 Int32 常量族。**frame 层(lz4frame.c 压缩 + 解压 API 全量)双向闭环**;isSkippedFrame/decompress_usingCDict 上游 0774d055 不存在(设计 §4.5 原清单误记,T1 已订正:skippable 判定经 frameInfo.frameType == LZ4F_skippableFrame 表达)。

## 剩余(依赖顺序)

(无 —— 路线图 M0-M8 全部完成)

## 遗留事项台账(归属里程碑)

- [x] ~~manifest `#` 行解析侧守卫(gen_golden.sh 已校验恰好 4 条;仓颉测试目前嵌常量不解析)~~(M3b 收尾查证关闭:src/lz4_test.cj 全量嵌常量、无任何 manifest 解析代码,M2/M3a/M3b 三代 356 行 golden 一贯此模式;`#` 行计数已由 gen_golden.sh 门控(现恰 11 条,含每节出处注释);若 M5/M6 帧测试引入 manifest 解析,按 gen_golden.sh 注释的 `#` 语义重开)
- [x] ~~`LZ4_compress_destSize_extState` 归属确认:lz4.h 公开 API(两 ref 均有),设计 §4.5 M2 清单漏记~~(M3b-T1 回写 §4.5:纳入 M3b-T4 落地)
- [x] ~~spanning/dest 对抗探针脚本入库(现仅嵌入常量,脚本在 /tmp 已失)~~(M3b 收尾勾销:dest_probe.c M2 已入库;M3a spanning 探针重建入库 scripts/span_probe.c——合并 /tmp 碎片为 lz4DecompressExtDictSpanningTest 全部钉住案例,对上游 0774d055 重编译验证 14/14 输出一致;M3b 新探针一并入库:scripts/edge_probe.c(lz4StreamingEdgeTest 边界语义源)+ scripts/probe_overlap.c(overlap-shrink 差分),均重编译运行验证与报告值一致)
- [x] ~~design.md §4.3 "默认 0" 措辞精确化:`offset!` 实为必传具名参数,无默认值~~(M3b-T1 文档批次;注:台账原记"规则 2",实际位于 §4.3 规则 3)
- [x] ~~`compress_fast_continue` 输入/字典重叠收缩分支体~~(M7-T1:lz4StreamOverlapShrinkTest 重放 probe pass2 几何,c=20106/xxh=55883273 钉值 + 64KB 窗解码闭合;probe 扩展 pass3 钉 <4 丢弃出处)
- [x] ~~lz4hc.cj 可达未覆盖行~~(M7-T2:翻转 12 行 = 四处 encodeSequence 出口 834-839/854-855(_Search3 sweep 400+ 组合)+ MID 钳制 1358 + opt 钳制 1739(fillOverflowClamp)+ overlap<4 丢弃 2372-2373(白盒状态断言);残行 22 裁定:L807/873-874/909-911 代数不可达(guard 条件在 s≥3 ∧ m2>m1 下恒假,含 _Search3 再迭代路径)、906-915/881-886/925-930 经验不可达(全量插桩 11008 状态零命中 m3>m2>s 情态 + 三组手工级联几何未触达)、L1046 上游结构性死代码(唯一调用方传 iLowLimit=ip)、L1629 改价恒平价代数 + 132 次专项扫描零触发 —— 证据见任务报告)
- [x] ~~lz4frame.cj 可达未覆盖行~~(M7-T1:换型分支 9 行 = 8 帧交替序列 + 白盒 None 臂穷举证明与输出等价断言 + ctx_swap_probe.c 钉值;紧容量 3 行 = 错误契约直接断言(bs5 几何过首守卫/cap∈[4,7] 过 endmark);M7-T4:l912 滞留迁移 = af0 1MB 流式长链;残行 = 块压缩器 None 兜底等 9 防御类,不变)
- [x] ~~lz4frame_decode.cj 可达未覆盖行~~(M7-T3:容量保全 8 行 = bs4 三满块累计 196608 恰满 maxBufferSize + 新缓冲终块直解(插桩钉值 dsz=196608/dst=30000/max=196608);copySize 钳制 = af-flush 双小块 + 容量 b1+7;顺带 join 族 3 子钳制(423/426/465)多缓冲变体;>1GB 截尾 2 行 = 本机内存裁定(3GB 总/~1GB 可用,C 同构保留);残 10 行防御类)
- [x] ~~M5 fuzzFrameCase LCG 连续奇偶锁定残余~~(M7-T5:nibble 位抽取 + ss/rawCoin 奇模数,M6 范式对齐)
- [x] ~~cjcov 覆盖快照漂移~~(M7-T6 调查关闭:同 commit 背靠背双跑 hit/total/未覆盖集全同 = 会话内完全确定;跨会话/跨构建总行数漂移(字节相同文件 627→632)= gcov 行归因的构建期差异,与覆盖行为无关;里程碑门禁沿用同会话口径即可)
- [x] ~~GC 陈旧读现象调查~~(M7-T6 关闭:最小复现程序 scripts/gc_stale_repro.cj(16MB×2 数组 + 交错索引比较 + 分配压)双工具链 10 轮(LTS×9/STS×1)零 transient/persistent 观测 = 未复现;现象不再现,缓解注释保留,如复发以该程序为起点)
- [ ] virgin-attach(dictCtx 前缀为空)→ noDictCtx 回退(lz4hc.cj L1988-1992):上游该路径 NULL 解引用为 UB/崩溃,仓颉防御性回退不复刻,输出无对照基准 —— 裁定登记(CHANGELOG 0.5.0 已归类)
- [x] ~~RDG_genBuffer 等 unused 警告~~(M8 裁定:-Woff unused/parser 抑制 + 归类登记,库源码零改动;见 CHANGELOG 0.9.0)
- [x] ~~fast 解压路径 0.85x 复评~~(M7-T5:bench_probe/benchAllTest 同机同轮 best-of-3,0.85x 不可复现 —— 实测全面比值 0.02-0.6x(字面密集 safe 解压 0.024x),与同轮 perf-smoke 交叉一致;判定差距结构性(安全层/GC/调用开销 vs C 裸内存+SIMD),M7 不做单点微调,基线表入 CHANGELOG,整体评估留 M8 按 §2.2 条款)
- [x] ~~CHANGELOG M3a 计时笔误~~(0.3.1 条目修正)
- [x] ~~wildCopy8 do-while 语义审计~~(M3a T3 审结:调用点等价,helper 已对齐上游)

## 待决事项

- 中心仓接入(M8 裁定暂不;需求出现时补 cangjie-repo.toml + 发布流程)
- ~/lz4 的 v1.10.0 worktree 是否常设保留(默认不留,按需 `git worktree add` 重建;见"基线"节命令)
- 帧格式 multithread(numThreads)上游此版本未暴露,无需决策;XXH64 对外暴露与否(M1 定为暂不,如需求出现重议)

## 下一步

路线图全部完成(M0-M8)。可选后续:中心仓发布、lz4file API 增补(§4.6 裁剪项)、上游同步(dev > 0774d055 时)。
