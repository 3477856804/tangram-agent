#!/usr/bin/env bash
# Tangram IM 网关看门狗：10 秒一轮探测，挂了自动拉起。
# 断连 / 进程被回收不再是灭顶之灾；凭据与配置落盘，重启即恢复。
#
# 用法：
#   TANGRAM_PUBLIC_HOST=192.168.1.10:50432 ./im/watchdog.sh
# 开机常驻：注册为 systemd service，或 crontab `@reboot /path/to/watchdog.sh`。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${TANGRAM_PORT:-50432}"
BIND="${TANGRAM_BIND:-0.0.0.0}"
ONEBOT="${NAPCAT_HTTP:-http://127.0.0.1:3000}"
PY="${PYTHON:-python3}"
LOG="${TANGRAM_LOG:-$ROOT/.tangram-gateway.log}"
PID_FILE="${TANGRAM_PID_FILE:-/tmp/tangram-gateway.pid}"
GW_PID=""

# Cloud Studio 端口转发：扫码成功下发的 AGP 地址须为手机可达的 wss:// 公网地址。
if [ -n "${X_IDE_SPACE_KEY:-}" ] && [ -n "${X_IDE_PREVIEW_DOMAIN:-}" ]; then
  PUBLIC_HOST="${TANGRAM_PUBLIC_HOST:-${X_IDE_SPACE_KEY}--${PORT}.${X_IDE_PREVIEW_DOMAIN}}"
  AGP_WSS="${TANGRAM_AGP_WSS:-1}"
else
  PUBLIC_HOST="${TANGRAM_PUBLIC_HOST:-}"
  AGP_WSS="${TANGRAM_AGP_WSS:-0}"
fi

start_gateway() {
  echo "[watchdog] $(date '+%F %T') 拉起 im.serve :$PORT (bind=$BIND)" >> "$LOG"
  (
    cd "$ROOT" || exit 1
    TANGRAM_BIND="$BIND" \
    TANGRAM_DATA="${TANGRAM_DATA:-$ROOT/.tangram-data}" \
    NAPCAT_QR_CACHE="${NAPCAT_QR_CACHE:-$ROOT/.tangram-data/napcat/cache/qrcode.png}" \
    TANGRAM_PUBLIC_HOST="$PUBLIC_HOST" \
    TANGRAM_AGP_WSS="$AGP_WSS" \
    "$PY" -m im.serve \
      --port "$PORT" --bind "$BIND" --onebot "$ONEBOT" \
      >> "$LOG" 2>&1 &
    echo $! > "$PID_FILE"
  )
  GW_PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
}

echo "[watchdog] 启动，探测 http://127.0.0.1:$PORT/api/status 每 10s" >> "$LOG"
while true; do
  if ! curl -fsS --max-time 3 "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; then
    if [ -n "$GW_PID" ]; then
      kill "$GW_PID" 2>/dev/null || true
    fi
    start_gateway
  fi
  sleep 10
done
