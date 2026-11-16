#!/bin/bash
# 生成「源码与 Xcode 工程」压缩包（版本名自动取自 App/Info.plist）。
#
#   bash scripts/make-source-zip.sh [输出 zip 路径]
#
# 刻意排除：构建产物（.build / build / dist）、.git、.DS_Store、xcuserdata、
# 历史补丁快照。保留 Tip/（打赏窗口原始源码与收款码）与 Installer/（安装器源码 +
# root 安装引擎），使整包自包含、可独立重建 App 与 DMG。
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SRC_ROOT}/App/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${SRC_ROOT}/App/Info.plist")"
NAME="FanBar-Pro-${VERSION}-源码与Xcode工程"
OUT_ZIP="${1:-${SRC_ROOT}/../${NAME}.zip}"
STAGE="$(mktemp -d /tmp/fanbar-src.XXXXXX)"
trap 'rm -rf "${STAGE}"' EXIT

echo "== 打包 FanBar Pro ${VERSION} (build ${BUILD}) =="
mkdir -p "${STAGE}/${NAME}"

echo "== 复制源码树 =="
rsync -a \
    --exclude '.build/' \
    --exclude 'build/' \
    --exclude 'dist/' \
    --exclude '.git/' \
    --exclude '.DS_Store' \
    --exclude '*.xcuserstate' \
    --exclude 'xcuserdata/' \
    --exclude '变更补丁/' \
    --exclude '*.bak' \
    --exclude 'Installer/install-root.sh.*' \
    "${SRC_ROOT}/" "${STAGE}/${NAME}/"

echo "== 校验自包含（缺一即失败） =="
MISSING=0
for required in \
    "Package.swift" \
    "Package.resolved" \
    "App/Info.plist" \
    "App/local.fanbar.helper.plist" \
    "FanBarPro.xcodeproj/project.pbxproj" \
    "WidgetExtension/FanBarWidgetExtension.xcodeproj/project.pbxproj" \
    "Sources/FanBar/FanBarApp.swift" \
    "Sources/FanBarShared/FanBarHelperProtocol.swift" \
    "Sources/FanBarHelper/FanBarHelperService.swift" \
    "Tests/FanBarTests" \
    "scripts/package-app.sh" \
    "scripts/audit-bundle.sh" \
    "scripts/zip-tree.py" \
    "脚本/构建-FanBar-Pro.command" \
    "一键编译.command" \
    "Installer/build-installer.sh" \
    "Installer/make-fanbar-dmg.sh" \
    "Installer/engine/install-core.sh" \
    "Installer/installer-main.swift" \
    "Installer/InstallerModel.swift" \
    "Installer/FanBarInstallerIcon.icns" \
    "Tip/TipDemo-main.swift" \
    "Tip/Resources/wechat.png" \
    "Assets" \
    "LICENSE"; do
    if [[ ! -e "${STAGE}/${NAME}/${required}" ]]; then
        echo "  ✗ 缺少必需文件：${required}" >&2
        MISSING=1
    fi
done
[[ ${MISSING} -eq 0 ]] || { echo "源码包不完整，已中止" >&2; exit 1; }
echo "  ✓ Xcode 工程、SwiftPM 清单、构建脚本、安装器源码、打赏源码均在包内"

echo "== 校验安装器脚本可脱离本机路径 =="
# 只查“可执行代码里出现本机绝对路径”。注释与校验脚本自身（含模式串）不算。
# 用变量拼出模式，避免本脚本自己被匹配到。
NEEDLE="/tmp/""fanbar119"
HITS="$(grep -rn -- "${NEEDLE}" "${STAGE}/${NAME}/Installer/" "${STAGE}/${NAME}/scripts/" 2>/dev/null \
        | grep -v 'make-source-zip\.sh:' \
        | grep -v ':[[:space:]]*#' || true)"
if [[ -n "${HITS}" ]]; then
    echo "  ✗ 存在硬编码构建路径（解压到别处会构建失败）：" >&2
    printf '%s\n' "${HITS}" >&2
    exit 1
fi
echo "  ✓ 安装器与构建脚本不含硬编码路径"

echo "== 校验版本一致 =="
STAGED_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${STAGE}/${NAME}/App/Info.plist")"
STAGED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${STAGE}/${NAME}/App/Info.plist")"
[[ "${STAGED_VER}" == "${VERSION}" && "${STAGED_BUILD}" == "${BUILD}" ]] \
    || { echo "  ✗ 包内 Info.plist 版本漂移：${STAGED_VER}/${STAGED_BUILD}" >&2; exit 1; }
INST_VER="$(grep -E '^VER=' "${STAGE}/${NAME}/Installer/build-installer.sh" | head -1 | cut -d'"' -f2)"
[[ "${INST_VER}" == "${VERSION}" ]] \
    || { echo "  ✗ 安装器脚本版本漂移：${INST_VER} ≠ ${VERSION}" >&2; exit 1; }
echo "  ✓ App 与安装器均为 ${VERSION} / ${BUILD}"

echo "== 压缩 =="
# 用 scripts/zip-tree.py 而不是 zip(1)：macOS 的 zip 写 UTF-8 字节却不置位
# EFS 标记（0x800），中文目录名在别的平台解压会变成乱码。
# 脚本会顺带校验 CRC 与「每个非 ASCII 名字都带 UTF-8 标记」。
rm -f "${OUT_ZIP}"
python3 "${SRC_ROOT}/scripts/zip-tree.py" "${STAGE}/${NAME}" "${OUT_ZIP}"

echo "== 结果 =="
echo "  文件 : ${OUT_ZIP}"
echo "  大小 : $(du -h "${OUT_ZIP}" | cut -f1)"
echo "  条目 : $(unzip -l "${OUT_ZIP}" | tail -1 | awk '{print $2}')"
unzip -t "${OUT_ZIP}" >/dev/null && echo "  完整性 : 通过（unzip -t）"
