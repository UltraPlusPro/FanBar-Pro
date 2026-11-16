import AppKit
import Combine
import FanBarShared

/// AppKit titles do not participate in SwiftUI's preference observation.
@MainActor
final class LocalizedWindowTitle {
    private var observation: AnyCancellable?

    /// `chineseOnly` keeps AppKit titles in Simplified/Traditional Chinese for
    /// windows that intentionally ship without other translations (the tip window).
    init(window: NSWindow, chinese: String, english: String, chineseOnly: Bool = false) {
        window.title = fanBarText(chinese, english, chineseOnly: chineseOnly)
        observation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak window] _ in
                Task { @MainActor in
                    window?.title = fanBarText(chinese, english, chineseOnly: chineseOnly)
                }
            }
    }
}
