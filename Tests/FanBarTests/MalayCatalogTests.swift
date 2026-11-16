import Foundation
import XCTest
@testable import FanBarShared

/// Malay (1.1.9) is a partial catalog: only high-frequency UI strings are
/// translated and a missing key falls back to English. These tests keep the
/// preference plumbing, live call sites, format specifiers and duplicate-key
/// hygiene honest without demanding full coverage.
final class MalayCatalogTests: XCTestCase {
    func testMalayPreferenceAndFallback() throws {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }

        UserDefaults.standard.set(FanBarLanguage.malay.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(FanBarLanguage.current, .malay)
        XCTAssertEqual(FanBarLanguage.malay.title, "Bahasa Melayu")
        XCTAssertEqual(FanBarLanguage.malay.localizationIdentifier, "ms")
        // A translated high-frequency key resolves in Malay.
        XCTAssertEqual(fanBarText("任意中文", "General"), "Umum")
        // An uncovered format key falls back to English (documented behaviour).
        XCTAssertEqual(fanBarFormat("风扇 %d", "Fan %d", 2), "Fan 2")

        UserDefaults.standard.set(FanBarLanguage.english.rawValue, forKey: FanBarLanguage.preferenceKey)
        XCTAssertEqual(fanBarText("任意中文", "General"), "General")
    }

    func testEveryMalayEntryIsALiveCallSite() throws {
        let used = Set(try CatalogCallSites.scan().map(\.english))
        for key in MalayCatalog.strings.keys where !used.contains(key) {
            XCTFail("Catalog entry no longer used: \"\(key)\"")
        }
    }

    func testMalayFormatSpecifiersMatchEnglish() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            guard let translated = MalayCatalog.text(for: site.english) else { continue }
            XCTAssertEqual(
                try CatalogCallSites.specifiers(in: translated),
                try CatalogCallSites.specifiers(in: site.english),
                "Malay specifiers differ for \"\(site.english)\""
            )
        }
    }

    func testMalayHasNoRepeatedKeys() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FanBarShared")
        let text = try String(contentsOf: shared.appendingPathComponent("MalayCatalog.swift"), encoding: .utf8)
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix(","),
                  let range = trimmed.range(of: "\": \"") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<range.lowerBound])
            XCTAssertTrue(seen.insert(key).inserted, "MalayCatalog.swift repeats key \"\(key)\"")
        }
    }
}
