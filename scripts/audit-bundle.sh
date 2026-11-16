#!/bin/bash
# 交付前签名审计（1.1.10）。
#
# 依据《按形态跑：macOS 27 时代 Apple 开发者签名、公证与分发新手全攻略》第 2 章
# 与第 12 章自检清单，把「签名工艺那一关」里最容易被漏掉的几条做成构建期硬门禁。
# 这里只检查本地能查的东西；公证与 staple 需要 Developer ID 与联网，不在本脚本内。
#
#   用法: audit-bundle.sh <FanBar Pro.app> [<签名身份>]
#
# 检查项：
#   1. 所有 Mach-O 都不得携带 com.apple.security.get-task-allow（公证头号拒因之一）。
#   2. 每个 Mach-O 都必须已签名且能通过 codesign --verify --strict。
#   3. App 与内嵌 Helper 必须锚定同一份签名身份（leaf 证书或 Team），
#      否则 helper 的 XPC 校验会在真机上拒绝 App —— 这是装完"看起来正常但控制不了风扇"
#      的典型成因。
#   4. Helper 的 designated requirement 必须真的绑定身份，不能退化成一个裸 identifier。
#   5. Developer ID 构建必须带 Hardened Runtime（flags 含 runtime）。
#   6. App 与 Widget 的版本号必须一致。
set -uo pipefail

app="${1:-}"
identity="${2:-}"
if [[ -z "${app}" || ! -d "${app}" ]]; then
    echo "usage: audit-bundle.sh <FanBar Pro.app> [identity]" >&2
    exit 2
fi

failures=0
fail() { echo "FAIL  $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok    $*"; }

# ---------------------------------------------------------------- Mach-O 清单
machos=()
while IFS= read -r -d '' file; do
    [[ -L "${file}" ]] && continue
    if file -b "${file}" 2>/dev/null | grep -q "Mach-O"; then
        machos+=("${file}")
    fi
done < <(find "${app}" -type f -print0 2>/dev/null)

if [[ ${#machos[@]} -eq 0 ]]; then
    fail "bundle 内没有找到任何 Mach-O"
fi

# ------------------------------------------------- 1/2. get-task-allow 与签名
for binary in "${machos[@]}"; do
    relative="${binary#"${app}"/}"
    entitlements="$(codesign -d --entitlements :- "${binary}" 2>/dev/null || true)"
    if [[ "${entitlements}" == *"com.apple.security.get-task-allow"* ]]; then
        fail "${relative} 携带 com.apple.security.get-task-allow（调试开口，公证必拒）"
    fi
    if ! codesign --verify --strict "${binary}" >/dev/null 2>&1; then
        fail "${relative} 签名校验失败"
    fi
done
pass "${#machos[@]} 个 Mach-O：无 get-task-allow，签名均可校验"

# --------------------------------------------- 3/4. App 与 Helper 身份一致性
leaf_of() {
    codesign -d -r- "$1" 2>/dev/null | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/\1/p' | head -1
}
team_of() {
    codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1
}

app_binary="${app}/Contents/MacOS/FanBar Pro"
helper_binary="${app}/Contents/Library/LaunchServices/local.fanbar.helper"

if [[ ! -x "${app_binary}" ]]; then
    fail "缺少主程序 Contents/MacOS/FanBar Pro"
fi
if [[ ! -x "${helper_binary}" ]]; then
    fail "缺少 Helper Contents/Library/LaunchServices/local.fanbar.helper"
fi

if [[ -x "${app_binary}" && -x "${helper_binary}" ]]; then
    app_leaf="$(leaf_of "${app_binary}")"
    helper_leaf="$(leaf_of "${helper_binary}")"
    app_team="$(team_of "${app_binary}")"
    helper_team="$(team_of "${helper_binary}")"

    if [[ -n "${app_leaf}" && -n "${helper_leaf}" ]]; then
        if [[ "${app_leaf}" == "${helper_leaf}" ]]; then
            pass "App 与 Helper 锚定同一 leaf 证书 ${app_leaf:0:12}…"
        else
            fail "App 与 Helper 的 leaf 证书不同（${app_leaf:0:12}… vs ${helper_leaf:0:12}…）：helper 会拒绝 App 的 XPC"
        fi
    elif [[ -n "${app_team}" && "${app_team}" != "not set" ]]; then
        if [[ "${app_team}" == "${helper_team}" ]]; then
            pass "App 与 Helper 属于同一 Team ${app_team}"
        else
            fail "App 与 Helper 的 Team 不同（${app_team} vs ${helper_team:-空}）"
        fi
    else
        fail "无法证明 App 与 Helper 共享签名身份（既无 leaf 锚点也无 Team）"
    fi

    helper_requirement="$(codesign -d -r- "${helper_binary}" 2>/dev/null | sed -n 's/^designated => //p' | head -1)"
    if [[ -z "${helper_requirement}" ]]; then
        fail "Helper 没有 designated requirement"
    elif [[ "${helper_requirement}" == 'identifier "local.fanbar.helper"' ]]; then
        fail "Helper 的 DR 只绑定了 identifier，任何 ad-hoc 进程都能冒充 App"
    else
        pass "Helper DR 绑定身份：${helper_requirement:0:60}…"
    fi
fi

# ------------------------------------------------------- 5. Hardened Runtime
if [[ "${identity}" == Developer\ ID\ Application:* ]]; then
    for binary in "${app_binary}" "${helper_binary}" "${app}/Contents/MacOS/FanBarDiagnostics"; do
        [[ -x "${binary}" ]] || continue
        flags="$(codesign -dv --verbose=4 "${binary}" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\(.*\)).*/\2/p' | head -1)"
        if [[ "${flags}" == *runtime* ]]; then
            pass "Hardened Runtime: ${binary#"${app}"/}"
        else
            fail "Developer ID 构建缺少 Hardened Runtime（--options runtime）：${binary#"${app}"/}"
        fi
    done
else
    pass "非 Developer ID 身份（${identity:-未提供}）：按设计不加 Hardened Runtime（Sparkle 无 Team 时库校验会拒绝加载）"
fi

# ---------------------------------------------------------- 6. 版本一致性
app_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist" 2>/dev/null)"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Contents/Info.plist" 2>/dev/null)"
widget_plist="${app}/Contents/PlugIns/FanBarWidget.appex/Contents/Info.plist"
if [[ -f "${widget_plist}" ]]; then
    widget_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${widget_plist}" 2>/dev/null)"
    widget_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${widget_plist}" 2>/dev/null)"
    if [[ "${widget_short}" == "${app_short}" && "${widget_build}" == "${app_build}" ]]; then
        pass "版本一致：${app_short} (${app_build})"
    else
        fail "Widget 版本 ${widget_short} (${widget_build}) 与 App ${app_short} (${app_build}) 不一致"
    fi
else
    pass "未打包 Widget，跳过版本比对"
fi

if [[ "${failures}" -ne 0 ]]; then
    echo "" >&2
    echo "签名审计未通过：${failures} 项失败" >&2
    exit 1
fi
echo "签名审计通过（${app}）"
