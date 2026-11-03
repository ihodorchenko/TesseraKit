//
//  DropSlotTests.swift
//  TesseraStartScreenTests
//
//  Позиция drop'а над пустым местом (E12.1, 03.11.2026).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Алгоритм упаковки»
//  (строго компактная, E8.5), §5 «Drag: позиция над пустым местом» (п. 46).
//
//  Наблюдение: ярлык, вынутый из панели папки, «падал в первое свободное
//  место» — над пустым местом (дыра, зазор, область под плитками) цель была
//  `.none`, превью оставалось в слоте «сразу после папки», и пользователь не
//  выбирал позицию. Теперь над пустым местом позиция — слот порядка, ближайший
//  к пальцу (`HoverTarget.slot`); превью живёт за пальцем, а drop кладёт
//  элемент ровно туда, где его показало превью.
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

    /// Делегат, ловящий только `didMove(toFolder:atIndex:)` и `didMove(toIndex:)`.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Вынос/перенос: ярлык, папка-цель и фактический индекс.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?, index: Int?)] = []

        /// Перестановка по сетке: ярлык и фактический индекс.
        var moves: [(id: AnyHashable, index: Int)] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atIndex index: Int?
        ) {
            folderMoves.append((tileID, folderID, index))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toIndex index: Int
        ) {
            moves.append((tileID, index))
        }
    }

    /// Стенд: ярлыки `sizes` (в порядке чтения), папка «F» с ярлыками
    /// `folderTiles` (small) стоит в порядке на позиции `folderAt`.
    ///
    /// Ярлыки папки идут в каталоге после остальных; папка создаётся первой из
    /// них и получает размер small, затем порядок канонизируется под колонки.
    private func makeHost(
        plain: [(String, TileSize)],
        folderTiles: [String],
        folderAt: Int,
        columns: Int = 4
    ) -> TesseraTestDragHost {
        var descriptors = plain.map { tesseraTestTile($0.0, size: $0.1) }
        descriptors += folderTiles.map { tesseraTestTile($0, size: .small) }
        return TesseraTestDragHost(
            descriptors: descriptors,
            columns: columns,
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            ),
            prepare: { store in
                guard let first = folderTiles.first,
                      let folder = store.createFolder(withTile: first) else { return }
                for tile in folderTiles.dropFirst() {
                    _ = store.addToFolder(tile, folderID: folder.id)
                }
                _ = store.resize(folder.id, to: .small)
                // Папка — на позицию `folderAt` среди элементов сетки.
                _ = store.moveItem(folder.id, toIndex: folderAt, columns: columns)
                store.canonicalizeVisibleOrder(columns: columns)
            }
        )
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
    /// панели брошен справа от «d» (пустая клетка конца): встаёт **в конец**
    /// порядка и в ту клетку, которую показало превью, а не «после папки».
    func testPanelDropRightOfLastTileLandsAtEnd() throws {
        let host = makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        XCTAssertEqual(host.storeIDs.count, 5)
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let folderID = try startPanelDrag(host, iconIndex: 2)

        // Отображаемый снимок: ярлык после папки. Палец — на пустой клетке
        // (колонка 3, строка 1), правее «d»; там ничего нет и в базе.
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(5), "Позиция — конец порядка")
        XCTAssertEqual(host.gridIDs, ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable])
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        let dFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "d"))
        XCTAssertEqual(previewFrame.minY, dFrame.minY, accuracy: 0.5, "Превью — в ряду «d», сразу за ним")
        XCTAssertGreaterThan(previewFrame.minX, dFrame.maxX)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")

        XCTAssertEqual(host.storeIDs, ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable])
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
        XCTAssertEqual(recorder.folderMoves.count, 1)
        XCTAssertEqual(recorder.folderMoves.first?.index, 5)
        let landed = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        XCTAssertEqual(landed, previewFrame, "Ярлык лёг ровно туда, где показало превью")
    }

    /// Палец в зазоре между «c» и «d» (между клетками, а не над плиткой): вынос
    /// встаёт между ними, а не «сразу после папки».
    func testPanelDropBetweenTwoTilesInGapInsertsBetween() throws {
        let host = makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)

        // В отображаемом снимке: a F f3 b / c d. Зазор между c (кол. 0) и d (кол. 1).
        let gap = CGPoint(
            x: grid.origin.x + grid.pitch - (grid.pitch - grid.unit) / 2,
            y: grid.point(column: 0, row: 1).y
        )
        host.coordinator.updateDrag(to: gap)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(4), "Между «c» (индекс 3) и «d»")

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")
        XCTAssertEqual(host.storeIDs, ["a", folderID, "b", "c", "f3", "d"] as [AnyHashable])
    }

    /// Палец левее/выше первой клетки (зона полей сверху): ярлык встаёт в начало
    /// порядка («первая строка»).
    func testPanelDropAboveFirstRowLandsAtStart() throws {
        let host = makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        host.host.grid.contentInsets = UIEdgeInsets(top: 60, left: 16, bottom: 0, right: 16)
        host.host.layout()
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)

        host.coordinator.updateDrag(to: CGPoint(x: grid.origin.x + 4, y: grid.origin.y - 30))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(0))
        XCTAssertEqual(host.gridIDs.first, AnyHashable("f3"))

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")
        XCTAssertEqual(host.storeIDs, ["f3", "a", folderID, "b", "c", "d"] as [AnyHashable])
        let landed = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        let aFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        XCTAssertEqual(landed.minY, aFrame.minY, accuracy: 0.5)
        XCTAssertLessThan(landed.minX, aFrame.minX, "Ярлык — первая клетка первой строки")
    }

    /// Пустая область под плитками (палец ниже последней строки): конец порядка.
    func testPanelDropBelowAllTilesLandsAtEnd() throws {
        let host = makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let folderID = try startPanelDrag(host, iconIndex: 0)
        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 30))

        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")
        XCTAssertEqual(host.storeIDs.last, AnyHashable("f1"))
        XCTAssertEqual(host.storeIDs.first, AnyHashable("a"))
        XCTAssertTrue(host.storeIDs.contains(folderID))
    }

    /// Дыра в раскладке: «m» (2×2), папка F и «s» справа от неё, под ними 2×1
    /// свободно, «w» (wide) ниже. Палец — в свободной клетке (1, 3): ярлык из
    /// панели встаёт в ближайшую достижимую клетку (1, 2), а не в слот «после
    /// папки» (0, 3); drop кладёт его туда же, куда показало превью.
    func testPanelDropIntoHoleLandsInNearestReachableCell() throws {
        let host = makeHost(
            plain: [("m", .medium), ("s", .small), ("w", .wide)],
            folderTiles: ["f1", "f2"],
            folderAt: 1
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        XCTAssertEqual(host.storeIDs, ["m", folderID, "s", "w"] as [AnyHashable])
        // Клетки малых: F — (0, 2), s — (0, 3).
        let grid = try cells(host, first: folderID, second: "s")
        let origin = try XCTUnwrap(host.host.grid.frame(forItemID: "m")).origin
        let cell = Cells(origin: origin, unit: grid.unit, pitch: grid.pitch)

        _ = try startPanelDrag(host, iconIndex: 1)
        // Базовая раскладка снимка: m, F (0,2), f2 (0,3), s (1,2); (1,3) свободна.

        host.coordinator.updateDrag(to: cell.point(column: 3, row: 1, fx: 0.1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(3), "После «s»")
        let preview = try XCTUnwrap(host.host.grid.frame(forItemID: "f2"))
        XCTAssertEqual(preview.minX, cell.point(column: 2, row: 1, fx: 0).x, accuracy: 0.5)
        XCTAssertEqual(preview.minY, cell.point(column: 2, row: 1, fy: 0).y, accuracy: 0.5)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f2")
        XCTAssertEqual(host.storeIDs, ["m", folderID, "s", "f2", "w"] as [AnyHashable])
        XCTAssertEqual(host.host.grid.frame(forItemID: "f2"), preview)
    }

    /// Вынос последнего ярлыка (папка распадается) в конец: индекс учитывает
    /// исчезнувшую папку, ярлык — последний в порядке.
    func testSoleTilePanelDropToEndDissolvesFolder() throws {
        let host = makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1"],
            folderAt: 1
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let grid = try cells(host, first: "a", second: folderID)
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        _ = try startPanelDrag(host, iconIndex: 0)

        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")

        XCTAssertEqual(host.storeIDs, ["a", "b", "c", "d", "f1"] as [AnyHashable], "Папка распалась")
        XCTAssertEqual(recorder.folderMoves.first?.index, 4)
    }

    // MARK: - Drag по сетке (та же ветка)

    /// Обычный drag: палец на пустой клетке справа от последней плитки — элемент
    /// встаёт в конец порядка (раньше оставался на месте: `.none`).
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
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(5))
        XCTAssertEqual(host.gridIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])

        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.storeIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])
        XCTAssertEqual(recorder.moves.first?.index, 5)
    }

    /// Над собственным базовым слотом цель не меняется (поведение «c», E8.4):
    /// превью остаётся прежним, а drop без перестановки не пишет в модель.
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

    /// Над плиткой (E8.4) поведение прежнее: `.reorder`, а не `.slot`.
    func testGridDragOverTileStillReorders() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .reorder("c", index: 2))
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// На подъёме палец стоит на месте иконки панели (после закрытия панели —
    /// пустое место под плитками): слот не «убегает» из-под пальца, пока палец
    /// не сдвинется заметно (`emptySlotActivationDistance`); потом превью
    /// следует за пальцем, а повтор той же точки превью не меняет.
    func testPanelLiftOverEmptySpaceKeepsDefaultSlotUntilFingerMoves() throws {
        let host = makeHost(
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
            ["a", folderID, "f3", "b", "c", "d"] as [AnyHashable],
            "На подъёме ярлык остаётся после папки"
        )

        host.coordinator.updateDrag(to: CGPoint(x: origin.x + 4, y: origin.y - 3))
        XCTAssertEqual(host.gridIDs[2], AnyHashable("f3"), "Дрожание пальца превью не трогает")

        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(5))
        let ids = host.gridIDs
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1, fx: 0.3, fy: 0.7))
        XCTAssertEqual(host.gridIDs, ids, "Та же клетка — то же превью")
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "Отмена: сетка = модель")
        XCTAssertNil(host.coordinator.dragSession)
    }

    /// RTL: клетка пальца считается в логических (не зеркальных) координатах —
    /// пустая клетка справа от последней плитки по порядку чтения (то есть
    /// левее неё на экране) — конец порядка.
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
        XCTAssertEqual(host.coordinator.dragSession?.hover, .slot(5))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.storeIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])
    }

    // MARK: - Чистая функция превью

    /// `previewOrder(insertionIndex:)`: позиция среди остальных, зажим границ.
    func testPreviewOrderByInsertionIndex() {
        let items = ["a", "b", "c", "d"].map { TileGridItem.tile(
            TileDescriptor(id: $0, title: $0, action: {}, badge: .none, size: .small)
        ) }
        func ids(_ index: Int) -> [AnyHashable]? {
            TileLayoutEngine.previewOrder(items: items, draggingID: "b", insertionIndex: index)?.map { $0.id }
        }
        XCTAssertEqual(ids(0), ["b", "a", "c", "d"] as [AnyHashable])
        XCTAssertEqual(ids(1), ["a", "b", "c", "d"] as [AnyHashable])
        XCTAssertEqual(ids(3), ["a", "c", "d", "b"] as [AnyHashable])
        XCTAssertEqual(ids(99), ["a", "c", "d", "b"] as [AnyHashable], "Зажим сверху")
        XCTAssertEqual(ids(-5), ["b", "a", "c", "d"] as [AnyHashable], "Зажим снизу")
        XCTAssertNil(TileLayoutEngine.previewOrder(items: items, draggingID: "zz", insertionIndex: 0))
    }
}

#endif
