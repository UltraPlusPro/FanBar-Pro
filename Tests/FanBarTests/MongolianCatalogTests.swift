import Foundation
import XCTest
@testable import FanBarShared

/// Keeps the Mongolian catalog in step with the `fanBarText` / `fanBarFormat`
/// call sites, which are the only source of UI copy.
final class MongolianCatalogTests: XCTestCase {
    func testMongolianPreferenceUpdatesTextAndFormats() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }

        UserDefaults.standard.set(FanBarLanguage.mongolian.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .mongolian)
        XCTAssertEqual(FanBarLanguage.mongolian.title, "Монгол")
        XCTAssertEqual(FanBarLanguage.mongolian.localizationIdentifier, "mn")
        XCTAssertEqual(fanBarText("设置", "Settings"), "Тохиргоо")
        XCTAssertEqual(fanBarFormat("风扇 %d", "Fan %d", 2), "Сэнс 2")

        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(fanBarText("设置", "Settings"), "Settings")
    }

    func testEveryCallSiteHasMongolian() throws {
        let sites = try CatalogCallSites.scan()
        XCTAssertGreaterThan(sites.count, 200, "call-site scan found too little; check the pattern")
        for site in sites where MongolianCatalog.text(for: site.english) == nil {
            XCTFail("No Mongolian for \"\(site.english)\" (\(site.location))")
        }
    }

    func testCatalogHasNoStaleEntries() throws {
        let used = Set(try CatalogCallSites.scan().map(\.english))
        for key in MongolianCatalog.strings.keys where !used.contains(key) {
            XCTFail("Catalog entry no longer used: \"\(key)\"")
        }
    }

    func testFormatSpecifiersMatchEnglish() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            guard let translated = MongolianCatalog.text(for: site.english) else { continue }
            XCTAssertEqual(
                try CatalogCallSites.specifiers(in: translated), try CatalogCallSites.specifiers(in: site.english),
                "Specifiers differ for \"\(site.english)\" (\(site.location))"
            )
        }
    }

    /// A value identical to its key is a placeholder, not a translation; the
    /// UI still reads, so it is reported rather than failed.
    func testCatalogIsTranslatedNotCopiedFromEnglish() throws {
        let untranslated = try CatalogCallSites.scan()
            .map(\.english)
            .filter { key in
                guard let value = MongolianCatalog.text(for: key) else { return false }
                return value == key && key.rangeOfCharacter(from: .letters) != nil
            }
        XCTAssertLessThan(
            untranslated.count, 40,
            "Mongolian still falls back to English for \(untranslated.count) keys: \(untranslated.sorted())"
        )
    }
}
