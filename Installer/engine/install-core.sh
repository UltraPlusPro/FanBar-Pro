#!/bin/bash
# ============================================================================
# FanBar Pro 1.1.9 · root 安装引擎
# 2026-11-15 从零重写（旧版 install-root.sh 作废）
#
# 旧版为什么必然失败（已实测复现）：
#   旧模板写的是   LOG="${FB_LOG:-__FB_LOG__}"
#   安装器把 __FB_LOG__ 替换成 '...'（含单引号）→ 变量值变成字面量 '/tmp/x.log'，
#   引号成了内容的一部分 → 日志文件永远建不出来（界面「进度日志为空」）；
#   PAYLOAD 同理 → [ ! -d ] 恒真 → exit 2。而 osascript 对任何 AppleScript
#   错误都返回 1，于是界面永远显示「安装失败（退出码 1）」。
#
# 新版设计（四条硬规则）：
#   1) 不用任何占位符替换。日志路径与 payload 路径一律由位置参数传入，
#      由调用方的 shell 完成引号处理，脚本里只做 ${1} / ${2}。
#   2) 不依赖调用环境。显式导出最小 PATH（与 do shell script 一致），
#      umask 022，所有命令写绝对路径。
#   3) 每一步都可核对。输出 STEP|（进度）/ CHECK|（逐项结果）/ OK| / WARN|
#      / FAIL|（带退出码），最后一定有 RESULT| 汇总行；main 用 trap 兜底，
#      任何意外退出都会留下原因，绝不再出现「日志为空」。
#   4) 失败不留半成品。先拷到 /Applications/.FanBarPro-staging-* 校验通过，
#      再把旧包 mv 走、新包 mv 到位（同卷 rename 原子），失败自动回滚。
#
# 用法：
#   install-core.sh <日志路径> <Payload/FanBar Pro.app> [安装根前缀]
# 环境变量（仅离线自测用，真实安装不要设置）：
#   FB_ROOT=/tmp/sandbox   写目标整体加前缀，绝不碰 /Applications、/Library
#   FB_DRYRUN=1            跳过 root 断言与一切 launchctl 动作，只落文件
#   FB_CANCEL=<文件路径>   该文件存在则在中途安全中止（退出码 20）
#
# 退出码：
#    0 全部成功        11 拷贝失败         12 暂存校验失败     13 换装失败
#   14 Helper 落位失败 15 Helper plist 非法 16 冷启动模板缺失  17 冷启动文件非法
#   19 应用已装但服务未全部加载（部分成功）  20 被取消         77 不是 root
# ============================================================================
set -u

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022

LOG="${1:-}"
PAYLOAD="${2:-}"
ROOT="${FB_ROOT:-}"
DRY="${FB_DRYRUN:-0}"
CANCEL="${FB_CANCEL:-}"

APPS="${ROOT}/Applications"
LAUNCHD="${ROOT}/Library/LaunchDaemons"
PHTOOLS="${ROOT}/Library/PrivilegedHelperTools"
CSDIR="${ROOT}/Library/Application Support/FanBar"
LOGDIR="${ROOT}/Library/Logs"

TARGET="${APPS}/FanBar Pro.app"
STAGE="${APPS}/.FanBarPro-staging-$$"
OLDAPP="${APPS}/.FanBarPro-old-$$"

HELPER_LABEL="local.fanbar.helper"
HELPER_LEGACY_LABEL="local.fanbar.helper.plist"
HELPER_PLIST="${LAUNCHD}/${HELPER_LABEL}.plist"
HELPER_ROOT="${PHTOOLS}/${HELPER_LABEL}"
HELPER_REL="Contents/Library/LaunchServices/${HELPER_LABEL}"
HELPER_BIN="${HELPER_ROOT}/${HELPER_REL}"
RUNTIME_REL="Contents/Frameworks/libswift_Concurrency.dylib"

CS_LABEL="local.fanbar.coldstart"
CS_PLIST="${LAUNCHD}/${CS_LABEL}.plist"
CS_SCRIPT="${CSDIR}/fanbar-coldstart.sh"
CS_SRC_DIR="${TARGET}/Contents/Resources/冷启动加强"
CS_PLIST_SRC="${CS_SRC_DIR}/${CS_LABEL}.plist"
CS_SCRIPT_SRC="${CS_SRC_DIR}/fanbar-coldstart.sh"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

PROGRESS="0.02"
SERVICE_FAIL=0
HANDLED=0

# ---------------------------------------------------------------------------
# 输出原语：全部写 stdout，由调用方的重定向落到日志文件（单一写入流，不会重复）
# ---------------------------------------------------------------------------
say()   { printf '%s\n' "$*"; }
step()  { PROGRESS="$2"; printf 'STEP|%s|%s|%s\n' "$1" "$2" "$3"; }
ok()    { printf 'OK|%s|%s\n' "$1" "$2"; }
warn()  { printf 'WARN|%s|%s\n' "$1" "$2"; }
check_ok()   { printf 'CHECK|%s|ok|%s\n' "$1" "$2"; }
check_fail() { printf 'CHECK|%s|FAIL|%s\n' "$1" "$2"; }

fail() {  # fail <退出码> <检查键> <中文一句话> <英文一句话>
    local code="$1" key="$2" zh="$3" en="$4"
    printf 'FAIL|%s|%s|%s\n' "$key" "$code" "$zh"
    printf 'STEP|error|%s|%s~%s\n' "$PROGRESS" "$zh" "$en"
    printf 'RESULT|failed|%s|%s\n' "$key" "$code"
    exit "$code"
}

# 任何意外退出（含 bash 自身报错）都留下可读原因，避免「日志为空」
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 77 ] && [ "$rc" -ne 20 ]; then
        printf 'TRAP|脚本意外退出|rc=%s|line=%s\n' "$rc" "${1:-?}"
        printf 'RESULT|failed|trap|%s\n' "$rc"
    fi
}
trap 'on_exit $LINENO' EXIT

cancel_requested() {
    if [ -n "${CANCEL}" ] && [ -e "${CANCEL}" ]; then
        printf 'CANCELLED|用户在安装过程中取消\n'
        printf 'RESULT|cancelled|cancel|20\n'
        exit 20
    fi
}

# 特权动作：dry-run 只打印不执行
priv() {
    if [ "${DRY}" = "1" ]; then say "[dryrun] $*"; return 0; fi
    "$@"
}

# ===========================================================================
# 0. 前置：日志可达性 + root 断言 + payload 合法性
# ===========================================================================
say "==================== FanBar Pro 安装引擎 ===================="
say "时间      : $(/bin/date '+%Y-%m-%d %H:%M:%S')"
say "脚本      : $0"
say "日志      : ${LOG:-<未指定，仅标准输出>}"
say "payload   : ${PAYLOAD:-<未指定>}"
say "安装根    : ${ROOT:-/}（空 = 真实系统目录）"
say "模式      : dry-run=${DRY}  uid=$(/usr/bin/id -u)  os=$(/usr/bin/sw_vers -productVersion 2>/dev/null)"
say "============================================================"

if [ -n "${LOG}" ] && [ ! -w "${LOG}" ]; then
    # 调用方应当已建好日志；这里再兜一层，确保后续输出不会因写入失败而丢失
    /bin/mkdir -p "$(/usr/bin/dirname "${LOG}")" 2>/dev/null || true
    : >> "${LOG}" 2>/dev/null || say "WARN 日志不可写：${LOG}（后续输出只在本进程 stdout）"
fi

if [ "${DRY}" != "1" ] && [ "$(/usr/bin/id -u)" != "0" ]; then
    say "FATAL 本次执行不是 root（uid=$(/usr/bin/id -u)）。"
    say "      真实安装需要写入 /Applications、${LAUNCHD}、${PHTOOLS}，必须以 root 运行。"
    printf 'FAIL|not_root|77|未能取得 root 权限\n'
    printf 'RESULT|failed|not_root|77\n'
    exit 77
fi
check_ok "root 权限" "uid=$(/usr/bin/id -u)（真实安装要求 0）"

if [ -z "${PAYLOAD}" ]; then
    fail 10 "payload_arg" "安装器没有传入主程序路径" "payload argument missing"
fi
if [ ! -d "${PAYLOAD}" ]; then
    fail 10 "payload_missing" "安装包不完整：找不到主程序" "payload app bundle not found"
fi
if [ ! -x "${PAYLOAD}/Contents/MacOS/FanBar Pro" ]; then
    fail 10 "payload_binary" "安装包不完整：主可执行文件缺失" "payload executable missing"
fi
PAYLOAD_SIZE="$(/usr/bin/du -sh "${PAYLOAD}" 2>/dev/null | /usr/bin/cut -f1)"
check_ok "主程序包" "${PAYLOAD}（${PAYLOAD_SIZE}）"
say "payload 版本: $(/usr/bin/plutil -extract CFBundleShortVersionString raw "${PAYLOAD}/Contents/Info.plist" 2>/dev/null || echo '?') ($(/usr/bin/plutil -extract CFBundleVersion raw "${PAYLOAD}/Contents/Info.plist" 2>/dev/null || echo '?'))"

cancel_requested

# ===========================================================================
# 1. 拷贝到暂存目录（不碰现有安装，失败可完全回滚）
# ===========================================================================
step "copying" "0.18" "正在拷贝应用程序…~Copying application files"
/bin/mkdir -p "${APPS}" || fail 11 "mkdir_apps" "无法创建目标目录 ${APPS}" "cannot create ${APPS}"
# 清理上次异常中断留下的暂存/旧包
/bin/rm -rf "${APPS}"/.FanBarPro-staging-* "${APPS}"/.FanBarPro-old-* 2>/dev/null || true
/bin/rm -rf "${STAGE}" 2>/dev/null || true

say "→ ditto ${PAYLOAD} → ${STAGE}"
if ! /usr/bin/ditto "${PAYLOAD}" "${STAGE}"; then
    /bin/rm -rf "${STAGE}" 2>/dev/null || true
    fail 11 "ditto" "拷贝应用程序失败（磁盘空间不足或安装镜像已弹出）" "ditto copy failed"
fi
cancel_requested

# ===========================================================================
# 2. 校验暂存副本（签名 + 可执行 + plist）
# ===========================================================================
step "verify" "0.34" "正在校验安装内容…~Verifying installation"
if [ ! -d "${STAGE}" ]; then
    fail 12 "stage_missing" "拷贝后暂存目录不存在" "staging directory missing"
fi
if [ ! -x "${STAGE}/Contents/MacOS/FanBar Pro" ]; then
    /bin/rm -rf "${STAGE}" 2>/dev/null || true
    fail 12 "stage_exec" "拷贝后主可执行文件不可执行（权限或拷贝损坏）" "staged executable is not executable"
fi
check_ok "主可执行文件" "${STAGE}/Contents/MacOS/FanBar Pro"

if /usr/bin/plutil -lint "${STAGE}/Contents/Info.plist" >/dev/null 2>&1; then
    check_ok "Info.plist" "plutil -lint 通过"
else
    /bin/rm -rf "${STAGE}" 2>/dev/null || true
    fail 12 "stage_plist" "Info.plist 语法非法，拷贝已损坏" "Info.plist is not a valid plist"
fi

# 签名校验：自签环境下 --strict 可能因扩展属性/资源封条差异报错，
# 只作为告警记录，绝不因此中断安装（否则用户会卡在一个能用的包上）。
if /usr/bin/codesign --verify --strict "${STAGE}" >/dev/null 2>&1; then
    check_ok "代码签名" "--strict 校验通过"
else
    warn "代码签名" "codesign --verify --strict 未通过（自签构建常见，继续安装）"
fi

cancel_requested

# ===========================================================================
# 3. 归属与权限 + 去隔离属性
# ===========================================================================
step "permissions" "0.46" "正在设置文件权限…~Setting permissions"
priv /usr/sbin/chown -R root:wheel "${STAGE}" >/dev/null 2>&1 || warn "chown" "chown root:wheel 未完全成功（不阻断）"
/bin/chmod -R a+rX "${STAGE}" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.quarantine "${STAGE}" 2>/dev/null || true
check_ok "权限" "root:wheel + a+rX + 去 quarantine"

# ===========================================================================
# 4. 停旧进程 → 原子换装（旧包先改名，新包 mv 到位，失败回滚）
# ===========================================================================
step "installing" "0.58" "正在安装应用程序…~Installing application"
if [ "${DRY}" != "1" ]; then
    /usr/bin/pkill -x "FanBar Pro" >/dev/null 2>&1 || true
    i=0
    while /usr/bin/pgrep -x "FanBar Pro" >/dev/null 2>&1 && [ "${i}" -lt 25 ]; do
        /bin/sleep 0.2
        i=$((i + 1))
    done
    say "→ 旧实例已退出（等待 ${i} 次轮询）"
fi
cancel_requested

ROLLED_BACK=0
if [ -e "${TARGET}" ]; then
    say "→ 现有安装改名为 ${OLDAPP}"
    if ! /bin/mv "${TARGET}" "${OLDAPP}" 2>/dev/null; then
        /bin/rm -rf "${STAGE}" 2>/dev/null || true
        fail 13 "move_old" "无法移开旧版本（可能正在运行或被占用）" "cannot move existing install aside"
    fi
fi

if ! /bin/mv "${STAGE}" "${TARGET}" 2>/dev/null; then
    if [ -e "${OLDAPP}" ]; then
        /bin/mv "${OLDAPP}" "${TARGET}" 2>/dev/null || true
        ROLLED_BACK=1
    fi
    /bin/rm -rf "${STAGE}" 2>/dev/null || true
    if [ "${ROLLED_BACK}" = "1" ]; then
        fail 13 "move_new" "新版本落位失败，已回滚到原版本（未损坏现有安装）" "failed to place new version; rolled back"
    fi
    fail 13 "move_new" "新版本落位失败" "failed to place new version"
fi
/bin/rm -rf "${OLDAPP}" 2>/dev/null || true

if [ ! -x "${TARGET}/Contents/MacOS/FanBar Pro" ]; then
    fail 13 "target_exec" "落位后主可执行文件缺失" "installed executable missing"
fi
check_ok "应用程序" "${TARGET}"

if [ "${DRY}" = "1" ]; then
    say "[dryrun] ${LSREGISTER} -f ${TARGET}"
else
    if [ -x "${LSREGISTER}" ]; then
        "${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || warn "LaunchServices" "lsregister 登记未成功（不阻断，首次启动会自登记）"
    fi
fi

# ===========================================================================
# 5. 后台风扇监控 Helper（LegacyLaunchd 路径，绝不使用 SMAppService）
# ===========================================================================
step "helper" "0.70" "正在注册风扇控制服务…~Registering fan control service"
HELPER_OK=0
if [ ! -f "${TARGET}/${HELPER_REL}" ]; then
    check_fail "Helper 程序" "主程序包内缺少 ${HELPER_REL}"
    SERVICE_FAIL=1
else
    # 先卸载再删文件，顺序不能反（launchd 仍持有已删文件会报错）
    priv /bin/launchctl bootout "system/${HELPER_LABEL}" >/dev/null 2>&1 || true
    priv /bin/launchctl bootout "system/${HELPER_LEGACY_LABEL}" >/dev/null 2>&1 || true
    wait_job_gone() {
        local n=0
        if [ "${DRY}" = "1" ]; then return 0; fi
        while [ "${n}" -lt 25 ]; do
            /bin/launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1 || return 0
            /bin/sleep 0.2; n=$((n + 1))
        done
        return 0
    }
    wait_job_gone

    /bin/rm -f "${HELPER_PLIST}" 2>/dev/null || true
    /bin/rm -rf "${HELPER_ROOT}" 2>/dev/null || true
    /bin/mkdir -p "${HELPER_ROOT}/Contents/Library/LaunchServices" "${HELPER_ROOT}/Contents/Frameworks" "${LAUNCHD}" \
        || { check_fail "Helper 目录" "无法创建 ${HELPER_ROOT}"; SERVICE_FAIL=1; }

    if ! /usr/bin/ditto "${TARGET}/Contents/Info.plist" "${HELPER_ROOT}/Contents/Info.plist" 2>/dev/null \
       || ! /usr/bin/ditto "${TARGET}/${HELPER_REL}" "${HELPER_BIN}" 2>/dev/null; then
        check_fail "Helper 拷贝" "无法把 Helper 复制到 PrivilegedHelperTools"
        SERVICE_FAIL=1
    else
        # Swift 运行时（若主程序包内自带，则一并复制）
        if [ -e "${TARGET}/${RUNTIME_REL}" ]; then
            /usr/bin/ditto "${TARGET}/${RUNTIME_REL}" "${HELPER_ROOT}/${RUNTIME_REL}" 2>/dev/null \
                || warn "Swift 运行时" "libswift_Concurrency 复制失败（宿主已提供则可忽略）"
        fi
        priv /usr/sbin/chown -R root:wheel "${HELPER_ROOT}" >/dev/null 2>&1 || true
        /bin/chmod -R go-w "${HELPER_ROOT}" 2>/dev/null || true

        # 指定要求：直接取 helper 自身的 Designated Requirement，
        # 与 app 侧 helperRequirement(teamID:nil, certificateSHA1:) 等价
        HELPER_DR="$(/usr/bin/codesign -d -r- "${HELPER_BIN}" 2>/dev/null | /usr/bin/sed -n 's/.*=> //p' | /usr/bin/head -1 || true)"
        if [ -n "${HELPER_DR}" ]; then
            HELPER_REQ="=${HELPER_DR}"
        else
            HELPER_REQ="=identifier \"${HELPER_LABEL}\""
        fi
        if /usr/bin/codesign --verify --strict -R "${HELPER_REQ}" "${HELPER_BIN}" >/dev/null 2>&1; then
            check_ok "Helper 签名" "-R 指定要求校验通过"
        else
            warn "Helper 签名" "-R 校未通过（自签构建常见，继续；XPC 侧会自行复核）"
        fi

        HELPER_PROG="${HELPER_ROOT}/${HELPER_REL}"
        /bin/cat > "${HELPER_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>ExitTimeOut</key><integer>5</integer><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>Label</key><string>${HELPER_LABEL}</string><key>MachServices</key><dict><key>${HELPER_LABEL}</key><true/></dict><key>ProcessType</key><string>Interactive</string><key>Program</key><string>${HELPER_PROG}</string><key>ProgramArguments</key><array><string>${HELPER_PROG}</string></array><key>RunAtLoad</key><true/><key>ThrottleInterval</key><integer>10</integer></dict></plist>
PLIST
        if /usr/bin/plutil -lint "${HELPER_PLIST}" >/dev/null 2>&1; then
            check_ok "Helper plist" "plutil -lint 通过"
        else
            check_fail "Helper plist" "job plist 语法非法"
            SERVICE_FAIL=1
        fi
        priv /usr/sbin/chown root:wheel "${HELPER_PLIST}" >/dev/null 2>&1 || true
        /bin/chmod 644 "${HELPER_PLIST}" 2>/dev/null || true

        # 加载：enable + bootstrap，失败重试一次，最终以 launchctl print 为准
        if [ "${DRY}" = "1" ]; then
            say "[dryrun] launchctl enable system/${HELPER_LABEL}"
            say "[dryrun] launchctl bootstrap system ${HELPER_PLIST}"
            HELPER_OK=1
        else
            /bin/launchctl enable "system/${HELPER_LABEL}" >/dev/null 2>&1 || true
            if /bin/launchctl bootstrap system "${HELPER_PLIST}" >/dev/null 2>&1; then
                say "$(printf '%s' '→ bootstrap helper：成功')"
            else
                rc1=$?
                say "→ bootstrap helper 首次失败（rc=${rc1}），0.6s 后重试"
                /bin/sleep 0.6
                /bin/launchctl bootstrap system "${HELPER_PLIST}" >/dev/null 2>&1 || say "→ bootstrap helper 重试仍失败"
            fi
            if /bin/launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
                check_ok "Helper 服务" "launchctl print system/${HELPER_LABEL} 可见"
                HELPER_OK=1
            else
                check_fail "Helper 服务" "launchctl bootstrap 后仍不可见（system/${HELPER_LABEL}）"
                SERVICE_FAIL=1
            fi
        fi
    fi
fi
[ "${HELPER_OK}" = "1" ] && say "OK 后台风扇监控 Helper 已注册（${HELPER_LABEL}）"

cancel_requested

# ===========================================================================
# 6. 开机冷启动 Daemon
# ===========================================================================
step "coldstart" "0.84" "正在注册开机守护服务…~Registering cold-start daemon"
CS_OK=0
if [ ! -f "${CS_PLIST_SRC}" ] || [ ! -f "${CS_SCRIPT_SRC}" ]; then
    check_fail "冷启动模板" "主程序包内缺少 冷启动加强/ 模板"
    SERVICE_FAIL=1
else
    if ! /usr/bin/plutil -lint "${CS_PLIST_SRC}" >/dev/null 2>&1; then
        check_fail "冷启动 plist" "模板 plist 语法非法"
        SERVICE_FAIL=1
    elif ! /bin/bash -n "${CS_SCRIPT_SRC}" >/dev/null 2>&1; then
        check_fail "冷启动脚本" "模板脚本 bash -n 未通过"
        SERVICE_FAIL=1
    else
        /bin/mkdir -p "${CSDIR}" "${LAUNCHD}" "${LOGDIR}" || true
        if /usr/bin/ditto "${CS_PLIST_SRC}" "${CS_PLIST}" 2>/dev/null \
           && /usr/bin/ditto "${CS_SCRIPT_SRC}" "${CS_SCRIPT}" 2>/dev/null; then
            priv /usr/sbin/chown -R root:wheel "${CSDIR}" >/dev/null 2>&1 || true
            /bin/chmod 755 "${CSDIR}" 2>/dev/null || true
            priv /usr/sbin/chown root:wheel "${CS_PLIST}" "${CS_SCRIPT}" >/dev/null 2>&1 || true
            /bin/chmod 644 "${CS_PLIST}" 2>/dev/null || true
            /bin/chmod 755 "${CS_SCRIPT}" 2>/dev/null || true

            if /usr/bin/plutil -lint "${CS_PLIST}" >/dev/null 2>&1; then
                check_ok "冷启动 plist" "plutil -lint 通过"
            else
                check_fail "冷启动 plist" "落位后语法校验失败"
                SERVICE_FAIL=1
            fi
            if /bin/bash -n "${CS_SCRIPT}" >/dev/null 2>&1; then
                check_ok "冷启动脚本" "bash -n 通过"
            else
                check_fail "冷启动脚本" "落位后 bash -n 未通过"
                SERVICE_FAIL=1
            fi

            if [ "${DRY}" = "1" ]; then
                say "[dryrun] launchctl bootout system/${CS_LABEL}"
                say "[dryrun] launchctl enable system/${CS_LABEL}"
                say "[dryrun] launchctl bootstrap system ${CS_PLIST}"
                CS_OK=1
            else
                /bin/launchctl bootout "system/${CS_LABEL}" >/dev/null 2>&1 || true
                n=0
                while [ "${n}" -lt 20 ]; do
                    /bin/launchctl print "system/${CS_LABEL}" >/dev/null 2>&1 || break
                    /bin/sleep 0.1; n=$((n + 1))
                done
                /bin/launchctl enable "system/${CS_LABEL}" >/dev/null 2>&1 || true
                if ! /bin/launchctl bootstrap system "${CS_PLIST}" >/dev/null 2>&1; then
                    say "→ bootstrap coldstart 首次失败，0.6s 后重试"
                    /bin/sleep 0.6
                    /bin/launchctl bootstrap system "${CS_PLIST}" >/dev/null 2>&1 || say "→ bootstrap coldstart 重试仍失败"
                fi
                if /bin/launchctl print "system/${CS_LABEL}" >/dev/null 2>&1; then
                    check_ok "冷启动服务" "launchctl print system/${CS_LABEL} 可见"
                    CS_OK=1
                else
                    check_fail "冷启动服务" "launchctl bootstrap 后仍不可见（system/${CS_LABEL}）"
                    SERVICE_FAIL=1
                fi
            fi
        else
            check_fail "冷启动落位" "无法把冷启动模板写入 ${CSDIR}"
            SERVICE_FAIL=1
        fi
    fi
fi
[ "${CS_OK}" = "1" ] && say "OK 开机冷启动守护已注册（${CS_LABEL}）"

# ===========================================================================
# 7. 终检 + 汇总
# ===========================================================================
step "verify_final" "0.94" "正在做安装后自检…~Final verification"
FINAL_OK=1
if [ -x "${TARGET}/Contents/MacOS/FanBar Pro" ]; then
    check_ok "应用落位" "主可执行文件可执行"
else
    check_fail "应用落位" "主可执行文件不可执行"
    FINAL_OK=0
fi
for f in "${HELPER_PLIST}" "${CS_PLIST}" "${CS_SCRIPT}"; do
    if [ -f "${f}" ]; then
        check_ok "文件存在" "${f}"
    else
        check_fail "文件缺失" "${f}"
        FINAL_OK=0
    fi
done

say ""
say "----------------------- 安装结果汇总 -----------------------"
say "应用      : $([ -x "${TARGET}/Contents/MacOS/FanBar Pro" ] && echo 成功 || echo 失败)  ${TARGET}"
say "Helper    : $([ "${HELPER_OK}" = "1" ] && echo 成功 || echo 失败)  ${HELPER_LABEL}"
say "冷启动    : $([ "${CS_OK}" = "1" ] && echo 成功 || echo 失败)  ${CS_LABEL}"
say "------------------------------------------------------------"

if [ "${FINAL_OK}" != "1" ]; then
    printf 'RESULT|failed|final_check|19\n'
    printf 'STEP|error|0.94|安装后自检未通过~Final verification failed\n'
    exit 19
fi
if [ "${SERVICE_FAIL}" != "0" ]; then
    printf 'RESULT|partial|services|19\n'
    printf 'STEP|error|0.94|应用已安装，服务未全部加载~App installed, services incomplete\n'
    say "FATAL 应用已安装，但有服务未能加载（见上方 CHECK|FAIL 行）"
    exit 19
fi

printf 'RESULT|ok||0\n'
say "== 安装成功：应用 + 两项系统服务均已就绪 =="
exit 0
