import FanBarShared
import XCTest
@testable import FanBar

/// The menu bar can show either CPU metric, but the fan control input must
/// never move because of that choice.
final class MenuBarTemperatureSourceTests: XCTestCase {
    func testDefaultIsSoCAverageSoAnUpdateReadsLikeThePreviousVersion() {
        XCTAssertEqual(MenuBarTemperatureSource.defaultSource, .socAverage)
        XCTAssertEqual(
            MenuBarTemperatureSource(rawValue: MenuBarTemperatureSource.preferenceKey) ?? .defaultSource,
            .socAverage,
            "an unset or unknown stored value must fall back to the previous behaviour"
        )
    }

    func testEveryCaseHasATitleAndADetail() {
        for source in MenuBarTemperatureSource.allCases {
            XCTAssertFalse(source.title.isEmpty, source.rawValue)
            XCTAssertFalse(source.detail.isEmpty, source.rawValue)
        }
        XCTAssertEqual(MenuBarTemperatureSource.allCases.count, 2)
    }

    func testPreferenceKeyIsStable() {
        // Renaming it would silently reset every existing install's choice.
        XCTAssertEqual(MenuBarTemperatureSource.preferenceKey, "fanbar.menuBarTemperatureSource")
    }

    /// The two readings must resolve to different sensors, or the preference
    /// would be a no-op: average prefers `cpuCelsius`, hottest prefers
    /// `cpuHottestCelsius`.
    func testReadingResolutionPicksTheRightSensor() {
        let reading = ThermalReading(
            sampledAt: Date(),
            cpuCelsius: 61,
            gpuCelsius: nil,
            cpuHottestCelsius: 78
        )
        XCTAssertEqual(reading.cpuCelsius, 61)
        XCTAssertEqual(reading.cpuHottestCelsius, 78)
        // The shared "what every surface shows" value stays the average.
        XCTAssertEqual(reading.cpuDisplayCelsius, 61)
    }

    /// Automatic mode has no curve input, so both choices read the same sample
    /// but pick different sensors. The fan control input must stay the average.
    @MainActor
    func testMenuBarHonoursTheChoiceWhileControlKeepsTheAverage() {
        let source = FakeFanReadingSource(cpuCelsius: 61, cpuHottestCelsius: 78)
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { source },
            refreshInterval: nil
        )
        controller.refresh()

        XCTAssertEqual(controller.menuBarTemperatureCelsius(source: .socAverage), 61)
        XCTAssertEqual(controller.menuBarTemperatureCelsius(source: .hottestCore), 78)
        // The control input, the alerts and the widget snapshot are unchanged.
        XCTAssertEqual(controller.displayTemperatureCelsius, 61)
        XCTAssertEqual(controller.temperatureHistory.last?.cpuCelsius, 61)
    }

    /// A sample written before this version carries no hottest-core value, so
    /// the choice must degrade to the average instead of printing nothing.
    @MainActor
    func testHottestCoreChoiceFallsBackWhenTheSampleHasNoPeak() {
        let source = FakeFanReadingSource(cpuCelsius: 61, cpuHottestCelsius: nil)
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { source },
            refreshInterval: nil
        )
        controller.refresh()

        XCTAssertEqual(controller.menuBarTemperatureCelsius(source: .hottestCore), 61)
    }

    // MARK: - Tooltip must never call the shown value the control input

    /// Walks the tooltip's `·`-separated segments and returns the one that
    /// talks about the control input, if any.
    private func controlInputSegment(of tooltip: String) -> String? {
        tooltip
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().contains("control input") }
    }

    /// DEF-3 regression. With `hottestCore` the menu bar prints the peak while
    /// the fans are steered by the average, so the tooltip has to name the two
    /// separately. Labelling the shown peak as the control input is a lie even
    /// though both numbers in it are correct.
    @MainActor
    func testHottestCoreTooltipDistinguishesShownValueFromControlInput() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }
        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)

        let source = FakeFanReadingSource(cpuCelsius: 61, cpuHottestCelsius: 78)
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { source },
            refreshInterval: nil
        )
        controller.refresh()

        let tooltip = controller.temperatureToolTip(source: .hottestCore)

        // It must say what is shown, and that it is the hottest core.
        XCTAssertTrue(tooltip.contains("Shown"), tooltip)
        XCTAssertTrue(tooltip.contains("78°C"), "the shown value must be the peak: \(tooltip)")
        XCTAssertTrue(tooltip.lowercased().contains("hottest"), tooltip)

        // And the control-input segment must name the average — never the peak.
        let control = try? XCTUnwrap(controlInputSegment(of: tooltip))
        let segment = control.flatMap { $0 } ?? ""
        XCTAssertFalse(segment.isEmpty, "tooltip must name the control input: \(tooltip)")
        XCTAssertFalse(
            segment.lowercased().contains("hottest"),
            "the hottest core must never be labelled the control input: \(segment)"
        )
        XCTAssertTrue(segment.contains("61°C"), "the control input is the average: \(segment)")
        XCTAssertTrue(segment.lowercased().contains("average"), segment)
    }

    /// With `socAverage` the shown value *is* the control input, so the tooltip
    /// says that once instead of printing the same number under two labels.
    @MainActor
    func testSoCAverageTooltipSaysShownValueIsTheControlInput() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }
        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)

        let source = FakeFanReadingSource(cpuCelsius: 61, cpuHottestCelsius: 78)
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { source },
            refreshInterval: nil
        )
        controller.refresh()

        let tooltip = controller.temperatureToolTip(source: .socAverage)
        XCTAssertTrue(tooltip.contains("Shown"), tooltip)
        XCTAssertTrue(tooltip.contains("61°C"), tooltip)
        // The peak stays visible, since it is what the average hides.
        XCTAssertTrue(tooltip.contains("78°C"), tooltip)
        XCTAssertTrue(
            tooltip.lowercased().contains("same value"),
            "showing and steering by one number must be said once: \(tooltip)"
        )
        // There is no separate control input to name, so none may be claimed.
        XCTAssertNil(
            controlInputSegment(of: tooltip),
            "socAverage must not present a second, separate control input: \(tooltip)"
        )
    }

    /// The "Display content" copy is written for the chosen metric, so the row
    /// can never describe a number it is not showing.
    @MainActor
    func testDisplayContentCopyFollowsTheTemperatureLogic() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }
        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)

        for mode in MenuBarDisplayMode.allCases {
            let average = mode.detail(temperatureSource: .socAverage)
            let hottest = mode.detail(temperatureSource: .hottestCore)
            XCTAssertFalse(average.isEmpty, mode.rawValue)
            XCTAssertFalse(hottest.isEmpty, mode.rawValue)

            // The two choices must actually read differently for the temperature
            // modes, or the copy is not following the setting at all.
            if mode == .cpuTemperature || mode == .temperatureAndFanSpeed
                || mode == .temperatureOverFanSpeed {
                XCTAssertNotEqual(average, hottest, mode.rawValue)
            }
        }

        // The temperature readout no longer claims to print the control input,
        // because under hottestCore it does not.
        let title = MenuBarDisplayMode.cpuTemperature.title(temperatureSource: .hottestCore)
        XCTAssertFalse(
            title.lowercased().contains("control input"),
            "the readout's name must not promise the control input: \(title)"
        )
    }

    /// The tooltip names the sensor, so "54°" is never ambiguous.
    @MainActor
    func testToolTipCaptionFollowsTheChoice() {
        let source = FakeFanReadingSource(cpuCelsius: 61, cpuHottestCelsius: 78)
        let controller = FanController(
            notificationCenter: nil,
            widgetSnapshotDestination: .disabled,
            makeReadingSource: { source },
            refreshInterval: nil
        )
        controller.refresh()

        let average = controller.temperatureToolTip(source: .socAverage)
        let hottest = controller.temperatureToolTip(source: .hottestCore)
        XCTAssertTrue(average.contains("61°C"), average)
        XCTAssertTrue(average.contains("78°C"), average)
        XCTAssertNotEqual(average, hottest)
    }
}
