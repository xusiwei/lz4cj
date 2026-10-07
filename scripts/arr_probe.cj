// Minimal repro for the Windows array-bounds-check anomaly seen in
// fuzzFrameDecodeTest (fuzz_test.cj:1235): sf[7] on an Array<UInt8>
// of length 8+sz (sz in 0..5000) throws IndexOutOfBoundsException
// although 7 < size. Run under both SDKs:
//   cjc scripts/arr_probe.cj -o scripts/arr_probe_lt && scripts/arr_probe_lt
main(): Int64 {
    let sz: Int64 = 4216                       // failing case: length 4224
    let sf = Array<UInt8>(8 + sz, {_ => 0u8})
    println("constructed size=${sf.size}")
    sf[7] = UInt8((sz >> 24) & 0xFF)           // <-- threw here on win-1.0.5
    println("write [7] ok")
    sf[0] = 0x50u8
    sf[4] = UInt8(sz & 0xFF)
    sf[sf.size - 1] = 0x2Au8
    println("write [0],[4],[size-1] ok")
    // sweep a few sizes to map the misbehavior window, if any
    var bad = 0
    for (s in 0..5001) {
        let a = Array<UInt8>(8 + Int64(s), {_ => 0u8})
        try {
            a[7] = 1u8
        } catch (e: Exception) {
            println("OOB at size=${a.size} index=7: ${e}")
            bad += 1
            if (bad >= 5) { break }
        }
    }
    println(if (bad == 0) { "sweep clean" } else { "sweep found ${bad}+ bad sizes" })
    return 0
}
