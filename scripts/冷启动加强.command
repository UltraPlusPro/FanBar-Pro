#!/bin/zsh
# FanBar Pro 1.1.9 · 冷启动加强（中文名，755 可执行，双击即用）
#
# 双击（无参数）：以管理员权限安装并加载一个 UID=0 的 Root LaunchDaemon
#   /Library/LaunchDaemons/local.fanbar.coldstart.plist，开机 30~90 秒窗口内
#   三次强制冷启动风扇控制 Helper。安装是唯一一次用户交互（系统密码框）。
# 供设置页调用：
#   --install     静默安装并加载（Root LaunchDaemon）
#   --uninstall   静默卸载：launchctl bootout system/<label> + 删 plist + 删 helper
#   --status      查看是否已加载（无需提权）
#   --self-test   打印电源 / 机型判定结果，不执行任何动作（可自测）
#
# 安装内容来自同目录的「冷启动加强/」模板（plist + 工作脚本），先 base64
# 编码再交给 root 端解码写入，避免 root 读取用户可写路径产生歧义。
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
template_dir="${script_dir}/冷启动加强"
plist_template="${template_dir}/local.fanbar.coldstart.plist"
helper_template="${template_dir}/fanbar-coldstart.sh"
label="local.fanbar.coldstart"
plist="/Library/LaunchDaemons/${label}.plist"
helper_dir="/Library/Application Support/FanBar"
helper="${helper_dir}/fanbar-coldstart.sh"
log="/Library/Logs/FanBar-ColdStart.log"
marker="/Library/Logs/FanBar-ColdStart.lastboot"
mode="${1:-interactive}"

# --- 状态（无需提权） -------------------------------------------------------
if [[ "$mode" == "--status" ]]; then
    if [[ -f "$plist" ]]; then
        print "已加载 / Loaded: ${plist}"
        /bin/launchctl print "system/${label}" 2>/dev/null | /usr/bin/head -20
        exit 0
    fi
    print "未加载 / Not loaded: ${plist} 不存在"
    exit 1
fi

# --- 判别逻辑自测（无需提权，与 daemon 脚本 classify_power 完全一致） -------
if [[ "$mode" == "--self-test" ]]; then
    model="$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
    [[ -z "$model" ]] && model="$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null | /usr/bin/awk -F': ' '/Model Identifier/{gsub(/^ +/, "", $2); print $2; exit}')"
    is_laptop=0
    case "$model" in MacBook*) is_laptop=1 ;; esac
    power="$(/usr/bin/pmset -g batt 2>/dev/null | /usr/bin/head -1)"
    on_ac=1
    case "$power" in
        *"'Battery Power'"*) on_ac=0 ;;
        *"'AC Power'"*) on_ac=1 ;;
    esac
    if (( is_laptop == 0 )); then should=1
    elif (( on_ac == 1 )); then should=1
    else should=0
    fi
    print "hw.model            : ${model}"
    print "isLaptop (MacBook*) : ${is_laptop}"
    print "pmset -g batt       : ${power}"
    print "onAC                : ${on_ac}"
    print "=> setBalanced      : ${should}   (desktop or AC MacBook = 1; battery MacBook = 0)"
    boot_line="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null)"
    boot_sec="$(printf '%s' "$boot_line" | /usr/bin/sed -nE 's/^\{[[:space:]]*sec[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p')"
    now="$(/bin/date +%s)"
    print "kern.boottime       : ${boot_line}"
    print "boot_sec / elapsed  : ${boot_sec} / $((now - boot_sec))s  (work only inside 30-90s)"
    exit 0
fi

if [[ ! -f "$plist_template" || ! -f "$helper_template" ]]; then
    print -u2 "错误 / Error: 找不到模板目录 ${template_dir}（请把本工具与「冷启动加强」文件夹一起留在 app 包内）"
    [[ "$mode" == "interactive" ]] && { print "按回车关闭 / Press Return to close"; read -r; }
    exit 1
fi

plist_b64="$(/usr/bin/base64 < "$plist_template" | /usr/bin/tr -d '\n')"
helper_b64="$(/usr/bin/base64 < "$helper_template" | /usr/bin/tr -d '\n')"

# root 端命令：全程单引号路径，无双引号 / 反斜杠 / $，AppleScript 字符串安全。
if [[ "$mode" == "--uninstall" ]]; then
    root_cmd="/bin/launchctl bootout system/${label} 2>/dev/null; /bin/rm -f '${plist}' '${helper}' '${marker}'; /usr/bin/logger -t fanbar-coldstart 'uninstalled: bootout + removed plist and helper'"
    ok_msg="已卸载 / Unloaded: launchctl bootout system/${label} + 删除 plist 与 helper。"
else
    root_cmd="/bin/mkdir -p '${helper_dir}' /Library/Logs; /bin/launchctl bootout system/${label} 2>/dev/null; echo ${plist_b64} | /usr/bin/base64 -D > '${plist}'; echo ${helper_b64} | /usr/bin/base64 -D > '${helper}'; /usr/sbin/chown root:wheel '${plist}' '${helper}'; /bin/chmod 644 '${plist}'; /bin/chmod 755 '${helper}'; /usr/bin/plutil -lint '${plist}' >/dev/null; /bin/bash -n '${helper}'; /bin/launchctl enable system/${label}; /bin/launchctl bootstrap system '${plist}'; /usr/bin/logger -t fanbar-coldstart 'installed and bootstrapped'"
    ok_msg="已加载 / Loaded: Root LaunchDaemon ${label}（UID=0）安装完成。"
fi

# 以管理员权限执行（唯一一次用户交互：系统密码框）
if /usr/bin/osascript -e "do shell script \"${root_cmd}\" with administrator privileges" >/dev/null 2>&1; then
    print "$ok_msg"
    print "日志 / Log: ${log}"
    if [[ "$mode" == "interactive" ]]; then
        print "按回车关闭 / Press Return to close"
        read -r
    fi
    exit 0
else
    print -u2 "操作未完成 / Operation incomplete（可能取消了管理员授权，或 bootstrap 失败）。"
    if [[ "$mode" == "interactive" ]]; then
        print "按回车关闭 / Press Return to close"
        read -r
    fi
    exit 1
fi
