# Reference (C) side of the lz4cj e2e suite: builds lz4cli against the
# upstream lz4 C sources compiled in-tree (same baseline checkout the
# port is validated against, commit 0774d055).
#
# Upstream source location resolution order:
#   1. cmake -DLZ4_PATH=/path/to/lz4
#   2. environment variable LZ4CJ_UPSTREAM
#   3. $HOME/lz4            (same default as scripts/gen_golden.sh)
cmake_minimum_required(VERSION 3.16)
project(lz4cli C)

if(NOT DEFINED LZ4_PATH)
    if(DEFINED ENV{LZ4CJ_UPSTREAM})
        set(LZ4_PATH "$ENV{LZ4CJ_UPSTREAM}")
    else()
        set(LZ4_PATH "$ENV{HOME}/lz4")
    endif()
endif()

if(NOT EXISTS "${LZ4_PATH}/lib/lz4.c")
    message(FATAL_ERROR
        "upstream lz4 sources not found at '${LZ4_PATH}'. "
        "Set -DLZ4_PATH=<lz4 checkout> or LZ4CJ_UPSTREAM, or clone: "
        "git clone https://github.com/lz4/lz4 ~/lz4 && git -C ~/lz4 checkout 0774d055")
endif()

add_executable(lz4cli
    lz4cli.c
    "${LZ4_PATH}/lib/lz4.c"
    "${LZ4_PATH}/lib/lz4hc.c"
    "${LZ4_PATH}/lib/lz4frame.c"
    "${LZ4_PATH}/lib/xxhash.c")
target_include_directories(lz4cli PRIVATE "${LZ4_PATH}/lib")
# MSVC: silence the upstream C sources' secure-CRT warnings
if(MSVC)
    target_compile_options(lz4cli PRIVATE /W1)
endif()
