cmake_minimum_required(VERSION 3.22)
project(squeezeagent CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_library(log-lib log)
find_library(z-lib z)

# Vendored AOSP slicer (dex IR + instrumentation: provides ExitHook/EntryHook).
file(GLOB SLICER_SRC third_party/slicer/*.cc)
add_library(slicer STATIC ${SLICER_SRC})
target_include_directories(slicer PUBLIC third_party/slicer/export)
target_link_libraries(slicer ${z-lib})
target_compile_options(slicer PRIVATE -Wno-unused-parameter -Wno-deprecated-declarations)

add_library(squeezeagent SHARED squeeze_agent.cc squeeze_transform.cc)
target_include_directories(squeezeagent PRIVATE include third_party/slicer/export)
target_link_libraries(squeezeagent slicer ${log-lib} ${z-lib})

# 16 KB page-size devices (Android 15+ hardware, `sdk_gphone16k_*` emulators) refuse
# to dlopen an ELF whose LOAD segments are 4 KB-aligned:
#   "program alignment (4096) cannot be smaller than system page size (16384)"
# NDK r27 only emits 16 KB alignment behind an opt-in (r28 makes it the default), so pin
# it on the target here rather than via the toolchain's ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES
# — this way it holds however the agent is built, not only through agent/build.sh.
# Harmless on 4 KB devices: the loader requires p_align >= page size, and 16384 is a
# multiple of 4096, so a 16 KB-aligned library maps fine on both.
target_link_options(squeezeagent PRIVATE "-Wl,-z,max-page-size=16384")
