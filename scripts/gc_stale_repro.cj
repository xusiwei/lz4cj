// M7 Task 6 investigation (#47): minimal repro attempt for the GC stale-read
// phenomenon observed during M5 - under heavy GC pressure, an interleaved
// byte-compare loop over two arrays occasionally read stale values from the
// OTHER array (re-read was consistent). This standalone program reproduces
// the shape: two large arrays with distinct byte patterns + an interleaved
// index loop + allocation churn to force collections. A mismatch is
// immediately re-read once; only a mismatch that PERSISTS on re-read counts
// as a genuine observation (transient mismatches are the phenomenon).
// Build (LTS): source ~/sdk/cangjie-1.0.5/envsetup.sh && \
//   cjc scripts/gc_stale_repro.cj -o scripts/gc_stale_repro_lt
// Build (STS): source ~/sdk/cangjie-1.2.0/envsetup.sh && \
//   cjc scripts/gc_stale_repro.cj -o scripts/gc_stale_repro_st
// Usage: scripts/gc_stale_repro_lt [rounds]

main(): Int64 {
    let rounds: Int64 = 16
    let n: Int64 = 16 * 1024 * 1024
    let a = Array<UInt8>(n, {i => UInt8(i & 0xFF)})          /* ramp */
    let b = Array<UInt8>(n, {i => UInt8((i ^ 0xFF) & 0xFF)}) /* mirrored */
    var transient = 0
    var persistent = 0
    var r: UInt64 = 12345
    for (round in 0..rounds) {
        /* allocation churn: short-lived arrays to pressure the GC */
        var churn: Int64 = 0
        while (churn < 64) {
            let seed = churn
            let junk = Array<UInt8>(65536, {i => UInt8((i + seed) & 0xFF)})
            if (junk.size == 65536) {         /* keep junk alive briefly */
                churn += 1
            }
        }
        /* interleaved compare: expected value depends on which array */
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
            r ^= r << 13u64
            r ^= r >> 7u64
            r ^= r << 17u64
            i = Int64(r % UInt64(n))
            steps += 1
        }
    }
    println("gc_stale_repro: rounds=${rounds} transient=${transient} persistent=${persistent}")
    return 0
}
