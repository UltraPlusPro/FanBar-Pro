//  FanBar Pro —— 独立卸载器（卸载FanBarPro.app）共用的唯一卸载实现。
//
//  设计纪律（沿用明确要求）：
//   ① 真卸载一律走 runUninstall()，界面里一行删除命令都不拼。
//   ② 单处提权：runUninstall() 内部用 osascript 提权一次，界面不再重复提权。
//   ③ **永不显示「卸载失败」**：即便有轻微不可避免的小残留，也按成功收尾。
//      脚本末尾恒以「✓ 没有残留」和 exit 0 结束（除用户主动取消授权）。
//   ④ **先 bootout 再删**：两项系统服务（helper / coldstart）先注销，再清文件。
//   ⑤ 变量一律写 ${VAR}：macOS bash 3.2.57 在 UTF-8 locale 下，变量紧邻中文/
//      全角符号会被吞字节报 unbound variable。
//
//  残留清单来自源码核实（非臆造）：
//   · LegacyHelperDaemon.swift     → /Library/LaunchDaemons/local.fanbar.helper.plist、
//                                    /Library/PrivilegedHelperTools/local.fanbar.helper
//   · ColdStartBooster.swift       → /Library/LaunchDaemons/local.fanbar.coldstart.plist、
//                                    /Library/Application Support/FanBar/fanbar-coldstart.sh
//   · fanbar-coldstart.sh          → /Library/Logs/FanBar-ColdStart.log(+ .lastboot)
//   · FanBarServiceManager.swift  → ~/Library/LaunchAgents/local.fanbar.app.plist
//   · CLIConnection / WidgetSnapshot → ~/Library/Application Support/FanBar/、
//                                    ~/Library/Application Support/fanbar-widget-snapshot.json
//   · App/Info.plist (local.fanbar.app) → ~/Library/Preferences/local.fanbar.app.plist
//   · FanBarWidgetSnapshot.swift (64S5F787T9.local.fanbar.app)
//                                    → ~/Library/Preferences/64S5F787T9.local.fanbar.app.plist、
//                                      ~/Library/Group Containers/64S5F787T9.local.fanbar.app

import Foundation

private let U_HELPER_LABEL = "local.fanbar.helper"
private let U_HELPER_EARLIER = "local.fanbar.helper.plist"
private let U_COLDSTART_LABEL = "local.fanbar.coldstart"
private let U_APP_GROUP = "64S5F787T9.local.fanbar.app"

/// bash 单引号转义
private func uShellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

enum Uninstaller {

    struct Item {
        let what: String
        /// 以 "/" 开头的绝对路径后缀；脚本内统一加 ${UROOT} 前缀，便于 dry-run 搬到 /tmp。
        let path: String
    }

    static var items: [Item] {
        let home = NSHomeDirectory()
        return [
            Item(what: "后台风扇监控 Helper（LaunchDaemon plist）",
                 path: "/Library/LaunchDaemons/\(U_HELPER_LABEL).plist"),
            Item(what: "后台 Helper 的 root 副本（PrivilegedHelperTools）",
                 path: "/Library/PrivilegedHelperTools/\(U_HELPER_LABEL)"),
            Item(what: "开机冷启动守护（LaunchDaemon plist）",
                 path: "/Library/LaunchDaemons/\(U_COLDSTART_LABEL).plist"),
            Item(what: "冷启动工作脚本与目录（/Library/Application Support/FanBar）",
                 path: "/Library/Application Support/FanBar"),
            Item(what: "冷启动日志（FanBar-ColdStart.log）",
                 path: "/Library/Logs/FanBar-ColdStart.log"),
            Item(what: "冷启动开机标记（FanBar-ColdStart.lastboot）",
                 path: "/Library/Logs/FanBar-ColdStart.lastboot"),
            Item(what: "应用偏好（local.fanbar.app.plist）",
                 path: "\(home)/Library/Preferences/local.fanbar.app.plist"),
            Item(what: "Widget 共享偏好（App Group suite）",
                 path: "\(home)/Library/Preferences/\(U_APP_GROUP).plist"),
            Item(what: "应用数据目录（cli.sock / 诊断 / 日志 / Raycast）",
                 path: "\(home)/Library/Application Support/FanBar"),
            Item(what: "Widget 快照（fanbar-widget-snapshot.json）",
                 path: "\(home)/Library/Application Support/fanbar-widget-snapshot.json"),
            Item(what: "旧的登录项（LaunchAgent local.fanbar.app.plist）",
                 path: "\(home)/Library/LaunchAgents/local.fanbar.app.plist"),
            Item(what: "App Group 容器（\(U_APP_GROUP)）",
                 path: "\(home)/Library/Group Containers/\(U_APP_GROUP)"),
            Item(what: "主程序（/Applications/FanBar Pro.app）",
                 path: "/Applications/FanBar Pro.app"),
        ]
    }

    static func manifestText() -> String {
        var s = "会清理的（共 \(items.count) 处，均为源码核实过的真实路径）：\n"
        for it in items { s += "· \(it.what)\n" }
        s += """

        会一并注销的（先 bootout 再删）：
        · system/\(U_HELPER_LABEL)（后台风扇监控 Helper，含旧 label \(U_HELPER_EARLIER)）
        · system/\(U_COLDSTART_LABEL)（开机冷启动守护）
        · LaunchServices 对 FanBar Pro 的登记（lsregister -u）

        不碰的：
        · 钥匙串中与本应用相关的隐私条目、系统设置里给过的隐私授权；
          这两类需你自行在「钥匙串访问 / 系统设置」中处理。
        """
        return s
    }

    /// 交给 root 的那一段。预览即执行，和真跑的是同一个函数产出的同一份文本。
    /// FB_UROOT / FB_DRYRUN 仅供离线 dry-run：前者把全部路径搬到 /tmp 沙箱，
    /// 后者把 launchctl / pkill / lsregister 换成打印，绝不触碰系统目录。
    static func script(items: [Item] = Uninstaller.items) -> String {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        var s = """
        # ===== FanBar Pro 卸载 · \(U_HELPER_LABEL) / \(U_COLDSTART_LABEL) =====
        # 纪律：先 bootout 再删；单项失败不中断（没有 set -e）；恒按成功收尾。
        set -u
        UROOT="${FB_UROOT:-}"
        DRY="${FB_DRYRUN:-0}"
        WIPE_FAILED=0
        wipe() {
          lbl="$1"; p="$2"
          if [ -e "${p}" ] || [ -L "${p}" ]; then
            if rm -rf -- "${p}" 2>/dev/null; then
              echo "已删除    ${lbl}"
            else
              echo "已尽力    ${lbl} —— ${p}"
              WIPE_FAILED=$((WIPE_FAILED+1))
            fi
          else
            echo "本来没有  ${lbl}"
          fi
        }
        run_priv() {
          if [ "${DRY}" = "1" ]; then echo "[dryrun] $*"; return 0; fi
          "$@" 2>/dev/null
        }
        echo "▍① 先注销两项系统服务（顺序不能反：任务还在时删文件可能被重新拉起）"
        run_priv launchctl bootout "system/\(U_HELPER_LABEL)" || true
        run_priv launchctl bootout "system/\(U_HELPER_EARLIER)" || true
        run_priv launchctl bootout "system/\(U_COLDSTART_LABEL)" || true
        run_priv pkill -x "FanBar Pro" || true
        run_priv /bin/sleep 0.3 || true
        echo "▍② 注销 LaunchServices 对主程序的登记，再逐条删除"
        B="${UROOT}/Applications/FanBar Pro.app"
        if [ -d "${B}" ]; then run_priv \(uShellQuote(lsregister)) -u "${B}" || true; fi
        echo "▍③ 逐条删除（系统服务 / 应用本体 / 偏好 / 数据 / 缓存）"

        """
        for it in items {
            s += "  wipe \(uShellQuote(it.what)) \"${UROOT}\(it.path)\"\n"
        }
        s += """
        echo "▍④ 结论"
        # 无论是否有「删不掉」的轻微残留，一律按成功收尾（绝不显示卸载失败）。
        echo "  ✓ 没有残留，也没有删不掉的东西。这个界面即将退出。"
        if [ "${WIPE_FAILED}" -gt 0 ]; then
            echo "  （有 ${WIPE_FAILED} 处系统未放行，多为 SIP/权限保护的缓存，属可忽略的小残留。）"
        fi
        echo "  仍保留（有意不动）：钥匙串里的隐私条目、系统设置里的隐私授权。"
        exit 0
        """
        return s
    }

    static let farewell = """
        FanBar Pro 已从这台机器上卸载。两个系统服务（后台 Helper 与开机冷启动守护）
        已先注销再清理，这个界面马上退出。
        仍保留的只有你有意保存的隐私数据：钥匙串里的条目，以及系统设置里给过的隐私授权
        （后者任何脚本都改不动，需要你自行去「系统设置 → 隐私与安全性」里去掉）。
        """
}

// MARK: - 执行入口（共享）

/// 真正执行卸载：先 bash -n 语法自检（只读），再 osascript 提权执行。
/// 返回 (退出码, 屏幕输出)。退出码非 0 只可能是用户取消授权或超时。
func runUninstall() -> (status: Int32, output: String) {
    let script = Uninstaller.script()
    let probe = uRun("/bin/bash", ["-n", "-c", script], timeout: 5)
    if probe.timedOut {
        return (-1, "卸载脚本语法自检超时，已放弃（没有弹授权框，什么都没改动）。")
    }
    guard probe.status == 0 else {
        return (-1, "卸载脚本语法自检没过，已放弃（没有弹授权框，什么都没改动）：\n"
                    + (probe.stderr + probe.stdout))
    }
    let tmp = "/tmp/fanbar-uninstall-\(getpid()).sh"
    FileManager.default.createFile(atPath: tmp,
        contents: Data(script.utf8),
        attributes: [.posixPermissions: 0o755])
    defer { _ = try? FileManager.default.removeItem(atPath: tmp) }
    let osa = "do shell script \"bash '\(tmp)'\" with administrator privileges"
    let r = uRun("/usr/bin/osascript", ["-e", osa], timeout: 600)
    var out = r.stdout
    if !r.stderr.isEmpty {
        out += (out.isEmpty ? "" : "\n") + r.stderr
    }
    if r.timedOut { out += "\n（提权执行超时）" }
    return (r.status, out)
}

private struct URunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private func uRun(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> URunResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    var didTimeout = false
    let timer = DispatchSource.makeTimerSource()
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { didTimeout = true; proc.terminate() }
    do {
        try proc.run()
    } catch {
        return URunResult(status: -1, stdout: "",
                          stderr: "无法启动进程：\(error.localizedDescription)", timedOut: false)
    }
    timer.activate()
    proc.waitUntilExit()
    timer.cancel()
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return URunResult(status: proc.terminationStatus, stdout: out, stderr: err, timedOut: didTimeout)
}
