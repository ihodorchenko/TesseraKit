//
//  TileCellDragTests.swift
//  TesseraStartScreenTests
//
//  Drag по ячейкам: цель — клетка под пальцем, превью от базовых размещений,
//  фиксация drop'а операциями `TesseraTileStore` по ячейкам (E14.5, 13.11.2026).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации
//  (E14)», п. 53; решения D20, D21, D22, D30–D33 в docs/STATE.md.
//
//  Приёмочные сценарии пользователя:
//  - A: ярлык, вынесенный из панели папки (или протащенный по сетке) и
//    отпущенный над ПУСТОЙ клеткой, ложится ровно в неё, а не в самую верхнюю дыру;
//  - B: пока палец над центром плитки/папки (`.group`/`.folder`), превью — базовая
//    раскладка: цель остаётся под пальцем, подсветка рисуется на ней;
//  - C: папка из ярлыка 1×1 встаёт на ячейку цели размером 2×2, соседи выталкиваются
//    вниз, а не отправляются далеко вниз со случайными дырами.
//
//  Раскладки точные: файл схемы версии 2 с дырами (`TileStoreCellFixture`) и сетка
//  из `TesseraTileStore.snapshot(columns:)`, 4 колонки. Без `sleep`: завершение —
//  прокруткой run loop (`waitUntil`).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileCellDragTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Делегат-рекордер событий координатора.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Перестановки по сетке.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

        /// Вынос/перенос между папками.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?, cell: TesseraTileGridPlacement?)] = []

        /// Созданные папки.
        var createdFolders: [TesseraTileFolder] = []

        /// Добавления в папку.
        var additions: [(id: AnyHashable, folder: AnyHashable)] = []

        /// Отказы функции одобрения.
        var failures: [TesseraTileGroupingAction] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toCell cell: TesseraTileGridPlacement
        ) {
            moves.append((tileID, cell))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TesseraTileGridPlacement?
        ) {
            folderMoves.append((tileID, folderID, cell))
        }

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TesseraTileFolder) {
            createdFolders.append(folder)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didAdd tileID: AnyHashable,
            toFolder folderID: AnyHashable
        ) {
            additions.append((tileID, folderID))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TesseraTileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            failures.append(action)
        }
    }

    /// Ячейка в короткой записи.
    private func at(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    /// Шесть малых плиток: `a b c d` в строке 0, `e f` в строке 1.
    private func makeSixTilesHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0,
            reorderPreviewDwell: 0
        )
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 1),
                CellFixtureTile("c", .small, 0, 2),
                CellFixtureTile("d", .small, 0, 3),
                CellFixtureTile("e", .small, 1, 0),
                CellFixtureTile("f", .small, 1, 1),
            ],
            configuration: configuration
        )
    }

    /// Сравнивает рамки с точностью до долей точки (пиксельная сетка раскладки).
    private func assertFrame(
        _ actual: CGRect?,
        _ expected: CGRect?,
        _ message: String = "",
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

    /// Ждёт завершения drop'а: сессии нет, снимок убран, сетка совпала с моделью.
    private func settle(_ host: TesseraTestDragHost, _ id: AnyHashable, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, "Сессия завершена", file: file, line: line)
        XCTAssertTrue(host.waitForDragCleanup(id), "Ячейка снова видима", file: file, line: line)
        XCTAssertTrue(
            host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) },
            "Сетка показывает ячейки модели",
            file: file,
            line: line
        )
    }

    /// Входит в edit, раскрывает панель папки и берёт иконку панели (E11.1).
    private func startPanelDrag(
        _ host: TesseraTestDragHost,
        folderID: AnyHashable,
        iconIndex: Int
    ) throws {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        // E16.1: вход сразу в вынос (долгое нажатие по панели начинает перестановку).
        host.coordinator.startDragFromPanel(at: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
    }

    // MARK: - Сценарий A: пустая клетка, а не самая верхняя дыра

    /// Ярлык из панели папки, отпущенный над пустой областью справа от папки 2×2,
    /// когда следующая плитка широкая: ложится **ровно в клетку под пальцем**
    /// (1, 3), а не в самую верхнюю дыру (0, 2).
    func testScenarioAPanelTileReleasedOverEmptyCellNextToFolderLandsExactlyThere() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("w", .wide, 2, 0)],
            folders: [
                CellFixtureFolder(
                    "F", .medium, 0, 0,
                    contents: [("f1", .small), ("f2", .small), ("f3", .small)]
                ),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try startPanelDrag(host, folderID: "F", iconIndex: 2)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)), "Клетка под пальцем")

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")

        XCTAssertEqual(host.store.placement(of: "f3"), at(1, 3), "Ровно в клетку под пальцем")
        XCTAssertNotEqual(host.store.placement(of: "f3"), at(0, 2), "Не в верхнюю дыру")
        XCTAssertEqual(host.store.placement(of: "F"), at(0, 0), "Папка на месте")
        XCTAssertEqual(host.store.placement(of: "w"), at(2, 0), "Широкая плитка на месте")
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
        XCTAssertEqual(recorder.folderMoves.count, 1)
    }

    /// То же для drag по сетке: плитка, отпущенная над пустой клеткой (1, 3),
    /// ложится в неё, а не «подтягивается» в дыру (0, 3) выше.
    func testScenarioAGridTileReleasedOverEmptyCellLandsExactlyThere() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 1),
                CellFixtureTile("c", .small, 0, 2),
                CellFixtureTile("d", .small, 1, 0),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("d"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host, "d")

        XCTAssertEqual(host.store.placement(of: "d"), at(1, 3))
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "b"), at(0, 1))
        XCTAssertEqual(host.store.placement(of: "c"), at(0, 2))
        XCTAssertFalse(
            host.store.placements(forColumns: 4).values.contains(at(0, 3)),
            "Дыра (0, 3) осталась пустой: обратного заполнения нет"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("d"))
    }

    // MARK: - Сценарий B: цель слияния остаётся под пальцем

    /// Над центром плитки (`.group`) превью — базовая раскладка: плитка, которую
    /// раньше сдвинуло превью перестановки, возвращается под палец, подсветка
    /// рисуется на её базовой рамке.
    func testScenarioBGroupTargetStaysUnderFingerAndIsHighlighted() throws {
        let host = try makeSixTilesHost()
        let baseB = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let baseTable = try XCTUnwrap(host.gridCells)

        XCTAssertTrue(host.startDrag("a"))
        // Над краем «c»: превью размещения — «c» вытолкнута вниз.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2, fx: 0.1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        XCTAssertNotEqual(host.gridCells, baseTable, "Превью сдвинуло раскладку")

        // Над центром «b»: превью — база целиком, «b» под пальцем.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(session.hover, .group("b"))
        XCTAssertEqual(session.previewPlacements, session.basePlacements, "Нет залипшего превью")
        XCTAssertEqual(host.gridCells, baseTable, "Сетка показывает базовые ячейки")
        assertFrame(host.host.grid.frame(forItemID: "b"), baseB, "Цель не «убегает»")
        let highlight = try XCTUnwrap(
            host.host.grid.subviews.compactMap { $0 as? TesseraTileDropHighlightView }.first { !$0.isHidden }
        )
        XCTAssertEqual(highlight.center.x, baseB.midX, accuracy: 0.5)
        XCTAssertEqual(highlight.center.y, baseB.midY, accuracy: 0.5)

        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }

    /// То же для центра папки (`.folder`): цель под пальцем, после удержания
    /// drop добавляет ярлык в папку, ячейка ярлыка остаётся дырой.
    func testScenarioBFolderTargetStaysUnderFingerAndDropAddsTile() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("x", .small, 0, 3),
            ],
            folders: [
                CellFixtureFolder("F", .medium, 1, 1, contents: [("f1", .small), ("f2", .small)]),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let baseF = try XCTUnwrap(host.host.grid.frame(forItemID: "F"))
        let baseTable = try XCTUnwrap(host.gridCells)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 1, fx: 0.1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 1)), "Край папки — ячейка папки")
        XCTAssertNotEqual(host.gridCells, baseTable)

        host.coordinator.updateDrag(to: CGPoint(x: baseF.midX, y: baseF.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("F"))
        XCTAssertEqual(host.gridCells, baseTable)
        assertFrame(host.host.grid.frame(forItemID: "F"), baseF)
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        settle(host, "F")
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "F"), at(1, 1), "Папка на месте")
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "Ячейка «a» — дыра")
    }

    // MARK: - Сценарий C: папка 2×2 на ячейке цели, соседи вниз

    /// Слияние двух малых ярлыков: папка 2×2 встаёт на ячейку цели «b» (0, 1),
    /// накрытые соседи выталкиваются вниз каскадом (D31), ячейка «a» остаётся
    /// дырой, а не «папка улетает далеко вниз со случайными дырами».
    func testScenarioCFolderFromSmallTileStandsOnTargetCellAndPushesNeighborsDown() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        let folder = try XCTUnwrap(recorder.createdFolders.first)
        settle(host, folder.id)

        XCTAssertEqual(folder.size, .medium, "Папка всегда 2×2 (D20)")
        XCTAssertEqual(folder.tiles.map { $0.id }, ["b", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 1), "На ячейке цели")
        XCTAssertEqual(host.store.placement(of: "c"), at(2, 2), "«c» вытолкнута вниз (накрыта папкой)")
        XCTAssertEqual(host.store.placement(of: "f"), at(2, 1), "«f» вытолкнута вниз (накрыта папкой)")
        XCTAssertEqual(host.store.placement(of: "d"), at(0, 3), "Не затронутые — на местах")
        XCTAssertEqual(host.store.placement(of: "e"), at(1, 0), "Не затронутые — на местах")
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "Ячейка «a» — дыра")
        // Живое подключение: рамки сетки — по ячейкам модели.
        let folderFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id))
        assertFrame(folderFrame, host.cellFrame(row: 0, column: 1, size: .medium), "Рамки — по ячейкам модели")
    }

    // MARK: - Хит-тест: клетка под пальцем

    /// Край широкой плитки-цели — её ячейка (не клетка под пальцем): ярлык встанет
    /// на её место, широкая уйдёт вниз.
    func testWideTargetEdgeResolvesToItsOriginCell() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("w", .wide, 0, 0),
                CellFixtureTile("x", .small, 2, 3),
            ]
        )
        XCTAssertTrue(host.startDrag("x"))
        // Правая часть широкой плитки (клетка (0, 3)), у самого края.
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "w"))
        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 0)), "Ячейка элемента-цели")

        host.coordinator.finishDrag(commit: true)
        settle(host, "x")
        XCTAssertEqual(host.store.placement(of: "x"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "w"), at(1, 0), "Широкая вытолкнута вниз")
    }

    /// Пустая клетка — цель «эта клетка»; собственная базовая ячейка цели не даёт.
    func testEmptyCellIsTargetAndOwnBaseCellIsNot() throws {
        let host = try makeSixTilesHost()
        XCTAssertTrue(host.startDrag("e"))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 2)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow, "Ниже последней занятой строки")

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 0, fx: 0.4, fy: 0.6)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none, "Своя базовая ячейка")
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(session.previewPlacements, session.basePlacements, "Превью — база")

        host.coordinator.finishDrag(commit: true)
        settle(host, "e")
        XCTAssertEqual(host.store.placement(of: "e"), at(1, 0), "No-op: на месте")
        XCTAssertEqual(host.store.placements(forColumns: 4).count, 6)
    }

    /// Палец ниже последней занятой строки — цель «новая строка»: drop кладёт
    /// элемент в колонку 0 новой строки (`moveItemToNewRow`).
    func testBelowLastRowDropsIntoNewRow() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        XCTAssertTrue(host.startDrag("b"))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 3, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        assertFrame(previewFrame, host.cellFrame(row: 2, column: 0), "Превью — начало новой строки")

        host.coordinator.finishDrag(commit: true)
        settle(host, "b")
        XCTAssertEqual(host.store.placement(of: "b"), at(2, 0))
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0), "Остальные на местах, дыра (0, 1) осталась")
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("b"))
    }

    /// У правого края ячейка ограничивается холстом: клетка (0, 3) для 2×2
    /// превращается в (0, 2) — и в превью, и на drop; цель хранит клетку пальца.
    func testRightEdgeCellIsClampedByPreviewAndDrop() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("m", .medium, 2, 0),
            ]
        )
        XCTAssertTrue(host.startDrag("m"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 3)), "Клетка пальца без ограничения")
        assertFrame(
            host.host.grid.frame(forItemID: "m"),
            host.cellFrame(row: 0, column: 2, size: .medium),
            "Превью — на ограниченной ячейке"
        )

        host.coordinator.finishDrag(commit: true)
        settle(host, "m")
        XCTAssertEqual(host.store.placement(of: "m"), at(0, 2))
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0))
        // Строки 2–3 опустели и схлопнулись (на drop), строка 1 покрыта «m».
        XCTAssertEqual(host.store.placements(forColumns: 4).count, 2)
    }

    /// RTL: клетка пальца считается в логических координатах — край занятой
    /// клетки даёт её логическую ячейку, пустая клетка — логические строку и колонку.
    func testRightToLeftResolvesLogicalCells() throws {
        let host = try makeSixTilesHost()
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.layout()
        let c = try XCTUnwrap(host.host.grid.frame(forItemID: "c"))
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        XCTAssertLessThan(c.minX, b.minX, "RTL: «c» левее «b»")

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: CGPoint(x: c.minX + 3, y: c.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Край «c»: логическая ячейка (0, 2)")

        // Пустая клетка (1, 3): на экране левее «f» (логическая колонка 1) на два шага.
        let f = try XCTUnwrap(host.host.grid.frame(forItemID: "f"))
        let pitch = b.minX - c.minX
        host.coordinator.updateDrag(to: CGPoint(x: f.midX - 2 * pitch, y: f.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.store.placement(of: "a"), at(1, 3))
    }

    /// Папка, брошенная на центр другой папки, не сливается (вложенности нет) —
    /// это размещение на её ячейку.
    func testFolderOverFolderCenterIsPlacementNotMerge() throws {
        let host = try TesseraTestDragHost(
            cells: [],
            folders: [
                CellFixtureFolder("F1", .medium, 0, 0, contents: [("a", .small), ("a2", .small)]),
                CellFixtureFolder("F2", .medium, 0, 2, contents: [("b", .small), ("b2", .small)]),
            ]
        )
        XCTAssertTrue(host.startDrag("F1"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("F2", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        host.coordinator.finishDrag(commit: false)
        settle(host, "F1")
    }

    // MARK: - Превью от базы

    /// Превью считается от базовых размещений, а не от предыдущего превью: после
    /// «b» → «c» сдвинута только «c», а «b» вернулась на место; возврат на свою
    /// ячейку даёт базу целиком. Порядок элементов снимка сетки следует за
    /// ячейками превью (E14.7), хост об изменениях не уведомляется.
    func testPreviewIsComputedFromBaseWithoutAccumulation() throws {
        let host = try makeSixTilesHost()
        var notifications = 0
        host.store.onChange = { _ in notifications += 1 }
        let baseCells = try XCTUnwrap(host.gridCells)
        let baseOrder = host.gridIDs

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1, fx: 0.1)))
        XCTAssertEqual(host.gridCells?["b"], at(1, 1), "«b» вытолкнута вниз, «f» ниже каскадом")
        XCTAssertEqual(host.gridCells?["f"], at(2, 1))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2, fx: 0.1)))
        XCTAssertEqual(host.gridCells?["b"], at(0, 1), "«b» вернулась: сдвиги не накапливаются")
        XCTAssertEqual(host.gridCells?["f"], at(1, 1), "«f» вернулась")
        XCTAssertEqual(host.gridCells?["c"], at(1, 2), "Сдвинута только цель")
        XCTAssertEqual(host.gridCells?["a"], at(0, 2), "Ярлык на ячейке цели")
        XCTAssertEqual(
            host.gridIDs,
            ["b", "a", "d", "e", "f", "c"] as [AnyHashable],
            "Порядок снимка — порядок чтения ячеек превью (E14.7)"
        )

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 0)))
        XCTAssertEqual(host.gridCells, baseCells, "Возврат на свою ячейку — база")
        XCTAssertEqual(host.gridIDs, baseOrder, "Порядок снимка — база")
        XCTAssertEqual(notifications, 0, "Хранилище во время drag не пишется")
        XCTAssertEqual(host.store.placements(forColumns: 4), baseCells)

        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }

    /// Пустые строки во время drag не схлопываются (D31): плитки ниже не
    /// поднимаются, пока элемент не брошен; на drop строка схлопывается.
    func testEmptyRowsAreNotCollapsedDuringDragButCollapseOnDrop() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("c", .small, 1, 0),
                CellFixtureTile("d", .small, 2, 0),
            ]
        )
        XCTAssertTrue(host.startDrag("c"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 3)))
        XCTAssertEqual(host.gridCells?["c"], at(0, 3))
        XCTAssertEqual(host.gridCells?["d"], at(2, 0), "Строка 1 опустела, но во время drag не схлопывается")

        host.coordinator.finishDrag(commit: true)
        settle(host, "c")
        XCTAssertEqual(host.store.placement(of: "c"), at(0, 3))
        XCTAssertEqual(host.store.placement(of: "d"), at(1, 0), "Пустая строка схлопнулась на drop")
    }

    // MARK: - Фиксация drop'а по видам цели

    /// Без выдержанного удержания центр плитки — no-op: ячейки модели и делегат
    /// не затронуты, сетка возвращается к модели.
    func testGroupWithoutHoldDropIsNoOp() throws {
        let host = try makeSixTilesHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let before = host.store.placements(forColumns: 4)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")

        XCTAssertEqual(host.store.placements(forColumns: 4), before)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    /// Отказ хоста на слияние: модель как до drop'а, делегат получает
    /// `didFailGrouping`, сетка возвращается к модели.
    func testGroupDeniedByApprovalKeepsModelAndReportsFailure() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .createFolder }
        let before = host.store.placements(forColumns: 4)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")

        XCTAssertEqual(host.store.placements(forColumns: 4), before)
        XCTAssertEqual(recorder.failures, [.createFolder])
        XCTAssertTrue(host.folders.isEmpty)
    }

    /// Отмена (и выход из edit) посреди drag возвращает базовую раскладку и не
    /// пишет в модель.
    func testCancelRestoresBaseAndLeavesModelUntouched() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        var notifications = 0
        host.store.onChange = { _ in notifications += 1 }
        let before = host.store.placements(forColumns: 4)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertNotEqual(host.gridCells, before)
        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
        XCTAssertEqual(host.gridCells, before)
        XCTAssertEqual(host.store.placements(forColumns: 4), before)
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(recorder.moves.isEmpty)

        XCTAssertTrue(host.startDrag("b"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 3, column: 0)))
        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.waitUntil { host.gridCells == before })
        XCTAssertEqual(host.store.placements(forColumns: 4), before)
    }

    /// Ярлык из панели на центр обычного ярлыка — не слияние, а вынос на ячейку
    /// этого ярлыка (он вытолкнут вниз); drop на центр родной папки — no-op.
    func testPanelTileOnPlainTileCenterIsPlacementAndOnSourceFolderIsNoOp() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("t", .small, 0, 2)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small), ("f2", .small)]),
            ]
        )
        try startPanelDrag(host, folderID: "F", iconIndex: 0)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Центр ярлыка — не группа")
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")
        XCTAssertEqual(host.store.placement(of: "f1"), at(0, 2))
        XCTAssertEqual(host.store.placement(of: "t"), at(1, 2), "Вытолкнут вниз")

        let host2 = try TesseraTestDragHost(
            cells: [],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small), ("f2", .small)]),
            ]
        )
        try startPanelDrag(host2, folderID: "F", iconIndex: 0)
        host2.coordinator.updateDrag(to: try XCTUnwrap(host2.point("F", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host2.coordinator.dragSession?.hover, .sourceFolder)
        host2.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host2.waitUntil { host2.coordinator.dragSession == nil })
        XCTAssertEqual(host2.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
    }

    /// Ярлык из панели в новую строку (D45): в папке два ярлыка, она распускается,
    /// оставшийся (large) встаёт на её ячейку со своим размером; превью «новой
    /// строки» считается уже с ним, как и операция хранилища, поэтому ярлык ложится
    /// ровно туда, где его показало превью (раньше папка из одного ярлыка исчезала).
    func testPanelTileToNewRowDissolvesFolderAndLandsWherePreviewShowed() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [
                CellFixtureFolder("F", .small, 1, 0, contents: [("f1", .small), ("f2", .large)]),
            ]
        )
        try startPanelDrag(host, folderID: "F", iconIndex: 0)
        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 20))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f1"))
        XCTAssertNotNil(host.host.grid.frame(forItemID: "f2"), "Превью показало распад: оставшийся ярлык на месте папки")
        XCTAssertNil(host.host.grid.frame(forItemID: "F"), "Папки в превью нет")
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")

        XCTAssertTrue(host.folders.isEmpty, "Папка распалась")
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 3))
        XCTAssertEqual(host.store.placement(of: "f2"), at(1, 0), "Оставшийся ярлык — на ячейке папки")
        XCTAssertEqual(host.store.snapshot().item(withID: "f2")?.size, .large, "со своим размером")
        XCTAssertEqual(host.store.placement(of: "f1"), at(5, 0), "Новая строка считается с оставшимся ярлыком")
        assertFrame(host.host.grid.frame(forItemID: "f1"), previewFrame, "Ярлык лёг туда, где показало превью")
    }

    // MARK: - Внешние изменения и магнит

    /// Внешняя правка, которая только передвинула плитки (состав тот же), делает
    /// базу устаревшей: drag безопасно отменяется (E10.5-B1, E14.5).
    func testExternalCellOnlyChangeCancelsDrag() throws {
        let host = try makeSixTilesHost()
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2, fx: 0.1)))
        XCTAssertTrue(host.coordinator.isDragging)

        XCTAssertTrue(host.store.moveItem("f", toCell: at(3, 3), columns: 4))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 3, fx: 0.1)))

        XCTAssertFalse(host.coordinator.isDragging, "Drag отменён")
        XCTAssertTrue(host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) })
        XCTAssertEqual(host.store.placement(of: "f"), at(3, 3), "Чужая правка не откатилась")
        XCTAssertGreaterThan(host.host.cell("a")?.contentView.alpha ?? 0, 0.9, "Ячейка видима")
    }

    /// Магнит: снимок притягивается к рамке ячейки-цели (для своего размера) и
    /// не притягивается над целями слияния.
    func testMagnetSnapsToTargetCellFrameAndNotOverMergeTargets() throws {
        let host = try makeSixTilesHost(
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 40,
                magnetSpringDuration: 0
            )
        )
        XCTAssertTrue(host.startDrag("a"))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        session.hasLeftOriginSlot = true

        // Пустая клетка (1, 3), палец чуть левее-выше центра (в радиусе притяжения).
        let center = try XCTUnwrap(host.cellFrame(row: 1, column: 3)).center
        let finger = CGPoint(
            x: center.x - session.grabOffset.x + 6,
            y: center.y - session.grabOffset.y - 6
        )
        host.coordinator.updateDrag(to: finger)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))
        let target = try XCTUnwrap(host.coordinator.dragMagnetTargetForTesting(at: finger))
        XCTAssertEqual(target.x, center.x, accuracy: 0.001, "Центр рамки ячейки-цели")
        XCTAssertEqual(target.y, center.y, accuracy: 0.001)

        // Над центром «b» (цель слияния) притяжения нет.
        let bCenter = try XCTUnwrap(host.cellPoint(row: 0, column: 1))
        host.coordinator.updateDrag(to: bCenter)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))
        XCTAssertNil(host.coordinator.dragMagnetTargetForTesting(at: bCenter))

        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }
}

private extension CGRect {

    /// Центр рамки.
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

#endif
