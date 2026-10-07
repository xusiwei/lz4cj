cmake_minimum_required(VERSION 3.18)
project(lz4cli C)

include(cmake/lz4.cmake)

add_executable(lz4cli lz4cli.c)
target_link_libraries(lz4cli PRIVATE lz4_static)
# Keep the small wrapper's MSVC warnings concise.
if(MSVC)
    target_compile_options(lz4cli PRIVATE /W1)
endif()
