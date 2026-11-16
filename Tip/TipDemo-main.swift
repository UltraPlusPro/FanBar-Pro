//
//  main.swift
//  打赏 · TipDemo 1.1
//
//  一个可直接复用的「打赏」成品 GUI（SwiftUI 界面 + AppKit 窗口宿主，单文件）。
//  抄作业方式：把本文件 + Resources/wechat.png + Resources/alipay.png + Resources/qq.png
//  拷进任意 app，改 CFBundleName 即可；也可以只抄 ContentView（配合 TipPresenter.present() 弹窗用）。
//
//  1.1 版（2026-11-13）：新增第三个渠道「反馈群」（QQ 群「Mac to Win」二维码，
//      群号 1135898675，用于崩溃打包 / 日志打包 / 功能请求 / 问题反馈）。
//      PayChannel 增加了 .qq 分支，其余逻辑通用，图片框仍为固定 300x470 等比适配。
//
//  1.0 版修复（2026-11-13）：
//   1. 收款图换成「已去隐私」的新图（旧 wechat.png 仍带 (**宸) 昵称，不能用）。
//   2. 竖长收款图（支付宝 1440x2240 ≈ 1.56:1）曾被裁掉：原实现写死 displayWidth = 450，
//      支付宝会被算成约 700pt 高，窗口装不下直接裁切。改为「等比适配到固定内容框」
//      （300x470），所有渠道都完整可见，且切换渠道窗口尺寸完全不跳。
//   3. 窗口尺寸由内容决定（NSHostingController.fittingSize），不写死小高度；
//      同时用 AppKit 锁死 min/max 尺寸，兼容 macOS 12.7（没有 SwiftUI
//      的 .windowResizability，那是 13.0+）。
//

import SwiftUI
import AppKit

// MARK: - 布局常量（唯一的尺寸来源，改这里就能整窗缩放）

enum TipLayout {
    /// 图片内容框：收款图等比缩放后必须完整落在这个框内。
    static let boxW: CGFloat = 300
    static let boxH: CGFloat = 470
    static let corner: CGFloat = 12
    /// 渠道选择器宽度（1.1 起有 3 个渠道，放宽到 320）
    static let pickerW: CGFloat = 320
    /// 内外边距 / 间距
    static let padding: CGFloat = 22
    static let spacing: CGFloat = 14
    /// 窗口内容的兜底下限（防止 fittingSize 在极端情况下算得过小）
    static let minWinW: CGFloat = 380
    static let minWinH: CGFloat = 620
    static let maxWinW: CGFloat = 560
}

// MARK: - AppKit 桥接：系统级窗口材质背景

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 支付渠道

enum PayChannel: String, CaseIterable, Identifiable {
    case wechat, alipay, qq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechat: return "微信支付"
        case .alipay: return "支付宝"
        case .qq:     return "反馈群"
        }
    }

    var imageName: String { rawValue }

    var hintText: String {
        switch self {
        case .wechat: return "打开微信「扫一扫」，支持作者 ¥2.00"
        case .alipay: return "打开支付宝「扫一扫」，支持作者 ¥2.00"
        case .qq:     return "扫码加入「Mac to Win」反馈群（群号 1135898675）：崩溃打包、日志打包、功能请求、问题反馈"
        }
    }

    var exportName: String {
        switch self {
        case .wechat: return "微信收款码.png"
        case .alipay: return "支付宝收款码.png"
        case .qq:     return "反馈群二维码.png"
        }
    }
}

// MARK: - 图片加载（尺寸取截图像素值，避免 Retina 下被当成 72dpi 缩一半）

enum QRImage {
    static func load(_ channel: PayChannel) -> NSImage? {
        guard let url = Bundle.main.url(forResource: channel.imageName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            image.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image
    }

    /// 等比适配到内容框后的显示尺寸：短边贴合，整图完整可见（绝不裁切）。
    static func fittedSize(_ channel: PayChannel) -> CGSize {
        guard let image = load(channel), image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: TipLayout.boxW, height: TipLayout.boxH)
        }
        let scale = min(TipLayout.boxW / image.size.width, TipLayout.boxH / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
}

// MARK: - 主界面（这就是可以整段抄走的打赏视图）

struct ContentView: View {
    @State private var channel: PayChannel = .wechat
    @State private var copied = false

    var body: some View {
        VStack(spacing: TipLayout.spacing) {
            Picker("支付方式", selection: $channel) {
                ForEach(PayChannel.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: TipLayout.pickerW)

            channelImage

            Text(channel.hintText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                // 固定提示区高度：三个渠道文案长短不一，避免切渠道时窗口高度跳动
                .frame(width: TipLayout.boxW, alignment: .center)
                .frame(minHeight: 38, alignment: .top)

            HStack(spacing: 12) {
                Button("保存二维码…") { saveQR() }
                Button(copied ? "已复制" : "复制二维码") { copyQR() }
            }
            .controlSize(.large)
        }
        .padding(TipLayout.padding)
        // 关键：内容尺寸固定 → 窗口尺寸 = 内容尺寸；
        // 图片框固定 300x470，切换渠道窗口尺寸完全不跳。
        .fixedSize()
        .background(VisualEffectBackground())
    }

    /// 收款图：等比适配进固定内容框，框本身固定占位，切换渠道不跳版。
    @ViewBuilder
    private var channelImage: some View {
        if let image = QRImage.load(channel) {
            let fitted = QRImage.fittedSize(channel)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // 先按等比适配后的真实尺寸布局，再整体落在固定占位框里：
                // 这样方形微信图(0.734:1)和竖长支付宝图(0.643:1)都完整可见。
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: TipLayout.corner))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .frame(width: TipLayout.boxW, height: TipLayout.boxH)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 44, weight: .light))
                Text("\(channel.title)收款码缺失")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(width: TipLayout.boxW, height: TipLayout.boxH)
        }
    }

    private func saveQR() {
        guard let image = QRImage.load(channel) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = channel.exportName
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    private func copyQR() {
        guard let image = QRImage.load(channel) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

// MARK: - 窗口呈现（这也是可以抄走的「以弹窗形式打开打赏」实现）

enum TipPresenter {
    private static var window: NSWindow?

    /// 用内容尺寸开一个独立「打赏」窗口（不缩放、居中、可在 Dock 里切换）。
    static func present() {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(rootView: ContentView())
        host.view.layoutSubtreeIfNeeded()
        var size = host.view.fittingSize

        // 兜底与夹取：宽度不低于 380 / 不高于 560，高度不低于 620（两个渠道都要装得下）。
        if size.width < TipLayout.minWinW { size.width = TipLayout.minWinW }
        if size.width > TipLayout.maxWinW { size.width = TipLayout.maxWinW }
        if size.height < TipLayout.minWinH { size.height = TipLayout.minWinH }
        let screenH = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        if size.height > screenH { size.height = screenH }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "打赏"
        window.contentViewController = host
        window.contentMinSize = size
        window.contentMaxSize = size
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        TipPresenter.window = window
    }
}

// MARK: - AppKit 生命周期

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 普通窗口程序（有 Dock 图标、出现在 Cmd-Tab 里）
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        TipPresenter.present()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { TipPresenter.present() }
        return true
    }
}

// MARK: - 程序入口（AppKit 主程序：窗口尺寸完全由内容决定）

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
