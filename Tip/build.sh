#!/bin/bash
# 编译并打包 TipDemo.app，使用本机 Local QA Code Signing 证书签名
set -e
cd "$(dirname "$0")"

APP="build/TipDemo.app"
IDENTITY="Local QA Code Signing"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O -target arm64-apple-macosx13.0 \
    Sources/main.swift -o "$APP/Contents/MacOS/TipDemo"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/wechat.png Resources/alipay.png Resources/qq.png "$APP/Contents/Resources/"

# 源码打包进 bundle（含资源图，可完整重建）
rm -f "$APP/Contents/Resources/SourceCode.zip"
zip -q -r -X "$APP/Contents/Resources/SourceCode.zip" \
    Sources Resources Info.plist build.sh -x "*.DS_Store"

codesign --force --deep --sign "$IDENTITY" "$APP"
codesign -vvv "$APP"
echo "已构建并签名: $APP"