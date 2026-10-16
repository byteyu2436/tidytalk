#!/bin/bash
# 打包 DMG，并可选地签名、公证。
#
# 环境变量：
#   SIGN_IDENTITY     Developer ID Application 身份（必填才能公证）
#   NOTARY_PROFILE    `xcrun notarytool store-credentials` 保存的钥匙串配置名；
#                     设置后会提交公证并装订票据
#   VERSION           版本号，默认 0.1.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
export VERSION
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DMG="$ROOT/build/Tidytalk-$VERSION.dmg"

scripts/build-app.sh

echo "==> 生成 DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Tidytalk.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # 未公证的试用版：附上首次打开的说明
  cp "Resources/安装说明.txt" "$STAGE/"
fi
rm -f "$DMG"
hdiutil create -volname "Tidytalk" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "公证需要设置 SIGN_IDENTITY 为 Developer ID Application 证书" >&2
    exit 1
  fi
  echo "==> 提交公证"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

# 只保留 DMG，避免 build/ 里的应用和已安装的应用在 Spotlight 里重复出现
rm -rf build/Tidytalk.app

echo "完成：$DMG"
