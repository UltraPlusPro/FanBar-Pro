import FanBarShared
import XCTest
@testable import FanBar

/// Covers the 1.1.10 split of the old single `curveMode` display into
/// "curve + temperature" and "curve + fan speed", including the migration of a
/// value stored by 1.1.9.
final class MenuBarDisplayModeTests: XCTestCase {
    func testEveryRawValueRoundTrips() {
        for mode in MenuBarDisplayMode.allCases {
            XCTAssertEqual(
                MenuBarDisplayMode.resolve(rawValue: mode.rawValue),
                mode,
                "a stored value must keep resolving to its own mode"
            )
        }
    }

    func testLegacyCurveModeMigratesToCurveTemperature() {
        XCTAssertEqual(
            MenuBarDisplayMode.resolve(rawValue: "curveMode"),
            .curveTemperature,
            "1.1.9 stored `curveMode`; dropping it would hide the second status item"
        )
    }

    func testUnknownAndMissingValuesFallBackToTheDefault() {
        XCTAssertEqual(MenuBarDisplayMode.resolve(rawValue: nil), .defaultMode)
        XCTAssertEqual(MenuBarDisplayMode.resolve(rawValue: ""), .defaultMode)
        XCTAssertEqual(MenuBarDisplayMode.resolve(rawValue: "temperatureCurve"), .defaultMode)
    }

    func testReadoutIsOnlyDefinedForTheTwoCurveModes() {
        XCTAssertEqual(MenuBarDisplayMode.curveTemperature.curveReadout, .temperature)
        XCTAssertEqual(MenuBarDisplayMode.curveRPM.curveReadout, .fanSpeed)
        for mode in [MenuBarDisplayMode.iconOnly, .cpuTemperature, .fanSpeed,
                     .temperatureAndFanSpeed, .temperatureOverFanSpeed] {
            XCTAssertNil(mode.curveReadout, "\(mode.rawValue) must not own the second item")
        }
    }

    func testCurveModeTitlesAreDistinctAndNamedAfterTheReadout() {
        let temperature = MenuBarDisplayMode.curveTemperature.title(temperatureSource: .socAverage)
        let rpm = MenuBarDisplayMode.curveRPM.title(temperatureSource: .socAverage)
        XCTAssertNotEqual(temperature, rpm)
        XCTAssertTrue(temperature.contains("温度"), temperature)
        XCTAssertTrue(rpm.contains("转速"), rpm)
    }

    func testEveryTitleIsNonEmpty() {
        for mode in MenuBarDisplayMode.allCases {
            XCTAssertFalse(mode.title(temperatureSource: .socAverage).isEmpty)
            XCTAssertFalse(mode.detail(temperatureSource: .socAverage).isEmpty)
        }
    }

    func testWidestReadoutCoversThreeDigitTemperaturesAndGroupedSpeeds() {
        // The status item is sized from these strings, so a reading that can
        // be longer would make the item resize and the popover anchor jump.
        XCTAssertEqual(CurveModeReadout.temperature.widestText, "100°")
        XCTAssertEqual(CurveModeReadout.fanSpeed.widestText, "8,888")
    }
}
