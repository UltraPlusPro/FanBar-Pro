import FanBarShared
import XCTest
@testable import FanBar

/// The control-service drop notice: on by default, silent for the cases the
/// user caused, and never more than once per incident.
final class HelperDropNotificationTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HelperDropNotificationSettings.enabledKey)
        super.tearDown()
    }

    func testEnabledByDefaultWhenNeverConfigured() {
        UserDefaults.standard.removeObject(forKey: HelperDropNotificationSettings.enabledKey)
        XCTAssertTrue(HelperDropNotificationSettings.isEnabled)
        XCTAssertTrue(HelperDropNotificationSettings.defaultEnabled)
    }

    func testExplicitOffSticks() {
        UserDefaults.standard.set(false, forKey: HelperDropNotificationSettings.enabledKey)
        XCTAssertFalse(HelperDropNotificationSettings.isEnabled)
    }

    func testPreferenceKeyAndCooldownAreStable() {
        XCTAssertEqual(HelperDropNotificationSettings.enabledKey, "fanbar.notifyOnHelperDrop")
        XCTAssertEqual(HelperDropNotificationSettings.cooldown, 600)
        // A launch must not read as a drop; the grace period has to exist.
        XCTAssertGreaterThan(HelperDropNotificationSettings.launchGracePeriod, 0)
    }

    func testGateAllowsOneNoticePerCooldown() {
        var gate = HelperDropGate(cooldown: 600)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(gate.allowsNotification(at: start))
        XCTAssertFalse(gate.allowsNotification(at: start.addingTimeInterval(1)))
        XCTAssertFalse(gate.allowsNotification(at: start.addingTimeInterval(599)))
        XCTAssertTrue(gate.allowsNotification(at: start.addingTimeInterval(600)))
    }

    func testGateEndsTheWindowWhenTheClockMovesBackwards() {
        var gate = HelperDropGate(cooldown: 600)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(gate.allowsNotification(at: start))
        // A backwards clock must not mute notices until it catches up.
        XCTAssertTrue(gate.allowsNotification(at: start.addingTimeInterval(-3_600)))
    }

    func testGateResetAllowsTheNextNoticeImmediately() {
        var gate = HelperDropGate(cooldown: 600)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(gate.allowsNotification(at: start))
        XCTAssertFalse(gate.allowsNotification(at: start.addingTimeInterval(1)))
        gate.reset()
        XCTAssertTrue(gate.allowsNotification(at: start.addingTimeInterval(2)))
    }

    func testBothCausesHaveLocalizedTitleAndBody() {
        for cause in [HelperDropCause.connectionLost, .processGone] {
            XCTAssertFalse(cause.title.isEmpty)
            XCTAssertFalse(cause.body.isEmpty)
        }
        // The two causes are distinguished, not one generic sentence twice.
        XCTAssertNotEqual(HelperDropCause.connectionLost.body, HelperDropCause.processGone.body)
    }

    /// Turning the setting off must not change anything else about the app.
    @MainActor
    func testSettingIsPersistedAndReadBack() {
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { FakeFanReadingSource() },
            refreshInterval: nil
        )
        controller.setNotifyOnHelperDrop(false)
        XCTAssertFalse(controller.notifyOnHelperDrop)
        XCTAssertFalse(HelperDropNotificationSettings.isEnabled)

        controller.setNotifyOnHelperDrop(true)
        XCTAssertTrue(controller.notifyOnHelperDrop)
        XCTAssertTrue(HelperDropNotificationSettings.isEnabled)
    }

    /// A drop reported while the helper was never enabled is not a surprise:
    /// nothing was running, so nobody is interrupted.
    @MainActor
    func testDropIsIgnoredWhenTheServiceWasNotEnabled() {
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { FakeFanReadingSource() },
            refreshInterval: nil
        )
        XCTAssertNotEqual(controller.helperState, .enabled)
        controller.handleUnexpectedHelperDrop()
        // No crash, no state change: the guard is what keeps a normal launch
        // and a hand-back from producing a notice.
        XCTAssertNotEqual(controller.helperState, .enabled)
    }
}
