//
//  TileFolderDissolveUITests.swift
//  TesseraStartScreenTests
//
//  Папка не бывает из 0–1 ярлыков: координатор и сетка (E14.8, D45,
//  13.11.2026). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления
//  реализации (E14)», п. 56; решения D45 в docs/STATE.md.
//
//  Проверяется на настоящем `TileStore` и сетке в окне (`TesseraTestDragHost`):
//  - unpin ярлыка раскрытой панели в папке из двух ярлыков: панель закрывается,
//    оставшийся ярлык встаёт на место папки, фокус VoiceOver — на него;
//  - unpin в папке из трёх: панель остаётся, фокус — на следующем ярлыке панели,
//    у последнего — на предыдущем; панель закрыта — на плитке папки;
//  - VoiceOver-действие «Открепить» на ярлыке панели;
//  - публичный `moveBetweenFolders(_:to: nil)` распускает папку из двух;
//  - drag из папки в два ярлыка: превью цели-размещения показывает итог (папка
//    заменена оставшимся ярлыком), над слиянием/родной папкой — база; drop кладёт
//    ярлыки ровно туда, где показало превью; отмена и отказ хоста возвращают
//    папку; drop на центр другой папки распускает источник;
//  - делегат: `didDissolveFolder` после основного колбэка, один раз.
//
//  Раскладки точные (`TileStoreCellFixture`), 4 колонки; без `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderDissolveUITests: XCTestCase {

    // MARK: - Помощники

    /// Делегат, пишущий события одной лентой: порядок важен.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// События: `unpin:id`, `move:id>папка|nil@ячейка`, `dissolve:папка>ярлык`.
        var events: [String] = []

        /// Отказы функции одобрения.
        var failures: [TileGroupingAction] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            events.append("unpin:\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TileGridPlacement?
        ) {
            let target = folderID.map { "\($0)" } ?? "nil"
            let at = cell.map { "(\($0.row),\($0.column))" } ?? "-"
            events.append("move:\(tileID)>\(target)@\(at)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            events.append("dissolve:\(folderID)>\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            failures.append(action)
        }
    }

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func record(_ host: TesseraTestDragHost) -> PostRecorder {
        let recorder = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            recorder.posts.append((notification, argument))
        }
        return recorder
    }

    private func at(_ row: Int, _ column: Int) -> TileGridPlacement {
        TileGridPlacement(row: row, column: column)
    }

    /// Фокус последнего поста — на заданном виде.
    private func assertFocus(
        _ recorder: PostRecorder,
        on view: UIView?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(recorder.posts.last?.0, UIAccessibility.Notification.layoutChanged, file: file, line: line)
        XCTAssertNotNil(view, "цель фокуса существует: \(message)", file: file, line: line)
        XCTAssertTrue((recorder.posts.last?.1 as? UIView) === view, message, file: file, line: line)
    }

    /// Входит в edit и раскрывает панель папки без анимации.
    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost, folderID: AnyHashable) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        }, "Действия ярлыков панели выставлены отложенной сверкой")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    /// Долгое нажатие по иконке панели: drag ярлыка из папки.
    private func startPanelDrag(_ host: TesseraTestDragHost, folderID: AnyHashable, iconIndex: Int) throws {
        try openPanel(host, folderID: folderID)
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        // E16.1: вход сразу в вынос (долгое нажатие по панели начинает перестановку).
        host.coordinator.startDragFromPanel(at: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
    }

    /// Рамка элемента в **базовой** раскладке drag-сессии (координаты сетки): рамки
    /// самой сетки сразу после подъёма ещё едут за batch-анимацией отображаемого снимка.
    private func baseFrame(_ host: TesseraTestDragHost, _ id: AnyHashable) throws -> CGRect {
        let session = try XCTUnwrap(host.coordinator.dragSession)
        let content = try XCTUnwrap(host.host.grid.baseContentFrames(
            for: session.baseSnapshot.items,
            placementTable: session.baseSnapshot.placementTable
        ))
        return host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[id]))
    }

    private func basePoint(_ host: TesseraTestDragHost, _ id: AnyHashable) throws -> CGPoint {
        let frame = try baseFrame(host, id)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func settle(_ host: TesseraTestDragHost, _ id: AnyHashable) {
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "Сетка = модель")
        XCTAssertTrue(host.waitForDragCleanup(id))
        XCTAssertNil(host.coordinator.dragSession)
    }

    private func assertFrame(
        _ actual: CGRect?,
        _ expected: CGRect?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual, let expected else {
            return XCTFail("Нет рамки: \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    /// Стенд: папка F (medium, (0,0)) из `contents`, плитки `a` (0,3) и `b` (2,3).
    private func makeHost(
        contents: [(String, TileSize)] = [("x", .small), ("y", .medium)],
        extraFolders: [CellFixtureFolder] = []
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("b", .small, 2, 3)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)] + extraFolders
        )
    }

    // MARK: - Unpin в панели

    /// Папка из двух: unpin ярлыка раскрытой панели закрывает панель (анимированно),
    /// оставшийся ярлык встаёт на место папки, фокус — на него; делегат получает
    /// `didUnpin`, затем `didDissolveFolder`.
    func testUnpinInsideTwoTileFolderPanelClosesAndFocusesRemainingTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host, folderID: "F")
        let folderCell = try XCTUnwrap(host.store.placement(of: "F"))

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty }, "фокус опубликован")
        XCTAssertTrue(host.waitForFolderTransitionDone())

        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertFalse(host.gridIDs.contains("F"), "Плитки папки на сетке нет")
        XCTAssertEqual(host.store.placement(of: "y"), folderCell, "Оставшийся ярлык — на ячейке папки")
        XCTAssertEqual(host.store.snapshot().item(withID: "y")?.size, .medium)
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        assertFocus(posts, on: host.host.cell("y"), "фокус — на оставшемся ярлыке (новый элемент сетки)")
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
        XCTAssertFalse(host.store.isPinned("x"))
        host.coordinator.endEditing()
    }

    /// Reduce Motion: панель закрывается мгновенно, результат тот же.
    func testUnpinInsideTwoTileFolderWithReduceMotionClosesPanelInstantly() throws {
        let host = try makeHost()
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        let posts = record(host)
        try openPanel(host, folderID: "F")

        host.coordinator.unpin("y")
        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта сразу")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertTrue(host.folders.isEmpty)
        assertFocus(posts, on: host.host.cell("x"), "фокус — на оставшемся ярлыке")
        host.coordinator.endEditing()
    }

    /// Папка из трёх: панель остаётся, фокус — на следующем ярлыке панели.
    func testUnpinInsideThreeTileFolderKeepsPanelAndFocusesNextTile() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host, folderID: "F")

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertEqual(host.host.grid.expandedFolderID, "F", "Панель осталась")
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["y", "z"] as [AnyHashable])
        let panel = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertEqual(panel.shortcutCells.count, 2)
        assertFocus(posts, on: panel.shortcutCells[0], "следующий после «x» — «y» (первый в панели)")
        XCTAssertEqual(recorder.events, ["unpin:x"], "Папка не распалась — события распада нет")
        host.coordinator.endEditing()
    }

    /// Последний ярлык панели: фокус — на предыдущем; средний — на следующем.
    func testUnpinInsideThreeTileFolderFocusesPreviousForLastAndNextForMiddle() throws {
        let last = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let lastPosts = record(last)
        try openPanel(last, folderID: "F")
        last.coordinator.unpin("z")
        XCTAssertTrue(last.waitUntil { !lastPosts.posts.isEmpty })
        let lastPanel = try XCTUnwrap(last.host.panelCell(folderID: "F"))
        XCTAssertEqual(last.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable])
        assertFocus(lastPosts, on: lastPanel.shortcutCells[1], "у последнего — предыдущий «y»")

        let middle = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let middlePosts = record(middle)
        try openPanel(middle, folderID: "F")
        middle.coordinator.unpin("y")
        XCTAssertTrue(middle.waitUntil { !middlePosts.posts.isEmpty })
        let middlePanel = try XCTUnwrap(middle.host.panelCell(folderID: "F"))
        assertFocus(middlePosts, on: middlePanel.shortcutCells[1], "следующий после «y» — «z», теперь второй")
        last.coordinator.endEditing()
        middle.coordinator.endEditing()
    }

    /// Панель закрыта: фокус — на плитке папки (на отсутствующую ячейку не уходит).
    func testUnpinInsideClosedThreeTileFolderFocusesFolderTile() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let posts = record(host)

        host.coordinator.unpin("y")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "z"] as [AnyHashable])
        assertFocus(posts, on: host.host.cell("F"), "панели нет — фокус на плитке папки")
    }

    /// Закрытая папка из двух: распад без панели — фокус на оставшемся ярлыке.
    func testUnpinInsideClosedTwoTileFolderFocusesRemainingTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertTrue(host.folders.isEmpty)
        assertFocus(posts, on: host.host.cell("y"), "оставшийся ярлык")
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
    }

    /// VoiceOver-действие «Открепить» на ярлыке панели идёт тем же маршрутом.
    func testVoiceOverUnpinActionOnPanelTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        let panel = try openPanel(host, folderID: "F")
        let unpinName = TesseraStartScreenStrings.string(.a11yActionUnpin)
        let actions = panel.shortcutCells[0].accessibilityCustomActions ?? []
        XCTAssertTrue(actions.contains { $0.name == unpinName }, "действие «Открепить» на ярлыке панели")
        let unpin = try XCTUnwrap(actions.first { $0.name == unpinName })

        XCTAssertEqual(unpin.actionHandler?(unpin), true)
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
        host.coordinator.endEditing()
    }

    // MARK: - Публичный вынос без жеста

    /// `moveBetweenFolders(_:to: nil)` на папке из двух: панель закрывается,
    /// оставшийся ярлык — на месте папки, вынесенный — на первой свободной ячейке
    /// после неё; `didMove`, затем `didDissolveFolder`; фокус — на вынесенном.
    func testPublicMoveToDesktopDissolvesTwoTileFolder() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small)])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host, folderID: "F")

        XCTAssertTrue(host.coordinator.moveBetweenFolders("x", to: nil))
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        XCTAssertTrue(host.waitForFolderTransitionDone())

        XCTAssertNil(host.host.grid.expandedFolderID)
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placement(of: "y"), at(0, 0), "оставшийся — на ячейке папки")
        let moved = try XCTUnwrap(host.store.placement(of: "x"))
        XCTAssertNotEqual(moved, at(0, 0), "вынесенный не лёг на оставшегося")
        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertTrue(recorder.events.first?.hasPrefix("move:x>nil@") == true)
        XCTAssertEqual(recorder.events.last, "dissolve:F>y")
        assertFocus(posts, on: host.host.cell("x"), "фокус — на вынесенном ярлыке")
        host.coordinator.endEditing()
    }

    // MARK: - Drag из панели: превью

    /// Папка из двух: над клеткой-размещением превью показывает итог (папка заменена
    /// оставшимся ярлыком на её ячейке, вынесенный — на клетке), над родной папкой и
    /// слиянием — база (папка), отмена возвращает папку с обоими ярлыками.
    func testPreviewShowsDissolvedPictureOverCellAndBaseOverSourceFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        // Старт: база — папка с оставшимся ярлыком и синтетический ярлык.
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"))
        XCTAssertNil(host.host.grid.frame(forItemID: "y"), "оставшийся ярлык ещё внутри папки")
        XCTAssertEqual(host.store.snapshot().folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable])
        let baseFolderFrame = try baseFrame(host, "F")

        // Клетка-размещение (пустая клетка внутри занятых строк): итог.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(2, 1)))
        XCTAssertNil(host.host.grid.frame(forItemID: "F"), "Превью: папки нет")
        assertFrame(host.host.grid.frame(forItemID: "y"), baseFolderFrame, "Превью: оставшийся ярлык на ячейке папки")
        assertFrame(
            host.host.grid.frame(forItemID: "x"),
            host.cellFrame(row: 2, column: 1),
            "Превью: вынесенный ярлык на клетке"
        )
        XCTAssertEqual(host.store.snapshot().folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable], "Модель за время drag не меняется")

        // Над родной папкой — база.
        host.coordinator.updateDrag(to: try basePoint(host, "F"))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .sourceFolder)
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"), "Над родной папкой — база: папка на месте")
        XCTAssertNil(host.host.grid.frame(forItemID: "y"))

        // Снова на клетку — итог (превью считается от базы, без накопления).
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 2)))
        XCTAssertNil(host.host.grid.frame(forItemID: "F"))
        assertFrame(host.host.grid.frame(forItemID: "y"), baseFolderFrame, "оставшийся ярлык на месте")
        assertFrame(host.host.grid.frame(forItemID: "x"), host.cellFrame(row: 2, column: 2), "вынесенный на новой клетке")

        // Отмена: папка с обоими ярлыками, сетка = модель, события нет.
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable], "Папка восстановлена")
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"))
        XCTAssertNil(host.host.grid.frame(forItemID: "y"))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    /// Папка из трёх: превью цели-размещения папку не распускает.
    func testPreviewOfThreeTileFolderKeepsFolder() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))

        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(2, 1)))
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"), "Папка из трёх осталась")
        XCTAssertNil(host.host.grid.frame(forItemID: "y"))
        XCTAssertNil(host.coordinator.dragSession?.folderDissolution)
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
    }

    // MARK: - Drag из панели: drop

    /// Drop на пустую клетку: ярлыки встают ровно туда, где показало превью (кадры
    /// и таблица ячеек равны), папка распущена, делегат получает `didMove` и затем
    /// `didDissolveFolder`.
    func testDropOnHoleCommitsPreviewAndDissolvesFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(2, 1)))
        let previewCells = try XCTUnwrap(host.gridCells)
        let previewY = try XCTUnwrap(host.host.grid.frame(forItemID: "y"))
        let previewX = try XCTUnwrap(host.host.grid.frame(forItemID: "x"))
        XCTAssertEqual(changes, 0, "Во время drag модель не пишется")

        host.coordinator.finishDrag(commit: true)
        settle(host, "x")

        XCTAssertEqual(changes, 1, "Одно уведомление за операцию")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placements(forColumns: 4), previewCells, "Модель = превью")
        assertFrame(host.host.grid.frame(forItemID: "y"), previewY, "оставшийся ярлык там, где показало превью")
        assertFrame(host.host.grid.frame(forItemID: "x"), previewX, "вынесенный ярлык там, где показало превью")
        XCTAssertEqual(host.store.placement(of: "x"), at(2, 1))
        XCTAssertEqual(host.store.placement(of: "y"), at(0, 0))
        XCTAssertEqual(recorder.events, ["move:x>nil@(2,1)", "dissolve:F>y"])
    }

    /// Drop на край родной папки: вынесенный ярлык занимает ячейку папки, оставшийся
    /// вытесняется вниз (обычные правила размещения) — модель равна превью.
    func testDropOnSourceFolderEdgeMatchesPreview() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small)])
        try startPanelDrag(host, folderID: "F", iconIndex: 0)
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "F"))

        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 0)))
        let previewCells = try XCTUnwrap(host.gridCells)
        host.coordinator.finishDrag(commit: true)
        settle(host, "x")

        XCTAssertEqual(host.store.placement(of: "x"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "y"), at(1, 0), "оставшийся вытеснен вниз")
        XCTAssertEqual(host.store.placements(forColumns: 4), previewCells, "Модель = превью")
        XCTAssertTrue(host.folders.isEmpty)
    }

    /// Drop на центр другой папки (после удержания): источник распущен, цель получила
    /// ярлык; делегат: `didMove`, затем `didDissolveFolder`.
    func testDropOnOtherFolderDissolvesSourceFolder() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
                CellFixtureFolder("G", .medium, 3, 0, contents: [("p", .small), ("q", .small)]),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try basePoint(host, "G"))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("G"))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })

        XCTAssertEqual(host.folders.map { $0.id }, ["G"] as [AnyHashable])
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["p", "q", "x"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "y"), at(0, 0), "оставшийся ярлык — на месте F")
        XCTAssertEqual(recorder.events, ["move:x>G@-", "dissolve:F>y"])
    }

    /// Хост отказал в выносе: модель не менялась, папка возвращена, распада нет.
    func testHostRejectionRestoresFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .moveBetweenFolders }
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))
        XCTAssertNil(host.host.grid.frame(forItemID: "F"), "в превью папка уже распущена")
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })

        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable], "Папка восстановлена")
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"))
        XCTAssertEqual(recorder.failures, [.moveBetweenFolders])
        XCTAssertFalse(recorder.events.contains { $0.hasPrefix("dissolve") })
    }

    /// Новая строка: превью считается с оставшимся ярлыком на месте папки.
    func testDropToNewRowMatchesPreview() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .large)])
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 3))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        let previewCells = try XCTUnwrap(host.gridCells)
        host.coordinator.finishDrag(commit: true)
        settle(host, "x")

        XCTAssertEqual(host.store.placements(forColumns: 4), previewCells, "Модель = превью")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.snapshot().item(withID: "y")?.size, .large)
    }
}

private extension TesseraTestDragHost {

    /// Ждёт, пока панель папки закончит переход и сетка применит отложенный снимок.
    func waitForFolderTransitionDone() -> Bool {
        host.waitForFolderTransition() && waitUntil { self.gridIDs == self.storeIDs }
    }
}

#endif
