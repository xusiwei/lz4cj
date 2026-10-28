package gc_stale_repro

/* GC 陈旧读复现程序(M7 Task 6 调查 #47;原 scripts/gc_stale_repro.cj,
   2026-10-28 搬入 examples/ 并函数化,比对语义逐字保留)。
   背景:M5 期间观察到的疑似现象 —— 重 GC 压力下,对两个数组的交错逐字节
   比较循环偶发读到"另一个数组"的陈旧值(复读一次则一致)。本程序构造同形状:
   两个 16MB 互补模式数组 + 随机索引交错比较 + 短命分配压制造 GC。
   判定口径:失配立即复读一次;只有复读仍失配才计 persistent(真陈旧),
   复读即一致计 transient(疑似瞬态)。
   结论(M7-T6,2026-10-02):双工具链共 10 轮(LTS×9/STS×1)零观测 —— 未复现,
   现象关闭;如复发,以本程序为起点(refer docs/progress.md #47)。 */

/* xorshift64 伪随机:驱动随机索引序列 */
func xorshift64(r: UInt64): UInt64 {
    var x = r
    x ^= x << 13u64
    x ^= x >> 7u64
    x ^= x << 17u64
    return x
}

/* 分配压:64 个 64KB 短命数组迫使 GC 在比较轮次之间发生 */
func churnRound(): Unit {
    var churn: Int64 = 0
    while (churn < 64) {
        let seed = churn
        let junk = Array<UInt8>(65536, { i => UInt8((i + seed) & 0xFF) })
        if (junk.size == 65536) {         /* 引用 junk,延迟其回收 */
            churn += 1
        }
    }
}

/* 一轮探测:随机索引交错读 a/b 并与各自期望模式比对,失配即复读定级。
   返回 (下一轮 rng 状态, 瞬态计数, 持续计数)。 */
func probeRound(a: Array<UInt8>, b: Array<UInt8>, n: Int64,
                seed: UInt64, round: Int64): (UInt64, Int64, Int64) {
    var r = seed
    var transient: Int64 = 0
    var persistent: Int64 = 0
    var i: Int64 = Int64(r % 997)
    var steps: Int64 = 0
    while (steps < 2000000) {
        let wantA = UInt8(i & 0xFF)
        let gotA = a[i]
        if (gotA != wantA) {
            if (a[i] != wantA) {
                persistent += 1
                println("PERSISTENT stale read on A at ${i}: got ${gotA} want ${wantA} round ${round}")
            } else {
                transient += 1
            }
        }
        let wantB = UInt8((i ^ 0xFF) & 0xFF)
        let gotB = b[i]
        if (gotB != wantB) {
            if (b[i] != wantB) {
                persistent += 1
                println("PERSISTENT stale read on B at ${i}: got ${gotB} want ${wantB} round ${round}")
            } else {
                transient += 1
            }
        }
        r = xorshift64(r)
        i = Int64(r % UInt64(n))
        steps += 1
    }
    return (r, transient, persistent)
}

main(): Int64 {
    let rounds: Int64 = 16
    let n: Int64 = 16 * 1024 * 1024
    let a = Array<UInt8>(n, { i => UInt8(i & 0xFF) })          /* ramp 模式 */
    let b = Array<UInt8>(n, { i => UInt8((i ^ 0xFF) & 0xFF) }) /* 镜像模式 */
    var transient: Int64 = 0
    var persistent: Int64 = 0
    var r: UInt64 = 12345
    for (round in 0..rounds) {
        churnRound()
        let (nr, t, p) = probeRound(a, b, n, r, round)
        r = nr
        transient += t
        persistent += p
    }
    println("gc_stale_repro: rounds=${rounds} transient=${transient} persistent=${persistent}")
    return 0
}
