// Standalone repro attempt for the Windows x64 wrong-bounds-check bug seen
// in fuzzFrameDecodeTest (both cangjie 1.0.5 & 1.2.0 windows-x64):
// after loading the size from a HEAP array and storing to consecutive
// constant indices [0..6], the [7] store throws
//   IndexOutOfBoundsException: The length of the array is 3691, but the index is 7.
// although sf.size == 3691 (verified by print right before).
// Build: cjc scripts/oob_repro.cj -o scripts/oob_repro_lt && scripts/oob_repro_lt

func fillSkippable(segSkipSize: Array<Int64>): Array<UInt8> {
    let sz = segSkipSize[0]
    let sf = Array<UInt8>(8 + sz, {_ => 0u8})
    println("constructed sf.size=${sf.size}")
    sf[0] = 0x50u8
    sf[1] = 0x2Au8
    sf[2] = 0x4Du8
    sf[3] = 0x18u8
    sf[4] = UInt8(sz & 0xFF)
    sf[5] = UInt8((sz >> 8) & 0xFF)
    sf[6] = UInt8((sz >> 16) & 0xFF)
    sf[7] = UInt8((sz >> 24) & 0xFF)   // <-- bogus OOB on windows-x64
    return sf
}

main(): Int64 {
    let segSkipSize = Array<Int64>(3, {_ => 3683})
    let sf = fillSkippable(segSkipSize)
    println("store7 OK, sf.size=${sf.size}")
    return 0
}
