cmake_minimum_required(VERSION 3.20)
project(tga_sdcpp LANGUAGES C CXX)

# 统一构建 stable-diffusion.cpp 共享库，供 Dart FFI 加载。
# 上游源码通过 git submodule 固定在仓库根目录 third_party/stable-diffusion.cpp。
set(SDCPP_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../third_party/stable-diffusion.cpp")
if(NOT EXISTS "${SDCPP_ROOT}/CMakeLists.txt")
  message(FATAL_ERROR "缺少 stable-diffusion.cpp 子模块，请先执行 git submodule update --init --recursive")
endif()

set(SD_BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(SD_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SD_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(SD_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(SD_WEBP OFF CACHE BOOL "" FORCE)
set(SD_WEBM OFF CACHE BOOL "" FORCE)

if(ANDROID)
  # 手机端优先 Vulkan；没有可用 GPU 时上游会回落 CPU。
  set(SD_VULKAN ON CACHE BOOL "" FORCE)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -fvisibility=hidden")
elseif(APPLE)
  set(SD_METAL ON CACHE BOOL "" FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "" FORCE)
elseif(WIN32)
  set(SD_VULKAN ON CACHE BOOL "" FORCE)
else()
  set(SD_VULKAN ON CACHE BOOL "" FORCE)
endif()

add_subdirectory("${SDCPP_ROOT}" "${CMAKE_BINARY_DIR}/sdcpp")

# 统一输出名：libstable-diffusion.so / .dylib / stable-diffusion.dll
set_target_properties(stable-diffusion PROPERTIES OUTPUT_NAME "stable-diffusion")
