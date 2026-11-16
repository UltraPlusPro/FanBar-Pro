import AppKit
import FanBarShared

/// The "gears" the `.curveTemperature` / `.curveRPM` displays can show (1.1.10,
/// plus the system default in 1.1.11).
///
/// Mapping onto the real infrastructure (FanCoolingPreset itself has only FOUR
/// cases — the others come from the controller, not from that enum):
///   · macOS           → FanController.Mode.automatic (1.1.11)
///   · 静谧 / 均衡 / 性能 / 极速 → FanCoolingPreset.silent/.balanced/
///     .performance/.extreme (rawValue 0…3)
///   · 固定            → FanController.Mode.fixed(Int)
///   · 自定义…         → a custom CoolingPresetID.custom(UUID)
/// Every case owns a distinct SF Symbol so the icon changes with the gear.
enum CurveMode: String, CaseIterable, Identifiable {
    /// 1.1.11: the same "hand the fans back to macOS" entry the main panel has.
    /// It is first in `allCases`, so the dropdown opens with the system default
    /// above the curve gears — and the menu-bar icon stops claiming 性能 while
    /// the fans are actually macOS-controlled.
    case systemDefault
    case silent
    case balanced
    case performance
    case extreme
    case fixed
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        // 1.1.11: identical wording to the main panel's own entry.
        case .systemDefault: fanBarText("macOS", "macOS")
        // Reuse the preset titles so 意见3's 静谧 rename stays the single source
        // of truth and no new catalog keys are introduced here.
        case .silent: FanCoolingPreset.silent.title
        case .balanced: FanCoolingPreset.balanced.title
        case .performance: FanCoolingPreset.performance.title
        case .extreme: FanCoolingPreset.extreme.title
        case .fixed: fanBarText("固定", "Fixed")
        case .custom: fanBarText("自定义…", "Custom")
        }
    }

    /// One distinct, verified SF Symbol per gear. `.systemDefault` reuses the
    /// symbol the main panel already draws for macOS automatic control.
    var symbolName: String {
        switch self {
        case .systemDefault: "arrow.triangle.2.circlepath"
        case .silent: "moon.stars.fill"
        case .balanced: "equal.circle.fill"
        case .performance: "speedometer"
        case .extreme: "bolt.fill"
        case .fixed: "lock.fill"
        case .custom: "slider.horizontal.3"
        }
    }

    var icon: NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        image?.isTemplate = true
        return image
    }

    var builtInPreset: FanCoolingPreset? {
        switch self {
        case .silent: .silent
        case .balanced: .balanced
        case .performance: .performance
        case .extreme: .extreme
        case .systemDefault, .fixed, .custom: nil
        }
    }

    /// True only for the entry that hands the fans back to macOS.
    var returnsToSystemDefault: Bool { self == .systemDefault }

    /// Which icon the menu bar should show for the controller's live state.
    @MainActor
    static func current(_ controller: FanController) -> CurveMode {
        // 1.1.11: while macOS owns the fans, no curve gear is "the current
        // one", so the icon must say macOS instead of keeping the last preset.
        if controller.mode == .automatic { return .systemDefault }
        if case .fixed = controller.mode { return .fixed }
        switch controller.curveCoolingPreset {
        case .builtIn(let preset):
            switch preset {
            case .silent: return .silent
            case .balanced: return .balanced
            case .performance: return .performance
            case .extreme: return .extreme
            }
        case .custom:
            return .custom
        }
    }
}

/// Owns the SECOND, fully independent NSStatusItem used by the
/// `.curveTemperature` / `.curveRPM` display options (1.1.10).
///
/// The primary status item keeps the fan icon. This item draws the current
/// curve mode's icon and, immediately to its right, the chosen readout —
/// temperature or average fan speed — because "曲线与温度" is defined as the
/// curve icon with the number *adjacent* to it, not as two loose icons.
///
/// ⌘-drag requirement: the item is created with the standard `NSStatusBarButton`
/// (no custom `view`, which would break SkyLight's native menu-bar dragging),
/// `behavior` is left at its default (nothing is set to prohibit movement), and
/// an `autosaveName` is assigned so a user-arranged position survives relaunch
/// — exactly the pattern `MenuBarResourceItems` already uses. With two separate
/// NSStatusItems the user can ⌘-drag the readout pair away from the fan icon.
@MainActor
final class CurveModeStatusItem: NSObject {
    static let autosaveName = "FanBarCurveMode"

    private var item: NSStatusItem?
    private weak var controller: FanController?
    private var shownMode: CurveMode?
    private var shownReadout: CurveModeReadout?
    private var shownText: String?
    private var icons: [CurveMode: NSImage] = [:]
    /// Lets the menu's "open panel" entry reuse the primary popover.
    var onShowPanel: (() -> Void)?

    var button: NSStatusBarButton? { item?.button }

    func update(controller: FanController, readout: CurveModeReadout?) {
        self.controller = controller
        guard let readout else {
            remove()
            return
        }
        let statusItem = item ?? makeItem()
        guard let button = statusItem.button else { return }
        let mode = CurveMode.current(controller)
        let temperatureSource = MenuBarTemperatureSource.current
        let text = readout.text(controller: controller, temperatureSource: temperatureSource)
        if mode != shownMode || readout != shownReadout || text != shownText {
            let icon = icon(for: mode)
            button.image = icon
            button.imagePosition = .imageLeading
            button.title = text
            // Digits must not change their advance width as the reading moves.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.toolTip = "\(mode.title) · \(text)"
            button.setAccessibilityTitle("\(mode.title) · \(text)")
            shownMode = mode
            shownReadout = readout
            shownText = text
            // Width follows the widest possible reading, never the current one,
            // so a changing number cannot make the item (and the popover it
            // anchors) jump from digit to digit.
            let width = Self.width(icon: icon, readout: readout)
            if statusItem.length != width { statusItem.length = width }
        }
    }

    /// icon + image/title gap + widest reading + the button's horizontal inset.
    private static func width(icon: NSImage?, readout: CurveModeReadout) -> CGFloat {
        let iconWidth = icon?.size.width ?? 16
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textWidth = (readout.widestText as NSString).size(withAttributes: [.font: font]).width
        return max(NSStatusItem.squareLength, ceil(iconWidth + 3 + textWidth + 3))
    }

    private func makeItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        // Do NOT touch `behavior` and do NOT assign a custom `view`: both would
        // interfere with the system's ⌘-drag menu-bar rearrangement.
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showMenu(_:))
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.imagePosition = .imageLeading
        item = statusItem
        shownMode = nil
        shownReadout = nil
        shownText = nil
        return statusItem
    }

    private func remove() {
        guard let statusItem = item else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        item = nil
        shownMode = nil
        shownReadout = nil
        shownText = nil
    }

    private func icon(for mode: CurveMode) -> NSImage? {
        if let cached = icons[mode] { return cached }
        guard let image = mode.icon else { return nil }
        icons[mode] = image
        return image
    }

    // MARK: - Menu

    @objc private func showMenu(_ sender: NSStatusBarButton) {
        guard let controller else { return }
        let current = CurveMode.current(controller)
        let menu = NSMenu()
        for mode in CurveMode.allCases {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.image = icon(for: mode)
            entry.state = mode == current ? .on : .off
            menu.addItem(entry)
            // 1.1.11: keep the system default visually apart from the curve
            // gears, exactly like the main panel's mode row.
            if mode.returnsToSystemDefault { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let panel = NSMenuItem(
            title: fanBarText("打开面板…", "Open menu bar panel"),
            action: #selector(openPanel(_:)),
            keyEquivalent: ""
        )
        panel.target = self
        menu.addItem(panel)
        // Show the menu anchored to this independent status item.
        statusItemMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private var statusItemMenu: NSMenu?

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CurveMode(rawValue: raw),
              let controller else { return }
        if let preset = mode.builtInPreset {
            controller.setCoolingPreset(.builtIn(preset))
            return
        }
        switch mode {
        case .systemDefault:
            // 1.1.11: 意见2 — the missing "hand back to macOS" entry.
            controller.setAutomatic()
        case .fixed:
            // Freeze at the current average speed (or a safe default), which is
            // the most predictable "固定" action from the menu bar.
            let rpm: Int
            if case .fixed(let value) = controller.mode {
                rpm = value
            } else if !controller.fans.isEmpty {
                let total = controller.fans.map(\.currentRPM).reduce(0, +)
                rpm = max(1200, total / controller.fans.count)
            } else {
                rpm = 2500
            }
            controller.setFixedRPM(rpm)
        case .custom:
            // 「自定义…」reuses the EXISTING curve editor: Settings › Cooling
            // hosts FanCurveEditorView. Select that tab then open Settings.
            UserDefaults.standard.set(SettingsTab.cooling.rawValue, forKey: SettingsTab.preferenceKey)
            SettingsWindowPresenter.shared.show(controller: controller)
        default:
            break
        }
    }

    @objc private func openPanel(_ sender: NSMenuItem) {
        onShowPanel?()
    }
}
