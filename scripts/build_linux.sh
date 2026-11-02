#!/usr/bin/env bash
#
# AsmrShelf — Linux 构建脚本
#
# 用法：
#   scripts/build_linux.sh [选项]
#
# 选项：
#   --mode <release|debug|profile>  构建模式，默认 release
#   --clean                         构建前执行 flutter clean
#   --no-pub                        跳过 flutter pub get
#   -h, --help                      显示本帮助
#
# 产物：build/linux/<架构>/<模式>/bundle/
# 日志：<应用根>/logs/build_linux_<时间戳>.log（可用 APP_LOG_DIR 覆盖）
#
# 环境变量覆盖：FLUTTER_BIN、APP_LOG_DIR、FLUTTER_STORAGE_BASE_URL、PUB_HOSTED_URL
#   把 FLUTTER_STORAGE_BASE_URL / PUB_HOSTED_URL 设为空字符串可关闭镜像。
#
# sqlite3 来源：pubspec.yaml 的 hooks 段写死 `source: system`，本脚本不提供下载分支
#   （国内网络访问 GitHub Releases 不可用）。脚本先探测 dlopen("libsqlite3.so")
#   能命中的系统库，找不到就直接失败，并把该库复制进 bundle/lib/ 一起分发。

set -euo pipefail

MODULE="build_linux"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXE_NAME="asmrshelf"

MODE="release"
DO_CLEAN=0
DO_PUB=1

usage() {
  sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="${2:?--mode 需要取值}"; shift 2 ;;
    --mode=*)  MODE="${1#*=}"; shift ;;
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
LOG_FILE="${LOG_DIR}/build_linux_$(date '+%Y%m%d_%H%M%S').log"

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

# ── 系统 sqlite3 ──
# 打印第一个能找到的系统 sqlite3。优先无版本号的 libsqlite3.so（libsqlite3-dev 提供），
# 再退到只有运行库的发行版上的 libsqlite3.so.0。
find_libsqlite3_so() {
  local dir name
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    for name in libsqlite3.so libsqlite3.so.0; do
      if [ -e "${dir}/${name}" ]; then
        printf '%s\n' "${dir}/${name}"
        return 0
      fi
    done
  done <<EOF
$(printf '%s' "${LD_LIBRARY_PATH:-}:${HOME}/.local/lib:/usr/lib/x86_64-linux-gnu:/usr/lib:/usr/lib/aarch64-linux-gnu:/lib" | tr ':' '\n')
EOF
  return 1
}

SYSTEM_SQLITE=""
if ! SYSTEM_SQLITE="$(find_libsqlite3_so)"; then
  log_error "找不到可被 dlopen(\"libsqlite3.so\") 命中的系统库。"
  log_error "处置：安装 libsqlite3-dev（Debian/Ubuntu）后重试。"
  exit 3
fi
log_info "系统 sqlite3：${SYSTEM_SQLITE}"

# ── 环境 ──
export PATH="${HOME}/flutter/bin:${PATH}"
export LD_LIBRARY_PATH="${HOME}/.local/lib:${LD_LIBRARY_PATH:-}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL-https://storage.flutter-io.cn}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL-https://pub.flutter-io.cn}"
# flutter_soloud 自带的 libopus 在 glibc 2.43 上编译，Ubuntu 24.04 只有 2.39，
# 不禁用会在运行时加载失败；本应用只播 mp3/wav，用不到 Xiph 系列编码。
export NO_XIPH_LIBS=1

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

run "$FLUTTER" --no-version-check --suppress-analytics build linux "--${MODE}"

# ── 产物 ──
BUNDLE="$(find "${APP_ROOT}/build/linux" -maxdepth 3 -type d -name bundle -print -quit)"
if [ -z "$BUNDLE" ]; then
  log_error "没找到 bundle 目录，构建产物缺失。"
  exit 5
fi
BINARY="${BUNDLE}/${EXE_NAME}"
if [ ! -x "$BINARY" ]; then
  log_error "没找到可执行文件：${BINARY}"
  exit 6
fi

mkdir -p "${BUNDLE}/lib"
cp -f "$SYSTEM_SQLITE" "${BUNDLE}/lib/libsqlite3.so"
log_info "已把系统 sqlite3 复制进 ${BUNDLE}/lib/"

MISSING="$(ldd "$BINARY" | grep 'not found' || true)"
if [ -n "$MISSING" ]; then
  log_warn "以下动态库在构建机上找不到，目标机需自行提供："
  printf '%s\n' "$MISSING" | tee -a "$LOG_FILE" >&2
fi

log_info "构建完成：${BINARY}"
log_info "日志：${LOG_FILE}"
printf '\n✅ 构建完成：%s\n' "$BUNDLE"
