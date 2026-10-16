#!/bin/bash
# 编译并组装 build/Tidytalk.app。
#
# 环境变量：
#   VERSION           版本号，默认 0.1.0
#   BUILD_NUMBER      构建号，默认当前时间
#   UPDATE_URL        检查更新用的 JSON 地址，不设置时应用里不显示检查更新
#   SIGN_IDENTITY     签名身份，例如 "Developer ID Application: Name (TEAMID)"；
#                     不设置时使用本地临时签名（ad-hoc），仅供本机使用
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="$ROOT/build/Tidytalk.app"

scripts/fetch-deps.sh

echo "==> 编译"
swift build -c release --product Tidytalk
BIN="$(swift build -c release --show-bin-path)/Tidytalk"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tidytalk"
cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
UPDATE_URL="${UPDATE_URL:-}"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s|__UPDATE_URL__|$UPDATE_URL|" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
# 界面语言（en、zh-Hans）
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "==> 签名（$SIGN_IDENTITY）"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # 临时签名默认的 designated requirement 是 cdhash，每次重新编译都会变，
  # 系统会把它当成新应用，之前授予的辅助功能权限随之失效。
  # 改为只按 bundle id 识别，开发期间授权一次即可一直有效。
  SIGN_ARGS=(--force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"")
else
  # Developer ID 分发需要 Hardened Runtime 和安全时间戳，才能通过公证
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$lib"
  else
    codesign "${SIGN_ARGS[@]}" "$lib"
  fi
done
codesign "${SIGN_ARGS[@]}" --entitlements Resources/Tidytalk.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "完成：$APP"
