import AppKit
import FanBarShared
import SwiftUI

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly
    case cpuTemperature
    case fanSpeed
    case temperatureAndFanSpeed
    case temperatureOverFanSpeed
    /// 1.1.10: fan icon + a separate NSStatusItem that shows the current curve
    /// mode's icon with the temperature readout right beside it.
    case curveTemperature
    /// 1.1.10: same second status item, but the readout beside the curve icon
    /// is the average fan speed.
    case curveRPM

    static let preferenceKey = "fanbar.menuBarDisplayMode"
    static let defaultMode = MenuBarDisplayMode.iconOnly
    /// 1.1.9 stored this single value; 1.1.10 splits it into the two readouts.
    static let legacyCurveModeRawValue = "curveMode"

    /// Resolves a stored value, including the 1.1.9 `curveMode` token. A build
    /// that gains or renames a case must never silently drop the user back to
    /// the icon-only default, which reads as "my second icon disappeared".
    static func resolve(rawValue: String?) -> MenuBarDisplayMode {
        guard let rawValue else { return .defaultMode }
        if let mode = MenuBarDisplayMode(rawValue: rawValue) { return mode }
        if rawValue == legacyCurveModeRawValue { return .curveTemperature }
        return .defaultMode
    }

    /// Rewrites a legacy or unknown stored token once, at launch, so every
    /// reader — `@AppStorage` in the settings window and the AppKit status
    /// items — sees one canonical value. `resolve` alone keeps the runtime
    /// correct, but the raw string would stay stale forever.
    static func repairStoredValue(defaults: UserDefaults = .standard) {
        guard let stored = defaults.string(forKey: preferenceKey) else { return }
        let resolved = resolve(rawValue: stored)
        if resolved.rawValue != stored {
            defaults.set(resolved.rawValue, forKey: preferenceKey)
        }
    }

    /// Non-nil when this mode owns the second, independent status item and
    /// which number has to sit immediately to the right of its curve icon.
    var curveReadout: CurveModeReadout? {
        switch self {
        case .curveTemperature: .temperature
        case .curveRPM: .fanSpeed
        case .iconOnly, .cpuTemperature, .fanSpeed, .temperatureAndFanSpeed, .temperatureOverFanSpeed:
            nil
        }
    }

    var id: String { rawValue }

    /// Two lines must fit the 22pt menu bar, so the stacked mode uses the
    /// compact size system extras use for two-row readouts.
    static let stackedFontSize: CGFloat = 9

    /// The readout's name. The temperature modes are named after what they
    /// actually print, which depends on the temperature-logic choice: calling
    /// the row "Temperature (control input)" while it shows the hottest core
    /// would name a number the fans are not steered by.
    func title(temperatureSource: MenuBarTemperatureSource) -> String {
        switch self {
        case .iconOnly: return fanBarText("仅图标", "Icon only")
        case .cpuTemperature: return fanBarText("温度（显示口径）", "Temperature (shown)")
        case .fanSpeed: return fanBarText("风扇转速", "Fan speed")
        case .temperatureAndFanSpeed:
            return fanBarText("温度与转速", "Temperature + fan speed")
        case .temperatureOverFanSpeed:
            return fanBarText("温度与转速（上下排列）", "Temperature over fan speed")
        case .curveTemperature:
            return fanBarText("曲线与温度", "Curve + temperature")
        case .curveRPM:
            return fanBarText("曲线与转速", "Curve + fan speed")
        }
    }

    /// Explains the row in the terms of the current temperature logic, so the
    /// description can never contradict the number beside it.
    func detail(temperatureSource: MenuBarTemperatureSource) -> String {
        switch self {
        case .iconOnly:
            return fanBarText(
                "保持菜单栏最简洁，只显示当前控制模式图标。",
                "Keep the menu bar minimal with only the current mode icon."
            )
        case .cpuTemperature:
            switch temperatureSource {
            case .socAverage:
                return fanBarText(
                    "显示 SoC 平均温度，与风扇控制输入同源；悬停可看到最高核温度。",
                    "Show the SoC average, the same value fan control uses; hover for the hottest core."
                )
            case .hottestCore:
                return fanBarText(
                    "显示 CPU 最热核温度；风扇控制仍按 SoC 平均，悬停可看到该值。",
                    "Show the hottest CPU core; fan control still steers by the SoC average, shown on hover."
                )
            }
        case .fanSpeed:
            return fanBarText(
                "显示全部风扇的平均 RPM，并使用千位分隔。",
                "Show the average RPM across all fans with grouping separators."
            )
        case .temperatureAndFanSpeed:
            switch temperatureSource {
            case .socAverage:
                return fanBarText(
                    "同时显示 SoC 平均温度和平均风扇转速。",
                    "Show the SoC average temperature and average fan speed together."
                )
            case .hottestCore:
                return fanBarText(
                    "同时显示 CPU 最热核温度和平均风扇转速。",
                    "Show the hottest CPU core temperature and average fan speed together."
                )
            }
        case .temperatureOverFanSpeed:
            switch temperatureSource {
            case .socAverage:
                return fanBarText(
                    "SoC 平均温度在上、转速在下，占用更少的菜单栏宽度。",
                    "Stack the SoC average above fan speed to take less menu bar width."
                )
            case .hottestCore:
                return fanBarText(
                    "CPU 最热核温度在上、转速在下，占用更少的菜单栏宽度。",
                    "Stack the hottest CPU core above fan speed to take less menu bar width."
                )
            }
        case .curveTemperature:
            return fanBarText(
                "风扇图标与曲线图标各占一个独立的菜单栏项；曲线图标右侧紧邻温度读数，按住 ⌘ 可拖动调整位置。",
                "A separate menu bar item pairs the curve icon with the temperature right beside it; hold ⌘ to drag it elsewhere."
            )
        case .curveRPM:
            return fanBarText(
                "风扇图标与曲线图标各占一个独立的菜单栏项；曲线图标右侧紧邻风扇转速读数，按住 ⌘ 可拖动调整位置。",
                "A separate menu bar item pairs the curve icon with the fan speed right beside it; hold ⌘ to drag it elsewhere."
            )
        }
    }
}

/// The number the second, independent status item prints immediately to the
/// right of the curve icon (1.1.10).
enum CurveModeReadout: String, CaseIterable, Identifiable {
    case temperature
    case fanSpeed

    var id: String { rawValue }

    @MainActor
    func text(controller: FanController, temperatureSource: MenuBarTemperatureSource) -> String {
        switch self {
        case .temperature:
            guard let celsius = controller.menuBarTemperatureCelsius(source: temperatureSource) else {
                return "—°"
            }
            return "\(Int(celsius.rounded()))°"
        case .fanSpeed:
            guard !controller.fans.isEmpty else { return "— RPM" }
            let total = controller.fans.map(\.currentRPM).reduce(0, +)
            return FanBarNumberFormatter.grouped(Int((Double(total) / Double(controller.fans.count)).rounded()))
        }
    }

    /// The widest reading this readout can print. Measured instead of the live
    /// value so the status item keeps one width as the number changes; a
    /// resizing item makes the popover anchor jump while refreshing.
    var widestText: String {
        switch self {
        case .temperature: "100°"
        case .fanSpeed: "8,888"
        }
    }
}

/// Which CPU metric the menu bar prints. It is a display choice only: fan
/// control keeps steering by the same averaged SoC input either way, so a
/// spikier readout can never make the fans audible.
enum MenuBarTemperatureSource: String, CaseIterable, Identifiable {
    /// The steady SoC average — also the value the fan curve and alerts use.
    /// Default, so an existing install reads exactly as it did before.
    case socAverage
    /// The hottest CPU core: peaks within a sample, so sudden load shows at once.
    case hottestCore

    static let preferenceKey = "fanbar.menuBarTemperatureSource"
    static let defaultSource = MenuBarTemperatureSource.socAverage

    /// The stored choice, for code paths that have no `@AppStorage` to observe
    /// (the AppKit status items). Unknown or missing values read as the default.
    static var current: MenuBarTemperatureSource {
        MenuBarTemperatureSource(
            rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        ) ?? .defaultSource
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .socAverage: fanBarText("SoC 平均", "SoC average")
        case .hottestCore: fanBarText("CPU 最热核", "CPU hottest core")
        }
    }

    var detail: String {
        switch self {
        case .socAverage: fanBarText(
            "显示整颗芯片的平均温度，更平稳，与风扇控制输入同源。",
            "Show the chip's average temperature: steadier, and the same value fan control uses."
        )
        case .hottestCore: fanBarText(
            "显示最热的 CPU 核心，对突发负载更敏感，读数会更跳。",
            "Show the hottest CPU core: faster to react to a sudden load, so the number moves more."
        )
        }
    }
}

/// The single source of truth for both the real menu bar label and its settings preview.
struct MenuBarStatusLabel: View {
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue

    @ObservedObject var controller: FanController
    let displayMode: MenuBarDisplayMode
    @AppStorage(MenuBarIconStyle.preferenceKey)
    private var iconStyleRawValue = MenuBarIconStyle.defaultStyle.rawValue
    /// Read here so the tray relabels the moment the choice changes.
    @AppStorage(MenuBarTemperatureSource.preferenceKey)
    private var temperatureSourceRawValue = MenuBarTemperatureSource.defaultSource.rawValue

    private var iconStyle: MenuBarIconStyle {
        MenuBarIconStyle(rawValue: iconStyleRawValue) ?? .defaultStyle
    }

    private var temperatureSource: MenuBarTemperatureSource {
        MenuBarTemperatureSource(rawValue: temperatureSourceRawValue) ?? .defaultSource
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: iconStyle.image(isManual: controller.isManualStatus))
                .renderingMode(.template)
                .foregroundColor(.primary)

            // 1.1.10: the settings preview mirrors the second status item —
            // curve icon with the chosen readout immediately to its right.
            if let readout = displayMode.curveReadout,
               let curveIcon = CurveMode.current(controller).icon {
                Image(nsImage: curveIcon)
                    .renderingMode(.template)
                    .foregroundColor(.primary)
                Text(readout.text(controller: controller, temperatureSource: temperatureSource))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }

            if displayMode == .temperatureOverFanSpeed {
                VStack(alignment: .leading, spacing: -1) {
                    Text(temperatureText)
                    Text(fanSpeedText)
                }
                .font(.system(size: MenuBarDisplayMode.stackedFontSize, weight: .medium).monospacedDigit())
            } else if let statusText {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel(accessibilityText)
        .help(controller.temperatureToolTip(source: temperatureSource))
        .environment(\.locale, (FanBarLanguage(rawValue: languageRawValue) ?? .system).locale)
    }

    private var statusText: String? {
        switch displayMode {
        case .iconOnly, .curveTemperature, .curveRPM:
            // The curve readouts live in the second status item, next to the
            // curve icon, so the primary item stays icon-only.
            nil
        case .cpuTemperature:
            temperatureText
        case .fanSpeed:
            fanSpeedText
        case .temperatureAndFanSpeed, .temperatureOverFanSpeed:
            "\(temperatureText) · \(fanSpeedText)"
        }
    }

    private var temperatureText: String {
        guard let temperature = controller.menuBarTemperatureCelsius(source: temperatureSource) else {
            return "—°"
        }
        return "\(Int(temperature.rounded()))°"
    }

    private var fanSpeedText: String {
        guard !controller.fans.isEmpty else { return "— RPM" }
        let total = controller.fans.map(\.currentRPM).reduce(0, +)
        let average = Int((Double(total) / Double(controller.fans.count)).rounded())
        return FanBarNumberFormatter.grouped(average)
    }

    private var accessibilityText: String {
        guard let statusText else {
            return fanBarFormat(
                "FanBar Pro，%@模式",
                "FanBar Pro, %@ mode",
                controller.mode == .automatic
                    ? fanBarText("系统", "automatic")
                    : fanBarText("手动", "manual")
            )
        }
        return fanBarFormat("FanBar Pro，%@", "FanBar Pro, %@", statusText)
    }
}

/// Optional independent status items. Missing preferences deliberately default to off.
enum MenuBarResource: String, CaseIterable {
    case cpu, memory, gpu

    var preferenceKey: String { "fanbar.menuBarResource.\(rawValue)" }
    var stylePreferenceKey: String { "\(preferenceKey).style" }
    /// A shared template glyph keeps the settings preview and status item identical.
    var icon: NSImage {
        let resource = self
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            func line(_ start: NSPoint, _ end: NSPoint) {
                let path = NSBezierPath()
                path.lineWidth = 1.1
                path.lineCapStyle = .round
                path.move(to: start)
                path.line(to: end)
                path.stroke()
            }
            let rect: NSRect = resource == .memory
                ? NSRect(x: 1.5, y: 4.0, width: 11, height: 6)
                : NSRect(x: 3, y: 3, width: 8, height: 8)
            if resource != .gpu {
                let outline = NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6)
                outline.lineWidth = 1.1
                outline.stroke()
            }
            switch resource {
            case .cpu:
                for position in [5.0, 9.0] {
                    line(NSPoint(x: position, y: 1.5), NSPoint(x: position, y: 3))
                    line(NSPoint(x: position, y: 11), NSPoint(x: position, y: 12.5))
                    line(NSPoint(x: 1.5, y: position), NSPoint(x: 3, y: position))
                    line(NSPoint(x: 11, y: position), NSPoint(x: 12.5, y: position))
                }
                NSBezierPath(roundedRect: NSRect(x: 5.25, y: 5.25, width: 3.5, height: 3.5), xRadius: 0.8, yRadius: 0.8).fill()
            case .memory:
                for x in [4.5, 7.0, 9.5] {
                    line(NSPoint(x: x, y: 6), NSPoint(x: x, y: 8))
                }
            case .gpu:
                // A horizontal expansion card: bracket, vents, fan and contacts.
                // The off-centre fan avoids a camera-like silhouette.
                let board = NSBezierPath(roundedRect: NSRect(x: 2, y: 4, width: 10, height: 6), xRadius: 0.7, yRadius: 0.7)
                board.lineWidth = 1.1
                board.stroke()
                line(NSPoint(x: 1, y: 3), NSPoint(x: 1, y: 11))
                line(NSPoint(x: 1, y: 4), NSPoint(x: 2, y: 4))
                line(NSPoint(x: 1, y: 10), NSPoint(x: 2, y: 10))
                for x in [4.0, 6.0, 8.0, 10.0] {
                    line(NSPoint(x: x, y: 3), NSPoint(x: x, y: 4))
                }
                line(NSPoint(x: 3.8, y: 5.7), NSPoint(x: 3.8, y: 8.3))
                line(NSPoint(x: 5.5, y: 5.7), NSPoint(x: 5.5, y: 8.3))
                let fan = NSBezierPath(ovalIn: NSRect(x: 7, y: 5.25, width: 3.5, height: 3.5))
                fan.lineWidth = 1.1
                fan.stroke()
                NSBezierPath(ovalIn: NSRect(x: 8.3, y: 6.55, width: 0.9, height: 0.9)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: fanBarText("内存", "MEM")
        case .gpu: "GPU"
        }
    }

    var title: String {
        switch self {
        case .cpu: fanBarText("CPU 使用率", "CPU usage")
        case .memory: fanBarText("内存使用率", "Memory usage")
        case .gpu: fanBarText("GPU 使用率", "GPU usage")
        }
    }

    var panelResource: PanelResourceList.Resource {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        }
    }

    func text(for usage: SystemUsage, style: MenuBarResourceStyle = .label) -> String {
        MenuBarResourceItemContent.make(self, usage: usage, style: style).title
    }

    func valueText(for usage: SystemUsage) -> String {
        let fraction: Double?
        switch self {
        case .cpu: fraction = usage.cpuFraction
        case .memory: fraction = usage.memoryFraction
        case .gpu: fraction = usage.gpuFraction
        }
        guard let value = fraction, value.isFinite else { return "—" }
        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}

/// Per-resource presentation. Explicitly saved choices are preserved.
enum MenuBarResourceStyle: String, CaseIterable, Identifiable {
    case label, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .label: fanBarText("名称与数值", "Label and value")
        case .icon: fanBarText("图标与数值", "Icon and value")
        }
    }
}
