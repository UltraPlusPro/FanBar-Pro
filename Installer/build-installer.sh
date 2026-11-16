#!/bin/bash
# FanBar Pro 1.1.11 (build 121) 安装器/卸载器构建脚本（本机 Swift 工具链，无 Xcode 工程）
#
# 产出两个独立 arm64 app：
#   安装FanBarPro.app —— 卡巴斯基风格安装向导，内嵌主程序 payload + install-root.sh
#   卸载FanBarPro.app —— 卸载器（浅色/跟随系统）
# 主程序 payload 由 FANBAR_APP 指定，默认取**本目录上一级**的
# ../dist/FanBar Pro.app（即源码树里 scripts/package-app.sh 的产物），
# 用 ditto 拷入安装器，签名与扩展属性原样保留。整包解压到任何位置都能直接构建。
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")"

VER="1.1.11"
BUILD="121"
TARGET_MIN="12.7"
IDENTITY="Local QA Code Signing"
# 图标分工（2026-11-15 改）：
#  · FanBarInstallerIcon.icns —— 安装器 app 图标：卡巴斯基安装器外框（灰底圆角方块 + 向下箭头），
#                               中间的白色卡片由 FanBar Pro 本体图标完全覆盖（1.1.10 去掉了
#                               1.1.9 版本图标外那一圈纯白）。由 /tmp/icons_work/compose2 合成，
#                               十个尺寸 iconutil 打包。
#  · ProductIcon.icns         —— FanBar Pro 本体图标（界面内的产品图标，来自 Assets/FanBar.icns）
#  · UninstallerIcon          —— 卸载器 app 图标 + 卸载器界面内产品图标：卡巴斯基原版卸载图标
INSTALLER_ICON="FanBarInstallerIcon.icns"
PRODUCT_ICON="ProductIcon.icns"
UNINSTALLER_ICON="UninstallerIcon.icns"

INSTALLER_APP="安装FanBarPro.app"
INSTALLER_BIN="InstallerFanBarPro"
INSTALLER_ID="local.fanbar.installer"

UNINSTALLER_APP="卸载FanBarPro.app"
UNINSTALLER_BIN="UninstallerFanBarPro"
UNINSTALLER_ID="local.fanbar.uninstaller"

# 源码树根 = 本脚本所在目录的上一级（Installer/ 的父目录）。
# 不再硬编码任何 /tmp 路径：解压到任意位置都能构建。
SRC_TREE="${SRC_TREE:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FANBAR_APP="${FANBAR_APP:-${SRC_TREE}/dist/FanBar Pro.app}"
OUT="${OUT:-$PWD/out}"

# 自签身份探测：不带 -v（自签证书不受信，-v 会漏掉）。
if [ "$(security find-identity -p codesigning 2>/dev/null | grep -cF "\"$IDENTITY\"")" -ge 1 ]; then
    SIGN=(--sign "$IDENTITY")
else
    SIGN=(--sign -)
fi

trash() { [ -e "$1" ] && mv "$1" "$(mktemp -d /tmp/fanbar-old.XXXXXX)/" 2>/dev/null || true; }

mkdir -p "$OUT"

# ---------- 卸载FanBarPro.app ----------
echo "▸ 编译卸载器（${UNINSTALLER_APP}）"
trash "$OUT/$UNINSTALLER_APP"
mkdir -p "$OUT/$UNINSTALLER_APP/Contents/MacOS" "$OUT/$UNINSTALLER_APP/Contents/Resources"

UNINST_STAGE="$(mktemp -d /tmp/fanbar-uninst.XXXXXX)"
cp uninstaller-main.swift "$UNINST_STAGE/main.swift"
swiftc -O -swift-version 5 -target "arm64-apple-macos$TARGET_MIN" \
    -o "$OUT/$UNINSTALLER_APP/Contents/MacOS/$UNINSTALLER_BIN" \
    "$UNINST_STAGE/main.swift" uninstall-shared.swift kask-ui.swift
rm -rf "$UNINST_STAGE"

cat > "$OUT/$UNINSTALLER_APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>$UNINSTALLER_BIN</string>
    <key>CFBundleIdentifier</key><string>$UNINSTALLER_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>卸载FanBarPro</string>
    <key>CFBundleDisplayName</key><string>卸载FanBarPro</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VER</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$TARGET_MIN</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PL
# 卸载器：app 图标与界面内本体图标都用卡巴斯基原版卸载图标（垃圾桶），原样沿用。
cp "$UNINSTALLER_ICON" "$OUT/$UNINSTALLER_APP/Contents/Resources/AppIcon.icns"
cp "$UNINSTALLER_ICON" "$OUT/$UNINSTALLER_APP/Contents/Resources/ProductIcon.icns"
xattr -rc "$OUT/$UNINSTALLER_APP"
codesign --force --timestamp=none "${SIGN[@]}" "$OUT/$UNINSTALLER_APP"
codesign --verify --strict --verbose=2 "$OUT/$UNINSTALLER_APP" >/dev/null 2>&1 || { echo "✗ 卸载器签名自检没过"; exit 1; }
echo "  ✓ $UNINSTALLER_APP 已构建并签名"

# ---------- 安装FanBarPro.app ----------
echo "▸ 编译安装器（${INSTALLER_APP}）"
trash "$OUT/$INSTALLER_APP"
mkdir -p "$OUT/$INSTALLER_APP/Contents/MacOS" "$OUT/$INSTALLER_APP/Contents/Resources/Payload"

INST_STAGE="$(mktemp -d /tmp/fanbar-inst.XXXXXX)"
cp installer-main.swift "$INST_STAGE/main.swift"
swiftc -O -swift-version 5 -target "arm64-apple-macos$TARGET_MIN" \
    -o "$OUT/$INSTALLER_APP/Contents/MacOS/$INSTALLER_BIN" \
    "$INST_STAGE/main.swift" InstallerModel.swift kask-ui.swift
rm -rf "$INST_STAGE"

cat > "$OUT/$INSTALLER_APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>$INSTALLER_BIN</string>
    <key>CFBundleIdentifier</key><string>$INSTALLER_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>安装FanBarPro</string>
    <key>CFBundleDisplayName</key><string>安装FanBarPro</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VER</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>$TARGET_MIN</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PL
# 安装器：app 图标 = 卡巴斯基外框 + FanBar 风叶（FanBarInstallerIcon.icns）；界面内产品图标仍是 FanBar 本体。
cp "$INSTALLER_ICON" "$OUT/$INSTALLER_APP/Contents/Resources/AppIcon.icns"
cp "$PRODUCT_ICON" "$OUT/$INSTALLER_APP/Contents/Resources/ProductIcon.icns"

# root 安装引擎随包（签名前拷入，被 codesign 封装）。
ENGINE="engine/install-core.sh"
[ -f "$ENGINE" ] || { echo "✗ 找不到安装引擎 $ENGINE"; exit 1; }
cp "$ENGINE" "$OUT/$INSTALLER_APP/Contents/Resources/install-core.sh"
chmod 755 "$OUT/$INSTALLER_APP/Contents/Resources/install-core.sh"

# 回归护栏：旧版 install-root.sh 之所以必然失败，是因为模板里留着
#   LOG="${FB_LOG:-__FB_LOG__}"  然后安装器把 __FB_LOG__ 替换成 '...'（引号进了变量值）。
# 新引擎一律用位置参数，绝不出现占位符。这里在构建期直接拦住任何回潮。
# 只看真实代码行（去掉注释），注释里说明这段历史是允许的。
RES="$OUT/$INSTALLER_APP/Contents/Resources/install-core.sh"
CODE="$(grep -v '^[[:space:]]*#' "$RES")"
if printf '%s\n' "$CODE" | grep -q '__FB_'; then
    echo "✗ install-core.sh 的代码里出现了 __FB_ 占位符（旧的模板替换方案，会重现「日志为空 + 退出码 1」的故障）"
    exit 1
fi
if printf '%s\n' "$CODE" | grep -qE '\$\{FB_(LOG|PAYLOAD):-'; then
    echo "✗ install-core.sh 仍用 \${FB_LOG:-...} / \${FB_PAYLOAD:-...} 接收路径：占位符替换会把引号带进变量值"
    exit 1
fi
LC_ALL=en_US.UTF-8 /bin/bash -n "$RES" || { echo "✗ install-core.sh bash -n 未过"; exit 1; }
echo "  ✓ 安装引擎无占位符、bash -n 通过"

# payload：主程序整包内嵌（ditto 保留签名资源）。
if [ -d "$FANBAR_APP" ]; then
    echo "▸ 内嵌主程序 payload：$FANBAR_APP"
    ditto "$FANBAR_APP" "$OUT/$INSTALLER_APP/Contents/Resources/Payload/FanBar Pro.app"
    codesign --verify --strict "$OUT/$INSTALLER_APP/Contents/Resources/Payload/FanBar Pro.app" \
        || { echo "✗ payload 主程序签名失效（ditto 之外的方式搬运会这样）"; exit 1; }
    [ -x "$OUT/$INSTALLER_APP/Contents/Resources/Payload/FanBar Pro.app/Contents/MacOS/FanBar Pro" ] \
        || { echo "✗ payload 里没有主可执行文件"; exit 1; }
else
    echo "⚠ 未找到主程序 payload：$FANBAR_APP（安装器已编译，但未内嵌 payload）"
    exit 1
fi

xattr -rc "$OUT/$INSTALLER_APP"
# payload 已是签好的包（这里是复核，不重签）；只签外层安装器。
codesign --force --timestamp=none "${SIGN[@]}" "$OUT/$INSTALLER_APP"
codesign --verify --strict --verbose=2 "$OUT/$INSTALLER_APP" >/dev/null 2>&1 || { echo "✗ 安装器签名自检没过"; exit 1; }
codesign --verify --strict "$OUT/$INSTALLER_APP/Contents/Resources/Payload/FanBar Pro.app" \
    || { echo "✗ 签完外层后 payload 签名失效"; exit 1; }
echo "  ✓ $INSTALLER_APP 已构建并签名"

echo ""
echo "✓ 构建完成，产物在：$OUT"
ls -1 "$OUT"
