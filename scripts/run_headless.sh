#!/usr/bin/env bash
#
# 檀阁瑞木 Tangram —— 无头对话便捷启动
#
# 一键启动无头对话: python backend/main.py --chat
# 通过 TANGRAM_DATA 指定数据目录（默认 ~/.tangram），便于隔离运行态数据。
#
# 用法：
#   scripts/run_headless.sh [--data DIR] [--host H] [--port P] [-h|--help]
#
# 约定：set -euo pipefail；不写死密钥/令牌；做参数/存在性检查。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"

DATA_DIR="${TANGRAM_DATA:-${HOME:-/tmp}/.tangram}"
HOST="127.0.0.1"
PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data) DATA_DIR="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help)
      echo "用法: $0 [--data DIR] [--host H] [--port P]"
      echo "  默认数据目录: \$HOME/.tangram (可用 TANGRAM_DATA 环境变量覆盖)"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${BACKEND_DIR}/main.py" ]]; then
  echo "错误: 未找到后端入口 ${BACKEND_DIR}/main.py" >&2
  exit 1
fi

mkdir -p "${DATA_DIR}"
export TANGRAM_DATA="${DATA_DIR}"

echo "==> 启动无头对话 (TANGRAM_DATA=${TANGRAM_DATA})"
echo "    主机: ${HOST}  端口: ${PORT:-随机(回环)}"

ARGS=(--chat --host "${HOST}")
if [[ -n "${PORT}" ]]; then
  ARGS+=(--bridge-port "${PORT}")
fi

cd "${BACKEND_DIR}"
exec python3 main.py "${ARGS[@]}"
