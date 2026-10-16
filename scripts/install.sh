#!/bin/bash
# 编译并安装到 /Applications，然后启动。之后可以在启动台、Spotlight 或"应用程序"文件夹中找到 Tidytalk。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEST="${INSTALL_DIR:-/Applications}/Tidytalk.app"

[[ -f Resources/AppIcon.icns ]] || scripts/make-icon.sh
scripts/build-app.sh

echo "==> 安装到 $DEST"
osascript -e 'tell application id "app.tidytalk.Tidytalk" to quit' >/dev/null 2>&1 || true
pkill -x Tidytalk >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto build/Tidytalk.app "$DEST"
# 只保留一份，避免 Spotlight 里出现两个 Tidytalk
rm -rf build/Tidytalk.app

open "$DEST"
echo "完成：$DEST"
