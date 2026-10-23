#!/bin/bash
# 打包 DMG，并可选地签名、公证。
#
# 环境变量：
#   SIGN_IDENTITY     签名身份，默认用钥匙串里的"Tidytalk Self-Signed"（见 scripts/signing.sh）；
#                     公证需要 Developer ID Application 身份。确实要发临时签名的包时设为 -
#   NOTARY_PROFILE    `xcrun notarytool store-credentials` 保存的钥匙串配置名；
#                     设置后会提交公证并装订票据
#   VERSION           版本号，默认 0.1.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
export VERSION
source "$ROOT/scripts/signing.sh"
if [[ "$SIGN_IDENTITY" == "-" && -z "${ALLOW_ADHOC:-}" ]]; then
  # 临时签名只按 bundle id 识别应用，任何同 id 的程序都能继承权限；
  # 而且和之前版本的签名身份不同，用户升级后要重新授权
  echo "钥匙串里没有签名证书\"$SELF_SIGNED_IDENTITY\"，不能打正式安装包（确实要临时签名请设 ALLOW_ADHOC=1）" >&2
  exit 1
fi
DMG="$ROOT/build/Tidytalk-$VERSION.dmg"

scripts/build-app.sh

echo "==> 生成 DMG"
# 已经挂着一个叫 Tidytalk 的磁盘（例如下载的安装包）时，访达会把两个磁盘弄混
if mount | grep -q " on /Volumes/Tidytalk "; then
  echo "请先在访达里推出已挂载的\"Tidytalk\"磁盘，再重新打包" >&2
  exit 1
fi
WORK="$(mktemp -d)"
MNT="$WORK/mnt"
cleanup() {
  [[ -d "$MNT" ]] && hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 打开 DMG 后的窗口：左边是应用，右边是"应用程序"文件夹，背景上的箭头提示拖过去。
# 尺寸和位置要与 scripts/make-dmg-background.swift 一致。
WIN_W=640; WIN_H=400; ICON_Y=180; APP_X=170; APPS_X=470

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R build/Tidytalk.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# 先做成可写的镜像，挂载后让访达排好窗口，再压缩成只读的 DMG
RW="$WORK/rw.dmg"
hdiutil create -volname "Tidytalk" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
mkdir -p "$MNT"
hdiutil attach "$RW" -readwrite -noverify -noautoopen -mountpoint "$MNT" >/dev/null
SetFile -a C "$MNT"   # 使用 .VolumeIcon.icns 作为磁盘图标

echo "==> 排列窗口（首次运行时系统可能会询问是否允许控制访达）"
osascript <<APPLESCRIPT
tell application "Finder"
  set dmgDisk to (POSIX file "$MNT" as alias)
  open dmgDisk
  set win to container window of dmgDisk
  set current view of win to icon view
  set toolbar visible of win to false
  set statusbar visible of win to false
  set bounds of win to {200, 120, 200 + $WIN_W, 120 + $WIN_H + 28}
  set opts to icon view options of win
  set arrangement of opts to not arranged
  set icon size of opts to 128
  set text size of opts to 13
  set background picture of opts to (POSIX file "$MNT/.background/background.tiff" as alias)
  set position of item "Tidytalk.app" of dmgDisk to {$APP_X, $ICON_Y}
  set position of item "Applications" of dmgDisk to {$APPS_X, $ICON_Y}
  close win
  open dmgDisk
  delay 1
  close container window of dmgDisk
end tell
APPLESCRIPT

# 等访达把布局写进 .DS_Store
for _ in $(seq 1 20); do [[ -f "$MNT/.DS_Store" ]] && break; sleep 0.5; done
sleep 1
rm -rf "$MNT/.fseventsd"
sync
hdiutil detach "$MNT" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# 只有 Developer ID 才给 DMG 签名：自签名证书签的 DMG 对下载的用户没有意义
if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
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
