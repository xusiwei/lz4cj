package print_version

/* 最简示例(概念源自上游 examples/print_version.c):只调用版本 API,
   是链接成功的 "hello world"。 */

import lz4.*

main(): Int64 {
    println("Hello World! LZ4 Library version = ${LZ4_versionNumber()}")
    println("version string: ${LZ4_versionString()}")
    return 0
}
