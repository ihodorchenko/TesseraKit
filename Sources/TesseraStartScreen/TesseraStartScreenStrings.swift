import Foundation

/// Внутренний единый источник пользовательских строк `TesseraStartScreen`.
///
/// E9.8г: до W5 строки по умолчанию жили русскими литералами прямо в коде
/// (озвучивания VoiceOver, меню и экран папки, дефолты `TesseraAppsListTexts`,
/// accessibility value панели). Теперь они лежат в ресурсах SPM — 
/// `Resources/en.lproj/Localizable.strings` и `Resources/ru.lproj/Localizable.strings` —
/// и резолвятся через `Bundle.module` по языку системы. Публичная поверхность
/// модуля не менялась: тип internal, все прежние настройки хоста
/// (``TesseraAppsListTexts``, `TesseraTileEditConfiguration.folderTitle`,
/// названия страниц контроллера) по-прежнему перекрывают значения по умолчанию.
///
/// Резолв:
/// - явный язык (`string(_:language:)`) — для тестов и для внутренних
///   вызовов, которым нужен детерминированный результат;
/// - `nil` — язык системы: первый предпочтённый язык, для которого есть
///   таблица. Язык без перевода (например, немецкий) откатывается к базовой
///   локали `en`, поэтому строка никогда не остаётся пустой и не превращается
///   в технический ключ.
///
/// Ключи — стабильные идентификаторы: паритет таблиц en/ru и соответствие
/// «ключ из кода ↔ ключ в таблицах» проверяют
/// `Tests/TesseraStartScreenTests/LocalizationTests.swift`.
///
/// - Note: `Bundle.module` в SPM существует только у target'а с ресурсами —
///   это `TesseraStartScreen`. Тестам бандл отдаётся швом ``bundle``, чтобы
///   они читали конкретные таблицы (`en.lproj`/`ru.lproj`), а не только
///   локализованный результат.
@usableFromInline
enum TesseraStartScreenStrings {

    // MARK: - Ресурсы

    /// Бандл ресурсов модуля (`Bundle.module`), в котором лежат таблицы строк.
    ///
    /// Шов для тестов: они передают этот бандл в `string(_:language:bundle:)`
    /// и читают таблицы en/ru напрямую.
    static var bundle: Bundle { .module }

    /// Языки, для которых в модуле есть таблица строк.
    static let supportedLanguages: Set<String> = ["en", "ru"]

    /// Базовая локаль: получает строка, если язык системы не поддержан.
    static let baseLanguage = "en"

    /// Имя таблицы строк в каждом `.lproj`.
    static let tableName = "Localizable"

    // MARK: - Ключи

    /// Ключ строки в таблицах `Localizable.strings`.
    ///
    /// Сырое значение — стабильный идентификатор: переименование ключа ломает
    /// таблицы en/ru и паритетный тест, поэтому ключи меняются только вместе с
    /// обоими `.strings`-файлами.
    enum Key: String, CaseIterable {

        // MARK: Режим редактирования и VoiceOver

        /// Вход в режим редактирования.
        case a11yEditingEntered = "a11y.editing.entered"

        /// Выход из режима редактирования.
        case a11yEditingExited = "a11y.editing.exited"

        /// Ярлык откреплён с рабочего стола.
        case a11yTileUnpinned = "a11y.tile.unpinned"

        /// Новый размер плитки (`%1$@` — название размера).
        case a11yResizeFormat = "a11y.resize.format"

        /// Название размера «маленький»/«small».
        case a11ySizeSmall = "a11y.size.small"

        /// Название размера «средний»/«medium».
        case a11ySizeMedium = "a11y.size.medium"

        /// Название размера «широкий»/«wide».
        case a11ySizeWide = "a11y.size.wide"

        /// Название размера «большой»/«large».
        case a11ySizeLarge = "a11y.size.large"

        // MARK: Папки

        /// Папка создана.
        case a11yFolderCreated = "a11y.folder.created"

        /// Ярлык добавлен в папку.
        case a11yFolderTileAdded = "a11y.folder.tileAdded"

        /// Ярлык перемещён в другую папку.
        case a11yFolderTileMoved = "a11y.folder.tileMoved"

        /// Ярлык перемещён из папки на рабочий стол.
        case a11yFolderTileOnStart = "a11y.folder.tileOnStart"

        /// Функция одобрения хоста запретила операцию с папкой.
        case a11yFolderUnavailable = "a11y.folder.unavailable"

        /// Папка создана перетаскиванием одного ярлыка на другой.
        case a11yFolderCreatedFromTwoTiles = "a11y.folder.createdFromTwoTiles"

        // MARK: Перетаскивание

        /// Внешнее изменение модели отменило перетаскивание.
        case a11yDragCancelled = "a11y.drag.cancelled"

        /// Удержание над папкой: отпускание добавит ярлык в папку.
        case a11yDragHoldToAddToFolder = "a11y.drag.holdToAddToFolder"

        /// Удержание над центром ярлыка: отпускание создаст папку.
        case a11yDragHoldToCreateFolder = "a11y.drag.holdToCreateFolder"

        // MARK: Отказ функции одобрения (D14)

        /// Шаблон сообщения об отказе (`%1$@` — причина).
        case a11yGroupingFailedFormat = "a11y.grouping.failedFormat"

        /// Причина отказа: добавление в папку запрещено.
        case a11yGroupingReasonAddDenied = "a11y.grouping.reason.addDenied"

        /// Причина отказа: создание папки запрещено.
        case a11yGroupingReasonCreateDenied = "a11y.grouping.reason.createDenied"

        /// Причина отказа: папка создана, но добавление ярлыка запрещено.
        case a11yGroupingReasonTileAddDenied = "a11y.grouping.reason.tileAddDenied"

        /// Причина отказа: перенос ярлыка из папки запрещён (E11.1).
        case a11yGroupingReasonMoveDenied = "a11y.grouping.reason.moveDenied"

        // MARK: Custom actions (§9)

        /// Действие «открепить ярлык».
        case a11yActionUnpin = "a11y.action.unpin"

        /// Действие «изменить размер плитки».
        case a11yActionResize = "a11y.action.resize"

        // MARK: Экран папки

        /// Кнопка закрытия экрана папки.
        case folderScreenDone = "folderScreen.done"

        /// Accessibility label кнопки закрытия.
        case folderScreenClose = "folderScreen.close"

        /// Подпись папки без названия.
        case folderScreenDefaultTitle = "folderScreen.defaultTitle"

        /// VoiceOver-действие «переместить ярлык».
        case folderScreenMoveAction = "folderScreen.moveAction"

        /// Заголовок меню перемещения (`%1$@` — подпись ярлыка).
        case folderScreenMoveMenuTitleFormat = "folderScreen.moveMenu.titleFormat"

        /// Пункт меню перемещения в папку (`%1$@` — название папки).
        case folderScreenMoveMenuIntoFormat = "folderScreen.moveMenu.intoFormat"

        /// Пункт меню «переместить на рабочий стол».
        case folderScreenMoveMenuToStart = "folderScreen.moveMenu.toStart"

        /// Подзаголовок экрана папки (`%1$ld` — число, `%2$@` — слово).
        case folderScreenTilesCountFormat = "folderScreen.tiles.countFormat"

        /// Слово «ярлык» для одного ярлыка.
        case folderScreenTilesWordOne = "folderScreen.tiles.word.one"

        /// Слово «ярлык» для нескольких ярлыков (2–4 в русском).
        case folderScreenTilesWordFew = "folderScreen.tiles.word.few"

        /// Слово «ярлык» для многих ярлыков.
        case folderScreenTilesWordMany = "folderScreen.tiles.word.many"

        // MARK: Список приложений

        /// Заголовок секции настроек.
        case appsListSettingsSectionTitle = "appsList.settingsSectionTitle"

        /// Текст пустого состояния.
        case appsListEmptyTitle = "appsList.emptyTitle"

        /// Действие «закрепить ярлык на рабочем столе».
        case appsListPinActionTitle = "appsList.pinActionTitle"

        /// Действие «открепить ярлык с рабочего стола».
        case appsListUnpinActionTitle = "appsList.unpinActionTitle"

        /// Значение закреплённой строки для VoiceOver.
        case appsListPinnedValue = "appsList.pinnedValue"

        // MARK: Сетка плиток

        /// Состояние раскрытой папки в accessibility value.
        case panelExpanded = "panel.expanded"

        // MARK: Общие

        /// Кнопка отмены в меню.
        case commonCancel = "common.cancel"
    }

    // MARK: - Резолв

    /// Возвращает строку по ключу для языка системы.
    ///
    /// - Parameter key: Ключ таблицы.
    /// - Returns: Локализованная строка (язык системы или базовая локаль).
    static func string(_ key: Key) -> String {
        string(key, language: nil)
    }

    /// Возвращает строку по ключу для явного языка.
    ///
    /// - Parameters:
    ///   - key: Ключ таблицы.
    ///   - language: Код языка (`"en"`, `"ru"`, допустим полный тег `ru-RU`)
    ///     или `nil` — язык системы. Неподдержанный язык откатывается к
    ///     ``baseLanguage``.
    ///   - bundle: Бандл ресурсов; по умолчанию ``bundle`` модуля. Параметр —
    ///     шов для тестов, а не публичная настройка.
    /// - Returns: Строка из таблицы; если таблица/ключ недоступны — базовый
    ///   язык, затем сырой ключ (видно в отладке).
    static func string(
        _ key: Key,
        language: String?,
        bundle: Bundle = TesseraStartScreenStrings.bundle
    ) -> String {
        let primary = resolvedLanguage(language, bundle: bundle)
        var candidates = [primary]
        if primary != baseLanguage {
            candidates.append(baseLanguage)
        }
        for code in candidates {
            guard let localized = localizedBundle(for: code, in: bundle) else { continue }
            let value = localized.localizedString(
                forKey: key.rawValue,
                value: key.rawValue,
                table: tableName
            )
            if value != key.rawValue {
                return value
            }
        }
        return key.rawValue
    }

    /// Язык резолва для строк по умолчанию.
    ///
    /// - Returns: `"ru"`, `"en"` или другой поддержанный код; для системы без
    ///   поддержанного языка — ``baseLanguage``.
    static func resolvedLanguage() -> String {
        resolvedLanguage(nil, bundle: bundle)
    }

    /// Резолвит код языка с учётом доступных таблиц.
    ///
    /// - Parameters:
    ///   - language: Явный код языка или `nil` — система.
    ///   - bundle: Бандл ресурсов.
    /// - Returns: Поддержанный код языка.
    static func resolvedLanguage(_ language: String?, bundle: Bundle) -> String {
        if let language {
            // Явный язык — детерминированно: неподдержанный откатывается к базе.
            return languageCode(from: language, available: availableLanguages(in: bundle)) ?? baseLanguage
        }
        // Язык системы: первый предпочтённый, для которого есть таблица.
        for preferred in Locale.preferredLanguages {
            if let code = languageCode(
                from: preferred,
                available: availableLanguages(in: bundle)
            ) {
                return code
            }
        }
        return baseLanguage
    }

    /// Приводит язык устройства к коду, для которого есть таблица.
    ///
    /// `Locale(identifier:)` знает полные теги (`ru-RU`, `en_US`) и исторические
    /// (`ru-RU` → `ru`); для незнакомых строк остаётся префикс до дефиса.
    ///
    /// - Parameters:
    ///   - identifier: Код языка или полный тег.
    ///   - available: Коды, для которых в бандле есть таблица.
    /// - Returns: Подходящий код или `nil`.
    private static func languageCode(
        from identifier: String,
        available: Set<String>
    ) -> String? {
        if let code = Locale(identifier: identifier).languageCode?.lowercased(),
           available.contains(code) {
            return code
        }
        let prefix = identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { $0.lowercased() }
        if let prefix, available.contains(prefix) {
            return prefix
        }
        return nil
    }

    /// Языки, для которых в бандле есть `.lproj`-таблица.
    ///
    /// - Parameter bundle: Бандл ресурсов.
    /// - Returns: Коды языков; пустое множество заменяется ``supportedLanguages``.
    static func availableLanguages(in bundle: Bundle) -> Set<String> {
        let localizations = Set(bundle.localizations.map { $0.lowercased() })
        let supported = localizations.intersection(supportedLanguages)
        return supported.isEmpty ? supportedLanguages : supported
    }

    /// Бандл конкретной локали внутри бандла ресурсов.
    ///
    /// - Parameters:
    ///   - code: Код языка.
    ///   - bundle: Бандл ресурсов модуля.
    /// - Returns: Бандл `xx.lproj` или `nil`, если локализации нет.
    static func localizedBundle(for code: String, in bundle: Bundle) -> Bundle? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("\(code).lproj", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Bundle(url: url)
    }

    // MARK: - Склонение числа ярлыков

    /// Слово «ярлык» в нужной числовой форме.
    ///
    /// Русский язык использует три формы (1 ярлык, 2 ярлыка, 5 ярлыков,
    /// 11 ярлыков), английский — две (1 shortcut, 2 shortcuts). Формы — в
    /// таблицах строк; правила выбора — здесь, потому что `.strings` не умеет
    /// plural-варианты (для этого нужен `.stringsdict`, а по решению W5 формат —
    /// обычные `Localizable.strings`).
    ///
    /// - Parameters:
    ///   - count: Число ярлыков (неотрицательное).
    ///   - language: Код языка или `nil` — язык системы. Параметр — шов для
    ///     тестов: правила форм проверяются для конкретного языка, а не для
    ///     локали симулятора.
    /// - Returns: Локализованное слово в нужной форме.
    static func folderTilesWord(for count: Int, language: String? = nil) -> String {
        let code = resolvedLanguage(language, bundle: bundle)
        if code == "ru" {
            let remainder100 = count % 100
            let remainder10 = count % 10
            if (11...14).contains(remainder100) {
                return string(.folderScreenTilesWordMany, language: language)
            }
            if remainder10 == 1 {
                return string(.folderScreenTilesWordOne, language: language)
            }
            if (2...4).contains(remainder10) {
                return string(.folderScreenTilesWordFew, language: language)
            }
            return string(.folderScreenTilesWordMany, language: language)
        }
        return string(
            count == 1 ? .folderScreenTilesWordOne : .folderScreenTilesWordMany,
            language: language
        )
    }

    /// Подзаголовок экрана папки: «3 ярлыка» / "3 shortcuts".
    ///
    /// - Parameters:
    ///   - count: Число ярлыков.
    ///   - language: Код языка или `nil` — язык системы (шов для тестов).
    /// - Returns: Готовое число с локализованным словом в нужной форме.
    static func folderTilesCountText(_ count: Int, language: String? = nil) -> String {
        String(
            format: string(.folderScreenTilesCountFormat, language: language),
            count,
            folderTilesWord(for: count, language: language)
        )
    }

    // MARK: - Значения по умолчанию для `TesseraAppsListTexts`

    /// Значения по умолчанию для ``TesseraAppsListTexts``, доступные из
    /// default-аргументов публичного инициализатора.
    ///
    /// `@usableFromInline` — единственный способ оставить публичной сигнатуру
    /// `TesseraAppsListTexts.init(settingsSectionTitle:..., ...)` без изменения
    /// и при этом резолвить значения в рантайме: default-аргумент публичного
    /// API не может ссылаться на обычный internal-символ. Тип и его члены
    /// остаются internal — публичная поверхность модуля не растёт.

    /// Заголовок секции настроек.
    @usableFromInline
    static var appsListSettingsSectionTitle: String {
        string(.appsListSettingsSectionTitle)
    }

    /// Текст пустого состояния.
    @usableFromInline
    static var appsListEmptyTitle: String {
        string(.appsListEmptyTitle)
    }

    /// Действие «закрепить».
    @usableFromInline
    static var appsListPinActionTitle: String {
        string(.appsListPinActionTitle)
    }

    /// Действие «открепить».
    @usableFromInline
    static var appsListUnpinActionTitle: String {
        string(.appsListUnpinActionTitle)
    }

    /// Значение закреплённой строки для VoiceOver.
    @usableFromInline
    static var appsListPinnedValue: String {
        string(.appsListPinnedValue)
    }
}
