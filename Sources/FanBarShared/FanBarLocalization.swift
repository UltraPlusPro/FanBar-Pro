import Foundation

/// User-selectable language for the menu-bar app and its helper messages.
public enum FanBarLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english
    case chinese
    case traditionalChinese
    case japanese
    case russian
    case french
    case korean
    case spanish
    case portuguese
    case ukrainian
    case finnish
    case vietnamese
    case tibetan
    case mongolian
    case romanian
    case german
    case hindi
    case malay

    public static let preferenceKey = "fanbar.language"
    public static let defaultValue = FanBarLanguage.system.rawValue

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .chinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .russian: "Русский"
        case .french: "Français"
        case .korean: "한국어"
        case .spanish: "Español"
        case .portuguese: "Português"
        case .ukrainian: "Українська"
        case .finnish: "Suomi"
        case .vietnamese: "Tiếng Việt"
        case .tibetan: "བོད་སྐད"
        case .mongolian: "Монгол"
        case .romanian: "Română"
        case .german: "Deutsch"
        case .hindi: "हिन्दी"
        case .malay: "Bahasa Melayu"
        }
    }

    /// The `.lproj` name used by bundle resources such as the widget's strings.
    public var localizationIdentifier: String {
        switch self {
        case .english: "en"
        case .chinese, .system: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .japanese: "ja"
        case .russian: "ru"
        case .french: "fr"
        case .korean: "ko"
        case .spanish: "es"
        case .portuguese: "pt"
        case .ukrainian: "uk"
        case .finnish: "fi"
        case .vietnamese: "vi"
        case .tibetan: "bo"
        case .mongolian: "mn"
        case .romanian: "ro"
        case .german: "de"
        case .hindi: "hi"
        case .malay: "ms"
        }
    }

    /// Resolve the system option at lookup time so a preference change is
    /// reflected without rebuilding or replacing the app bundle.
    public static var current: FanBarLanguage {
        if let rawValue = UserDefaults.standard.string(forKey: preferenceKey),
           let stored = FanBarLanguage(rawValue: rawValue),
           stored != .system {
            return stored
        }

        let languageCode = Locale.current.languageCode?.lowercased() ?? "en"
        if languageCode == "ja" || preferredLanguageCode == "ja" { return .japanese }
        if languageCode == "ru" || preferredLanguageCode == "ru" { return .russian }
        if languageCode == "fr" || preferredLanguageCode == "fr" { return .french }
        if languageCode == "ko" || preferredLanguageCode == "ko" { return .korean }
        if languageCode == "es" || preferredLanguageCode == "es" { return .spanish }
        if languageCode == "pt" || preferredLanguageCode == "pt" { return .portuguese }
        if languageCode == "uk" || preferredLanguageCode == "uk" { return .ukrainian }
        if languageCode == "fi" || preferredLanguageCode == "fi" { return .finnish }
        if languageCode == "vi" || preferredLanguageCode == "vi" { return .vietnamese }
        if languageCode == "bo" || preferredLanguageCode == "bo" { return .tibetan }
        if languageCode == "mn" || preferredLanguageCode == "mn" { return .mongolian }
        if languageCode == "ro" || preferredLanguageCode == "ro" { return .romanian }
        if languageCode == "de" || preferredLanguageCode == "de" { return .german }
        if languageCode == "hi" || preferredLanguageCode == "hi" { return .hindi }
        if languageCode == "ms" || preferredLanguageCode == "ms" { return .malay }
        guard languageCode.hasPrefix("zh") else { return .english }
        return prefersTraditionalScript ? .traditionalChinese : .chinese
    }

    private static var preferredLanguageCode: String? {
        Locale.preferredLanguages.first?.lowercased().components(separatedBy: "-").first
    }

    /// FanBar ships no `.lproj` for the app itself, so `Locale.current` may
    /// carry only a region; the preferred-language list keeps the script
    /// (`zh-Hant-TW`) or at least the region (`zh-HK`) the user picked.
    private static var prefersTraditionalScript: Bool {
        if Locale.current.scriptCode == "Hant" { return true }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        guard preferred.hasPrefix("zh") else { return false }
        if preferred.contains("hant") { return true }
        if preferred.contains("hans") { return false }
        return ["-tw", "-hk", "-mo"].contains { preferred.hasSuffix($0) }
    }

    public var isEnglish: Bool { self == .english }

    public var locale: Locale {
        let language = self == .system ? Self.current : self
        return Locale(identifier: language.localizationIdentifier)
    }
}

/// Chinese-only copy for the support/tip window (1.1.9). The tip window is not
/// localised into English/Japanese/etc. on purpose: it shows Simplified Chinese,
/// Traditional Chinese when the resolved interface language is Traditional
/// Chinese, and Simplified Chinese for every other language. `current` resolves
/// the `.system` option at lookup time, so a preference change needs no restart.
@inline(__always)
public func fanBarTipChinese(_ simplified: String) -> String {
    switch FanBarLanguage.current {
    case .traditionalChinese:
        return TraditionalChineseConverter.shared.convert(simplified)
    default:
        return simplified
    }
}

/// Reads the current preference at lookup time. SwiftUI callers must also
/// observe `FanBarLanguage.preferenceKey` with AppStorage and read it in body;
/// a parent's redraw alone does not invalidate an unchanged child view.
///
/// `chineseOnly` restricts copy to Simplified/Traditional Chinese for the tip
/// window; the English argument is still passed so the catalog call-site scan
/// keeps recording the key, but is intentionally ignored at runtime in that mode.
@inline(__always)
public func fanBarText(_ chinese: String, _ english: String, chineseOnly: Bool = false) -> String {
    if chineseOnly { return fanBarTipChinese(chinese) }
    return localized(chinese, english, for: FanBarLanguage.current)
}

@inline(__always)
public func fanBarFormat(
    _ chinese: String,
    _ english: String,
    _ arguments: CVarArg...,
    chineseOnly: Bool = false
) -> String {
    let template = chineseOnly
        ? fanBarTipChinese(chinese)
        : localized(chinese, english, for: FanBarLanguage.current)
    return String(format: template, arguments: arguments)
}

private func localized(
    _ chinese: String,
    _ english: String,
    for language: FanBarLanguage
) -> String {
    switch language {
    case .english: english
    case .traditionalChinese: TraditionalChineseConverter.shared.convert(chinese)
    // An entry missing from the catalog reads in English rather than as a key;
    // The catalog tests keep that from shipping.
    case .japanese: JapaneseCatalog.text(for: english) ?? english
    case .russian: RussianCatalog.text(for: english) ?? english
    case .french: FrenchCatalog.text(for: english) ?? english
    case .korean: KoreanCatalog.text(for: english) ?? english
    case .spanish: SpanishCatalog.text(for: english) ?? english
    case .portuguese: PortugueseCatalog.text(for: english) ?? english
    case .ukrainian: UkrainianCatalog.text(for: english) ?? english
    case .finnish: FinnishCatalog.text(for: english) ?? english
    case .vietnamese: VietnameseCatalog.text(for: english) ?? english
    case .tibetan: TibetanCatalog.text(for: english) ?? english
    case .mongolian: MongolianCatalog.text(for: english) ?? english
    case .romanian: RomanianCatalog.text(for: english) ?? english
    case .german: GermanCatalog.text(for: english) ?? english
    case .hindi: HindiCatalog.text(for: english) ?? english
    case .malay: MalayCatalog.text(for: english) ?? english
    case .chinese, .system: chinese
    }
}

/// Derives Traditional Chinese copy from the Simplified source strings so the
/// call sites keep a single Chinese literal. ICU's `Hans-Hant` transform only
/// maps characters, so a Taiwan-usage pass then swaps mainland terms for the
/// ones macOS itself uses in zh-Hant (設定, 選單列, 登入項目…).
final class TraditionalChineseConverter: @unchecked Sendable {
    static let shared = TraditionalChineseConverter()

    private let lock = NSLock()
    private var cache: [String: String] = [:]

    /// Applied in order after the character transform, so longer phrases
    /// must precede the shorter terms they contain.
    private static let vocabulary: [(String, String)] = [
        ("登錄項與擴展", "登入項目與延伸功能"),
        ("登錄項", "登入項目"),
        ("登錄", "登入"),
        ("系統設置", "系統設定"),
        ("設置", "設定"),
        ("菜單欄", "選單列"),
        ("菜單", "選單"),
        // ICU keeps 里 (village) for the locative 里; fix it only after the
        // nouns FanBar puts it behind, so a future 公里 stays intact.
        ("列里", "列裡"),
        ("單里", "單裡"),
        ("板里", "板裡"),
        ("在程序塢中", "在 Dock 中"),
        ("用於訪達、", "用於 Finder、"),
        ("啓動台", "啟動台"),
        ("程序", "程式"),
        ("重啓", "重新啟動"),
        ("啓", "啟"),
        // 预设 (preset) also becomes 預設, so keep the default curve distinct.
        ("預設的默認", "預設的初始"),
        ("默認", "預設"),
        ("當前", "目前"),
        ("自定義", "自訂"),
        ("界面", "介面"),
        ("圖標", "圖像"),
        ("實時", "即時"),
        ("數據", "資料"),
        ("硬盤", "硬碟"),
        ("硬件", "硬體"),
        ("傳感器", "感測器"),
        ("屏幕", "螢幕"),
        ("倉庫", "儲存庫"),
        ("保存", "儲存"),
        ("運行", "執行"),
        ("支持", "支援"),
        ("撤銷", "還原"),
        ("返回了", "傳回了"),
        ("響應", "回應"),
        ("超時", "逾時"),
        ("檢測到", "偵測到"),
        ("拖動", "拖移"),
        ("智能", "智慧"),
        ("性能", "效能"),
        ("高級", "進階"),
        ("通用", "一般"),
        ("“", "「"),
        ("”", "」"),
    ]

    func convert(_ simplified: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[simplified] { return cached }

        var result = simplified.applyingTransform(
            StringTransform("Hans-Hant"),
            reverse: false
        ) ?? simplified
        for (mainland, taiwan) in Self.vocabulary {
            result = result.replacingOccurrences(of: mainland, with: taiwan)
        }
        cache[simplified] = result
        return result
    }
}
