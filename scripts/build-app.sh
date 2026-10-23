#!/bin/bash
# 编译并组装 build/Tidytalk.app。
#
# 环境变量：
#   VERSION           版本号，默认 0.1.0
#   BUILD_NUMBER      构建号，默认当前时间
#   UPDATE_URL        检查更新地址，默认读取 GitHub 仓库的最新 Release；设为空字符串则隐藏检查更新
#   DEV_TOOLS         设为 1 时编入开发用命令（--snapshot、--check-permissions 等），
#                     发给用户的版本不要设置
#   SIGN_IDENTITY     签名身份：不设置时，钥匙串里有"Tidytalk Self-Signed"证书就用它，否则用临时签名（-）；
#                     也可以是 "Developer ID Application: Name (TEAMID)"。见 scripts/signing.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
source "$ROOT/scripts/signing.sh"
APP="$ROOT/build/Tidytalk.app"

scripts/fetch-deps.sh

echo "==> 检查翻译"
# 缺英文翻译时直接停下，免得发出去的英文界面里夹着中文
python3 scripts/localization.py >/dev/null || { python3 scripts/localization.py | grep 缺少翻译; exit 1; }

echo "==> 编译"
SWIFT_FLAGS=(-c release)
if [[ "${DEV_TOOLS:-0}" == "1" ]]; then
  SWIFT_FLAGS+=(-Xswiftc -DTIDYTALK_DEV_TOOLS)
  echo "    包含开发工具"
fi
swift build "${SWIFT_FLAGS[@]}" --product Tidytalk
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/Tidytalk"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tidytalk"
# SwiftPM 编出来的程序只在自己旁边找动态库（@loader_path），应用包里的动态库放在 Contents/Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Tidytalk"
# fetch-deps.sh 组装的 xcframework 里只有 arm64（只支持 Apple 芯片，安装包能小一截）
for lib in Vendor/CSherpaOnnx.xcframework/macos-arm64/*.dylib Vendor/OnnxRuntime.xcframework/macos-arm64/*.dylib; do
  cp "$lib" "$APP/Contents/Frameworks/"
done
UPDATE_URL="${UPDATE_URL-https://api.github.com/repos/byteyu2436/tidytalk/releases/latest}"
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
# AI 服务选项的图标（Ollama、LM Studio 的标志来自它们的官网）
cp -R Resources/ProviderIcons "$APP/Contents/Resources/"
# 实时字幕用来切分句子的语音检测模型（Silero VAD）
cp Resources/silero_vad.onnx "$APP/Contents/Resources/"
# 许可证与第三方声明（随附的 sherpa-onnx、ONNX Runtime）
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

echo "==> 签名（$SIGN_IDENTITY）"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # 临时签名默认的 designated requirement 是 cdhash，每次重新编译都会变，
  # 系统会把它当成新应用，之前授予的辅助功能权限随之失效。
  # 改为只按 bundle id 识别，开发期间授权一次即可一直有效。
  # 注意：这样本机任何同 bundle id 的临时签名程序都能继承这些权限，正式版不要用临时签名
  SIGN_ARGS=(--force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"")
elif [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
  # Developer ID 分发需要 Hardened Runtime 和安全时间戳，才能通过公证
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
else
  # 自签名证书：默认的 designated requirement 绑定这张证书。
  # 不用 Apple 的时间戳服务（只给 Apple 签发的证书用）；不开 Hardened Runtime，
  # 否则库验证要求动态库来自同一个开发者团队，自签名证书没有团队，会加载失败
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
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
