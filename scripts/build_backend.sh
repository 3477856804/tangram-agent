#!/usr/bin/env bash
#
# 檀阁瑞木 Tangram —— 后端可分发构建脚本
#
# 行为：
#   1. 真实编译检查 backend / training / harness / im（compileall 失败即退出）。
#   2. 可选 --pyinstaller：真的调用 pyinstaller 打一个可分发单文件包。
#   3. 拷贝真实随包运行时资源到产出目录（缺一个就报错，不静默跳过）。
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

# 待拷贝的真实运行时资源（相对仓库根）；全部随仓库存在，构建时逐一校验。
RESOURCES=(
  "backend/app/sandbox/sandbox_policy.json"
  "backend/app/models/active.json"
  "backend/requirements.txt"
  "im/requirements.txt"
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

# ---- 真实编译门禁：四个 Python 包全部 compileall ----
echo "==> 编译检查 backend / training / harness / im"
for pkg in backend training harness im; do
  if [[ ! -d "${REPO_ROOT}/${pkg}" ]]; then
    echo "错误: 缺少源码目录 ${pkg}" >&2
    exit 1
  fi
  ( cd "${REPO_ROOT}" && python3 -m compileall -q "${pkg}" ) || {
    echo "错误: ${pkg} 编译检查未通过" >&2
    exit 1
  }
  echo "  ${pkg}: OK"
done

mkdir -p "${OUTPUT_DIR}"

# ---- 可选 pyinstaller 打包（真实执行 + 校验产物）----
if [[ "${USE_PYINSTALLER}" -eq 1 ]]; then
  if command -v pyinstaller >/dev/null 2>&1; then
    echo "使用 pyinstaller 打包 ..."
    ( cd "${BACKEND_DIR}" && pyinstaller --noconfirm --clean --name tangram-backend \
        --onefile --paths "${REPO_ROOT}" --paths "${BACKEND_DIR}" main.py ) || {
      echo "错误: pyinstaller 打包失败" >&2
      exit 1
    }
    built="${BACKEND_DIR}/dist/tangram-backend"
    if [[ ! -f "${built}" ]]; then
      echo "错误: 打包结束但找不到可执行文件 ${built}" >&2
      exit 1
    fi
    cp "${built}" "${OUTPUT_DIR}/"
    echo "已生成可执行包: ${OUTPUT_DIR}/tangram-backend"
  else
    echo "错误: 指定了 --pyinstaller 但本机没有 pyinstaller。" >&2
    echo "提示: python3 -m pip install pyinstaller，或去掉该参数以源码分发。" >&2
    exit 1
  fi
else
  echo "提示: 未启用 --pyinstaller，默认以源码方式分发。"
  echo "      无头运行: python3 backend/main.py --chat"
  echo "      桥接调试: python3 backend/main.py --bridge tcp"
fi

# ---- 拷贝真实运行时资源（缺失即失败，不静默跳过）----
echo "==> 拷贝运行时资源到 ${OUTPUT_DIR}"
for rel in "${RESOURCES[@]}"; do
  src="${REPO_ROOT}/${rel}"
  if [[ ! -f "${src}" ]]; then
    echo "错误: 缺少运行时资源 ${rel}" >&2
    exit 1
  fi
  dest="${OUTPUT_DIR}/${rel}"
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}"
  echo "  拷贝 ${rel}"
done

echo "后端构建产物目录: ${OUTPUT_DIR}"
