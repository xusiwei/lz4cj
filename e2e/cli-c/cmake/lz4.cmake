# Fetch the exact upstream baseline used by the lz4cj parity tests.
# To use an existing checkout without network access, configure with
# -DFETCHCONTENT_SOURCE_DIR_LZ4=<absolute path to lz4>.
include(FetchContent)

# Upstream's CMake project lives in build/cmake and provides lz4_static.
set(LZ4_BUNDLED_MODE ON CACHE BOOL "Build LZ4 as a bundled dependency" FORCE)
set(LZ4_BUILD_CLI OFF CACHE BOOL "Do not build upstream CLI" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build the static LZ4 library" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "Build the static LZ4 library" FORCE)

FetchContent_Declare(lz4
    GIT_REPOSITORY https://github.com/lz4/lz4.git
    GIT_TAG 0774d05537f9762f838f7ab541b7765f1a729cb5
    SOURCE_SUBDIR build/cmake
)
FetchContent_MakeAvailable(lz4)

if(NOT TARGET lz4_static)
    message(FATAL_ERROR "FetchContent did not provide the lz4_static target")
endif()

# Match the former in-tree build's warning level for upstream C sources.
if(MSVC)
    target_compile_options(lz4_static PRIVATE /W1)
endif()
