#!/bin/bash
#
# FanBar Pro 1.1.9 —— 本地代码签名构建脚本
#
# 为什么需要它：
#   上游的 scripts/package-app.sh 是唯一的构建入口（编译 → 组装 .app →
#   逐个签名 → 校验），但它默认要求 Developer ID 证书。本机没有 Developer ID，
#   只有一张本地证书 `Local QA Code Signing`，所以这里只是把它需要的环境变量
#   固定下来，然后交给 package-app.sh 完成全部工作 —— 不再另写一套组装逻辑。
#
#   1.5.6 的关键变化：签名的意义
#   1.1.5 的交付构建是 ad-hoc 签名（TeamIdentifier 为空）。用这种签名把 helper
#   注册给 SMAppService 后，launchd 会写下一条**任何代码都满足不了**的启动约束
#   （`launchctl print` 里能看到 `LWCR … cdhash "$in" = [ ]`、`ccat = 0`），
#   于是每次开机约 35 秒后 helper 被 SIGKILL：
#       EXC_CRASH (SIGKILL, Code Signature Invalid) / Launch Constraint Violation
#   这正是「root Helper 开机不唤起」的根因。改用一张固定的本地证书签名后，
#   app 与 helper 的 Authority / designated requirement 一致且跨重启稳定。
#
# 用法：
#   ./构建-FanBar-Pro.command            默认 release + arm64，产出 build/FanBar Pro.app
#   ./构建-FanBar-Pro.command --dmg      额外产出 build/FanBar-Pro-<版本>-arm64.dmg
#   ./构建-FanBar-Pro.command --open     构建完成后在访达中显示产物
#
# 环境变量覆盖（与 package-app.sh 一致）：
#   FANBAR_SIGN_IDENTITY   默认 "Local QA Code Signing"；有 Developer ID 时改成它
#   FANBAR_ARCHS           默认 arm64
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

MAKE_DMG=0
OPEN_AFTER=0
for arg in "$@"; do
    case "${arg}" in
        --dmg)   MAKE_DMG=1 ;;
        --open)  OPEN_AFTER=1 ;;
        --debug|--release|--skip-build)
            echo "警告：${arg} 不再支持；package-app.sh 只做 release 构建（调试请直接用 Xcode）" >&2
            ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: ${arg}" >&2; exit 2 ;;
    esac
done

export FANBAR_SIGN_IDENTITY="${FANBAR_SIGN_IDENTITY:-Local QA Code Signing}"
export FANBAR_ARCHS="${FANBAR_ARCHS:-arm64}"
# 某些托管环境不允许 SwiftPM 的嵌套沙盒；置 1 可跳过（不影响产物）。
export FANBAR_DISABLE_SWIFTPM_SANDBOX="${FANBAR_DISABLE_SWIFTPM_SANDBOX:-1}"
export FANBAR_APP_OUTPUT="${FANBAR_APP_OUTPUT:-build/FanBar Pro.app}"
# 把可复现的源码压缩包一并放进 app（Contents/Resources/Source/），并在签名前放入，
# 这样 _CodeSignature/CodeResources 会密封它。留空则不内嵌。
if [[ -z "${FANBAR_SOURCE_ZIP:-}" ]]; then
    SOURCE_ZIP_DEFAULT="${ROOT}/../FanBar-Pro-1.1.9-源码与Xcode工程.zip"
    if [[ -f "${SOURCE_ZIP_DEFAULT}" ]]; then
        export FANBAR_SOURCE_ZIP="${SOURCE_ZIP_DEFAULT}"
    fi
fi

echo "== FanBar Pro 1.1.9 本地构建 =="
echo "签名身份 : ${FANBAR_SIGN_IDENTITY}"
echo "架构     : ${FANBAR_ARCHS}"
echo "产物     : ${FANBAR_APP_OUTPUT}"
echo

APP_OUTPUT="${FANBAR_APP_OUTPUT}"
if [[ "${APP_OUTPUT}" != /* ]]; then
    APP_OUTPUT="${ROOT}/${APP_OUTPUT}"
fi

zsh scripts/package-app.sh

if [[ ${MAKE_DMG} -eq 1 ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
    DMG_PATH="${ROOT}/build/FanBar-Pro-${VERSION}-arm64.dmg"
    STAGING="$(mktemp -d /tmp/fanbar-dmg.XXXXXX)"
    mkdir -p "${STAGING}/FanBar Pro"
    ditto "${APP_OUTPUT}" "${STAGING}/FanBar Pro/FanBar Pro.app"
    ln -s /Applications "${STAGING}/FanBar Pro/Applications"
    rm -f "${DMG_PATH}"
    hdiutil create -volname "FanBar Pro ${VERSION}" -srcfolder "${STAGING}/FanBar Pro" \
        -format UDZO -ov "${DMG_PATH}" >/dev/null
    rm -rf "${STAGING}"
    echo "DMG     : ${DMG_PATH}"
fi

if [[ ${OPEN_AFTER} -eq 1 ]]; then
    open -R "${APP_OUTPUT}"
fi

echo
echo "== 完成 =="
echo "应用 : ${APP_OUTPUT}"
echo "验证 : codesign -dv --verbose=4 \"${APP_OUTPUT}\""
echo "       codesign -dv --verbose=4 \"${APP_OUTPUT}/Contents/Library/LaunchServices/local.fanbar.helper\""
