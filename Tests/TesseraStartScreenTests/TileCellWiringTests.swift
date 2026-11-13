//
//  TileCellWiringTests.swift
//  TesseraStartScreenTests
//
//  Живое подключение ячеек и кнопки правки по операциям `TileStore` по ячейкам
//  (E14.5, 13.11.2026). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  «Отступления реализации (E14)», п. 53; решения D30–D33 в docs/STATE.md.
//
//  Проверяется:
//  - рамки сетки равны сохранённым ячейкам модели (в том числе с дырами);
//  - открепление оставляет дыру, схлопывается только полностью пустая строка (D31);
//  - стрелка размера: рост выталкивает вниз, уменьшение оставляет дыру/схлопывает строку;
//  - ширина сетки сообщается хранилищу и при смене колонок (D32);
//  - сетка, построенная хостом без таблицы ячеек, подтягивается на входе в правку;
//  - `onChange` хранилища отдаёт снимок с таблицей ячеек, когда ширина известна;
//  - публичные `move(toIndex:)`/`createFolder`/`addToFolder` идут по ячейкам.
//
//  Раскладки точные (`TileStoreCellFixture`), 4 колонки; без `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileCellWiringTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Делегат, считающий события открепления, размера и перестановки.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// События `didUnpin`.
        var unpins: [AnyHashable] = []

        /// События `didResize`.
        var resizes: [(id: AnyHashable, size: TileSize)] = []

        /// События `didMove(toIndex:)`.
        var moves: [(id: AnyHashable, index: Int)] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            unpins.append(tileID)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didResize tileID: AnyHashable,
            to size: TileSize
        ) {
            resizes.append((tileID, size))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toIndex index: Int
        ) {
            moves.append((tileID, index))
        }
    }

    /// Ячейка в короткой записи.
    private func at(_ row: Int, _ column: Int) -> TileGridPlacement {
        TileGridPlacement(row: row, column: column)
    }

    /// Сравнивает рамки с точностью до долей точки.
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

    /// Раскладка с дырами: `a (0,0)`, `b (0,2)`, `c (1,3)`, `w` wide `(2,0)`.
    private func makeHoleyHost() throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 2),
                CellFixtureTile("c", .small, 1, 3),
                CellFixtureTile("w", .wide, 2, 0),
            ]
        )
    }

    // MARK: - Живое подключение

    /// Сетка из `TileStore.snapshot(columns:)` показывает плитки ровно на
    /// сохранённых ячейках модели — с дырами, без обратного заполнения.
    func testGridFramesEqualStoredPlacementsWithHoles() throws {
        let host = try makeHoleyHost()
        let sizes: [String: TileSize] = ["a": .small, "b": .small, "c": .small, "w": .wide]

        for (id, cell) in host.store.placements(forColumns: 4) {
            let key = try XCTUnwrap(id.base as? String)
            assertFrame(
                host.host.grid.frame(forItemID: id),
                host.host.grid.baseFrame(forCell: cell, size: try XCTUnwrap(sizes[key])),
                "\(key) на ячейке (\(cell.row), \(cell.column))"
            )
        }
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        XCTAssertEqual(host.store.placement(of: "b"), at(0, 2), "Дыра (0, 1) не заполнена")
    }

    /// Первый запуск (ячеек в файле ещё нет): штатный путь даёт ту же компактную
    /// раскладку, что и упаковка по порядку, без дыр.
    func testFirstLaunchShowsCompactLayoutThroughCells() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) }
        )
        let expected: [(String, Int, Int)] = [
            ("a", 0, 0), ("b", 0, 1), ("c", 0, 2), ("d", 0, 3), ("e", 1, 0),
        ]
        for (id, row, column) in expected {
            assertFrame(
                host.host.grid.frame(forItemID: AnyHashable(id)),
                host.cellFrame(row: row, column: column),
                id
            )
        }
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
    }

    /// Хост, построивший сетку из `snapshot()` без таблицы ячеек, получает на входе
    /// в правку те же ячейки, что и в модели (без анимации).
    func testEditingSyncsGridWhenHostOmittedCellTable() throws {
        let host = try makeHoleyHost()
        host.host.grid.reload(snapshot: host.store.snapshot())
        host.host.layout()
        XCTAssertNil(host.host.grid.snapshot?.placementTable, "Хост показывает упаковку по порядку")

        host.coordinator.beginEditing()
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        assertFrame(host.host.grid.frame(forItemID: "b"), host.cellFrame(row: 0, column: 2))
        host.coordinator.endEditing()
    }

    /// `onChange` хранилища отдаёт снимок с таблицей ячеек, когда ширина сетки
    /// известна (её сообщает координатор); без ширины — прежний снимок.
    func testOnChangeSnapshotCarriesCellTableWhenWidthIsKnown() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: 4,
            tiles: [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 2)],
            in: directory,
            autosaves: false
        )
        var snapshots: [TileGridSnapshot] = []
        store.onChange = { snapshots.append($0) }

        XCTAssertTrue(store.resizeInPlace("a", to: .medium, columns: 4))
        XCTAssertEqual(snapshots.last?.placementTable?.columns, 4)
        XCTAssertEqual(snapshots.last?.placementTable?.cells["b"], at(0, 2))

        let bare = TileStore(directoryURL: TesseraTestDirectory().url)
        bare.autosaves = false
        bare.setCatalog([tesseraTestTile("a", size: .small)])
        var bareSnapshot: TileGridSnapshot?
        bare.onChange = { bareSnapshot = $0 }
        XCTAssertTrue(bare.unpin("a"))
        XCTAssertNil(bareSnapshot?.placementTable, "Хост без ширины — прежний снимок")
    }

    // MARK: - Открепление

    /// Открепление оставляет дыру: остальные плитки не двигаются, ячейка ярлыка
    /// свободна; строка, где остались другие плитки, не схлопывается.
    func testUnpinLeavesHoleWithoutRepacking() throws {
        let host = try makeHoleyHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        let before = host.store.placements(forColumns: 4)
        let bFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        var expected = before
        expected["a"] = nil
        XCTAssertEqual(host.store.placements(forColumns: 4), expected, "Только «a» ушла, остальные на местах")
        XCTAssertTrue(host.waitUntil { host.gridCells == expected })
        assertFrame(host.host.grid.frame(forItemID: "b"), bFrame, "Соседи не двигаются")
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "Дыра на месте «a»")
        host.coordinator.endEditing()
    }

    /// Открепление единственной плитки строки схлопывает пустую строку (D31):
    /// ниже лежащие плитки поднимаются; дыры внутри остальных строк остаются.
    func testUnpinOfOnlyTileInRowCollapsesEmptyRow() throws {
        let host = try makeHoleyHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        host.coordinator.unpin("c")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "b"), at(0, 2), "Дыра в строке 0 осталась")
        // Строка 1 (где была «c») опустела: «w» поднимается на неё.
        XCTAssertEqual(host.store.placement(of: "w"), at(1, 0))
        XCTAssertTrue(host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) })
        host.coordinator.endEditing()
    }

    /// Ярлык в папке открепляется без fly-out (его нет на сетке): последний ярлык
    /// папки убирает папку, её ячейка остаётся дырой.
    func testUnpinOfSoleFolderTileLeavesHoleWhereFolderWas() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small)])]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        host.coordinator.unpin("f1")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placements(forColumns: 4), ["a": at(0, 3)], "Дыра на месте папки, без репака")
        XCTAssertTrue(host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) })
        host.coordinator.endEditing()
    }

    // MARK: - Размер

    /// Стрелка размера: рост на месте выталкивает мешающую плитку вниз каскадом
    /// (D31), якорная ячейка остаётся.
    func testCycleSizeGrowthPushesNeighborDownAndKeepsAnchor() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 1),
                CellFixtureTile("z", .small, 0, 3),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
        XCTAssertEqual(recorder.resizes.count, 1)
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0), "Якорь остался")
        XCTAssertEqual(host.store.placement(of: "b"), at(2, 1), "«b» вытолкнута под плитку 2×2")
        XCTAssertEqual(host.store.placement(of: "z"), at(0, 3), "Не затронутая — на месте")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        assertFrame(host.host.grid.frame(forItemID: "a"), host.cellFrame(row: 0, column: 0, size: .medium))
        host.coordinator.endEditing()
    }

    /// Уменьшение плитки оставляет дыру; если строки, которые она покрывала, опустели,
    /// они схлопываются (D31).
    func testCycleSizeShrinkLeavesHoleAndCollapsesEmptyRows() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("big", .large, 0, 0),
                CellFixtureTile("x", .small, 4, 0),
            ]
        )
        host.coordinator.beginEditing()

        XCTAssertEqual(host.coordinator.cycleSize(of: "big"), .small, "large → small")
        XCTAssertEqual(host.store.placement(of: "big"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "x"), at(1, 0), "Пустые строки 1–3 схлопнулись")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        host.coordinator.endEditing()
    }

    // MARK: - Ширина сетки

    /// Смена числа колонок сообщается хранилищу; при правке сетка пересобирается
    /// под новую ширину, а файл не перезаписывается (холст прежней ширины, D32).
    func testColumnsChangeReportsWidthToStoreAndRebuildsGridWhileEditing() throws {
        let host = try makeHoleyHost()
        XCTAssertEqual(host.store.canvasColumns, 4)
        host.coordinator.beginEditing()

        host.host.grid.columns = 6
        XCTAssertEqual(host.store.effectiveColumns, 6, "Хранилище узнало новую ширину")
        XCTAssertEqual(host.store.canvasColumns, 4, "Файл не перезаписан, пока пользователь ничего не правит")
        XCTAssertEqual(host.host.grid.snapshot?.placementTable?.columns, 6, "Сетка пересобрана под 6 колонок")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 6))
        XCTAssertEqual(host.gridCells?["b"], at(0, 1), "Проекция D32: порядок чтения без дыр")

        host.host.grid.columns = 4
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4), "Возврат к ширине холста возвращает дыры")
        XCTAssertEqual(host.gridCells?["b"], at(0, 2))
        host.coordinator.endEditing()
    }

    /// Смена колонок во время drag отменяет его: база считалась на прежней ширине.
    func testColumnsChangeDuringDragCancelsDrag() throws {
        let host = try makeHoleyHost()
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 1)))

        host.host.grid.columns = 6
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 6))
        XCTAssertGreaterThan(host.host.cell("a")?.contentView.alpha ?? 0, 0.9, "Ячейка снова видима")
    }

    // MARK: - Публичные операции координатора

    /// Публичный `move(toIndex:)` идёт по ячейкам: элемент встаёт на ячейку того,
    /// кто сейчас на этом индексе, тот выталкивается вниз; индекс за концом — в
    /// новую строку; пустая строка схлопывается.
    func testPublicMoveToIndexUsesCells() throws {
        let host = try makeHoleyHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        // Порядок чтения: a (0,0), b (0,2), c (1,3), w (2,0).

        XCTAssertTrue(host.coordinator.move("w", toIndex: 1), "«w» на индекс 1: ячейка «b»")
        XCTAssertEqual(host.store.placement(of: "w"), at(0, 0), "4×2 ограничена холстом до колонки 0")
        XCTAssertEqual(host.storeIDs.first, AnyHashable("w"))
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.index, host.storeIDs.firstIndex(of: "w"))

        let toEnd = host.coordinator.move("a", toIndex: 99)
        XCTAssertTrue(toEnd)
        XCTAssertEqual(host.storeIDs.last, AnyHashable("a"), "Индекс за концом — новая строка")
        XCTAssertEqual(host.store.placement(of: "a")?.column, 0)
        XCTAssertFalse(host.coordinator.move("a", toIndex: 99), "Уже на этом индексе")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
    }

    /// Публичные `createFolder(withTile:)` и `addToFolder` не теряют дыры: ячейки
    /// считаются движком, а не упаковкой по порядку.
    func testPublicFolderOperationsKeepHoles() throws {
        let host = try makeHoleyHost()

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "b", title: "G"))
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 2), "Папка 2×2 на ячейке ярлыка")
        XCTAssertEqual(host.store.placement(of: "c"), at(2, 3), "«c» накрыта папкой и вытолкнута вниз")
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0), "«a» на месте, дыра (0, 1) осталась")

        XCTAssertTrue(host.coordinator.addToFolder("a", folderID: folder.id))
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "Ячейка «a» — дыра")
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 2), "Папка не сдвинулась")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
    }
}

#endif
