import Foundation
import XCTest
@testable import FanBarShared

/// Romanian (1.1.9) is a partial catalog: only high-frequency UI strings are
/// translated and a missing key falls back to English. These tests keep the
/// preference plumbing, live call sites, format specifiers and duplicate-key
/// hygiene honest without demanding full coverage.
final class RomanianCatalogTests: XCTestCase {
    func testRomanianPreferenceAndFallback() throws {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }

        UserDefaults.standard.set(FanBarLanguage.romanian.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .romanian)
        XCTAssertEqual(FanBarLanguage.romanian.title, "Română")
        XCTAssertEqual(FanBarLanguage.romanian.localizationIdentifier, "ro")
        // A translated high-frequency key resolves in Romanian.
        XCTAssertEqual(fanBarText("任意中文", "General"), "General")
        // An uncovered format key falls back to English (documented behaviour).
        XCTAssertEqual(fanBarFormat("风扇 %d", "Fan %d", 2), "Fan 2")

        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(fanBarText("任意中文", "General"), "General")
    }

    func testEveryRomanianEntryIsALiveCallSite() throws {
        let used = Set(try CatalogCallSites.scan().map(\.english))
        for key in RomanianCatalog.strings.keys where !used.contains(key) {
            XCTFail("Catalog entry no longer used: \"\(key)\"")
        }
    }

    func testRomanianFormatSpecifiersMatchEnglish() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            guard let translated = RomanianCatalog.text(for: site.english) else { continue }
            XCTAssertEqual(
                try CatalogCallSites.specifiers(in: translated),
                try CatalogCallSites.specifiers(in: site.english),
                "Romanian specifiers differ for \"\(site.english)\""
            )
        }
    }

    func testRomanianHasNoRepeatedKeys() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FanBarShared")
        let text = try String(contentsOf: shared.appendingPathComponent("RomanianCatalog.swift"), encoding: .utf8)
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix(","),
                  let range = trimmed.range(of: "\": \"") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<range.lowerBound])
            XCTAssertTrue(seen.insert(key).inserted, "RomanianCatalog.swift repeats key \"\(key)\"")
        }
    }
}
