//
//  TilePlacementGridTests.swift
//  TesseraStartScreenTests
//
//  Сетка со снимком, несущим таблицу явных ячеек (E14.3, D30). Проектный
//  документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка» и «Отступления
//  реализации (E14)», п. 51; решения D30–D33 в docs/STATE.md.
//
//  Проверяется `TesseraTileGridView`:
//  - `baseContentFrames(for:placementTable:)` берёт слоты из того же источника,
//    что раскладка: рамки совпадают с тем, что рисует сетка, — для снимка с
//    дырами, при откате на упаковку и в RTL;
//  - раскрытие папки на снимке с дырами: индекс панели считается по ячейкам, строки
//    ниже полосы сдвигаются без репака;
//  - дифф снимка: смена одних ячеек (те же элементы в том же порядке) —
//    изменение раскладки и анимируется как перестановка; тот же снимок кадры не
//    меняет;
//  - `TesseraTileStore.snapshot(columns:)` для другой ширины сетки игнорируется (рамки
//    упаковки); равенство рамок сетки и ячеек модели после операций — в
//    `TileCellWiringTests` (после E14.6 операции оставляют дыры, и прежнее
//    сравнение «таблица = упаковка» потеряло смысл);
//  - магнитные центры без таблицы остаются на упаковке по порядку.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePlacementGridTests: XCTestCase {

    // MARK: - Вспомогательные средства

    private func cell(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    private func small(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .small)) }
    private func medium(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .medium)) }

    private func layoutGrid(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    private func makeGrid(
        columns: Int = 4,
        width: CGFloat = 390,
        rightToLeft: Bool = false
    ) -> TesseraTileGridView {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        grid.columns = columns
        if rightToLeft {
            grid.semanticContentAttribute = .forceRightToLeft
            grid.subviews
                .compactMap { $0 as? UICollectionView }
                .forEach { $0.semanticContentAttribute = .forceRightToLeft }
        }
        return grid
    }

    /// Снимок с дырами: a и b в первой строке с зазором, c ниже и правее.
    private func holeSnapshot(columns: Int = 4) -> TesseraTileGridSnapshot {
        TesseraTileGridSnapshot(
            items: [small("a"), small("b"), medium("c")],
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(
                cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(3, 1)],
                columns: columns
            )
        )
    }

    private func assertClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 0.01, "\(message): x", file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 0.01, "\(message): y", file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.01, "\(message): w", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 0.01, "\(message): h", file: file, line: line)
    }

    /// Рамки сетки по идентификаторам (координаты сетки).
    private func gridFrames(_ grid: TesseraTileGridView, ids: [AnyHashable]) throws -> [AnyHashable: CGRect] {
        var result: [AnyHashable: CGRect] = [:]
        for id in ids { result[id] = try XCTUnwrap(grid.frame(forItemID: id), "рамка \(id)") }
        return result
    }

    // MARK: - baseContentFrames

    /// Рамки базовой раскладки совпадают с тем, что рисует сетка, — для снимка с
    /// дырами; без таблицы они прежние (упаковка), и это другая картинка.
    func testBaseContentFramesMatchLayoutForSnapshotWithHoles() throws {
        let grid = makeGrid()
        let snapshot = holeSnapshot()
        grid.reload(snapshot: snapshot)
        layoutGrid(grid)

        let ids = snapshot.items.map { $0.id }
        let drawn = try gridFrames(grid, ids: ids)
        let base = try XCTUnwrap(grid.baseContentFrames(for: snapshot.items, placementTable: snapshot.placementTable))
        for id in ids {
            assertClose(grid.gridFrame(fromContentFrame: try XCTUnwrap(base[id])), try XCTUnwrap(drawn[id]), "\(id)")
        }

        // Без таблицы — упаковка по порядку: c поднимается к a и b.
        let packed = try XCTUnwrap(grid.baseContentFrames(for: snapshot.items))
        XCTAssertLessThan(try XCTUnwrap(packed["c"]).minY, try XCTUnwrap(base["c"]).minY)
    }

    /// Негодная таблица: рамки и сетки, и базовой раскладки — упаковка по порядку.
    func testInvalidTableFallsBackInGridAndBaseFrames() throws {
        let items: [TesseraTileGridItem] = [small("a"), small("b"), medium("c")]
        let broken = TesseraTileGridPlacementTable(
            cells: ["a": cell(0, 0), "b": cell(0, 0), "c": cell(3, 1)],
            columns: 4
        )

        let reference = makeGrid()
        reference.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layoutGrid(reference)

        let grid = makeGrid()
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: [], placementTable: broken))
        layoutGrid(grid)

        let base = try XCTUnwrap(grid.baseContentFrames(for: items, placementTable: broken))
        for item in items {
            assertClose(
                try XCTUnwrap(grid.frame(forItemID: item.id)),
                try XCTUnwrap(reference.frame(forItemID: item.id)),
                "сетка \(item.id)"
            )
            assertClose(
                grid.gridFrame(fromContentFrame: try XCTUnwrap(base[item.id])),
                try XCTUnwrap(reference.frame(forItemID: item.id)),
                "базовая раскладка \(item.id)"
            )
        }
    }

    /// RTL: базовые рамки с дырами совпадают с зеркальной раскладкой сетки.
    func testBaseContentFramesMatchLayoutInRightToLeft() throws {
        let grid = makeGrid(rightToLeft: true)
        let snapshot = holeSnapshot()
        grid.reload(snapshot: snapshot)
        layoutGrid(grid)

        let base = try XCTUnwrap(grid.baseContentFrames(for: snapshot.items, placementTable: snapshot.placementTable))
        for item in snapshot.items {
            assertClose(
                grid.gridFrame(fromContentFrame: try XCTUnwrap(base[item.id])),
                try XCTUnwrap(grid.frame(forItemID: item.id)),
                "\(item.id)"
            )
        }
        // Логическая колонка 0 в RTL — правая: a правее b.
        XCTAssertGreaterThan(try XCTUnwrap(base["a"]).minX, try XCTUnwrap(base["b"]).minX)
    }

    // MARK: - Раскрытие папки

    /// Раскрытие папки на снимке с дырами: индекс панели по ячейкам, строки
    /// ниже полосы сдвинуты на панель без репака; магнит при открытой папке
    /// по-прежнему пуст.
    func testOpeningFolderKeepsHolesBelowBand() throws {
        let folder = tesseraTestFolder("f", tileCount: 6)
        let items: [TesseraTileGridItem] = [.folder(folder), small("s"), small("x"), small("y")]
        let table = TesseraTileGridPlacementTable(
            cells: ["f": cell(0, 0), "s": cell(0, 2), "x": cell(5, 0), "y": cell(8, 3)],
            columns: 4
        )
        let grid = makeGrid()
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: [], placementTable: table))
        layoutGrid(grid)

        let closedX = try XCTUnwrap(grid.frame(forItemID: "x"))
        let closedY = try XCTUnwrap(grid.frame(forItemID: "y"))

        grid.openFolder(folder, animated: false)
        layoutGrid(grid)

        // Панель — после s (последняя плитка полосы), до x и y.
        let panelIndex = try XCTUnwrap(grid.displayItems.firstIndex { $0.isFolderPanel })
        XCTAssertEqual(
            panelIndex,
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: items.map { TesseraTilePlacedItem(id: $0.id, size: $0.size, cell: table.cells[$0.id]!) },
                columns: 4,
                expandedFolderID: folder.id
            )
        )
        XCTAssertEqual(panelIndex, 2)

        let openX = try XCTUnwrap(grid.frame(forItemID: "x"))
        let openY = try XCTUnwrap(grid.frame(forItemID: "y"))
        XCTAssertEqual(openX.minY - closedX.minY, openY.minY - closedY.minY, accuracy: 0.01, "оба сдвинуты одинаково")
        XCTAssertGreaterThan(openX.minY - closedX.minY, 0, "сдвиг вниз на панель")
        XCTAssertEqual(openY.minY - openX.minY, closedY.minY - closedX.minY, accuracy: 0.01, "дыра между x и y сохранена")
        XCTAssertTrue(grid.magnetSlotCenters(for: .small).isEmpty, "при открытой папке магнит пуст")

        grid.closeFolder(animated: false)
        layoutGrid(grid)
        assertClose(try XCTUnwrap(grid.frame(forItemID: "x")), closedX, "x вернулась")
        assertClose(try XCTUnwrap(grid.frame(forItemID: "y")), closedY, "y вернулась")
    }

    // MARK: - Дифф снимка

    /// Смена одних ячеек (те же элементы в том же порядке) — изменение
    /// раскладки: идёт веткой «тот же состав» с batch-анимацией (не кроссфейд и
    /// не мгновенно) и доезжает до новых рамок.
    func testCellOnlyChangeIsDetectedAndAnimatesLikeReorder() throws {
        let host = TesseraTestWindowedGrid(columns: 4)
        host.grid.isReduceMotionEnabled = { false }
        host.grid.reload(snapshot: holeSnapshot())
        host.layout()

        let beforeC = try XCTUnwrap(host.grid.frame(forItemID: "c"))
        let beforeA = try XCTUnwrap(host.grid.frame(forItemID: "a"))

        let moved = TesseraTileGridSnapshot(
            items: holeSnapshot().items,
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(
                cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(6, 0)],
                columns: 4
            )
        )
        host.grid.update(snapshot: moved, animated: true)

        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade, "переезд, а не кроссфейд")
        XCTAssertFalse(host.grid.didApplyLastSnapshotWithoutAnimation, "переезд анимируется")

        let arrived = host.waitUntil(timeout: 3) {
            guard let frame = host.grid.frame(forItemID: "c") else { return false }
            return frame.minY > beforeC.minY + 1
        }
        XCTAssertTrue(arrived, "c доехала до новой ячейки")
        host.layout()
        let afterC = try XCTUnwrap(host.grid.frame(forItemID: "c"))
        XCTAssertGreaterThan(afterC.minY, beforeC.minY)
        XCTAssertEqual(afterC.minX, try XCTUnwrap(host.grid.baseContentFrames(for: moved.items, placementTable: moved.placementTable)?["c"]).minX, accuracy: 0.01)
        assertClose(try XCTUnwrap(host.grid.frame(forItemID: "a")), beforeA, "a не двигалась")
    }

    /// Тот же снимок кадры не меняет: ни при анимированном, ни при
    /// неанимированном применении.
    func testUnchangedSnapshotDoesNotMoveAnything() throws {
        let host = TesseraTestWindowedGrid(columns: 4)
        host.grid.isReduceMotionEnabled = { false }
        let snapshot = holeSnapshot()
        host.grid.reload(snapshot: snapshot)
        host.layout()
        let ids = snapshot.items.map { $0.id }
        let before = try gridFrames(host.grid, ids: ids)

        host.grid.update(snapshot: snapshot, animated: true)
        host.spin(0.5)
        host.layout()
        host.grid.update(snapshot: snapshot, animated: false)
        host.layout()

        let after = try gridFrames(host.grid, ids: ids)
        for id in ids {
            assertClose(try XCTUnwrap(after[id]), try XCTUnwrap(before[id]), "\(id)")
        }
    }

    /// Неанимированная смена ячеек применяется сразу (`reload`): рамки новые
    /// без ожидания анимации.
    func testCellOnlyChangeAppliesImmediatelyWithoutAnimation() throws {
        let grid = makeGrid()
        grid.reload(snapshot: holeSnapshot())
        layoutGrid(grid)
        let before = try XCTUnwrap(grid.frame(forItemID: "c"))

        grid.reload(snapshot: TesseraTileGridSnapshot(
            items: holeSnapshot().items,
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(
                cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(5, 1)],
                columns: 4
            )
        ))
        layoutGrid(grid)
        XCTAssertGreaterThan(try XCTUnwrap(grid.frame(forItemID: "c")).minY, before.minY)
    }

    // MARK: - Магнит

    /// `magnetSlotCenters` на снимке без таблицы остаётся на упаковке по
    /// порядку (откат E14.3): снимок с дырами, поданный без таблицы, его не
    /// ломает. `baseInsertionIndex` (позиция вставки по порядку) удалён в E14.6.
    func testMagnetStaysPackBasedOnSnapshotWithoutTable() throws {
        let grid = makeGrid()
        let snapshot = holeSnapshot()
        grid.reload(snapshot: snapshot)
        layoutGrid(grid)

        XCTAssertFalse(grid.magnetSlotCenters(for: .small).isEmpty)
    }

    // MARK: - Снимок хранилища

    /// Случайный каталог: ярлыки разных размеров (малые чаще).
    private func randomCatalog(seed: UInt64, count: Int) -> [TesseraTileDescriptor] {
        var generator = TesseraTestSeededGenerator(seed: seed)
        let sizes: [TesseraTileSize] = [.small, .small, .medium, .medium, .wide, .large]
        return (0..<count).map { index in
            tesseraTestTile("t\(index)", size: sizes[generator.int(upperBound: sizes.count)])
        }
    }

    /// Таблица для другой ширины сетки игнорируется: рамки прежние.
    func testStoreSnapshotForOtherWidthFallsBackToPack() throws {
        let directory = TesseraTestDirectory()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(randomCatalog(seed: 5, count: 12))
        store.placeItems(columns: 6)

        let legacy = makeGrid(columns: 4)
        legacy.reload(snapshot: store.snapshot())
        layoutGrid(legacy)

        let grid = makeGrid(columns: 4)
        grid.reload(snapshot: store.snapshot(columns: 6))
        layoutGrid(grid)

        for item in store.snapshot().items {
            assertClose(
                try XCTUnwrap(grid.frame(forItemID: item.id)),
                try XCTUnwrap(legacy.frame(forItemID: item.id)),
                "\(item.id)"
            )
        }
        XCTAssertNil(store.snapshot(columns: 0).placementTable)
    }
}

#endif
