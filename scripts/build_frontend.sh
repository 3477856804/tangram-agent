#!/usr/bin/env bash
#
# 檀阁瑞木 Tangram —— 前端构建脚本
#
# 封装: cd frontend && flutter pub get && flutter build <platform>
#   platform: linux / windows / macos / android（参数指定）
#
# 说明：桌面端（linux / windows / macos）为优先支持目标；移动端 android 次之；
#       iOS 受 App Store 发版约束；
#       Web 端 FFI 不适用，不纳入核心承诺。
#
# 用法：
#   scripts/build_frontend.sh <platform> [--extra "args"] [-h|--help]
#
# 约定：set -euo pipefail；不写死密钥/令牌；做参数/存在性检查。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FRONTEND_DIR="${REPO_ROOT}/frontend"

EXTRA_ARGS=()

# 桌面端优先：未指定平台时提示
if [[ $# -lt 1 ]]; then
  echo "用法: $0 <platform>  (linux|windows|macos|android)" >&2
  echo "说明: 桌面端(linux/windows/macos)为优先支持目标。" >&2
  exit 1
fi

PLATFORM="$1"; shift

case "${PLATFORM}" in
  linux|windows|macos|android) ;;
  *)
    echo "错误: 不支持的平台 '${PLATFORM}'" >&2
    echo "支持: linux windows macos android" >&2
    exit 1
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --extra) EXTRA_ARGS+=($2); shift 2 ;;
    -h|--help)
      echo "用法: $0 <platform> [--extra 'args']"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "${FRONTEND_DIR}" ]]; then
  echo "错误: 未找到前端目录 ${FRONTEND_DIR}" >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "错误: 未找到 flutter 命令。请先安装 Flutter SDK。" >&2
  exit 1
fi

echo "==> 前端构建: 平台=${PLATFORM} (桌面端优先)"

# Flutter 项目默认不携带各平台运行器；首次构建时在临时目录生成后只拷贝平台目录，
# 避免 flutter create 覆盖现有 pubspec / 测试文件。
if [[ ! -d "${FRONTEND_DIR}/${PLATFORM}" ]]; then
  echo "==> 未发现 ${PLATFORM} 运行器，生成平台模板并拷贝"
  TMP_PLATFORM_DIR="$(mktemp -d)"
  ( cd "${TMP_PLATFORM_DIR}" && flutter create --platforms="${PLATFORM}" --project-name tangram . >/dev/null )
  cp -a "${TMP_PLATFORM_DIR}/${PLATFORM}" "${FRONTEND_DIR}/"
  rm -rf "${TMP_PLATFORM_DIR}"
fi

# Android：平台运行器目录不入库、由 flutter create 生成，因此「所有文件访问」
# 权限声明与原生授权通道必须在每次生成后幂等注入，保证任意机器重建的 APK
# 都具备设备文件访问能力。脚本对非 android 平台不执行，幂等可重复运行。
# 品牌资产：鹿 PNG 已入库，构建前校验其与真源 SVG 一致（不引入渲染库依赖）。
echo "==> 校验品牌鹿资产（真源派生、透明 PNG 齐备）"
python3 "${SCRIPT_DIR}/gen_brand_assets.py" --check

if [[ "${PLATFORM}" == "android" ]]; then
  # Flutter 增量构建会复用旧的 Dart kernel 与 asset bundle，出现过「源码已改、
  # 装到手机上仍是旧界面（旧方块 logo）」的情况。Android 打包一律先清缓存，
  # 保证 kernel_blob.bin / flutter_assets 全部按当前源码重新生成。
  echo "==> 全新构建：清理 Flutter 增量缓存与旧 APK 产物"
  ( cd "${FRONTEND_DIR}" && flutter clean )
  rm -f "${FRONTEND_DIR}"/build/app/outputs/flutter-apk/*.apk \
        "${FRONTEND_DIR}"/android/app/build/outputs/flutter-apk/*.apk \
        "${FRONTEND_DIR}"/build/app/outputs/apk/*/*.apk \
        "${FRONTEND_DIR}"/android/app/build/outputs/apk/*/*.apk \
        "${REPO_ROOT}"/tangram-agent.apk
  echo "==> 注入 Android 设备文件访问能力（幂等）"
  python3 "${SCRIPT_DIR}/inject_android_permissions.py" "${FRONTEND_DIR}/android"
  echo "==> 注入 TGA 品牌（应用名 + 纯鹿启动图标，幂等）"
  python3 "${SCRIPT_DIR}/inject_android_branding.py" "${FRONTEND_DIR}/android"
  echo "==> 注入国内可达构建镜像（Gradle 发行包 + Maven 仓库，幂等）"
  python3 "${SCRIPT_DIR}/inject_android_mirrors.py" "${FRONTEND_DIR}/android"
  echo "==> 统一 Android compileSdk（app 固定 36 + 插件子模块强制 36，幂等）"
  python3 "${SCRIPT_DIR}/inject_android_compile_sdk.py" "${FRONTEND_DIR}/android"
fi

# 国内可达镜像：pub 包与 Flutter 引擎制品（海外环境自动回退官方源也可）
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

# Android：Flutter 工具固定到 <flutter 项目>/build/app/outputs/flutter-apk 找 APK，
# 但部分 AGP / Flutter Gradle Plugin 组合会把产物留在 android/app/build/outputs，
# 于是 flutter 命令以 "failed to produce an .apk file" 退出，而 APK 其实已生成。
# 这里以「实际产物是否存在且为本次新生成」为准，并把 APK 统一交付到仓库根目录，
# 保证任意机器 clone 后一次 build_frontend.sh android 都能拿到可安装的 APK。
if [[ "${PLATFORM}" == "android" ]]; then
  if [[ ${#EXTRA_ARGS[@]} -eq 0 ]]; then EXTRA_ARGS=(--debug); fi
  ( cd "${FRONTEND_DIR}" && flutter pub get ) || { echo "错误: flutter pub get 失败" >&2; exit 1; }
  # OTA 版本自检真源：把 VERSION 注入 App（UpdateService.currentVersion）。
  TGA_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION" 2>/dev/null || echo 0.0.1)"
  EXTRA_ARGS+=(--dart-define=TANGRAM_VERSION="${TGA_VERSION}")
  echo "==> OTA 版本注入: TANGRAM_VERSION=${TGA_VERSION}"
  set +e
  ( cd "${FRONTEND_DIR}" && flutter build apk "${EXTRA_ARGS[@]}" )
  BUILD_RC=$?
  set -e
  APK=""
  for f in "${FRONTEND_DIR}"/build/app/outputs/flutter-apk/*.apk \
           "${FRONTEND_DIR}"/android/app/build/outputs/flutter-apk/*.apk \
           "${FRONTEND_DIR}"/build/app/outputs/apk/*/*.apk \
           "${FRONTEND_DIR}"/android/app/build/outputs/apk/*/*.apk; do
    if [[ -f "$f" ]]; then APK="$f"; break; fi
  done
  if [[ -z "$APK" ]] || ! find "$APK" -mmin -60 | grep -q .; then
    echo "错误: 未找到本次构建生成的 APK（flutter build apk 退出码 ${BUILD_RC}）" >&2
    exit 1
  fi
  cp -f "$APK" "${REPO_ROOT}/tangram-agent.apk"
  echo "==> APK 已产出: ${REPO_ROOT}/tangram-agent.apk"
  echo "    源产物: ${APK}"
else
  ( cd "${FRONTEND_DIR}" && flutter pub get && flutter build "${PLATFORM}" "${EXTRA_ARGS[@]}" )
fi
echo "前端构建完成: ${PLATFORM}"
