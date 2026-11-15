#!/usr/bin/env bash
# 稳健安装 Flutter SDK（CI 专用）。
#
# 设计要点（修 2026-11-15 build-all-platforms Linux job 的失败）：
#   失败根因：从 storage.flutter-io.cn 下载 1.41G tarball，速度 200~800KB/s，
#   --max-time 600 超时后 --retry-all-errors 配合 -C - 续传，但镜像 CDN 偶发
#   不支持 byte ranges，触发 curl (33) "does not seem to support byte ranges"，
#   最终 exit 33 直接失败。
#
#   1) 官方源 storage.googleapis.com 优先：GitHub 的 runner 在境外，官方源反而
#      最快最稳；国内镜像仅作兜底（保留 FLUTTER_MIRROR_FIRST=1 可反转顺序）。
#   2) 不使用 -C -：镜像节点 range 支持不稳定，续传会 curl(33)。改为一次下完
#      → 校验 → 原子落地；任一源失败就换下一个源整包重下。
#   3) 用 --speed-time/--speed-limit 检测“假死”：只有连续低速才算失败，
#      慢但持续推进的下载不会被误杀；不设固定 max-time。
#   4) 下载后按扩展名做完整性校验（xz -t / unzip -t），校验通过才解包，
#      绝不把半截文件当成功。
#
# 用法：
#   bash scripts/install_flutter.sh <linux|macos> <安装目录>
#   linux  -> 安装目录直接是 SDK 根（内含 bin/flutter）
#   macos  -> 解压出 <安装目录>/flutter（内含 bin/flutter）
set -euo pipefail

PLATFORM="${1:?用法: install_flutter.sh <linux|macos> <安装目录>}"
DEST="${2:?缺少安装目录}"
VER="3.50.0"

case "$PLATFORM" in
  linux)
    FNAME="flutter_linux_${VER}-stable.tar.xz"
    KIND="tarxz"
    ;;
  macos)
    FNAME="flutter_macos_${VER}-stable.zip"
    KIND="zip"
    ;;
  *)
    echo "不支持的平台: $PLATFORM（仅 linux/macos）" >&2
    exit 2
    ;;
esac

OFFICIAL="https://storage.googleapis.com/flutter_infra_release/releases/stable/${PLATFORM}/${FNAME}"
MIRROR="https://storage.flutter-io.cn/flutter_infra_release/releases/stable/${PLATFORM}/${FNAME}"

if [ "${FLUTTER_MIRROR_FIRST:-0}" = "1" ]; then
  URLS=("$MIRROR" "$OFFICIAL")
else
  URLS=("$OFFICIAL" "$MIRROR")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
DL="$TMP_DIR/$FNAME"

verify() {
  case "$KIND" in
    tarxz) xz -t "$DL" >/dev/null 2>&1 ;;
    zip)   unzip -tq "$DL" >/dev/null 2>&1 ;;
  esac
}

ok=0
for url in "${URLS[@]}"; do
  echo "==> 下载 Flutter $VER ($PLATFORM): $url"
  rm -f "$DL"
  # --speed-limit 20KB/s 持续 90s 才判失败；慢但推进的下载不会被误杀
  # 不用 -C -（镜像 range 不稳定），不用 --max-time（大文件慢网需要时间）
  if curl -fL --retry 4 --retry-all-errors --retry-delay 2 \
       --connect-timeout 30 \
       --speed-time 90 --speed-limit 20480 \
       -o "$DL" "$url"; then
    echo "==> 校验完整性: $DL"
    if verify; then
      echo "==> 校验通过，解包到 $DEST"
      mkdir -p "$DEST"
      case "$KIND" in
        tarxz) tar -xJf "$DL" -C "$DEST" --strip-components=1 ;;
        zip)   unzip -q "$DL" -d "$DEST" ;;
      esac
      ok=1
      break
    else
      echo "!! 校验失败（文件不完整），换下一个源重下" >&2
    fi
  else
    echo "!! 下载失败，换下一个源" >&2
  fi
done

if [ "$ok" -ne 1 ]; then
  echo "所有源均失败，无法安装 Flutter $VER" >&2
  exit 1
fi

case "$PLATFORM" in
  linux) BIN="$DEST/bin/flutter" ;;
  macos) BIN="$DEST/flutter/bin/flutter" ;;
esac
"$BIN" --version
echo "==> Flutter 安装完成: $BIN"
