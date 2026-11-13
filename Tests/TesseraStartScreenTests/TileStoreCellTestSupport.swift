//
//  TileStoreCellTestSupport.swift
//  TesseraStartScreenTests
//
//  Общие помощники тестов операций по ячейкам `TileStore` (E14.4).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка» и
//  «Отступления реализации (E14)»; решения D30–D33 в docs/STATE.md.
//
//  Фикстура записывает файл схемы версии 2 с явными ячейками (в том числе с
//  дырами) и грузит его в `TileStore`, так что стартовая раскладка точная и не
//  зависит от упаковки. Проверка инвариантов — одна на все тесты.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

/// Короткая запись ячейки в тестах.
func tesseraCell(_ row: Int, _ column: Int) -> TileGridPlacement {
    TileGridPlacement(row: row, column: column)
}

/// Ярлык верхнего уровня в фикстуре.
struct CellFixtureTile {
    var id: String
    var size: TileSize
    var row: Int
    var column: Int

    init(_ id: String, _ size: TileSize, _ row: Int, _ column: Int) {
        self.id = id
        self.size = size
        self.row = row
        self.column = column
    }
}

/// Папка верхнего уровня в фикстуре: содержимое задаётся парами «id — размер».
struct CellFixtureFolder {
    var id: String
    var size: TileSize
    var row: Int
    var column: Int
    var contents: [(id: String, size: TileSize)]

    init(_ id: String, _ size: TileSize = .medium, _ row: Int, _ column: Int, contents: [(String, TileSize)]) {
        self.id = id
        self.size = size
        self.row = row
        self.column = column
        self.contents = contents.map { (id: $0.0, size: $0.1) }
    }
}

enum TileStoreCellFixture {

    /// Создаёт хранилище с точной стартовой раскладкой версии 2.
    ///
    /// - Parameters:
    ///   - columns: Ширина холста в файле; ширина хоста для операций передаётся
    ///     отдельно в каждом вызове.
    ///   - tiles: Ярлыки верхнего уровня.
    ///   - folders: Папки верхнего уровня (их содержимое входит в каталог).
    ///   - unpinned: Ярлыки каталога вне сетки.
    ///   - ghosts: Ярлыки на сетке, которых нет в каталоге (невидимые ключи).
    ///   - directory: Каталог файла состояния.
    ///   - autosaves: Автосохранение после операций.
    static func makeStore(
        columns: Int,
        tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TileSize)] = [],
        ghosts: [CellFixtureTile] = [],
        in directory: TesseraTestDirectory,
        autosaves: Bool = true
    ) throws -> TileStore {
        var catalog = tiles.map { tesseraTestTile($0.id, size: $0.size) }
        catalog += folders.flatMap { $0.contents.map { tesseraTestTile($0.id, size: $0.size) } }
        catalog += unpinned.map { tesseraTestTile($0.0, size: $0.1) }

        var sizes: [String: String] = [:]
        var items: [[String: Any]] = []
        for tile in tiles {
            sizes["s:" + tile.id] = tile.size.rawValue
            items.append(["kind": "tile", "key": "s:" + tile.id, "row": tile.row, "column": tile.column])
        }
        for ghost in ghosts {
            sizes["s:" + ghost.id] = ghost.size.rawValue
            items.append(["kind": "tile", "key": "s:" + ghost.id, "row": ghost.row, "column": ghost.column])
        }
        var folderObjects: [[String: Any]] = []
        for folder in folders {
            items.append(["kind": "folder", "key": "s:" + folder.id, "row": folder.row, "column": folder.column])
            for content in folder.contents { sizes["s:" + content.id] = content.size.rawValue }
            folderObjects.append([
                "key": "s:" + folder.id,
                "title": folder.id,
                "size": folder.size.rawValue,
                "tileKeys": folder.contents.map { "s:" + $0.id },
            ])
        }
        for (id, size) in unpinned { sizes["s:" + id] = size.rawValue }

        let document: [String: Any] = [
            "version": 2,
            "columns": columns,
            "items": items,
            "sizes": sizes,
            "folders": folderObjects,
        ]

        let store = TileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(catalog)
        try directory.create()
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: store.fileURL)
        try store.load()
        store.autosaves = autosaves
        return store
    }
}

extension XCTestCase {

    /// Проверяет инварианты модели после операции по ячейкам (E14.4).
    ///
    /// - Без пересечений и в границах `[0, columns)` (`TileLayoutEngine.validate`).
    /// - У каждого видимого верхнеуровневого элемента ровно одна ячейка, чужих нет.
    /// - Каждый ярлык каталога встречается ровно один раз: на сетке, в папке или
    ///   среди откреплённых; папки не пусты, идентификаторы не повторяются.
    /// - При `checkOrder` холст равен `columns`, а порядок снимка — порядок
    ///   чтения ячеек (строка, колонка).
    func tesseraAssertCellInvariants(
        _ store: TileStore,
        columns: Int,
        catalogIDs: [String],
        checkOrder: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = store.snapshot()
        let cells = store.placements(forColumns: columns)

        XCTAssertEqual(
            Set(snapshot.items.map { $0.id }), Set(cells.keys),
            "у каждого видимого элемента ровно одна ячейка", file: file, line: line
        )
        XCTAssertEqual(snapshot.items.count, cells.count, file: file, line: line)

        let placed = snapshot.items.compactMap { item -> TilePlacedItem? in
            guard let cell = cells[item.id] else { return nil }
            return TilePlacedItem(id: item.id, size: item.size, cell: cell)
        }
        XCTAssertEqual(
            TileLayoutEngine.validate(placed, columns: columns), [],
            "пересечения или выход за холст", file: file, line: line
        )

        var seen: [String] = []
        for item in snapshot.items {
            switch item {
            case .tile(let tile): seen.append(tile.id.base as? String ?? "?")
            case .folder(let folder):
                XCTAssertFalse(folder.tiles.isEmpty, "пустая папка на сетке", file: file, line: line)
                seen += folder.tiles.map { $0.id.base as? String ?? "?" }
            case .folderContent: XCTFail("панели в снимке хранилища нет", file: file, line: line)
            }
        }
        seen += snapshot.unpinned.map { $0.id.base as? String ?? "?" }
        XCTAssertEqual(seen.sorted(), catalogIDs.sorted(), "ярлык потерян или задвоен", file: file, line: line)
        let folderIDs = snapshot.folders.map { $0.id }
        XCTAssertEqual(Set(folderIDs).count, folderIDs.count, file: file, line: line)

        if checkOrder {
            XCTAssertEqual(store.canvasColumns, columns, file: file, line: line)
            XCTAssertEqual(
                snapshot.items.map { $0.id }, store.placementReadingOrder(forColumns: columns),
                "порядок модели — порядок чтения ячеек", file: file, line: line
            )
            let sorted = snapshot.items.compactMap { cells[$0.id] }
            XCTAssertEqual(
                sorted,
                sorted.sorted { TileGridPlacement.isReadingOrdered($0, before: $1) },
                file: file, line: line
            )
        }
    }
}

#endif
