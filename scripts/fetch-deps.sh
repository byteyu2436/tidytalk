#!/bin/bash
# 下载 sherpa-onnx 预编译动态库（C API）和对应版本的头文件到 Vendor/sherpa-onnx，校验哈希后
# 组装成 Package.swift 用的两个 xcframework：Vendor/CSherpaOnnx.xcframework（带头文件和模块定义）、
# Vendor/OnnxRuntime.xcframework。只保留 arm64（Tidytalk 只支持 Apple 芯片）。
#
# 环境变量：
#   SHERPA_ONNX_VERSION   版本号，默认 1.13.8
#   SHERPA_ONNX_TARBALL   本地已下载的 *-osx-universal2-shared-no-tts-lib.tar.bz2，跳过下载
set -euo pipefail

VERSION="${SHERPA_ONNX_VERSION:-1.13.8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/sherpa-onnx"
NAME="sherpa-onnx-v${VERSION}-osx-universal2-shared-no-tts-lib"
LIB_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
HEADER_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VERSION}/sherpa-onnx/c-api/c-api.h"

# 已知版本的文件哈希：这些库会被签进应用，下载的内容不对时直接停下
# （系统自带的 bash 3.2 没有关联数组，用 case）
expected_sha256() {
  case "$VERSION:$1" in
    1.13.8:libsherpa-onnx-c-api.dylib) echo 08d8c58693e00cb0f4f5b26eec87f5f124cbac946ddc651ed5c0a58d6e0ec721 ;;
    1.13.8:libonnxruntime.dylib) echo 0181c2458590a90540a64ec218a78c9a4879f55747349253e54fa97d0d8de7eb ;;
    1.13.8:c-api.h) echo 2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce ;;
    *) echo "" ;;
  esac
}

verify() {
  local file="$1" name expected actual
  name="$(basename "$file")"
  expected="$(expected_sha256 "$name")"
  if [[ -z "$expected" ]]; then
    echo "    注意：没有 $name 在 $VERSION 版本的哈希，跳过校验"
    return
  fi
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "错误：$name 的 SHA-256 不对（$actual），期望 $expected" >&2
    exit 1
  fi
}

# 组装一个只含 arm64 动态库的 xcframework。用法：make_xcframework 名称 动态库 [头文件目录]
make_xcframework() {
  local name="$1" lib="$2" headers="${3:-}"
  local out="$ROOT/Vendor/$name.xcframework"
  local libname headers_key=""
  libname="$(basename "$lib")"
  rm -rf "$out"
  mkdir -p "$out/macos-arm64"
  lipo "$lib" -thin arm64 -output "$out/macos-arm64/$libname"
  if [[ -n "$headers" ]]; then
    cp -R "$headers" "$out/macos-arm64/Headers"
    headers_key="<key>HeadersPath</key><string>Headers</string>"
  fi
  cat > "$out/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>LibraryIdentifier</key><string>macos-arm64</string>
			<key>LibraryPath</key><string>$libname</string>
			$headers_key
			<key>SupportedArchitectures</key><array><string>arm64</string></array>
			<key>SupportedPlatform</key><string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key><string>XFWK</string>
	<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
}

make_xcframeworks() {
  local headers
  headers="$(mktemp -d)"
  cp "$DEST/include/c-api.h" "$headers/"
  printf 'module CSherpaOnnx {\n    header "c-api.h"\n    export *\n}\n' > "$headers/module.modulemap"
  make_xcframework CSherpaOnnx "$DEST/lib/libsherpa-onnx-c-api.dylib" "$headers"
  make_xcframework OnnxRuntime "$DEST/lib/libonnxruntime.dylib"
  rm -rf "$headers"
}

if [[ -f "$DEST/lib/libsherpa-onnx-c-api.dylib" && -f "$DEST/include/c-api.h" \
      && -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" ]]; then
  # 已经下载过的也重新校验一遍，被改动过就停下
  verify "$DEST/lib/libsherpa-onnx-c-api.dylib"
  verify "$DEST/lib/libonnxruntime.dylib"
  verify "$DEST/include/c-api.h"
  # xcframework 每次都从校验过的文件重新生成，不信任上一次留下的
  make_xcframeworks
  echo "sherpa-onnx $VERSION 已就绪：$DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "${SHERPA_ONNX_TARBALL:-}" ]]; then
  cp "$SHERPA_ONNX_TARBALL" "$TMP/sherpa.tar.bz2"
else
  echo "下载 $LIB_URL"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 20 -o "$TMP/sherpa.tar.bz2" "$LIB_URL"
fi
echo "下载 $HEADER_URL"
curl -fL --retry 5 --retry-all-errors --connect-timeout 20 -o "$TMP/c-api.h" "$HEADER_URL"

tar -xjf "$TMP/sherpa.tar.bz2" -C "$TMP"
verify "$TMP/$NAME/lib/libsherpa-onnx-c-api.dylib"
verify "$TMP/$NAME/lib/libonnxruntime.dylib"
verify "$TMP/c-api.h"

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/include"
cp "$TMP/$NAME/lib/libsherpa-onnx-c-api.dylib" "$TMP/$NAME/lib/libonnxruntime.dylib" "$DEST/lib/"
cp "$TMP/c-api.h" "$DEST/include/c-api.h"
echo "$VERSION" > "$DEST/VERSION"
make_xcframeworks
echo "完成：$DEST"
