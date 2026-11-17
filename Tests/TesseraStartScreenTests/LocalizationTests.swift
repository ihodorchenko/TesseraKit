//
//  LocalizationTests.swift
//  TesseraStartScreenTests
//
//  Localization of the default `TesseraStartScreen` strings.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §9 "Accessibility"
//  (VoiceOver announcements with localized strings), "Implementation deviations".
//
//  What is checked:
//  - parity of the `Resources/en.lproj/Localizable.strings` and `ru.lproj` tables
//    (no key present in only one table; values are non-empty and differ from the key);
//  - every key of `TesseraStartScreenStrings.Key` exists in both tables and
//    resolves through the internal seam (`string(_:language:bundle:)`);
//  - ru/en resolution, a full tag (`ru-RU`), the base locale for an unsupported
//    language (`de` → en) and the system language;
//  - the ``TesseraAppsListTexts`` defaults are non-empty, match the table and
//    differ between en and ru where a translation is expected;
//  - a static scan of the sources: `Sources/TesseraStartScreen/*.swift`
//    contains no Cyrillic string literals (comments and doc examples do not count).
//

#if canImport(UIKit)

import Foundation
import XCTest
@testable import TesseraStartScreen

/// A source string literal found by the scanner.
private struct FoundLiteral {
    let value: String
    let line: Int
}

final class LocalizationTests: XCTestCase {

    // MARK: - Helpers

    /// Reads the `Localizable.strings` table of a specific language from the built
    /// module resource bundle (`Bundle.module`).
    ///
    /// It reads the actual file rather than going through the resolver: the test must
    /// see both tables regardless of the system language.
    private func table(
        for language: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: String] {
        let bundle = TesseraStartScreenStrings.bundle
        let url = try XCTUnwrap(
            bundle.resourceURL?
                .appendingPathComponent("\(language).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings", isDirectory: false),
            "The built bundle has no \(language).lproj/Localizable.strings",
            file: file,
            line: line
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(
            plist as? [String: String],
            "\(language).lproj/Localizable.strings cannot be read as a key-value table",
            file: file,
            line: line
        )
    }

    /// The `Sources/TesseraStartScreen` source directory.
    ///
    /// The path comes from `#filePath` (the absolute path at compile time):
    /// in the simulator runtime it points at the working tree. If the tree
    /// is unavailable (for example, a binary build without sources), the test
    /// is skipped rather than failing spuriously.
    private func sourcesDirectory(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("TesseraStartScreen", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sources.path) else {
            throw XCTSkip(
                "The static literal check did not find the sources (\(sources.path))",
                file: file,
                line: line
            )
        }
        return sources
    }

    // MARK: - Resources are packaged

    /// The resource bundle is exactly the module bundle, and it contains both localizations.
    func testResourceBundleContainsBothLocalizations() {
        let bundle = TesseraStartScreenStrings.bundle

        XCTAssertTrue(
            bundle.bundleURL.lastPathComponent.contains("TesseraStartScreen"),
            "Bundle.module must point at the module resource bundle: \(bundle.bundleURL)"
        )
        XCTAssertTrue(
            Set(bundle.localizations).isSuperset(of: ["en", "ru"]),
            "The bundle must contain the en and ru localizations: \(bundle.localizations)"
        )
        XCTAssertTrue(
            TesseraStartScreenStrings.supportedLanguages.isSubset(of: Set(bundle.localizations)),
            "Every supported language must have a table"
        )
    }

    // MARK: - Table parity

    /// The en/ru key sets are equal; every code key exists in both tables;
    /// values are non-empty and are not the raw key.
    func testTablesHaveSameKeysAndTranslationsForEveryCodeKey() throws {
        let english = try table(for: "en")
        let russian = try table(for: "ru")

        XCTAssertEqual(
            Set(english.keys),
            Set(russian.keys),
            "The en/ru keys diverge: only in en \(Set(english.keys).subtracting(russian.keys)), "
                + "only in ru \(Set(russian.keys).subtracting(english.keys))"
        )
        XCTAssertFalse(english.isEmpty, "The en table is empty")

        for key in TesseraStartScreenStrings.Key.allCases {
            let raw = key.rawValue
            let en = try XCTUnwrap(english[raw], "No key \(raw) in en.lproj")
            let ru = try XCTUnwrap(russian[raw], "No key \(raw) in ru.lproj")
            XCTAssertFalse(
                en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty en value for \(raw)"
            )
            XCTAssertFalse(
                ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Empty ru value for \(raw)"
            )
            XCTAssertNotEqual(en, raw, "The en value for \(raw) is not translated")
            XCTAssertNotEqual(ru, raw, "The ru value for \(raw) is not translated")
        }
    }

    /// Every code key resolves in both locales through the internal seam.
    func testEveryCodeKeyResolvesThroughSeamInBothLanguages() {
        for key in TesseraStartScreenStrings.Key.allCases {
            for language in ["en", "ru"] {
                let value = TesseraStartScreenStrings.string(key, language: language)
                XCTAssertNotEqual(
                    value,
                    key.rawValue,
                    "Key \(key.rawValue) not found in the \(language) table"
                )
                XCTAssertFalse(value.isEmpty, "Empty string \(key.rawValue) (\(language))")
            }
        }
    }

    // MARK: - Resolution

    /// An explicit locale through the seam: ru and en give different values.
    func testResolvesRussianAndEnglishThroughExplicitLanguageSeam() {
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.folderScreenDone, language: "ru"),
            "Готово"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.folderScreenDone, language: "en"),
            "Done"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.panelExpanded, language: "ru"),
            "раскрыта"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.panelExpanded, language: "en"),
            "expanded"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.a11yActionUnpin, language: "ru"),
            "Открепить"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.a11yActionUnpin, language: "en"),
            "Unpin"
        )
    }

    /// A full language tag and historical forms are mapped to the table code.
    func testFullLanguageTagResolvesToTable() {
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.folderScreenDone, language: "ru-RU"),
            "Готово"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.folderScreenDone, language: "ru_RU"),
            "Готово"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.folderScreenDone, language: "en-US"),
            "Done"
        )
    }

    /// A language without a table falls back to the base locale en, not to the key or an empty
    /// string (the "SPM localization" risk: an unknown user language).
    func testUnsupportedLanguageFallsBackToBaseLocalization() {
        for language in ["de", "de-DE", "fr", "zh-Hans"] {
            XCTAssertEqual(
                TesseraStartScreenStrings.string(.folderScreenDone, language: language),
                "Done",
                "Expected a fallback to the base locale en for \(language)"
            )
        }
        XCTAssertEqual(TesseraStartScreenStrings.baseLanguage, "en")
    }

    /// The system language resolves to one of the supported tables, and the default
    /// strings match an explicit resolution of that language.
    func testSystemLanguageResolvesToAvailableTable() {
        let language = TesseraStartScreenStrings.resolvedLanguage()

        XCTAssertTrue(
            TesseraStartScreenStrings.supportedLanguages.contains(language),
            "The system language \(language) has no table"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.a11yEditingEntered),
            TesseraStartScreenStrings.string(.a11yEditingEntered, language: language)
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.string(.folderScreenDone),
            TesseraStartScreenStrings.string(.folderScreenDone, language: language)
        )
    }

    // MARK: - Apps list defaults (AppsListPage)

    /// `TesseraAppsListTexts()` resolves to the system language table, all fields are
    /// non-empty, and an explicit host override still works.
    func testAppsListDefaultTextsAreLocalizedAndNonEmpty() {
        let defaults = TesseraAppsListTexts()
        let language = TesseraStartScreenStrings.resolvedLanguage()

        let fields: [(String, TesseraStartScreenStrings.Key)] = [
            (defaults.settingsSectionTitle, .appsListSettingsSectionTitle),
            (defaults.emptyTitle, .appsListEmptyTitle),
            (defaults.pinActionTitle, .appsListPinActionTitle),
            (defaults.unpinActionTitle, .appsListUnpinActionTitle),
            (defaults.pinnedValue, .appsListPinnedValue),
        ]
        for (value, key) in fields {
            XCTAssertFalse(value.isEmpty, "Empty default \(key.rawValue)")
            XCTAssertEqual(
                value,
                TesseraStartScreenStrings.string(key, language: language),
                "Default \(key.rawValue) does not match the \(language) table"
            )
        }

        let custom = TesseraAppsListTexts(settingsSectionTitle: "Host settings")
        XCTAssertEqual(custom.settingsSectionTitle, "Host settings")
        XCTAssertEqual(custom.emptyTitle, defaults.emptyTitle)
    }

    /// The defaults of the apps list that are expected to be translated differ between en and ru.
    func testAppsListDefaultTitlesDifferBetweenEnglishAndRussian() {
        let keys: [TesseraStartScreenStrings.Key] = [
            .appsListSettingsSectionTitle,
            .appsListEmptyTitle,
            .appsListPinActionTitle,
            .appsListUnpinActionTitle,
            .appsListPinnedValue,
        ]
        for key in keys {
            let en = TesseraStartScreenStrings.string(key, language: "en")
            let ru = TesseraStartScreenStrings.string(key, language: "ru")
            XCTAssertNotEqual(en, ru, "Default \(key.rawValue) is not translated: \(en)")
        }
    }

    // MARK: - Static literal check

    /// The component sources contain no Cyrillic string literals at all: user-facing
    /// text lives in the localization tables, developer-facing messages are in English.
    func testSourcesContainNoCyrillicStringLiterals() throws {
        let directory = try sourcesDirectory()
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(files.isEmpty, "No .swift files found in \(directory.path)")

        var findings: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SwiftSourceScanner.stringLiterals(in: source) {
                guard SwiftSourceScanner.containsCyrillic(literal.value) else { continue }
                findings.append(
                    "\(file.lastPathComponent):\(literal.line): \"\(literal.value)\""
                )
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "Cyrillic string literals found in sources: user-facing strings must "
                + "go through TesseraStartScreenStrings and the en/ru tables, "
                + "developer-facing messages must be in English:\n"
                + findings.joined(separator: "\n")
        )
    }

    // MARK: - Tile count declension

    /// Russian word forms of the folder screen subtitle: 1/2/5/11/21.
    ///
    /// The language is set explicitly: the test must not depend on the simulator locale.
    func testRussianTilesCountUsesPluralForms() {
        let language = "ru"
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(1, language: language),
            "1 ярлык"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(3, language: language),
            "3 ярлыка"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(5, language: language),
            "5 ярлыков"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(11, language: language),
            "11 ярлыков"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(21, language: language),
            "21 ярлык"
        )
    }

    /// English word forms of the subtitle: singular/plural.
    func testEnglishTilesCountUsesSingularAndPlural() {
        let language = "en"
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(1, language: language),
            "1 shortcut"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(2, language: language),
            "2 shortcuts"
        )
        XCTAssertEqual(
            TesseraStartScreenStrings.folderTilesCountText(11, language: language),
            "11 shortcuts"
        )
    }
}

// MARK: - String literal scanner

/// A minimal Swift source scanner: it drops comments (including
/// nested block comments) and collects the contents of string literals with line
/// numbers.
///
/// Interpolation (`\(...)`) stays part of the literal's contents: the static
/// check only cares whether the literal text contains Cyrillic, not the
/// interpolated expression. Nested literals inside an interpolation
/// are skipped by balancing parentheses, so they do not terminate the outer literal.
private enum SwiftSourceScanner {

    static func stringLiterals(in source: String) -> [FoundLiteral] {
        scan(source)
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    // MARK: Scanning

    private static func scan(_ source: String) -> [FoundLiteral] {
        let characters = Array(source)
        let count = characters.count
        var literals: [FoundLiteral] = []
        var index = 0
        var line = 1
        var state = State.code
        var blockCommentDepth = 0

        func characterAt(_ position: Int) -> Character? {
            guard position >= 0, position < count else { return nil }
            return characters[position]
        }

        func starts(with prefix: String, at offset: Int = 0) -> Bool {
            var position = index + offset
            for expected in prefix {
                guard position < count, characters[position] == expected else { return false }
                position += 1
            }
            return true
        }

        while index < count {
            let current = characters[index]

            switch state {
            case .code:
                if starts(with: "//") {
                    state = .lineComment
                    index += 2
                    continue
                }
                if starts(with: "/*") {
                    state = .blockComment
                    blockCommentDepth = 1
                    index += 2
                    continue
                }
                if starts(with: "\"\"\"") {
                    let startLine = line
                    index += 3
                    var value = ""
                    while index < count {
                        if starts(with: "\"\"\"") {
                            break
                        }
                        let character = characters[index]
                        if character == "\n" {
                            line += 1
                        }
                        if character == "\\" {
                            if let next = characterAt(index + 1) {
                                value.append(character)
                                value.append(next)
                                index += 2
                                continue
                            }
                        }
                        value.append(character)
                        index += 1
                    }
                    literals.append(FoundLiteral(value: value, line: startLine))
                    index += 3
                    continue
                }
                if current == "\"" {
                    let startLine = line
                    index += 1
                    var value = ""
                    while index < count {
                        let character = characters[index]
                        if character == "\\" {
                            guard let next = characterAt(index + 1) else {
                                break
                            }
                            if next == "(" {
                                // Interpolation stays part of the literal
                                // contents: the check cares whether the source text contains
                                // Cyrillic, not the interpolated code.
                                let end = skipInterpolation(
                                    characters: characters,
                                    from: index + 2
                                )
                                guard end > index else { break }
                                value.append(contentsOf: characters[index..<end])
                                index = end
                                continue
                            }
                            value.append(character)
                            value.append(next)
                            index += 2
                            continue
                        }
                        if character == "\"" {
                            break
                        }
                        if character == "\n" {
                            line += 1
                        }
                        value.append(character)
                        index += 1
                    }
                    literals.append(FoundLiteral(value: value, line: startLine))
                    index += 1
                    continue
                }
                if current == "\n" {
                    line += 1
                }
                index += 1

            case .lineComment:
                if current == "\n" {
                    line += 1
                    state = .code
                }
                index += 1

            case .blockComment:
                if starts(with: "*/") {
                    blockCommentDepth -= 1
                    index += 2
                    if blockCommentDepth == 0 {
                        state = .code
                    }
                    continue
                }
                if starts(with: "/*") {
                    blockCommentDepth += 1
                    index += 2
                    continue
                }
                if current == "\n" {
                    line += 1
                }
                index += 1
            }
        }

        return literals
    }

    // MARK: Interpolation

    /// Returns the index after the closing parenthesis of an interpolation `\(...)`.
    private static func skipInterpolation(
        characters: [Character],
        from start: Int
    ) -> Int {
        var index = start
        var depth = 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "\"" {
                // A nested string literal inside an interpolation.
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += 2
                        continue
                    }
                    if characters[index] == "\"" {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index + 1
                }
            }
            index += 1
        }
        return index
    }

    // MARK: Helpers

    private enum State {
        case code
        case lineComment
        case blockComment
    }

}

#endif
