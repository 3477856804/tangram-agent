#!/usr/bin/env bash
# 桌面端（Linux / macOS）构建 stable-diffusion.cpp，供 Dart FFI 加载。
# Windows 请在 PowerShell / MSVC 环境执行等价 cmake 命令。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build/sdcpp-desktop"

cmake -S "${ROOT}/native/sdcpp" -B "${BUILD}" -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD}" --target stable-diffusion -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

echo "构建完成：${BUILD}/sdcpp"
echo "Linux 运行前把该目录加入 LD_LIBRARY_PATH；macOS 放入 .app/Contents/Frameworks。"
