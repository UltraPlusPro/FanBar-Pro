#!/bin/bash
# FanBar Pro 1.1.9 · 冷启动加强 —— Root LaunchDaemon 工作脚本
#
# 运行身份：UID=0（由 /Library/LaunchDaemons/local.fanbar.coldstart.plist 加载）。
# 目标：解决「开机只启动了主程序、风扇控制 Helper 没起来（多由第三方启动代理 /
# 守护干扰）」的问题，以外部 root 高权限在开机后短窗口内强力唤起 Helper，
# 让用户不必去系统设置关开一次按指纹冷启动。
#
# 严格行为：
#   1) 用 `sysctl -n kern.boottime` 求开机时刻，仅在开机第 30~90 秒窗口内工作；
#   2) 第 30 / 60 / 90 秒各对 Helper 做一次强制冷启动；
#   3) 90 秒之后本次开机内永久不再拉起（boottime marker 幂等保护）；
#   4) 插电 MacBook 或台式机顺带把风扇曲线设为「均衡」，未插电 MacBook 不改；
#   5) 全程静默、无 UI、无 Dock 图标，日志写 /Library/Logs/。
#
# Helper 的真实机制（已在 1.1.7 源码中查证，非臆造）：
#   * label = local.fanbar.helper（FanBarService.helperBundleID）
#   * 本地自签构建走 legacy LaunchDaemon：/Library/LaunchDaemons/local.fanbar.helper.plist
#     （LegacyHelperDaemon.jobDefinition()：RunAtLoad=true, MachServices, KeepAlive）
#   * 强制冷启动 = /bin/launchctl kickstart -k system/local.fanbar.helper
#     （Sources/FanBar/HelperJobInspector.swift 的 kickstart() 用的就是这条命令）
#   * job 未加载但系统 plist 还在时，用 launchctl bootstrap system <plist> 拉起
#   * 注意：Contents/Helpers/fanbar CLI 不直接连 root helper，它经 app 的
#     cli.sock → app → XPC → helper，所以不能拿 CLI 当「冷启动 Helper」的手段。
#
# 「均衡」曲线的真实机制（已查证）：
#   * fanbar preset set balanced
#     Sources/FanBarCLI/CLIArguments.swift → CLICommandHandler →
#     FanController.setCoolingPreset(.balanced) → XPC → root helper
#     （FanCoolingPreset.balanced.maximumFraction = 0.50，中文名「均衡」）
#   * CLI 通过 ~/Library/Application Support/FanBar/cli.sock 连到用户空间的
#     app，getpeereid 要求同用户，因此必须以登录用户身份 su -l 执行。

set -u

LABEL_HELPER="local.fanbar.helper"
HELPER_PLIST="/Library/LaunchDaemons/local.fanbar.helper.plist"
LOG="/Library/Logs/FanBar-ColdStart.log"
MARKER="/Library/Logs/FanBar-ColdStart.lastboot"
WINDOW_START=30
WINDOW_END=90
KICK_AT=(30 60 90)

log() {
    /usr/bin/logger -t fanbar-coldstart "$1" 2>/dev/null || true
    printf '%s  %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true
}

# --- 1. 开机时刻与已运行秒数 ------------------------------------------------
# kern.boottime 形如：{ sec = 1794655319, usec = 376861 } Sat Nov 14 19:21:59 2026
boot_line="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null)"
# 必须锚定 "{ sec = ..."：贪婪的 ".*sec" 会误命中后面的 "usec = ..."，
# 把微秒数当成开机秒数，窗口判断就全错了。
boot_sec="$(printf '%s' "$boot_line" | /usr/bin/sed -nE 's/^\{[[:space:]]*sec[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p')"
if [[ -z "$boot_sec" ]] || (( boot_sec < 1000000000 )); then
    log "ERROR 无法解析 kern.boottime（得到 '$boot_sec'）：$boot_line"
    exit 1
fi
now="$(/bin/date +%s)"
elapsed=$((now - boot_sec))

# --- 2. 每次开机只处理一次 / 窗口外直接退出 ---------------------------------
if [[ -f "$MARKER" ]] && [[ "$(/bin/cat "$MARKER" 2>/dev/null)" == "$boot_sec" ]]; then
    log "SKIP 本次开机已处理（boot=$boot_sec elapsed=${elapsed}s）"
    exit 0
fi
if (( elapsed >= WINDOW_END )); then
    printf '%s' "$boot_sec" > "$MARKER" 2>/dev/null || true
    log "SKIP 超出 30–90s 窗口（boot=$boot_sec elapsed=${elapsed}s），本次开机不再拉起"
    exit 0
fi
# 先写幂等标记，避免 daemon 被重复触发时并发跑两遍
printf '%s' "$boot_sec" > "$MARKER" 2>/dev/null || true
log "START boot=$boot_sec elapsed=${elapsed}s model=$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"

# --- 3. Helper 强制冷启动（真实命令） ---------------------------------------
force_restart_helper() {
    local tag="$1"
    if /bin/launchctl print "system/${LABEL_HELPER}" >/dev/null 2>&1; then
        /bin/launchctl enable "system/${LABEL_HELPER}" 2>/dev/null || true
        if /bin/launchctl kickstart -k "system/${LABEL_HELPER}" >/dev/null 2>&1; then
            log "KICK ${tag} kickstart -k system/${LABEL_HELPER} OK"
        else
            log "KICK ${tag} kickstart -k 失败，改走 bootout + bootstrap"
            /bin/launchctl bootout "system/${LABEL_HELPER}" 2>/dev/null || true
            if [[ -f "$HELPER_PLIST" ]]; then
                /bin/launchctl bootstrap system "$HELPER_PLIST" 2>/dev/null || true
            fi
        fi
    elif [[ -f "$HELPER_PLIST" ]]; then
        if /bin/launchctl bootstrap system "$HELPER_PLIST" 2>/dev/null; then
            log "KICK ${tag} bootstrap system ${HELPER_PLIST} OK"
        else
            log "KICK ${tag} bootstrap 未成功（可能已由其它注册加载）"
        fi
    else
        log "KICK ${tag} SKIP 未发现 ${HELPER_PLIST}（控制服务可能还没启用）"
    fi
}

# --- 4. 电源 / 机型判定（判别逻辑，可自测） ---------------------------------
# 机型：sysctl -n hw.model。MacBook* 前缀 = 笔记本；其余（iMac / Macmini /
#       MacStudio / MacPro / Xserve / 台式 Mac14,x 等）= 台式机。
#       hw.model 取不到时回退 system_profiler SPHardwareDataType 的 Model Identifier。
# 电源：pmset -g batt 首行的 'AC Power' / 'Battery Power'。台式机无电池时
#       pmset 常只报 AC 或不报电池，按插电处理。
# 规则：台式机 → 改；插电 MacBook → 改；电池 MacBook → 不改。
classify_power() {
    local model power is_laptop=0 on_ac=1 should=0
    model="$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
    if [[ -z "$model" ]]; then
        model="$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null \
            | /usr/bin/awk -F': ' '/Model Identifier/{gsub(/^ +/, "", $2); print $2; exit}')"
    fi
    case "$model" in
        MacBook*) is_laptop=1 ;;
        *) is_laptop=0 ;;
    esac
    power="$(/usr/bin/pmset -g batt 2>/dev/null | /usr/bin/head -1)"
    case "$power" in
        *"'Battery Power'"*) on_ac=0 ;;
        *"'AC Power'"*) on_ac=1 ;;
        *) on_ac=1 ;;   # 无电池 / 无法判定：台式机默认按插电
    esac
    if (( is_laptop == 0 )); then
        should=1          # 台式机：无条件
    elif (( on_ac == 1 )); then
        should=1          # 插电 MacBook
    else
        should=0          # 未插电 MacBook：明确不得改曲线
    fi
    CLASSIFY_MODEL="$model"
    CLASSIFY_POWER="$power"
    CLASSIFY_IS_LAPTOP="$is_laptop"
    CLASSIFY_ON_AC="$on_ac"
    CLASSIFY_SHOULD_SET="$should"
}

# --- 5. 「均衡」曲线（真实 CLI 机制，以登录用户身份执行） --------------------
set_balanced_curve() {
    local cli="" app candidate user uid
    for app in "/Applications/FanBar Pro.app" "/Applications/FanBar.app"; do
        if [[ -x "$app/Contents/Helpers/fanbar" ]]; then
            cli="$app/Contents/Helpers/fanbar"
            break
        fi
    done
    if [[ -z "$cli" ]]; then
        for candidate in /usr/local/bin/fanbar /opt/homebrew/bin/fanbar; do
            if [[ -x "$candidate" ]]; then cli="$candidate"; break; fi
        done
    fi
    if [[ -z "$cli" ]]; then
        log "CURVE SKIP 未找到 fanbar CLI（app 不在 /Applications，且 PATH 无链接）"
        return
    fi
    user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)"
    uid="$(/usr/bin/stat -f %u /dev/console 2>/dev/null)"
    if [[ -z "$user" || "$user" == "root" ]]; then
        log "CURVE SKIP 尚无登录用户（user=${user}），跳过设曲线"
        return
    fi
    # su -l 提供完整用户环境（HOME / TMPDIR），CLI 才能连上用户的 cli.sock；
    # 不带 --hold，遵循 app 设置里既有的「交还给 macOS」恢复策略。
    if /usr/bin/su -l "$user" -c "'$cli' preset set balanced" >>"$LOG" 2>&1; then
        log "CURVE OK preset set balanced（uid=$uid user=$user cli=${cli}）"
    else
        log "CURVE FAIL preset set balanced 未成功（uid=$uid user=${user}），不影响三次冷启动"
    fi
}

# --- 6. 主流程：等到 30 / 60 / 90 秒各冷启动一次 ---------------------------
for target in "${KICK_AT[@]}"; do
    if (( elapsed < target )); then
        /bin/sleep $((target - elapsed))
    fi
    now="$(/bin/date +%s)"
    elapsed=$((now - boot_sec))
    if (( elapsed > WINDOW_END + 5 )); then
        log "STOP elapsed=${elapsed}s 已越过 90s 窗口，退出"
        exit 0
    fi
    force_restart_helper "${target}s"
done

classify_power
log "CLASSIFY model=$CLASSIFY_MODEL laptop=$CLASSIFY_IS_LAPTOP ac=$CLASSIFY_ON_AC power=[$CLASSIFY_POWER] -> setBalanced=$CLASSIFY_SHOULD_SET"
if (( CLASSIFY_SHOULD_SET == 1 )); then
    set_balanced_curve
else
    log "CURVE SKIP MacBook 未插电，按要求不得改曲线"
fi
log "DONE 本次开机冷启动加强结束（boot=$boot_sec elapsed=${elapsed}s）"
exit 0
