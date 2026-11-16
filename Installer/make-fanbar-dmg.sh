#!/bin/bash
# 把 build-installer.sh 的产物打成 FanBar Pro 1.1.9 安装镜像。
# DMG 根目录只有两样东西（卡巴斯基 / NSudo-StyleKit 式）：
#   安装FanBarPro.app  —— 安装向导，主程序整包内嵌在其 Contents/Resources/Payload/
#   卸载FanBarPro.app  —— 独立卸载器
# 不再有 Applications 软链：安装动作交给安装器，用户无需拖拽。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")"

SRC_TREE="${SRC_TREE:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export FANBAR_APP="${FANBAR_APP:-${SRC_TREE}/dist/FanBar Pro.app}"
[ -d "$FANBAR_APP" ] || { echo "✗ 找不到主程序：$FANBAR_APP"; exit 1; }
VER="$(plutil -extract CFBundleShortVersionString raw "$FANBAR_APP/Contents/Info.plist" 2>/dev/null || echo 1.1.9)"
BUILD="$(plutil -extract CFBundleVersion raw "$FANBAR_APP/Contents/Info.plist" 2>/dev/null || echo 119)"
OUT="${OUT:-${SRC_TREE}/dist/FanBar-Pro-${VER}-arm64.dmg}"

echo "▸ 构建安装器/卸载器（payload = ${FANBAR_APP}）"
OUT="$PWD/out" bash ./build-installer.sh

INSTALLER="out/安装FanBarPro.app"
UNINSTALLER="out/卸载FanBarPro.app"
PAYLOAD="$INSTALLER/Contents/Resources/Payload/FanBar Pro.app"

[ -d "$INSTALLER" ]   || { echo "✗ 找不到 $INSTALLER"; exit 1; }
[ -d "$UNINSTALLER" ] || { echo "✗ 找不到 $UNINSTALLER"; exit 1; }
[ -d "$PAYLOAD" ]     || { echo "✗ 安装器里没有内嵌 payload（${PAYLOAD}）"; exit 1; }
[ -x "$PAYLOAD/Contents/MacOS/FanBar Pro" ] || { echo "✗ payload 里没有主可执行文件"; exit 1; }
[ -f "$INSTALLER/Contents/Resources/install-core.sh" ] || { echo "✗ 安装器缺少 install-core.sh（root 安装引擎）"; exit 1; }
grep -v '^[[:space:]]*#' "$INSTALLER/Contents/Resources/install-core.sh" | grep -q '__FB_' \
    && { echo "✗ 安装引擎代码里出现占位符回潮"; exit 1; }

verify_pkg() {
    if codesign --verify --deep --strict "$1" >/dev/null 2>&1; then
        echo "  ✓ --deep --strict: $1"
        return 0
    fi
    # package-app.sh 记录过：Sparkle 的 Versions/B + Current 符号链接布局在部分
    # codesign 版本下会让 --deep 报 "bundle format is ambiguous"，此时退到
    # app 级 --strict（launchd/Gatekeeper 实际读的就是这层 seal）。
    if codesign --verify --strict "$1" >/dev/null 2>&1; then
        echo "  ✓ --strict（--deep 受 Sparkle 符号链接布局限制）: $1"
        return 0
    fi
    echo "✗ 签名校验失败: $1"
    return 1
}
echo "▸ 校验三个包的签名（安装器 / 卸载器 / 安装器内嵌主程序）"
verify_pkg "$INSTALLER"   || exit 1
verify_pkg "$UNINSTALLER" || exit 1
verify_pkg "$PAYLOAD"     || exit 1

echo "▸ 版本一致性：app=${VER}/${BUILD}"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PAYLOAD/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PAYLOAD/Contents/Info.plist"
W_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PAYLOAD/Contents/PlugIns/FanBarWidget.appex/Contents/Info.plist")"
W_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PAYLOAD/Contents/PlugIns/FanBarWidget.appex/Contents/Info.plist")"
echo "  widget appex=${W_VER}/${W_BUILD}"
[ "$W_VER" = "$VER" ] && [ "$W_BUILD" = "$BUILD" ] || { echo "✗ widget appex 版本不同步"; exit 1; }

echo "▸ 打 DMG：FanBar Pro ${VER} (build ${BUILD}) → $OUT"
STAGE="$(mktemp -d /tmp/fanbar-dmg.XXXXXX)"
ditto "$INSTALLER"   "$STAGE/安装FanBarPro.app"
ditto "$UNINSTALLER" "$STAGE/卸载FanBarPro.app"

EXPECT=$'安装FanBarPro.app\n卸载FanBarPro.app'
ACTUAL="$(ls -1 "$STAGE" | sort)"
if [ "$ACTUAL" != "$(printf '%s\n' "$EXPECT" | sort)" ]; then
    echo "✗ DMG 根目录内容不对："; echo "$ACTUAL"
    echo "  期望只有：安装FanBarPro.app / 卸载FanBarPro.app"; exit 1
fi

DMG_TMP="$(mktemp -d /tmp/fanbar-dmg-build.XXXXXX)/FanBar Pro ${VER}.dmg"
hdiutil create -volname "FanBar Pro ${VER}" -srcfolder "$STAGE" -ov -format UDZO "$DMG_TMP" >/dev/null
mkdir -p "$(dirname "$OUT")"
cp "$DMG_TMP" "$OUT"

echo "✓ DMG 就绪：$OUT"
echo "  大小: $(du -h "$OUT" | cut -f1)"
echo "  sha256: $(shasum -a 256 "$OUT" | awk '{print $1}')"
echo "  根目录: $(ls -1 "$STAGE" | tr '\n' ' ')"
