//  InstallerModel.swift —— 安装器状态机（2026-11-15 从零重写）
//
//  为什么重写：旧状态机把「能不能安装」寄托在 osascript 的退出码上，而
//  osascript 对**任何** AppleScript 错误都只返回 1（实测：do shell script "exit 2"
//  → osascript 退出码 1）。于是旧版界面永远显示「安装失败（退出码 1）」，
//  永远说不出真正的失败原因，而真正的原因（模板占位符把引号替换进了变量值）
//  被彻底掩埋。
//
//  新机制（三条）：
//   ① 真正执行安装的是 install-core.sh。它把**自己的退出码**写进 exit.code 文件，
//      把逐项结果写进安装日志（STEP| / CHECK| / FAIL| / RESULT|）。
//      提权命令本身恒以 exit 0 收尾，所以 osascript 不会再抛错；
//      界面读文件拿真实状态，不猜。
//   ② 提权层若根本没跑起来（用户取消授权、密码错误、策略拦截），exit.code 不存在，
//      此时读 osascript 的输出文本区分原因，并把系统原文显示出来。
//   ③ 引擎报成功后，界面**再独立自检一遍**（应用可执行 / Helper 已加载 /
//      冷启动文件与 job 都在），自检不过就如实报告，绝不假报成功。
//
//  工作目录 /var/tmp/fanbar-installer-<pid>/：日志、退出码、授权输出都在里面，
//  用户可读，出问题可直接把 install.log 发出来。

import SwiftUI
import AppKit
import Foundation

final class InstallerModel: ObservableObject {
    @Published var step: InstallStep = .welcome
    @Published var acceptedEULA = false
    @Published var acceptedServices = false

    @Published var progress: Double = 0
    @Published var stageTitle = "安装"
    @Published var stageSubtitle = "准备安装…"
    @Published var stageDetail = ""
    @Published var failed = false
    @Published var failureText = ""
    @Published var cancelled = false
    @Published var installedPath = "/Applications/FanBar Pro.app"
    /// 引擎逐项结果（CHECK| / WARN| / FAIL| 行），失败时直接摆给用户看
    @Published var checkLines: [String] = []

    private var task: Process?
    private var pollTimer: Timer?
    private var osaHandle: FileHandle?

    /// 所有落盘文件都在这个目录里；root 只做追加写，界面始终可读
    private let workDir: String
    private var logPath: String   { workDir + "/install.log" }
    private var exitPath: String  { workDir + "/exit.code" }
    private var osaPath: String   { workDir + "/osascript.out" }
    private var cancelPath: String { workDir + "/cancel" }
    private var runnerPath: String { workDir + "/install-core.sh" }

    static let appVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.9"
    }()
    static let appBuild: String = {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "119"
    }()

    init() {
        workDir = "/var/tmp/fanbar-installer-\(getpid())"
        try? FileManager.default.createDirectory(atPath: workDir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
    }

    // MARK: - 路径与引用

    /// 单引号包裹；路径里的单引号按 shell 规则转义（DMG 挂载点、中文目录名都安全）
    func sq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func payloadURL() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let u = res.appendingPathComponent("Payload/FanBar Pro.app")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return u
    }

    /// 提权执行的完整 shell 命令（不含双引号，可直接放进 AppleScript 的双引号字符串）
    func escalationCommand(payload: URL) -> String {
        let r = sq(runnerPath), l = sq(logPath), p = sq(payload.path)
        let e = sq(exitPath), c = sq(cancelPath)
        // 说明：末尾 exit 0 让 osascript 永不抛错，真实退出码由 exit.code 传递
        return "FB_CANCEL=\(c) /bin/bash \(r) \(l) \(p) >> \(l) 2>&1; "
             + "__fb_rc=$?; /bin/echo EXITCODE=$__fb_rc >> \(l); "
             + "/bin/echo $__fb_rc > \(e); exit 0"
    }

    // MARK: - 准备安装引擎

    private func prepareRunner() -> String? {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("install-core.sh"),
              FileManager.default.fileExists(atPath: src.path) else {
            return "安装器缺少安装引擎（Contents/Resources/install-core.sh）。\n请重新下载 DMG 后再运行。"
        }
        try? FileManager.default.removeItem(atPath: runnerPath)
        do {
            try FileManager.default.copyItem(atPath: src.path, toPath: runnerPath)
        } catch {
            return "无法把安装引擎写入 \(workDir)：\(error.localizedDescription)"
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerPath)

        // 日志与授权输出**先由界面建好**：root 只追加，界面必然读得到，
        // 彻底避免旧版「日志路径写不出来 → 界面一片空白」。
        // 先删后建：上一次运行（或失败重试）后这两个文件可能已被 root 写入过，
        // 不删会导致本轮读到上一轮的陈旧 STEP/CHECK 行。
        for f in [logPath, osaPath] {
            try? FileManager.default.removeItem(atPath: f)
            FileManager.default.createFile(atPath: f, contents: Data())
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f)
        }
        try? FileManager.default.removeItem(atPath: exitPath)
        try? FileManager.default.removeItem(atPath: cancelPath)
        return nil
    }

    /// 提权前的语法自检：不弹窗、不改系统，语法坏了当场报
    private func syntaxCheck() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n", runnerPath]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "无法执行 bash -n：\(error.localizedDescription)" }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "bash -n 退出码 \(p.terminationStatus)" : text
    }

    // MARK: - 开始安装

    func startInstall() {
        step = .progress
        failed = false
        cancelled = false
        checkLines = []
        progress = 0.02
        stageTitle = "安装"
        stageSubtitle = "正在准备安装…"
        stageDetail = "Preparing"
        KWindowShell.shared.setClosable(false)

        guard let payload = payloadURL() else {
            fail("安装器内部找不到主程序包（Contents/Resources/Payload/FanBar Pro.app）。\n请把 DMG 重新挂载后再运行安装器，或重新下载 DMG。")
            return
        }
        if let err = prepareRunner() { fail(err); return }
        if let bad = syntaxCheck() {
            fail("安装引擎语法自检未通过（没有提权，未做任何更改）：\n\(bad)")
            return
        }

        startPolling()

        let cmd = escalationCommand(payload: payload)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [
            "-e", "with timeout of 900 seconds",
            "-e", "do shell script \"\(cmd)\" with administrator privileges",
            "-e", "end timeout"
        ]
        if let fh = FileHandle(forWritingAtPath: osaPath) {
            p.standardOutput = fh
            p.standardError = fh
            osaHandle = fh
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }
        do {
            try p.run()
            task = p
        } catch {
            pollTimer?.invalidate()
            pollTimer = nil
            fail("无法启动授权流程：\(error.localizedDescription)")
        }
    }

    // MARK: - 收尾判定

    private func finish() {
        pollTimer?.invalidate()
        pollTimer = nil
        osaHandle?.closeFile()
        osaHandle = nil
        readProgressOnce()

        if cancelled { return }   // 用户已主动取消，界面已经是取消态

        // 授权层没跑起来时，osascript 还没来得及写 exit.code；给它 0.3s 缓冲
        var rcText = readExitCode()
        if rcText == nil {
            for _ in 0..<3 where rcText == nil {
                Thread.sleep(forTimeInterval: 0.1)
                rcText = readExitCode()
            }
        }
        guard let code = rcText.flatMap({ Int($0) }) else {
            interpretEscalationFailure()
            return
        }

        switch code {
        case 0:
            succeedAfterVerify()
        case 20:
            markCancelled("安装已取消：引擎在当前步骤结束时安全中止，没有留下半成品。")
        case 77:
            fail("安装引擎没有拿到 root 权限（退出码 77），因此没有改动系统。\n\n"
                 + "请确认当前账户是管理员（系统设置 → 用户与群组），"
                 + "并在授权弹窗里输入该管理员的密码。\n\n" + reportBlock())
        case 19:
            fail("应用程序已装好，但两项系统服务没有全部加载成功。\n"
                 + "风扇控制与开机守护需要这两项服务，请把下面的日志发给开发者。\n\n" + reportBlock())
        case 10:
            fail("安装包不完整（退出码 10）：安装器内嵌的主程序找不到或已损坏。\n请重新下载 DMG。\n\n" + reportBlock())
        case 11:
            fail("拷贝应用程序失败（退出码 11）：可能是磁盘空间不足，或安装镜像已被弹出。\n\n" + reportBlock())
        case 12:
            fail("拷贝后的校验没通过（退出码 12）：安装内容损坏，旧版本未被改动。\n\n" + reportBlock())
        case 13:
            fail("替换应用程序失败（退出码 13）：旧版本正在运行或被占用。\n"
                 + "请完全退出 FanBar Pro 后重试；若已回滚，现有安装完好无损。\n\n" + reportBlock())
        case 14, 15:
            fail("后台风扇监控服务装配失败（退出码 \(code)）。应用已安装，服务未就绪。\n\n" + reportBlock())
        case 16, 17:
            fail("开机冷启动服务装配失败（退出码 \(code)）。应用已安装，服务未就绪。\n\n" + reportBlock())
        default:
            fail("安装失败（引擎退出码 \(code)）。\n\n" + reportBlock())
        }
    }

    private func readExitCode() -> String? {
        guard let raw = try? String(contentsOfFile: exitPath, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 没有 exit.code 说明提权命令根本没执行：用 osascript 的原文区分原因
    private func interpretEscalationFailure() {
        let osa = ((try? String(contentsOfFile: osaPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if osa.contains("-128") || osa.localizedCaseInsensitiveContains("user canceled")
            || osa.contains("用户已取消") || osa.contains("已取消") {
            markCancelled("已取消安装：没有完成管理员授权，未做任何更改。")
            return
        }
        if osa.contains("-60007") {
            fail("管理员密码不正确，未做任何更改。\n\n系统返回：\n\(osa)")
            return
        }
        if osa.contains("-60005") || osa.contains("-60006")
            || osa.localizedCaseInsensitiveContains("not authorized")
            || osa.localizedCaseInsensitiveContains("not permitted") {
            fail("系统拒绝了本次授权，未做任何更改。\n\n系统返回：\n\(osa)")
            return
        }
        if osa.contains("-1712") || osa.localizedCaseInsensitiveContains("timed out") {
            fail("安装超时被系统中止。若已开始拷贝，应用可能处于未完成状态，请重新运行安装器。\n\n系统返回：\n\(osa)")
            return
        }
        fail("安装没有开始：未能取得管理员权限。\n\n系统返回：\n"
             + (osa.isEmpty ? "（无输出）" : osa)
             + "\n\n日志：\(logPath)")
    }

    // MARK: - 装后独立自检（不信引擎的自述，自己再看一遍）

    private func succeedAfterVerify() {
        let v = verifyInstallation()
        if v.ok {
            progress = 1.0
            stageSubtitle = "安装完成"
            stageDetail = "应用与两项服务均已就绪"
            KWindowShell.shared.setClosable(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.step = .done }
        } else {
            fail("安装引擎报告成功，但安装后自检发现问题：\n\(v.detail)\n\n日志：\(logPath)")
        }
    }

    private func verifyInstallation() -> (ok: Bool, detail: String) {
        var lines: [String] = []
        var ok = true
        func hard(_ label: String, _ cond: Bool, _ detail: String) {
            lines.append((cond ? "✓ " : "✗ ") + label + "：" + detail)
            if !cond { ok = false }
        }
        func soft(_ label: String, _ cond: Bool, _ detail: String) {
            lines.append((cond ? "✓ " : "△ ") + label + "：" + detail)
        }

        let appBin = "/Applications/FanBar Pro.app/Contents/MacOS/FanBar Pro"
        let helperBin = "/Library/PrivilegedHelperTools/local.fanbar.helper/Contents/Library/LaunchServices/local.fanbar.helper"
        let helperPlist = "/Library/LaunchDaemons/local.fanbar.helper.plist"
        let coldPlist = "/Library/LaunchDaemons/local.fanbar.coldstart.plist"
        let coldScript = "/Library/Application Support/FanBar/fanbar-coldstart.sh"

        hard("主程序", FileManager.default.isExecutableFile(atPath: appBin), "/Applications/FanBar Pro.app")
        hard("Helper 程序", FileManager.default.fileExists(atPath: helperBin), helperBin)
        hard("Helper plist", FileManager.default.fileExists(atPath: helperPlist), helperPlist)
        hard("冷启动 plist", FileManager.default.fileExists(atPath: coldPlist), coldPlist)
        hard("冷启动脚本", FileManager.default.fileExists(atPath: coldScript), coldScript)

        let helperLoaded = jobLoaded("local.fanbar.helper")
        hard("Helper 已加载", helperLoaded, "launchctl print system/local.fanbar.helper")
        // 冷启动 Daemon 是 RunAtLoad + KeepAlive=false：跑完就退出，job 仍在但状态会变，
        // 因此只做提示，不作为失败依据。
        soft("冷启动 job", jobLoaded("local.fanbar.coldstart"), "launchctl print system/local.fanbar.coldstart")

        return (ok, lines.joined(separator: "\n"))
    }

    private func jobLoaded(_ label: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(label)"]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - 进度轮询

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.readProgressOnce()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// 日志行格式：
    ///   STEP|<键>|<0.00-1.00>|<中文>~<English>
    ///   CHECK|<项目>|ok|FAIL|<说明>   WARN|<项目>|<说明>   FAIL|<键>|<码>|<中文>
    private func readProgressOnce() {
        guard let raw = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        var next: [String] = []
        for line in raw.split(separator: "\n") {
            let p = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard !p.isEmpty else { continue }
            switch p[0] {
            case "STEP" where p.count >= 4:
                if let v = Double(p[2]) { progress = max(progress, min(1.0, v)) }
                let pair = p[3].split(separator: "~", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    stageSubtitle = pair[0]
                    stageDetail = pair[1]
                } else {
                    stageSubtitle = p[3]
                }
            case "CHECK" where p.count >= 4:
                next.append((p[2] == "ok" ? "✓ " : "✗ ") + p[1] + "：" + p[3])
            case "WARN" where p.count >= 3:
                next.append("△ " + p[1] + "：" + p[2])
            case "FAIL" where p.count >= 4:
                next.append("✗ " + p[3] + "（代码 " + p[2] + "）")
            default:
                break
            }
        }
        if next != checkLines { checkLines = next }
    }

    /// 失败时给用户的诊断块：逐项结果 + 日志尾部 + 日志路径
    private func reportBlock() -> String {
        var out: [String] = []
        if !checkLines.isEmpty {
            out.append("逐项结果：")
            out.append(contentsOf: checkLines.suffix(14))
        }
        if let raw = try? String(contentsOfFile: logPath, encoding: .utf8), !raw.isEmpty {
            let tail = raw.split(separator: "\n").suffix(8).joined(separator: "\n")
            out.append("")
            out.append("日志尾部：")
            out.append(tail)
        } else {
            out.append("")
            out.append("（安装日志为空：说明提权后的脚本没有真正开始执行）")
        }
        out.append("")
        out.append("完整日志：\(logPath)")
        return out.joined(separator: "\n")
    }

    // MARK: - 取消与终态

    func cancelInstall() {
        cancelled = true
        // root 子进程不能直接 kill（osascript 已把命令交给 root），
        // 改为放一个取消标志，引擎在步骤边界安全中止
        FileManager.default.createFile(atPath: cancelPath, contents: Data())
        pollTimer?.invalidate()
        pollTimer = nil
        KWindowShell.shared.setClosable(true)
        stageSubtitle = "已取消"
        stageDetail = "安装已取消"
        progress = 0
        failed = true
        failureText = "已请求取消。若引擎已进入拷贝阶段，会在该步骤结束时安全中止；"
                    + "换装是原子的，不会留下半成品。"
        step = .done
        // 3 秒后仍未退出，再收掉 osascript
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.task?.terminate()
        }
    }

    private func markCancelled(_ text: String) {
        cancelled = true
        KWindowShell.shared.setClosable(true)
        failed = true
        stageSubtitle = "已取消"
        stageDetail = "未做任何更改"
        failureText = text
        step = .done
    }

    private func fail(_ text: String) {
        pollTimer?.invalidate()
        pollTimer = nil
        KWindowShell.shared.setClosable(true)
        failed = true
        failureText = text
        stageSubtitle = "安装未完成"
        stageDetail = "Installation failed"
        step = .done
    }
}
