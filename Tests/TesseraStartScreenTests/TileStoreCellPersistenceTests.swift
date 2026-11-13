//
//  TileStoreCellPersistenceTests.swift
//  TesseraStartScreenTests
//
//  Персистентность и граничные случаи операций `TileStore` по ячейкам (E14.4).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 и «Отступления
//  реализации (E14)»; решения D31–D33 в docs/STATE.md.
//
//  Проверяются: круг записи/чтения с дырами, принятие холста новой ширины
//  первой же успешной операцией (D32) и сохранность файла при отказе,
//  невидимые ключи вне коллизий (E14.1), автосохранение выключено — файл не
//  пишется, ошибки ввода без побочных эффектов.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreCellPersistenceTests: XCTestCase {

    private func reload(_ store: TileStore, catalog: [String], in directory: TesseraTestDirectory) throws -> TileStore {
        let fresh = TileStore(directoryURL: directory.url)
        fresh.setCatalog(catalog.map { tesseraTestTile($0, size: .small) })
        try fresh.load()
        return fresh
    }

    private func fileItems(_ store: TileStore) throws -> [[String: Any]] {
        let data = try Data(contentsOf: store.fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["items"] as? [[String: Any]])
    }

    // MARK: - Круг записи и чтения

    /// Дыры переживают сохранение и загрузку; порядок модели — порядок чтения.
    func testRoundTripKeepsHoles() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("a", .small, 0, 0),
            CellFixtureTile("b", .small, 0, 1),
            CellFixtureTile("c", .medium, 1, 2),
            CellFixtureTile("d", .small, 3, 0),
        ]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, in: directory)

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(5, 4), columns: 6))
        XCTAssertTrue(store.unpin("b", columns: 6))
        XCTAssertTrue(store.resize("d", to: .wide, columns: 6))
        let expected = store.placements
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(3, 0))

        let fresh = TileStore(directoryURL: directory.url)
        fresh.setCatalog(tiles.map { tesseraTestTile($0.id, size: .medium) })
        try fresh.load()

        XCTAssertEqual(fresh.canvasColumns, 6)
        XCTAssertEqual(fresh.placements, expected)
        XCTAssertEqual(tesseraTestIDs(fresh.snapshot().items), tesseraTestIDs(store.snapshot().items))
        XCTAssertEqual(fresh.snapshot().item(withID: "d")?.size, .wide)
        XCTAssertEqual(fresh.snapshot().unpinned.map { $0.id }, ["b"])
        tesseraAssertCellInvariants(fresh, columns: 6, catalogIDs: ["a", "b", "c", "d"])

        // Файл: ширина холста и ячейки каждого элемента в порядке чтения.
        let items = try fileItems(store)
        XCTAssertEqual(items.compactMap { $0["key"] as? String }, ["s:c", "s:d", "s:a"])
        XCTAssertEqual(items.compactMap { $0["row"] as? Int }, [1, 3, 5])
    }

    /// Папка и вынос из неё переживают круг записи.
    func testRoundTripWithFolderOperations() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("t", .small, 2, 2), CellFixtureTile("s", .small, 0, 5), CellFixtureTile("k", .small, 4, 0)]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "s", onto: "t", title: "Игры", columns: 6) else {
            return XCTFail("папка должна создаться")
        }
        // D45: чтобы после выноса папка пережила круг записи, в ней три ярлыка.
        XCTAssertTrue(store.addToFolder("k", folderID: folder.id, columns: 6))
        XCTAssertTrue(store.extractFromFolder("s", toCell: tesseraCell(6, 3), columns: 6))
        let expected = store.placements

        let fresh = try reload(store, catalog: ["t", "s", "k"], in: directory)
        XCTAssertEqual(fresh.placements, expected)
        XCTAssertEqual(fresh.snapshot().folders.first?.title, "Игры")
        XCTAssertEqual(fresh.snapshot().folders.first?.id, folder.id)
        XCTAssertEqual(fresh.snapshot().folders.first?.tiles.map { $0.id }, ["t", "k"])
        tesseraAssertCellInvariants(fresh, columns: 6, catalogIDs: ["t", "s", "k"])
    }

    // MARK: - Ширина хоста (D32)

    /// Операция при другой ширине хоста: первая успешная принимает проекцию
    /// как новый холст и применяет правку; возврат к 6 колонкам дыр уже не даёт.
    func testWidthMismatchAdoptsProjectionAsCanvasOnFirstMutation() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("a", .small, 0, 0),
            CellFixtureTile("b", .small, 0, 5),
            CellFixtureTile("c", .medium, 4, 3),
        ]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, in: directory)
        let original = try Data(contentsOf: store.fileURL)

        // Проекция на 4 колонки: репак по порядку чтения без дыр; файл не тронут.
        let projection = store.placements(forColumns: 4)
        XCTAssertEqual(projection["a"], tesseraCell(0, 0))
        XCTAssertEqual(projection["b"], tesseraCell(0, 1))
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)

        XCTAssertTrue(store.moveItem("c", toCell: tesseraCell(0, 1), columns: 4))

        XCTAssertEqual(store.canvasColumns, 4, "первая правка принимает холст новой ширины")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 0), "a из проекции не двигался")
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(2, 1), "b вытолкнут под c")
        tesseraAssertCellInvariants(store, columns: 4, catalogIDs: ["a", "b", "c"])
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL), original)

        let items = try fileItems(store)
        XCTAssertEqual(items.count, 3)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["columns"] as? Int, 4)
    }

    /// Отказ при несовпадающей ширине холст не принимает и файл не пишет.
    func testFailedOperationOnMismatchedWidthKeepsCanvasAndHoles() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 3, 5)]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, in: directory)
        let original = try Data(contentsOf: store.fileURL)
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.moveItem("nope", toCell: tesseraCell(0, 0), columns: 4))
        XCTAssertFalse(store.unpin("nope", columns: 4))
        XCTAssertFalse(store.pinTile("a", columns: 4))
        XCTAssertFalse(store.collapseEmptyRows(columns: 4))

        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(3, 5), "дыры на месте")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(notifications, 0)
    }

    /// Холст отсутствует (нераскладочное состояние): операция назначает ячейки
    /// упаковкой порядка и применяет правку.
    func testOperationBeforeCanvasExistsAdoptsPackedLayout() throws {
        let directory = TesseraTestDirectory()
        let store = TileStore(directoryURL: directory.url)
        store.setCatalog([tesseraTestTile("a", size: .small), tesseraTestTile("b", size: .small), tesseraTestTile("c", size: .small)])
        XCTAssertNil(store.canvasColumns)

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(4, 0), columns: 6))

        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1), "упаковка порядка, без репака после правки")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 2))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: 6, catalogIDs: ["a", "b", "c"])
    }

    // MARK: - Невидимые ключи

    /// Невидимый ярлык вне каталога хранит ячейку и не участвует в коллизиях.
    func testInvisibleItemsKeepCellsAndAreIgnoredByCollisions() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .medium, 0, 0), CellFixtureTile("b", .small, 0, 4)]
        let ghosts = [CellFixtureTile("ghost", .small, 0, 0)]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, ghosts: ghosts, in: directory)

        XCTAssertTrue(store.moveItem("b", toCell: tesseraCell(0, 0), columns: 6))

        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(1, 0), "a вытолкнут b, призрак не мешал")
        XCTAssertNil(store.placement(of: "ghost"))
        XCTAssertFalse(store.placements.keys.contains(AnyHashable("ghost")))
        tesseraAssertCellInvariants(store, columns: 6, catalogIDs: ["a", "b"])

        let ghostRecord = try XCTUnwrap(try fileItems(store).first { $0["key"] as? String == "s:ghost" })
        XCTAssertEqual(ghostRecord["row"] as? Int, 0)
        XCTAssertEqual(ghostRecord["column"] as? Int, 0)
    }

    /// Невидимый ключ, которому не хватило ширины новой сетки, получает место в
    /// конце; видимые элементы это не затрагивает.
    func testInvisibleItemOutsideNarrowCanvasGetsNewCell() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let ghosts = [CellFixtureTile("ghost", .small, 0, 5)]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, ghosts: ghosts, in: directory)

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(2, 1), columns: 4))

        XCTAssertEqual(store.canvasColumns, 4)
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(2, 1))
        let ghostRecord = try XCTUnwrap(try fileItems(store).first { $0["key"] as? String == "s:ghost" })
        let column = try XCTUnwrap(ghostRecord["column"] as? Int)
        XCTAssertLessThan(column, 4, "призрак помещён в новую ширину холста")
    }

    // MARK: - Побочные эффекты

    /// Автосохранение выключено: операция меняет модель, файл не пишется.
    func testAutosaveOffDoesNotWriteButSaveKeepsHoles() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 2, 2)]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, in: directory, autosaves: false)
        let original = try Data(contentsOf: store.fileURL)

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(5, 5), columns: 6))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)

        try store.save()
        let fresh = try reload(store, catalog: ["a", "b"], in: directory)
        XCTAssertEqual(fresh.placement(of: "a"), tesseraCell(5, 5))
        XCTAssertEqual(fresh.placement(of: "b"), tesseraCell(2, 2))
    }

    /// Ошибочный ввод всех операций: состояние, файл и уведомления не меняются.
    func testInvalidInputHasNoSideEffects() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try TileStoreCellFixture.makeStore(columns: 6, tiles: tiles, folders: folders, unpinned: [("u", .small)], in: directory)
        let original = try Data(contentsOf: store.fileURL)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        for columns in [0, -3] {
            XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(1, 1), columns: columns))
            XCTAssertFalse(store.moveItemToNewRow("a", columns: columns))
            XCTAssertFalse(store.resize("a", to: .wide, columns: columns))
            XCTAssertFalse(store.addToFolder("a", folderID: "f", columns: columns))
            XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(1, 1), columns: columns))
            XCTAssertFalse(store.extractFromFolderToNewRow("x", columns: columns))
            XCTAssertFalse(store.moveBetweenFolders("x", to: "f", columns: columns))
            XCTAssertFalse(store.unpin("a", columns: columns))
            XCTAssertFalse(store.pinTile("u", columns: columns))
            XCTAssertFalse(store.collapseEmptyRows(columns: columns))
        }
        XCTAssertFalse(store.moveItemToNewRow("u", columns: 6), "ярлык вне сетки")
        XCTAssertFalse(store.moveItem("u", toCell: tesseraCell(1, 1), columns: 6))

        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(notifications, 0)
    }
}

#endif
