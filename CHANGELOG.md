# Changelog

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
