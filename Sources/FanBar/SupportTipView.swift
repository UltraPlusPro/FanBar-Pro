import AppKit
import FanBarShared
import SwiftUI

/// Where a payment QR code comes from. The images ship twice: inside the
/// SwiftPM resource bundle (so `swift run` and `swift test` find them) and at
/// `Contents/Resources/Tip/` in the packaged app (so the bundle is browsable
/// and the embedded source archive is self-contained).
enum SupportTipAssets {
    enum Channel: String, CaseIterable, Identifiable {
        case wechat
        case alipay
        case qq

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wechat: fanBarText("微信支付", "WeChat Pay", chineseOnly: true)
            case .alipay: fanBarText("支付宝", "Alipay", chineseOnly: true)
            // 1.1.9: the QQ feedback group label is Chinese-only, with the
            // trailing "/ Feedback Group (QQ)" removed. A plain literal keeps
            // its dedicated wording without adding a key to every catalog.
            case .qq: fanBarTipChinese("反馈群 (QQ)")
            }
        }

        var hint: String {
            switch self {
            case .wechat: fanBarText("打开微信「扫一扫」", "Scan with WeChat", chineseOnly: true)
            case .alipay: fanBarText("打开支付宝「扫一扫」", "Scan with Alipay", chineseOnly: true)
            // 1.1.9: Chinese-only hint; the slash-English tail was removed.
            case .qq: fanBarTipChinese("打开 QQ「扫一扫」加入反馈群（群号 1135898675）：崩溃打包、日志打包、功能请求")
            }
        }

        /// The file name in both locations.
        var fileName: String {
            switch self {
            case .wechat: "TipWechat"
            case .alipay: "TipAlipay"
            case .qq: "TipQQ"
            }
        }

        /// What a save or copy names the image.
        var exportName: String {
            switch self {
            case .wechat: fanBarText("微信收款码.png", "WeChat-QR.png", chineseOnly: true)
            case .alipay: fanBarText("支付宝收款码.png", "Alipay-QR.png", chineseOnly: true)
            case .qq: fanBarTipChinese("反馈群二维码.png")
            }
        }
    }

    /// Packaged app location first, SwiftPM resource bundle second: both are
    /// sealed into the same signature, so neither path is a fallback to an
    /// unsigned file.
    static func url(for channel: Channel) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Tip", isDirectory: true)
                .appendingPathComponent("\(channel.fileName).png"),
            FanBarResources.url(forResource: channel.fileName, withExtension: "png"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    static func image(for channel: Channel) -> NSImage? {
        guard let url = url(for: channel), let image = NSImage(contentsOf: url) else { return nil }
        // Show the QR at its own pixel size so the codes stay crisp and scannable.
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            image.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image
    }
}

/// Fixed measurements, so the window opens at one predictable size and the
/// layout tests can assert on them.
enum SupportTipLayout {
    static let windowWidth: CGFloat = 420
    /// One square for the code: tall portrait screenshots fit inside it rather
    /// than stretching the window to their own height.
    static let codeBox: CGFloat = 300
}

/// The tip panel: one QR at a time behind a segmented channel switch, with
/// Save and Copy beside it. There is no network access anywhere: both images
/// travel inside the app bundle.
struct SupportTipView: View {
    /// Read so a language change relabels the window without a restart.
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue

    var onClose: () -> Void

    @State private var channel: SupportTipAssets.Channel = .wechat
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(fanBarText("支持 FanBar Pro", "Support FanBar Pro", chineseOnly: true))
                    .font(.system(size: 15, weight: .semibold))
                Text(fanBarText(
                    "FanBar Pro 免费开源，由我业余基于官方开源项目主线 0.9 构建，签名证书也是自费。如果它帮到了你，可以随意打赏。",
                    "FanBar Pro is free and open source, built in my spare time on top of the official 0.9 mainline. I pay for the signing certificate myself. If it helps, chip in any amount.",
                    chineseOnly: true
                ))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 380)

            Picker(fanBarText("支付方式", "Payment method", chineseOnly: true), selection: $channel) {
                ForEach(SupportTipAssets.Channel.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 1.1.9: three channels (WeChat / Alipay / QQ group) need a wider picker.
            .frame(width: 320)

            // The source screenshots are portrait (≈1:1.36), so a fixed width
            // would make the window needlessly tall. Fit the code inside one
            // square box instead and let the aspect ratio decide the rest.
            if let image = SupportTipAssets.image(for: channel) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: SupportTipLayout.codeBox, height: SupportTipLayout.codeBox)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .accessibilityLabel(channel.title)
            } else {
                // A missing image is visible rather than a silently blank panel.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: SupportTipLayout.codeBox, height: SupportTipLayout.codeBox)
                    .overlay(
                        Text(fanBarText("收款码未随应用提供", "Payment code is not bundled", chineseOnly: true))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }

            Text(channel.hint)
                .font(.callout)
                .foregroundColor(.secondary)

            // 1.1.7 removed the secondary "open the web checkout in a browser"
            // row: the bundled codes are the only tip path the window offers.

            HStack(spacing: 10) {
                Button(fanBarText("保存…", "Save…", chineseOnly: true)) { saveQR() }
                    .accessibilityLabel(fanBarFormat(
                        "保存%@收款码", "Save the %@ payment code", channel.title,
                        chineseOnly: true
                    ))
                Button(copied ? fanBarText("已复制", "Copied", chineseOnly: true) : fanBarText("复制", "Copy", chineseOnly: true)) {
                    copyQR()
                }
                .accessibilityLabel(fanBarFormat(
                    "复制%@收款码", "Copy the %@ payment code", channel.title,
                    chineseOnly: true
                ))
                Spacer(minLength: 0)
                Button(fanBarText("关闭", "Close", chineseOnly: true), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: SupportTipLayout.windowWidth)
        // 1.1.9: Chinese-only window. `.id` forces a redraw on a language
        // change so Simplified/Traditional copy relabels without a restart;
        // the locale stays Chinese so SwiftUI never formats in another language.
        .id(languageRawValue)
        .environment(\.locale, tipLocale)
    }

    private var tipLocale: Locale {
        FanBarLanguage.current == .traditionalChinese
            ? Locale(identifier: "zh-Hant")
            : Locale(identifier: "zh-Hans")
    }

    private func saveQR() {
        guard let image = SupportTipAssets.image(for: channel) else { return }
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
        guard let image = SupportTipAssets.image(for: channel) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Owns the one tip window. It is a real window of the app rather than a
/// separate helper executable, so its pixels and its code are both covered by
/// the app's own `codesign` seal.
@MainActor
final class SupportTipWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = SupportTipWindowPresenter()

    private var windowController: NSWindowController?
    private var localizedTitle: LocalizedWindowTitle?

    @discardableResult
    func show() -> NSWindow {
        let window: NSWindow
        if let existing = windowController?.window {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: SupportTipView(onClose: { [weak self] in self?.close() }))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            // The zoom button would only fight the fixed-width content.
            newWindow.standardWindowButton(.zoomButton)?.isHidden = true
            newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
            newWindow.isReleasedWhenClosed = false
            newWindow.isRestorable = false
            newWindow.delegate = self
            windowController = NSWindowController(window: newWindow)
            localizedTitle = LocalizedWindowTitle(window: newWindow, chinese: "支持开发", english: "Support", chineseOnly: true)
            newWindow.center()
            window = newWindow
        }
        window.title = fanBarText("支持开发", "Support", chineseOnly: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func close() {
        windowController?.close()
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
        localizedTitle = nil
    }
}
