//
//  TileFolderReorderTests.swift
//  TesseraStartScreenTests
//
//  Перестановка ярлыков внутри папки: модель, координатор, VoiceOver (E16.1,
//  D40, 13.11.2026; W10M §6.5). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  «Отступления реализации (E16)», п. 65; решение D40 в docs/STATE.md.
//
//  Проверяется:
//  - `TileStore.moveWithinFolder(_:folderID:toIndex:)`: вперёд/назад, ужатие
//    индекса, no-op (без `onChange` и записи), чужие идентификаторы, круг записи,
//    одно уведомление, ячейки и размеры не меняются, одобрение хоста не
//    спрашивается, невидимые члены (до регистрации каталога);
//  - `TesseraTileEditCoordinator.moveWithinFolder(_:to:)`: сетка и панель
//    показывают новый порядок, делегат `didReorderTile` ровно один раз, фокус
//    VoiceOver на ярлыке в его новой ячейке панели;
//  - custom actions «Переместить раньше/позже» на ярлыках панели: наличие у
//    первого/среднего/последнего, действие, строки en/ru.
//
//  Раскладки точные (`TileStoreCellFixture`), 6 колонок для модели, 4 для сетки.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderReorderTests: XCTestCase {

    private let columns = 6
    private let folderID: AnyHashable = "F"

    // MARK: - Помощники модели

    /// Папка F (medium, (0,0)) из `contents` и плитка `a` справа от неё.
    private func makeStore(
        contents: [(String, TileSize)] = [("x", .small), ("y", .small), ("z", .small), ("w", .small)],
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) throws -> TileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [CellFixtureTile("a", .small, 0, 4)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)],
            in: directory,
            autosaves: autosaves
        )
    }

    private func order(_ store: TileStore, folder: AnyHashable = "F") -> [AnyHashable] {
        store.snapshot().folders.first { $0.id == folder }?.tiles.map { $0.id } ?? []
    }

    /// Считает уведомления `onChange` и запоминает порядок папки в каждом.
    private final class ChangeRecorder {
        var orders: [[AnyHashable]] = []
    }

    private func record(_ store: TileStore) -> ChangeRecorder {
        let recorder = ChangeRecorder()
        store.onChange = { snapshot in
            recorder.orders.append(snapshot.folders.first?.tiles.map { $0.id } ?? [])
        }
        return recorder
    }

    // MARK: - Модель: перестановка

    /// Ярлык идёт вперёд: порядок папки в снимке, `folderContaining` и превью.
    func testMoveForwardReordersFolder() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)

        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 2))

        XCTAssertEqual(order(store), ["y", "z", "x", "w"] as [AnyHashable])
        XCTAssertEqual(store.folderContaining("x")?.tiles.map { $0.id }, ["y", "z", "x", "w"] as [AnyHashable])
    }

    /// Ярлык идёт назад.
    func testMoveBackwardReordersFolder() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)

        XCTAssertTrue(store.moveWithinFolder("w", folderID: "F", toIndex: 1))

        XCTAssertEqual(order(store), ["x", "w", "y", "z"] as [AnyHashable])
    }

    /// Индекс вне границ ужимается к границе.
    func testIndexIsClamped() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)

        XCTAssertTrue(store.moveWithinFolder("y", folderID: "F", toIndex: -7))
        XCTAssertEqual(order(store), ["y", "x", "z", "w"] as [AnyHashable])

        XCTAssertTrue(store.moveWithinFolder("y", folderID: "F", toIndex: 99))
        XCTAssertEqual(order(store), ["x", "z", "w", "y"] as [AnyHashable])

        // Ужатие до текущей позиции — no-op.
        XCTAssertFalse(store.moveWithinFolder("y", folderID: "F", toIndex: 42))
        XCTAssertEqual(order(store), ["x", "z", "w", "y"] as [AnyHashable])
    }

    /// Папка из двух ярлыков: перестановка — обмен.
    func testTwoTileFolderSwaps() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(contents: [("x", .small), ("y", .small)], in: directory)

        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
        XCTAssertEqual(order(store), ["y", "x"] as [AnyHashable])
        XCTAssertFalse(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
    }

    // MARK: - Модель: no-op и чужие идентификаторы

    /// Та же позиция — `false`, без `onChange` и без записи файла.
    func testSamePositionIsNoOpWithoutNotificationOrSave() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)
        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
        try FileManager.default.removeItem(at: store.fileURL)
        let recorder = record(store)

        XCTAssertFalse(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
        XCTAssertFalse(store.moveWithinFolder("y", folderID: "F", toIndex: 0))

        XCTAssertTrue(recorder.orders.isEmpty, "Ни одного onChange")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "Ничего не записано")
        XCTAssertEqual(order(store), ["y", "x", "z", "w"] as [AnyHashable])
    }

    /// Неизвестная папка, неизвестный ярлык, ярлык не из этой папки, плитка сетки
    /// вместо папки — `false`, модель не меняется.
    func testUnknownIdentifiersAreNoOps() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [CellFixtureTile("a", .small, 0, 4)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
                CellFixtureFolder("G", .medium, 2, 0, contents: [("p", .small), ("q", .small)]),
            ],
            in: directory
        )
        let recorder = record(store)

        XCTAssertFalse(store.moveWithinFolder("x", folderID: "nope", toIndex: 1), "Папки нет")
        XCTAssertFalse(store.moveWithinFolder("nope", folderID: "F", toIndex: 1), "Ярлыка нет")
        XCTAssertFalse(store.moveWithinFolder("p", folderID: "F", toIndex: 1), "Ярлык из другой папки")
        XCTAssertFalse(store.moveWithinFolder("a", folderID: "F", toIndex: 1), "Ярлык с рабочего стола")
        XCTAssertFalse(store.moveWithinFolder("x", folderID: "a", toIndex: 1), "Плитка вместо папки")

        XCTAssertTrue(recorder.orders.isEmpty)
        XCTAssertEqual(order(store, folder: "F"), ["x", "y"] as [AnyHashable])
        XCTAssertEqual(order(store, folder: "G"), ["p", "q"] as [AnyHashable])
    }

    // MARK: - Модель: персистентность и побочные эффекты

    /// Круг записи: порядок переживает перезапуск; превью и снимок показывают его.
    func testOrderSurvivesRoundTrip() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)

        XCTAssertTrue(store.moveWithinFolder("w", folderID: "F", toIndex: 0))
        XCTAssertEqual(order(store), ["w", "x", "y", "z"] as [AnyHashable])

        let fresh = TileStore(directoryURL: directory.url)
        fresh.setCatalog(["a", "x", "y", "z", "w"].map { tesseraTestTile($0, size: .small) })
        try fresh.load()
        XCTAssertEqual(order(fresh), ["w", "x", "y", "z"] as [AnyHashable], "Порядок в файле")
        XCTAssertEqual(
            fresh.snapshot().folders.first?.tiles.map { $0.id },
            store.snapshot().folders.first?.tiles.map { $0.id }
        )
        XCTAssertEqual(fresh.placements, store.placements)
    }

    /// Одно уведомление `onChange`, и снимок в нём уже с новым порядком.
    func testExactlyOneChangeWithNewOrder() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let recorder = record(store)

        XCTAssertTrue(store.moveWithinFolder("z", folderID: "F", toIndex: 0))

        XCTAssertEqual(recorder.orders.count, 1)
        XCTAssertEqual(recorder.orders.first, ["z", "x", "y", "w"] as [AnyHashable])
    }

    /// Ячейки и размеры верхнего уровня и самих ярлыков не меняются.
    func testPlacementsAndSizesAreUntouched() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(
            contents: [("x", .small), ("y", .wide), ("z", .medium)],
            in: directory
        )
        let placements = store.placements
        let sizes = Dictionary(uniqueKeysWithValues: store.snapshot().items.map { ($0.id, $0.size) })
        let tileSizes = Dictionary(
            uniqueKeysWithValues: (store.snapshot().folders.first?.tiles ?? []).map { ($0.id, $0.size) }
        )

        XCTAssertTrue(store.moveWithinFolder("z", folderID: "F", toIndex: 0))

        XCTAssertEqual(store.placements, placements)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.snapshot().items.map { ($0.id, $0.size) }), sizes)
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: (store.snapshot().folders.first?.tiles ?? []).map { ($0.id, $0.size) }
            ),
            tileSizes
        )
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "x", "y", "z"])
    }

    /// Одобрение хоста (D14) не спрашивается: состав папки не меняется.
    func testApprovalIsNotAsked() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        var asked = 0
        store.approval = { _, _, _ in
            asked += 1
            return false
        }

        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 3))

        XCTAssertEqual(asked, 0)
        XCTAssertEqual(order(store), ["y", "z", "w", "x"] as [AnyHashable])
    }

    /// Невидимые члены (файл прочитан до регистрации каталога): без каталога
    /// перестановка отказывает; после регистрации работает по видимым ярлыкам.
    func testInvisibleMembersBeforeCatalogRegistration() throws {
        let directory = TesseraTestDirectory()
        let source = try makeStore(in: directory, autosaves: true)
        try source.save()

        let fresh = TileStore(directoryURL: directory.url)
        try fresh.load()
        XCTAssertFalse(
            fresh.moveWithinFolder("x", folderID: "F", toIndex: 2),
            "Каталога нет: видимых ярлыков в папке нет"
        )

        fresh.setCatalog(["a", "x", "y", "z", "w"].map { tesseraTestTile($0, size: .small) })
        XCTAssertTrue(fresh.moveWithinFolder("x", folderID: "F", toIndex: 2))
        XCTAssertEqual(order(fresh), ["y", "z", "x", "w"] as [AnyHashable])
    }

    // MARK: - Помощники координатора

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var reorders: [(tile: AnyHashable, folder: AnyHashable, index: Int)] = []
        var grouping: [TileGroupingAction] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didReorderTile tileID: AnyHashable,
            inFolder folderID: AnyHashable,
            toIndex index: Int
        ) {
            reorders.append((tileID, folderID, index))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            grouping.append(action)
        }
    }

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func makeHost(
        contents: [(String, TileSize)] = [("x", .small), ("y", .small), ("z", .small)]
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)]
        )
    }

    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == self.folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        })
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    // MARK: - Координатор

    /// Публичный метод: модель, сетка с закрытой панелью, делегат ровно раз.
    func testCoordinatorMoveUpdatesModelGridAndDelegate() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.moveWithinFolder("x", to: 2))

        XCTAssertEqual(order(host.store), ["y", "z", "x"] as [AnyHashable])
        XCTAssertEqual(
            host.host.grid.snapshot?.folders.first?.tiles.map { $0.id },
            ["y", "z", "x"] as [AnyHashable],
            "Сетка показывает новый порядок"
        )
        XCTAssertEqual(recorder.reorders.count, 1)
        XCTAssertEqual(recorder.reorders.first?.tile, "x")
        XCTAssertEqual(recorder.reorders.first?.folder, "F")
        XCTAssertEqual(recorder.reorders.first?.index, 2)
        XCTAssertTrue(recorder.grouping.isEmpty, "Одобрение хоста не спрашивалось")
    }

    /// Ужатие индекса: делегат получает фактический индекс.
    func testCoordinatorReportsClampedIndex() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.moveWithinFolder("x", to: 50))

        XCTAssertEqual(recorder.reorders.first?.index, 2)
    }

    /// No-op и неизвестный ярлык: `false`, делегат молчит, сетка не меняется.
    func testCoordinatorNoOpAndUnknownTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertFalse(host.coordinator.moveWithinFolder("x", to: 0), "Позиция та же")
        XCTAssertFalse(host.coordinator.moveWithinFolder("a", to: 0), "Ярлык не в папке")
        XCTAssertFalse(host.coordinator.moveWithinFolder("nope", to: 0))

        XCTAssertTrue(recorder.reorders.isEmpty)
        XCTAssertEqual(order(host.store), ["x", "y", "z"] as [AnyHashable])
    }

    /// Открытая панель переконфигурируется на месте: ярлыки в слотах идут в новом
    /// порядке, превью-иконки закрытой папки тоже.
    func testOpenPanelShowsNewOrder() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ["x", "y", "z"] as [AnyHashable?])

        XCTAssertTrue(host.coordinator.moveWithinFolder("z", to: 0))

        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ["z", "x", "y"] as [AnyHashable?], "Тот же вид панели")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID, "Панель осталась открытой")
        XCTAssertEqual(host.host.grid.snapshot?.folders.first?.tiles.map { $0.id }, ["z", "x", "y"] as [AnyHashable])
    }

    /// Фокус VoiceOver остаётся на переставленном ярлыке — в его новой ячейке панели.
    func testFocusStaysOnMovedTileInNewPanelCell() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let posts = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.posts.append((notification, argument))
        }

        XCTAssertTrue(host.coordinator.moveWithinFolder("x", to: 2))

        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        let post = try XCTUnwrap(posts.posts.last)
        XCTAssertEqual(post.0, .layoutChanged)
        let focused = try XCTUnwrap(post.1 as? TesseraTileCell)
        XCTAssertTrue(focused === panel.shortcutCells[2], "Новая ячейка панели")
        XCTAssertEqual(focused.itemID, "x")
    }

    /// Во время drag публичная перестановка отказывает (модель сессии не меняется).
    func testCoordinatorRefusesDuringDrag() throws {
        let host = try makeHost()
        host.coordinator.beginEditing()
        XCTAssertTrue(host.startDrag("a"))

        XCTAssertFalse(host.coordinator.moveWithinFolder("x", to: 2))
        XCTAssertEqual(order(host.store), ["x", "y", "z"] as [AnyHashable])

        host.coordinator.finishDrag(commit: false)
        host.coordinator.endEditing()
    }

    // MARK: - VoiceOver: custom actions

    private func actionNames(of cell: TesseraTileCell) -> [String] {
        (cell.accessibilityCustomActions ?? []).map { $0.name }
    }

    private func action(_ name: String, of cell: TesseraTileCell) -> UIAccessibilityCustomAction? {
        cell.accessibilityCustomActions?.first { $0.name == name }
    }

    private var earlier: String { TesseraStartScreenStrings.string(.a11yActionMoveEarlier) }
    private var later: String { TesseraStartScreenStrings.string(.a11yActionMoveLater) }

    /// У первого ярлыка нет «раньше», у последнего — «позже», у среднего оба.
    func testMoveActionsPresenceAtFirstMiddleLast() throws {
        let host = try makeHost()
        let panel = try openPanel(host)

        let first = actionNames(of: panel.shortcutCells[0])
        XCTAssertFalse(first.contains(earlier))
        XCTAssertTrue(first.contains(later))

        let middle = actionNames(of: panel.shortcutCells[1])
        XCTAssertTrue(middle.contains(earlier))
        XCTAssertTrue(middle.contains(later))

        let last = actionNames(of: panel.shortcutCells[2])
        XCTAssertTrue(last.contains(earlier))
        XCTAssertFalse(last.contains(later))
    }

    /// «Позже» двигает ярлык на одну позицию; «раньше» — обратно; делегат слышит.
    func testMoveActionsMoveByOnePosition() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)

        let moveLater = try XCTUnwrap(action(later, of: panel.shortcutCells[0]))
        XCTAssertEqual(moveLater.actionHandler?(moveLater), true)
        XCTAssertEqual(order(host.store), ["y", "x", "z"] as [AnyHashable])
        XCTAssertEqual(recorder.reorders.last?.index, 1)

        // Отложенная сверка обновляет действия по новому положению.
        XCTAssertTrue(host.waitUntil {
            self.actionNames(of: panel.shortcutCells[0]).contains(self.later)
                && !self.actionNames(of: panel.shortcutCells[0]).contains(self.earlier)
                && self.actionNames(of: panel.shortcutCells[1]).contains(self.earlier)
        })
        let moveEarlier = try XCTUnwrap(action(earlier, of: panel.shortcutCells[1]))
        XCTAssertEqual(moveEarlier.actionHandler?(moveEarlier), true)
        XCTAssertEqual(order(host.store), ["x", "y", "z"] as [AnyHashable])
        XCTAssertEqual(recorder.reorders.count, 2)
    }

    /// После ухода ярлыка из папки набор действий пересчитывается: у нового
    /// последнего ярлыка «позже» пропадает.
    func testMoveActionsRefreshAfterFolderShrinks() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small), ("w", .small)])
        let panel = try openPanel(host)
        XCTAssertTrue(actionNames(of: panel.shortcutCells[2]).contains(later))

        host.coordinator.unpin("w")
        XCTAssertTrue(host.waitUntil { host.store.folderContaining("x")?.tiles.count == 3 })
        XCTAssertTrue(host.waitUntil {
            !self.actionNames(of: panel.shortcutCells[2]).contains(self.later)
        }, "У нового последнего ярлыка «позже» нет")
    }

    /// Папка из двух ярлыков: у первого только «позже», у второго только «раньше».
    func testMoveActionsInTwoTileFolder() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small)])
        let panel = try openPanel(host)

        XCTAssertEqual(
            [earlier, later].filter { actionNames(of: panel.shortcutCells[0]).contains($0) },
            [later]
        )
        XCTAssertEqual(
            [earlier, later].filter { actionNames(of: panel.shortcutCells[1]).contains($0) },
            [earlier]
        )
    }

    /// Вне режима редактирования действий нет.
    func testNoMoveActionsOutsideEditing() throws {
        let host = try makeHost()
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        host.spin(0.05)

        for cell in panel.shortcutCells {
            XCTAssertFalse(actionNames(of: cell).contains(earlier))
            XCTAssertFalse(actionNames(of: cell).contains(later))
        }
    }

    // MARK: - Строки en/ru

    func testMoveStringsExistInBothLanguages() {
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveEarlier, language: "en"), "Move earlier")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveLater, language: "en"), "Move later")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveEarlier, language: "ru"), "Переместить раньше")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveLater, language: "ru"), "Переместить позже")
        for language in ["en", "ru"] {
            let format = TesseraStartScreenStrings.string(.a11yFolderTilePositionFormat, language: language)
            XCTAssertTrue(String(format: format, 2, 5).contains("2"), format)
            XCTAssertTrue(String(format: format, 2, 5).contains("5"), format)
        }
    }
}

#endif
