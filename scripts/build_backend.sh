#!/usr/bin/env bash
#
# 檀阁瑞木 Tangram —— 后端可分发构建脚本
#
# 行为：
#   1. 检测 pyinstaller；若存在则打包为可分发包（占位检测，默认不打包，提示以源码运行）。
#   2. 拷贝运行时资源：sandbox_policy.json / active.json / channels.json 到产出目录。
#
# 用法：
#   scripts/build_backend.sh [--output DIR] [--pyinstaller] [-h|--help]
#
# 约定：set -euo pipefail；不写死密钥/令牌；做存在性/参数检查。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
OUTPUT_DIR="${REPO_ROOT}/dist/backend"
USE_PYINSTALLER=0
VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)"

# 待拷贝的运行时资源（相对仓库根）
RESOURCES=(
  "backend/app/sandbox/sandbox_policy.json"
  "backend/app/models/active.json"
  "server/ota/channels.json"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)      OUTPUT_DIR="$2"; shift 2 ;;
    --pyinstaller) USE_PYINSTALLER=1; shift ;;
    -h|--help)
      echo "用法: $0 [--output DIR] [--pyinstaller]"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

echo "==> 后端构建 (Tangram ${VERSION})"

# 编译检查（源码可运行前的基本门禁）
echo "提示: 编译检查 python3 -m compileall backend"
( cd "${REPO_ROOT}" && python3 -m compileall -q backend )

mkdir -p "${OUTPUT_DIR}"

# ---- 可选 pyinstaller 打包（占位检测）----
if [[ "${USE_PYINSTALLER}" -eq 1 ]]; then
  if command -v pyinstaller >/dev/null 2>&1; then
    echo "使用 pyinstaller 打包 ..."
    ( cd "${BACKEND_DIR}" && pyinstaller --name tangram-backend --onefile main.py )
    if [[ -f "${BACKEND_DIR}/dist/tangram-backend" ]]; then
      cp "${BACKEND_DIR}/dist/tangram-backend" "${OUTPUT_DIR}/"
      echo "已生成可执行包: ${OUTPUT_DIR}/tangram-backend"
    fi
  else
    echo "警告: 未找到 pyinstaller，跳过打包。" >&2
    echo "提示: 直接用源码运行 python backend/main.py --bridge tcp" >&2
  fi
else
  echo "提示: 未启用 --pyinstaller，默认以源码方式分发。"
  echo "      无头运行: python backend/main.py --chat"
  echo "      桥接调试: python backend/main.py --bridge tcp"
fi

# ---- 拷贝运行时资源 ----
echo "==> 拷贝运行时资源到 ${OUTPUT_DIR}"
for rel in "${RESOURCES[@]}"; do
  src="${REPO_ROOT}/${rel}"
  if [[ ! -f "${src}" ]]; then
    echo "警告: 缺少资源 ${rel}，跳过" >&2
    continue
  fi
  dest="${OUTPUT_DIR}/${rel}"
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}"
  echo "  拷贝 ${rel}"
done

echo "后端构建产物目录: ${OUTPUT_DIR}"
