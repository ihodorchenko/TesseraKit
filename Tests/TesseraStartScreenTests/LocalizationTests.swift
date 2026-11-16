//
//  LocalizationTests.swift
//  TesseraStartScreenTests
//
//  E9.8г (W5): локализация строк по умолчанию `TesseraStartScreen`.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §9 «Accessibility»
//  (озвучивание VoiceOver локализованными строками), «Отступления реализации».
//
//  Проверяется:
//  - паритет таблиц `Resources/en.lproj/Localizable.strings` и `ru.lproj`
//    (нет ключа только в одной таблице; значения непустые и не равны ключу);
//  - каждый ключ из `TesseraStartScreenStrings.Key` есть в обеих таблицах и
//    резолвится через internal-шов (`string(_:language:bundle:)`);
//  - резолв ru/en, полный тег (`ru-RU`), базовая локаль для неподдержанного
//    языка (`de` → en) и системный язык;
//  - дефолты ``TesseraAppsListTexts`` непустые, совпадают с таблицей и
//    различаются в en/ru там, где ожидается перевод;
//  - статическая проверка исходников: в `Sources/TesseraStartScreen/*.swift`
//    не осталось кириллических string-литералов вне allowlist
//    developer-facing строк (комментарии и doc-примеры не считаются).
//

#if canImport(UIKit)

import Foundation
import XCTest
@testable import TesseraStartScreen

/// Строковый литерал исходника, найденный сканером.
private struct FoundLiteral {
    let value: String
    let line: Int
}

final class LocalizationTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Developer-facing кириллические строки, которым локализация не нужна.
    ///
    /// Это не user-facing текст: диагностика для разработчика/хоста, сообщение
    /// компилятору или DEBUG-only assertion. Всё, что видит пользователь,
    /// должно идти через `TesseraStartScreenStrings` (ключи таблиц en/ru).
    private static let developerFacingAllowlist: Set<String> = [
        // TesseraTileStore: описание ошибки для логов/диагностики хоста
        // (`CustomStringConvertible`), в UI не показывается.
        "TesseraTileStore: неподдерживаемая версия схемы \\(version)",
        // LiveTileEngine: precondition программиста, сообщение для отладки.
        "upperBound должен быть положительным",
        // TesseraStartScreenView: `@available(*, deprecated, message:)` — сообщение
        // компилятору и интегратору, а не пользователю.
        "Переходы страниц приходят через TesseraStartScreenViewController.delegate",
        // TileEditCoordinator: DEBUG-assertion контракта хоста (E10.5-B1);
        // собирается из трёх литералов, ни один не показывается пользователю.
        "TesseraTileEditCoordinator.startDrag: снимок сетки не совпадает ",
        "с моделью TesseraTileStore на захвате — drag не начнётся. ",
        "Хост обязан применять снимки store к сетке (E10.5-B1).",
        // AppsListPage: fatalError для неверного способа создания
        // контроллера/кнопки — programmer error, не UI.
        "TesseraAppsListPageViewController создаётся через make(store:settings:texts:columns:)",
        "TesseraAppsListPinButton создаётся только программно",
    ]

    /// Читает таблицу `Localizable.strings` конкретного языка из собранного
    /// ресурсного бандла модуля (`Bundle.module`).
    ///
    /// Чтение идёт по фактическому файлу, а не через резолвер: тест должен
    /// видеть обе таблицы независимо от языка системы.
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
            "В собранном бандле нет \(language).lproj/Localizable.strings",
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
            "\(language).lproj/Localizable.strings не читается как таблица ключ-значение",
            file: file,
            line: line
        )
    }

    /// Каталог исходников `Sources/TesseraStartScreen`.
    ///
    /// Путь берётся из `#filePath` (абсолютный путь на момент компиляции):
    /// в рантайме симулятора он указывает на рабочее дерево. Если дерево
    /// недоступно (например, бинарная сборка без исходников), тест
    /// пропускается, а не падает ложно.
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
                "Статическая проверка литералов не нашла исходники (\(sources.path))",
                file: file,
                line: line
            )
        }
        return sources
    }

    // MARK: - Ресурсы упакованы

    /// Ресурсный бандл — именно бандл модуля, и в нём обе локализации.
    func testResourceBundleContainsBothLocalizations() {
        let bundle = TesseraStartScreenStrings.bundle

        XCTAssertTrue(
            bundle.bundleURL.lastPathComponent.contains("TesseraStartScreen"),
            "Bundle.module должен указывать на ресурсный бандл модуля: \(bundle.bundleURL)"
        )
        XCTAssertTrue(
            Set(bundle.localizations).isSuperset(of: ["en", "ru"]),
            "В бандле должны быть локализации en и ru: \(bundle.localizations)"
        )
        XCTAssertTrue(
            TesseraStartScreenStrings.supportedLanguages.isSubset(of: Set(bundle.localizations)),
            "Каждый поддержанный язык обязан иметь таблицу"
        )
    }

    // MARK: - Паритет таблиц

    /// Наборы ключей en/ru совпадают; каждый ключ кода есть в обеих таблицах;
    /// значения непустые и не являются сырым ключом.
    func testTablesHaveSameKeysAndTranslationsForEveryCodeKey() throws {
        let english = try table(for: "en")
        let russian = try table(for: "ru")

        XCTAssertEqual(
            Set(english.keys),
            Set(russian.keys),
            "Ключи en/ru расходятся: только в en \(Set(english.keys).subtracting(russian.keys)), "
                + "только в ru \(Set(russian.keys).subtracting(english.keys))"
        )
        XCTAssertFalse(english.isEmpty, "Таблица en пуста")

        for key in TesseraStartScreenStrings.Key.allCases {
            let raw = key.rawValue
            let en = try XCTUnwrap(english[raw], "Нет ключа \(raw) в en.lproj")
            let ru = try XCTUnwrap(russian[raw], "Нет ключа \(raw) в ru.lproj")
            XCTAssertFalse(
                en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Пустое значение en для \(raw)"
            )
            XCTAssertFalse(
                ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Пустое значение ru для \(raw)"
            )
            XCTAssertNotEqual(en, raw, "Значение en для \(raw) не переведено")
            XCTAssertNotEqual(ru, raw, "Значение ru для \(raw) не переведено")
        }
    }

    /// Каждый ключ кода резолвится в обеих локалях через internal-шов.
    func testEveryCodeKeyResolvesThroughSeamInBothLanguages() {
        for key in TesseraStartScreenStrings.Key.allCases {
            for language in ["en", "ru"] {
                let value = TesseraStartScreenStrings.string(key, language: language)
                XCTAssertNotEqual(
                    value,
                    key.rawValue,
                    "Ключ \(key.rawValue) не найден в таблице \(language)"
                )
                XCTAssertFalse(value.isEmpty, "Пустая строка \(key.rawValue) (\(language))")
            }
        }
    }

    // MARK: - Резолв

    /// Явная локаль через шов: ru и en дают разные значения.
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

    /// Полный тег языка и исторические формы приводятся к коду таблицы.
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

    /// Язык без таблицы откатывается к базовой локали en, а не к ключу/пустой
    /// строке (риск «локализация в SPM»: неизвестный язык у пользователя).
    func testUnsupportedLanguageFallsBackToBaseLocalization() {
        for language in ["de", "de-DE", "fr", "zh-Hans"] {
            XCTAssertEqual(
                TesseraStartScreenStrings.string(.folderScreenDone, language: language),
                "Done",
                "Для \(language) ожидался fallback на базовую локаль en"
            )
        }
        XCTAssertEqual(TesseraStartScreenStrings.baseLanguage, "en")
    }

    /// Язык системы резолвится в одну из поддержанных таблиц, и строки по
    /// умолчанию совпадает с явным резолвом этого языка.
    func testSystemLanguageResolvesToAvailableTable() {
        let language = TesseraStartScreenStrings.resolvedLanguage()

        XCTAssertTrue(
            TesseraStartScreenStrings.supportedLanguages.contains(language),
            "Системный язык \(language) не имеет таблицы"
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

    // MARK: - Дефолты списка приложений (AppsListPage)

    /// `TesseraAppsListTexts()` резолвится в таблицу языка системы, все поля
    /// непустые, а явная замена хоста по-прежнему работает.
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
            XCTAssertFalse(value.isEmpty, "Пустой дефолт \(key.rawValue)")
            XCTAssertEqual(
                value,
                TesseraStartScreenStrings.string(key, language: language),
                "Дефолт \(key.rawValue) не совпадает с таблицей \(language)"
            )
        }

        let custom = TesseraAppsListTexts(settingsSectionTitle: "Host settings")
        XCTAssertEqual(custom.settingsSectionTitle, "Host settings")
        XCTAssertEqual(custom.emptyTitle, defaults.emptyTitle)
    }

    /// Ожидаемо переводимые дефолты списка различаются в en и ru.
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
            XCTAssertNotEqual(en, ru, "Дефолт \(key.rawValue) не переведён: \(en)")
        }
    }

    // MARK: - Статическая проверка литералов

    /// В исходниках компонента не осталось кириллических string-литералов вне
    /// allowlist developer-facing строк.
    func testSourcesContainNoCyrillicStringLiteralsOutsideAllowlist() throws {
        let directory = try sourcesDirectory()
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(files.isEmpty, "Не найдено ни одного .swift в \(directory.path)")

        var findings: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SwiftSourceScanner.stringLiterals(in: source) {
                guard SwiftSourceScanner.containsCyrillic(literal.value) else { continue }
                guard !Self.developerFacingAllowlist.contains(literal.value) else { continue }
                findings.append(
                    "\(file.lastPathComponent):\(literal.line): \"\(literal.value)\""
                )
            }
        }

        XCTAssertTrue(
            findings.isEmpty,
            "Кириллические литералы вне allowlist: пользовательские строки должны "
                + "идти через TesseraStartScreenStrings и таблицы en/ru (E9.8г):\n"
                + findings.joined(separator: "\n")
        )
    }

    // MARK: - Склонение числа ярлыков

    /// Русские словоформы подзаголовка экрана папки: 1/2/5/11/21.
    ///
    /// Язык задаётся явно: тест не должен зависеть от локали симулятора.
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

    /// Английские словоформы подзаголовка: одна/множественная.
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

// MARK: - Сканер строковых литералов

/// Минимальный сканер Swift-исходника: отбрасывает комментарии (включая
/// вложенные блочные) и собирает содержимое строковых литералов с номерами
/// строк.
///
/// Интерполяция (`\(...)`) остаётся частью содержимого литерала: статической
/// проверке важно лишь, есть ли кириллица в тексте литерала, а не в
/// подставленном выражении. Вложенные литералы внутри интерполяции
/// пропускаются балансировкой скобок, чтобы не оборвать внешний литерал.
private enum SwiftSourceScanner {

    static func stringLiterals(in source: String) -> [FoundLiteral] {
        scan(source)
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    // MARK: Сканирование

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
                                // Интерполяция остаётся частью содержимого
                                // литерала: проверке важно, есть ли кириллица в
                                // исходном тексте, а не в подставленном коде.
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

    // MARK: Интерполяция

    /// Возвращает индекс после закрывающей скобки интерполяции `\(...)`.
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
                // Вложенный строковый литерал внутри интерполяции.
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

    // MARK: Служебные

    private enum State {
        case code
        case lineComment
        case blockComment
    }

}

#endif
