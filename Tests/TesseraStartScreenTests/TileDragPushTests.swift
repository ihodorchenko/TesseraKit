//
//  TileDragPushTests.swift
//  TesseraStartScreenTests
//
//  Тесты push-физики перетаскивания (задача E8.4).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5 «Режим редактирования»
//  и docs/PLAN.md E8.4: при наведении на плитку-цель перетаскиваемая плитка
//  встаёт в слот цели, а цель и плитки под ней сдвигаются вниз; порядок —
//  превью без записи в `TileStore`, фиксация — только на drop.
//
//  Проверяется чистая функция `TileLayoutEngine.previewOrder` (никакого UI):
//  направление сдвига, граничные позиции, стабильность остальных элементов,
//  отсутствие накопления сдвигов между целями, папки и вырожденные случаи.
//  Отдельный тест подтверждает контракт фиксации: `TileStore.move` по индексу
//  перетаскиваемой плитки в превью даёт ровно превью-порядок — координатор
//  опирается на это в `finishDrag(commit: true)`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileDragPushTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Элементы сетки из ярлыков small в заданном порядке.
    ///
    /// - Parameter ids: Идентификаторы ярлыков в порядке сетки.
    /// - Returns: Элементы снимка.
    private func makeItems(_ ids: [String]) -> [TileGridItem] {
        ids.map { TileGridItem.tile(tesseraTestTile($0, size: .small)) }
    }

    /// Индекс элемента в превью-порядке.
    ///
    /// - Parameters:
    ///   - id: Идентификатор элемента.
    ///   - items: Порядок сетки.
    /// - Returns: Индекс или `-1`.
    private func index(of id: AnyHashable, in items: [TileGridItem]) -> Int {
        items.firstIndex { $0.id == id } ?? -1
    }

    /// Хранилище с ярлыками small в порядке каталога.
    ///
    /// - Parameters:
    ///   - ids: Идентификаторы ярлыков.
    ///   - directory: Временный каталог теста.
    /// - Returns: Настроенное хранилище без автосохранения.
    private func makeStore(
        _ ids: [String],
        in directory: TesseraTestDirectory
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(ids.map { tesseraTestTile($0, size: .small) })
        return store
    }

    // MARK: - Направление сдвига

    /// Перетаскивание вниз: плитка встаёт в слот цели, а плитки между старой и
    /// новой позицией сдвигаются вверх, заполняя освободившийся слот.
    func testPreviewDownwardPlacesDraggedTileInTargetSlot() {
        let base = makeItems(["a", "b", "c", "d"])

        let preview = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "a",
            targetID: "c"
        )

        XCTAssertEqual(tesseraTestIDs(preview ?? []), ["b", "c", "a", "d"])
        // Целевой индекс — исходный индекс цели (2), он же индекс плитки в
        // превью и аргумент `TileStore.move` при фиксации.
        XCTAssertEqual(index(of: "a", in: preview ?? []), index(of: "c", in: base))
        XCTAssertEqual(index(of: "a", in: preview ?? []), 2)
    }

    /// Перетаскивание вверх: цель и все плитки под ней сдвигаются ровно на одну
    /// позицию вниз — ради этого сдвига слот цели и освобождается.
    func testPreviewUpwardPushesTargetAndBelowDown() {
        let base = makeItems(["a", "b", "c", "d"])

        let preview = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "d",
            targetID: "b"
        ) ?? []

        XCTAssertEqual(tesseraTestIDs(preview), ["a", "d", "b", "c"])
        for pushedID in ["b", "c"] {
            XCTAssertEqual(
                index(of: pushedID, in: preview),
                index(of: pushedID, in: base) + 1,
                "Плитка \(pushedID) должна сдвинуться на одну позицию вниз"
            )
        }
        // Верхняя плитка не участвует в сдвиге.
        XCTAssertEqual(index(of: "a", in: preview), 0)
    }

    /// Соседняя пара: перетаскивание вниз и вверх меняет плитки местами.
    /// Отдельно проверяется нижнее направление — без него перестановку
    /// «на одну позицию вниз» сделать было бы нельзя.
    func testPreviewSwapsAdjacentTilesInBothDirections() {
        let base = makeItems(["a", "b"])

        let downward = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "a",
            targetID: "b"
        )
        let upward = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "b",
            targetID: "a"
        )

        XCTAssertEqual(tesseraTestIDs(downward ?? []), ["b", "a"])
        XCTAssertEqual(tesseraTestIDs(upward ?? []), ["b", "a"])
    }

    // MARK: - Границы

    /// Перетаскивание на последнюю и на первую позицию.
    func testPreviewHandlesFirstAndLastTargets() {
        let base = makeItems(["a", "b", "c", "d"])

        let toLast = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "a",
            targetID: "d"
        )
        let toFirst = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "d",
            targetID: "a"
        )

        XCTAssertEqual(tesseraTestIDs(toLast ?? []), ["b", "c", "d", "a"])
        XCTAssertEqual(tesseraTestIDs(toFirst ?? []), ["d", "a", "b", "c"])
    }

    /// Список из одного элемента и перестановка «сам на себя» вырождены.
    func testPreviewReturnsNilWhenThereIsNothingToReorder() {
        let single = makeItems(["a"])
        let base = makeItems(["a", "b"])

        XCTAssertNil(
            TileLayoutEngine.previewOrder(items: single, draggingID: "a", targetID: "a")
        )
        XCTAssertNil(
            TileLayoutEngine.previewOrder(items: base, draggingID: "a", targetID: "a")
        )
    }

    /// Отсутствие участников в наборе — вырожденный случай.
    func testPreviewReturnsNilForUnknownIdentifiers() {
        let base = makeItems(["a", "b"])

        XCTAssertNil(
            TileLayoutEngine.previewOrder(items: base, draggingID: "missing", targetID: "b")
        )
        XCTAssertNil(
            TileLayoutEngine.previewOrder(items: base, draggingID: "a", targetID: "missing")
        )
        XCTAssertNil(
            TileLayoutEngine.previewOrder(items: [], draggingID: "a", targetID: "b")
        )
    }

    // MARK: - Стабильность и отсутствие накопления

    /// Пересчёт от базового порядка: смена цели не накапливает сдвиги, а
    /// возврат к прежней цели даёт прежний порядок.
    func testPreviewDoesNotAccumulateBetweenTargets() {
        let base = makeItems(["a", "b", "c", "d"])

        let overC = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "a",
            targetID: "c"
        )
        let overB = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "a",
            targetID: "b"
        )
        let backToC = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "a",
            targetID: "c"
        )

        XCTAssertEqual(tesseraTestIDs(overC ?? []), ["b", "c", "a", "d"])
        XCTAssertEqual(tesseraTestIDs(overB ?? []), ["b", "a", "c", "d"])
        // Если бы превью считалось от предыдущего результата, здесь был бы
        // сдвиг на два слота.
        XCTAssertEqual(tesseraTestIDs(backToC ?? []), tesseraTestIDs(overC ?? []))
    }

    /// Меняется только положение перетаскиваемой плитки: состав, размеры и
    /// относительный порядок остальных элементов сохраняются.
    func testPreviewKeepsOtherItemsStable() {
        let base: [TileGridItem] = [
            .tile(tesseraTestTile("a", size: .small)),
            .tile(tesseraTestTile("b", size: .medium)),
            .tile(tesseraTestTile("c", size: .wide)),
            .tile(tesseraTestTile("d", size: .small)),
        ]

        let preview = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "c",
            targetID: "a"
        ) ?? []

        XCTAssertEqual(preview.count, base.count)
        XCTAssertEqual(Set(tesseraTestIDs(preview)), Set(tesseraTestIDs(base)))
        XCTAssertEqual(preview.first?.size, .wide)
        XCTAssertEqual(
            preview.filter { $0.id != AnyHashable("c") }.map { $0.id },
            base.filter { $0.id != AnyHashable("c") }.map { $0.id }
        )
    }

    // MARK: - Папки

    /// Плитка-папка участвует в перестановке как обычный элемент, а её
    /// содержимое не меняется.
    func testPreviewReordersFolderTileWithoutTouchingContents() {
        let folder = TileFolder(
            id: "f",
            title: "Работа",
            tiles: [tesseraTestTile("x"), tesseraTestTile("y")]
        )
        let base: [TileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folder(folder),
            .tile(tesseraTestTile("b")),
        ]

        let preview = TileLayoutEngine.previewOrder(
            items: base,
            draggingID: "b",
            targetID: "f"
        ) ?? []

        XCTAssertEqual(tesseraTestIDs(preview), ["a", "b", "f"])
        XCTAssertEqual(
            preview.compactMap { $0.folder }.first?.tiles.map { $0.id } ?? [],
            ["x", "y"]
        )
    }

    /// Панель раскрытой папки (D17) — не плитка: ни как цель, ни как
    /// перетаскиваемый элемент она не участвует в перестановке.
    func testPreviewRejectsFolderPanel() {
        let folder = TileFolder(id: "f", title: "Работа", tiles: [tesseraTestTile("x")])
        let withPanel: [TileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folderContent(folder),
        ]

        XCTAssertNil(
            TileLayoutEngine.previewOrder(
                items: withPanel,
                draggingID: "a",
                targetID: "f"
            )
        )
        XCTAssertNil(
            TileLayoutEngine.previewOrder(
                items: withPanel,
                draggingID: "f",
                targetID: "a"
            )
        )
    }

    // MARK: - Контракт фиксации drop'а

    /// `TileStore.moveItem(_:toIndex:columns:)` по индексу перетаскиваемой плитки
    /// в превью даёт ровно превью-порядок и возвращает фактический индекс — на
    /// этом стоит `finishDrag(commit: true)` (E10.5-C1).
    func testStoreMoveReproducesPreviewOrder() {
        let directory = TesseraTestDirectory()
        let cases: [(dragging: String, target: String, expected: [AnyHashable])] = [
            ("a", "c", ["b", "c", "a", "d"]),
            ("d", "b", ["a", "d", "b", "c"]),
            ("a", "b", ["b", "a", "c", "d"]),
            ("a", "d", ["b", "c", "d", "a"]),
            ("d", "a", ["d", "a", "b", "c"]),
        ]

        for testCase in cases {
            let store = makeStore(["a", "b", "c", "d"], in: directory)
            let base = store.snapshot().items
            guard let preview = TileLayoutEngine.previewOrder(
                items: base,
                draggingID: AnyHashable(testCase.dragging),
                targetID: AnyHashable(testCase.target)
            ) else {
                XCTFail("Нет превью для \(testCase.dragging) → \(testCase.target)")
                continue
            }

            XCTAssertEqual(tesseraTestIDs(preview), testCase.expected)
            guard let previewIndex = preview.firstIndex(
                where: { $0.id == AnyHashable(testCase.dragging) }
            ) else {
                XCTFail("Перетаскиваемая плитка потерялась в превью")
                continue
            }

            let actualIndex = store.moveItem(
                AnyHashable(testCase.dragging),
                toIndex: previewIndex,
                columns: 4
            )
            XCTAssertNotNil(
                actualIndex,
                "\(testCase.dragging) → \(testCase.target): moveItem должен переставить"
            )
            XCTAssertEqual(
                actualIndex,
                previewIndex,
                "Индекс перетаскиваемой плитки в превью совпадает с фактическим"
            )
            XCTAssertEqual(
                tesseraTestIDs(store.snapshot().items),
                testCase.expected,
                "Модель после drop'а должна совпасть с превью"
            )
        }
    }
}

#endif
