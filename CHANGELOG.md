# Changelog

## 0.4.0 (M3b)

- 流式压缩全家 API(设计 §4.5 流式压缩 10 函数全量 + 补记项):`LZ4_createStream` / `LZ4_freeStream` / `LZ4_resetStream` / `LZ4_resetStream_fast` / `LZ4_loadDict` / `LZ4_loadDictSlow` / `LZ4_attach_dictionary` / `LZ4_compress_fast_continue` / `LZ4_saveDict`,以及 M2 清单漏记、台账裁决纳入的 `LZ4_compress_destSize_extState`(元组返回);`LZ4_stream_t` 字典区以 (dictBuf/dictStartIdx/dictSize) 引用对落地(不拷贝,与 C 生命周期契约一致;saveDict 为唯一拷贝点),`LZ4_prepareTable` 真实表保留语义取代清表(fastReset 由此真实化)
- 压缩核心扩展为四字典模式:noDict 不变 + withPrefix64k / usingExtDict / usingDictCtx(attach 的两条路径:>4KB 整态拷贝走 extDict、≤4KB 走 dictCtx 咨询);跨段匹配计数 `LZ4_count2`、`lz4RenormDictT`(>2GB 表重整,按上游保留)
- 签名偏离登记(设计 §4.3 规则 4 扩展):`LZ4_compress_fast_continue` 取 `(srcBuf, srcIdx: Int64)` 位置对(块源可在缓冲任意位置,extdict 双缓冲 zig-zag 等 golden 几何必需);C 侧 `dictEnd == source` 指针相等分派以 `lz4SameBuffer` 原始地址(分配同一性)判定实现(瞬态哨兵写-读-复原探针;单线程契约下与 C 指针语义严格一致,强于 M3a 解压侧的内容窗口谓词——内容判定在 savedict/extdict 场景会产生错误状态演化,已由 golden 排除)
- golden 验证(清单扩至 356 行,+46):cont 7(+cont0 1:新鲜 continue 走 byU32 与 one-shot default 的 byU16 合法分歧锚点,c=20143 vs 19452 双录)+ savedict 6(ret 40960 历史受限 / 65536 64KB 截顶 + 迁移后续块仍逐字节一致)+ dictfast 8 / dictslow 8(64KB 字典 RDG 仓颉侧再生,xxh 钉值;含输入即字典自身前缀的流式 RDG 行)+ attach 4(dictCtx 咨询 / 整表拷贝两路径,分支经调用后状态钉住)+ extdict 6(双缓冲 zig-zag,位置对表达跨缓冲块源)+ destext 6(共享状态,委托行 c/consumed 精确且 == default 交叉验证、fillOutput 行 (size, consumed) 精确、每次调用后状态干净钉住——漏掉出口 initStream 即后续行失败);另 fastreset 10 行(M3b-T1,同流双块场景 + off=/tt= 状态钉住)
- 闭环往返 + 边界:cont/savedict/extdict 几何滚动解码闭合(与 `LZ4_decompress_safe_continue` 互为镜像);dict/attach 20 例 `decompress_safe_usingDict` 还原;边界 C 探针钉值(紧容量 → 0 且破坏流、saveDict fresh/0/-1 → 0、1000B 历史 → 1000 + 内容、loadDict <HASH_UNIT → 0 但先 reset+64KB 增量、attach 空字典回退 == 裸 continue 逐字节)
- 探针入库(台账义务):`scripts/span_probe.c`(M3a extDict 跨界拷贝探针重建,对上游 0774d055 重编译 14/14 一致)+ `scripts/edge_probe.c`(边界语义源)+ `scripts/probe_overlap.c`(overlap-shrink 差分:pass2 c=20106 xxh=55883273 + 解码闭合,仓颉侧逐字节一致)
- 覆盖率(cangjie-1.0.5,`cjcov --html-details`):总体行覆盖 96.1%(3745/3898);库源码 96.81%(1366/1411),其中 common/datagen/xxhash 100%、lz4.cj 95.5%(949/994);lz4.cj 45 个未覆盖行:fillOutput 回退哈希清除 L329-333/L618-622(对抗用例未触达)、usingDictCtx test-next 候选二解析 L663-670(attach 用例每位置直接命中,未走 miss 分支)、dispatch 尺寸守卫与 destSize 委托失败兜底 L755/L855(防御/不可达)、acceleration 钳制 L782/L1109/L1112(防御,C 契约钳制)、lz4RenormDictT L930-945(>2GB 表重整,未覆盖——触发是 U32 currentOffset 累加,需单状态 >2GB 流量方可达,非 64 位不可达;按上游保留)、loadDict >64KB 截尾 L972(golden 字典恒 64KB)、重叠收缩分支体 L1147-1154(**可达**,C 差分已验但未入套件,台账登记 M7 补)、fast 循环 partial+extDict 钳制 L1447-1450(结构性不可达,上游同冗余)、滚动窗口谓词失配/None L1903/L1945(公 API 不可达)
- 文档:design.md §4.3 规则 4 扩展至压缩侧(位置对 + lz4SameBuffer 等价性说明)、§4.4 字典引用对字段状态、§4.5 流式压缩行状态;docs/progress.md 首次按新维护规则更新(M3b 行 + 台账勾销 2 项/关闭 1 项/新登记 1 项)
- 双工具链全绿:LTS-1.0.5 与 STS-1.2.0 各 57/57 测试通过

## 0.3.1(基线确证)

- 移植基线显式化并实证:上游 dev commit `0774d055`(2026-06-01)= v1.10.0 发布线之上的官方修复线(dev 版本宏自报 1.10.0)。以 v1.10.0(tag ebb370ca)独立 worktree 重编 golden harness 重跑全矩阵:manifest 304/304 行、artifacts 264/264、partial 探针(解压合法输入)全部逐字节一致——**压缩输出与 v1.10.0 完全等价**;解压侧保留其后官方修复(read_variable_length OOB 读修复、快/慢循环 ip/iend 边界修复、match length limit 修复),损坏输入行为较 v1.10.0 更严格(v1.10.0 该处为 OOB 读未定义行为,不在仓颉复刻)。HC/frame 后续里程碑按同一 commit 移植
- 新增 `docs/progress.md` 进度追踪文件(完成态证据、剩余工作分解、遗留事项台账、待决事项),每里程碑收尾更新
- 修正:M3a 套件计时为 LTS 8.7s / STS 8.9s(此前一处记录误写 12.9s/10.4s)

## 0.3.0 (M3a)

- 块解压全家族 API:`LZ4_decompress_safe` / `LZ4_decompress_safe_partial`(target 提前停止语义)/ `LZ4_decompress_safe_usingDict` / `LZ4_decompress_safe_partial_usingDict`(外部字典,分离数组模型下恒 forceExtDict 实例化;dictSize 越界防御性 -1)+ 流式解码状态族 `LZ4_createStreamDecode` / `LZ4_freeStreamDecode` / `LZ4_setStreamDecode` / `LZ4_decoderRingBufferSize` / `LZ4_decompress_safe_continue`(dest 以 (dstBuf, dstIdx) 位置对表达滚动契约;C 指针相等判定以"滚动窗口内容等价"谓词替代,作用域已限定并登记设计 §4.3 规则 4)。内部 `LZ4_decompress_generic` 双循环(safe 状态机 + fast 捷径,分派点 FASTLOOP_SAFE_DISTANCE 与上游一致;`LZ4_decompress_generic_forced` 测试钩子可强制两路)
- golden 验证(清单 v2,300 行 = 264 块行 + 16 dict 行 + 8 stream + 10 ring + 2 setdict):解压侧 206 个 artifact 逐字节还原 + 16 空artifact→-1;dict 14 字节精确 + 2 摘要行;partial 探针 20 行(含 5 dict-partial,目标 {0,1,n/2,n-1,n});stream/ring/setdict 滚动解码逐字节 + 累计前缀摘要闭合;ring 覆盖 64KB 边界毕业(smallPrefix→withPrefix64k)与回绕换向(forceExtDict→doubleDict)
- 差分验证(T3):280 清单行 + 531 随机(mp×尺寸扫描)+ 20 extDict 合成流 + 20 withPrefix64k 合成流 + 40 随机 partial,forced-safe 与 forced-fast 返回值与字节全一致;100 损坏输入双向一致(双负或同正同字节)。新增对抗用例:extDict 跨界 match 拷贝(字典尾→块内,C 探针钉值:fast/safe 双循环 + partial 钳制 + -2/-6 错误码)
- 模糊测试(T5,`src/fuzz_test.cj`):`fuzzDecompressTest` 2000 种子 × (safe + partial 双路),变换 = 无变换(逐字节往返)/ 1-8 位翻转 / 截断 1-16 / 偏移字段篡改 / 随机垃圾;不变量:无异常逃逸、返回值二值化(负或 ≤ 容量)、负值满足 -(ip)-1 位置编码界、无变换时逐字节精确。`fuzzContinueTest` 200 种子 × 3-6 块流式序列(线性/环形布局含回绕),中途损坏 → 干净前缀传播逐字节精确、损坏块负值或 ≤ 块长、错误后不复用状态。全套件 LTS 12.9s / STS 10.4s,未触发 60s 降级阈值
- 覆盖率(cangjie-1.0.5,`cjcov --html-details`):总体行覆盖 96.3%(2711/2816);库源码 98.35%(1075/1093),其中 lz4.cj 97.3%(658/676)、common/datagen/xxhash 100%;lz4.cj 18 个未覆盖行均为防御/不可达分支:fillOutput 回退哈希清除 L198-202/L370-374(对抗用例未触达)、limitedOutput 中途溢出 ×2(L311/L479)、acceleration 上限钳制(L501)、destSize 委托失败兜底(L562,不可达)、fast 循环 partial+extDict 钳制(L787-790,结构性不可达:近端 match 已分流 safe 段,上游同冗余)、滚动窗口谓词失配出口与 None 分支(L1243/L1285,公 API 不可达)
- 杂项:perf 冒烟注释与实际轮数对齐(best-of-2);`LZ4_SKIP_PERF` 环境变量可跳过 ~1.5GB 解压冒烟(默认运行);gen_golden.c ring 注释散文清理;streamSourceBuffer RDG 生成提出循环;setStreamDecode 冗余空分支合并
- 双工具链全绿:LTS-1.0.5 与 STS-1.2.0 各 44/44 测试通过

## 0.1.0 (M0+M1)

- cjpm 静态库工程,双工具链(LTS-1.0.5 / STS-1.2.0)构建与测试脚本
- XXH32 / XXH64:one-shot + 流式 state,官方向量 + C 交叉验证
- datagen:输出兼容的可复现语料生成器(192 组摘要交叉验证)

## 0.2.0 (M2)

- 一站式块压缩 API:`LZ4_compress_default` / `LZ4_compress_fast` / `LZ4_compress_fast_extState` / `LZ4_compress_fast_extState_fastReset` / `LZ4_compress_destSize`(元组返回 `(size, consumed)`);配套 `LZ4_compressBound` 与流状态原语(`LZ4_stream_t` / `LZ4_sizeofState` / `LZ4_initStream`)
- golden 验证:256 行清单(8 尺寸 × 4 mp × 2 seed × 4 模式,`corpus/block_golden_ref.txt` + `corpus/block/` artifact)+ 125 行对抗性 destSize 缩减用例(常量/周期/LCG 缓冲小目标,强制 matchCode 缩短路径);字节级精确比对 222 个 artifact(常规 162 + dest 60),consumed 精确 64/64;对抗用例可由 `scripts/dest_probe.c` 对上游 C 重编译再生,与 `src/lz4_test.cj` 内嵌常量逐行一致
- 覆盖率(cangjie-1.0.5,`cjcov --html-details`):总体行覆盖 95.8%(1050/1096);库源码(common/datagen/lz4/xxhash)97.7%(648/663),其中 lz4.cj 94.9%(281/296)、其余三个库文件 100%;lz4.cj 15 个未覆盖行均为防御/罕见分支:fillOutput 回退哈希清除子路径 L1204-1215(对抗用例未触达 `ip <= filledIp`)、limitedOutput 中途溢出失败返回 ×2(L1123-1126/L1219)、srcSize 越界拒绝(L1369)、acceleration 上限钳制(L1396)、destSize 委托常规路径的失败兜底(实际不可达)
- 双工具链全绿:LTS-1.0.5 与 STS-1.2.0 各 21/21 测试通过
