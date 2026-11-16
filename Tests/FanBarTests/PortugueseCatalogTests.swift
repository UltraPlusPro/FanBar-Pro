import Foundation
import XCTest
@testable import FanBarShared

/// The Portuguese catalog shipped without a test, so mistyped format
/// specifiers (`%,0f` instead of `%.0f`) reached the UI and made
/// `String(format:)` print garbage or trap. This is the same coverage,
/// stale-entry and specifier guard the other catalogs already have.
final class PortugueseCatalogTests: XCTestCase {
    func testPortuguesePreferenceUpdatesTextAndFormats() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }

        UserDefaults.standard.set(FanBarLanguage.portuguese.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .portuguese)
        XCTAssertEqual(FanBarLanguage.portuguese.title, "Português")
        XCTAssertEqual(FanBarLanguage.portuguese.localizationIdentifier, "pt")
        XCTAssertEqual(fanBarText("设置", "Settings"), "Configurações")
        XCTAssertEqual(fanBarFormat("风扇 %d", "Fan %d", 2), "Fã 2")

        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(fanBarText("设置", "Settings"), "Settings")
    }

    func testEveryCallSiteHasPortuguese() throws {
        let sites = try CatalogCallSites.scan()
        XCTAssertGreaterThan(sites.count, 200, "call-site scan found too little; check the pattern")
        for site in sites where PortugueseCatalog.text(for: site.english) == nil {
            XCTFail("No Portuguese for \"\(site.english)\" (\(site.location))")
        }
    }

    func testCatalogHasNoStaleEntries() throws {
        let used = Set(try CatalogCallSites.scan().map(\.english))
        for key in PortugueseCatalog.strings.keys where !used.contains(key) {
            XCTFail("Catalog entry no longer used: \"\(key)\"")
        }
    }

    func testFormatSpecifiersMatchEnglish() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            guard let translated = PortugueseCatalog.text(for: site.english) else { continue }
            XCTAssertEqual(
                try CatalogCallSites.specifiers(in: translated), try CatalogCallSites.specifiers(in: site.english),
                "Specifiers differ for \"\(site.english)\" (\(site.location))"
            )
        }
    }
}
