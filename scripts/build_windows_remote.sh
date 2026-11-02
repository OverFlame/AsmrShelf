#!/usr/bin/env bash
#
# 在 Linux 上通过 SSH 远程触发 Windows 构建。
#
# 说明：Flutter 不支持 Linux 交叉编译 Windows（官方硬限制，本机实测报
#       `"build windows" only supported on Windows hosts.`）。
#       本脚本实现的是「远程触发 Windows 本机构建 + 回传产物」，
#       从而在 Linux 上一键拿到 Windows 版。
#
# Windows 端前提：
#   1. 已安装 Flutter + Visual Studio（含「使用 C++ 的桌面开发」工作负载）
#   2. 已开启 OpenSSH Server（设置 → 应用 → 可选功能 → OpenSSH 服务器）
#   3. 已配置免密 SSH 登录（或本机安装 sshpass 并改用 sshpass）
#   4. 项目已放在 Windows 上（默认 SYNC=0），
#      或设置 SYNC=1 从本机 rsync 上传（此时 Windows 端需另装 rsync，如 cwRsync）
#
set -euo pipefail

# ── 配置（可在此修改，或通过同名环境变量覆盖）──
WINDOWS_HOST="${WINDOWS_HOST:-}"               # 必填：Windows IP/主机名，如 192.168.1.100
WINDOWS_USER="${WINDOWS_USER:-}"               # 必填：SSH 用户名
WIN_PROJECT_DIR="${WIN_PROJECT_DIR:-C:/AsmrShelf}"  # Windows 上项目路径
SYNC="${SYNC:-0}"                              # 0=项目已在 Windows；1=从本机 rsync 上传
OUT_DIR="dist/windows"                         # 本机产物输出目录（相对项目根）

if [ -z "$WINDOWS_HOST" ] || [ -z "$WINDOWS_USER" ]; then
  echo "请先配置 WINDOWS_HOST 和 WINDOWS_USER（编辑脚本顶部变量，或用环境变量传入）" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$SYNC" = "1" ]; then
  echo "==> 同步源码到 Windows ..."
  rsync -az --delete \
    --exclude '.git' --exclude '.dart_tool' --exclude 'build' \
    "$PROJECT_DIR/" "$WINDOWS_USER@$WINDOWS_HOST:$WIN_PROJECT_DIR/"
fi

echo "==> 远程触发 Windows 构建 ..."
ssh "$WINDOWS_USER@$WINDOWS_HOST" \
  "cmd /c \"cd /d $WIN_PROJECT_DIR && call scripts\\build_windows.bat\""

echo "==> 回传产物 ..."
mkdir -p "$PROJECT_DIR/$OUT_DIR"
scp "$WINDOWS_USER@$WINDOWS_HOST:$WIN_PROJECT_DIR/build/windows/x64/runner/Release/*.exe" \
  "$PROJECT_DIR/$OUT_DIR/"

echo ""
echo "✅ 完成：$OUT_DIR"
