import Foundation
import XCTest
@testable import FanBarShared

/// Coverage and format-specifier guard for the catalogs that have no test file
/// of their own. Ukrainian and Vietnamese both shipped with mistyped
/// specifiers (`%,0f`, `.0f%%`), which `String(format:)` renders as garbage;
/// one shared guard keeps every shipped language honest without a new file per
/// language.
final class CatalogFormatCoverageTests: XCTestCase {
    /// Every shipped catalog, named as the language it serves.
    private var catalogs: [(language: FanBarLanguage, text: (String) -> String?)] {
        [
            (.russian, RussianCatalog.text(for:)),
            (.japanese, JapaneseCatalog.text(for:)),
            (.french, FrenchCatalog.text(for:)),
            (.korean, KoreanCatalog.text(for:)),
            (.spanish, SpanishCatalog.text(for:)),
            (.portuguese, PortugueseCatalog.text(for:)),
            (.ukrainian, UkrainianCatalog.text(for:)),
            (.finnish, FinnishCatalog.text(for:)),
            (.vietnamese, VietnameseCatalog.text(for:)),
            (.tibetan, TibetanCatalog.text(for:)),
            (.mongolian, MongolianCatalog.text(for:)),
        ]
    }

    func testEveryCatalogCoversEveryCallSite() throws {
        let sites = try CatalogCallSites.scan()
        XCTAssertGreaterThan(sites.count, 200, "call-site scan found too little; check the pattern")
        for catalog in catalogs {
            for site in sites where catalog.text(site.english) == nil {
                XCTFail("No \(catalog.language.rawValue) for \"\(site.english)\" (\(site.location))")
            }
        }
    }

    /// The single most dangerous catalog bug: a translated `fanBarFormat`
    /// template whose specifiers do not match the English one positionally.
    func testEveryCatalogFormatsWithTheSameSpecifiers() throws {
        for site in try CatalogCallSites.scan() where site.isFormat {
            let expected = try CatalogCallSites.specifiers(in: site.english)
            for catalog in catalogs {
                guard let translated = catalog.text(site.english) else { continue }
                XCTAssertEqual(
                    try CatalogCallSites.specifiers(in: translated), expected,
                    "\(catalog.language.rawValue) specifiers differ for \"\(site.english)\" (\(site.location))"
                )
            }
        }
    }

    /// Two identical keys in one dictionary literal do not fail to build: Swift
    /// keeps the last one and, for a literal this size, traps at runtime. A
    /// generator that appends without de-duplicating produces exactly that, so
    /// the source text is checked rather than the resulting dictionary.
    func testNoCatalogRepeatsAKey() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FanBarShared")
        let catalogs = [
            "Finnish", "French", "Japanese", "Korean", "Portuguese", "Russian",
            "Spanish", "Ukrainian", "Vietnamese", "Tibetan", "Mongolian",
            // 1.1.9: partial catalogs are checked for duplicate keys here too.
            "Romanian", "German", "Hindi", "Malay",
        ]
        for name in catalogs {
            let path = shared.appendingPathComponent("\(name)Catalog.swift")
            let text = try String(contentsOf: path, encoding: .utf8)
            var seen = Set<String>()
            var repeated: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""), trimmed.hasSuffix(","),
                      let range = trimmed.range(of: "\": \"") else { continue }
                let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<range.lowerBound])
                if !seen.insert(key).inserted { repeated.append(key) }
            }
            XCTAssertTrue(
                repeated.isEmpty,
                "\(name)Catalog.swift repeats \(repeated.count) keys: \(Array(Set(repeated)).sorted().prefix(5))"
            )
        }
    }

    /// In a `fanBarFormat` template every `%` is read by `String(format:)`, so
    /// one that is not a complete specifier consumes arguments unexpectedly or
    /// prints garbage. `fanBarText` strings are never formatted, so a literal
    /// "0%" there is correct and is not checked.
    func testFormatTemplatesHaveOnlyCompleteSpecifiers() throws {
        for catalog in catalogs {
            for site in try CatalogCallSites.scan() where site.isFormat {
                guard let value = catalog.text(site.english) else { continue }
                let consumed = try CatalogCallSites.specifiers(in: value).joined().filter { $0 == "%" }.count
                XCTAssertEqual(
                    consumed,
                    value.filter { $0 == "%" }.count,
                    "\(catalog.language.rawValue) has an incomplete specifier in \"\(value)\" (\(site.english))"
                )
            }
        }
    }
}
