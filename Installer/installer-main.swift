//  安装FanBarPro.app —— 卡巴斯基风格安装向导（FanBar Pro v1.1.9 / build 119）
//
//  DMG 根目录只有「安装FanBarPro.app」+「卸载FanBarPro.app」。
//  主程序内嵌在 安装FanBarPro.app/Contents/Resources/Payload/FanBar Pro.app。
//  点「安装」后整段只提权一次，装到 /Applications/FanBar Pro.app，并直接以
//  root 注册两项服务（后台 Helper + 开机冷启动 Daemon），用户无需再到设置操作。
//
//  root 脚本模板 = Contents/Resources/install-root.sh；安装器把两个占位符替换成
//  真实路径后写临时文件，先 bash -n 自检再交给 osascript 提权执行。
//  STEP| 进度轮询与脚本同文件，保证预览与真跑一致。

import SwiftUI
import AppKit
import Foundation

// MARK: - 安装步骤

enum InstallStep: Int {
    case welcome = 0
    case license = 1
    case progress = 2
    case done = 3
}

// MARK: - 各页面

struct WelcomeView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 42)
            KProductIconView(size: 104, bordered: false)
            Text("欢迎使用")
                .font(.system(size: 13))
                .foregroundColor(KTheme.textSecondary)
                .padding(.top, 20)
            Text("FanBar Pro")
                .font(.system(size: 27, weight: .regular))
                .foregroundColor(KTheme.textPrimary)
                .padding(.top, 8)
            Text("版本 \(InstallerModel.appVersion) · build \(InstallerModel.appBuild)")
                .font(.system(size: 11.5))
                .foregroundColor(KTheme.textSecondary)
                .padding(.top, 6)
            Text("macOS 菜单栏风扇控制工具 · 安装完自动注册风扇监控与开机守护服务")
                .font(.system(size: 12))
                .foregroundColor(KTheme.textSecondary)
                .padding(.top, 2)
            Spacer()
            VStack(spacing: 10) {
                KButton(title: "安装", primary: true, width: 150) {
                    model.step = .license
                }
                KButton(title: "了解安装内容", primary: false, width: 150) {
                    model.step = .license
                }
            }
            Spacer().frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KTheme.windowDeep)
    }
}

struct LicenseView: View {
    @ObservedObject var model: InstallerModel

    private var canContinue: Bool { model.acceptedEULA && model.acceptedServices }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最终用户授权许可协议")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(KTheme.textPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("FanBar Pro 最终用户授权许可协议（下称「本协议」）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(KTheme.textPrimary)
                    Text("重要声明：在开始使用本软件之前，请仔细阅读以下条款。在这个窗口里单击「接受」，即表示您确认已阅读并同意本协议的全部条款。若您不能完全同意，请点「返回」退出安装程序。")
                        .font(.system(size: 12)).foregroundColor(KTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("一、软件性质\nFanBar Pro 是一款 macOS 菜单栏风扇控制工具，可读取温度、转速并在授权后控制风扇。它以开源项目主线为基础构建，按「现状」提供，不附带任何明示或默示担保。")
                        .font(.system(size: 12)).foregroundColor(KTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("二、开源许可\n本软件以 MIT 许可证发布；你有权使用、复制、修改与分发，但须保留原始版权与许可声明。")
                        .font(.system(size: 12)).foregroundColor(KTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("三、本机数据与隐私\n本软件默认在本机运行，不收集或上传你的文件内容。兼容性/诊断报告的上传（若使用）均需你主动确认；温度历史、曲线等设置保存在本机。")
                        .font(.system(size: 12)).foregroundColor(KTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("四、安装内容与系统服务\n安装会：向「应用程序」文件夹写入 /Applications/FanBar Pro.app；并直接以管理员权限注册两项系统服务，用户无需再到设置里操作——\n  · 后台风扇监控 Helper（local.fanbar.helper）：root 拥有的 LaunchDaemon，用于风扇控制，走 LegacyLaunchd 路径，不使用 SMAppService；\n  · 开机冷启动守护服务（local.fanbar.coldstart）：开机 30/60/90 秒窗口内强力唤起 Helper，插电/台式机顺带设为「均衡」曲线。\n服务均写入 /Library/LaunchDaemons 等系统目录，卸载时由「卸载FanBarPro.app」反向清理。安装过程不会创建管理员账户、不会写入 sudoers。")
                        .font(.system(size: 12)).foregroundColor(KTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(KTheme.cardBG)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(KTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 10) {
                KCheckBox(on: $model.acceptedEULA,
                          label: "我确认已完整阅读、理解和接受最终用户授权许可协议的条款和条件")
                KCheckBox(on: $model.acceptedServices,
                          label: "我了解安装会注册上述两项系统服务（后台 Helper 与开机冷启动守护），并同意授予一次管理员权限")
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Spacer()
                KButton(title: "返回", primary: false, width: 150) { model.step = .welcome }
                KButton(title: "接受", primary: true, width: 150, enabled: canContinue) { model.startInstall() }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KTheme.windowDeep)
    }
}

struct ProgressView_: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        KProgressPage(title: model.stageTitle,
                      subtitle: model.stageSubtitle,
                      detail: model.stageDetail,
                      progress: model.progress,
                      onCancel: { model.cancelInstall() }) {
            VStack(spacing: 6) {
                Text("快了…")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(KTheme.textPrimary)
                Text("正在为你安装 FanBar Pro")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(KTheme.textPrimary)
            }
        }
    }
}

struct DoneView: View {
    @ObservedObject var model: InstallerModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if model.failed {
                ZStack {
                    Circle().fill(Color(rgb: 0x8C3A3A)).frame(width: 66, height: 66)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 30, weight: .bold)).foregroundColor(.white)
                }
                Text(model.cancelled ? "已取消" : "安装未完成")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(KTheme.textPrimary).padding(.top, 18)
                ScrollView {
                    Text(model.failureText)
                        .font(.system(size: 11.5)).foregroundColor(KTheme.textSecondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxWidth: 600, maxHeight: 210)
                .background(KTheme.cardBG)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(KTheme.cardBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 40).padding(.top, 12)
            } else {
                ZStack {
                    Circle().fill(KTheme.green).frame(width: 66, height: 66)
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .bold)).foregroundColor(.white)
                }
                Text("安装完成")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(KTheme.textPrimary).padding(.top, 20)
                Text("FanBar Pro 已安装到「应用程序」文件夹")
                    .font(.system(size: 13)).foregroundColor(KTheme.textSecondary).padding(.top, 8)
                Text(model.installedPath)
                    .font(.system(size: 11)).foregroundColor(Color(rgb: 0x7E828A)).padding(.top, 4)
                Text("已自动注册并加载：后台风扇监控 Helper（local.fanbar.helper）\n与开机冷启动守护服务（local.fanbar.coldstart）。无需再到设置里操作。")
                    .font(.system(size: 11)).foregroundColor(KTheme.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10).padding(.horizontal, 40)
            }
            Spacer()
            KButton(title: "完成", primary: true, width: 150) { NSApp.terminate(nil) }
            Spacer().frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KTheme.windowDeep)
    }
}

struct InstallerRoot: View {
    @StateObject private var model = InstallerModel()

    var body: some View {
        Group {
            switch model.step {
            case .welcome:  WelcomeView(model: model)
            case .license:  LicenseView(model: model)
            case .progress: ProgressView_(model: model)
            case .done:     DoneView(model: model)
            }
        }
        .frame(width: 720, height: 560)
    }
}

// MARK: - 入口

// 用顶层语句：build-installer.sh 编译前会把本文件暂存成 main.swift。
// 自检用 --print-escalation-command：只打印将要提权执行的那条命令（不提权、不弹窗），
// 便于把引擎主体拿出来单独跑逻辑验证。
if CommandLine.arguments.contains("--print-escalation-command") {
    let model = InstallerModel()
    guard let payload = model.payloadURL() else {
        FileHandle.standardError.write("payload missing\n".data(using: .utf8)!)
        exit(1)
    }
    print(model.escalationCommand(payload: payload))
    exit(0)
}

final class InstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KWindowShell.shared.show(title: "安装: FanBar Pro", size: NSSize(width: 720, height: 560)) {
            InstallerRoot()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let kApp = NSApplication.shared
kApp.setActivationPolicy(.regular)
let kDelegate = InstallerAppDelegate()
kApp.delegate = kDelegate
kApp.run()
