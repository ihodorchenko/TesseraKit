//
//  TileFolderRenameTests.swift
//  TesseraStartScreenTests
//
//  Переименование папки (D35, E15.5; W10M §6.7). Проектный документ:
//  docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации (E15)», п. 62;
//  решение D35 в docs/STATE.md.
//
//  Проверяется:
//  - модель: `TesseraTileStore.renameFolder(_:to:)` (обрезка пробелов, пустое имя —
//    имя по умолчанию, предел 64 символа, неизвестная папка, то же имя без
//    уведомления, круг записи, одно `onChange`, ячейка/размер/состав целы);
//  - сетка: правка имени в открытой панели (поле, return, тап мимо, пустое имя,
//    итоговое имя в обработчике, высота шапки, закрытие панели, смена
//    обработчика, предел при вводе), клавиатура (поле над ней, возврат полей и
//    смещения, Reduce Motion), RTL и Dynamic Type;
//  - координатор: обработчик, `TesseraTileStore`, делегат, имя по умолчанию из
//    конфигурации, вход/выход из режима редактирования, выключенный координатор;
//  - VoiceOver: действие «Переименовать» на заголовке панели и плитке папки,
//    подпись поля, фокус до и после правки;
//  - жесты: долгое нажатие по имени не стартует ни drag, ни вход в правку (зона
//    имени), долгое нажатие по ярлыку панели по-прежнему выносит его;
//  - строки en/ru.
//
//  Раскладки точные (`TileStoreCellFixture`, 4 колонки), без `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderRenameTests: XCTestCase {

    // MARK: - Помощники модели

    private let columns = 4

    private func makeStore(
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) throws -> TesseraTileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [CellFixtureTile("a0", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])],
            in: directory,
            autosaves: autosaves
        )
    }

    private func folderTitle(_ store: TesseraTileStore, id: AnyHashable = "F") -> String? {
        store.snapshot(columns: columns).folders.first { $0.id == id }?.title
    }

    private func countNotifications(_ store: TesseraTileStore) -> () -> Int {
        var count = 0
        store.onChange = { _ in count += 1 }
        return { count }
    }

    // MARK: - TesseraTileStore.renameFolder

    /// Пробелы и переводы строк по краям отбрасываются; результат записан в модель.
    func testRenameTrimsSurroundingWhitespaceAndNewlines() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        XCTAssertTrue(store.renameFolder("F", to: "  \n Работа \t\n"))
        XCTAssertEqual(folderTitle(store), "Работа")
    }

    /// Пустое и состоящее из пробелов имя возвращает имя по умолчанию — то же
    /// локализованное «Папка»/«Folder», что получает новая папка.
    func testRenameEmptyReturnsDefaultTitle() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let fallback = TesseraStartScreenStrings.string(.folderScreenDefaultTitle)

        XCTAssertTrue(store.renameFolder("F", to: "Работа"))
        XCTAssertTrue(store.renameFolder("F", to: ""))
        XCTAssertEqual(folderTitle(store), fallback)

        XCTAssertTrue(store.renameFolder("F", to: "Игры"))
        XCTAssertTrue(store.renameFolder("F", to: "  \n\t "))
        XCTAssertEqual(folderTitle(store), fallback, "Только пробелы — тоже пустое имя")
    }

    /// Предел 64 символа: длинное имя обрезается, пробелы на краю среза чистятся.
    func testRenameCapsLengthAndTrimsAfterCut() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        XCTAssertEqual(TesseraTileFolder.maximumTitleLength, 64)

        XCTAssertTrue(store.renameFolder("F", to: String(repeating: "я", count: 100)))
        XCTAssertEqual(folderTitle(store), String(repeating: "я", count: 64))

        // Срез попадает на пробел: хвост после обрезки не остаётся пробелом.
        let spaced = String(repeating: "a", count: 63) + " " + String(repeating: "b", count: 10)
        XCTAssertTrue(store.renameFolder("F", to: spaced))
        XCTAssertEqual(folderTitle(store), String(repeating: "a", count: 63))

        // Ровно предел проходит целиком; считаются символы, а не байты.
        let emoji = String(repeating: "😀", count: 64)
        XCTAssertTrue(store.renameFolder("F", to: emoji))
        XCTAssertEqual(folderTitle(store)?.count, 64)
    }

    /// Имя — одна строка: переводы строк внутри становятся пробелами.
    func testRenameKeepsSingleLine() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        XCTAssertTrue(store.renameFolder("F", to: "Рабочие\nпроекты"))
        XCTAssertEqual(folderTitle(store), "Рабочие проекты")
    }

    /// Неизвестная папка и ярлык вместо папки — `false`, без уведомлений.
    func testRenameUnknownFolderIsNoOp() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let notifications = countNotifications(store)

        XCTAssertFalse(store.renameFolder("nope", to: "X"))
        XCTAssertFalse(store.renameFolder("a0", to: "X"), "Ярлык — не папка")
        XCTAssertEqual(notifications(), 0)
        XCTAssertEqual(folderTitle(store), "F")
    }

    /// То же имя (в том числе после нормализации) — `false`, без `onChange` и записи.
    func testRenameToSameTitleIsNoOpWithoutNotificationOrSave() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)
        XCTAssertTrue(store.renameFolder("F", to: "Работа"))
        try FileManager.default.removeItem(at: store.fileURL)
        let notifications = countNotifications(store)

        XCTAssertFalse(store.renameFolder("F", to: "Работа"))
        XCTAssertFalse(store.renameFolder("F", to: "  Работа  "))
        XCTAssertEqual(notifications(), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path),
            "Неизменённое имя не пишет файл"
        )
    }

    /// Круг записи: имя переживает перезапуск; пустое имя — имя по умолчанию.
    func testRenamePersistsThroughRoundTrip() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)
        XCTAssertTrue(store.renameFolder("F", to: "Работа"))

        let catalog = ["a0", "x", "y", "z"].map { tesseraTestTile($0, size: .small) }
        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog(catalog)
        try fresh.load()
        XCTAssertEqual(folderTitle(fresh), "Работа")

        XCTAssertTrue(store.renameFolder("F", to: ""))
        let again = TesseraTileStore(directoryURL: directory.url)
        again.setCatalog(catalog)
        try again.load()
        XCTAssertEqual(folderTitle(again), TesseraStartScreenStrings.string(.folderScreenDefaultTitle))
    }

    /// Ровно одно уведомление на успешную операцию; снимок несёт новое имя.
    func testRenameNotifiesOnChangeOnce() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        var snapshots: [TesseraTileGridSnapshot] = []
        store.onChange = { snapshots.append($0) }

        XCTAssertTrue(store.renameFolder("F", to: "Работа"))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.folders.first?.title, "Работа")
    }

    /// Переименование не трогает ни ячейку, ни размер, ни состав папки.
    func testRenameKeepsCellSizeAndContent() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let before = store.snapshot(columns: columns)
        let cellsBefore = before.placementTable?.cells
        let folderBefore = try XCTUnwrap(before.folders.first)

        XCTAssertTrue(store.renameFolder("F", to: "Работа"))
        let after = store.snapshot(columns: columns)
        let folderAfter = try XCTUnwrap(after.folders.first)
        XCTAssertEqual(after.placementTable?.cells, cellsBefore)
        XCTAssertEqual(folderAfter.size, folderBefore.size)
        XCTAssertEqual(folderAfter.tiles.map { $0.id }, folderBefore.tiles.map { $0.id })
        XCTAssertEqual(after.items.map { $0.id }, before.items.map { $0.id })
    }

    // MARK: - Помощники сетки

    private final class Recorder {
        var renames: [(AnyHashable, String)] = []
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private struct GridFixture {
        let host: TesseraTestWindowedGrid
        let folder: TesseraTileFolder
        let recorder: Recorder
        var grid: TesseraTileGridView { host.grid }
    }

    /// Сетка в окне с одной папкой «Работа» из четырёх ярлыков; обработчик
    /// переименования записывает вызовы (`installsHandler == false` — без него).
    private func makeGridFixture(
        installsHandler: Bool = true,
        title: String = "Работа",
        extraItems: [TesseraTileGridItem] = [],
        size: CGSize = TesseraTestWindowedGrid.defaultSize
    ) -> GridFixture {
        let folder = tesseraTestFolder("F", tileCount: 4, title: title)
        let host = TesseraTestWindowedGrid(
            items: [.folder(folder)] + extraItems,
            columns: 4,
            size: size
        )
        host.window.makeKeyAndVisible()
        let recorder = Recorder()
        host.grid.accessibilityNotificationPoster = { recorder.posts.append(($0, $1)) }
        if installsHandler {
            host.grid.folderRenameHandler = { recorder.renames.append(($0, $1)) }
        }
        return GridFixture(host: host, folder: folder, recorder: recorder)
    }

    @discardableResult
    private func openPanel(_ fixture: GridFixture) throws -> TesseraFolderPanelCell {
        fixture.grid.openFolder(fixture.folder, animated: false)
        fixture.host.layout()
        XCTAssertEqual(fixture.grid.expandedFolderID, "F")
        return try XCTUnwrap(fixture.host.panelCell(folderID: "F"))
    }

    private func type(_ text: String, in panel: TesseraFolderPanelCell) {
        panel.titleTextField.text = text
    }

    private func pressReturn(in panel: TesseraFolderPanelCell) {
        let field = panel.titleTextField
        _ = field.delegate?.textFieldShouldReturn?(field)
    }

    /// Тап по свободному месту сетки (под панелью) — как касание пальцем.
    private func tapGridBackground(_ grid: TesseraTileGridView) {
        final class FakeTap: UITapGestureRecognizer {
            var point = CGPoint.zero
            override func location(in view: UIView?) -> CGPoint { point }
        }
        let tap = FakeTap()
        tap.point = CGPoint(x: 195, y: grid.bounds.height - 20)
        grid.perform(NSSelectorFromString("handleBackgroundTap:"), with: tap)
    }

    private func longPressRecognizer(of panel: TesseraFolderPanelCell) -> UILongPressGestureRecognizer? {
        panel.titleHeaderLabel.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first
    }

    // MARK: - Сетка: вход в правку

    /// Долгое нажатие по имени (≈0,5 с) включено только когда у сетки есть
    /// обработчик; без него заголовок статичен, правка не начинается, действия
    /// VoiceOver нет.
    func testNameLongPressIsEnabledOnlyWithHandler() throws {
        let without = makeGridFixture(installsHandler: false)
        let bare = try openPanel(without)
        XCTAssertEqual(longPressRecognizer(of: bare)?.isEnabled, false)
        XCTAssertEqual(longPressRecognizer(of: bare)?.minimumPressDuration ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(bare.beginTitleEditing())
        XCTAssertFalse(bare.isEditingTitle)
        XCTAssertNil(bare.titleHeaderLabel.accessibilityCustomActions)
        XCTAssertFalse(without.grid.isFolderNameHit(at: CGPoint(x: 100, y: 20)))

        let with = makeGridFixture()
        let panel = try openPanel(with)
        XCTAssertEqual(longPressRecognizer(of: panel)?.isEnabled, true)
        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertTrue(panel.isEditingTitle)
        XCTAssertTrue(with.grid.isEditingFolderName)
    }

    /// Поле: имя в поле как в заголовке и выделено целиком, одна строка, return —
    /// «Готово», без автокоррекции; подпись для VoiceOver; шрифт и рамка как у заголовка.
    func testFieldIsPrefilledSelectedSingleLineAndAccessible() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let label = panel.titleHeaderLabel
        XCTAssertTrue(panel.beginTitleEditing())

        let field = panel.titleTextField
        XCTAssertEqual(field.text, "Работа")
        XCTAssertFalse(field.isHidden)
        XCTAssertTrue(label.isHidden)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertEqual(field.returnKeyType, .done)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.spellCheckingType, .no)
        XCTAssertEqual(field.accessibilityLabel, TesseraStartScreenStrings.string(.folderNameFieldLabel))
        XCTAssertEqual(field.font, label.font)
        XCTAssertEqual(field.frame, label.frame, "Поле занимает рамку заголовка")

        let range = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.text(in: range), "Работа", "Имя выделено целиком")
    }

    /// Правка не меняет высоту шапки: панель и ярлыки под заголовком остаются на месте.
    func testHeaderHeightAndLayoutAreStableDuringEditing() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let panelFrame = panel.frame
        let shortcutFrames = panel.shortcutCells.map { $0.frame }
        let labelFrame = panel.titleHeaderLabel.frame
        let contentHeight = fixture.grid.contentSize.height

        XCTAssertTrue(panel.beginTitleEditing())
        fixture.host.layout()
        XCTAssertEqual(panel.frame, panelFrame)
        XCTAssertEqual(panel.shortcutCells.map { $0.frame }, shortcutFrames)
        XCTAssertEqual(panel.titleHeaderLabel.frame, labelFrame)
        XCTAssertEqual(panel.titleTextField.frame, labelFrame)
        XCTAssertEqual(fixture.grid.contentSize.height, contentHeight)

        pressReturn(in: panel)
        fixture.host.layout()
        XCTAssertEqual(panel.frame, panelFrame)
        XCTAssertEqual(panel.titleHeaderLabel.frame, labelFrame)
    }

    // MARK: - Сетка: фиксация

    /// Return фиксирует имя: обработчик получает итоговое (нормализованное) имя,
    /// заголовок показывает его, правка закончена.
    func testReturnCommitsFinalNameAndUpdatesLabel() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("  Игры  ", in: panel)
        pressReturn(in: panel)

        XCTAssertEqual(fixture.recorder.renames.count, 1)
        XCTAssertEqual(fixture.recorder.renames.first?.0, "F")
        XCTAssertEqual(fixture.recorder.renames.first?.1, "Игры")
        XCTAssertEqual(panel.titleHeaderLabel.text, "Игры")
        XCTAssertEqual(panel.titleHeaderLabel.accessibilityLabel, "Игры")
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertFalse(fixture.grid.isEditingFolderName)
        XCTAssertTrue(panel.titleTextField.isHidden)
        XCTAssertFalse(panel.titleHeaderLabel.isHidden)
        XCTAssertFalse(panel.titleTextField.isFirstResponder)
    }

    /// Тап по фону сетки фиксирует имя и папку не закрывает.
    func testBackgroundTapCommitsAndKeepsFolderOpen() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Игры", in: panel)

        tapGridBackground(fixture.grid)
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Игры"])
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertEqual(fixture.grid.expandedFolderID, "F", "Тап мимо поля только фиксирует имя")
        XCTAssertEqual(panel.titleHeaderLabel.text, "Игры")

        // Вне правки тот же тап по-прежнему закрывает папку.
        fixture.grid.isReduceMotionEnabled = { true }
        tapGridBackground(fixture.grid)
        XCTAssertNil(fixture.grid.expandedFolderID)
    }

    /// Пустое имя (и из одних пробелов) — «имя по умолчанию»: обработчик получает
    /// пустую строку, заголовок показывает локализованное имя по умолчанию.
    func testEmptyNameBecomesDefaultTitle() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("   ", in: panel)
        pressReturn(in: panel)

        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, [""])
        XCTAssertEqual(
            panel.titleHeaderLabel.text,
            TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        )
    }

    /// Имя не изменилось (в том числе после обрезки пробелов) — обработчик не зовётся.
    func testUnchangedNameDoesNotCallHandler() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type(" Работа ", in: panel)
        pressReturn(in: panel)
        XCTAssertTrue(fixture.recorder.renames.isEmpty)
        XCTAssertEqual(panel.titleHeaderLabel.text, "Работа")

        // Пустая папка-имя по умолчанию и пустой ввод — тоже «без изменений».
        let untitled = makeGridFixture(title: "")
        let blank = try openPanel(untitled)
        XCTAssertTrue(blank.beginTitleEditing())
        type("", in: blank)
        pressReturn(in: blank)
        XCTAssertTrue(untitled.recorder.renames.isEmpty)
    }

    /// Обработчик получает имя не длиннее предела, одной строкой.
    func testHandlerReceivesCappedSingleLineName() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type(String(repeating: "ы", count: 90) + "\nхвост", in: panel)
        pressReturn(in: panel)
        XCTAssertEqual(fixture.recorder.renames.first?.1.count, TesseraTileFolder.maximumTitleLength)
        XCTAssertFalse(fixture.recorder.renames.first?.1.contains("\n") ?? true)
    }

    /// Ввод ограничен пределом: правка, после которой строка длиннее 64, не
    /// применяется; удаление и замена в пределах — проходят.
    func testTypingIsCappedAtMaximumLength() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        let field = panel.titleTextField
        let delegate = try XCTUnwrap(field.delegate)

        field.text = String(repeating: "a", count: 64)
        XCTAssertFalse(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 64, length: 0), replacementString: "b") ?? true
        )
        XCTAssertTrue(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 0, length: 1), replacementString: "b") ?? false,
            "Замена символа в пределе проходит"
        )
        XCTAssertTrue(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 60, length: 4), replacementString: "") ?? false,
            "Удаление проходит"
        )
        XCTAssertFalse(
            delegate.textField?(field, shouldChangeCharactersIn: NSRange(location: 64, length: 0), replacementString: "😀") ?? true
        )
    }

    /// Закрытие панели во время правки фиксирует имя (D35), фокус VoiceOver на
    /// заголовок панели не возвращается.
    func testClosingPanelWhileEditingCommits() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Игры", in: panel)
        fixture.recorder.posts.removeAll()

        fixture.grid.closeFolder(animated: false)
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Игры"])
        XCTAssertFalse(fixture.grid.isEditingFolderName)
        XCTAssertNil(fixture.grid.expandedFolderID)
        XCTAssertFalse(
            fixture.recorder.posts.contains { ($0.1 as? UILabel) === panel.titleHeaderLabel },
            "Панель закрыта: фокус идёт на плитку папки"
        )
    }

    /// Смена обработчика посреди правки фиксирует набранное старым обработчиком;
    /// при `nil` заголовок снова статичен.
    func testReplacingHandlerCommitsWithOldHandlerAndDisablesEditing() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Игры", in: panel)

        fixture.grid.folderRenameHandler = nil
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Игры"])
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertFalse(panel.isTitleEditable)
        XCTAssertEqual(longPressRecognizer(of: panel)?.isEnabled, false)
        XCTAssertNil(panel.titleHeaderLabel.accessibilityCustomActions)
    }

    /// Панель ушла в переиспользование посреди правки: имя фиксируется, а
    /// обработчик зовётся на следующем проходе runloop.
    func testReusingPanelWhileEditingCommitsDeferred() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Игры", in: panel)

        panel.prepareForReuse()
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertTrue(fixture.recorder.renames.isEmpty, "Обработчик не зовётся внутри переиспользования")
        XCTAssertTrue(fixture.host.waitUntil { !fixture.recorder.renames.isEmpty })
        XCTAssertEqual(fixture.recorder.renames.first?.1, "Игры")
    }

    // MARK: - Клавиатура

    /// Окно 390×500 и папка ниже первого экрана; панель раскрыта, сетка
    /// прокручена так, что шапка панели у нижнего края экрана (клавиатура её
    /// перекроет). Reduce Motion включён: прокрутка без анимации.
    private func makeScrollingFixture() throws -> (GridFixture, TesseraFolderPanelCell, CGFloat) {
        let tiles: [TesseraTileGridItem] = (0..<4).map { .tile(tesseraTestTile("t\($0)", size: .medium)) }
        let folder = tesseraTestFolder("F", tileCount: 4, title: "Работа")
        let host = TesseraTestWindowedGrid(
            items: tiles + [.folder(folder)] + (0..<6).map { .tile(tesseraTestTile("u\($0)", size: .wide)) },
            columns: 4,
            size: CGSize(width: 390, height: 500)
        )
        host.window.makeKeyAndVisible()
        let recorder = Recorder()
        host.grid.accessibilityNotificationPoster = { recorder.posts.append(($0, $1)) }
        host.grid.folderRenameHandler = { recorder.renames.append(($0, $1)) }
        host.grid.isReduceMotionEnabled = { true }
        let fixture = GridFixture(host: host, folder: folder, recorder: recorder)

        let folderFrame = try XCTUnwrap(host.grid.frame(forItemID: "F"))
        host.grid.openFolder(folder, animated: false)
        host.layout()
        let offset = folderFrame.maxY - 380
        XCTAssertGreaterThan(offset, 0, "Папка ниже первого экрана")
        host.grid.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        host.layout()
        let panel = try XCTUnwrap(host.panelCell(folderID: "F"))
        return (fixture, panel, host.collectionView?.contentOffset.y ?? 0)
    }

    private func fieldFrameInGrid(_ panel: TesseraFolderPanelCell, grid: TesseraTileGridView) -> CGRect {
        panel.titleTextField.convert(panel.titleTextField.bounds, to: grid)
    }

    /// Клавиатура перекрывает поле — сетка прокручивается так, чтобы поле стало
    /// видно над ней (Reduce Motion — без анимации, смещение сразу), нижнее поле
    /// коллекции равно перекрытию; по завершении поля и смещение возвращаются.
    func testKeyboardScrollsFieldAboveKeyboardAndRestoresOnEnd() throws {
        let (fixture, panel, originalOffset) = try makeScrollingFixture()
        let grid = fixture.grid
        let collection = try XCTUnwrap(fixture.host.collectionView)
        XCTAssertGreaterThan(fieldFrameInGrid(panel, grid: grid).maxY, 200, "Без клавиатуры поле ниже её будущей кромки")

        XCTAssertTrue(panel.beginTitleEditing())
        let keyboardHeight: CGFloat = 300
        grid.applyKeyboardFrame(
            CGRect(x: 0, y: 500 - keyboardHeight, width: 390, height: keyboardHeight)
        )
        XCTAssertEqual(collection.contentInset.bottom, keyboardHeight, accuracy: 0.5)
        let field = fieldFrameInGrid(panel, grid: grid)
        XCTAssertGreaterThanOrEqual(field.minY, 0, "Заголовок виден сверху")
        XCTAssertLessThanOrEqual(field.maxY, 500 - keyboardHeight, "Поле над клавиатурой")

        pressReturn(in: panel)
        XCTAssertEqual(collection.contentInset.bottom, 0, accuracy: 0.001, "Поля возвращены")
        XCTAssertEqual(collection.contentOffset.y, originalOffset, accuracy: 1, "Смещение возвращено")
    }

    /// Клавиатура скрылась посреди правки: поля возвращаются, правка продолжается;
    /// скролл пользователя во время правки не откатывается по завершении.
    func testKeyboardHideRestoresInsetsAndUserScrollIsKept() throws {
        let (fixture, panel, _) = try makeScrollingFixture()
        let grid = fixture.grid
        let collection = try XCTUnwrap(fixture.host.collectionView)
        XCTAssertTrue(panel.beginTitleEditing())
        grid.applyKeyboardFrame(CGRect(x: 0, y: 200, width: 390, height: 300))
        XCTAssertEqual(collection.contentInset.bottom, 300, accuracy: 0.5)

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertEqual(collection.contentInset.bottom, 0, accuracy: 0.001)
        XCTAssertTrue(panel.isEditingTitle, "Скрытие клавиатуры правку не завершает")

        // Пользователь прокрутил сам: по завершении смещение не откатывается.
        grid.setContentOffset(CGPoint(x: 0, y: collection.contentOffset.y + 120), animated: false)
        let userOffset = collection.contentOffset.y
        pressReturn(in: panel)
        XCTAssertEqual(collection.contentOffset.y, userOffset, accuracy: 1)
    }

    /// Уведомление о клавиатуре, пришедшее до регистрации правки (во время
    /// `becomeFirstResponder`), учитывается: последняя рамка запоминается.
    func testKeyboardFrameNotificationBeforeEditingIsRemembered() throws {
        let (fixture, panel, _) = try makeScrollingFixture()
        let collection = try XCTUnwrap(fixture.host.collectionView)

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 200, width: 390, height: 300)]
        )
        XCTAssertEqual(collection.contentInset.bottom, 0, accuracy: 0.001, "Вне правки поля не трогаются")
        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertEqual(collection.contentInset.bottom, 300, accuracy: 0.5)
        pressReturn(in: panel)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - RTL и Dynamic Type

    /// RTL: поле и заголовок в одной рамке (полная ширина шапки), выравнивание
    /// естественное; поле в RTL зеркалится вместе с заголовком.
    func testRightToLeftHeaderKeepsFieldAndLabelAligned() throws {
        let fixture = makeGridFixture()
        fixture.grid.semanticContentAttribute = .forceRightToLeft
        fixture.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        let panel = try openPanel(fixture)
        panel.semanticContentAttribute = .forceRightToLeft
        panel.contentView.semanticContentAttribute = .forceRightToLeft
        fixture.host.layout()

        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertEqual(panel.titleTextField.frame, panel.titleHeaderLabel.frame)
        XCTAssertEqual(panel.titleTextField.textAlignment, .natural)
        XCTAssertEqual(panel.titleHeaderLabel.textAlignment, .natural)
        type("Игры", in: panel)
        pressReturn(in: panel)
        XCTAssertEqual(fixture.recorder.renames.map { $0.1 }, ["Игры"])
    }

    /// Dynamic Type: поле берёт шрифт заголовка (с потолком по высоте шапки) и
    /// следует за ним при смене категории.
    func testFieldFontFollowsHeaderFontAndFitsHeader() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let large = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let expected = TesseraFolderPanelCell.makeTitleFont(compatibleWith: large)
        XCTAssertLessThanOrEqual(
            expected.lineHeight,
            TesseraTileLayoutEngine.panelHeaderHeight,
            "Строка заголовка помещается в шапку на AX5"
        )
        panel.refreshTypography()
        XCTAssertEqual(panel.titleTextField.font, panel.titleHeaderLabel.font)
    }

    // MARK: - VoiceOver

    /// Действие «Переименовать» на заголовке панели начинает ту же правку;
    /// фокус уходит на поле, а после фиксации возвращается на заголовок.
    func testHeaderRenameActionStartsEditingAndReturnsFocus() throws {
        let fixture = makeGridFixture()
        let panel = try openPanel(fixture)
        let actions = try XCTUnwrap(panel.titleHeaderLabel.accessibilityCustomActions)
        XCTAssertEqual(actions.map { $0.name }, [TesseraStartScreenStrings.string(.a11yActionRenameFolder)])
        fixture.recorder.posts.removeAll()

        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertTrue(panel.isEditingTitle)
        XCTAssertTrue(
            fixture.recorder.posts.contains { $0.0 == .layoutChanged && ($0.1 as? UITextField) === panel.titleTextField },
            "Фокус на поле"
        )

        type("Игры", in: panel)
        fixture.recorder.posts.removeAll()
        pressReturn(in: panel)
        XCTAssertTrue(
            fixture.recorder.posts.contains { $0.0 == .layoutChanged && ($0.1 as? UILabel) === panel.titleHeaderLabel },
            "Фокус вернулся на заголовок"
        )
        XCTAssertEqual(panel.titleHeaderLabel.accessibilityLabel, "Игры", "Подпись отражает новое имя")
        XCTAssertFalse(
            fixture.recorder.posts.contains { $0.0 == .announcement },
            "Дополнительных объявлений нет"
        )
    }

    /// Плитка папки получает действие «Переименовать» вместе с обработчиком;
    /// активация раскрывает папку и начинает правку; без обработчика действия нет.
    func testFolderTileRenameActionOpensPanelAndStartsEditing() throws {
        let fixture = makeGridFixture()
        let tile = try XCTUnwrap(fixture.host.cell("F"))
        let actions = try XCTUnwrap(tile.accessibilityCustomActions)
        XCTAssertEqual(actions.map { $0.name }, [TesseraStartScreenStrings.string(.a11yActionRenameFolder)])
        XCTAssertNil(fixture.grid.expandedFolderID)

        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.actionHandler?(action), true)
        XCTAssertTrue(fixture.host.waitUntil(timeout: 3) { fixture.grid.isEditingFolderName })
        XCTAssertEqual(fixture.grid.expandedFolderID, "F")

        fixture.grid.commitFolderNameEditing()
        fixture.grid.folderRenameHandler = nil
        XCTAssertNil(try XCTUnwrap(fixture.host.cell("F")).accessibilityCustomActions)
    }

    /// Обычная плитка-ярлык действия «Переименовать» не получает.
    func testTilesHaveNoRenameAction() throws {
        let tile = tesseraTestTile("t", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(tile), .folder(tesseraTestFolder("F"))])
        host.grid.folderRenameHandler = { _, _ in }
        XCTAssertNil(host.cell("t")?.accessibilityCustomActions)
        XCTAssertNotNil(host.cell("F")?.accessibilityCustomActions)
    }

    // MARK: - Строки

    /// Новые строки есть в en и ru и различаются.
    func testStringsExistInBothLanguages() {
        for key in [TesseraStartScreenStrings.Key.a11yActionRenameFolder, .folderNameFieldLabel] {
            let en = TesseraStartScreenStrings.string(key, language: "en")
            let ru = TesseraStartScreenStrings.string(key, language: "ru")
            XCTAssertNotEqual(en, key.rawValue)
            XCTAssertNotEqual(ru, key.rawValue)
            XCTAssertNotEqual(en, ru)
        }
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionRenameFolder, language: "en"), "Rename")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionRenameFolder, language: "ru"), "Переименовать")
        XCTAssertEqual(TesseraStartScreenStrings.string(.folderNameFieldLabel, language: "en"), "Folder name")
        XCTAssertEqual(TesseraStartScreenStrings.string(.folderNameFieldLabel, language: "ru"), "Имя папки")
    }

    // MARK: - Координатор

    private final class DelegateRecorder: TesseraTileEditCoordinatorDelegate {
        var renames: [(AnyHashable, String)] = []
        var events: [String] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didRenameFolder folderID: AnyHashable,
            to title: String
        ) {
            renames.append((folderID, title))
        }

        func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {
            events.append("begin")
        }

        func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {
            events.append("end")
        }
    }

    private func makeCoordinatorHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0
        )
    ) throws -> TesseraTestDragHost {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a0", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])],
            configuration: configuration
        )
        host.host.window.makeKeyAndVisible()
        return host
    }

    private func openPanel(_ host: TesseraTestDragHost) throws -> TesseraFolderPanelCell {
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        return try XCTUnwrap(host.host.panelCell(folderID: "F"))
    }

    /// Координатор ставит обработчик; правка имени в панели меняет `TesseraTileStore`,
    /// сетку и вызывает делегат один раз с итоговым именем; размер, ячейка и
    /// состав не меняются.
    func testCoordinatorHandlerRenamesStoreGridAndNotifiesDelegate() throws {
        let host = try makeCoordinatorHost()
        let delegate = DelegateRecorder()
        host.coordinator.delegate = delegate
        XCTAssertNotNil(host.host.grid.folderRenameHandler)
        let cellsBefore = host.store.snapshot(columns: 4).placementTable?.cells
        let panel = try openPanel(host)

        XCTAssertTrue(panel.beginTitleEditing())
        type("  Игры ", in: panel)
        pressReturn(in: panel)

        XCTAssertEqual(host.folders.first?.title, "Игры")
        XCTAssertEqual(host.host.grid.items.compactMap { $0.folder }.first?.title, "Игры")
        XCTAssertEqual(delegate.renames.count, 1)
        XCTAssertEqual(delegate.renames.first?.0, "F")
        XCTAssertEqual(delegate.renames.first?.1, "Игры")
        XCTAssertEqual(host.store.snapshot(columns: 4).placementTable?.cells, cellsBefore)
        XCTAssertEqual(host.folders.first?.size, .medium)
        XCTAssertEqual(host.folders.first?.tiles.count, 3)
        XCTAssertFalse(host.coordinator.isEditing, "Переименование не входит в режим редактирования")
    }

    /// Пустое имя возвращает имя по умолчанию: локализованное либо
    /// `folderTitle` конфигурации — как при создании папки.
    func testCoordinatorEmptyNameUsesDefaultOrConfiguredTitle() throws {
        let plain = try makeCoordinatorHost()
        XCTAssertTrue(plain.coordinator.renameFolder("F", to: "Работа"))
        XCTAssertTrue(plain.coordinator.renameFolder("F", to: "  "))
        XCTAssertEqual(plain.folders.first?.title, TesseraStartScreenStrings.string(.folderScreenDefaultTitle))

        let custom = try makeCoordinatorHost(
            configuration: TesseraTileEditConfiguration(folderTitle: "Мои")
        )
        XCTAssertTrue(custom.coordinator.renameFolder("F", to: "Работа"))
        XCTAssertTrue(custom.coordinator.renameFolder("F", to: ""))
        XCTAssertEqual(custom.folders.first?.title, "Мои")
    }

    /// Неизменённое и неизвестное имя — `false`, делегат не зовётся.
    func testCoordinatorRenameNoOpDoesNotNotifyDelegate() throws {
        let host = try makeCoordinatorHost()
        let delegate = DelegateRecorder()
        host.coordinator.delegate = delegate

        XCTAssertFalse(host.coordinator.renameFolder("F", to: "F"))
        XCTAssertFalse(host.coordinator.renameFolder("missing", to: "X"))
        XCTAssertTrue(delegate.renames.isEmpty)
    }

    /// Переименование работает и в режиме редактирования; вход в режим
    /// редактирования и выход из него фиксируют набираемое имя.
    func testEditModeTransitionsCommitName() throws {
        let host = try makeCoordinatorHost()
        let delegate = DelegateRecorder()
        host.coordinator.delegate = delegate
        host.coordinator.beginEditing()
        let panel = try openPanel(host)

        XCTAssertTrue(panel.beginTitleEditing(), "В правке переименование доступно")
        type("Игры", in: panel)
        host.coordinator.endEditing()
        XCTAssertEqual(host.folders.first?.title, "Игры", "Выход из правки фиксирует имя")
        XCTAssertFalse(host.host.grid.isEditingFolderName)

        let reopened = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertTrue(reopened.beginTitleEditing())
        type("Работа", in: reopened)
        host.coordinator.beginEditing()
        XCTAssertEqual(host.folders.first?.title, "Работа", "Вход в правку фиксирует имя")
        XCTAssertEqual(delegate.renames.map { $0.1 }, ["Игры", "Работа"])
    }

    /// Тап по фону сетки во время правки имени в режиме редактирования фиксирует
    /// имя; режим редактирования при этом остаётся (выход — отдельным тапом).
    func testBackgroundTapDuringRenameCommitsAndKeepsEditMode() throws {
        let host = try makeCoordinatorHost()
        host.coordinator.beginEditing()
        let panel = try openPanel(host)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Игры", in: panel)

        tapGridBackground(host.host.grid)
        XCTAssertEqual(host.folders.first?.title, "Игры")
        XCTAssertFalse(host.host.grid.isEditingFolderName)
        XCTAssertTrue(host.coordinator.isEditing, "Фиксация имени режим правки не завершает")
        XCTAssertEqual(host.host.grid.expandedFolderID, "F")
        host.coordinator.endEditing()
    }

    /// Выключенный координатор снимает обработчик (заголовок статичен) и
    /// фиксирует набираемое имя; включённый — возвращает.
    func testDisablingCoordinatorRemovesRenameHandler() throws {
        let host = try makeCoordinatorHost()
        let panel = try openPanel(host)
        XCTAssertTrue(panel.beginTitleEditing())
        type("Игры", in: panel)

        host.coordinator.isEnabled = false
        XCTAssertNil(host.host.grid.folderRenameHandler)
        XCTAssertEqual(host.folders.first?.title, "Игры", "Набранное зафиксировано до выключения")
        XCTAssertFalse(panel.isEditingTitle)
        XCTAssertFalse(panel.beginTitleEditing())

        host.coordinator.isEnabled = true
        XCTAssertNotNil(host.host.grid.folderRenameHandler)
        XCTAssertTrue(panel.beginTitleEditing())
        panel.endTitleEditing()
    }

    /// Действие «Переименовать» на плитке папки сосуществует с действиями
    /// редактора: редактор назначает и снимает свои (`= nil`), «Переименовать»
    /// остаётся и в правке, и после выхода из неё.
    func testRenameActionSurvivesEditorActionReconciliation() throws {
        let host = try makeCoordinatorHost()
        let renameName = TesseraStartScreenStrings.string(.a11yActionRenameFolder)
        XCTAssertEqual(actionNames(host, "F"), [renameName])

        host.coordinator.beginEditing()
        host.spin(0.1)
        let editing = actionNames(host, "F")
        XCTAssertTrue(editing.contains(TesseraStartScreenStrings.string(.a11yActionResize)), "Действия редактора на месте")
        XCTAssertEqual(editing.filter { $0 == renameName }.count, 1, "«Переименовать» — одно, без дублей")
        host.coordinator.endEditing()
        XCTAssertEqual(actionNames(host, "F"), [renameName])
    }

    private func actionNames(_ host: TesseraTestDragHost, _ id: AnyHashable) -> [String] {
        host.host.cell(id)?.accessibilityCustomActions?.map { $0.name } ?? []
    }

    // MARK: - Жесты

    /// Зона имени: вся строка заголовка открытой панели; ярлыки панели, фон и
    /// закрытая панель — не имя. Жесты сетки и координатора такие касания не принимают.
    func testNameHitZoneIsHeaderOnly() throws {
        let host = try makeCoordinatorHost()
        let panel = try openPanel(host)
        let grid = host.host.grid
        let header = panel.titleHeaderLabel.convert(panel.titleHeaderLabel.bounds, to: grid)
        XCTAssertTrue(grid.isFolderNameHit(at: CGPoint(x: header.midX, y: header.midY)))
        XCTAssertTrue(grid.isFolderNameHit(at: CGPoint(x: header.minX + 4, y: header.midY)))

        let geometry = try XCTUnwrap(grid.panelShortcutGeometry())
        let tileFrame = geometry.frames[0]
        XCTAssertFalse(grid.isFolderNameHit(at: CGPoint(x: tileFrame.midX, y: tileFrame.midY)))
        XCTAssertFalse(grid.isFolderNameHit(at: CGPoint(x: header.midX, y: grid.bounds.height - 5)))

        grid.closeFolder(animated: false)
        XCTAssertFalse(grid.isFolderNameHit(at: CGPoint(x: header.midX, y: header.midY)), "Панель закрыта")
    }

    /// Долгое нажатие по имени не входит в правку и не начинает drag: касание
    /// в зоне имени жест координатора не принимает, а само нажатие запускает
    /// правку имени. Долгое нажатие по ярлыку панели по-прежнему выносит его.
    func testNameLongPressDoesNotDragAndTileLongPressStillDragsOut() throws {
        let host = try makeCoordinatorHost()
        host.coordinator.beginEditing()
        let panel = try openPanel(host)
        let grid = host.host.grid
        let panelItem = try XCTUnwrap(grid.displayItems.first { $0.isFolderPanel })

        // Долгое нажатие по имени: правка имени, drag нет.
        XCTAssertTrue(panel.beginTitleEditing())
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.coordinator.isEditing)
        panel.endTitleEditing()

        // Долгое нажатие по ярлыку панели в правке — drag из папки.
        let geometry = try XCTUnwrap(grid.panelShortcutGeometry())
        let frame = geometry.frames[1]
        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.coordinator.endEditing()
    }
}

#endif
