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
//  - чистая функция `TileLayoutEngine.resizePlacement` — порядок и итоговая
//    компактная геометрия (`pack` того же набора);
//  - интеграция в `TileStore.resize(_:to:columns:)` и в resize-цикл
//    координатора (`TesseraTileEditCoordinator.cycleSize(of:)`);
//  - инварианты: набор элементов не теряется и не дублируется, уменьшение не
//    выталкивает соседей, цикл четырёх размеров не сломан.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileResizePushTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Элементы сетки из пар «идентификатор — размер» в порядке сетки.
    private func makeItems(_ sizes: [(String, TileSize)]) -> [TileGridItem] {
        sizes.map { TileGridItem.tile(tesseraTestTile($0.0, size: $0.1)) }
    }

    /// Идентификаторы элементов в порядке массива.
    private func ids(_ items: [TileGridItem]) -> [AnyHashable] {
        items.map { $0.id }
    }

    /// Слоты компактной упаковки по идентификатору: та же геометрия, что видит
    /// раскладка сетки.
    private func slots(
        _ items: [TileGridItem],
        columns: Int = 4
    ) -> [AnyHashable: TileLayoutSlot] {
        let pairs: [(id: AnyHashable, size: TileSize)] = items.map {
            (id: $0.id, size: $0.size)
        }
        var result: [AnyHashable: TileLayoutSlot] = [:]
        for slot in TileLayoutEngine.pack(items: pairs, columns: columns, unit: 1) {
            result[slot.id] = slot
        }
        return result
    }

    private func makeStore(
        _ descriptors: [TileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        return store
    }

    /// Сетка, разложенная без окна: коллекция получает bounds.
    private func makeGrid(store: TileStore, columns: Int = 4) -> TesseraTileGridView {
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
        in items: [TileGridItem]
    ) -> TileSize? {
        items.first { $0.id == id }?.size
    }

    // MARK: - Увеличение при свободном месте справа

    /// medium → wide, справа свободно: порядок не меняется, плитка остаётся в
    /// (0,0), соседи снизу не трогаются.
    func testIncreaseWithFreeSpaceKeepsOrderAndNeighbors() throws {
        let items = makeItems([
            ("a", .medium),
            ("b", .wide),
            ("c", .large),
        ])
        let before = slots(items)

        // Обе соседние плитки стоят ниже (wide/large справа не помещаются),
        // поэтому целевой след (0,0) 4×2 свободен.
        XCTAssertEqual(before[AnyHashable("b")]?.row, 2)
        XCTAssertEqual(before[AnyHashable("c")]?.row, 4)

        let result = TileLayoutEngine.resizePlacement(
            items: items,
            resizingID: AnyHashable("a"),
            newSize: .wide,
            columns: 4
        )

        XCTAssertEqual(ids(result), ids(items), "Порядок не должен меняться")
        XCTAssertEqual(size(of: AnyHashable("a"), in: result), .wide)

        let after = slots(result)
        XCTAssertEqual(after[AnyHashable("a")]?.column, 0)
        XCTAssertEqual(after[AnyHashable("a")]?.row, 0)
        XCTAssertEqual(after[AnyHashable("a")]?.unitColumns, 4)

        // Соседи не тронуты: их слоты совпадают с прежними.
        XCTAssertEqual(after[AnyHashable("b")], before[AnyHashable("b")])
        XCTAssertEqual(after[AnyHashable("c")], before[AnyHashable("c")])
    }

    // MARK: - Увеличение при занятом месте справа

    /// medium → wide, справа стоит medium: соседняя плитка уезжает вниз,
    /// изменённая остаётся в (0,0), порядок детерминирован.
    func testIncreaseWithOccupiedRightPushesConflictDown() throws {
        let items = makeItems([
            ("a", .medium),
            ("b", .medium),
            ("c", .small),
        ])
        let before = slots(items)
        XCTAssertEqual(before[AnyHashable("b")]?.column, 2, "b стоит справа от a")
        XCTAssertEqual(before[AnyHashable("c")]?.row, 2, "c стоит ниже a")

        let result = TileLayoutEngine.resizePlacement(
            items: items,
            resizingID: AnyHashable("a"),
            newSize: .wide,
            columns: 4
        )

        // Конфликтующая b уходит в конец порядка и встаёт ниже; c остаётся
        // раньше и на своём месте.
        XCTAssertEqual(ids(result), ["a", "c", "b"])
        XCTAssertEqual(size(of: AnyHashable("a"), in: result), .wide)

        let after = slots(result)
        let resized = try XCTUnwrap(after[AnyHashable("a")])
        XCTAssertEqual(resized.column, 0)
        XCTAssertEqual(resized.row, 0)
        XCTAssertEqual(after[AnyHashable("c")], before[AnyHashable("c")])

        let pushed = try XCTUnwrap(after[AnyHashable("b")])
        XCTAssertEqual(pushed.row, 2, "b вытолкнута вниз")
        XCTAssertGreaterThan(pushed.row, before[AnyHashable("b")]?.row ?? 0)
        XCTAssertFalse(pushed.unitFrame.intersects(resized.unitFrame))
    }

    /// Рост вниз (wide 4×2 → large 4×4): плитки под следом выталкиваются ниже,
    /// а колонка и строка изменённой плитки сохраняются.
    func testIncreaseDownwardsPushesLowerTiles() throws {
        let items = makeItems([
            ("a", .wide),
            ("b", .medium),
            ("c", .small),
        ])
        let before = slots(items)
        XCTAssertEqual(before[AnyHashable("b")]?.row, 2)
        XCTAssertEqual(before[AnyHashable("c")]?.row, 2)

        let result = TileLayoutEngine.resizePlacement(
            items: items,
            resizingID: AnyHashable("a"),
            newSize: .large,
            columns: 4
        )

        XCTAssertEqual(ids(result), ids(items), "Конфликты уже идут в порядке чтения")
        let after = slots(result)
        XCTAssertEqual(after[AnyHashable("a")]?.row, 0)
        XCTAssertEqual(after[AnyHashable("a")]?.column, 0)
        XCTAssertEqual(after[AnyHashable("a")]?.unitRows, 4)

        for id in [AnyHashable("b"), AnyHashable("c")] {
            let slot = try XCTUnwrap(after[id])
            XCTAssertGreaterThanOrEqual(slot.row, 4, "Плитка \(id) должна уйти под large")
        }
    }

    // MARK: - Уменьшение

    /// Уменьшение не выталкивает соседей: новый след — подмножество старого,
    /// поэтому порядок остаётся прежним (соседи могут подняться компактно).
    func testShrinkKeepsOrderAndDoesNotPush() throws {
        let items = makeItems([
            ("a", .wide),
            ("b", .medium),
            ("c", .small),
        ])
        let before = slots(items)
        XCTAssertEqual(before[AnyHashable("b")]?.row, 2)

        for newSize in [TileSize.medium, .small] {
            let result = TileLayoutEngine.resizePlacement(
                items: items,
                resizingID: AnyHashable("a"),
                newSize: newSize,
                columns: 4
            )

            XCTAssertEqual(ids(result), ids(items), "Уменьшение не меняет порядок")
            XCTAssertEqual(size(of: AnyHashable("a"), in: result), newSize)

            let after = slots(result)
            XCTAssertEqual(after[AnyHashable("a")]?.column, 0)
            XCTAssertEqual(after[AnyHashable("a")]?.row, 0)

            // Соседи не «проваливаются»: компактная упаковка может поднять их
            // вверх, но не вниз.
            XCTAssertLessThanOrEqual(
                after[AnyHashable("b")]?.row ?? Int.max,
                before[AnyHashable("b")]?.row ?? 0
            )
            XCTAssertLessThanOrEqual(
                after[AnyHashable("c")]?.row ?? Int.max,
                before[AnyHashable("c")]?.row ?? 0
            )
        }
    }

    // MARK: - Перенос влево (не помещается в своей колонке)

    /// small в последней колонке → medium: плитка прижимается влево, строка
    /// сохраняется, а плитка слева, попавшая в новый след, уходит вниз.
    func testIncreaseNearRightEdgeKeepsRowAndPushesLeftConflictDown() throws {
        let items = makeItems([
            ("a", .small),
            ("b", .medium),
            ("c", .small),
        ])
        let before = slots(items)
        XCTAssertEqual(before[AnyHashable("c")]?.column, 3)

        let result = TileLayoutEngine.resizePlacement(
            items: items,
            resizingID: AnyHashable("c"),
            newSize: .medium,
            columns: 4
        )

        XCTAssertEqual(ids(result), ["a", "c", "b"])
        let after = slots(result)
        XCTAssertEqual(after[AnyHashable("c")]?.row, 0, "Строка сохраняется")
        XCTAssertEqual(after[AnyHashable("c")]?.unitColumns, 2)
        XCTAssertGreaterThanOrEqual(after[AnyHashable("b")]?.row ?? 0, 2)
    }

    // MARK: - Инварианты и вырожденные случаи

    /// Для любого элемента и любого размера D15 результат — перестановка
    /// исходного набора: элементы не теряются и не дублируются, размер
    /// меняется только у изменённой плитки, результат детерминирован.
    func testResizePlacementIsPermutationForAllSizes() {
        let items = makeItems([
            ("a", .medium),
            ("b", .small),
            ("c", .wide),
            ("d", .large),
            ("e", .medium),
        ])
        let allIDs = ids(items)

        for element in items {
            for newSize in TileSize.allCases {
                let result = TileLayoutEngine.resizePlacement(
                    items: items,
                    resizingID: element.id,
                    newSize: newSize,
                    columns: 4
                )

                XCTAssertEqual(result.count, items.count)
                XCTAssertEqual(Set(ids(result)), Set(allIDs))
                XCTAssertEqual(
                    result.filter { $0.id == element.id }.count,
                    1,
                    "Элемент не должен дублироваться"
                )
                XCTAssertEqual(size(of: element.id, in: result), newSize)

                for other in items where other.id != element.id {
                    XCTAssertEqual(
                        size(of: other.id, in: result),
                        other.size,
                        "Размер соседа \(other.id) не меняется"
                    )
                }

                // Детерминизм: повторный вызов даёт тот же порядок.
                XCTAssertEqual(
                    ids(TileLayoutEngine.resizePlacement(
                        items: items,
                        resizingID: element.id,
                        newSize: newSize,
                        columns: 4
                    )),
                    ids(result)
                )
            }
        }
    }

    /// Вырожденные случаи возвращают вход без изменений: неизвестный
    /// идентификатор, панель раскрытой папки в наборе и сама панель как цель.
    func testResizePlacementReturnsInputForDegenerateCases() {
        let items = makeItems([
            ("a", .medium),
            ("b", .small),
        ])

        let unknown = TileLayoutEngine.resizePlacement(
            items: items,
            resizingID: AnyHashable("missing"),
            newSize: .wide,
            columns: 4
        )
        XCTAssertEqual(ids(unknown), ids(items))
        XCTAssertEqual(unknown.map { $0.size }, items.map { $0.size })

        let panel = TileGridItem.folderContent(
            TileFolder(id: AnyHashable("folder"), title: "Папка", tiles: [tesseraTestTile("t")])
        )
        let withPanel = [items[0], panel, items[1]]
        let resized = TileLayoutEngine.resizePlacement(
            items: withPanel,
            resizingID: AnyHashable("a"),
            newSize: .wide,
            columns: 4
        )
        XCTAssertEqual(ids(resized), ids(withPanel))

        let panelTarget = TileLayoutEngine.resizePlacement(
            items: withPanel,
            resizingID: AnyHashable("folder"),
            newSize: .large,
            columns: 4
        )
        XCTAssertEqual(ids(panelTarget), ids(withPanel))

        XCTAssertEqual(
            ids(TileLayoutEngine.resizePlacement(
                items: items,
                resizingID: AnyHashable("a"),
                newSize: .wide,
                columns: 0
            )),
            ids(items)
        )
    }

    // MARK: - Интеграция в TileStore

    /// `TileStore.resize(_:to:columns:)` меняет размер и порядок одной
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
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A"))
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

    /// Старый вход `resize(_:to:)` использует каноническую сетку D15 (4
    /// колонки) и ту же push-семантику.
    func testStoreResizeWithoutColumnsUsesCanonicalGrid() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)

        XCTAssertTrue(store.resize("a", to: .wide))
        XCTAssertEqual(ids(store.snapshot().items), ["a", "c", "b"])
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)
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

        // medium → wide: b справа конфликтует и уходит вниз.
        XCTAssertEqual(editor.cycleSize(of: "a"), .wide)
        XCTAssertEqual(ids(store.snapshot().items), ["a", "c", "b"])
        XCTAssertEqual(ids(grid.items), ["a", "c", "b"])
        XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs)

        // wide → large → small → medium: полный круг D15.
        XCTAssertEqual(editor.cycleSize(of: "a"), .large)
        XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs)

        XCTAssertEqual(editor.cycleSize(of: "a"), .small)
        XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs)

        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
        XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs)
        XCTAssertEqual(size(of: AnyHashable("b"), in: grid.items), .medium)
        XCTAssertEqual(size(of: AnyHashable("c"), in: grid.items), .small)
    }
}

#endif
