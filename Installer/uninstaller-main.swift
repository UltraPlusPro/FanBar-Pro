//  卸载FanBarPro.app —— 卡巴斯基卸载器同款界面（FanBar Pro v1.1.9）
//
//  三条不能破的纪律：
//  ① 真卸载一律走共享模块 runUninstall()（uninstall-shared.swift），本文件不拼脚本。
//  ② 卸载器进程不活在 /Applications/FanBar Pro.app 里，删到一半不会「自己把自己干掉」。
//  ③ **不显示「卸载失败」**：只要不是用户主动取消授权，一律显示成功；
//     用户取消则回到欢迎页并提示「已取消，未做任何更改」，也不出现「失败」字样。

import SwiftUI
import AppKit
import Foundation

// MARK: - 文案

enum L {
    static let windowTitle     = "卸载: FanBar Pro"
    static let welcomeText     = "您确定要从此 Mac 卸载 FanBar Pro 吗?"
    static let btnUninstall    = "卸载"
    static let btnCancel       = "取消"

    static let progressTitle   = "卸载"
    static let ongoingSubtitle = "正在删除…"
    static let ongoingText     = "正在准备卸载…"
    static let authSubtitle    = "正在进行身份验证…"
    static let authText        = "请输入管理员密码以开始卸载。将先注销后台 Helper 与开机守护服务。"
    static let cancelledNotice = "已取消，系统未做任何更改。"

    static let finishedOK      = "卸载已成功完成。"
    static let btnQuit         = "退出"
}

enum Step {
    case welcome
    case progress
    case finished
}

// MARK: - 状态机

final class UninstallerModel: ObservableObject {
    @Published var step: Step = .welcome
    @Published var progress: Double = 0
    @Published var subtitle = L.ongoingSubtitle
    @Published var bodyText = L.ongoingText
    @Published var finishedMessage = L.finishedOK
    @Published var notice: String? = nil

    private var cancelled = false
    private var tickTimer: Timer?

    func startUninstall() {
        step = .progress
        progress = 0.05
        subtitle = L.ongoingSubtitle
        bodyText = L.ongoingText
        notice = nil
        cancelled = false
        KWindowShell.shared.setClosable(false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.progress = 0.18
            self.subtitle = L.authSubtitle
            self.bodyText = L.authText
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.progress < 0.9 { self.progress += 0.035 } else { t.invalidate() }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runUninstall()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.tickTimer?.invalidate()
                self.tickTimer = nil
                guard !self.cancelled else { return }
                let out = result.output
                if out.contains("User canceled") || out.contains("-128") || result.status == 1 {
                    // 用户取消授权：什么都没删；回到欢迎页并提示，不显示「失败」。
                    KWindowShell.shared.setClosable(true)
                    self.progress = 0
                    self.notice = L.cancelledNotice
                    self.step = .welcome
                    return
                }
                // 其它一切（脚本恒 exit 0 且以 ✓ 收尾）：一律按成功处理。
                self.progress = 1.0
                KWindowShell.shared.setClosable(true)
                self.finishedMessage = L.finishedOK
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.step = .finished
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        tickTimer?.invalidate()
        tickTimer = nil
        NSApp.terminate(nil)
    }
}

// MARK: - 产品图

struct KProductPic: View {
    var size: CGFloat = 140
    var body: some View {
        Group {
            if let img = KProductIcon.shared {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(rgb: 0xF0F0F2))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 欢迎页

struct WelcomePage: View {
    @ObservedObject var model: UninstallerModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            KProductPic(size: 140)
            Text(L.welcomeText)
                .font(.system(size: 23, weight: .regular))
                .foregroundColor(KTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 42)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12.5))
                    .foregroundColor(KTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
            }
            Spacer()
            HStack(spacing: 20) {
                KButton(title: L.btnCancel, primary: false, width: 140) { model.cancel() }
                KButton(title: L.btnUninstall, primary: true, width: 140) { model.startUninstall() }
            }
            Spacer().frame(height: 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KTheme.windowDeep)
    }
}

// MARK: - 进度页

struct ProgressPage: View {
    @ObservedObject var model: UninstallerModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            KProductPic(size: 104)
            Text(L.progressTitle)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(KTheme.textPrimary)
                .padding(.top, 26)
            Text(model.subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(KTheme.textSecondary)
                .padding(.top, 10)
            Text(model.bodyText)
                .font(.system(size: 12))
                .foregroundColor(KTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
                .padding(.top, 4)
                .padding(.horizontal, 40)
            KLightProgressBar(value: model.progress)
                .frame(width: 280)
                .padding(.top, 26)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KTheme.windowDeep)
    }
}

// MARK: - 完成页（只有成功一种结局）

struct FinishedPage: View {
    @ObservedObject var model: UninstallerModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            KFinishedBadge(ok: true, size: 64)
            Text(model.finishedMessage)
                .font(.system(size: 14))
                .foregroundColor(KTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .padding(.horizontal, 40)
            Text(Uninstaller.farewell)
                .font(.system(size: 11))
                .foregroundColor(KTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 44)
            Spacer()
            KButton(title: L.btnQuit, primary: true, width: 140) { NSApp.terminate(nil) }
            Spacer().frame(height: 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KTheme.windowDeep)
    }
}

struct UninstallerRoot: View {
    @StateObject private var model = UninstallerModel()

    var body: some View {
        Group {
            switch model.step {
            case .welcome:  WelcomePage(model: model)
            case .progress: ProgressPage(model: model)
            case .finished: FinishedPage(model: model)
            }
        }
        .frame(width: 620, height: 420)
    }
}

// MARK: - 入口

// QA 用 --dump-uninstall-script 打印真跑时使用的同一份 root 脚本
// （不提权、不弹窗），供离线 dry-run 做 bash -n / 路径沙箱验证。
if CommandLine.arguments.contains("--dump-uninstall-script") {
    print(Uninstaller.script())
    exit(0)
}

final class UninstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KWindowShell.shared.show(title: L.windowTitle,
                                 size: NSSize(width: 620, height: 420),
                                 background: KTheme.nsWindowBG) {
            UninstallerRoot()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let uApp = NSApplication.shared
uApp.setActivationPolicy(.regular)
let uDelegate = UninstallerAppDelegate()
uApp.delegate = uDelegate
uApp.run()
