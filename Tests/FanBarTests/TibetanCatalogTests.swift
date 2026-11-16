import Foundation
import XCTest
@testable import FanBarShared

/// Keeps the Tibetan catalog in step with the `fanBarText` / `fanBarFormat`
/// call sites, which are the only source of UI copy.
final class TibetanCatalogTests: XCTestCase {
    func testTibetanPreferenceUpdatesTextAndFormats() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }

        UserDefaults.standard.set(FanBarLanguage.tibetan.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .tibetan)
        XCTAssertEqual(FanBarLanguage.tibetan.title, "བོད་སྐད")
        XCTAssertEqual(FanBarLanguage.tibetan.localizationIdentifier, "bo")
        XCTAssertEqual(fanBarText("设置", "Settings"), "སྒྲིག་བཀོད།")
        XCTAssertEqual(fanBarFormat("风扇 %d", "Fan %d", 2), "རླུང་འཁོར་ 2")

        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(fanBarText("设置", "Settings"), "Settings")
    }

    func testEveryCallSiteHasTibetan() throws {
        let sites = try CatalogCallSites.scan()
        XCTAssertGreaterThan(sites.count, 200, "call-site scan found too little; check the pattern")
        for site in sites where TibetanCatalog.text(for: site.english) == nil {
            XCTFail("No Tibetan for \"\(site.english)\" (\(site.location))")
        }
    }

    func testCatalogHasNoStaleEntries() throws {
        let used = Set(try CatalogCallSites.scan().map(\.english))
        for key in TibetanCatalog.strings.keys where !used.contains(key) {
            XCTFail("Catalog entry no longer used: \"\(key)\"")
        }
    }

    func testFormatSpecifiersMatchEnglish() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            guard let translated = TibetanCatalog.text(for: site.english) else { continue }
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
                guard let value = TibetanCatalog.text(for: key) else { return false }
                return value == key && key.rangeOfCharacter(from: .letters) != nil
            }
        XCTAssertLessThan(
            untranslated.count, 40,
            "Tibetan still falls back to English for \(untranslated.count) keys: \(untranslated.sorted())"
        )
    }
}
