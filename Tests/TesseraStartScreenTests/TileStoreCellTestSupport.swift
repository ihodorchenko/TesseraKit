//
//  TileStoreCellTestSupport.swift
//  TesseraStartScreenTests
//
//  Shared helpers for `TesseraTileStore` cell-operation tests.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid" and
//  "Implementation notes and deviations"; decisions D30–D33 in docs/DECISIONS.md.
//
//  The fixture writes a version 2 schema file with explicit cells (including
//  holes) and loads it into `TesseraTileStore`, so the starting layout is exact and does not
//  depend on packing. The invariant check is shared by all tests.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

/// A short way to write a cell in tests.
func tesseraCell(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
    TesseraTileGridPlacement(row: row, column: column)
}

/// A top-level tile in the fixture.
struct CellFixtureTile {
    var id: String
    var size: TesseraTileSize
    var row: Int
    var column: Int

    init(_ id: String, _ size: TesseraTileSize, _ row: Int, _ column: Int) {
        self.id = id
        self.size = size
        self.row = row
        self.column = column
    }
}

/// A top-level folder in the fixture: contents are given as "id — size" pairs.
struct CellFixtureFolder {
    var id: String
    var size: TesseraTileSize
    var row: Int
    var column: Int
    var contents: [(id: String, size: TesseraTileSize)]

    init(_ id: String, _ size: TesseraTileSize = .medium, _ row: Int, _ column: Int, contents: [(String, TesseraTileSize)]) {
        self.id = id
        self.size = size
        self.row = row
        self.column = column
        self.contents = contents.map { (id: $0.0, size: $0.1) }
    }
}

enum TileStoreCellFixture {

    /// Creates a store with an exact version 2 starting layout.
    ///
    /// - Parameters:
    ///   - columns: The canvas width in the file; the host width for operations is passed
    ///     separately in each call.
    ///   - tiles: Top-level tiles.
    ///   - folders: Top-level folders (their contents are part of the catalog).
    ///   - unpinned: Catalog tiles outside the grid.
    ///   - ghosts: Tiles on the grid that are not in the catalog (invisible keys).
    ///   - directory: The state file directory.
    ///   - autosaves: Autosave after operations.
    static func makeStore(
        columns: Int,
        tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = [],
        ghosts: [CellFixtureTile] = [],
        in directory: TesseraTestDirectory,
        autosaves: Bool = true
    ) throws -> TesseraTileStore {
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

        // File order is the reading order of the cells (as after any store operation):
        // `gridOrder` is maintained by operations, not by loading.
        func isBefore(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
            let left = tesseraCell(lhs["row"] as? Int ?? 0, lhs["column"] as? Int ?? 0)
            let right = tesseraCell(rhs["row"] as? Int ?? 0, rhs["column"] as? Int ?? 0)
            return TesseraTileGridPlacement.isReadingOrdered(left, before: right)
        }
        items = items.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if isBefore(l, r) { return true }
            if isBefore(r, l) { return false }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        let document: [String: Any] = [
            "version": 2,
            "columns": columns,
            "items": items,
            "sizes": sizes,
            "folders": folderObjects,
        ]

        let store = TesseraTileStore(directoryURL: directory.url)
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

    /// Checks the model invariants after a cell operation.
    ///
    /// - No overlaps and within the `[0, columns)` bounds (`TesseraTileLayoutEngine.validate`).
    /// - Every visible top-level item has exactly one cell, and there are no foreign ones.
    /// - Every catalog tile appears exactly once: on the grid, in a folder or
    ///   among the unpinned; every folder holds at least two tiles (D45, except for the
    ///   transitional `createFolder(withTile:)` folder under `allowSingleTileFolders`),
    ///   and identifiers are not repeated.
    /// - With `checkOrder` the canvas equals `columns`, and the snapshot order is the
    ///   reading order of the cells (row, column).
    func tesseraAssertCellInvariants(
        _ store: TesseraTileStore,
        columns: Int,
        catalogIDs: [String],
        checkOrder: Bool = true,
        allowSingleTileFolders: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = store.snapshot()
        let cells = store.placements(forColumns: columns)

        XCTAssertEqual(
            Set(snapshot.items.map { $0.id }), Set(cells.keys),
            "every visible item has exactly one cell", file: file, line: line
        )
        XCTAssertEqual(snapshot.items.count, cells.count, file: file, line: line)

        let placed = snapshot.items.compactMap { item -> TesseraTilePlacedItem? in
            guard let cell = cells[item.id] else { return nil }
            return TesseraTilePlacedItem(id: item.id, size: item.size, cell: cell)
        }
        XCTAssertEqual(
            TesseraTileLayoutEngine.validate(placed, columns: columns), [],
            "overlaps or out of canvas", file: file, line: line
        )

        var seen: [String] = []
        for item in snapshot.items {
            switch item {
            case .tile(let tile): seen.append(tile.id.base as? String ?? "?")
            case .folder(let folder):
                XCTAssertGreaterThanOrEqual(
                    folder.tiles.count, allowSingleTileFolders ? 1 : TesseraTileStore.minimumFolderTileCount,
                    "folder with 0–1 tiles on the grid (D45)", file: file, line: line
                )
                seen += folder.tiles.map { $0.id.base as? String ?? "?" }
            case .folderContent: XCTFail("there is no panel in the store snapshot", file: file, line: line)
            }
        }
        seen += snapshot.unpinned.map { $0.id.base as? String ?? "?" }
        XCTAssertEqual(seen.sorted(), catalogIDs.sorted(), "tile lost or duplicated", file: file, line: line)
        let folderIDs = snapshot.folders.map { $0.id }
        XCTAssertEqual(Set(folderIDs).count, folderIDs.count, file: file, line: line)

        if checkOrder {
            XCTAssertEqual(store.canvasColumns, columns, file: file, line: line)
            XCTAssertEqual(
                snapshot.items.map { $0.id }, store.placementReadingOrder(forColumns: columns),
                "model order is the reading order of the cells", file: file, line: line
            )
            let sorted = snapshot.items.compactMap { cells[$0.id] }
            XCTAssertEqual(
                sorted,
                sorted.sorted { TesseraTileGridPlacement.isReadingOrdered($0, before: $1) },
                file: file, line: line
            )
        }
    }
}

#endif
