# Changelog

## 0.1.0 (M0+M1)

- cjpm 静态库工程,双工具链(LTS-1.0.5 / STS-1.2.0)构建与测试脚本
- XXH32 / XXH64:one-shot + 流式 state,官方向量 + C 交叉验证
- datagen:输出兼容的可复现语料生成器(192 组摘要交叉验证)

## 0.2.0 (M2)

- 一站式块压缩 API:`LZ4_compress_default` / `LZ4_compress_fast` / `LZ4_compress_fast_extState` / `LZ4_compress_fast_extState_fastReset` / `LZ4_compress_destSize`(元组返回 `(size, consumed)`);配套 `LZ4_compressBound` 与流状态原语(`LZ4_stream_t` / `LZ4_sizeofState` / `LZ4_initStream`)
- golden 验证:256 行清单(8 尺寸 × 4 mp × 2 seed × 4 模式,`corpus/block_golden_ref.txt` + `corpus/block/` artifact)+ 125 行对抗性 destSize 缩减用例(常量/周期/LCG 缓冲小目标,强制 matchCode 缩短路径);字节级精确比对 222 个 artifact(常规 162 + dest 60),consumed 精确 64/64;对抗用例可由 `scripts/dest_probe.c` 对上游 C 重编译再生,与 `src/lz4_test.cj` 内嵌常量逐行一致
- 覆盖率(cangjie-1.0.5,`cjcov --html-details`):总体行覆盖 95.8%(1050/1096);库源码(common/datagen/lz4/xxhash)97.7%(648/663),其中 lz4.cj 94.9%(281/296)、其余三个库文件 100%;lz4.cj 15 个未覆盖行均为防御/罕见分支:fillOutput 回退哈希清除子路径 L1204-1215(对抗用例未触达 `ip <= filledIp`)、limitedOutput 中途溢出失败返回 ×2(L1123-1126/L1219)、srcSize 越界拒绝(L1369)、acceleration 上限钳制(L1396)、destSize 委托常规路径的失败兜底(实际不可达)
- 双工具链全绿:LTS-1.0.5 与 STS-1.2.0 各 21/21 测试通过
