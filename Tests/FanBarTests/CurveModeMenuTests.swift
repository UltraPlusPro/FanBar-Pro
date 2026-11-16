import FanBarShared
import XCTest
@testable import FanBar

/// 1.1.11 意见2：`.curveTemperature` / `.curveRPM` 的第二个菜单栏图标，
/// 它的下拉菜单必须和主面板一样带「macOS」这一系统默认项。
///
/// 断言的是「菜单内容」本身（`CurveMode.allCases` 就是菜单的行来源），
/// 以及 macOS 项必须排在最前、必须真的有一套"交还"语义、其余档位不受影响。
final class CurveModeMenuTests: XCTestCase {
    func testSystemDefaultOpensTheMenu() {
        XCTAssertEqual(
            CurveMode.allCases.first, .systemDefault,
            "菜单第一行必须是 macOS，否则用户仍要先往下找"
        )
    }

    func testOnlyTheSystemDefaultEntryHandsFansBackToMacOS() {
        XCTAssertEqual(CurveMode.allCases.filter(\.returnsToSystemDefault), [.systemDefault])
        for mode in CurveMode.allCases where mode != .systemDefault {
            XCTAssertFalse(mode.returnsToSystemDefault, "\(mode.rawValue) 不应触发交还")
        }
        // A preset mapping would make `selectMode` take the preset branch and
        // never reach `setAutomatic()`.
        XCTAssertNil(CurveMode.systemDefault.builtInPreset)
    }

    func testSystemDefaultIsLabelledMacOS() {
        XCTAssertEqual(CurveMode.systemDefault.title.lowercased(), "macos")
        XCTAssertEqual(CurveMode.systemDefault.symbolName, "arrow.triangle.2.circlepath")
    }

    func testEveryGearKeepsItsOwnSymbol() {
        let symbols = CurveMode.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "图标重复会让档位难以区分")
        XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty })
    }

    func testEveryEntryHasATitleAndARoundTrippingRawValue() {
        for mode in CurveMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, "\(mode.rawValue) 没有标题")
            XCTAssertEqual(
                CurveMode(rawValue: mode.rawValue), mode,
                "菜单用 rawValue 回传，往返失败会让点击无效"
            )
        }
    }

    func testTheFourBuiltInPresetsStillMapOntoTheirPreset() {
        XCTAssertEqual(CurveMode.silent.builtInPreset, .silent)
        XCTAssertEqual(CurveMode.balanced.builtInPreset, .balanced)
        XCTAssertEqual(CurveMode.performance.builtInPreset, .performance)
        XCTAssertEqual(CurveMode.extreme.builtInPreset, .extreme)
        XCTAssertNil(CurveMode.fixed.builtInPreset)
        XCTAssertNil(CurveMode.custom.builtInPreset)
    }

    /// The menu used to show one separator plus "打开面板…"; with macOS added it
    /// must show two separators, so the system default stays visually apart.
    func testMenuGroupsSystemDefaultApartFromTheCurveGears() {
        let separatorsAfter = CurveMode.allCases.filter(\.returnsToSystemDefault).count
        XCTAssertEqual(separatorsAfter, 1, "macOS 与其后的曲线档位之间恰好一条分隔线")
    }
}
