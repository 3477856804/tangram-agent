#!/usr/bin/env bash
#
# 檀阁瑞木 Tangram —— 依赖安装便捷脚本
#
# 检测平台，安装/提示：
#   - 后端 Python 依赖（backend/requirements.txt；目前基本为空，仅标准库即可运行，支持未来扩展）
#   - 前端 Flutter 依赖（flutter pub get）
#
# 用法：
#   scripts/install_deps.sh [--backend] [--frontend] [--all] [-h|--help]
#
# 约定：set -euo pipefail；不写死密钥/令牌；做存在性/参数检查。

set -euo pipefail

# ---- 路径集中 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
FRONTEND_DIR="${REPO_ROOT}/frontend"

DO_BACKEND=0
DO_FRONTEND=0

# ---- 参数检查 ----
if [[ $# -eq 0 ]]; then
  DO_BACKEND=1
  DO_FRONTEND=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)  DO_BACKEND=1; shift ;;
    --frontend) DO_FRONTEND=1; shift ;;
    --all)      DO_BACKEND=1; DO_FRONTEND=1; shift ;;
    -h|--help)
      echo "用法: $0 [--backend] [--frontend] [--all]"
      echo "  默认（无参数）同时安装前后端依赖。"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      echo "用法: $0 [--backend] [--frontend] [--all]" >&2
      exit 1
      ;;
  esac
done

# ---- 平台检测（仅提示，不写死路径）----
detect_platform() {
  local os
  os="$(uname -s 2>/dev/null || echo unknown)"
  case "${os}" in
    Linux*)   echo "linux" ;;
    Darwin*)  echo "macos" ;;
    CYGWIN*|MINGW*|MSYS*|Windows_NT) echo "windows" ;;
    *)        echo "unknown" ;;
  esac
}
PLATFORM="$(detect_platform)"
echo "检测平台: ${PLATFORM}"

# ---- 后端依赖 ----
if [[ "${DO_BACKEND}" -eq 1 ]]; then
  echo "==> 后端依赖"
  if [[ ! -f "${BACKEND_DIR}/requirements.txt" ]]; then
    echo "错误: 未找到 ${BACKEND_DIR}/requirements.txt" >&2
    exit 1
  fi

  if command -v pip >/dev/null 2>&1; then
    PIP="pip"
  elif command -v pip3 >/dev/null 2>&1; then
    PIP="pip3"
  elif command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    PIP="python3 -m pip"
  else
    echo "错误: 未找到 pip。请先安装 Python 3.11+。" >&2
    echo "兜底: 参考 https://pip.pypa.io/en/stable/installation/ 安装 pip 后再试。" >&2
    exit 1
  fi

  echo "提示: 安装后端依赖 (${PIP} install -r backend/requirements.txt)"
  if "${PIP}" install -r "${BACKEND_DIR}/requirements.txt"; then
    echo "后端依赖安装完成。"
  else
    echo "警告: 后端依赖安装失败。" >&2
    echo "兜底: 当前后端仅依赖标准库即可运行；requirements.txt 中的包为可选扩展。" >&2
    echo "      可先 '${PIP} install --upgrade pip' 后重试，或检查网络/镜像源。" >&2
  fi
fi

# ---- 前端依赖 ----
if [[ "${DO_FRONTEND}" -eq 1 ]]; then
  echo "==> 前端依赖"
  if [[ ! -d "${FRONTEND_DIR}" ]]; then
    echo "错误: 未找到前端目录 ${FRONTEND_DIR}" >&2
    exit 1
  fi
  if ! command -v flutter >/dev/null 2>&1; then
    echo "错误: 未找到 flutter 命令。请先安装 Flutter SDK 并加入 PATH。" >&2
    echo "兜底: 参考 https://docs.flutter.dev/get-started/install 安装后重试。" >&2
    exit 1
  fi
  echo "提示: 进入 frontend 执行 flutter pub get"
  ( cd "${FRONTEND_DIR}" && flutter pub get )
  echo "前端依赖解析完成。"
fi

echo "依赖准备完成。"
