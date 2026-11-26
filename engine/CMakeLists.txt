cmake_minimum_required(VERSION 3.16)
project(ambi_engine CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
# tune for the build machine: -march=native (x86, recent clang / gcc), else -mcpu=native
# (Apple clang on Apple Silicon), else no tuning
include(CheckCXXCompilerFlag)
check_cxx_compiler_flag("-march=native" HAVE_MARCH_NATIVE)
check_cxx_compiler_flag("-mcpu=native" HAVE_MCPU_NATIVE)
if(HAVE_MARCH_NATIVE)
  set(NATIVE_FLAG "-march=native")
elseif(HAVE_MCPU_NATIVE)
  set(NATIVE_FLAG "-mcpu=native")
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -ffast-math ${NATIVE_FLAG}")

find_package(PkgConfig REQUIRED)
pkg_check_modules(JACK REQUIRED jack)
find_package(Threads REQUIRED)
set(LINK_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/link)
if(NOT EXISTS ${LINK_DIR}/AbletonLinkConfig.cmake OR NOT EXISTS ${LINK_DIR}/modules/asio-standalone/asio/include)
  message(FATAL_ERROR "Ableton Link is missing in engine/third_party/link. Run:\n"
    "  git submodule update --init --recursive\n"
    "or, outside a git checkout:\n"
    "  git clone --recursive https://github.com/Ableton/link.git engine/third_party/link")
endif()
include(${LINK_DIR}/AbletonLinkConfig.cmake)

add_executable(ambi-engine
  src/main.cpp
  src/engine.cpp
  src/decoder.cpp
)
target_include_directories(ambi-engine PRIVATE ${JACK_INCLUDE_DIRS})
target_link_libraries(ambi-engine PRIVATE ${JACK_LIBRARIES} Threads::Threads Ableton::Link)
target_compile_options(ambi-engine PRIVATE -Wall -Wextra -Wno-unused-parameter)
