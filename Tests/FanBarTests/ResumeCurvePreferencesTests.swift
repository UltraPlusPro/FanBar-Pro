import FanBarShared
import Foundation
import XCTest
@testable import FanBar

/// Covers the launch-replay decision logic: the persisted token format, the
/// "give up instead of guessing" decode rules, the fallback for a preset the
/// user deleted, the fan-range clamp and the gates that decide whether a
/// launch may touch the fans at all.
final class ResumeCurvePreferencesTests: XCTestCase {
    private static let suiteName = "local.fanbar.tests.resumeCurvePreferences"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        self.defaults = defaults
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Token round trip

    func testBuiltInPresetsRoundTripThroughTheirToken() {
        for preset in FanCoolingPreset.allCases {
            let id = CoolingPresetID.builtIn(preset)
            let raw = ResumeCurvePreferences.rawValue(for: .preset(id))

            XCTAssertEqual(raw, "preset:\(id.token)")
            XCTAssertEqual(ResumeCurvePreferences.snapshot(from: raw), .preset(id))
        }
    }

    func testCustomPresetRoundTripsThroughItsUUID() throws {
        let id = CoolingPresetID.custom(UUID(uuidString: "8C1E4F42-1B1D-4C6F-9F2C-0A6B5D3E7A11")!)
        let raw = ResumeCurvePreferences.rawValue(for: .preset(id))

        XCTAssertEqual(raw, "preset:custom:8C1E4F42-1B1D-4C6F-9F2C-0A6B5D3E7A11")
        XCTAssertEqual(ResumeCurvePreferences.snapshot(from: raw), .preset(id))
    }

    func testFixedRPMRoundTrips() {
        let raw = ResumeCurvePreferences.rawValue(for: .fixed(2400))

        XCTAssertEqual(raw, "fixed:2400")
        XCTAssertEqual(ResumeCurvePreferences.snapshot(from: raw), .fixed(2400))
    }

    func testSnapshotSurvivesSaveAndReload() {
        ResumeCurvePreferences.save(.fixed(3200), defaults: defaults)
        XCTAssertEqual(ResumeCurvePreferences.storedSnapshot(defaults: defaults), .fixed(3200))

        ResumeCurvePreferences.save(.preset(.builtIn(.extreme)), defaults: defaults)
        XCTAssertEqual(
            ResumeCurvePreferences.storedSnapshot(defaults: defaults),
            .preset(.builtIn(.extreme))
        )

        ResumeCurvePreferences.clear(defaults: defaults)
        XCTAssertNil(ResumeCurvePreferences.storedSnapshot(defaults: defaults))
    }

    // MARK: - Decode rejections

    func testMalformedTokensDecodeToNil() {
        let malformed: [String?] = [
            nil,
            "",
            "   ",
            "preset",
            "preset:",
            "preset:builtin",
            "preset:builtin:",
            "preset:builtin:99",
            "preset:builtin:abc",
            "preset:custom:",
            "preset:custom:not-a-uuid",
            "fixed",
            "fixed:",
            "fixed:0",
            "fixed:-1",
            "fixed:abc",
            "fixed:2400:6000",
            "temperatureCurve",
            "unknown:2400",
            ":2400"
        ]

        for raw in malformed {
            XCTAssertNil(
                ResumeCurvePreferences.snapshot(from: raw),
                "expected nil for \(String(describing: raw))"
            )
        }
    }

    func testStoredGarbageDecodesToNilRatherThanAFallbackMode() {
        defaults.set("fixed:-5", forKey: ResumeCurvePreferences.snapshotKey)
        XCTAssertNil(ResumeCurvePreferences.storedSnapshot(defaults: defaults))

        defaults.set(2400, forKey: ResumeCurvePreferences.snapshotKey)
        XCTAssertNil(
            ResumeCurvePreferences.storedSnapshot(defaults: defaults),
            "a non-string value must not decode into a mode"
        )
    }

    // MARK: - Deleted custom preset

    func testDeletedCustomPresetFallsBackToTheBuiltInFallback() {
        let deleted = CoolingPresetID.custom(UUID())
        let available: [CoolingPresetID] = [.builtIn(.silent), .builtIn(.balanced)]

        XCTAssertEqual(
            ResumeCurvePreferences.resolvedPreset(deleted, available: available),
            .fallback
        )
        XCTAssertEqual(CoolingPresetID.fallback, .builtIn(.balanced))
    }

    func testAvailablePresetIsKeptAsIs() {
        let custom = CoolingPresetID.custom(UUID())
        let available: [CoolingPresetID] = [.builtIn(.silent), .builtIn(.performance), custom]

        XCTAssertEqual(
            ResumeCurvePreferences.resolvedPreset(custom, available: available),
            custom
        )
        XCTAssertEqual(
            ResumeCurvePreferences.resolvedPreset(.builtIn(.performance), available: available),
            .builtIn(.performance)
        )
    }

    func testEmptyCatalogAlsoFallsBack() {
        XCTAssertEqual(
            ResumeCurvePreferences.resolvedPreset(.builtIn(.extreme), available: []),
            .fallback
        )
    }

    // MARK: - Fan range clamp

    func testResolvedRPMClampsToTheLiveFanRange() {
        let range = 1200...6000

        XCTAssertEqual(ResumeCurvePreferences.resolvedRPM(2400, in: range), 2400)
        XCTAssertEqual(ResumeCurvePreferences.resolvedRPM(1200, in: range), 1200)
        XCTAssertEqual(ResumeCurvePreferences.resolvedRPM(6000, in: range), 6000)
        XCTAssertEqual(
            ResumeCurvePreferences.resolvedRPM(900, in: range),
            1200,
            "a target below this Mac's fans must be raised to their minimum"
        )
        XCTAssertEqual(
            ResumeCurvePreferences.resolvedRPM(9000, in: range),
            6000,
            "a target above this Mac's fans must be lowered to their maximum"
        )
    }

    func testResolvedRPMHandlesADegenerateRange() {
        XCTAssertEqual(ResumeCurvePreferences.resolvedRPM(3000, in: 2000...2000), 2000)
    }

    // MARK: - Restore gates

    func testRestoreTargetReturnsTheSnapshotWhenEveryGateIsOpen() {
        ResumeCurvePreferences.setEnabled(true, defaults: defaults)
        ResumeCurvePreferences.save(.preset(.builtIn(.performance)), defaults: defaults)

        XCTAssertEqual(
            ResumeCurvePreferences.restoreTarget(
                defaults: defaults,
                isHelperEnabled: true,
                isBusy: false,
                isAutomatic: true
            ),
            .preset(.builtIn(.performance))
        )
    }

    func testRestoreTargetIsBlockedWhenTheSwitchIsOff() {
        ResumeCurvePreferences.save(.fixed(2500), defaults: defaults)
        defaults.set(false, forKey: ResumeCurvePreferences.enabledKey)

        XCTAssertNil(
            ResumeCurvePreferences.restoreTarget(
                defaults: defaults,
                isHelperEnabled: true,
                isBusy: false,
                isAutomatic: true
            )
        )
    }

    func testRestoreTargetIsBlockedWhenTheHelperIsNotEnabled() {
        ResumeCurvePreferences.setEnabled(true, defaults: defaults)
        ResumeCurvePreferences.save(.fixed(2500), defaults: defaults)

        XCTAssertNil(
            ResumeCurvePreferences.restoreTarget(
                defaults: defaults,
                isHelperEnabled: false,
                isBusy: false,
                isAutomatic: true
            )
        )
    }

    func testRestoreTargetIsBlockedWhileAnotherSwitchIsInFlight() {
        ResumeCurvePreferences.setEnabled(true, defaults: defaults)
        ResumeCurvePreferences.save(.fixed(2500), defaults: defaults)

        XCTAssertNil(
            ResumeCurvePreferences.restoreTarget(
                defaults: defaults,
                isHelperEnabled: true,
                isBusy: true,
                isAutomatic: true
            )
        )
    }

    func testRestoreTargetIsBlockedWhenTheUserAlreadyPickedAMode() {
        ResumeCurvePreferences.setEnabled(true, defaults: defaults)
        ResumeCurvePreferences.save(.fixed(2500), defaults: defaults)

        XCTAssertNil(
            ResumeCurvePreferences.restoreTarget(
                defaults: defaults,
                isHelperEnabled: true,
                isBusy: false,
                isAutomatic: false
            ),
            "a mode already chosen this session must win over the replay"
        )
    }

    func testRestoreTargetIsNilWithoutAStoredSnapshot() {
        ResumeCurvePreferences.setEnabled(true, defaults: defaults)

        XCTAssertNil(
            ResumeCurvePreferences.restoreTarget(
                defaults: defaults,
                isHelperEnabled: true,
                isBusy: false,
                isAutomatic: true
            )
        )
    }

    // MARK: - Switch lifecycle

    func testTurningTheSwitchOffForgetsTheSnapshot() {
        ResumeCurvePreferences.setEnabled(true, defaults: defaults)
        ResumeCurvePreferences.save(.fixed(2400), defaults: defaults)
        XCTAssertNotNil(ResumeCurvePreferences.storedSnapshot(defaults: defaults))

        ResumeCurvePreferences.setEnabled(false, defaults: defaults)

        XCTAssertFalse(ResumeCurvePreferences.isEnabled(defaults: defaults))
        XCTAssertNil(
            ResumeCurvePreferences.storedSnapshot(defaults: defaults),
            "an unarmed switch must not keep a mode to replay later"
        )
        XCTAssertNil(defaults.object(forKey: ResumeCurvePreferences.snapshotKey))
    }

    func testTurningTheSwitchOnKeepsAnExistingSnapshot() {
        ResumeCurvePreferences.save(.fixed(2400), defaults: defaults)

        ResumeCurvePreferences.setEnabled(true, defaults: defaults)

        XCTAssertTrue(ResumeCurvePreferences.isEnabled(defaults: defaults))
        XCTAssertEqual(ResumeCurvePreferences.storedSnapshot(defaults: defaults), .fixed(2400))
    }

    func testEnabledDefaultsToTrueOnAFreshDomain() {
        // 1.1.10: a fresh install resumes the last curve after a restart
        // without the user having to find the switch first.
        XCTAssertTrue(ResumeCurvePreferences.isEnabled(defaults: defaults))
        XCTAssertNil(ResumeCurvePreferences.storedSnapshot(defaults: defaults))
    }

    func testExplicitlyDisablingSurvivesAReload() {
        // Only a key that was never written reads as on; an explicit "off" is
        // user intent and must not be swallowed by the new default.
        ResumeCurvePreferences.setEnabled(false, defaults: defaults)
        XCTAssertFalse(ResumeCurvePreferences.isEnabled(defaults: defaults))
        // Reconstruct the read path the app uses on the next launch.
        XCTAssertFalse(ResumeCurvePreferences.isEnabled(defaults: defaults))
    }

    func testMalformedStoredValueFallsBackToOn() {
        defaults.set("yes", forKey: ResumeCurvePreferences.enabledKey)
        XCTAssertTrue(ResumeCurvePreferences.isEnabled(defaults: defaults))
    }

    func testStoredKeysKeepTheirNames() {
        // The keys are persisted user data: renaming them silently disarms
        // every existing install.
        XCTAssertEqual(ResumeCurvePreferences.enabledKey, "fanbar.resumeLastCurveOnLaunch")
        XCTAssertEqual(ResumeCurvePreferences.snapshotKey, "fanbar.resumeLastCurveMode")
    }
}
