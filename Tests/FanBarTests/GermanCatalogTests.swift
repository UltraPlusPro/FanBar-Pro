import Foundation
import XCTest
@testable import FanBarShared

/// German (1.1.9) is a partial catalog: only high-frequency UI strings are
/// translated and a missing key falls back to English. These tests keep the
/// preference plumbing, live call sites, format specifiers and duplicate-key
/// hygiene honest without demanding full coverage.
final class GermanCatalogTests: XCTestCase {
    func testGermanPreferenceAndFallback() throws {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }

        UserDefaults.standard.set(FanBarLanguage.german.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .german)
        XCTAssertEqual(FanBarLanguage.german.title, "Deutsch")
        XCTAssertEqual(FanBarLanguage.german.localizationIdentifier, "de")
        // A translated high-frequency key resolves in German.
        XCTAssertEqual(fanBarText("任意中文", "General"), "Allgemein")
        // An uncovered format key falls back to English (documented behaviour).
        XCTAssertEqual(fanBarFormat("风扇 %d", "Fan %d", 2), "Fan 2")

        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(fanBarText("任意中文", "General"), "General")
    }

    func testEveryGermanEntryIsALiveCallSite() throws {
        let used = Set(try CatalogCallSites.scan().map(\.english))
        for key in GermanCatalog.strings.keys where !used.contains(key) {
            XCTFail("Catalog entry no longer used: \"\(key)\"")
        }
    }

    func testGermanFormatSpecifiersMatchEnglish() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            guard let translated = GermanCatalog.text(for: site.english) else { continue }
            XCTAssertEqual(
                try CatalogCallSites.specifiers(in: translated),
                try CatalogCallSites.specifiers(in: site.english),
                "German specifiers differ for \"\(site.english)\""
            )
        }
    }

    func testGermanHasNoRepeatedKeys() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FanBarShared")
        let text = try String(contentsOf: shared.appendingPathComponent("GermanCatalog.swift"), encoding: .utf8)
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix(","),
                  let range = trimmed.range(of: "\": \"") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<range.lowerBound])
            XCTAssertTrue(seen.insert(key).inserted, "GermanCatalog.swift repeats key \"\(key)\"")
        }
    }
}
