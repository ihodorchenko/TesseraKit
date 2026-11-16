//
//  TileStoreVisibleOrderTests.swift
//  TesseraStartScreenTests
//
//  Тесты видимых и невидимых ключей сетки в `TesseraTileStore` (W2: E10.3a, после
//  E14.6 — на операциях по ячейкам).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»,
//  «Отступления реализации» п. 4–5 и (E14) п. 52–54; план — docs/PLAN.md,
//  разделы «E9–E10» и «E14».
//
//  Проверяются:
//  - ярлыки вне каталога (невидимые ключи) сохраняют свои ячейки и места в
//    файле при переносе, закреплении и откреплении видимых элементов, а
//    невидимый ключ нельзя переставить (его нет в снимке);
//  - порядок снимка после операций — порядок чтения ячеек видимых элементов.
//
//  Индексного API (`move(toIndex:)`, `pin(at:)`) больше нет (E14.6, D33):
//  прежние тесты этого файла на нём заменены. Покрытие
//  прежних сценариев: `TileStoreCellOperationsTests` (перенос, зажим, no-op),
//  `TileStoreCellPropertyTests` (порядок снимка = порядок чтения после любой
//  последовательности операций) и `TileStoreCellPersistenceTests` (невидимые
//  ключи, холст, круг записи).
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreVisibleOrderTests: XCTestCase {

    // MARK: - Вспомогательные средства

    private let columns = 6

    private func ids(_ store: TesseraTileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Каталог [a, b, c, d] — все small в строке 0 (колонки 0…3); раскладка
    /// записана файлом версии 2. Каталог хранилища урезан до `visible`, так что
    /// остальные ключи — невидимые (E10.3a).
    private func makeStoreHiding(
        _ hidden: Set<String>,
        in directory: TesseraTestDirectory
    ) throws -> TesseraTileStore {
        let all: [CellFixtureTile] = [
            CellFixtureTile("a", .small, 0, 0),
            CellFixtureTile("b", .small, 0, 1),
            CellFixtureTile("c", .small, 0, 2),
            CellFixtureTile("d", .small, 0, 3),
        ]
        return try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: all.filter { !hidden.contains($0.id) },
            ghosts: all.filter { hidden.contains($0.id) },
            in: directory,
            autosaves: false
        )
    }

    /// Поднимает хранилище с полным каталогом поверх файла, записанного `store`.
    private func reloadWithFullCatalog(
        savedBy store: TesseraTileStore,
        in directory: TesseraTestDirectory
    ) throws -> TesseraTileStore {
        try store.save()
        let reloaded = TesseraTileStore(directoryURL: directory.url)
        reloaded.autosaves = false
        reloaded.setCatalog(["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) })
        try reloaded.load()
        return reloaded
    }

    // MARK: - Невидимые ключи при переносе

    /// Каталог [a, b, c, d], b убран из каталога: перенос `a` на ячейку `c`
    /// выталкивает `c` вниз, порядок снимка — порядок чтения ячеек, а
    /// невидимый `b` сохраняет свою ячейку и после возврата в каталог остаётся
    /// на ней.
    func testMoveItemToCellKeepsHiddenKeyCell() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["b"], in: directory)
        XCTAssertEqual(ids(store), ["a", "c", "d"])

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(0, 2), columns: columns))
        // a на (0,2); c выталкивается на (1,2); d на (0,3): порядок чтения a, d, c.
        XCTAssertEqual(ids(store), ["a", "d", "c"])
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 2))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 2))

        let reloaded = try reloadWithFullCatalog(savedBy: store, in: directory)
        XCTAssertEqual(reloaded.placement(of: "b"), tesseraCell(0, 1), "невидимый b остался на своей ячейке")
        XCTAssertEqual(reloaded.placement(of: "a"), tesseraCell(0, 2))
        XCTAssertEqual(reloaded.placement(of: "c"), tesseraCell(1, 2))
    }

    /// Ячейка невидимого ключа не участвует в коллизиях: перенос видимого
    /// элемента на неё не выталкивает невидимый ключ, и вернувшийся в каталог
    /// ключ уходит в новую строку (его ячейку заняли).
    func testMoveOntoHiddenKeyCellDoesNotPushHiddenKey() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["b"], in: directory)

        XCTAssertTrue(store.moveItem("d", toCell: tesseraCell(0, 1), columns: columns))
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(0, 1))
        XCTAssertEqual(ids(store), ["a", "d", "c"])

        // «b» возвращается в каталог: его ячейку заняли, поэтому он идёт в новую
        // строку в конце холста, а видимые элементы не двигаются.
        store.setCatalog(["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) })
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(1, 0))
    }

    /// Невидимый ключ переставить, изменить и открепить нельзя: его нет в
    /// снимке, операции возвращают `false` и ничего не пишут.
    func testHiddenKeyCannotBeMovedResizedOrUnpinned() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["a", "d"], in: directory)
        XCTAssertEqual(ids(store), ["b", "c"])

        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(1, 0), columns: columns))
        XCTAssertFalse(store.moveItemToNewRow("a", columns: columns))
        XCTAssertFalse(store.resize("a", to: .medium, columns: columns))
        XCTAssertFalse(store.unpin("a", columns: columns))
        XCTAssertEqual(notifications, 0)
        XCTAssertNil(store.placement(of: "a"))
    }

    // MARK: - Невидимые ключи при закреплении

    /// Закрепление идёт в новую строку и не трогает ячейки невидимых ключей;
    /// открепление оставляет дыру, а возврат в тот же ряд через новую строку
    /// порядок чтения не нарушает.
    func testPinAndUnpinKeepHiddenKeyCell() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["b"], in: directory)

        XCTAssertTrue(store.unpin("d", columns: columns))
        XCTAssertEqual(ids(store), ["a", "c"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["d"])

        XCTAssertTrue(store.pinTile("d", columns: columns))
        XCTAssertEqual(ids(store), ["a", "c", "d"])
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(1, 0), "закрепление — новая строка в конце холста")

        let reloaded = try reloadWithFullCatalog(savedBy: store, in: directory)
        XCTAssertEqual(reloaded.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(reloaded.placement(of: "d"), tesseraCell(1, 0))
    }

    // MARK: - Порядок снимка = порядок чтения ячеек

    /// После переноса, роста и открепления порядок `snapshot().items` и
    /// `placementReadingOrder` совпадают (хранилище не канонизирует порядок:
    /// он производный от ячеек).
    func testSnapshotOrderFollowsCellsAfterOperations() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [
                CellFixtureTile("a", .medium, 0, 0),
                CellFixtureTile("w", .wide, 2, 0),
                CellFixtureTile("s", .small, 0, 2),
            ],
            in: directory,
            autosaves: false
        )
        // Порядок чтения: a(0,0), s(0,2), w(2,0).
        XCTAssertEqual(ids(store), ["a", "s", "w"])

        XCTAssertTrue(store.moveItem("s", toCell: tesseraCell(3, 4), columns: columns))
        XCTAssertEqual(ids(store), ["a", "w", "s"])
        XCTAssertEqual(ids(store), store.placementReadingOrder(forColumns: columns))

        XCTAssertTrue(store.resize("a", to: .wide, columns: columns))
        XCTAssertEqual(ids(store), store.placementReadingOrder(forColumns: columns))

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertEqual(ids(store), ["w", "s"])
        XCTAssertEqual(ids(store), store.placementReadingOrder(forColumns: columns))
    }
}

#endif
