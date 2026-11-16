import AppKit
import Combine
import Foundation

/// System Low Power Mode is a hard, non-configurable gate on FanBar motion
/// (1.1.9). Both the menu-bar icon rotation and the panel fan rotors pause while
/// it is on and resume automatically when it turns off. There is deliberately no
/// user-facing switch that can disable this constraint.
///
/// `ProcessInfo.processInfo.isLowPowerModeEnabled` answers `false` unless the OS
/// explicitly reports Low Power Mode, so a state that cannot be read never
/// falsely pauses animation (no false positives).
enum LowPowerMode {
    /// Production reads the real system state. Tests inject a fixed value to
    /// exercise pause/resume without changing system settings.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    static var isActive: Bool {
        overrideForTesting ?? ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Posted once by `LowPowerModeMonitor` at startup and on every
    /// `NSProcessInfoPowerStateDidChange`, so AppKit (status item) and SwiftUI
    /// (panel) recompute their animation gates without a second timer.
    static let didChangeNotification = Notification.Name("FanBarLowPowerModeDidChange")
}

/// Bridges `NSProcessInfoPowerStateDidChangeNotification` to FanBar. The
/// `@Published` value drives SwiftUI redraws; the notification drives the AppKit
/// status item. Accessing `shared` installs the system observer exactly once.
@MainActor
final class LowPowerModeMonitor: ObservableObject {
    static let shared = LowPowerModeMonitor()

    @Published private(set) var isActive: Bool

    private var observer: NSObjectProtocol?

    private init() {
        isActive = LowPowerMode.isActive
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let active = LowPowerMode.isActive
            Task { @MainActor in
                self?.isActive = active
                NotificationCenter.default.post(name: LowPowerMode.didChangeNotification, object: nil)
            }
        }
    }
}
