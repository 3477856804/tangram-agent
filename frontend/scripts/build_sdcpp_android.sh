#!/usr/bin/env bash
# 构建 Android arm64 的 stable-diffusion.cpp，并放进 Flutter jniLibs。
# 用法：
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build_sdcpp_android.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANDROID_NDK_HOME:?请设置 ANDROID_NDK_HOME 指向 Android NDK}"
ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
BUILD="${ROOT}/build/sdcpp-android-${ABI}"

case "${ABI}" in
  arm64-v8a) TRIPLE=aarch64-linux-android ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
  x86_64) TRIPLE=x86_64-linux-android ;;
  *) echo "不支持的 ABI: ${ABI}" >&2; exit 1 ;;
esac

TOOLCHAIN="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
cmake -S "${ROOT}/native/sdcpp" -B "${BUILD}" \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
  -DANDROID_ABI="${ABI}" \
  -DANDROID_PLATFORM="android-${API}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}${API}-clang" \
  -DCMAKE_CXX_COMPILER="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}${API}-clang++"

cmake --build "${BUILD}" --target stable-diffusion -j"$(nproc)"

OUT="${ROOT}/android/app/src/main/jniLibs/${ABI}"
mkdir -p "${OUT}"
cp "${BUILD}/sdcpp/libstable-diffusion.so" "${OUT}/libstable-diffusion.so"
echo "已输出: ${OUT}/libstable-diffusion.so"
