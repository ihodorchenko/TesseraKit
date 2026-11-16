//
//  TileResizePushTests.swift
//  TesseraStartScreenTests
//
//  Тесты resize-выталкивания (задача E8.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка» и
//  §5 «Режим редактирования» (resize запускает переупаковку с анимацией),
//  §14 «Уточнения MVP» п. 4 (D15: четыре размера — 1×1, 2×2, 4×2, 4×4).
//
//  Спека WP: при увеличении плитки проверяется свободное место справа; если
//  места нет или там другие плитки, они выталкиваются вниз, освобождая место
//  для нового размера. Цикл размеров остаётся четырёхвидовым
//  (small → medium → wide → large → small).
//
//  Проверяется:
//  - интеграция в `TesseraTileStore.resize(_:to:columns:)` и в resize-цикл
//    координатора (`TesseraTileEditCoordinator.cycleSize(of:)`);
//  - инварианты: набор элементов не теряется и не дублируется, цикл четырёх
//    размеров не сломан.
//
//  Чистая функция `TesseraTileLayoutEngine.resizePlacement` (порядок) удалена в E14.6
//  вместе с тестами на неё: выталкивание вниз при росте и дыра при уменьшении
//  проверены на размещениях — `TileLayoutEnginePlacementTests`,
//  `TileLayoutEnginePlacementPropertyTests` (движок), `TileStoreCellOperationsTests`
//  (хранилище).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileResizePushTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Идентификаторы элементов в порядке массива.
    private func ids(_ items: [TesseraTileGridItem]) -> [AnyHashable] {
        items.map { $0.id }
    }

    /// Слоты компактной упаковки по идентификатору: та же геометрия, что видит
    /// раскладка сетки.
    private func slots(
        _ items: [TesseraTileGridItem],
        columns: Int = 4
    ) -> [AnyHashable: TesseraTileLayoutSlot] {
        let pairs: [(id: AnyHashable, size: TesseraTileSize)] = items.map {
            (id: $0.id, size: $0.size)
        }
        var result: [AnyHashable: TesseraTileLayoutSlot] = [:]
        for slot in TesseraTileLayoutEngine.pack(items: pairs, columns: columns, unit: 1) {
            result[slot.id] = slot
        }
        return result
    }

    private func makeStore(
        _ descriptors: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        store.placeItems(columns: 4)
        return store
    }

    /// Сетка, разложенная без окна: коллекция получает bounds.
    private func makeGrid(store: TesseraTileStore, columns: Int = 4) -> TesseraTileGridView {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        grid.columns = columns
        grid.reload(snapshot: store.snapshot())
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
        return grid
    }

    /// Размер элемента с идентификатором в порядке.
    private func size(
        of id: AnyHashable,
        in items: [TesseraTileGridItem]
    ) -> TesseraTileSize? {
        items.first { $0.id == id }?.size
    }

    // MARK: - Интеграция в TesseraTileStore

    /// `TesseraTileStore.resize(_:to:columns:)` меняет размер и порядок одной
    /// операцией: конфликтующая плитка уходит вниз, снимок сразу даёт новый
    /// порядок, повтор — no-op.
    func testStoreResizeAppliesPushOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)

        XCTAssertEqual(ids(store.snapshot().items), ["a", "b", "c"])
        XCTAssertTrue(store.resize("a", to: .wide, columns: 4))

        let snapshot = store.snapshot()
        XCTAssertEqual(ids(snapshot.items), ["a", "c", "b"])
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)

        let after = slots(snapshot.items)
        XCTAssertEqual(after[AnyHashable("a")]?.row, 0)
        XCTAssertEqual(after[AnyHashable("a")]?.unitColumns, 4)
        XCTAssertEqual(after[AnyHashable("b")]?.row, 2)

        XCTAssertFalse(
            store.resize("a", to: .wide, columns: 4),
            "Повторный resize в тот же размер — no-op"
        )
        XCTAssertEqual(ids(store.snapshot().items), ["a", "c", "b"])
    }

    /// Resize папки идёт той же push-семантикой; ярлык внутри папки меняет
    /// только размер и порядок сетки не трогает.
    func testStoreResizeFolderPushesConflictsAndKeepsLayoutOrder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: 4))
        XCTAssertEqual(ids(store.snapshot().items), [folder.id, "b", "c"])

        XCTAssertTrue(store.resize(folder.id, to: .wide, columns: 4))
        XCTAssertEqual(ids(store.snapshot().items), [folder.id, "c", "b"])
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)

        // Ярлык внутри папки на сетке не стоит: переставлять нечего.
        XCTAssertTrue(store.resize("a", to: .large, columns: 4))
        XCTAssertEqual(ids(store.snapshot().items), [folder.id, "c", "b"])
        XCTAssertEqual(
            store.folderContaining("a")?.tiles.first?.size,
            .large
        )
    }

    // MARK: - Цикл размеров координатора

    /// Цикл small → medium → wide → large → small не сломан: координатор
    /// передаёт число колонок сетки, порядок переставляется push-семантикой,
    /// набор элементов сохраняется на каждом шаге.
    func testCycleSizeKeepsFourSizeCycleWithPush() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)
        let allIDs = Set<AnyHashable>(["a", "b", "c"])

        // E15.3 (D28): полный круг D15 в порядке W10M — medium → large → small →
        // wide → medium; набор элементов сохраняется на каждом шаге.
        for expected in [TesseraTileSize.large, .small, .wide, .medium] {
            XCTAssertEqual(editor.cycleSize(of: "a"), expected)
            XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs, "после \(expected)")
            XCTAssertEqual(Set(ids(grid.items)), allIDs, "сетка после \(expected)")
        }
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
        XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs)
        XCTAssertEqual(size(of: AnyHashable("b"), in: grid.items), .medium)
        XCTAssertEqual(size(of: AnyHashable("c"), in: grid.items), .small)
    }

    /// Рост 2×2 → 4×2 выталкивает соседа вниз (прежняя проверка шага medium → wide:
    /// в цикле D28 из medium следующий — large, поэтому набор сужен до medium/wide).
    func testCycleSizeMediumToWidePushesRightNeighborDown() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)
        editor.supportedSizesProvider = { _ in [.medium, .wide] }

        // medium → wide: b справа конфликтует и уходит вниз.
        XCTAssertEqual(editor.cycleSize(of: "a"), .wide)
        XCTAssertEqual(ids(store.snapshot().items), ["a", "c", "b"])
        XCTAssertEqual(ids(grid.items), ["a", "c", "b"])
    }
}

#endif
