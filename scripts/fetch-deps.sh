#!/bin/bash
# 下载 sherpa-onnx 预编译动态库（C API）和对应版本的头文件到 Vendor/sherpa-onnx。
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

if [[ -f "$DEST/lib/libsherpa-onnx-c-api.dylib" && -f "$DEST/include/c-api.h" \
      && -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$VERSION" ]]; then
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

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/include"
cp "$TMP/$NAME/lib/libsherpa-onnx-c-api.dylib" "$TMP/$NAME/lib/libonnxruntime.dylib" "$DEST/lib/"
cp "$TMP/c-api.h" "$DEST/include/c-api.h"
echo "$VERSION" > "$DEST/VERSION"
echo "完成：$DEST"
