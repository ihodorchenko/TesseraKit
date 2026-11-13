//
//  DropSlotTests.swift
//  TesseraStartScreenTests
//
//  Позиция drop'а: клетка под пальцем (E12.1 → E14.5, 13.11.2026).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Алгоритм упаковки»,
//  §5 «Drag: позиция над пустым местом» (п. 46) и п. 53 «Цели drag — клетка
//  под пальцем» (E14.5, D21, D31, D33).
//
//  Наблюдение: ярлык, вынутый из панели папки, «падал в первое свободное
//  место» — позицию выбрать было нельзя. С E12.1 над пустым местом цель была
//  слотом порядка (`HoverTarget.slot`), а с E14.5 — клеткой под пальцем
//  (`HoverTarget.cell`): элемент ложится **ровно в эту клетку**, дыры
//  сохраняются, мешающие плитки выталкиваются вниз (D31), под плитками —
//  цель «новая строка» (`HoverTarget.newRow`). Превью живёт за пальцем (те же
//  элементы на других ячейках), а drop кладёт элемент туда, где его показало
//  превью.
//
//  Проверяется на реальных ячейках и настоящем `TileStore` в окне
//  (`TesseraTestDragHost`), без `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class DropSlotTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Делегат, ловящий только `didMove(toFolder:atCell:)` и `didMove(toCell:)`.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Вынос/перенос: ярлык, папка-цель и фактическая ячейка.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?, cell: TileGridPlacement?)] = []

        /// Перестановка по сетке: ярлык и фактическая ячейка.
        var moves: [(id: AnyHashable, cell: TileGridPlacement)] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TileGridPlacement?
        ) {
            folderMoves.append((tileID, folderID, cell))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toCell cell: TileGridPlacement
        ) {
            moves.append((tileID, cell))
        }
    }

    /// Стенд: ярлыки `plain` (в порядке чтения), папка «F» с ярлыками
    /// `folderTiles` (small) стоит в порядке на позиции `folderAt`.
    ///
    /// Раскладка — компактная, как её давали операции по порядку до E14
    /// (`TesseraTestDragHost(packed:)`, E14.6); папка — small.
    private func makeHost(
        plain: [(String, TileSize)],
        folderTiles: [String],
        folderAt: Int,
        columns: Int = 4
    ) throws -> TesseraTestDragHost {
        var entries: [TesseraTestPackedEntry] = plain.map { .tile($0.0, $0.1) }
        entries.insert(.folder("F", .small, folderTiles.map { ($0, TileSize.small) }), at: min(folderAt, entries.count))
        return try TesseraTestDragHost(packed: entries, columns: columns)
    }

    /// Входит в edit, раскрывает панель папки и берёт иконку панели (E11.1).
    private func startPanelDrag(
        _ host: TesseraTestDragHost,
        iconIndex: Int
    ) throws -> AnyHashable {
        let folderID = try XCTUnwrap(host.firstFolderID)
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        host.coordinator.handleLongPress(
            on: panelItem,
            at: CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        )
        XCTAssertTrue(host.coordinator.isDragging)
        return folderID
    }

    /// Геометрия сетки малых плиток до drag: начало (0, 0), юнит и шаг клетки.
    private struct Cells {
        let origin: CGPoint
        let unit: CGFloat
        let pitch: CGFloat

        /// Точка в клетке (колонка, строка); `fx`/`fy` — доля клетки.
        func point(column: Int, row: Int, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(column) * pitch + unit * fx,
                y: origin.y + CGFloat(row) * pitch + unit * fy
            )
        }
    }

    /// Клетки по двум соседним малым плиткам первой строки (до drag).
    private func cells(_ host: TesseraTestDragHost, first: AnyHashable, second: AnyHashable) throws -> Cells {
        let a = try XCTUnwrap(host.host.grid.frame(forItemID: first))
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: second))
        return Cells(origin: a.origin, unit: a.width, pitch: b.minX - a.minX)
    }

    /// Ждёт, пока сетка догонит модель после drop'а и снимок уберётся.
    private func settle(_ host: TesseraTestDragHost, _ id: AnyHashable) {
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "Сетка = модель")
        XCTAssertTrue(host.waitForDragCleanup(id))
        XCTAssertNil(host.coordinator.dragSession)
    }

    // MARK: - Drag из панели

    /// Порядок «a F b c d» (4 колонки): ряд 0 — a F b c, ряд 1 — d. Ярлык из
    /// панели брошен справа от «d» (пустая клетка (1, 3)): встаёт **ровно в эту
    /// клетку** — ту, которую показало превью, а не «после папки».
    func testPanelDropRightOfLastTileLandsAtEnd() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        XCTAssertEqual(host.storeIDs.count, 5)
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let folderID = try startPanelDrag(host, iconIndex: 2)

        // Отображаемый снимок: ярлык после папки в порядке снимка, на сетке — на
        // свободной ячейке после папки. Палец — на пустой клетке (колонка 3,
        // строка 1), правее «d»; там ничего нет и в базе.
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TileGridPlacement(row: 1, column: 3)),
            "Цель — клетка под пальцем"
        )
        XCTAssertEqual(
            host.gridIDs,
            ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable],
            "Порядок снимка — порядок чтения ячеек превью (E14.7): «f3» на клетке (1, 3) — после «d»"
        )
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        let dFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "d"))
        XCTAssertEqual(previewFrame.minY, dFrame.minY, accuracy: 0.5, "Превью — в ряду «d», сразу за ним")
        XCTAssertGreaterThan(previewFrame.minX, dFrame.maxX)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")

        XCTAssertEqual(host.storeIDs, ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "f3"), TileGridPlacement(row: 1, column: 3))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
        XCTAssertEqual(recorder.folderMoves.count, 1)
        XCTAssertEqual(recorder.folderMoves.first?.cell, TileGridPlacement(row: 1, column: 3))
        let landed = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        XCTAssertEqual(landed, previewFrame, "Ярлык лёг ровно туда, где показало превью")
    }

    /// Палец в зазоре между клетками (не над самой плиткой): зазор относится к
    /// клетке слева — это край занятой клетки «d», поэтому вынос встаёт на ячейку
    /// «d», а «d» выталкивается вниз (D31), а не «сразу после папки».
    func testPanelDropBetweenTwoTilesInGapInsertsBetween() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)

        // Базовая раскладка: ряд 0 — a F b c, ряд 1 — d (1, 0), f3 (1, 1). Зазор
        // между клетками (1, 0) и (1, 1) — хвост клетки «d».
        let gap = CGPoint(
            x: grid.origin.x + grid.pitch - (grid.pitch - grid.unit) / 2,
            y: grid.point(column: 0, row: 1).y
        )
        host.coordinator.updateDrag(to: gap)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TileGridPlacement(row: 1, column: 0)),
            "Зазор — край клетки «d»: ячейка «d»"
        )

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")
        XCTAssertEqual(host.storeIDs, ["a", folderID, "b", "c", "f3", "d"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "f3"), TileGridPlacement(row: 1, column: 0))
        XCTAssertEqual(host.store.placement(of: "d"), TileGridPlacement(row: 2, column: 0), "«d» вытолкнут вниз")
    }

    /// Палец левее/выше первой клетки (зона полей сверху): ярлык встаёт на первую
    /// клетку «a» (0, 0), а «a» выталкивается вниз (D31).
    func testPanelDropAboveFirstRowLandsAtStart() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        host.host.grid.contentInsets = UIEdgeInsets(top: 60, left: 16, bottom: 0, right: 16)
        host.host.layout()
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)

        host.coordinator.updateDrag(to: CGPoint(x: grid.origin.x + 4, y: grid.origin.y - 30))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TileGridPlacement(row: 0, column: 0)),
            "Над полями строка зажимается до 0: край клетки «a»"
        )

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")
        XCTAssertEqual(host.store.placement(of: "f3"), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(host.store.placement(of: "a"), TileGridPlacement(row: 1, column: 0), "«a» вытолкнут вниз")
        XCTAssertEqual(
            host.storeIDs,
            ["f3", folderID, "b", "c", "a", "d"] as [AnyHashable],
            "Порядок модели — порядок чтения ячеек"
        )
        let landed = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        let aFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        XCTAssertLessThan(landed.minY, aFrame.minY, "Ярлык — первая клетка первой строки, «a» ниже")
    }

    /// Пустая область под плитками (палец ниже последней строки): цель «новая
    /// строка» — ярлык встаёт в начало новой строки в конце холста.
    func testPanelDropBelowAllTilesLandsAtEnd() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let folderID = try startPanelDrag(host, iconIndex: 0)
        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 30))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")
        XCTAssertEqual(host.store.placement(of: "f1"), TileGridPlacement(row: 2, column: 0), "Новая строка после ряда «d»")
        XCTAssertEqual(host.storeIDs.last, AnyHashable("f1"))
        XCTAssertEqual(host.storeIDs.first, AnyHashable("a"))
        XCTAssertTrue(host.storeIDs.contains(folderID))
    }

    /// Дыра в раскладке: «m» (2×2), папка F и «s» справа от неё, под ними 2×1
    /// свободно, «w» (wide) ниже. Палец — в свободной клетке (1, 3): ярлык из
    /// панели встаёт **ровно в неё** (E14.5: клетка под пальцем, а не ближайший
    /// слот порядка); drop кладёт его туда же, куда показало превью.
    func testPanelDropIntoHoleLandsInNearestReachableCell() throws {
        let host = try makeHost(
            plain: [("m", .medium), ("s", .small), ("w", .wide)],
            folderTiles: ["f1", "f2"],
            folderAt: 1
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folderCell = try XCTUnwrap(host.store.placement(of: folderID))
        XCTAssertEqual(host.storeIDs, ["m", folderID, "s", "w"] as [AnyHashable])
        // Клетки малых: F — (0, 2), s — (0, 3).
        let grid = try cells(host, first: folderID, second: "s")
        let origin = try XCTUnwrap(host.host.grid.frame(forItemID: "m")).origin
        let cell = Cells(origin: origin, unit: grid.unit, pitch: grid.pitch)

        _ = try startPanelDrag(host, iconIndex: 1)
        // Базовая раскладка снимка: m, F (0,2), f2 (0,3), s (1,2); (1,3) свободна.

        host.coordinator.updateDrag(to: cell.point(column: 3, row: 1, fx: 0.1))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TileGridPlacement(row: 1, column: 3)),
            "Клетка под пальцем"
        )
        let preview = try XCTUnwrap(host.host.grid.frame(forItemID: "f2"))
        XCTAssertEqual(preview.minX, cell.point(column: 3, row: 1, fx: 0).x, accuracy: 0.5)
        XCTAssertEqual(preview.minY, cell.point(column: 3, row: 1, fy: 0).y, accuracy: 0.5)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f2")
        // D45: в папке F из двух ярлыков остался «f1» — папка распущена, он на её месте.
        XCTAssertEqual(host.storeIDs, ["m", "f1", "s", "f2", "w"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "f1"), folderCell, "f1 заняла ячейку папки")
        XCTAssertEqual(host.store.placement(of: "f2"), TileGridPlacement(row: 1, column: 3))
        XCTAssertEqual(host.host.grid.frame(forItemID: "f2"), preview)
    }

    /// Вынос одного из двух ярлыков (D45: папка распускается, оставшийся «f2» встаёт
    /// на её ячейку) в клетку правее «d»: вынесенный ярлык — последний в порядке чтения.
    func testPanelDropOfOneOfTwoTilesToEndDissolvesFolder() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2"],
            folderAt: 1
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folderCell = try XCTUnwrap(host.store.placement(of: folderID))
        let grid = try cells(host, first: "a", second: folderID)
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        _ = try startPanelDrag(host, iconIndex: 0)

        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")

        XCTAssertEqual(host.storeIDs, ["a", "f2", "b", "c", "d", "f1"] as [AnyHashable], "Папка распалась")
        XCTAssertEqual(host.store.placement(of: "f2"), folderCell, "f2 — на месте папки")
        XCTAssertEqual(host.store.placement(of: "b"), TileGridPlacement(row: 0, column: 2), "Остальные без репака")
        XCTAssertEqual(recorder.folderMoves.first?.cell, TileGridPlacement(row: 1, column: 3))
    }

    // MARK: - Drag по сетке (та же ветка)

    /// Обычный drag: палец на пустой клетке справа от последней плитки — элемент
    /// встаёт ровно в эту клетку; его старое место остаётся дырой (E14.5).
    func testGridDragToEmptyCellAfterLastTileMovesToEnd() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e", "f"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let grid = try cells(host, first: "a", second: "b")
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TileGridPlacement(row: 1, column: 3)))
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        XCTAssertEqual(previewFrame.minX, grid.point(column: 3, row: 1, fx: 0).x, accuracy: 0.5)
        XCTAssertEqual(previewFrame.minY, grid.point(column: 3, row: 1, fy: 0).y, accuracy: 0.5)

        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.storeIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "a"), TileGridPlacement(row: 1, column: 3))
        XCTAssertEqual(host.store.placement(of: "b"), TileGridPlacement(row: 0, column: 1), "Дыра на месте «a» осталась")
        XCTAssertEqual(recorder.moves.first?.cell, TileGridPlacement(row: 1, column: 3))
    }

    /// Над собственной базовой ячейкой цели нет (`.none`): превью — база, а drop
    /// без изменения раскладки не пишет в модель.
    func testGridDragOverOwnSlotKeepsOrder() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e", "f"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let grid = try cells(host, first: "a", second: "b")
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("e"))
        host.coordinator.updateDrag(to: grid.point(column: 0, row: 1, fx: 0.4, fy: 0.6))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none)
        host.coordinator.finishDrag(commit: true)
        settle(host, "e")
        XCTAssertEqual(host.storeIDs, ["a", "b", "c", "d", "e", "f"] as [AnyHashable])
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    /// Над краем плитки цель — её ячейка (`.cell` с ячейкой «c»), а не клетка
    /// под пальцем: элемент встанет на место «c», а «c» уйдёт вниз.
    func testGridDragOverTileStillReorders() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TileGridPlacement(row: 0, column: 2)))
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// На подъёме палец стоит на месте иконки панели (после закрытия панели —
    /// пустое место под плитками): пустышка не «убегает» из-под пальца, пока
    /// палец не сдвинется заметно (`emptySlotActivationDistance`); потом превью
    /// следует за пальцем, а повтор той же клетки превью не меняет.
    func testPanelLiftOverEmptySpaceKeepsDefaultSlotUntilFingerMoves() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)
        // Иконка панели лежала ниже плиток; после закрытия панели там пусто.
        let origin = try XCTUnwrap(host.coordinator.dragSession?.originPoint)
        XCTAssertEqual(
            host.gridIDs,
            ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable],
            "На подъёме ярлык стоит на первой свободной ячейке после папки; порядок — порядок чтения ячеек (E14.7)"
        )

        let liftFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        host.coordinator.updateDrag(to: CGPoint(x: origin.x + 4, y: origin.y - 3))
        XCTAssertEqual(
            host.host.grid.frame(forItemID: "f3"),
            liftFrame,
            "Дрожание пальца превью не трогает"
        )

        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TileGridPlacement(row: 1, column: 3)))
        let moved = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        XCTAssertNotEqual(moved, liftFrame, "Пустышка поехала за пальцем")
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1, fx: 0.3, fy: 0.7))
        XCTAssertEqual(host.host.grid.frame(forItemID: "f3"), moved, "Та же клетка — то же превью")
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "Отмена: сетка = модель")
        XCTAssertNil(host.coordinator.dragSession)
    }

    /// RTL: клетка пальца считается в логических (не зеркальных) координатах —
    /// пустая клетка справа от последней плитки по порядку чтения (то есть
    /// левее неё на экране) — логическая колонка 2 строки 1.
    func testGridDragToEmptyCellInRightToLeftLandsAtEnd() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e", "f"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.layout()
        let a = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        XCTAssertLessThan(b.minX, a.minX, "RTL: вторая плитка левее первой")
        let pitch = a.minX - b.minX
        let f = try XCTUnwrap(host.host.grid.frame(forItemID: "f"))

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: CGPoint(x: f.midX - pitch, y: f.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TileGridPlacement(row: 1, column: 2)))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.storeIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "a"), TileGridPlacement(row: 1, column: 2))
    }
}

#endif
