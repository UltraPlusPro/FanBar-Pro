import Foundation
import XCTest
@testable import FanBarShared

/// Ukrainian shipped before 1.1.9. This test verifies the gaps the request
/// asked us to check: it is selectable in the language picker (allCases), its
/// catalog is complete (every call site), and the preference plumbing resolves.
final class UkrainianCatalogTests: XCTestCase {
    func testUkrainianIsSelectableAndFullyCovered() throws {
        XCTAssertTrue(FanBarLanguage.allCases.contains(.ukrainian))
        XCTAssertEqual(FanBarLanguage.ukrainian.title, "Українська")
        XCTAssertEqual(FanBarLanguage.ukrainian.localizationIdentifier, "uk")

        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }
        UserDefaults.standard.set(FanBarLanguage.ukrainian.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .ukrainian)
        XCTAssertEqual(fanBarText("设置", "Settings"), UkrainianCatalog.text(for: "Settings"))

        let sites = try CatalogCallSites.scan()
        XCTAssertGreaterThan(sites.count, 200)
        for site in sites {
            XCTAssertNotNil(UkrainianCatalog.text(for: site.english),
                            "No Ukrainian for \"\(site.english)\" (\(site.location))")
        }
    }
}
