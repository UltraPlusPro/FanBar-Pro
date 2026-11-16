import AppKit
import FanBarShared
import Foundation
import IOKit.ps

/// What FanBar should do to the fan mode when a power or foreground condition
/// fires. Mirrors the menu's mode choices so the user maps each trigger to a
/// familiar outcome.
enum AdaptiveCoolingTrigger: String, CaseIterable, Identifiable, Sendable {
    /// Leave the current mode untouched.
    case noChange
    /// Hand control back to macOS automatic control.
    case macOS
    case silent
    case balanced
    case performance
    case extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noChange: fanBarText("不变化", "No change")
        case .macOS: fanBarText("macOS 系统", "macOS")
        case .silent: fanBarText("静谧", "Silent")
        case .balanced: fanBarText("均衡", "Balanced")
        case .performance: fanBarText("性能", "Performance")
        case .extreme: fanBarText("极速", "Extreme")
        }
    }
}

/// Watches two independent conditions that should temporarily steer the fan
/// mode — running on battery, and a full-screen game in front — and restores the
/// user's previous mode once both clear. A trigger whose action is `.noChange`
/// never overrides, so the feature is invisible until the user picks something.
///
/// Battery and game are combined with the game taking priority: a full-screen
/// game on battery uses the game's action; leaving the game falls back to the
/// battery action if still unplugged; plugging back in ends every override.
@MainActor
final class AdaptiveModeCoordinator {
    static let batteryDisconnectActionKey = "fanbar.batteryDisconnectAction"
    static let fullscreenGameActionKey = "fanbar.fullscreenGameAction"

    private weak var controller: FanController?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var appObserver: NSObjectProtocol?
    private var timer: Timer?

    /// The mode in effect before any override began; restored when overrides end.
    private var savedMode: FanController.Mode?
    /// The trigger currently applied, or nil when no override is active.
    private var appliedTrigger: AdaptiveCoolingTrigger?
    /// Guards against re-sending the same trigger before the helper is ready.
    private var hasAppliedTrigger = false

    /// Begins observing power-source and foreground-app changes. Safe to call
    /// once; a second call rebuilds the observers but is otherwise a no-op.
    func start(controller: FanController) {
        self.controller = controller
        installPowerSourceObserver()
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // A game leaving full-screen (⌘Esc) fires no activation event, and the
        // settings can change between notifications, so re-evaluate on a slow
        // beat. Three seconds is unnoticeable to the user and light on CPU.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    func stop() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
            self.appObserver = nil
        }
        timer?.invalidate()
        timer = nil
        controller = nil
    }

    // MARK: - Evaluation

    private func evaluate() {
        guard let controller else { return }
        let batteryAction = AdaptiveCoolingTrigger(
            rawValue: UserDefaults.standard.string(forKey: Self.batteryDisconnectActionKey) ?? ""
        ) ?? .noChange
        let gameAction = AdaptiveCoolingTrigger(
            rawValue: UserDefaults.standard.string(forKey: Self.fullscreenGameActionKey) ?? ""
        ) ?? .noChange

        // Full-screen game outranks battery; both are ignored when their action is
        // `.noChange`, which keeps an unconfigured trigger from doing anything.
        let onBattery = isOnBattery()
        let fullscreenGame = isFrontmostAppFullscreenGame()
        let desired: AdaptiveCoolingTrigger?
        if fullscreenGame {
            desired = gameAction == .noChange ? nil : gameAction
        } else if onBattery {
            desired = batteryAction == .noChange ? nil : batteryAction
        } else {
            desired = nil
        }

        applyDesired(desired, controller: controller)

        // The helper may have come online since the override began; send the
        // pending trigger now rather than waiting for the next transition.
        if controller.helperState == .enabled {
            trySend(controller: controller)
        }
    }

    private func applyDesired(_ desired: AdaptiveCoolingTrigger?, controller: FanController) {
        switch (appliedTrigger, desired) {
        case (.none, .none):
            return
        case (.none, .some(let trigger)):
            savedMode = controller.mode
            appliedTrigger = trigger
            hasAppliedTrigger = false
            trySend(controller: controller)
        case (.some, .none):
            let saved = savedMode
            savedMode = nil
            appliedTrigger = nil
            hasAppliedTrigger = false
            guard controller.helperState == .enabled else { return }
            restoreMode(saved, controller: controller)
        case (.some(let current), .some(let trigger)):
            guard current != trigger else { return }
            appliedTrigger = trigger
            hasAppliedTrigger = false
            trySend(controller: controller)
        }
    }

    private func trySend(controller: FanController) {
        guard controller.helperState == .enabled,
              let trigger = appliedTrigger,
              !hasAppliedTrigger else { return }
        applyTrigger(trigger, controller: controller)
        hasAppliedTrigger = true
    }

    private func applyTrigger(_ trigger: AdaptiveCoolingTrigger, controller: FanController) {
        switch trigger {
        case .noChange:
            break
        case .macOS:
            controller.setAutomatic()
        case .silent:
            controller.setCoolingPreset(.builtIn(.silent))
        case .balanced:
            controller.setCoolingPreset(.builtIn(.balanced))
        case .performance:
            controller.setCoolingPreset(.builtIn(.performance))
        case .extreme:
            controller.setCoolingPreset(.builtIn(.extreme))
        }
    }

    private func restoreMode(_ saved: FanController.Mode?, controller: FanController) {
        guard let saved else {
            // Nothing was captured (e.g. the override began while automatic);
            // handing back to macOS is the safe default.
            controller.setAutomatic()
            return
        }
        switch saved {
        case .automatic:
            controller.setAutomatic()
        case .temperatureCurve:
            controller.setCoolingPreset(controller.curveCoolingPreset)
        case .fixed(let rpm):
            controller.setFixedRPM(rpm)
        }
    }

    // MARK: - Power source

    /// Observes `com.apple.system.powersource` and re-evaluates on change. The
    /// callback is a plain C function; the coordinator is passed as an unretained
    /// pointer so it is never leaked or double-freed.
    private func installPowerSourceObserver() {
        if let existing = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), existing, .defaultMode)
            powerSourceRunLoopSource = nil
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let coordinator = Unmanaged<AdaptiveModeCoordinator>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in coordinator.evaluate() }
        }, context)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// True when the Mac is running from its battery rather than AC power.
    private func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        // The providing-source type answers AC-vs-battery directly and is the
        // most reliable signal; fall back to scanning the sources if it is absent.
        if let providing = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() {
            let value = providing as String
            if value == (kIOPSACPowerValue as String) { return false }
            if value == (kIOPSBatteryPowerValue as String) { return true }
        }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeRetainedValue()
                    as? [String: Any],
                  (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalType as String)
            else { continue }
            if (description[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSBatteryPowerValue as String) {
                return true
            }
        }
        return false
    }

    // MARK: - Full-screen game

    /// True when the frontmost regular app is a game (its bundle declares the
    /// Games category) and one of its windows fully covers a display. Native
    /// full-screen windows match the display rect exactly; borderless-windowed
    /// games that fill the screen also match, which is the behaviour we want.
    private func isFrontmostAppFullscreenGame() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular,
              isGame(bundleURL: frontmost.bundleURL) else { return false }
        return isAppFullscreenOnAnyDisplay(frontmost)
    }

    private func isGame(bundleURL: URL?) -> Bool {
        guard let url = bundleURL,
              let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let category = plist["LSApplicationCategoryType"] as? String else { return false }
        return category == "public.app-category.games"
    }

    private func isAppFullscreenOnAnyDisplay(_ app: NSRunningApplication) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let appWindows = windowList.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) }
        // Reading window geometry needs no screen-recording permission; only
        // window images do. A covering window matches the display rect within a
        // couple of pixels to absorb the rounded, scaled-edges of real layouts.
        for screen in NSScreen.screens {
            let frame = screen.frame
            for window in appWindows {
                guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let x = bounds["X"] as? CGFloat,
                      let y = bounds["Y"] as? CGFloat,
                      let width = bounds["Width"] as? CGFloat,
                      let height = bounds["Height"] as? CGFloat else { continue }
                if abs(x - frame.origin.x) <= 2,
                   abs(y - frame.origin.y) <= 2,
                   abs(width - frame.width) <= 4,
                   abs(height - frame.height) <= 4 {
                    return true
                }
            }
        }
        return false
    }
}
