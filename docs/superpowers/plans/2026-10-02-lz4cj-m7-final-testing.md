# lz4cj M7 实现计划(收尾测试:定向覆盖 + >256KB 运行时矩阵 + fuzz 加压 + bench + 两项调查)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 清空三文件(lz4hc.cj / lz4frame.cj / lz4frame_decode.cj)+ lz4.cj overlap-shrink 的全部**可达**未覆盖行,补齐设计 §8.2 最后一行(>256KB 运行时往返 + C 侧哈希钉值,不入库),fuzz 加压(含压缩侧 LCG 奇偶锁修复),新建 bench 并复评 fast 解压 0.85x,完成 cjcov 快照漂移与 GC 陈旧读两项调查,双工具链全绿 + 文档收尾。

**Architecture:** 不改库公开 API(纯测试侧里程碑;仅当 bench 复评确认劣化时允许 common.cj 热路径等价优化)。所有新增期望值来源:①既有 C 探针钉值(probe_overlap pass2 c=20106/xxh=55883273);②新 C 探针(换型 ctx 交替、>256KB large 矩阵、_Search3 代表几何)对上游 0774d055 编译产出后嵌入常量;③API 契约错误码直接断言。>1GB 截尾行因本机内存(3GB 总 / ~1GB 可用)不可测 → 裁定登记。golden 清单 manifest 门检数字不变(489 数据行;>256KB 行按设计"不入库"以运行时探针承载)。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm + cjcov、cc(C 探针,~/lz4@0774d055)、std.unittest。

**Spec:** `docs/design.md`(§6.3 bench、§8.1 L4、§8.2 参数矩阵含 >256KB 行、§8.3、§10 M7 行)。关联:`docs/progress.md` L32(M7 分解)与遗留台账 L41/42/43/44/45/46/47/50。

## Global Constraints

- 同一套源码在 LTS-1.0.5 与 STS-1.2.0 下编译、测试全绿;每任务收尾 `scripts/build_and_test.sh both`;不得移除 `--int-overflow=wrapping -O2`。
- 上游参照 `~/lz4`(commit 0774d055)。新 C 探针脚本入库 scripts/,编译命令照 probe_overlap.c 头注格式(`cc -O2 -I$HOME/lz4/lib -I$HOME/lz4/tests ...`),运行验证后才嵌入常量。
- 未覆盖行行号为 2026-10-02 M6 收官快照(cov_html_m6)复核值;若执行中行号漂移,按语义(注释中的上游行锚)重新对位。
- 新测试断言失败信息带场景标识(沿 M5/M6 缓解模式:大数组比对失败打印行号;GC 陈旧读台账 #47 遗留,失败先复读一次再判)。
- 套件时长预算:LTS 全量(当前 141 测试 ~22s)新增后 ≤ ~50s;超预算时收缩 fuzz 种子增量,不收缩定向用例。
- 提交信息 `M7: ...` 前缀;每任务收尾勾选本计划;main 直提交流程(M0-M6 既定)。
- 最终验收(设计 §10 M7):全部测试双绿;golden ≥ 200 用例(现 489 数据行,已满足;本里程碑新增为运行时探针行)。

---

### Task 1: 压缩侧定向覆盖 —— lz4.cj overlap-shrink 套件钉值 + lz4frame.cj 换型分支与紧容量错误

**Files:** src/lz4_test.cj(追加)、src/lz4frame_test.cj(追加)、scripts/ctx_swap_probe.c(新)

**Interfaces:**
- Consumes: `scripts/probe_overlap.c`(pass2 钉值 c=20106 xxh32=55883273);lz4_test.cj 既有 cont 节几何代码(RDG seeds 501/502/503,7 滚动块);lz4frame.cj `LZ4F_compressBegin/Update/End/uncompressedUpdate/compressFrame_usingCDict/createCDict`、错误常量 `LZ4F_ERROR_dstMaxSize_tooSmall` 族
- Produces: 测试 `lz4StreamOverlapShrinkTest`、`lz4fCtxTypeSwapTest`、`lz4fTightCapacityErrorTest`;C 探针 `scripts/ctx_swap_probe.c`(可复跑再生钉值)

**覆盖目标:** lz4.cj L1179-1181/1183-1184/1186(overlap-shrink 分支体 6 行);lz4frame.cj L475/482-485/487-490(换型 Some/None 臂 9 行)、L836(uncompressedUpdate 容量守卫)、L1025(compressEnd 尾区)、L1076(usingCDict 界限)。

- [x] **Step 1: `lz4StreamOverlapShrinkTest`**(lz4_test.cj,RED 先行)
  - 几何照 probe_overlap.c 逐字重放:单缓冲 buf = RDG(122880,0.50,0.0,501) + RDG(122880,0.90,0.0,502) + RDG(16384,0.50,0.0,503)(总 262144);`LZ4_createStream` + 7 次 `LZ4_compress_fast_continue`(k<6:srcIdx=k*40960 size 40960;k=6:srcIdx=245760 size 16384;accel=1)——与 golden cont 节相同的 pass1;
  - pass2:`LZ4_compress_fast_continue(buf, srcIdx=0, 40960)`(源与累计字典重叠 → 触发收缩分支体)→ 断言 `c == 20106` 且 `XXH32(out, c, 0) == 0x55883273`(CHANGELOG 0.4.0/probe_overlap.c 双源钉值);
  - 解码闭合:`LZ4_decompress_safe_usingDict(out, c → 40960, 字典 = buf[196608..262144) 的 65536 字节副本)` 输出 == buf[0..40960) 逐字节;
  - 先在本地重编译运行 scripts/probe_overlap 确认钉值仍一致(cc 命令见其头注)。
- [x] **Step 2: `lz4fCtxTypeSwapTest`**(lz4frame_test.cj)
  - 新 C 探针 scripts/ctx_swap_probe.c:单 cctx,循环 [Begin(lv=0) → Update(A,65536) → End; Begin(lv=9) → Update(A) → End] × 2(A = RDG(65536,0.50,0.0,0);prefs bm=linked bs=4 raw,af=0),打印 4 帧 size + XXH32 + XXH64;同几何 fresh cctx 单帧对照打印(验证 C 语义 = 复用等价);编译运行取值;
  - 仓颉侧重放同序列:断言 4 帧 size/XXH32(XXH64) == 探针钉值;断言每次交替帧 == fresh cctx 同参数帧逐字节(状态重用输出等价);
  - 状态断言:两次交替后 `cctx.lz4CtxFast != None && cctx.lz4CtxHC != None`(这正是 Some 臂执行的证据;None-HC 臂由 Begin(lv=0)→Begin(lv=9) 序列覆盖)。
- [x] **Step 3: `lz4fTightCapacityErrorTest`**(lz4frame_test.cj;三行错误契约,API 契约直接断言)
  - L836:bm=1 cctx,Begin 后 `LZ4F_uncompressedUpdate(dst 容量 = srcSize-1, src 65536)` → 断言返回 isError 且 getErrorCode == -LZ4F_ERROR_dstMaxSize_tooSmall 对应码(与 M5 既有错误断言写法一致);同调用容量 = srcSize → 成功;
  - L1025:ccs=1 cctx,Begin + Update 后 `LZ4F_compressEnd(dst 容量 = 3)`(< endmark 4 + ccs 4)→ 同错误码;容量 = 8 → 成功;
  - L1076:`LZ4F_compressFrame_usingCDict(dst 容量 = compressFrameBound-1)` → 同错误码;容量 = bound → 成功。
- [x] **Step 4: 覆盖复查 + GREEN + Commit**:LTS `cjpm test --coverage` + cjcov 确认 13 行全转覆盖(漂移按语义对位);`scripts/build_and_test.sh both` 双绿;Commit `M7: compression-side targeted coverage - overlap-shrink pin, ctx type swap, tight-capacity errors`

---

### Task 2: HC 难达行定向 —— _Search3 扫描 + countBack + fillOutput 钳制 + 改价 + overlap<4 丢弃

**Files:** src/lz4hc_test.cj(追加)、scripts/hc_search3_probe.c(新)

**Interfaces:**
- Consumes: `LZ4_compress_HC_destSize`(元组返回)、`LZ4_compress_HC_continue_destSize`、`LZ4_loadDictHC`、`LZ4_attach_HC_dictionary`、`LZ4_decompress_safe`/`_usingDict`;lz4hc_test.cj 既有 destSize/流式几何先例(fuzz destSize 抽查块、hcdestcont 行)
- Produces: 测试 `lz4hcSearch3SweepTest`、`lz4hcFillOverflowClampTest`、`lz4hcDictCtxCountBackTest`、`lz4hcOptLiteralRepriceTest`、`lz4hcOverlapShrinkTest`;C 探针 `scripts/hc_search3_probe.c`

**覆盖目标:** lz4hc.cj L807/834-837/839/854-855/873-874/881-884/886/906-915/925-928/930(_Search3 合并校正 + 四处 fillOutput 出口,28 行)、L1046(dictCtx countBack)、L1358(MID 钳制)、L1739(hashChain 钳制)、L1629(opt 字面量改价)、L2372-2373(HC overlap<4 丢弃)。

- [x] **Step 1: `lz4hcSearch3SweepTest`**(参数扫描,解码闭合自证)
  - 合成输入族 F(每件 65536 字节):p ∈ {5,17,63,255} 周期重复,每 97 字节 1 字节文字变异(打破完全周期);双周期交错(p1 段/p2 段交替,段长 512);前导文字游程 L ∈ {1,5,33} 后接周期 p;三层几何 A(64)B(64)AB + 长尾 C;
  - 每输入 × lv ∈ {4,9} × `LZ4_compress_HC_destSize` tg ∈ {c0/8, c0/4, c0/2, 3*c0/4, c0-1}(c0 = notLimited 实测值)→ 断言:size ≤ tg、consumed ≤ n、`LZ4_decompress_safe(out) == src[0..consumed)` 逐字节;
  - 流式变体:2-4 连续块第二块 `LZ4_compress_HC_continue_destSize` 同 tg 阶梯(逼 _Search3 出口在 continue 路径出现);
  - 本测试以扫描组合数(≥ 5 输入 × 2 lv × 5 tg × 2 路径 = 100 组合)概率覆盖 28 行,以 cjcov 复查为准;未命中行按未覆盖行注释语义加构造(如 L873-874 需 correction 把 m2.len 压到 <4 → 用 p=5 短周期 + 紧 tg 迫使 correction)。
- [x] **Step 2: `lz4hcFillOverflowClampTest`**(钳制两行)
  - 输入 131072 全零 + 输入 131072 周期 4(0x00-0x03):各 × lv ∈ {1(MID→L1358), 4, 9(hashChain→L1739)} × tg ∈ {64, 100, 128, 256} → destSize 断言同上(巨型 match + 紧输出 → ovml/matchLength > maxMlSize 钳制);
  - 解码闭合用 usingDict 窗口(src 前缀 65536 副本)当 consumed < n。
- [x] **Step 3: `lz4hcDictCtxCountBackTest`**(L1046)
  - 构造:字典 D = 65536 字节 = RDG(65536,0.50,0.0,99);字典流 resetStreamHC(9) + loadDictHC(D);工作流 attach_HC_dictionary 后压缩块 B = 8 字节随机头 ‖ D[30000-4 .. 30000+200](使 ip=8 > iLowLimit 且匹配起点前 4 字节亦可回溯匹配 → countBack 实调用);
  - 断言:c > 0、`LZ4_decompress_safe_usingDict(B 长度, 字典 D)` 逐字节 == B、二次压缩逐字节确定;
  - scripts/hc_search3_probe.c 钉值:本几何 + Step 1 三个代表组合(p=17/lv9/tg=c0/4、双周期/lv4/tg=c0/2、三层/lv9/tg=3c0/4)对上游编译运行,打印 c + XXH32;仓颉侧断言同值(校正路径语义保真)。
- [x] **Step 4: `lz4hcOptLiteralRepriceTest`**(L1629,opt 改价)
  - 几何候选族 ×3(每个 65536):①64 字节随机块 ‖ 周期 11 重复 ‖ 200 随机 ‖ 周期 11 相位偏移 3;②字面量游程序列{1..7 交替}+ 短匹配(5-7 字节)散布;③RDG(0.85) 直放(lv10-12 扫 lv ∈ {10,11,12});断言 notLimited 往返 + 二次确定;cjcov 复查 L1629,未命中再迭代几何(改价条件:price < opt[pos].price 且 litlen<4,短匹配 + 长文字游程是高发区)。
- [x] **Step 5: `lz4hcOverlapShrinkTest`**(L2372-2373,HC 版 overlap<4 丢弃)
  - 单缓冲 buf 64 字节:`LZ4_loadDictHC(s, buf, 0, 8)`(字典 = buf[0..8))→ `LZ4_compress_HC_continue(s, buf, srcIdx=6, 50)`(源尾 56 越过 dictStart 0、srcIdx 6 < dictEnd 8 → 收缩后存活 2 字节 < LZ4HC_HASHSIZE=4 → 丢弃分支);
  - 断言:c > 0、解码(以 buf[0..8) 为字典,或安全余量下 standalone)输出 == buf[6..56) 前缀语义按 consumed、二次确定;对照非重叠调用(独立缓冲同内容)输出可异(状态差异)但各自闭环。
- [x] **Step 6: 覆盖复查 + GREEN + Commit**:cjcov 确认本任务 32 行全转覆盖;`scripts/build_and_test.sh both`;Commit `M7: HC targeted coverage - _Search3 sweep, countBack, fill clamps, reprice, overlap discard`

---

### Task 3: 解压侧定向 —— dictInTmp 容量保全 + flushOut copySize 钳制 + >1GB 截尾裁定

**Files:** src/lz4frame_test.cj(追加)、docs/progress.md(裁定登记)、CHANGELOG.md(归类,随 Task 6 一起收尾亦可先行登记)

**Interfaces:**
- Consumes: M6 `lz4fMultiBufferDecodeTest` 几何先验(part 4 多缓冲)、终审回归测试(字典前缀输出几何)、`LZ4F_decompress` 三元组、`LZ4F_decompress_usingDict`
- Produces: 测试 `lz4fDictInTmpPreserveTest`、`lz4fFlushOutCopyClampTest`;台账 #44 的 >1GB 截尾裁定记录

**覆盖目标:** lz4frame_decode.cj L410-417(updateDict dictInTmp 容量保全 8 行)、L997(flushOut 尾部保存 copySize 钳制);L491-492(>1GB 截尾)裁定不改码。

- [x] **Step 1: `lz4fDictInTmpPreserveTest`**(RED)
  - 帧输入:RDG(200000, 0.90, 0.0, 808),仓颉 `lz4fFdmpFrame` 成帧(bs=4, bm=0 linked, lv=0, af=0);
  - 解压几何:前 ~120000 字节阶段每次喂 src 1000 字节、dst 容量 1000(逼 flushOut 部分排空 + withinTmp updateDict,字典在 tmp 内累计超 64KB);随后切换 dst 容量为剩余全量(直解满块,dictInTmp && dictSize+… > maxBufferSize → 保全分支 410-417);
  - 断言:末次 ret==0、Σconsumed==size、输出 == 输入逐字节;参数(阶段切点 100000/120000/140000 × 小容量 1000/4000)扫描至 cjcov 命中;
  - 构造依据(台账 #44):"多段小容量冲刷 + 直解几何可扩 + 小块首块紧容量"。
- [x] **Step 2: `lz4fFlushOutCopyClampTest`**(L997)
  - 几何 = M6 终审回归 (a) 字典前缀输出几何的紧容量版:dst 缓冲 128KB,B[0..65536) = 字典副本、输出区起 dstIdx=65536;`LZ4F_decompress_usingDict`(dict = RDG(65536,0.50,0.0,99),帧 = 同字典前缀续压 65536 块,bs=4 bm=0);
  - 首调用 dst 容量 = 2000(紧 → flushOut 部分排空 + 尾部历史保存进入钳制路径:copySize = preserveSize 钳制与 C L2125 同构);次调用容量给足至完成;
  - 断言:输出拼接 == 帧内容、(code,0,0) 错误契约不触发、双几何(容量 2000 / 70000)输出一致;
  - RED 验证法:临时在 997 行前插计数打印(或 cjcov)确认命中后移除。
- [x] **Step 3: >1GB 截尾裁定(L491-492)**
  - 事实链:分支条件 dictSize > 1GB;本机 3GB 总内存 / ~1GB 可用,分配 >1GB Array<UInt8> 不可行(且与 8MB corpus 预算 / 套件时长冲突);
  - 裁定:登记为"可达但本机内存预算外,C 同构保留为防御性对照"(docs/progress.md 台账 #44 勾销措辞 + CHANGELOG 0.8.0 归类),不写测试;上游行为等价性由代码逐行对照注释(既有)背书。
- [x] **Step 4: 覆盖复查 + GREEN + Commit**:cjcov 确认 410-417/997 转覆盖(库文件可达未覆盖清零,除裁定行);`scripts/build_and_test.sh both`;Commit `M7: decode-side targeted coverage - dictInTmp preserve, flushOut copy clamp, 1GB ruling`

---

### Task 4: >256KB 运行时矩阵 —— large_probe.c + src/large_test.cj(设计 §8.2 最后一行)

**Files:** scripts/large_probe.c(新)、src/large_test.cj(新)

**Interfaces:**
- Consumes: `RDG_genBuffer`(仓颉 datagen.cj:116 与 C 同序列)、block/HC/frame 全部公开压缩族 + 解压闭环族、Task 1 的错误断言写法
- Produces: 测试 `lz4LargeBlockTest`、`lz4LargeHcTest`、`lz4LargeFrameTest`(同文件);C 探针钉值常量表 `LARGE_PROBE_REF`(嵌入 large_test.cj)

**覆盖目标:** 设计 §8.2 ">256KB 输入:运行时 datagen 生成,仅往返 + C 侧哈希比对(不入库)";顺带 lz4frame.cj L912(localSaveDict 滞留迁移:af=0 linked 流 >192KB 使 tmpIn 越界)。

- [x] **Step 1: C 探针 scripts/large_probe.c**
  - 输入(固定):L_A=RDG(300000,0.50,0.0,4242)、L_B=RDG(1048576,0.90,0.0,5353)、L_C=RDG(327680,0.00,0.0,6464)(不可压)、L_D=RDG(1048576,1.00,0.0,7575)(超高重复);
  - block 4 行:L_A default / L_A fast(8) / L_B destSize(tg=786432) / L_D default;
  - HC 6 行:L_A lv=2 / L_A lv=9 / L_B lv=12 / L_B lv=12 fav=1 / L_D lv=9 / HC continue:L_B 按 262144 × 4 连续块 loadDictHC 头(无)+ rolling `LZ4_compress_HC_continue`;
  - frame 一次性 6 行:L_A{bs4,bm0} / L_B{bs6,bm1,ccs1,bcs1,csz} / L_C{bs4,lv0} / L_D{bs7,bm0,af1} / L_B{lv12} / L_A{did=42,ccs1};
  - frame 流式 1 行(核心):L_B af=0 bm=0 bs=4 lv=0,Begin + Update 65536×15 + 16384 + 中途一次 flush + End(累计 1MB > 192KB → C L1106-1112 滞留迁移);
  - 每行打印 mode 标签 + c + XXH32 + XXH64;destSize 行另打印 consumed;编译运行(头注编译命令),核对外观合理性(如 L_C 行 ≈ 原样存储)后取值;
  - corpus 预算:本探针不入 manifest、不落 corpus(设计明定"不入库")。
- [x] **Step 2: src/large_test.cj(RED:先嵌占位 0 → 跑探针填真值)**
  - `LARGE_PROBE_REF: Array<(标签, mode 参数…, wantC, wantConsumed, want32, want64)>` 常量表;
  - `lz4LargeBlockTest`:重建 L_* 输入(RDG 同参)→ 各 mode 压缩 → size/consumed/XXH32/XXH64 全等断言 + `LZ4_decompress_safe` 闭环(destSize 行按 consumed 前缀;fast 行另做 `LZ4_decompress_safe` 往返);
  - `lz4LargeHcTest`:同上;continue 行用 `LZ4_decompress_safe_continue` 滚动闭环;
  - `lz4LargeFrameTest`:一次性行 `LZ4F_compressFrame` 族对参数成帧 → 哈希等 + `LZ4F_decompress` 整段闭环(Σ三元组校验);流式行手工链(与探针同切分)→ 哈希等 + 解压闭环;**断言 cctx.tmpBuff 复用路径无异常即隐含**(912 行由流式行覆盖,cjcov 复查);
  - 时长预算:压缩+解压 ~30MB IO,< 2s(LTS)。
- [x] **Step 3: GREEN + cjcov 确认 L912 转覆盖 + Commit** `M7: >256KB runtime matrix - large_probe.c C pinning + block/HC/frame roundtrip and hash tests`

---

### Task 5: fuzz 加压 + LCG 奇偶锁修复 + bench 新建与 0.85x 复评

**Files:** src/fuzz_test.cj(修改)、src/bench_test.cj(新)、scripts/bench_probe.c(新)、src/common.cj(仅当复评确认劣化)

**Interfaces:**
- Consumes: fuzzFrameDecodeCase L1089-1098 的修复范型(一字低 nibble 位抽取 + 奇模数);lz4DecompressPerfSmokeTest 的 LZ4_SKIP_PERF env 先例(std.env.getVariable)
- Produces: 修复后的 fuzzFrameCase 抽参;种子提升后的五个 fuzz 测试;`benchAllTest`(LZ4_SKIP_BENCH 可跳过,默认运行);scripts/bench_probe.c(吞吐对照)

- [x] **Step 1: LCG 修复(台账 #45)**:fuzz_test.cj fuzzFrameCase L761-768 的四参数连续 `r%2` 改为 M6 范型:一次 `fuzzLcgNext` 取 `nib = r % 16`,`bm = nib&1`、`ccs = (nib>>1)&1`、`bcs = (nib>>2)&1`、`af = (nib>>3)&1`;该函数内其余连续布尔抽取(如 ss)一并核查,奇模数化(`r % 3 == 0`);注释引用 fuzzFrameDecodeCase L1089 同源说明;既有确定性重放断言不变(×2 重放即自证)。
- [x] **Step 2: 种子提升**(fuzz 加压):fuzzDecompressTest 2000→3000、fuzzContinueTest 200→320、fuzzHcTest 300→420(opt 层加种子顺带加压 _Search3 概率)、fuzzFrameTest 120→240、fuzzFrameDecodeTest 150→300;更新各测试的打印统计行与派生计数器断言(如 hc 分层恰各 140);LTS 套件总时长 ≤ ~50s,超则回撤 decode 至 240 / decompress 至 2600(优先保 hc)。
- [x] **Step 3: scripts/bench_probe.c(C 对照)**:输入 4MB RDG(0.0/0.5/0.9/1.0 四件 × block;frame 另 bs4);测 `LZ4_compress_default` / `LZ4_decompress_safe` / `LZ4_decompress_fast`(仅 C 侧,仓颉无此 API,作对照基准)/ HC lv9/lv12 / frame 压缩/解压;best-of-3 计时打印 MB/s;头注编译命令。
- [x] **Step 4: src/bench_test.cj**:同输入同口径仓颉计时(MonoTime,先热身 1 轮 + best-of-3);重点场景:**字面量密集(RDG mp=0.0)的 safe 解压**与 mp=0.5/0.9 对照 —— 复评台账 #50 的 ~0.85x;env `LZ4_SKIP_BENCH=1` 跳过(默认运行,沿 LZ4_SKIP_PERF 模式);打印格式与 bench_probe.c 对齐(方便人工对照);不做断言门槛(设计 §6.3:非回归门槛)。
- [x] **Step 5: 0.85x 复评与决策**:双工具链各跑一次 benchAllTest + bench_probe.c,记录仓颉/C 比值表(写入任务执行记录,CHANGELOG 汇总);判定:字面量密集 safe 解压比值 ≥ 0.90 → 登记复核结论关闭台账 #50;< 0.90 → 热点优化候选 = LZ4_wildCopy32/LZ4_memcpy_using_offset 的 64 位步进改 128/256 位批拷(CPointer<UInt64> 多发并行展开;字节语义不变,由既有 golden/差分/全量测试兜底),优化后重跑 golden + 全量双绿 + 比值复测;优化不改公开 API 与调用契约。
- [x] **Step 6: GREEN + Commit** `M7: fuzz hardening - LCG parity fix, seed increases; bench harness + fast-decode re-evaluation`

---

### Task 6: 两项调查 + 覆盖率门禁 + 里程碑收尾

**Files:** scripts/gc_stale_repro.cj(新,独立编译不入包)、scripts/cjcov_drift_check.sh(新,可选)、docs/progress.md、docs/design.md、CHANGELOG.md、README.md

**Interfaces:**
- Consumes: 前五任务全部;report/cov_html_m6 基线数字(lz4frame.cj 473/499 等)
- Produces: 两项调查结论(台账 #46/#47 勾销)、M6 收官覆盖对照、文档三件套 M7 更新、gc_stale_repro 复现程序

- [x] **Step 1: cjcov 快照漂移调查(#46)**:同 commit、LTS 下连跑两次 `cjpm test --coverage` + `cjcov --html-details`(输出到 report/cov_html_m7a/m7b);提取 lz4frame.cj hit/total 与 cov_html_m6(473/499)三方对比;检查 cjcov_logs/gcov_parse.log 差异(行合并规则/注释行计数);结论二选一写入台账:①工具计数不稳定(并行测试执行序影响 *.gcov 合并)→ 记录幅度与规避(以多次众数为准);②真实覆盖变化 → 行级归因;无论哪种,勾销 #46。
- [x] **Step 2: GC 陈旧读最小复现(#47)**:scripts/gc_stale_repro.cj(单文件 main,`cjc scripts/gc_stale_repro.cj -o scripts/gc_stale_repro` 两工具链各编译):两 16MB 数组 a(模式 0xA5…)/b(模式 0x5A…),交错索引循环逐字节比对(期望恒 a 值),循环体内大量短命分配制造 GC 压力(若工具链暴露显式 GC 触发 API 则附加调用,双版本探测);失配即复读一次再判(区分真陈旧 vs 逻辑错);双工具链各 ≥ 10 轮;结论写入台账:复现(记录工具链/轮数/出现率,决定是否上报上游)或未复现(关闭,缓解注释保留);不修改库与测试。
- [x] **Step 3: 覆盖率门禁**:LTS 全量 `cjpm test --coverage` + cjcov --html-details → report/cov_html_m7;门槛:库源码行覆盖 ≥ 96.5%(基线 96.52%,本里程碑只增不减);三文件可达未覆盖行清零(T3 裁定的 491-492 除外,归类防御性登记);产出未覆盖行终版归类表(lz4.cj 既有 45 行分类不变 + 本里程碑裁定行)入 CHANGELOG。
- [x] **Step 4: 文档收尾**:progress.md(已完成表加 M7 行:证据数字 = 新增测试数/覆盖数/golden 探针行数/fuzz 种子/bench 比值;API 计数不变;剩余节仅留 M8;台账 #41/#42/#43/#44/#45/#46/#47/#50 勾销或裁定闭合;下一步 M8);CHANGELOG 0.8.0(定向覆盖清单 + >256KB 矩阵 + fuzz 加压与 LCG 修复 + bench 比值表 + 两项调查结论 + 覆盖率 + 双绿);README(测试计数、bench 使用法一节、性能比值一句话);design.md §10 M7 行勾选(若 §8.2 措辞需按"运行时探针承载 >256KB"精确化,一并订正)。
- [x] **Step 5: 全量门禁 + Commit** `scripts/build_and_test.sh both` 双绿;Commit `M7: investigations, coverage gate and milestone wrap-up`

---

## Self-Review 记录

- 规格覆盖:进度 L32 M7 三分解 → golden 全矩阵(T4 >256KB 行 + T1 紧容量/overlap 套件行)、fuzz 加压(T5)、bench 复评(T5);台账 #41(T1)、#42(T2+T5)、#43(T1 换型/紧容量 + T4 滞留迁移)、#44(T3 + 裁定)、#45(T5)、#46(T6)、#47(T6)、#50(T5);设计 §6.3 bench_test(T5)、§8.2 >256KB(T4)、§10 M7 验收(T6 Step 3/5:双绿 + golden ≥ 200 既满足)。换型 Some 臂的"输出等价已由 golden 钉住"(M5 台账语)指 fresh 帧等价 —— 本计划 T1 以 ctx_swap_probe 新钉交替帧,闭环。
- 类型一致性:所有新测试走既有公开/internal API 签名(位置对 (buf,idx)、destSize 元组、frame 三元组),无新库接口;探针脚本沿用 scripts/*.c 头注惯例。
- 占位扫描:无 TBD;两处"按 cjcov 复查迭代几何"(T2 Step 1/Step 4)为数据依赖路径,已给候选族与升级方向,非占位;>1GB 裁定为显式决策非延后(附事实链)。
- 已知风险:①_Search3 28 行纯几何触达是最大不确定项 —— 扫描组合 ≥100 + 阶梯 tg + 流式双路,并以未覆盖行语义逐条补救;若终有残行,按 M6 先例在台账登记具体行 + 构造思路,覆盖率门槛相应说明(不视为任务失败,视为发现);②lz4fDictInTmpPreserveTest 的阶段切点依赖 maxBufferSize 内部布局 —— 以参数扫描兜底;③bench 比值受机器噪声 —— best-of-3 + 双工具链各一次,结论以数量级判;④gc_stale_repro 若两工具链 API 分歧,以分配压方案为准并在脚本头注记录。

- 修订记录(2026-10-03 收官,内联执行——子代理配额于 T2 派发时耗尽,切换 executing-plans 模式):
  - T1 三处简报修正(HC-None 臂公开不可达穷举证明 → 白盒;L836 需 bs=5;L1025 需 cap∈[4,7])+ 两扩展(probe pass3、8 帧序列)
  - T2 残行 22 裁定:_Search3 校正族(807/873-874/909-911 代数不可达;906-915/881-886/925-930 经验不可达,11008 插桩状态零命中)、L1046 上游死代码、L1629 改价恒平价;maxBufferSize = maxBlockSize+128KB(简报 64KB 有误)由 T3 修正利用
  - T3 几何重推导(调用止点 getCBlock vs flushOut、帧完成自动 reset、调用预消费块头三陷阱)+ join 族 3 子钳制发现性补充
  - T4 lv12 帧分歧疑云 = 测试元组转录错位(非端口 bug,三路独立探针排查)
  - T5 0.85x 不可复现裁定(实测 0.02-0.6x 结构性差距,基线表入 CHANGELOG);bench_probe 弃 decompress_fast(上游弃用 API,ASAN 实证 OOB)
  - T6 两调查关闭: cjcov 会话内确定/跨构建行归因漂移;GC 陈旧读 10 轮零复现(程序入库)
  - 证据细节见 .superpowers/sdd/2026-10-02-lz4cj-m7-final-testing/task-{1..5}-report.md(git 忽略区,本修订记录为其库内摘要)
