//  NSudo for macOS —— 卡巴斯基风格 SwiftUI 组件（安装器 / 卸载器共用）
//
//  这个文件被编进两个独立可执行文件：
//    · 安装NSudo.app（installer-main.swift）
//    · 卸载NSudo.app（uninstaller-main.swift）
//  两边共用同一套主题色、按钮、勾选框、六边形进度图形与窗口装配逻辑，
//  避免「安装器是深蓝、卸载器是深灰」这种各写各的分叉。
//
//  视觉口径来自交付参考图（Kaspersky Endpoint Security 安装向导）：
//  深灰近黑窗口、蓝色主按钮、中性灰次按钮、白字 + 浅灰次要文字、
//  进度页深青底 + 绿色六边形描边 + 底部标题/副标题/进度条 + 右侧圆形取消。

import SwiftUI
import AppKit

// MARK: - 主题

enum KTheme {
    // 自适应系统外观（浅色 / 深色）：全部用语义色（NSColor 系统色）。
    // 这些是「动态颜色」，会随 macOS 的浅色 / 深色模式自动切换，
    // 不再钉死成一套深色字面量 —— 窗口 appearance 也不再写 .darkAqua（见 KWindowShell）。
    static let windowBG   = Color(NSColor.windowBackgroundColor)
    static let windowDeep = Color(NSColor.windowBackgroundColor)
    // 内容卡片：比窗口背景浅一档（深色下卡片更亮、浅色下卡片更白），形成层次。
    static let cardBG     = Color(NSColor.controlBackgroundColor)
    static let cardBorder = Color(NSColor.separatorColor)
    // 按钮
    static let blue       = Color(NSColor.systemBlue)
    static let grayBtn    = Color(NSColor.controlColor)
    // 文字
    static let textPrimary   = Color(NSColor.labelColor)
    static let textSecondary = Color(NSColor.secondaryLabelColor)
    // 进度页（活动面板，跟随系统：深色下是深灰、浅色下是浅灰）
    static let progressBG = Color(NSColor.controlBackgroundColor)
    static let green      = Color(NSColor.systemGreen)
    static let trackGray  = Color(NSColor.separatorColor)
    // 产品图标外圈描边：语义分隔色（中性，跟随系统）。
    // 曾经这里是一道品红（#C24BD8）细框，因为交付参考图上有一圈洋红 ——
    // 但那圈洋红是用户在截图上手画的「看这里」提示圈，不是卡巴斯基的界面元素。
    // 交付物里出现任何品红/粉紫色装饰边框都是错的，所以钉成中性分隔色。
    static let iconRing   = Color(NSColor.separatorColor)

    // AppKit 侧（窗口背景 / 标题栏要跟随系统）：语义系统色，浅色/深色自动变。
    static let nsWindowBG = NSColor.windowBackgroundColor
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red:   Double((rgb >> 16) & 0xFF) / 255.0,
                  green: Double((rgb >> 8)  & 0xFF) / 255.0,
                  blue:  Double( rgb        & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

// MARK: - 产品图标

/// 产品图标（NSudo 主图标）。构建时以 ProductIcon.icns 放进 Resources。
enum KProductIcon {
    static let shared: NSImage? = {
        if let p = Bundle.main.path(forResource: "ProductIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: p) { return img }
        if let p = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: p) { return img }
        return NSImage(named: "ProductIcon") ?? NSImage(named: "AppIcon")
    }()
}

/// 产品图标 + 可选品红细描边（欢迎页 / 确认页）
struct KProductIconView: View {
    var size: CGFloat = 104
    var bordered: Bool = true
    var body: some View {
        ZStack {
            if let img = KProductIcon.shared {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color(rgb: 0xF0F0F2))
                    .frame(width: size, height: size)
            }
        }
        .padding(bordered ? 13 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(bordered ? KTheme.iconRing : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - 按钮

struct KButton: View {
    let title: String
    var primary: Bool = true
    var width: CGFloat = 150
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(primary ? .white : Color(NSColor.controlTextColor))
                .frame(width: width, height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(primary ? KTheme.blue : KTheme.grayBtn)
                )
                // 次按钮（取消 / 返回 / 定制 / 卸载里的「取消」这类中性按钮）必须有一圈边框：
                // 浅色模式下 controlColor 底色接近白，没边框就会「整颗按钮消失」在白底上，
                // 对齐卡巴斯基那种「白底 + 浅灰边框 + 深色字」的中性按钮。
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(primary ? Color.clear : KTheme.cardBorder, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.45)
    }
}

// MARK: - 勾选框

struct KCheckBox: View {
    @Binding var on: Bool
    let label: String

    var body: some View {
        Button(action: { on.toggle() }) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    // 未勾选：透明底 + 一圈边框（空勾选框）。曾经这里用深色填充（#3A3D44），
                    // 浅色模式下就变成一个「黑点」，所以改成空框。勾选后才是蓝色实心 + 白对勾。
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(on ? KTheme.blue : Color.clear)
                    RoundedRectangle(cornerRadius: 3.5)
                        .stroke(on ? Color.clear : KTheme.cardBorder, lineWidth: 1)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 15, height: 15)
                .offset(y: 1)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(KTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 进度条

struct KProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(KTheme.trackGray).frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [Color(rgb: 0x2F7CF6), Color(rgb: 0x5AA0FF)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, CGFloat(value))) * geo.size.width, height: 4)
            }
            .frame(height: 4)
        }
        .frame(height: 4)
    }
}

/// 圆形取消按钮（参考图右下角那颗灰底 x）
struct KCancelCircle: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(rgb: 0x55585E))
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Color(rgb: 0xD8DADF))
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 六边形进度图形

/// 六边形（带圆角），原点在上方顶点，顺时针。
struct HexagonShape: Shape {
    var cornerRatio: CGFloat = 0.16

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 * 0.96
        var pts: [CGPoint] = []
        for i in 0..<6 {
            let a = (Double(i) / 6.0) * 2 * .pi - .pi / 2
            pts.append(CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
        }
        func toward(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = max(0.0001, sqrt(dx * dx + dy * dy))
            return CGPoint(x: from.x + dx / len * d, y: from.y + dy / len * d)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
        }
        var p = Path()
        for i in 0..<6 {
            let cur = pts[i]
            let prev = pts[(i + 5) % 6]
            let next = pts[(i + 1) % 6]
            let a1 = toward(cur, prev, dist(cur, prev) * cornerRatio)
            let a2 = toward(cur, next, dist(cur, next) * cornerRatio)
            if i == 0 { p.move(to: a1) } else { p.addLine(to: a1) }
            p.addQuadCurve(to: a2, control: cur)
        }
        p.closeSubpath()
        return p
    }
}

/// 进度页中央图形：绿色六边形描边 + 内部斜线纹理 + 外侧细刻度线 + 四个度数标注。
struct KHexProgressGraphic: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2
                let hexRect = CGRect(x: c.x - outer * 0.80, y: c.y - outer * 0.80,
                                     width: outer * 1.60, height: outer * 1.60)
                let hex = HexagonShape(cornerRatio: 0.15).path(in: hexRect)

                // 内部底色 + 斜线纹理。深色模式保留原来的深青；浅色模式改成浅灰底，
                // 因为浅色模式下中央大标题是深色字，若仍盖在深青底上反而看不见。
                let hexFill = colorScheme == .dark ? Color(rgb: 0x112E34) : Color(white: 0.86)
                ctx.drawLayer { layer in
                    layer.clip(to: hex)
                    layer.fill(hex, with: .color(hexFill))
                    var x = hexRect.minX - hexRect.height
                    let step: CGFloat = 9
                    while x < hexRect.maxX + hexRect.height {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: hexRect.maxY))
                        p.addLine(to: CGPoint(x: x + hexRect.height, y: hexRect.minY))
                        layer.stroke(p, with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
                        x += step
                    }
                }

                // 外侧刻度线（长短交替）
                for i in 0..<180 {
                    let a = (Double(i) / 180.0) * 2 * .pi
                    let isMajor = i % 15 == 0
                    let inner = outer * (isMajor ? 0.87 : 0.905)
                    let len = outer * (isMajor ? 0.055 : 0.028)
                    let p1 = CGPoint(x: c.x + CGFloat(cos(a)) * inner,
                                     y: c.y + CGFloat(sin(a)) * inner)
                    let p2 = CGPoint(x: c.x + CGFloat(cos(a)) * (inner + len),
                                     y: c.y + CGFloat(sin(a)) * (inner + len))
                    var p = Path(); p.move(to: p1); p.addLine(to: p2)
                    ctx.stroke(p, with: .color(Color.primary.opacity(isMajor ? 0.28 : 0.15)),
                               lineWidth: isMajor ? 1.2 : 0.8)
                }

                // 绿色主描边
                ctx.stroke(hex, with: .color(KTheme.green),
                           style: StrokeStyle(lineWidth: 8, lineJoin: .round))
            }

            // 度数标注（对齐参考图的细小白字）
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Group {
                    degreeText("67°").position(x: w * 0.28, y: h * 0.14)
                    degreeText("127°").position(x: w * 0.70, y: h * 0.115)
                    degreeText("117°").position(x: w * 0.245, y: h * 0.885)
                    degreeText("26°").position(x: w * 0.605, y: h * 0.925)
                }
            }
        }
    }

    private func degreeText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9.5))
            .foregroundColor(Color.secondary)
    }
}

// MARK: - 进度页公共外壳

/// 深青底 + 六边形 + 中央大字 + 底部标题/副标题/进度条（+ 可选取消）
struct KProgressPage<CenterText: View>: View {
    let title: String
    let subtitle: String
    let detail: String
    let progress: Double
    var onCancel: (() -> Void)? = nil
    @ViewBuilder var centerText: () -> CenterText

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                KTheme.progressBG
                KHexProgressGraphic()
                    .frame(width: 330, height: 330)
                    .padding(.bottom, 12)
                centerText()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(KTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(KTheme.textSecondary)
                    .padding(.bottom, 6)
                HStack(spacing: 14) {
                    KProgressBar(value: progress)
                    if let onCancel = onCancel {
                        KCancelCircle(action: onCancel)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KTheme.windowBG)
        }
    }
}

// MARK: - 浅色主题（卸载器专用）
//
//  卸载器不是深色的！卡巴斯基卸载器是一个浅色 WebView（见其 derp.css：
//  color: #303030、font-family "Helvetica Neue"、白底、#container 左右 padding 40px、
//  #image 180×180 + #textual 弹性占满），与深色的安装向导完全两套皮肤。
//  这里按那份 CSS 的真实数值复刻，而不是「把安装器调亮一点」。

enum KLight {
    static let text        = Color(NSColor.labelColor)
    static let textWeak    = Color(NSColor.secondaryLabelColor)
    static let windowBG    = Color(NSColor.windowBackgroundColor)
    static let trackBG     = Color(NSColor.separatorColor)
    static let accent      = Color(NSColor.systemBlue)
    // finished_ok.pdf / finished_error.pdf 渲染取样得到的真实色（系统语义色，深浅两 mode 都清晰）
    static let okGreen     = Color(NSColor.systemGreen)
    static let failRed     = Color(NSColor.systemRed)

    static let nsWindowBG  = NSColor.windowBackgroundColor

    /// derp.css 用的是 Helvetica Neue；本机没有就退回系统字体（绝不是 Helvetica 斜体那种糊字）。
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        if NSFont(name: "Helvetica Neue", size: size) != nil {
            // SwiftUI 的 .custom 需要真实字族名；Helvetica Neue 的 Regular 家族名即为 "Helvetica Neue"
            switch weight {
            case .medium where NSFont(name: "HelveticaNeue-Medium", size: size) != nil:
                return .custom("HelveticaNeue-Medium", size: size)
            case .semibold where NSFont(name: "HelveticaNeue-Bold", size: size) != nil:
                return .custom("HelveticaNeue-Bold", size: size)
            default:
                return .custom("Helvetica Neue", size: size)
            }
        }
        return .system(size: size, weight: fontWeight(weight))
    }

    /// NSFont.Weight → Font.Weight（SwiftUI 用自己的一套权重枚举）
    private static func fontWeight(_ w: NSFont.Weight) -> Font.Weight {
        switch w {
        case .bold, .semibold: return .semibold
        case .medium:          return .medium
        case .light, .thin, .ultraLight: return .light
        default:               return .regular
        }
    }
}

/// 系统原生圆角按钮（NSButton .rounded）。
/// 浅色界面上「深色自绘按钮」会显得像第三方皮肤，卡巴斯基那边用的就是系统按钮，
/// 所以这里直接桥 NSButton，连按下高亮都交给 AppKit。
struct KSystemButton: NSViewRepresentable {
    let title: String
    var isDefault: Bool = false
    var width: CGFloat = 96
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: title, target: context.coordinator,
                         action: #selector(Coordinator.fire))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.font = NSFont(name: "Helvetica Neue", size: 13) ?? .systemFont(ofSize: 13)
        b.keyEquivalent = isDefault ? "\r" : ""
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// 完成页圆形徽标：绿圆 + 白对勾 / 红圆 + 白感叹号（对齐 finished_ok.pdf / finished_error.pdf）
struct KFinishedBadge: View {
    var ok: Bool
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(ok ? KLight.okGreen : KLight.failRed)
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

/// 浅色进度条：灰底 + 蓝色填充，圆角 2pt（卡巴斯基那条细长条）
struct KLightProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(KLight.trackBG).frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(KLight.accent)
                    .frame(width: max(0, min(1, CGFloat(value))) * geo.size.width, height: 4)
            }
            .frame(height: 4)
        }
        .frame(height: 4)
    }
}

// MARK: - 窗口装配

/// 固定尺寸窗口（SwiftUI 通过 NSHostingView 挂进来）。
/// appearance / 背景由调用方给：安装器深色、卸载器浅色，两套皮肤共用这一个壳，
/// 免得「一个窗口能跟随系统切换、另一个不能」这种不一致。
final class KWindowShell: NSObject, NSWindowDelegate {
    static let shared = KWindowShell()
    private var window: NSWindow?

    func show<Content: View>(title: String,
                             size: NSSize,
                             appearance: NSAppearance.Name? = nil,
                             background: NSColor = KTheme.nsWindowBG,
                             @ViewBuilder content: () -> Content) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered,
                         defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.backgroundColor = background
        // appearance 为 nil 时交给系统：窗口跟随「浅色 / 深色」自动切换，不再钉死深色。
        if let a = appearance { w.appearance = NSAppearance(named: a) }
        w.titlebarAppearsTransparent = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 进度执行期间禁止关窗（关掉窗口就等于关掉安装器，进度会丢在半路）
    func setClosable(_ yes: Bool) {
        guard let w = window else { return }
        if yes { w.styleMask.insert(.closable) } else { w.styleMask.remove(.closable) }
        w.standardWindowButton(.closeButton)?.isEnabled = yes
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
