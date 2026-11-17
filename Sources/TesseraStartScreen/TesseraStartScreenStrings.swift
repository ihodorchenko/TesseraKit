import Foundation

/// Internal single source of user-facing strings for `TesseraStartScreen`.
///
/// Default strings used to be Russian literals directly in code (VoiceOver announcements, menus and
/// the folder screen, the `TesseraAppsListTexts` defaults, the panel's accessibility value). They now
/// live in SPM resources, `Resources/en.lproj/Localizable.strings` and
/// `Resources/ru.lproj/Localizable.strings`, and are resolved through `Bundle.module` by the system
/// language. The public surface of the module did not change: the type is internal, and all existing
/// host settings (``TesseraAppsListTexts``, `TesseraTileEditConfiguration.folderTitle`, controller
/// page names) still override the defaults.
///
/// Resolution:
/// - an explicit language (`string(_:language:)`) is for tests and for internal calls that need a
///   deterministic result;
/// - `nil` means the system language: the first preferred language that has a table. A language
///   without a translation (for example, German) falls back to the base locale `en`, so a string is
///   never empty and never turns into a technical key.
///
/// Keys are stable identifiers: parity of the en/ru tables and the match between "key in code" and
/// "key in tables" are checked by `Tests/TesseraStartScreenTests/LocalizationTests.swift`.
///
/// - Note: In SPM, `Bundle.module` exists only for a target with resources, which is
///   `TesseraStartScreen`. Tests get the bundle through the ``bundle`` seam so that they read specific
///   tables (`en.lproj`/`ru.lproj`), not only the localized result.
@usableFromInline
enum TesseraStartScreenStrings {

    // MARK: - Resources

    /// The module's resource bundle (`Bundle.module`) that holds the string tables.
    ///
    /// A seam for tests: they pass this bundle to `string(_:language:bundle:)` and read the en/ru
    /// tables directly.
    static var bundle: Bundle { .module }

    /// Languages that have a string table in the module.
    static let supportedLanguages: Set<String> = ["en", "ru"]

    /// The base locale: used when the system language is not supported.
    static let baseLanguage = "en"

    /// The name of the string table in each `.lproj`.
    static let tableName = "Localizable"

    // MARK: - Keys

    /// A string key in the `Localizable.strings` tables.
    ///
    /// The raw value is a stable identifier: renaming a key breaks the en/ru tables and the parity
    /// test, so keys change only together with both `.strings` files.
    enum Key: String, CaseIterable {

        // MARK: Edit mode and VoiceOver

        /// Entering edit mode.
        case a11yEditingEntered = "a11y.editing.entered"

        /// Leaving edit mode.
        case a11yEditingExited = "a11y.editing.exited"

        /// A shortcut was unpinned from the start screen.
        case a11yTileUnpinned = "a11y.tile.unpinned"

        /// The new tile size (`%1$@` is the size name).
        case a11yResizeFormat = "a11y.resize.format"

        /// The name of the "small" size.
        case a11ySizeSmall = "a11y.size.small"

        /// The name of the "medium" size.
        case a11ySizeMedium = "a11y.size.medium"

        /// The name of the "wide" size.
        case a11ySizeWide = "a11y.size.wide"

        /// The name of the "large" size.
        case a11ySizeLarge = "a11y.size.large"

        // MARK: Folders

        /// A folder was created.
        case a11yFolderCreated = "a11y.folder.created"

        /// A shortcut was added to a folder.
        case a11yFolderTileAdded = "a11y.folder.tileAdded"

        /// A shortcut was moved to another folder.
        case a11yFolderTileMoved = "a11y.folder.tileMoved"

        /// A shortcut was moved from a folder to the start screen.
        case a11yFolderTileOnStart = "a11y.folder.tileOnStart"

        /// The host approval function forbade a folder operation.
        case a11yFolderUnavailable = "a11y.folder.unavailable"

        /// A folder was created by dragging one shortcut onto another.
        case a11yFolderCreatedFromTwoTiles = "a11y.folder.createdFromTwoTiles"

        /// The new position of a shortcut after reordering within a folder (`%1$d` is the number,
        /// `%2$d` is the shortcut count).
        case a11yFolderTilePositionFormat = "a11y.folder.tilePositionFormat"

        // MARK: Dragging

        /// An external model change cancelled the drag.
        case a11yDragCancelled = "a11y.drag.cancelled"

        /// Hovering over a folder: releasing adds the shortcut to the folder.
        case a11yDragHoldToAddToFolder = "a11y.drag.holdToAddToFolder"

        /// Hovering over a shortcut's center: releasing creates a folder.
        case a11yDragHoldToCreateFolder = "a11y.drag.holdToCreateFolder"

        // MARK: Approval function denial (D14)

        /// The denial message template (`%1$@` is the reason).
        case a11yGroupingFailedFormat = "a11y.grouping.failedFormat"

        /// Denial reason: adding to a folder is forbidden.
        case a11yGroupingReasonAddDenied = "a11y.grouping.reason.addDenied"

        /// Denial reason: creating a folder is forbidden.
        case a11yGroupingReasonCreateDenied = "a11y.grouping.reason.createDenied"

        /// Denial reason: adding a shortcut to a new folder is forbidden (the whole creation is rolled
        /// back).
        case a11yGroupingReasonTileAddDenied = "a11y.grouping.reason.tileAddDenied"

        /// Denial reason: moving a shortcut out of a folder is forbidden.
        case a11yGroupingReasonMoveDenied = "a11y.grouping.reason.moveDenied"

        // MARK: Custom actions (§9)

        /// The "unpin shortcut" action.
        case a11yActionUnpin = "a11y.action.unpin"

        /// The "resize tile" action.
        case a11yActionResize = "a11y.action.resize"

        /// The "rename folder" action (the folder tile and the panel title, D35).
        case a11yActionRenameFolder = "a11y.action.renameFolder"

        /// The "add shortcut to folder" action (`%1$@` is the folder name).
        case a11yActionAddToFolderFormat = "a11y.action.addToFolderFormat"

        /// The "remove shortcut from folder to the start screen" action.
        case a11yActionRemoveFromFolder = "a11y.action.removeFromFolder"

        /// The "move shortcut to another folder" action (`%1$@` is the folder name).
        case a11yActionMoveToFolderFormat = "a11y.action.moveToFolderFormat"

        /// The "move shortcut one position earlier in the folder panel" action.
        case a11yActionMoveEarlier = "a11y.action.moveEarlier"

        /// The "move shortcut one position later in the folder panel" action.
        case a11yActionMoveLater = "a11y.action.moveLater"

        // MARK: Folder screen

        /// The folder screen close button.
        case folderScreenDone = "folderScreen.done"

        /// The accessibility label of the close button.
        case folderScreenClose = "folderScreen.close"

        /// The caption of a folder without a name.
        case folderScreenDefaultTitle = "folderScreen.defaultTitle"

        /// The accessibility label of the folder rename field in the open panel (D35).
        case folderNameFieldLabel = "folderName.fieldLabel"

        /// The VoiceOver action "move shortcut".
        case folderScreenMoveAction = "folderScreen.moveAction"

        /// The title of the move menu (`%1$@` is the shortcut caption).
        case folderScreenMoveMenuTitleFormat = "folderScreen.moveMenu.titleFormat"

        /// A menu item to move into a folder (`%1$@` is the folder name).
        case folderScreenMoveMenuIntoFormat = "folderScreen.moveMenu.intoFormat"

        /// The menu item "move to the start screen".
        case folderScreenMoveMenuToStart = "folderScreen.moveMenu.toStart"

        /// The folder screen subtitle (`%1$ld` is the count, `%2$@` is the word).
        case folderScreenTilesCountFormat = "folderScreen.tiles.countFormat"

        /// The word "shortcut" for a single shortcut.
        case folderScreenTilesWordOne = "folderScreen.tiles.word.one"

        /// The word "shortcut" for a few shortcuts (2-4 in Russian).
        case folderScreenTilesWordFew = "folderScreen.tiles.word.few"

        /// The word "shortcut" for many shortcuts.
        case folderScreenTilesWordMany = "folderScreen.tiles.word.many"

        // MARK: Apps list

        /// The title of the settings section.
        case appsListSettingsSectionTitle = "appsList.settingsSectionTitle"

        /// The empty state text.
        case appsListEmptyTitle = "appsList.emptyTitle"

        /// The "pin shortcut to the start screen" action.
        case appsListPinActionTitle = "appsList.pinActionTitle"

        /// The "unpin shortcut from the start screen" action.
        case appsListUnpinActionTitle = "appsList.unpinActionTitle"

        /// The VoiceOver value of a pinned row.
        case appsListPinnedValue = "appsList.pinnedValue"

        // MARK: Tile grid

        /// The expanded folder state in the accessibility value.
        case panelExpanded = "panel.expanded"

        // MARK: Badge (§9)

        /// The VoiceOver value of a dot badge without a number (D34).
        case a11yBadgeDot = "a11y.badge.dot"

        // MARK: Common

        /// The cancel button in a menu.
        case commonCancel = "common.cancel"
    }

    // MARK: - Resolution

    /// Returns the string for a key in the system language.
    ///
    /// - Parameter key: The table key.
    /// - Returns: The localized string (system language or the base locale).
    static func string(_ key: Key) -> String {
        string(key, language: nil)
    }

    /// Returns the string for a key in an explicit language.
    ///
    /// - Parameters:
    ///   - key: The table key.
    ///   - language: A language code (`"en"`, `"ru"`; a full tag such as `ru-RU` is allowed) or `nil`
    ///     for the system language. An unsupported language falls back to ``baseLanguage``.
    ///   - bundle: The resource bundle; the module's ``bundle`` by default. The parameter is a seam
    ///     for tests, not a public setting.
    /// - Returns: The string from the table; if the table or key is unavailable, the base language,
    ///   then the raw key (visible while debugging).
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

    /// The resolution language for default strings.
    ///
    /// - Returns: `"ru"`, `"en"` or another supported code; for a system without a supported
    ///   language, ``baseLanguage``.
    static func resolvedLanguage() -> String {
        resolvedLanguage(nil, bundle: bundle)
    }

    /// Resolves a language code against the available tables.
    ///
    /// - Parameters:
    ///   - language: An explicit language code, or `nil` for the system language.
    ///   - bundle: The resource bundle.
    /// - Returns: A supported language code.
    static func resolvedLanguage(_ language: String?, bundle: Bundle) -> String {
        if let language {
            // An explicit language is deterministic: an unsupported one falls back to the base.
            return languageCode(from: language, available: availableLanguages(in: bundle)) ?? baseLanguage
        }
        // The system language: the first preferred one that has a table.
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

    /// Maps a device language to a code that has a table.
    ///
    /// `Locale(identifier:)` knows full tags (`ru-RU`, `en_US`) and legacy ones (`ru-RU` -> `ru`);
    /// for unknown strings the prefix before the hyphen is kept.
    ///
    /// - Parameters:
    ///   - identifier: A language code or a full tag.
    ///   - available: The codes that have a table in the bundle.
    /// - Returns: A matching code or `nil`.
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

    /// Languages that have an `.lproj` table in the bundle.
    ///
    /// - Parameter bundle: The resource bundle.
    /// - Returns: Language codes; an empty set is replaced with ``supportedLanguages``.
    static func availableLanguages(in bundle: Bundle) -> Set<String> {
        let localizations = Set(bundle.localizations.map { $0.lowercased() })
        let supported = localizations.intersection(supportedLanguages)
        return supported.isEmpty ? supportedLanguages : supported
    }

    /// The bundle of a specific locale inside the resource bundle.
    ///
    /// - Parameters:
    ///   - code: A language code.
    ///   - bundle: The module's resource bundle.
    /// - Returns: The `xx.lproj` bundle, or `nil` if there is no localization.
    static func localizedBundle(for code: String, in bundle: Bundle) -> Bundle? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("\(code).lproj", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Bundle(url: url)
    }

    // MARK: - Pluralization of the shortcut count

    /// The word "shortcut" in the right plural form.
    ///
    /// Russian uses three forms (the word takes different endings for 1, 2-4 and 5+ shortcuts, with
    /// 11-14 behaving like 5+), English uses two (1 shortcut, 2 shortcuts). The forms live in the
    /// string tables; the selection rules live here, because `.strings` cannot express plural
    /// variants (that needs `.stringsdict`, and the format here is plain `Localizable.strings`).
    ///
    /// - Parameters:
    ///   - count: The shortcut count (non-negative).
    ///   - language: A language code, or `nil` for the system language. The parameter is a seam for
    ///     tests: the form rules are checked for a specific language, not for the simulator locale.
    /// - Returns: The localized word in the right form.
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

    /// The folder screen subtitle: "3 shortcuts" in English, the Russian plural form in Russian.
    ///
    /// - Parameters:
    ///   - count: The shortcut count.
    ///   - language: A language code, or `nil` for the system language (a seam for tests).
    /// - Returns: The number with the localized word in the right form.
    static func folderTilesCountText(_ count: Int, language: String? = nil) -> String {
        String(
            format: string(.folderScreenTilesCountFormat, language: language),
            count,
            folderTilesWord(for: count, language: language)
        )
    }

    // MARK: - Defaults for `TesseraAppsListTexts`

    /// Defaults for ``TesseraAppsListTexts``, available from the default arguments of the public
    /// initializer.
    ///
    /// `@usableFromInline` is the only way to keep the public signature
    /// `TesseraAppsListTexts.init(settingsSectionTitle:..., ...)` unchanged and still resolve values
    /// at runtime: a default argument of a public API cannot reference an ordinary internal symbol.
    /// The type and its members stay internal, so the module's public surface does not grow.

    /// The title of the settings section.
    @usableFromInline
    static var appsListSettingsSectionTitle: String {
        string(.appsListSettingsSectionTitle)
    }

    /// The empty state text.
    @usableFromInline
    static var appsListEmptyTitle: String {
        string(.appsListEmptyTitle)
    }

    /// The "pin" action.
    @usableFromInline
    static var appsListPinActionTitle: String {
        string(.appsListPinActionTitle)
    }

    /// The "unpin" action.
    @usableFromInline
    static var appsListUnpinActionTitle: String {
        string(.appsListUnpinActionTitle)
    }

    /// The VoiceOver value of a pinned row.
    @usableFromInline
    static var appsListPinnedValue: String {
        string(.appsListPinnedValue)
    }
}
