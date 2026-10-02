# lz4cj M5 实现计划(Frame 压缩:cctx 全 API + CDict + 头编码)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移植 lz4frame.c 压缩侧全部非弃用 API(LZ4F_cctx 状态机、preferences 归一化、Begin/Update/uncompressedUpdate/Flush/End、compressFrame 一次性族、CDict、头编码),frame 压缩产物与 C golden 逐字节一致(L3 单向),双工具链全绿。

**Architecture:** `LZ4F_cctx` 以类承载:C 的 `tmpBuff/tmpIn` 指针对 → `Array<UInt8> + Int64 索引`;`lz4CtxPtr` void* + alloc/type 双标记 → `Option<LZ4_stream_t>` / `Option<LZ4_streamHC_t>` 双字段 + 标记(输出等价的布局偏离);流式 API 的 dst/src 沿 §4.3 规则 4 位置对 `(buf, idx)`;块压缩经既有偏移入口(continue 家族)+ lz4.cj/lz4hc.cj 各新增一个偏移版 extState 快复位内部函数。

**Tech Stack:** Cangjie LTS-1.0.5 / STS-1.2.0、cjpm、cc(C golden)、std.unittest。

**Spec:** `docs/design.md`(§4.5 frame 清单、§5.5、§8.2 参数矩阵、§10 M5 行、附录 12 第 8 条)。关联:`docs/progress.md` M5 分解。

## Global Constraints

- 同一套源码在 LTS-1.0.5 与 STS-1.2.0 下编译、测试全绿;每任务收尾 `scripts/build_and_test.sh both`;不得移除 `--int-overflow=wrapping -O2`;指针三律——frame 装配层以 `Array<UInt8>` 安全索引为主(设计 §6.1 冷路径划分),块压缩下沉到既有 unsafe 核心。
- API 命名与 lz4frame.h 逐字一致;`LZ4F_errorCode_t = Int64`(size_t,负值错误模式,§4.7)。
- 上游参照 `~/lz4`(commit 0774d055,`lib/lz4frame.c` 2167 行,压缩侧 L101-1259)。分段锚点:
  - L189-233 LE 读写(复用 common.cj 的 LZ4_readLE32/64、LZ4_writeLE32/64);L245-257 常量(_1BIT.._8BITS、LZ4F_BLOCKUNCOMPRESSED_FLAG=0x80000000u32、BLOCKSIZEID_DEFAULT=4、minFHSize=7、maxFHSize=19、BHSize=4、BFSize=4)
  - L264-285 cctx 结构 + LZ4B_COMPRESSED/LZ4B_UNCOMPRESSED 与 ctxNone/ctxFast/ctxHC;L291-331 错误族(errorStrings、isError、getErrorName、getErrorCode、getVersion=LZ4F_VERSION 100、compressionLevel_max=LZ4HC_CLEVEL_MAX);L335-344 getBlockSize(blockSizes[]{64K,256K,1M,4M},id==0→4,越界→maxBlockSize_invalid);L351-355 headerChecksum((XXH32(header,len,0)>>8) 截断字节)
  - L361-373 optimalBSID;L381-406 compressBound_internal(flush=autoFlush|(srcSize==0)、maxBuffered=blockSize-1、nbFullBlocks/lastBlockSize/nbBlocks、返回 (BHSize+blockCRCSize)*nbBlocks + blockSize*nbFullBlocks + lastBlockSize + frameEnd);L408-418 compressFrameBound(maxFHSize + internal(强制 autoFlush=1, 0));L884-890 compressBound 公开(autoFlush→alreadyBuffered=0,否则 (size_t)-1)
  - L430-476 compressFrame_usingCDict(csz≠0 自动改写为 srcSize、optimalBSID、单块强制 independent、autoFlush=1、stableSrc=1、容量不足 → dstMaxSize_tooSmall、Begin→Update→End 链);L486-526 compressFrame(HEAPMODE=0 栈路径:maxBufferSize=5MB 防分配 hack、prefs 为 NULL 或 level<2 时预置栈上 fast 流 alloc=1/type=ctxFast)
  - L533-597 LZ4F_CDict(dictContent 拷贝 ≤64KB 截尾、fastCtx=initStream+loadDictSlow、HCCtx=initStreamHC+setCompressionLevel(9)+loadDictHC);L604-646 create/freeCompressionContext;L657-694 LZ4F_initStream(fast:cdict 或 linked 才 resetStream_fast(+attach),否则依赖 one-shot 自复位;HC:恒 resetStreamHC_fast(+attach));cctx_size(L696-701)不移植
  - L706-830 compressBegin_internal:ctx 管理 L722-752(alloc/type 双标记、换型重 init);缓冲管理 L754-772(requiredBuffSize:autoFlush→linked 64KB/indep 0,否则 blockSize + linked 128KB);上下文初始化 L774-794(linked 才 initStream;level≥2 → favorDecompressionSpeed;dictBuffer → loadDict/loadDictHC);头编码 L796-829(魔数 LE32、FLG、BD、可选 csz LE64(该分支 totalInSize=0)/did LE32、HC 字节);L832-876 Begin/usingDictOnce(隐藏)/usingDict/usingCDict 包装
  - L900-926 makeBlock(dstCapacity=srcSize>1?srcSize-1:1;cSize==0||cSize>=srcSize → 未压缩块+0x80000000 标志+原样拷贝;crcFlag → XXH32 覆盖**存储后**数据);L929-968 四个 compressBlock 变体 + doNotCompress(返 0,恒触发未压缩存储);L970-980 selectCompression(UNCOMPRESSED 优先,level<2 二岔,HC 二岔);L983-989 localSaveDict(saveDict/saveDictHC 64KB,tmpIn=tmpBuff+dictSize);L991-993 lastBlockStatus + k_cOptionsNull
  - L1008-1121 compressUpdateImpl(cStage 检查 → -20;bound 检查含 alreadyBuffered=tmpInSize → -11;UNCOMPRESSED 另查 dstCapacity<srcSize;模式切换先 flush;tmpIn 补块 memcpy 自 src 头部;整块循环;autoFlush 余块;linked+fromSrcBuffer → stableSrc?tmpIn=tmpBuff:localSaveDict;!autoFlush 且 tmpIn+blockSize>maxBufferSize → localSaveDict;余量拷入 tmpIn;ccs → XXH32_update 覆盖整个 srcBuffer;totalInSize+=srcSize);L1135-1164 Update/uncompressedUpdate;L1175-1212 flush(tmpInSize==0 先返 0——先于 cStage 检查的上游顺序怪癖;linked → tmpIn+=tmpInSize;tmpIn 越界 → localSaveDict);L1224-1259 compressEnd(flush → endmark 0 → ccs digest → cStage=0 → csz≠totalInSize → frameSize_wrong)
  - L1262 起为解压侧(M6,不触);错误枚举 lz4frame.h L668-693(25 项,OK_NoError=0 … ERROR_maxCode=24)
- **语言事实(2026-10-01 实测 cjc 1.0.5)**:仓颉无 C 风格值枚举(`enum E { A = 0 }` 编译拒绝)→ 五个帧枚举与 LZ4F_errorCodes 全以 **Int32/Int64 常量族**承载,成员名逐字;struct 支持成员默认值 + 显式 `init()`,嵌套 struct 赋值拷贝(值语义)实证可用。
- **cctx 状态模型 ruling**(§4.4 + §4.3 规则 4 延伸):

```
public class LZ4F_cctx {
    internal var prefs: LZ4F_preferences_t = LZ4F_preferences_t()
    internal var version: UInt32 = 0
    internal var cStage: Int32 = 0                        // 0 未初始化 / 1 已 Begin
    internal var cdict: Option<LZ4F_CDict> = None
    internal var maxBlockSize: Int64 = 0
    internal var maxBufferSize: Int64 = 0
    internal var tmpBuff: Array<UInt8> = Array<UInt8>(0, {_ => 0u8})  // 空 = C NULL
    internal var tmpIn: Int64 = 0                         // tmpBuff 内偏移(C 指针 → 索引)
    internal var tmpInSize: Int64 = 0
    internal var totalInSize: UInt64 = 0
    internal var xxh: XXH32_state_t = XXH32_state_t()
    internal var lz4CtxFast: Option<LZ4_stream_t> = None  // C void* lz4CtxPtr →
    internal var lz4CtxHC: Option<LZ4_streamHC_t> = None  //   双 Option + 双标记
    internal var lz4CtxAlloc: Int32 = 0                   // 0=none 1=fast 2=hc(尺寸序单调)
    internal var lz4CtxType: Int32 = 0
    internal var blockCompressMode: Int32 = 0             // LZ4B_COMPRESSED
}
```

  ctx 管理移植:`allocatedSize < requiredSize` ⟺ `lz4CtxAlloc < ctxTypeID`(尺寸 0<16416<262200 单调);alloc 分支 = 新建所需类型对象 + 另一字段置 None(镜像 C free)+ 双标记更新;换型分支(alloc 足够但 type 不同)= 目标类型对象按需新建并全量 init(fast: initStream;HC: initStreamHC + setCompressionLevel(prefs.compressionLevel)),仅更新 type——类实例 vs C 原地重解释的布局偏离,输出等价,注释登记。
- **stableSrc 语义**:C "字典驻留 src" ⟺ 块压缩状态持有源 Array 引用(`LZ4_stream_t.dictBuf` / `LZ4_streamHC_t.prefixBuf` 引用对天然承载),无需指针比较;stableSrc=1 时 `tmpIn = 0`,否则 localSaveDict 拷贝 64KB 历史 入 tmpBuff。
- **签名约定**(§4.3 规则 2/4 frame 延伸,README API 对照表逐条登记):
  - 长度/返回一律 `Int64`(size_t);`prefsPtr/cOptPtr/cdict` 指针 → `Option<T>`(None = NULL)
  - 全部写出型 API 的 dst = `(dstBuf: Array<UInt8>, dstIdx: Int64)` 位置对 + `dstCapacity: Int64`(自位置起算;C 调用方前移指针的等价物);`LZ4F_compressUpdate/uncompressedUpdate` 的 src 同取 `(srcBuf, srcIdx: Int64)` 位置对(块源 srcBuf[srcIdx, srcIdx+srcSize),M3b 惯例)
  - `LZ4F_createCompressionContext(version: UInt32): LZ4F_cctx`(C 出参 → 返回值;分配失败 GC 下不可达);`LZ4F_freeCompressionContext(cctx): Int64` 恒 0;`LZ4F_freeCDict(cdict): Unit`
  - `LZ4F_isError(code) = code < 0 && code > -LZ4F_ERROR_maxCode`(C 无符号比较的带符号等价:真错误域恰为 -23..-1;code==-24 非错误,上游边沿保留)
- 保真度关键点(附录 12 第 8 条展开,评审对照):①FLG 位序与 (csz>0)/(did>0) 布尔化;②HC 字节 = XXH32(头,0)>>8 截断;③csz≠0 时 totalInSize=0 复位仅在该分支(上游怪癖照搬);④makeBlock 的 dstCapacity 收缩(srcSize-1)、未压缩块判定(cSize==0||cSize>=srcSize)、块校验和覆盖存储后字节;⑤bound 检查含 alreadyBuffered=tmpInSize;⑥mode 切换先 flush 再续;⑦linked+fromSrcBuffer 的 stableSrc 二岔;⑧flush 的 tmpInSize==0 先返 0(先于 cStage 检查)与 linked 的 tmpIn 前移;⑨compressEnd 的 cStage=0 先于 csz 校验;⑩compressFrame 的 csz 自动改写/optimalBSID/单块强制 independent/autoFlush=1/stableSrc=1 四联变换与 5MB 防分配 hack;⑪selectCompression 五路中 UNCOMPRESSED 优先于 level。
- golden 约定:期望值嵌入测试常量(先例);artifacts ≤ 65536B 存 `corpus/block/<idx>.lz4` 原件;gen_golden.sh 编译行追加 `"$HOME/lz4/lib/lz4frame.c"`,gen_golden.c 加 `#define LZ4F_STATIC_LINKING_ONLY`(getBlockSize/uncompressedUpdate 需要);行格式契约见各任务;corpus 总量 ≤ 8MB(现 4.3MB,预计 +~1.2MB)。
- **corpus 政策(2026-10-01 用户裁定,M5 起生效)**:corpus 二进制数据不再进入 git 历史,git 只保留生产 golden 的脚本(gen_golden.c/.sh 等,scripts/ 内)。落地:`.gitignore` 追加 `corpus/`;`git rm -r --cached corpus/` 一次性解除跟踪(工作区文件保留,历史中旧 blob 不动);此后 corpus 一律由 `scripts/gen_golden.sh` 本地再生(需 cc + ~/lz4@0774d055)。**M5 新测试的 artifact 比对一律优雅降级**:文件存在 → 逐字节比对;缺失 → 跳过并打印 notice(size + xxh32/64 摘要断言恒为权威校验,嵌入常量不受影响)。既有 M2-M4 测试不改(本机 corpus 在盘,双绿不受影响);T4 的 README 记录再生工作流。
- 提交信息 `M5: ...` 前缀;每任务收尾勾选本计划;最终任务更新 progress.md + CHANGELOG 0.6.0 + README;执行沿用 main 直提交流程(M0-M4 既定)。

---

### Task 1: lz4frame.cj 骨架 —— 类型/枚举/错误族/边界数学 + cctx 生命周期 + design 订正

**Files:** src/lz4frame.cj(新)、src/lz4frame_test.cj(新)、docs/design.md

**Interfaces:**
- Produces:
  - `public const LZ4F_VERSION: UInt32 = 100`;`public func LZ4F_getVersion(): UInt32`;`public func LZ4F_compressionLevel_max(): Int32`(= LZ4HC_CLEVEL_MAX)
  - 枚举常量族(成员名逐字,Int32):`LZ4F_default=0/LZ4F_max64KB=4/LZ4F_max256KB=5/LZ4F_max1MB=6/LZ4F_max4MB=7`、`LZ4F_blockLinked=0/LZ4F_blockIndependent=1`、`LZ4F_noContentChecksum=0/LZ4F_contentChecksumEnabled=1`、`LZ4F_noBlockChecksum=0/LZ4F_blockChecksumEnabled=1`、`LZ4F_frame=0/LZ4F_skippableFrame=1`
  - 错误码常量族(Int64,lz4frame.h L668-693 序):`LZ4F_OK_NoError=0`、`LZ4F_ERROR_GENERIC=1`、`LZ4F_ERROR_maxBlockSize_invalid=2`、`LZ4F_ERROR_blockMode_invalid=3`、`LZ4F_ERROR_parameter_invalid=4`、`LZ4F_ERROR_compressionLevel_invalid=5`、`LZ4F_ERROR_headerVersion_wrong=6`、`LZ4F_ERROR_blockChecksum_invalid=7`、`LZ4F_ERROR_reservedFlag_set=8`、`LZ4F_ERROR_allocation_failed=9`、`LZ4F_ERROR_srcSize_tooLarge=10`、`LZ4F_ERROR_dstMaxSize_tooSmall=11`、`LZ4F_ERROR_frameHeader_incomplete=12`、`LZ4F_ERROR_frameType_unknown=13`、`LZ4F_ERROR_frameSize_wrong=14`、`LZ4F_ERROR_srcPtr_wrong=15`、`LZ4F_ERROR_decompressionFailed=16`、`LZ4F_ERROR_headerChecksum_invalid=17`、`LZ4F_ERROR_contentChecksum_invalid=18`、`LZ4F_ERROR_frameDecoding_alreadyStarted=19`、`LZ4F_ERROR_compressionState_uninitialized=20`、`LZ4F_ERROR_parameter_null=21`、`LZ4F_ERROR_io_write=22`、`LZ4F_ERROR_io_read=23`、`LZ4F_ERROR_maxCode=24`
  - `public func LZ4F_isError(code: Int64): Bool`;`public func LZ4F_getErrorName(code: Int64): String`(25 项字符串数组,名字去 LZ4F_ 前缀;非错误 → "Unspecified error code");`public func LZ4F_getErrorCode(functionResult: Int64): Int64`(非错误→0;错误→-code)
  - `public func LZ4F_getBlockSize(blockSizeID: Int32): Int64`(L335-344;0→4 代入;越界 → -LZ4F_ERROR_maxBlockSize_invalid)
  - `internal func lz4fHeaderChecksum(header: Array<UInt8>, length: Int64): UInt8`;`internal func lz4fOptimalBSID(requestedBSID: Int32, srcSize: Int64): Int32`(L361-373;requested=0 时原样返回 0 的怪癖保留)
  - `internal func lz4fCompressBoundInternal(srcSize: Int64, prefs: Option<LZ4F_preferences_t>, alreadyBuffered: Int64): Int64`(L381-406;None → INIT 副本 + ccs/bcs 最坏置 1;(size_t)-1 以 Int64.Max 传入);`public func LZ4F_compressFrameBound(srcSize: Int64, preferencesPtr: Option<LZ4F_preferences_t>): Int64`(L408-418);`public func LZ4F_compressBound(srcSize: Int64, preferencesPtr: Option<LZ4F_preferences_t>): Int64`(L884-890)
  - `public struct LZ4F_frameInfo_t`(默认值 = LZ4F_INIT_FRAMEINFO:`blockSizeID: Int32 = LZ4F_max64KB`、`blockMode: Int32 = LZ4F_blockLinked`、`contentChecksumFlag: Int32 = LZ4F_noContentChecksum`、`frameType: Int32 = LZ4F_frame`、`contentSize: UInt64 = 0`、`dictID: UInt32 = 0`、`blockChecksumFlag: Int32 = LZ4F_noBlockChecksum`;显式 `public init()`);`public struct LZ4F_preferences_t`(`frameInfo: LZ4F_frameInfo_t = LZ4F_frameInfo_t()`、`compressionLevel: Int32 = 0`、`autoFlush: UInt32 = 0`、`favorDecSpeed: UInt32 = 0`;reserved[3] 省略,登记);`public struct LZ4F_compressOptions_t`(`stableSrc: UInt32 = 0`;reserved 省略,登记)
  - `public class LZ4F_cctx`(字段见 Global Constraints);`public func LZ4F_createCompressionContext(version: UInt32): LZ4F_cctx`(version 仅存字段);`public func LZ4F_freeCompressionContext(cctx: LZ4F_cctx): Int64`(恒 0)
- Consumes: xxhash.cj 的 XXH32(internal);lz4hc.cj 的 LZ4HC_CLEVEL_MAX

- [ ] **Step 1: corpus 政策落地(独立提交)**:`.gitignore` 追加 `corpus/`;`git rm -r --cached corpus/`(工作区保留);提交 `M5: untrack corpus binaries - regenerate via scripts/gen_golden.sh`(政策依据见 Global Constraints;scripts/ 内生成脚本保持跟踪)
- [ ] **Step 2: 失败测试(src/lz4frame_test.cj)**:
  - `lz4fErrorTest`:isError(-1)..isError(-23) 全真;isError(-24) 假(上游边沿);isError(0)/isError(1)/isError(10957) 假;getErrorName(-1)=="ERROR_GENERIC"、(-11)=="ERROR_dstMaxSize_tooSmall"、(-14)=="ERROR_frameSize_wrong"、(-20)=="ERROR_compressionState_uninitialized";getErrorName(0)/getErrorName(5)=="Unspecified error code";getErrorCode(0)==0、getErrorCode(7)==7、getErrorCode(-3)==3
  - `lz4fVersionTest`:getVersion()==100;compressionLevel_max()==12
  - `lz4fGetBlockSizeTest`:0→65536、4→65536、5→262144、6→1048576、7→4194304;3/8/-1→-2
  - `lz4fOptimalBSIDTest`:(7,0)→4、(7,65536)→4、(7,65537)→5、(6,262144)→5、(6,262145)→6、(6,300000)→6、(5,10)→4、(4,10)→4、(0,999)→0
  - `lz4fCompressBoundTest`(手算钉值,pre-flight 订正后):compressBound(0, None)==65551;compressBound(100, prefs{bs=4,af=1,ccs=1})==112;compressBound(100, prefs{bs=7,af=0})==4;compressFrameBound(0, None)==23;compressFrameBound(65536, None)==65563;compressFrameBound(65536, prefs{bs=4,ccs=1})==65567(注:ccs/bcs 最坏置 1 仅在 internal 直接收 None 时生效;compressFrameBound 对 None 走本地零值 prefs + autoFlush=1)
  - `lz4fHeaderChecksumTest`:两组构造头(默认 7B / csz+did 19B)→ (XXH32(头,len,0)>>8)&0xFF 钉值(经本仓 XXH32 计算,交叉自证)
  - `lz4fCctxLifecycleTest`:create(100) → cStage==0、version==100、tmpBuff.size==0、lz4CtxAlloc==0、lz4CtxType==0、maxBufferSize==0;free==0
  - `lz4fPrefsDefaultsTest`:LZ4F_preferences_t() 全字段 == C INIT 逐字段;LZ4F_compressOptions_t().stableSrc==0;struct 拷贝独立性
- [ ] **Step 3: RED → 实现**(对照 L189-476、L884-890、lz4frame.h 枚举/结构;错误名表 25 项;isError 按约束公式)
- [ ] **Step 4: GREEN(双工具链,93+新增,既有不回归)**
- [ ] **Step 5: design.md 订正批次**:①§4.5 frame 清单补 `LZ4F_compressBegin_usingDict`(lz4frame.h L561,v1.10 稳定,原清单漏记);②§4.6 显式不移植表补:LZ4F_customMem 族 + `LZ4F_createCompressionContext_advanced`/`LZ4F_createCDict_advanced`(GC 分配模型)、`LZ4F_cctx_size`/`LZ4F_dctx_size`(C 布局信息性 API)、`LZ4F_ENABLE_OBSOLETE_ENUMS` 旧别名(上游默认关闭);③§4.5 类型条目注记:五枚举以 Int32 常量族承载 + reserved 字段省略(实测依据);④§8.2 注记:corpus 不入库(2026-10-01 裁定),由 scripts/gen_golden.sh 本地再生
- [ ] **Step 6: Commit** `M5: frame skeleton - types, error family, bounds and cctx lifecycle`

---

### Task 2: compressBegin 家族 —— 头编码 + ctx/缓冲管理 + frhdr golden

**Files:** src/lz4frame.cj、src/lz4frame_test.cj、scripts/gen_golden.c、scripts/gen_golden.sh、corpus/

**Interfaces:**
- Produces:
  - `internal func lz4fInitStream(cctx: LZ4F_cctx, level: Int32, blockMode: Int32): Unit`(L657-683:level<2 时 cdict!=None 或 linked → LZ4_resetStream_fast(lz4CtxFast!)+ cdict → LZ4_attach_dictionary(流, cdict.fastCtx);level≥2 → LZ4_resetStreamHC_fast(lz4CtxHC!, level)+ cdict → LZ4_attach_HC_dictionary)
  - `internal func lz4fCompressBeginInternal(cctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, dictBuffer: Option<Array<UInt8>>, dictSize: Int64, cdict: Option<LZ4F_CDict>, prefsPtr: Option<LZ4F_preferences_t>): Int64`(L706-830 全量:dstCapacity<19 → -11;prefs=None → INIT 默认,值拷贝入 cctx.prefs;ctx 管理(双标记,见 Global Constraints);blockSizeID==0→4;maxBlockSize=getBlockSize;缓冲管理(requiredBuffSize 公式,tmpBuff 尺寸不足则新建 Array 并置 maxBufferSize);tmpIn=0、tmpInSize=0、XXH32_reset(xxh,0);cdict 存字段;linked 才 lz4fInitStream;level≥2 → LZ4_favorDecompressionSpeed(lz4CtxHC!, Int32(prefs.favorDecSpeed));dictBuffer → dictSize>Int32.Max → -4;ctxType==ctxFast → LZ4_loadDict 否则 LZ4_loadDictHC;头编码 L796-829 逐字节:魔数 LE32 → FLG → BD → 可选 csz LE64(置 totalInSize=0)/did LE32 → HC 字节;cStage=1)
  - `public func LZ4F_compressBegin(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, prefsPtr: Option<LZ4F_preferences_t>): Int64`(L832-839:dictBuffer=None、cdict=None)
  - `public func LZ4F_compressBegin_usingDict(cctx, dstBuf, dstIdx, dstCapacity, dict: Array<UInt8>, dictSize: Int64, prefsPtr: Option<LZ4F_preferences_t>): Int64`(L855-866:经 usingDictOnce 直通 internal;上游"仅首块用字典"的已知不完整实现,注释照搬)
  - `public func LZ4F_compressBegin_usingCDict(cctx, dstBuf, dstIdx, dstCapacity, cdict: Option<LZ4F_CDict>, prefsPtr: Option<LZ4F_preferences_t>): Int64`(L868-876)
  - 常量:`public const LZ4F_HEADER_SIZE_MIN: Int64 = 7`、`LZ4F_HEADER_SIZE_MAX: Int64 = 19`、`LZ4F_BLOCK_HEADER_SIZE: Int64 = 4`、`LZ4F_BLOCK_CHECKSUM_SIZE: Int64 = 4`、`LZ4F_CONTENT_CHECKSUM_SIZE: Int64 = 4`、`LZ4F_ENDMARK_SIZE: Int64 = 4`、`LZ4F_MAGICNUMBER: UInt32 = 0x184D2204u32`、`LZ4F_MAGIC_SKIPPABLE_START: UInt32 = 0x184D2A50u32`(lz4frame.h L281-294/L406-407;skippable 常量 M6 消费,先行落位)
- Consumes: T1 全部;LZ4_resetStream_fast/LZ4_attach_dictionary/LZ4_loadDict(lz4.cj);LZ4_resetStreamHC_fast/LZ4_attach_HC_dictionary/LZ4_loadDictHC/LZ4_favorDecompressionSpeed(lz4hc.cj);XXH32_reset/one-shot(xxhash.cj)
- 注:LZ4F_CDict 类 T4 落地,本任务 cdict 仅作 Option 透传(frhdr golden 无 cdict 行)

- [ ] **Step 1: C golden 扩展**(gen_golden.sh 编译行加 `"$HOME/lz4/lib/lz4frame.c"`;gen_golden.c 加 `#define LZ4F_STATIC_LINKING_ONLY` + `#include "lz4frame.h"` + frhdr 节):
  - `mode=frhdr` 10 行,行格式:`n=65536 mp=0.50 seed=0 mode=frhdr bs=<0|4|5|6|7> bm=<0|1> ccs=<0|1> bcs=<0|1> csz=<v> did=<v> lv=<L> size=<7|11|15|19> xxh32=.. xxh64=.. inxxh32=.. inxxh64=.. file=block/<idx>.lz4`(inxxh 为 RDG 输入摘要,格式统一;头字节即 artifact)
  - 行集(输入恒 A=(65536,0.50,0),逐行 fresh cctx + LZ4F_compressBegin(dst 19B)):①全默认(7B);②csz=65536(15B);③did=305419896(11B);④csz+did(19B);⑤ccs=1 bcs=1(7B);⑥bm=1(7B);⑦bs=5;⑧bs=6;⑨bs=7(各 7B);⑩lv=9(7B,头字节与①相同但钉 HC ctx 分配路径)
  - 门检:数据行 426+10=436,总行 436+18(注释 17+1)== 454,`grep -c '^#'`==18,`grep -c 'mode=frhdr'`==10
- [ ] **Step 2: 失败测试**(lz4frame_test.cj):
  - `lz4fBeginHdrGoldenTest`:10 行按行字段重建 prefs → Begin → size + xxh32/64 + artifact 逐字节;并直接断言魔数字节 `04 22 4D 18`、默认 FLG==0x60、BD==(bsID&7)<<4、HC==lz4fHeaderChecksum
  - `lz4fBeginStateTest`:Begin 后 cStage==1;XXH32_digest(cctx.xxh)==0x02CC5D05(空输入,证 reset);缓冲四象限(af=1+bm=0→65536;af=1+bm=1→0;af=0+bs=4+bm=0→196608;af=0+bm=1→65536);ctxType(lv=0→1/lv=9→2);同一 cctx 连续 Begin lv9→lv0(alloc 保持 2、type 归 1、快流重建、两次头字节一致)与 lv0→lv9(alloc 1→2、HC 新建)
  - `lz4fBeginErrorTest`:dstCapacity=18 → -11 且 isError 真;getErrorName(-11)=="ERROR_dstMaxSize_tooSmall"
  - `lz4fBeginDictStateTest`:Begin_usingDict(A 切 4096B, lv=0) 后 cctx.lz4CtxFast 的 dictSize==4096(internal 可见性,预热 T4)
- [ ] **Step 3: 实现**(对照 L657-876 逐行;头字节组装用安全索引直写 + XXH32;totalInSize=0 仅 csz 分支)
- [ ] **Step 4: GREEN(双工具链)+ Commit** `M5: compressBegin family with header encoding and buffer management`

---

### Task 3: 块压缩机制 + Update/uncompressedUpdate/Flush/End + frame golden 主矩阵

**Files:** src/lz4frame.cj、src/lz4frame_test.cj、src/lz4.cj、src/lz4hc.cj、scripts/gen_golden.c、scripts/gen_golden.sh、corpus/

**Interfaces:**
- Produces:
  - lz4.cj:`internal func lz4CompressExtStateFastResetAt(state: LZ4_stream_t, src: Array<UInt8>, srcIdx: Int64, srcSize: Int32, dst: Array<UInt8>, dstIdx: Int64, dstCapacity: Int32, acceleration: Int32): Int32` —— `lz4CompressExtStateBody` 增 srcIdx/dstIdx 形参重构,公开 `LZ4_compress_fast_extState_fastReset` 委托 idx=0,行为不变(M2/M3b golden 不回归即证)
  - lz4hc.cj:`internal func lz4hcExtStateHCFastResetAt(state: LZ4_streamHC_t, src: Array<UInt8>, srcIdx: Int64, srcSize: Int32, dst: Array<UInt8>, dstIdx: Int64, dstCapacity: Int32, compressionLevel: Int32): Int32`(= L2006-2018 偏移版:resetStreamHC_fast + LZ4HC_initInternal(state, src, srcIdx) + limit 择取 + lz4hcCompressRun;公开 extStateHC_fastReset 委托 idx=0)
  - lz4frame.cj 块机制:
    - `internal func lz4fSelectCompressionKind(blockMode: Int32, level: Int32, compressMode: Int32): Int32`(0=compressBlock/1=compressBlock_continue/2=compressBlockHC/3=compressBlockHC_continue/4=doNotCompress;L970-980,UNCOMPRESSED 优先)
    - `internal func lz4fCompressBlock(kind: Int32, cctx: LZ4F_cctx, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int32, dst: Array<UInt8>, dstIdx: Int64, dstCapacity: Int32): Int32`(L929-968:kind0 fast indep:acceleration=level<0?-level+1:1,lz4fInitStream(indep) 后 cdict? LZ4_compress_fast_continue: lz4CompressExtStateFastResetAt;kind1:直接 LZ4_compress_fast_continue;kind2 HC indep:cdict? LZ4_compress_HC_continue: lz4hcExtStateHCFastResetAt;kind3:LZ4_compress_HC_continue;kind4:0)
    - `internal func lz4fMakeBlock(dst: Array<UInt8>, dstIdx: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, kind: Int32, cctx: LZ4F_cctx, crcFlag: Int32): Int64`(L900-926:dstCapacity=srcSize>1?srcSize-1:1;cSize==0||cSize>=srcSize → LE32(cSize|0x80000000)+原样拷贝;否则 LE32(cSize);crcFlag→XXH32(存储区,seed 0) 追加 LE32;返回 4+cSize+crcFlag*4)
    - `internal func lz4fLocalSaveDict(cctx: LZ4F_cctx): Unit`(L983-989:level<2 → LZ4_saveDict(fast, tmpBuff, 65536) 否则 LZ4_saveDictHC(hc, tmpBuff, 65536);tmpIn = 返回 dictSize)
    - `internal func lz4fCompressUpdateImpl(cctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, cOptPtr: Option<LZ4F_compressOptions_t>, blockCompression: Int32): Int64`(L1008-1121 全量,保真点 ⑤⑥⑦:bound 检查 alreadyBuffered=tmpInSize;模式切换先 flush;cStage!=1 → -20;UNCOMPRESSED 另查 dstCapacity<srcSize;tmpIn 补块自 src 头部拷贝;整块循环自 srcIdx 起;autoFlush 余块;linked+fromSrcBuffer → stableSrc?tmpIn=0:localSaveDict;!autoFlush 且 tmpIn+blockSize>maxBufferSize → localSaveDict;余量拷入 tmpIn;ccs → XXH32_update(xxh, srcBuf, srcSize, offset: srcIdx)——注意 offset 为源位置对;totalInSize+=UInt64(srcSize))
    - `public func LZ4F_compressUpdate(cctx, dstBuf, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcIdx: Int64, srcSize: Int64, cOptPtr: Option<LZ4F_compressOptions_t>): Int64`(L1135-1144,blockCompression=COMPRESSED)
    - `public func LZ4F_uncompressedUpdate(同签名): Int64`(L1155-1164,UNCOMPRESSED)
    - `internal func lz4fFlushImpl(cctx, dstBuf, dstIdx: Int64): Int64`(L1175-1212:tmpInSize==0 先返 0;cStage!=1 → -20;dstCapacity<tmpInSize+8 → -11;makeBlock(kind 按 cctx.blockCompressMode);linked → tmpIn+=tmpInSize;tmpInSize=0;tmpIn+maxBlockSize>maxBufferSize → localSaveDict)
    - `public func LZ4F_flush(cctx, dstBuf, dstIdx: Int64, dstCapacity: Int64, cOptPtr: Option<LZ4F_compressOptions_t>): Int64`(cOptPtr 目前仅占位,C 亦未用,注释)
    - `public func LZ4F_compressEnd(cctx, dstBuf, dstIdx: Int64, dstCapacity: Int64, cOptPtr: Option<LZ4F_compressOptions_t>): Int64`(L1224-1259:flush → 错误透传;endmark 4×0x00(dstCapacity<4 → -11);ccs → XXH32_digest LE32(dstCapacity<8 → -11);cStage=0;csz≠0 且 ≠totalInSize → -14)
- Consumes: T1/T2 全部;LZ4_compress_fast_continue(lz4.cj 公开偏移);LZ4_compress_HC_continue(lz4hc.cj 公开偏移);LZ4_saveDict/saveDictHC;XXH32_update/digest

- [ ] **Step 1: C golden 扩展**(frame 节,注释 1 条):
  - `mode=frame` 27 行,行格式:`n=<n> mp=<mp> seed=<seed> mode=frame bs=<4..7> bm=<0|1> ccs=<0|1> bcs=<0|1> csz=<v> did=<v> lv=<L> af=<0|1> ss=<0|1> sc=<1shot|chunks<k>|flushmid|umix> size=<c> xxh32=.. xxh64=.. inxxh32=.. inxxh64=.. [file=block/<idx>.lz4]`
  - 场景(fresh cctx/行;dst 单缓冲 = LZ4F_compressFrameBound(n, &prefs),逐调用前移指针、容量 = 剩余;ss=1 行给 Update 传 {stableSrc=1}):
    1-7. A=(65536,0.50,0) sc=1shot:①默认(af=0 ss=0);②af=1;③ccs=1;④bcs=1;⑤ccs=1 bcs=1;⑥bm=1;⑦bm=1 ccs=1 bcs=1
    8-20. C=(131072,0.90,0) sc=1shot:⑧默认(多块 localSaveDict);⑨ss=1;⑩af=1;⑪bm=1;⑫lv=3;⑬lv=9;⑭lv=12;⑮lv=12 fav=1;⑯lv=-3(accel=4);⑰bs=5;⑱bs=6;⑲bs=7;⑳csz=131072
    21. C sc=flushmid(Update 50000 → flush → Update 余 → End,af=0)
    22. C bm=1 sc=umix(Update 65536 → uncompressedUpdate 32768 → Update 32768 → End;模式切换 flush)
    23. C sc=chunks5(5 段 26214/26215,af=0,跨调用缓冲累积)
    24-26. D=(255,0.50,0)/G=(1,0.00,0)/F=(0,0.00,0) 默认 sc=1shot;F 行 ccs=1(Begin+End,空内容校验和 0x02CC5D05 钉入帧尾)
    27. A did=42 sc=1shot
  - 门检:数据行 436+27=463,总行 463+19(注释 18+1)== 482,`grep -c '^#'`==19,`grep -c 'mode=frame '`==27
- [ ] **Step 2: 失败测试**(lz4frame_test.cj):
  - `lz4fFrameGoldenTest`:27 行重建 prefs/场景 → 逐字节 + digest + artifact;**独立块闭环**:bm=1 行解析自身输出(跳头 7/15B,按 4B 块头迭代至 endmark,最高位未压缩则原样切),每块 LZ4_decompress_safe == 对应输入切片;**ccs 闭环**:ccs=1 行尾 4B == XXH32(输入, seed 0)
  - `lz4fUpdateStateTest`:af=0 下 chunks5 前 2 次 Update 返回 0(全缓冲,26214×2<65536);tmpInSize 累积断言;csz 行 totalInSize 演进;A 默认行单 Update 返回 0(恰一块满,入 tmpBuff)、End flush 出块
  - `lz4fUpdateErrorTest`:未 Begin 先 Update → -20;dstCapacity=compressBound-1 → -11;End 时 csz=1(≠实际)→ -14 且 isError;错误后状态废弃(上游契约,不测复用)
  - `lz4fFlushQuirkTest`:fresh cctx(未 Begin)flush → 0(tmpInSize==0 先于 cStage 检查);Begin 后无数据 flush → 0;buffering 后 flush 返回块字节数;再 flush → 0
  - `lz4fUncompressedSemanticsTest`:bm=1 umix 序列仓颉侧重放 == C golden 行 22;uncompressedUpdate 于 af=0 下先缓冲后切模式 flush 的返回值序列钉住(0/块/0/块)
- [ ] **Step 3: 实现**(lz4.cj/lz4hc.cj At 变体重构先行,跑既有全量确认不回归;再对照 L900-1259 逐行落 lz4frame.cj;XXH32_update 的 offset 具名参传 srcIdx)
- [ ] **Step 4: GREEN(双工具链)+ Commit** `M5: block machinery, update/flush/end and frame golden matrix`

---

### Task 4: CDict + compressFrame 一次性族 + fuzz + M5 收尾

**Files:** src/lz4frame.cj、src/lz4frame_test.cj、src/fuzz_test.cj、scripts/gen_golden.c、scripts/gen_golden.sh、corpus/、docs/progress.md、CHANGELOG.md、README.md、docs/design.md(如订正遗漏)

**Interfaces:**
- Produces:
  - `public class LZ4F_CDict { internal var dictContent: Array<UInt8>; internal var fastCtx: LZ4_stream_t; internal var HCCtx: LZ4_streamHC_t }`(L533-538)
  - `public func LZ4F_createCDict(dictBuffer: Array<UInt8>, dictSize: Int64): LZ4F_CDict`(L540-588:>64KB 截尾拷贝 dictContent;LZ4_initStream(fastCtx) + LZ4_loadDictSlow(fastCtx, dictContent, size);LZ4_initStreamHC(HCCtx) + LZ4_setCompressionLevel(HCCtx, LZ4HC_CLEVEL_DEFAULT) + LZ4_loadDictHC(HCCtx, dictContent, size);C 的 NULL 入参/分配失败模式不可达,注释登记)
  - `public func LZ4F_freeCDict(cdict: LZ4F_CDict): Unit`(GC no-op)
  - `public func LZ4F_compressFrame_usingCDict(cctx: LZ4F_cctx, dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcSize: Int64, cdict: Option<LZ4F_CDict>, preferencesPtr: Option<LZ4F_preferences_t>): Int64`(L430-476:prefs=None → 零值默认;csz≠0 → 改写为 srcSize;optimalBSID;srcSize≤getBlockSize → 强制 independent;autoFlush=1;options{stableSrc=1};dstCapacity<compressFrameBound → -11;Begin_usingCDict → Update → End 链,内部传 dstIdx 递进)
  - `public func LZ4F_compressFrame(dstBuf: Array<UInt8>, dstIdx: Int64, dstCapacity: Int64, srcBuf: Array<UInt8>, srcSize: Int64, preferencesPtr: Option<LZ4F_preferences_t>): Int64`(L486-526 HEAPMODE=0 等价:临时 cctx(GC),version=LZ4F_VERSION,maxBufferSize=5MB 防分配 hack(注释:依赖 af=1+ss=1,tmpBuff 恒不分配);prefs==None 或 level<2 → 预置 LZ4_stream_t(initStream)+alloc=1/type=ctxFast;委托 usingCDict(None))
- Consumes: T1-T3 全部;LZ4_loadDictSlow/LZ4_initStream(lz4.cj);LZ4_initStreamHC/LZ4_setCompressionLevel/LZ4_loadDictHC(lz4hc.cj)

- [ ] **Step 1: C golden 扩展**(3 个新节,注释 3 条):
  - `mode=f1s` 8 行(行格式 `… mode=f1s lv=<L> [csz=<1|auto>] [did=<v>] [ccs=<1>] [bcs=<1>] size=… xxh32=… …`):①A prefs=NULL;②B=(65536,0.90,7) lv=3;③B lv=9;④B lv=12;⑤C lv=9(多块 linked 保留);⑥A csz=1(自动改写为 65536);⑦A did=305419896 ccs=1;⑧A lv=-3
  - `mode=fcd` 2 行(`… dd=<dictSize> dmp=0.50 dseed=<seed> lv=<L> [bm=1] …`):①A dd=65536 dseed=99 lv=0(单块,CDict 快路径);②C bm=1 dd=65536 dseed=99 lv=9(独立多块,每块 attach)
  - `mode=fdt` 2 行(同上字段,经 LZ4F_compressBegin_usingDict):①A dd=65536 dseed=99 lv=0 bm=0(linked,loadDict at Begin);②C dd=64 dseed=77 lv=9 bm=1(上游"仅首块用字典"怪癖钉住:首块有字典增益,后续块无)
  - 字典均 RDG(dmp=0.50, dseed);harness 每行 fresh cctx;dst = compressFrameBound
  - 门检:数据行 463+12=475,总行 475+22(注释 19+3)== 497,`grep -c '^#'`==22,`grep -c 'mode=f1s '`==8,`grep -c 'mode=fcd '`==2,`grep -c 'mode=fdt '`==2;corpus 体积复查 ≤ 8MB
- [ ] **Step 2: 失败测试**(lz4frame_test.cj):
  - `lz4fFrameOneShotGoldenTest`:f1s 8 行逐字节 + digest + artifact(NULL prefs 行传 None)
  - `lz4fCDictGoldenTest`:fcd 2 行逐字节(字典 RDG 再生 → createCDict → compressFrame_usingCDict)
  - `lz4fBeginDictGoldenTest`:fdt 2 行逐字节(compressBegin_usingDict + Update + End)
  - `lz4fCDictUnitTest`:>64KB 字典(131072B)→ dictContent.size==65536(截尾);fastCtx/HCCtx 预消化断言(以同一输入块对比:createCDict 流的首块输出 == 直接 loadDict/loadDictHC 新流的首块输出,逐字节)
  - `lz4fFrameEquivalenceTest`(仓颉内自证):compressFrame(A, None) == Begin/Update/End 手工链(prefs{bm=1, af=1} + options{ss=1},由四联变换推导)逐字节;compressFrame(B, lv9) 同法
  - `lz4fFrameBoundGuaranteeTest`:对 golden 全部 f1s/frame 行参数,断言 产物 size ≤ compressFrameBound(n, prefs)
- [ ] **Step 3: 实现**(对照 L430-526、L533-597;compressFrame 的 5MB hack 与预置 fast 流两分支逐条)
- [ ] **Step 4: fuzz 扩展**(src/fuzz_test.cj)`fuzzFrameTest`:120 种子,每种子随机 {n∈[0,150000]、mp、bs∈{4,5,6,7}、bm、ccs、bcs、af、lv∈{-3,0,3,9,12}、ss、chunks∈[1,6]}:
  - 场景 A:compressFrame 一次成帧;场景 B:Begin + 随机切分 Update(bm=1 时随机插入 uncompressedUpdate,含模式切换)+ 随机中途 flush + End
  - 断言:无异常逃逸;各调用返回非错误(容量恒给 compressFrameBound);总输出 == 各段返回和;endmark 4×0x00 位于 [total-4-ccs*4, total-4);ccs=1 → 尾 4B == XXH32(拼接输入);bm=1 → 逐块 LZ4_decompress_safe 闭环 == 输入切片;同参数二次运行逐字节确定
- [ ] **Step 5: 覆盖率门禁**:`cjcov --html-details`(LTS);库源码行覆盖 ≥ 96%(基线 96.60%,frame 新增约 900-1000 行);未覆盖行逐条归类(防御/不可达/台账登记 M7)
- [ ] **Step 6: 文档收尾**:progress.md(M5 行 + 证据数字 + API 计数更新 frame 压缩侧 14 函数 + 常量族 + 台账处置;下一步 M6);CHANGELOG 0.6.0(frame 压缩侧全量 + golden 475 行 + 覆盖率 + 双绿 + corpus 政策);README API 对照表 frame 节(枚举 Int32 承载、位置对签名、createCompressionContext 出参、reserved 省略、usingDict 仅首块语义注记)+ **golden 语料再生工作流一节**(corpus 不入库;`scripts/gen_golden.sh` 依赖 cc 与 ~/lz4@0774d055;测试摘要断言自足,artifacts 存在时才逐字节比对)
- [ ] **Step 7: 全量门禁 `scripts/build_and_test.sh both` + Commit** `M5: CDict, one-shot frame family, fuzz and milestone wrap-up`

---

- 修订记录:2026-10-01 执行前依用户裁定追加 corpus 政策(T1 Step 1 政策提交、M5 新测试 artifact 优雅降级、T4 README 再生工作流、design §8.2 注记);golden 行数与门检数字不变。

## Self-Review 记录

- 规格覆盖:设计 §4.5 frame 压缩侧清单全承接 —— 版本/错误 5(isError/getErrorName/getErrorCode/getVersion/compressionLevel_max)、getBlockSize(T1,设计列于解压节,M6 复用)、compressFrameBound(T1)、compressBound(T1)、create/freeCompressionContext(T1)、Begin/Begin_usingDict/Begin_usingCDict(T2)、compressUpdate/uncompressedUpdate/flush/compressEnd(T3)、compressFrame/compressFrame_usingCDict(T4)、createCDict/freeCDict(T4);类型与五枚举(T1,Int32 常量族裁决);头编码单测(T2 frhdr + 字节断言);design 订正(usingDict 补记、不移植 3 项、枚举承载注记)落 T1 Step 4。M5 验收标准(frame 产物与 C golden 一致 L3 单向 + 头编码单测 + 双绿)由 T2-T4 golden(49 新行)与各任务双绿门禁覆盖。
- 类型一致性:长度/返回 Int64;位置对 (buf, idx) 全任务统一;Option<T> 承接可空指针;LZ4F_cctx 字段名与状态模型逐字;At 变体命名沿 lz4CompressExtStateFastResetAt / lz4hcExtStateHCFastResetAt(先例 *At 无先例,取 M3b 惯例的动宾后缀);错误常量 Int64 与 getBlockSize 返回 Int64 一致。
- 占位扫描:无 TBD/TODO;T2 的 cdict 参数为透传占位(LZ4F_CDict 类 T4 落地,接口已定义);lz4fFlushImpl 的 cOptPtr 未消费与上游一致(注释)。
- 已知风险:①XXH32_update 的 offset 具名参必须传 srcIdx(源位置对),传 0 会漏哈希块首区段——ccs 闭环测试兜底;②compressFrame 的 5MB hack 在仓颉的等价物是"tmpBuff 恒空数组",依赖 af=1+ss=1 不变量,若 prefs 变换遗漏会空引用——equivalence 测试钉住;③换型分支(fast↔HC 同 cctx 复用)是状态重建而非 C 原地重解释,输出等价但分配行为不同——Begin 状态测试钉 alloc/type 标记;④linked+uncompressedUpdate 组合上游仅 release 可达(debug assert),golden 刻意避开(umix 行 bm=1),仓颉不复刻 assert,注释登记;⑤localSaveDict 依赖 saveDict/saveDictHC 对 tmpBuff 的原位拷贝,两函数均已存在且 golden 验证过;⑥f1s 行 ⑤(C lv9 多块 linked)与 frame 行 ⑬(lv9 sc=1shot)输入相同但 prefs 变换不同(autoFlush/bm),字节应不同——防行间误拷贝,测试分别独立断言。


