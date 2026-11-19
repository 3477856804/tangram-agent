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

option(TGA_SD_VULKAN "启用 Vulkan 后端（需要 Vulkan SDK/驱动）" OFF)
if(ANDROID)
  # 默认 CPU，构建机装好 Vulkan SDK 后可 -DTGA_SD_VULKAN=ON。
  set(SD_VULKAN ${TGA_SD_VULKAN} CACHE BOOL "" FORCE)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -fvisibility=hidden")
elseif(APPLE)
  set(SD_METAL ON CACHE BOOL "" FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "" FORCE)
elseif(WIN32)
  set(SD_VULKAN ${TGA_SD_VULKAN} CACHE BOOL "" FORCE)
else()
  # Linux CI 常常没有 Vulkan SDK，默认 CPU，显式打开需 -DTGA_SD_VULKAN=ON。
  set(SD_VULKAN ${TGA_SD_VULKAN} CACHE BOOL "" FORCE)
endif()

add_subdirectory("${SDCPP_ROOT}" "${CMAKE_BINARY_DIR}/sdcpp")

# 统一输出名：libstable-diffusion.so / .dylib / stable-diffusion.dll
set_target_properties(stable-diffusion PROPERTIES OUTPUT_NAME "stable-diffusion")
