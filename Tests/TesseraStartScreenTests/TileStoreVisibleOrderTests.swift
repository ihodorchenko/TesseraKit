//
//  TileStoreVisibleOrderTests.swift
//  TesseraStartScreenTests
//
//  Тесты порядка сетки в `TileStore` (W2: E10.3a, E10.3b, E10.15).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»,
//  §5 «Режим редактирования» и «Отступления реализации» п. 4–5; план —
//  docs/PLAN.md, раздел «E9–E10».
//
//  Проверяются:
//  - индексы `move(_:toIndex:)`/`pin(_:at:)` и новых перегрузок трактуются в
//    пространстве видимого снимка, а невидимые ключи (ярлыки вне каталога)
//    сохраняют свои места в файле (E10.3a);
//  - новые перегрузки возвращают фактический видимый индекс (E10.3b);
//  - канонизация: после операций с `columns` порядок снимка совпадает с
//    порядком чтения строго компактной раскладки (E10.15), одно изменение —
//    одно уведомление.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreVisibleOrderTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Хранилище без автосохранения поверх временного каталога.
    private func makeStore(
        _ descriptors: [TileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TileStore {
        let store = TileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        return store
    }

    /// Сохраняет раскладку каталога `full` и поднимает новое хранилище с
    /// урезанным каталогом `visible` поверх того же файла (ярлыки вне каталога
    /// становятся невидимыми ключами).
    private func makeStoreWithHiddenKeys(
        full: [TileDescriptor],
        visible: [TileDescriptor],
        in directory: TesseraTestDirectory,
        prepare: (TileStore) -> Void = { _ in }
    ) throws -> TileStore {
        let original = makeStore(full, in: directory)
        prepare(original)
        try original.save()

        let restored = makeStore(visible, in: directory)
        try restored.load()
        return restored
    }

    private func ids(_ store: TileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Порядок снимка — порядок чтения раскладки: слоты `pack` в порядке
    /// снимка строго возрастают по (строка, колонка).
    private func assertReadingOrder(
        _ store: TileStore,
        columns: Int,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let layoutItems = store.snapshot().layoutItems
        let slots = TileLayoutEngine.pack(items: layoutItems, columns: columns, unit: 1)
        XCTAssertEqual(slots.count, layoutItems.count, message(), file: file, line: line)
        for (previous, next) in zip(slots, slots.dropFirst()) {
            let ordered = previous.row < next.row
                || (previous.row == next.row && previous.column < next.column)
            XCTAssertTrue(
                ordered,
                "\(message()) порядок снимка не совпадает с порядком чтения: "
                    + "\(previous.id)(\(previous.row),\(previous.column)) → "
                    + "\(next.id)(\(next.row),\(next.column))",
                file: file,
                line: line
            )
        }
    }

    // MARK: - E10.3a: индексы в пространстве видимого снимка

    /// Каталог [A,B,C,D], B убран из каталога: `move(A, 2)` даёт видимый
    /// порядок [C,D,A] — тот же, что превью перетаскивания, — а невидимый B
    /// сохраняет своё место в файле.
    func testMoveUsesVisibleIndexWhenCatalogHidesTile() throws {
        let directory = TesseraTestDirectory()
        let full = ["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) }
        let store = try makeStoreWithHiddenKeys(
            full: full,
            visible: full.filter { $0.id != AnyHashable("b") },
            in: directory
        )
        XCTAssertEqual(ids(store), ["a", "c", "d"])

        // Превью drop'а A на D и индекс A в нём — то, что передаёт координатор.
        let preview = try XCTUnwrap(TileLayoutEngine.previewOrder(
            items: store.snapshot().items,
            draggingID: "a",
            targetID: "d"
        ))
        let previewIDs = preview.map { $0.id }
        let index = try XCTUnwrap(previewIDs.firstIndex(of: "a"))
        XCTAssertEqual(previewIDs, ["c", "d", "a"])

        XCTAssertTrue(store.move("a", toIndex: index))
        XCTAssertEqual(ids(store), previewIDs)

        // Невидимый B не сдвинулся: после возвращения в каталог он на прежнем
        // индексе внутреннего порядка.
        try store.save()
        let reloaded = makeStore(full, in: directory)
        try reloaded.load()
        XCTAssertEqual(ids(reloaded), ["c", "b", "d", "a"])
    }

    /// Перестановка в начало и за конец при невидимых ключах тоже работает в
    /// видимых индексах.
    func testMoveClampsInVisibleSpace() throws {
        let directory = TesseraTestDirectory()
        let full = ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) }
        let store = try makeStoreWithHiddenKeys(
            full: full,
            visible: full.filter { $0.id != AnyHashable("a") && $0.id != AnyHashable("d") },
            in: directory
        )
        XCTAssertEqual(ids(store), ["b", "c", "e"])

        XCTAssertTrue(store.move("e", toIndex: 0))
        XCTAssertEqual(ids(store), ["e", "b", "c"])

        XCTAssertTrue(store.move("e", toIndex: 99))
        XCTAssertEqual(ids(store), ["b", "c", "e"])

        XCTAssertFalse(store.move("e", toIndex: 2))
        // Невидимый ключ переставлять нельзя: его нет в снимке.
        XCTAssertFalse(store.move("a", toIndex: 0))
        XCTAssertNil(store.moveItem("a", toIndex: 0, columns: nil))
    }

    /// `pin(_:at:)` вставляет в видимом пространстве: D закрепляется третьим
    /// видимым элементом, хотя перед ним во внутреннем порядке стоит
    /// невидимый B.
    func testPinUsesVisibleIndexWhenCatalogHidesTile() throws {
        let directory = TesseraTestDirectory()
        let full = ["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) }
        let store = try makeStoreWithHiddenKeys(
            full: full,
            visible: full.filter { $0.id != AnyHashable("b") },
            in: directory,
            prepare: { XCTAssertTrue($0.unpin("d")) }
        )
        XCTAssertEqual(ids(store), ["a", "c"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["d"])

        XCTAssertTrue(store.pin("d", at: 2))
        XCTAssertEqual(ids(store), ["a", "c", "d"])

        XCTAssertTrue(store.unpin("d"))
        XCTAssertTrue(store.pin("d", at: 1))
        XCTAssertEqual(ids(store), ["a", "d", "c"])

        // B по-прежнему на своём месте (индекс 1 внутреннего порядка).
        try store.save()
        let reloaded = makeStore(full, in: directory)
        try reloaded.load()
        XCTAssertEqual(ids(reloaded), ["a", "b", "d", "c"])
    }

    // MARK: - E10.3b: фактический видимый индекс

    /// Перегрузки возвращают зажатый видимый индекс; `nil` — операция
    /// отклонена.
    func testOverloadsReturnClampedVisibleIndex() throws {
        let directory = TesseraTestDirectory()
        let full = ["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) }
        let store = try makeStoreWithHiddenKeys(
            full: full,
            visible: full.filter { $0.id != AnyHashable("b") },
            in: directory,
            prepare: { XCTAssertTrue($0.unpin("d")) }
        )
        XCTAssertEqual(ids(store), ["a", "c"])

        XCTAssertEqual(store.pinTile("d", at: 42, columns: nil), 2)
        XCTAssertEqual(ids(store), ["a", "c", "d"])
        XCTAssertNil(store.pinTile("d", at: 0, columns: nil), "уже закреплён")
        XCTAssertNil(store.pinTile("b", at: 0, columns: nil), "нет в каталоге")

        XCTAssertEqual(store.moveItem("d", toIndex: -3, columns: nil), 0)
        XCTAssertEqual(ids(store), ["d", "a", "c"])
        XCTAssertEqual(store.moveItem("d", toIndex: 0, columns: nil), 0, "no-op возвращает текущий индекс")
        XCTAssertEqual(store.moveItem("a", toIndex: 99, columns: nil), 2)
        XCTAssertEqual(ids(store), ["d", "c", "a"])
        XCTAssertNil(store.moveItem("missing", toIndex: 0, columns: nil))
    }

    // MARK: - E10.15: канонизация порядка чтения

    /// Пример из ревью: [medium A, wide W, small S] на 4 колонках. Строгая
    /// компактная упаковка ставит S справа от A, а W — под ними, поэтому
    /// порядок чтения — A, S, W.
    func testReadingOrderOfMediumWideSmall() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: "a", size: .medium),
            (id: "w", size: .wide),
            (id: "s", size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 1)
        XCTAssertEqual(slots.map { $0.id }, ["a", "w", "s"])
        XCTAssertEqual(slots.map { [$0.row, $0.column] }, [[0, 0], [2, 0], [0, 2]])

        XCTAssertEqual(TileStore.readingOrder(of: items, columns: 4), ["a", "s", "w"])
    }

    /// Элемент без слота (шире сетки) остаётся сразу за предшественником.
    func testReadingOrderKeepsUnslottedItemAfterPredecessor() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: "a", size: .medium),
            (id: "w", size: .wide),
            (id: "s", size: .small),
        ]
        // На 3 колонках wide не помещается и слота не получает.
        XCTAssertEqual(TileStore.readingOrder(of: items, columns: 3), ["a", "w", "s"])
        XCTAssertEqual(TileStore.readingOrder(of: items, columns: 0), ["a", "w", "s"])
    }

    /// Хранилище приводит порядок к порядку чтения: no-op-перестановка с
    /// `columns` канонизирует [A,W,S] в [A,S,W] одним уведомлением.
    func testMoveWithColumnsCanonicalizesInOneChange() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("w", size: .wide),
            tesseraTestTile("s", size: .small),
        ], in: directory)
        XCTAssertEqual(ids(store), ["a", "w", "s"])

        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertEqual(store.moveItem("a", toIndex: 0, columns: 4), 0)
        XCTAssertEqual(ids(store), ["a", "s", "w"])
        XCTAssertEqual(notifications, 1)
        assertReadingOrder(store, columns: 4)

        // Уже канонический порядок: ничего не меняется и не уведомляется.
        XCTAssertEqual(store.moveItem("a", toIndex: 0, columns: 4), 0)
        XCTAssertFalse(store.canonicalizeVisibleOrder(columns: 4))
        XCTAssertEqual(notifications, 1)
    }

    /// Перестановка и канонизация вместе — одно изменение; возвращается
    /// индекс после канонизации.
    func testMoveAndCanonicalizationAreOneChange() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("w", size: .wide),
            tesseraTestTile("s", size: .small),
            tesseraTestTile("t", size: .small),
        ], in: directory)

        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        // [T, A, W, S]: T(0,0), A(0,1), W(2,0), S(0,3) → чтение T, A, S, W.
        XCTAssertEqual(store.moveItem("t", toIndex: 0, columns: 4), 0)
        XCTAssertEqual(ids(store), ["t", "a", "s", "w"])
        XCTAssertEqual(notifications, 1)
        assertReadingOrder(store, columns: 4)

        // W «в начало»: [W, T, A, S] уже канонический — W встаёт на индекс 0.
        XCTAssertEqual(store.moveItem("w", toIndex: 0, columns: 4), 0)
        XCTAssertEqual(ids(store), ["w", "t", "a", "s"])
        XCTAssertEqual(notifications, 2)
        assertReadingOrder(store, columns: 4)
    }

    /// `pinTile` с `columns` возвращает индекс после канонизации.
    func testPinTileWithColumnsReturnsCanonicalIndex() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("w", size: .wide),
            tesseraTestTile("s", size: .small),
        ], in: directory)
        XCTAssertTrue(store.unpin("s"))
        XCTAssertEqual(ids(store), ["a", "w"])

        // В конец: [A, W, S] → чтение [A, S, W], фактический индекс S — 1.
        XCTAssertEqual(store.pinTile("s", at: nil, columns: 4), 1)
        XCTAssertEqual(ids(store), ["a", "s", "w"])
    }

    /// Канонизация переставляет только видимые элементы: невидимый ключ
    /// сохраняет свой индекс во внутреннем порядке и в файле.
    func testCanonicalizationKeepsHiddenKeysInPlace() throws {
        let directory = TesseraTestDirectory()
        let full = [
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .small),
            tesseraTestTile("w", size: .wide),
            tesseraTestTile("s", size: .small),
        ]
        let store = try makeStoreWithHiddenKeys(
            full: full,
            visible: full.filter { $0.id != AnyHashable("b") },
            in: directory
        )
        XCTAssertEqual(ids(store), ["a", "w", "s"])

        XCTAssertTrue(store.canonicalizeVisibleOrder(columns: 4))
        XCTAssertEqual(ids(store), ["a", "s", "w"])

        try store.save()
        let reloaded = makeStore(full, in: directory)
        try reloaded.load()
        XCTAssertEqual(ids(reloaded), ["a", "b", "s", "w"])
    }

    /// resize с `columns` оставляет порядок каноническим.
    func testResizeWithColumnsKeepsReadingOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .small),
            tesseraTestTile("c", size: .small),
            tesseraTestTile("d", size: .small),
            tesseraTestTile("e", size: .small),
        ], in: directory)

        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertTrue(store.resize("b", to: .medium, columns: 4))
        XCTAssertEqual(notifications, 1)
        assertReadingOrder(store, columns: 4)

        XCTAssertTrue(store.resize("a", to: .wide, columns: 4))
        XCTAssertEqual(notifications, 2)
        assertReadingOrder(store, columns: 4)
    }

    /// Рандомизированная проверка (фиксированное зерно): после любой
    /// последовательности move/resize/pin с `columns` (и unpin/папок с явной
    /// канонизацией) `pack(snapshot)` даёт слоты, отсортированные по
    /// (строка, колонка) в порядке снимка, а возвращённый индекс совпадает с
    /// фактическим.
    func testRandomOperationsKeepSnapshotInReadingOrder() {
        let sizes: [TileSize] = [.small, .small, .small, .medium, .medium, .wide, .large]

        for columns in [4, 6] {
            for seed in UInt64(1)...UInt64(20) {
                var random = TesseraTestSeededGenerator(seed: seed &* 7919 &+ UInt64(columns))
                let catalog = (0..<12).map { index in
                    tesseraTestTile("t\(index)", size: sizes[random.int(upperBound: sizes.count)])
                }
                let directory = TesseraTestDirectory()
                let store = makeStore(catalog, in: directory)
                store.canonicalizeVisibleOrder(columns: columns)
                assertReadingOrder(store, columns: columns, "seed \(seed), старт")

                for step in 0..<40 {
                    let context = "seed \(seed), columns \(columns), шаг \(step)"
                    let visible = store.snapshot().items.map { $0.id }
                    switch random.int(upperBound: 6) {
                    case 0, 1:
                        guard !visible.isEmpty else { continue }
                        let id = visible[random.int(upperBound: visible.count)]
                        let target = random.int(upperBound: visible.count + 2) - 1
                        let result = store.moveItem(id, toIndex: target, columns: columns)
                        XCTAssertEqual(result, store.snapshot().items.firstIndex { $0.id == id }, context)
                    case 2:
                        guard !visible.isEmpty else { continue }
                        let id = visible[random.int(upperBound: visible.count)]
                        let size = sizes[random.int(upperBound: sizes.count)]
                        store.resize(id, to: size, columns: columns)
                    case 3:
                        let unpinned = store.snapshot().unpinned.map { $0.id }
                        guard !unpinned.isEmpty else { continue }
                        let id = unpinned[random.int(upperBound: unpinned.count)]
                        let target = random.int(upperBound: visible.count + 1)
                        let result = store.pinTile(id, at: target, columns: columns)
                        XCTAssertNotNil(result, context)
                        XCTAssertEqual(result, store.snapshot().items.firstIndex { $0.id == id }, context)
                    case 4:
                        let tiles = store.snapshot().items.compactMap { $0.tile?.id }
                        guard tiles.count > 3 else { continue }
                        store.unpin(tiles[random.int(upperBound: tiles.count)])
                        store.canonicalizeVisibleOrder(columns: columns)
                    default:
                        let tiles = store.snapshot().items.compactMap { $0.tile?.id }
                        guard let id = tiles.first else { continue }
                        store.createFolder(withTile: id, title: "F")
                        store.canonicalizeVisibleOrder(columns: columns)
                    }
                    assertReadingOrder(store, columns: columns, context)
                }
            }
        }
    }
}

#endif
