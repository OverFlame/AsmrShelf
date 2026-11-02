#!/usr/bin/env bash
#
# AsmrShelf — Android 构建脚本
#
# 用法：
#   scripts/build_android.sh [选项]
#
# 选项：
#   --mode <release|debug|profile>  构建模式，默认 release
#   --split                         按 ABI 拆包（--split-per-abi，仅 release 有效）
#   --clean                         构建前执行 flutter clean
#   --no-pub                        跳过 flutter pub get
#   -h, --help                      显示本帮助
#
# 产物：build/app/outputs/flutter-apk/app-<模式>.apk（--split 时另出 app-<abi>-<模式>.apk）
# 日志：<应用根>/logs/build_android_<时间戳>.log（可用 APP_LOG_DIR 覆盖）
#
# 环境变量覆盖：FLUTTER_BIN、APP_LOG_DIR、ANDROID_HOME、ANDROID_SDK_ROOT、
#   FLUTTER_STORAGE_BASE_URL、PUB_HOSTED_URL
#
# 前提：Android SDK（含 build-tools、platform-tools）与 JDK 17+。
# 说明：Android 上 sqflite 走插件自带的 SQLite，不使用 pubspec 里 sqlite3 的 FFI 配置。

set -euo pipefail

MODULE="build_android"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="release"
DO_CLEAN=0
DO_PUB=1
DO_SPLIT=0

usage() {
  sed -n '3,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="${2:?--mode 需要取值}"; shift 2 ;;
    --mode=*)  MODE="${1#*=}"; shift ;;
    --split)   DO_SPLIT=1; shift ;;
    --clean)   DO_CLEAN=1; shift ;;
    --no-pub)  DO_PUB=0; shift ;;
    -h|--help) usage ;;
    *) printf '未知参数：%s\n' "$1" >&2; usage ;;
  esac
done

case "$MODE" in
  release|debug|profile) ;;
  *) printf '非法 --mode：%s（可选 release/debug/profile）\n' "$MODE" >&2; exit 2 ;;
esac

# ── 日志 ──
LOG_DIR="${APP_LOG_DIR:-${APP_ROOT}/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build_android_$(date '+%Y%m%d_%H%M%S').log"

_emit() {
  printf '[%s] [%-5s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$MODULE" "$2"
}
log_info()  { _emit INFO  "$1" | tee -a "$LOG_FILE"; }
log_warn()  { _emit WARN  "$1" | tee -a "$LOG_FILE" >&2; }
log_error() { _emit ERROR "$1" | tee -a "$LOG_FILE" >&2; }

run() {
  log_info "运行：$*"
  set +e
  "$@" 2>&1 | tee -a "$LOG_FILE"
  local status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ]; then
    log_error "命令失败（退出码 ${status}）：$*"
    exit "$status"
  fi
}

trap 'log_warn "收到中断信号，退出"; exit 130' INT TERM HUP

# ── 环境 ──
export PATH="${HOME}/flutter/bin:${PATH}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL-https://storage.flutter-io.cn}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL-https://pub.flutter-io.cn}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

if [ ! -d "$ANDROID_HOME" ]; then
  log_error "Android SDK 目录不存在：${ANDROID_HOME}（用 ANDROID_HOME 指定）"
  exit 3
fi
log_info "Android SDK：${ANDROID_HOME}"

if ! command -v java >/dev/null 2>&1; then
  log_error "找不到 java，需 JDK 17+。"
  exit 4
fi
log_info "java：$(java -version 2>&1 | head -1)"

FLUTTER="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [ -z "$FLUTTER" ]; then
  log_error "找不到 flutter，可用 FLUTTER_BIN 指定路径。"
  exit 4
fi
log_info "flutter：${FLUTTER}"

cd "$APP_ROOT"

if [ "$DO_CLEAN" -eq 1 ]; then
  run "$FLUTTER" clean
fi

if [ "$DO_PUB" -eq 1 ]; then
  run "$FLUTTER" --no-version-check --suppress-analytics pub get
fi

BUILD_ARGS=(--no-version-check --suppress-analytics build apk "--${MODE}")
if [ "$DO_SPLIT" -eq 1 ]; then
  if [ "$MODE" = "release" ]; then
    BUILD_ARGS+=(--split-per-abi)
  else
    log_warn "--split 只在 release 下生效，已忽略（当前模式：${MODE}）"
  fi
fi
run "$FLUTTER" "${BUILD_ARGS[@]}"

# ── 产物 ──
APK_DIR="${APP_ROOT}/build/app/outputs/flutter-apk"
if [ -d "$APK_DIR" ]; then
  log_info "产物清单："
  find "$APK_DIR" -maxdepth 1 -name "*.apk" -printf '  %p（%s 字节）\n' | tee -a "$LOG_FILE"
else
  log_warn "没找到 APK 输出目录：${APK_DIR}"
fi

log_info "日志：${LOG_FILE}"
printf '\n✅ 构建完成：%s\n' "$APK_DIR"
