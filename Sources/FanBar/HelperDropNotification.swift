import FanBarShared
import Foundation
import UserNotifications

/// Settings and copy for the "the control service dropped" notice.
///
/// This is a safety net, not a nag: the helper going away silently is the one
/// failure a user cannot see, because the fans simply revert to macOS and
/// nothing in the UI says so. It is therefore on by default, but scoped tightly
/// — see `HelperDropGate` and the suppression rules in `FanController`.
enum HelperDropNotificationSettings {
    static let enabledKey = "fanbar.notifyOnHelperDrop"
    /// On by default: the whole point is to surface a silent failure.
    static let defaultEnabled = true

    static let identifier = "fanbar.helper-drop"

    /// One drop, one notice. Losing the XPC connection typically fails several
    /// calls within a few seconds (the retry, the re-apply, the health probe),
    /// and a helper crash-loop can repeat for minutes.
    static let cooldown: TimeInterval = 10 * 60

    /// After launch the helper is deliberately re-registered and probed, which
    /// produces a moment of "not enabled" on every start. Notices stay quiet
    /// for this long so a normal launch never reads as a failure.
    static let launchGracePeriod: TimeInterval = 20

    static var isEnabled: Bool {
        // Absent means never configured, which must read as the default rather
        // than as `Bool`'s false.
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

/// Rate-limits the drop notice so one incident produces one notification.
struct HelperDropGate {
    var cooldown: TimeInterval = HelperDropNotificationSettings.cooldown
    private(set) var lastNotifiedAt: Date?

    /// Returns whether a drop at `date` may notify, recording it when it may.
    /// A clock moved backwards ends the window instead of muting notices until
    /// the clock catches up.
    mutating func allowsNotification(at date: Date) -> Bool {
        if let lastNotifiedAt {
            let elapsed = date.timeIntervalSince(lastNotifiedAt)
            if elapsed >= 0, elapsed < cooldown { return false }
        }
        lastNotifiedAt = date
        return true
    }

    mutating func reset() {
        lastNotifiedAt = nil
    }
}

/// Why the helper is considered gone. It decides the wording, and it is what
/// makes the "user asked for this" cases distinguishable from a real drop.
enum HelperDropCause {
    /// The daemon stopped answering or its XPC connection broke.
    case connectionLost
    /// The service is still installed but launchd no longer has the process.
    case processGone

    var title: String {
        fanBarText("风扇控制服务已掉线", "The fan control service stopped")
    }

    var body: String {
        switch self {
        case .connectionLost:
            fanBarText(
                "风扇已交回 macOS 自动控制。可在「通用」中重新启用控制服务。",
                "The fans are back under macOS control. Re-enable the service in General."
            )
        case .processGone:
            fanBarText(
                "控制服务进程已退出，风扇已交回 macOS 自动控制。可重新启用控制服务。",
                "The control service process exited, so macOS has the fans. Re-enable the service to take over again."
            )
        }
    }
}
