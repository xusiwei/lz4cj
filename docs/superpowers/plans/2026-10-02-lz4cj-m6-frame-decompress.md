# lz4cj M6 实现计划(Frame 解压:dctx 全 API + 分片续传状态机 + getFrameInfo + skippable)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移植 lz4frame.c 解压侧全部 API(LZ4F_dctx 14-stage 分片续传状态机、decodeHeader、getFrameInfo、decompress/decompress_usingDict、headerSize、skippable 跳帧、块/内容校验和、帧拼接),对 C golden 帧解压逐字节等价 + hint 序列钉值(L3 双向),随机切分/损坏输入模糊零异常(L4),双工具链全绿。

**Architecture:** `LZ4F_dctx` 以类承载,`dict/tmpOut` 指针对 → `(Array<UInt8>, Int64 索引)` + `dictInTmp` 标记(C 指针同一性的等价物);C `dict+dictSize==ptr` 前缀连续判定 → M3a 内容窗口谓词(输出等价:假阳性 ⇒ 历史字节相同 ⇒ 解码输出相同;假阴性 ⇒ 走 join-into-tmp 拷贝路径,输出相同仅性能差异);状态机保持 C 单 `while(doAnotherStage)` + stage 分派结构,fall-through 以"同迭代顺序进入下一 stage 块"直译;块解码下沉 `LZ4_decompress_generic` 既有 (buf, idx) 模型(prefix/extDict 实例化择取为纯性能选择,输出不变式)。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm、cc(C golden/harness)、std.unittest。

**Spec:** `docs/design.md`(§4.3 规则 1/4、§4.5 frame 解压清单、§4.7、§5.5 解压状态机、§8.3、§10 M6 行、§11 R5)。关联:`docs/progress.md` M6 分解。

## Global Constraints

- 同一套源码在 LTS-1.0.5 与 STS-1.2.0 下编译、测试全绿;每任务收尾 `scripts/build_and_test.sh both`;不得移除 `--int-overflow=wrapping -O2`;frame 装配层以 `Array<UInt8>` 安全索引为主(§6.1),块解码经既有 unsafe 核心。
- API 命名与 lz4frame.h 逐字一致;`LZ4F_errorCode_t = Int64`(负值错误模式,§4.7);长度/返回一律 `Int64`(size_t)。
- **上游参照** `~/lz4`(commit 0774d055,`lib/lz4frame.c` 2167 行,解压侧 L1262-2167)。分段锚点:
  - L1266-1276 dStage_t 枚举(15 级:dstage_getFrameHeader=0, storeFrameHeader, init, getBlockHeader, storeBlockHeader, copyDirect, getBlockChecksum, getCBlock, storeCBlock, flushOut, getSuffix, storeSuffix, getSFrameSize, storeSFrameSize, skipSkippable=14);L1278-1299 dctx 结构;L1302-1341 create/freeDecompressionContext(free 返回 **dStage**;advanced 变体不移植);L1343-1350 dctx_size 不移植;L1354-1362 resetDecompressionContext(dict=NULL、dictSize=0、skipChecksum=0、frameRemainingSize=0、stage=getFrameHeader)
  - L1365-1464 decodeHeader:srcSize<7 → -12;**skippable 特判**(`readLE32 & 0xFFFFFFF0 == 0x184D2A50`;`src==dctx->header` 时 tmpInSize=srcSize/tmpInTarget=8/storeSFrameSize/返回 srcSize,否则 getSFrameSize/返回 4 —— 以 `srcIsHeader: Bool` 参数区分调用点);魔数校验 → -13;FLG 位提取(version≠1 → -6、保留位 → -8);BD(bsID<4 → -2、保留位 → -8);HC 字节 → -17;frameInfo 保存 + maxBlockSize=getBlockSize + csz LE64 → frameRemainingSize + did LE32 @ frameHeaderSize-5;stage=init;返回 frameHeaderSize。frameInfo 先整体清零(C MEM_INIT;含 blockSizeID=0 等全零,非 INIT 默认值)
  - L1471-1495 headerSize(srcSize<5 → -12;skippable → 8;魔数 → -13;7+csz*8+did*4);lz4frame.h L408 `LZ4F_MIN_SIZE_TO_KNOW_HEADER_LENGTH=5`
  - L1512-1551 getFrameInfo 三岔:dStage>storeFrameHeader → 不读输入(consumed=0、拷贝 frameInfo、返回值 = decompress(dctx, NULL, 0, NULL, 0, NULL) 的 hint);dStage==storeFrameHeader → -19 frameDecoding_alreadyStarted;否则 headerSize → srcSizePtr<hSize → -12 → decodeHeader → 成功 consumed=hSize、返回 BHSize=4(hint),错误 consumed=0;**frameInfo 无论如何都拷出**
  - L1558-1623 updateDict(仅 linked):五分支——dictSize==0 → dict=dstPtr;`dict+dictSize==dstPtr` 前缀延展;dst 内历史 ≥64KB → dict=dstBufferStart;withinTmp && dict==tmpOutBuffer → 延展;withinTmp(非 tmp)→ 拷入 tmpOut 前 preserveSize 区;dict==tmpOutBuffer(非 withinTmp)→ 容量钳制后 dst 内容拷至 dictSize 处;终局 join(dict 尾 64K-dstSize + dst 内容 → tmpOutBuffer 首)
  - L1644-2147 decompress 状态机(保真点见下);L2144-2146 出口三元组;L2149-2167 decompress_usingDict(`dStage <= dstage_init`(≤2)才注入 dict)
  - lz4frame.h L370-383 decompressOptions_t(stableDst/skipChecksums/reserved 省略)
- **API 清单订正(本计划 T1 落 design)**:上游 0774d055 的 lz4frame.h/lz4frame.c **不存在** `LZ4F_isSkippedFrame` 与 `LZ4F_decompress_usingCDict`(grep 全库证实;design §4.5 原清单误记)→ 移植清单订正为实际存在的 8 项:createDecompressionContext、freeDecompressionContext、resetDecompressionContext、headerSize、getFrameInfo、decompress、decompress_usingDict、isError/getErrorName/getErrorCode(复用) + getBlockSize(M5 已落地)。
- **dctx 状态模型 ruling**(§4.4 + §4.3 规则 4 延伸):

```
public class LZ4F_dctx {
    internal var frameInfo: LZ4F_frameInfo_t = LZ4F_frameInfo_t()
    internal var version: UInt32 = 0
    internal var dStage: Int32 = 0                        // dstage_* 常量族(0..14)
    internal var frameRemainingSize: UInt64 = 0
    internal var maxBlockSize: Int64 = 0
    internal var maxBufferSize: Int64 = 0
    internal var tmpIn: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})       // 空 = C NULL;dstage_init 分配 maxBlockSize+4
    internal var tmpInSize: Int64 = 0
    internal var tmpInTarget: Int64 = 0
    internal var tmpOutBuffer: Array<UInt8> = Array<UInt8>(0, {_ => 0u8}) // 空 = C NULL;分配 maxBlockSize + (linked?128KB:0)
    internal var dictBuf: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})      // C const BYTE* dict → 引用对
    internal var dictIdx: Int64 = 0
    internal var dictInTmp: Bool = false                   // dict 指向 tmpOutBuffer(C 指针同一性标记,每个赋值点同步)
    internal var dictSize: Int64 = 0
    internal var tmpOut: Int64 = 0                         // C BYTE* tmpOut → tmpOutBuffer 内索引
    internal var tmpOutSize: Int64 = 0
    internal var tmpOutStart: Int64 = 0
    internal var xxh: XXH32_state_t = XXH32_state_t()
    internal var blockChecksum: XXH32_state_t = XXH32_state_t()
    internal var skipChecksum: Int32 = 0
    internal var header: Array<UInt8> = Array<UInt8>(19, {_ => 0u8})      // LZ4F_HEADER_SIZE_MAX
}
```

- **指针语义翻译表**(评审对照):
  - `dict == NULL` ⇔ `dictBuf.size == 0`(空数组哨兵,usingDict 传空数组 + 0 等价 C NULL+0)
  - `dict == tmpOutBuffer` ⇔ `dictInTmp` 标记(updateDict/解码路径/尾部保存/usingDict/reset 全部赋值点同步置位)
  - `dict + dictSize == dstPtr`(updateDict 前缀判定)⇔ `dictBuf.size != 0 && !dictInTmp && dictIdx + dictSize == dstPos && 尾部 min(dictSize, 64KB) 内容窗口逐字节相等`(M3a 谓词;每次 O(64KB),每块一次,可忽略)
  - `dict + dictSize == tmpOut`(decode-directly 例外)⇔ `dictInTmp && dictIdx + dictSize == tmpOut`(纯内部索引,精确)
  - 尾部历史保存条件 `dict != tmpOutBuffer && dict != NULL` ⇔ `dictBuf.size != 0 && !dictInTmp`;stage 域检查 `(dStage)-2 < (getSuffix)-2` ⇔ `dStage >= 2 && dStage < 10`(init..flushOut)
  - 块解码实例化(纯性能选择,输出不变式——解码输出仅取决于历史字节):`dictBuf 空或 dictSize==0` → noDict(lowPrefixIdx=dstPos, dict=None);前缀连续(上方谓词)→ prefix 实例化(`lowPrefixIdx = dstPos - (dictSize >= 65535 ? 65536 : dictSize)`,dict=None,镜像 M3a rolling 分支钳制);否则 extDict(lowPrefixIdx=dstPos,dict=Some(dictBuf),dictStartIdx=dictIdx;**dictSize > 1GB 截尾**:dictIdx += dictSize-65536、dictSize=65536)。统一经 `LZ4_decompress_generic(srcArr, srcSize, dstArr, dstPos, maxBlockSize, false, lowPrefixIdx, dictOpt, dictStartIdx, dictSize)`(lz4.cj:1753 既有签名);返回 <0 → -16 decompressionFailed
  - dst NULL(C `dstBuffer==NULL, *dstSizePtr==0`)⇔ 空数组 + dstIdx=0 + dstCapacity=0;C 的全部 NULL 守卫在容量 0 算术下自然归零(sizeToCopy=0、dstPtr==dstEnd),无需特判——注释登记
- **错误契约**:C 在函数入口即置 `*srcSizePtr=0; *dstSizePtr=0`,RETURN_ERROR 直返 → 错误时三元组恒 `(errorCode, 0, 0)`,包括已部分消费/写出的调用——逐字复刻,测试钉住
- **保真度关键点**(评审对照,上游行锚):①错误三元组归零;②首调用 0 字节输入 → 返回 minFHSize=7 且 **dStage 不变**(L1686-1687 先于 storeFrameHeader);③storeFrameHeader hint = 剩余头 + BHSize;④skippable 双路(外源消费 4B + getSFrameSize;srcIsHeader 路径 tmpInSize=srcSize 怪癖)与 getSFrameSize 输入不足时 **tmpInSize=4**(header 已持魔数,L2069);⑤getBlockHeader 直读/storeBlockHeader 暂存于 **tmpIn**;⑥块头 0 → getSuffix;nextCBlockSize > maxBlockSize → -2;未压缩标志 → copyDirect + 块校验 state reset;⑦getCBlock 早退 hint(`dstPtr==dstEnd || srcPtr==srcEnd` → BHSize+nextCBlockSize+crcSize,L1784-1787);⑧块校验和:tmpInTarget -= 4 后 one-shot XXH32 覆盖 `[0, tmpInTarget)` 对比尾 LE32;⑨copyDirect 校验和覆盖**源**字节,getCBlock 覆盖**解码后**字节;⑩decode-directly 条件 `dst剩余 >= maxBlockSize && !(dictInTmp && dictIdx+dictSize==tmpOut)`;⑪decode-into-tmp 的 dict 布置(dict==tmpOutBuffer → >128KB 截尾至 64KB,tmpOut=dictSize;否则 tmpOut = min(dictSize,64KB));⑫flushOut 的 withinTmp=1 updateDict 与 hint=BHSize;⑬getSuffix:frameRemainingSize≠0 → -14 **先于** ccs 分支;无 ccs → hint=0 + reset + 停;⑭storeSuffix 暂存于 **tmpIn**、getBlockChecksum 暂存于 **header**(两处不同);⑮skipChecksum 置位粘滞至 reset;⑯尾部历史保存(L2112-2142)flushOut 特殊分支(preserveSize=tmpOut 索引、copySize=64K-tmpOutSize 钳制)与其余分支(min(dictSize,64K) 拷至 tmpOutBuffer 首、tmpOut=newDictSize);⑰帧完成自动 reset → 拼接续解;⑱XXH32 reset 仅 ccs 帧于 dstage_init;⑲状态机 fall-through(getFrameHeader→storeFrameHeader、init→getBlockHeader、getCBlock→storeCBlock、getSuffix→storeSuffix、getSFrameSize→storeSFrameSize)以"同迭代顺序进入下一 stage 块"直译,含 `if (dStage == dstage_storeX)` 可跳过式与 `if (0)` 式
- golden 约定:期望值嵌入测试常量(先例);fdmp 新节(14 行,见 T3);corpus 政策沿 M5(不入库,`scripts/gen_golden.sh` 再生;artifact 比对优雅降级);corpus ≤ 8MB(现 ~5.4MB,fdmp 不落 artifact)。
- 测试侧字节比对注意:全量套件高 GC 压力下大数组逐字节比较偶发陈旧读(台账 #44)——沿 M5 缓解模式(比对失败带行号打印;必要时摘要累加器承载),不改变断言语义。
- 提交信息 `M6: ...` 前缀;每任务收尾勾选本计划;最终任务更新 progress.md + CHANGELOG 0.7.0 + README;执行沿用 main 直提交流程(M0-M5 既定)。

---

### Task 1: lz4frame_decode.cj 骨架 —— dctx 生命周期 + headerSize + decompressOptions + design 订正

**Files:** src/lz4frame_decode.cj(新)、src/lz4frame_test.cj(追加)、docs/design.md

**Interfaces:**
- Produces:
  - `public struct LZ4F_decompressOptions_t`(`stableDst: UInt32 = 0`、`skipChecksums: UInt32 = 0`;reserved 省略,登记);`public init()`
  - `public const LZ4F_MIN_SIZE_TO_KNOW_HEADER_LENGTH: Int64 = 5`
  - dStage 常量族(internal Int32,成员名逐字):`dstage_getFrameHeader=0`、`dstage_storeFrameHeader=1`、`dstage_init=2`、`dstage_getBlockHeader=3`、`dstage_storeBlockHeader=4`、`dstage_copyDirect=5`、`dstage_getBlockChecksum=6`、`dstage_getCBlock=7`、`dstage_storeCBlock=8`、`dstage_flushOut=9`、`dstage_getSuffix=10`、`dstage_storeSuffix=11`、`dstage_getSFrameSize=12`、`dstage_storeSFrameSize=13`、`dstage_skipSkippable=14`
  - `public class LZ4F_dctx`(字段见 Global Constraints ruling)
  - `public func LZ4F_createDecompressionContext(version: UInt32): LZ4F_dctx`(C 出参 + errorCode → 直接返回实例;分配失败 GC 下不可达,注释登记;version 仅存字段,C 不校验)
  - `public func LZ4F_freeDecompressionContext(dctx: LZ4F_dctx): Int64`(返回 `Int64(dctx.dStage)`,C 语义"释放时的状态";C 可接受 NULL → 仓颉非空类型,N/A 注记)
  - `public func LZ4F_resetDecompressionContext(dctx: LZ4F_dctx): Unit`(L1354-1362 五字段复位;dictBuf 置空数组 + dictInTmp=false)
  - `public func LZ4F_headerSize(srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64): Int64`(L1471-1495;srcSize<5 → -12;`(readLE32(srcBuf,srcIdx) & 0xFFFFFFF0u32) == LZ4F_MAGIC_SKIPPABLE_START` → 8;魔数 ≠ → -13;`7 + (FLG>>3&1)*8 + (FLG&1)*4`)
- Consumes: lz4frame.cj 的 LZ4F_MAGICNUMBER/LZ4F_MAGIC_SKIPPABLE_START(Int32 常量已有)、lz4fReadLE32 等价物(common.cj LZ4_readLE32)
- 注:decodeHeader/getFrameInfo/decompress 属 T2(状态机依赖);本任务的 dctx 类仅供生命周期测试

- [x] **Step 1: 失败测试**(lz4frame_test.cj 追加 M6 节):
  - `lz4fDctxLifecycleTest`:create(100) → dStage==0、version==100、frameInfo 字段 == LZ4F_frameInfo_t() 默认、tmpIn.size==0、tmpOutBuffer.size==0、dictBuf.size==0、dictInTmp==false、skipChecksum==0、header.size==19;free == 0;reset 后(create → 手工置乱五字段 → reset)dStage==0、dictBuf.size==0、dictSize==0、skipChecksum==0、frameRemainingSize==0
  - `lz4fHeaderSizeTest`:构造头字节(魔数 `04 22 4D 18` LE):FLG=0x60 → 7;FLG=0x68(csz)→ 15;FLG=0x61(did)→ 11;FLG=0x69 → 19;skippable 魔数 0x184D2A50 任意后 4 字节 → 8;0x184D2A5F → 8;坏魔数 0x184D2205 → -13 且 isError;srcSize=4 → -12;srcIdx=3 偏移读(帧起于缓冲中部)正确
  - `lz4fDecompressOptionsTest`:默认全 0;struct 拷贝独立
- [x] **Step 2: RED → 实现**(新文件 src/lz4frame_decode.cj,文件头注明上游 lz4frame.c L1262-1350/L1471-1495 + commit 0774d055)
- [x] **Step 3: design.md 订正批次**:§4.5 解压清单订正——移除 `LZ4F_isSkippedFrame`、`LZ4F_decompress_usingCDict`(上游 0774d055 不存在,原清单误记;skippable 判定经 frameInfo.frameType==LZ4F_skippableFrame 表达),getBlockSize 注记"M5 已落地"
- [x] **Step 4: GREEN(双工具链,117+新增)+ Commit** `M6: frame decode skeleton - dctx lifecycle, headerSize and design corrections`

---

### Task 2: 解压状态机 + decodeHeader + getFrameInfo + decompress/usingDict 公开族 + L2/L3

**Files:** src/lz4frame_decode.cj、src/lz4frame_test.cj、src/xxhash.cj(XXH32 offset 重载)

**Interfaces:**
- Produces:
  - xxhash.cj:`internal func XXH32(input: Array<UInt8>, len: Int64, seed: UInt32, offset!: Int64): UInt32` 重载(现 3 参版委托 offset=0;块校验和 one-shot 需 src 位置对)
  - `internal func lz4fZeroFrameInfo(): LZ4F_frameInfo_t`(全字段 0,C MEM_INIT 等价——注意 ≠ struct 默认值)
  - `internal func lz4fDecodeHeader(dctx: LZ4F_dctx, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, srcIsHeader: Bool): Int64`(L1365-1464 全量;srcIsHeader 区分 C `src == dctx->header` 比较的两个调用点:storeFrameHeader/内部 header 路径传 true)
  - `internal func lz4fDictPrefixAt(dctx: LZ4F_dctx, dstArr: Array<UInt8>, dstPos: Int64): Bool`(前缀连续谓词,见 Global Constraints 翻译表;dstPos-k ≥ 0 由 dictIdx ≥ 0 蕴含)
  - `internal func lz4fUpdateDict(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstPos: Int64, dstSize: Int64, dstBaseIdx: Int64, withinTmp: Bool): Unit`(L1558-1623 五分支逐行;dstBaseIdx = 本调用 dst 起始索引,即 C dstBufferStart;每次赋值点同步 dictBuf/dictIdx/dictSize/dictInTmp)
  - `internal func lz4fDecompressBody(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, dOpt: LZ4F_decompressOptions_t): (Int64, Int64, Int64)`(L1644-2147 全量状态机 + 尾部历史保存;返回 (ret=hint/错误, srcConsumed, dstWritten);错误恒 (code, 0, 0))
  - `public func LZ4F_decompress(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, dOptPtr: Option<LZ4F_decompressOptions_t>): (Int64, Int64, Int64)`(None → 零值 options;skipChecksum 粘滞置位在 body 入口)
  - `public func LZ4F_decompress_usingDict(dctx: LZ4F_dctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, dictBuffer: Array<UInt8>, dictSize: Int64, dOptPtr: Option<LZ4F_decompressOptions_t>): (Int64, Int64, Int64)`(L2154-2167:`dStage <= dstage_init` 才置 dictBuf=dictBuffer/dictIdx=0/dictSize/dictInTmp=false,后直通 body;字典须整帧存活——GC 引用天然满足,注释)
  - `public func LZ4F_getFrameInfo(dctx: LZ4F_dctx, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64): (Int64, LZ4F_frameInfo_t, Int64)`(L1512-1551 三岔;already-decoded 岔以空数组/0/0 调 lz4fDecompressBody 取 hint;返回 (code/hint, frameInfo 拷贝, srcConsumed);srcBuf 于 already-decoded 岔不读但仍需传数组——测试传空数组)
- Consumes: T1 全部;`LZ4_decompress_generic`(lz4.cj:1753);`XXH32_reset/update/digest` + 新 offset 重载;`LZ4F_getBlockSize`(lz4frame.cj);`lz4fHeaderChecksum`(lz4frame.cj)
- 实现注意:状态机翻译保持 `var doAnotherStage = true; var nextSrcSizeHint: Int64 = 1` + `while` 循环 + 按 dStage 的分派结构;每个 stage 块内 `break`(C break switch → 继续 while)/`doAnotherStage=0`/错误直返 `return (code, 0, 0)` 三种出口与 C 逐一对应;fall-through 按约束⑲直译;srcPtr/dstPtr 以 `srcPos/dstPos: Int64` 游标表达

- [x] **Step 1: 失败测试**(lz4frame_test.cj):
  - `lz4fRoundTripMatrixTest`(L2):A 输入(RDG(65536,0.50,0),inxxh32=0xc20f7bcc 钉值)× {bs 4/5/6/7 × bm 0/1 × ccs 0/1 × bcs 0/1 × csz {0,n} × af 0/1}(128 组):LZ4F_compressFrame 成帧 → 单次 LZ4F_decompress(dst 容量 n)→ (0, size, n) + 输出逐字节 == 输入;csz 组另断 frameInfo 解码侧 contentSize == n
  - `lz4fDecodeGoldenTest`(L3 双向):遍历既有 FRAME_GOLD_REF 27 行(仓颉重建帧,M5 已证逐字节 == C)→ 整段解压 → 输出 XXH32 == 行内钉值 inxxh(0xc20f7bcc/0xbf1377f2/0xf125f7b1/0x9608f5fb/0x02cc5d05 按输入分布);artifact 存在时(lz4fReadArtifact)解 **C 产物字节** == 仓颉输入(双向闭合;缺失优雅降级打印 notice);断言末次 ret==0、Σconsumed==size、Σwritten==n
  - `lz4fGetFrameInfoTest`:fresh dctx + 默认头 7B → (4, fi{bs=4,bm=0,ccs=0,bcs=0,csz=0,did=0,type=0}, 7);csz+did 头(嵌入 M5 frhdr 常量几何自行构造 Begin 产物)→ (4, …csz/did…, 19);解压半帧后(dStage>storeFrameHeader)再调 → consumed=0、frameInfo 相同、hint=4;首调 decompress 仅 6B(storeFrameHeader)再调 getFrameInfo → -19;srcSize=6 → -12;skippable 头 → frameType==LZ4F_skippableFrame、consumed=4
  - `lz4fDecodeErrorContractTest`:坏魔数 → (-13, 0, 0);FLG version=2 → (-6,0,0);FLG 保留位 → (-8,0,0);BD bsID=3 → (-2,0,0);坏 HC 字节 → (-17,0,0);压缩块内篡改 1 字节(保长度)→ -16;篡改块校验和尾 4B → -7;篡改内容校验和尾 4B → -18;csz 帧实际内容不符 → -14;每例断言三元组零消费零写出(错误契约);错误后 dctx 上游不担保复用(不测续用,契约注释)
  - `lz4fDecompressStateTest`:0 字节首调用 → (7, 0, 0) 且 dStage 仍 0;7B 头调用 → consumed=7、hint≥4、dStage ≥ 3;ccs 帧解码后 xxh digest 状态;完整帧后 dStage==0(自动 reset)→ 同 dctx 续解第二帧(拼接最小例);空输入帧(F)解压 → (0, 11, 0)(7 头 + 4 endmark)
  - `lz4fUsingDictDecodeTest`:fdt 行 1 几何(A dd=65536 dseed=99 lv=0 bm=0)——仓颉 compressBegin_usingDict 成帧 → LZ4F_decompress_usingDict(同字典)→ 输出 == 输入;同帧无字典解码 → 结果钉住(成功与否按实测,断言与 C golden T3 fdmp 行一致前先记录);dict 注入仅 dStage≤init:半帧后调 usingDict 不改 dict(状态断言)
- [x] **Step 2: RED → 实现**(xxhash.cj 重载先行;对照 L1365-1551、L1558-1623、L1644-2167 逐行;保真点 ①-⑲ 逐条自查后勾)
- [x] **Step 3: GREEN(双工具链,既有不回归)+ Commit** `M6: decompression state machine, getFrameInfo and public decompress family`

---

### Task 3: 分片续传矩阵 + options + skippable/拼接 + fdmp C golden 钉值

**Files:** scripts/gen_golden.c、scripts/gen_golden.sh、corpus/、src/lz4frame_test.cj

**Interfaces:**
- Produces: golden 清单新节 `mode=fdmp`(14 行,C 解压探针钉值;行格式 `n=<n> mp=<mp> seed=<seed> mode=fdmp sc=<id> [参数] out=<c:w:h;...> code=<v> fi=<bs,bm,ccs,bcs,type,csz,did> outxxh32=<..>`;scenario 定义如下);Cangjie 侧嵌入常量断言
- Consumes: T2 全部;gen_golden.c 既有 frhdr/frame 节的帧构造代码

- [x] **Step 1: C golden 扩展**(gen_golden.c 加 fdmp 节 + gen_golden.sh 门检更新)。行集(帧除注明外均为 C harness 现场构造,bs=4 默认 prefs;A=(65536,0.50,0)、D=(255,0.50,0)):
  1. `sc=fi` A 默认帧:getFrameInfo(fresh, srcSize=19)→ out=`7:4` fi=`4,0,0,0,0,0,0`
  2. `sc=fi` A csz=65536 did=305419896 帧 → out=`19:4` fi=`4,0,0,0,0,65536,305419896`
  3. `sc=fimid` A ccs=1 帧:decompress(头+首块字节)后 getFrameInfo → out=`0:4`(consumed=0、hint=4)
  4. `sc=fimid2` A 帧:decompress 仅 6B(storeFrameHeader)后 getFrameInfo → code=-19
  5. `sc=fishort` A 帧:getFrameInfo srcSize=6 → code=-12;srcSize=4 → code=-12(headerSize MIN_SIZE 先拒)
  6. `sc=seq1` D ccs=1 bcs=1 bm=0 lv=0 帧,调用列 srcSize=[1,6,11,55,55,余] × dstCap=65536 → out=6 组 `c:w:h` 三元组(覆盖 storeFrameHeader 续传/storeCBlock 分片/getSuffix)
  7. `sc=seq2` 同帧,srcSize=[30,30,30,30,余] × dstCap=[2,2,2,2,65536,65536] → out=6 组(覆盖 flushOut 部分 tmpOutStart + withinTmp updateDict + 尾部历史保存)
  8. `sc=seq3` skippable(魔数 0x184D2A50、size=13、payload 零):调用列 [3,2,6,余] → out=4 组(getSFrameSize/storeSFrameSize 续传 + skipSkippable 分片 hint)
  9. `sc=seq4` skippable(魔数 0x184D2A5F、size=0)单次整帧 → out=`8:0:0`(consumed=8、written=0、hint=0)
  10. `sc=cat` D ccs=1 帧 + skippable(size=5)+ D bcs=1 帧:单 dctx 顺序解压 → out=三段 `c:w:h`(每段 ret==0 边界;帧拼接)
  11. `sc=dict` A dd=65536 **dseed=0**(字典内容 == 输入,确保块内引用字典)lv=0 bm=0 Begin_usingDict 帧:decompress_usingDict(同字典)→ out=`<size>:65536:0` outxxh32=0xc20f7bcc;同帧无字典解压 → code=-16(引用越界必败,双钉)
  12. `sc=errhdr` 构造坏帧 5 例(坏魔数/FLG version=2/FLG 保留位/BD bsID=3/坏 HC)→ out=`-13;-6;-8;-2;-17`
  13. `sc=errblk` A 帧:块大小字段改 65537(>maxBlockSize)→ -2;块校验和尾篡改 → -7 → out=`-2;-7`
  14. `sc=errtail` A ccs=1 帧:尾 CRC 篡改 → -18;csz=60000 帧解码完成 → -14;截断至半块调用 → 正 hint(非错误,钉 hint 值)→ out=`-18;-14;<hint>`
  - 门检(gen_golden.sh sanity 块追加 + 总数改):数据行 475+14=489,总行 489+23(注释 22+1)== 512,`grep -c '^#'`==23,`grep -c 'mode=fdmp'`==14;corpus ≤ 8MB 复查
- [x] **Step 2: 失败测试**(lz4frame_test.cj):
  - `lz4fDecodeFdmpGoldenTest`:14 行场景仓颉侧重放,嵌入常量断言全部 out/code/fi/outxxh32(先跑 gen_golden.sh 取 C 值,手工嵌入;skippable 帧与坏帧按行规格构造字节)
  - `lz4fRandomSplitTest`:FRAME_GOLD_REF 27 行 × 切分模式 {1B、7B、997B、LCG 随机(fuzzLcgNext 风格本地 LCG,seed=行号)}:按 hint 喂入循环至 ret==0 → 输出 == 输入逐字节 + Σconsumed==size;另 × dst 容量 {10B、1000B、n}(小容量逼 flushOut 多轮回);dstIdx=4096 位置对解码(输出落于大缓冲中部)
  - `lz4fStableDstTest`:bm=0 多块 C 帧解码:pledge 兑现场景(缓冲 = 128KB,dstIdx=65536,先前调用产出留在 [0, dstIdx) 不动)stableDst=1 与 =0 输出一致、调用数 ≤ 无 stable 基线(性能语义,仅断言正确性 + 不抛)
  - `lz4fSkipChecksumsTest`:ccs=1 bcs=1 帧篡改两处 CRC 字节:skipChecksums=1 → 解压成功且输出 == 输入(校验跳过);=0 → -7/-18;粘滞性:首调用置 1 后续调用不传 options 仍跳过
  - `lz4fSkippableTest`:尺寸 {0,1,13,70000} × 魔数 {0x184D2A50, 0x184D2A5F}:整段与 [3,2,余] 切分解压 → (0, 8+size, 0) 且零输出;skipSkippable 完成后 dctx 可续解正常帧(reset 语义)
  - `lz4fFrameConcatTest`:仓颉自产 4 帧矩阵(含 ccs/bcs/skippable 混排)单 dctx 顺序解压,输出拼接 == 各输入拼接;getFrameInfo 在段间可调用
- [x] **Step 3: GREEN(双工具链)+ Commit** `M6: resumption matrix, skippable/concat and fdmp C golden pinning`

---

### Task 4: frame 解压 fuzz + 覆盖率 + M6 收尾

**Files:** src/fuzz_test.cj、src/lz4frame_decode.cj(如补防御注释)、docs/progress.md、CHANGELOG.md、README.md、docs/design.md(如订正遗漏)

**Interfaces:**
- Produces: `fuzzFrameDecodeTest`(fuzz_test.cj);文档三件套收尾
- Consumes: T2/T3 全部;M5 fuzzFrameTest 的帧规划器(fuzzFramePlanBlocks/fuzzFrameRunChain 复用)

- [ ] **Step 1: fuzz 扩展**(fuzz_test.cj)`fuzzFrameDecodeTest`:150 种子,每种子随机 {n∈[0,150000]、mp、bs∈{4..7}、bm、ccs、bcs、af、lv∈{-3,0,3,9,12}、成帧方式一次性/流式}:
  - 场景 A(随机切分):成帧 → LCG 随机 src 切分 + 随机 dst 容量 ∈ {0、小(逼 flushOut/storeCBlock)、恰 maxBlockSize、n}逐调用 → 输出 == 输入 + 末次 ret==0
  - 场景 B(拼接):2-4 帧连发(混 skippable)单 dctx 顺序解 → 输出拼接断言
  - 场景 C(损坏):对帧字节随机翻转 1-3 处/随机截断/随机块内篡改 → 解压循环至 ret==0 或 isError;断言绝无异常逃逸、错误时三元组零消费零写出;若"完成"则输出可任意(损坏可能巧合合法)
  - 断言:全部调用返回值非错误或恰为错误(无异常);同种子二次运行逐字节确定
- [ ] **Step 2: 覆盖率门禁**:`cjpm test --coverage` + `cjcov --html-details`(LTS);库源码行覆盖 ≥ 96%(基线 96.43%,lz4frame_decode.cj 预计 ~700 行);未覆盖行逐条归类(预期防御类:dictSize>1GB 截尾、部分 updateDict 尾分支若 fuzz 未达 → 补定向用例或台账登记 M7)
- [ ] **Step 3: 文档收尾**:progress.md(M6 行 + 证据数字 + API 计数更新 frame 解压侧 7 函数 + decompressOptions/常量;下一步 M7);CHANGELOG 0.7.0(frame 解压全量 + fdmp 14 行 + 覆盖率 + 双绿 + 订正注记);README API 对照 frame 解压节(位置对签名、getFrameInfo/decompress 元组返回、free 返回 dStage、create 出参、dst NULL = 空数组+容量 0、isSkippedFrame/decompress_usingCDict 不存在订正、skippable 经 frameType 判定)+ 测试计数更新
- [ ] **Step 4: 全量门禁 `scripts/build_and_test.sh both` + Commit** `M6: frame decode fuzz, coverage and milestone wrap-up`

---

## Self-Review 记录

- 规格覆盖:设计 §4.5 解压清单(订正后 8 项)全承接——create/free/reset(T1)、headerSize(T1)、getFrameInfo/decompress/decompress_usingDict(T2)、getBlockSize(M5 复用)、isError 族(M5 复用);类型 LZ4F_decompressOptions_t(T1,reserved 省略登记);§4.3 规则 1 的两组元组签名(T2,逐字);§5.5 解压状态机/续传/stableDst/skipChecksums/skippable/拼接(T2-T3);§8.3 分片续传 + 损坏输入(T3-T4);§10 M6 验收(L2 往返 T2、L3 双向 T2/T3、L4 T4、双绿每任务);§4.5 订正落 T1 Step 3。isSkippedFrame/decompress_usingCDict 不存在于上游 → 订正移除(设计清单错误,非裁剪)。
- 类型一致性:长度/返回 Int64;位置对 (buf, idx) 全任务统一;三元组 (ret, srcConsumed, dstWritten)/(code, frameInfo, srcConsumed) 与 §4.3 规则 1 逐字;LZ4F_dctx 字段名与状态模型逐字;lz4fDecompressBody 与公开包装参数序一致;XXH32 重载不动既有签名。
- 占位扫描:无 TBD/TODO;T2 usingDict 无字典结果"按实测钉住"有明确来源(T3 fdmp 行 11 C 侧双钉,先记录后断言);T3 fdmp 行的 out 数值由 C harness 产出后嵌入(先例:M5 golden 同流程)。
- 已知风险:①updateDict 五分支的指针算术翻译(尤其 withinTmp 非 tmp 分支的 oldDictEnd = dict+dictSize-tmpOutStart)是最高危区——fdmp seq2 + 随机切分小容量组合强制覆盖,逐分支行锚评审;②内容窗口谓词的输出等价论证(假阳性 ⇒ 历史字节相同)依赖"解码输出仅取决于历史字节"——由 fdmp sc=dict 双钉 + C golden 全行解压兜底;③getCBlock 早退 hint 的 `dstPtr==dstEnd || srcPtr==srcEnd` 在容量 0 哨兵下语义(空数组 + dstIdx=0)必须与 C NULL 一致——错误契约与 fdmp seq 行钉住;④尾部历史保存的 stage 域 [2,10) 上界(排除 getSuffix=10)易错——STATIC_ASSERT(dstage_init==2) 对应断言嵌入测试;⑤storeSuffix 暂存 tmpIn 而 getBlockChecksum 暂存 header 的不对称是上游怪癖——保真点⑭显式对照;⑥XXH32 offset 重载不得改动 3 参版行为(委托关系 + 既有 xxhash 测试回归即证)。
