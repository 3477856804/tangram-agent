#!/usr/bin/env bash
#
# 构建内置 edwl（多线程分片下载器），产物落到后端可执行目录。
#
# 用法：
#   scripts/build_edwl.sh [-h|--help]
#
# 产物：backend/app/models/bin/edwl（Windows 下为 edwl.exe）
#
# 依赖：C 编译器（gcc/clang，C11）+ libcurl 开发包 + CMake >= 3.16 + pkg-config。
#   Windows(MSYS2): 必须在 MINGW64 环境里构建（纯 MSYS 环境会因路径反斜杠丢失而失败）
#                   MSYSTEM=MINGW64 bash scripts/build_edwl.sh
#                   pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-cmake \
#                   mingw-w64-x86_64-ninja mingw-w64-x86_64-pkg-config \
#                   mingw-w64-x86_64-curl-winssl
#   Debian/Ubuntu:  sudo apt install build-essential cmake pkg-config libcurl4-openssl-dev
#
# 约定：set -euo pipefail；不写死绝对路径；失败即退出，不产出一个坏二进制冒充成功。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${REPO_ROOT}/third_party/edwl"
BUILD_DIR="${SRC_DIR}/build"
OUT_DIR="${REPO_ROOT}/backend/app/models/bin"

CMAKE="${CMAKE:-cmake}"
JOBS="${JOBS:-}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help)
			sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "未知参数: $1" >&2
			exit 2
			;;
	esac
done

if [[ ! -f "${SRC_DIR}/CMakeLists.txt" ]]; then
	echo "错误: 未找到 edwl 源码 ${SRC_DIR}/CMakeLists.txt" >&2
	exit 1
fi

if ! command -v "${CMAKE}" >/dev/null 2>&1; then
	echo "错误: 找不到 ${CMAKE}，请先安装 CMake >= 3.16" >&2
	exit 1
fi

if [[ -z "${JOBS}" ]]; then
	if command -v nproc >/dev/null 2>&1; then
		JOBS="$(nproc)"
	else
		JOBS="4"
	fi
fi

echo "==> 配置 edwl（${SRC_DIR}）"
# 编译器由 PATH 决定（Windows 上请在 MINGW64 环境里跑，见脚本头注释）：
#   纯 MSYS 环境下 CMake 会把编译器路径的反斜杠喂给 /bin/sh，结果“找到编译器却
#   无法编译简单测试程序”；路径还带空格时更糟。可用 EDWL_CC 显式指定。
EXTRA_ARGS=()
if [[ -n "${EDWL_CC:-}" ]]; then
	EXTRA_ARGS+=("-DCMAKE_C_COMPILER=${EDWL_CC}")
fi
echo "    编译器: $(command -v gcc || echo 未找到 gcc)  环境: ${MSYSTEM:-unknown}"

"${CMAKE}" -S "${SRC_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release \
	-DEDWL_BUILD_TESTS=ON "${EXTRA_ARGS[@]}"

echo "==> 编译（-j ${JOBS}）"
"${CMAKE}" --build "${BUILD_DIR}" -j "${JOBS}"

BIN=""
for candidate in "${BUILD_DIR}/edwl.exe" "${BUILD_DIR}/edwl" \
                 "${BUILD_DIR}/Release/edwl.exe" "${BUILD_DIR}/bin/edwl.exe"; do
	if [[ -f "${candidate}" ]]; then
		BIN="${candidate}"
		break
	fi
done

if [[ -z "${BIN}" ]]; then
	echo "错误: 编译结束但找不到 edwl 可执行文件（在 ${BUILD_DIR} 下）" >&2
	exit 1
fi

mkdir -p "${OUT_DIR}"
TARGET="${OUT_DIR}/$(basename "${BIN}")"
cp -f "${BIN}" "${TARGET}"
chmod +x "${TARGET}"

echo "==> 产物: ${TARGET}"
"${TARGET}" --version 2>/dev/null || true
