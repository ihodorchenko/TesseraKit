//
//  TileStoreFolderMinTwoTests.swift
//  TesseraStartScreenTests
//
//  A folder never has 0–1 tiles: the `TesseraTileStore` model (D45).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, "Implementation notes and deviations";
//  decisions D30–D33 and D45 in docs/DECISIONS.md.
//
//  The rule: when an operation removes a tile from a folder and one is left, the folder
//  is dissolved: the remaining tile takes the folder's cell with **its own** size
//  through `TesseraTileLayoutEngine.inserting` (a larger one pushes neighbors down, D31,
//  a column that is too far right shifts left, a smaller one leaves a hole). The rule
//  applies to all operations that remove a tile from a folder (take-out, take-out into a new
//  row, unpin, move to another folder), to the catalog cleanup and to
//  file loading. The exception is the transitional folder `createFolder(withTile:)`.
//
//  Exact layouts (`TileStoreCellFixture`), 6 columns; one notification and
//  one write per operation.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreFolderMinTwoTests: XCTestCase {

    private let columns = 6

    // MARK: - Helpers

    private func makeStore(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = [],
        in directory: TesseraTestDirectory,
        autosaves: Bool = true
    ) throws -> TesseraTileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns, tiles: tiles, folders: folders, unpinned: unpinned, in: directory, autosaves: autosaves
        )
    }

    private func catalogIDs(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = []
    ) -> [String] {
        tiles.map { $0.id } + folders.flatMap { $0.contents.map { $0.id } } + unpinned.map { $0.0 }
    }

    /// Counts `onChange` notifications.
    private func countNotifications(_ store: TesseraTileStore) -> () -> Int {
        var count = 0
        store.onChange = { _ in count += 1 }
        return { count }
    }

    /// The file contains exactly the model cells: a reloaded store matches.
    private func assertRoundTrip(
        _ store: TesseraTileStore,
        catalog: [String],
        in directory: TesseraTestDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try store.save()
        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog(catalog.map { tesseraTestTile($0, size: store.descriptor(withID: $0)?.size ?? .small) })
        try fresh.load()
        XCTAssertEqual(fresh.placements, store.placements, "cells survive the write round trip", file: file, line: line)
        XCTAssertEqual(
            fresh.snapshot().items.map { $0.id }, store.snapshot().items.map { $0.id }, file: file, line: line
        )
        XCTAssertEqual(fresh.snapshot().folders.count, store.snapshot().folders.count, file: file, line: line)
        for item in store.snapshot().items {
            XCTAssertEqual(fresh.snapshot().item(withID: item.id)?.size, item.size, file: file, line: line)
        }
    }

    // MARK: - Take-out from a folder

    /// A take-out from a folder of two tiles: the folder is dissolved, the remaining tile takes
    /// its cell, the taken-out one goes to the specified one. One notification, one write round trip.
    func testExtractLeavingOneDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 3), columns: columns))

        XCTAssertEqual(notifications(), 1, "one change per operation")
        XCTAssertNil(store.placement(of: "f"))
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0), "the remaining tile is on the folder's cell")
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .small, "with its own size")
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(3, 3))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
        try assertRoundTrip(store, catalog: ["a", "x", "y"], in: directory)
    }

    /// A take-out from a folder of three tiles: the folder stays with two, cells do not change.
    func testExtractLeavingTwoKeepsFolder() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 3), columns: columns))

        XCTAssertEqual(notifications(), 1)
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(0, 0))
        XCTAssertEqual(store.folderContaining("y")?.tiles.map { $0.id }, ["y", "z"])
        XCTAssertEqual(store.snapshot().folders.count, 1)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// A take-out into a new row: the remaining tile stands on the folder's cell and counts toward
    /// the "last occupied row" (after a dissolution a large tile lowers the new row).
    func testExtractToNewRowDissolvesAndCountsRemainingTileInNewRow() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolderToNewRow("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .large)
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(4, 0), "after large (rows 0–3)")
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// A take-out onto the folder's own cell: the remaining tile already stands there, the one taken out
    /// takes the cell and pushes it down (the usual placement rules).
    func testExtractOntoFolderCellPushesRemainingTileDown() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(0, 0), columns: columns))

        XCTAssertEqual(store.placement(of: "x"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(1, 0), "y is pushed below x")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// The host forbade the take-out: the model does not change, the folder is intact, no notifications.
    func testDeniedExtractLeavesFolderIntact() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore([], folders: folders, in: directory)
        let before = store.placements
        let notifications = countNotifications(store)
        store.approval = { _, _, _ in false }

        XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(3, 3), columns: columns))

        XCTAssertEqual(notifications(), 0)
        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(store.folderContaining("x")?.tiles.map { $0.id }, ["x", "y"])
    }

    // MARK: - Size of the remaining tile

    /// A remaining tile larger than the folder (large) pushes neighbors down in a cascade.
    func testRemainingTileBiggerThanFolderPushesNeighborsDown() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("a", .small, 2, 0),
            CellFixtureTile("b", .small, 2, 1),
            CellFixtureTile("c", .small, 0, 4),
            CellFixtureTile("d", .small, 4, 0),
        ]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .large)
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(4, 0), "a is pushed out below large")
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(4, 1))
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(5, 0), "the cascade reached d")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 4), "holes outside the area are untouched")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders, unpinned: []))
    }

    /// A wide tile at the right edge: the column shifts left so that it fits.
    func testWideRemainingTileAtRightEdgeClampsLeft() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("n", .small, 0, 2)]
        let folders = [CellFixtureFolder("f", .medium, 0, 4, contents: [("x", .small), ("y", .wide)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 2), "4 columns: left to column 2")
        XCTAssertEqual(store.placement(of: "n"), tesseraCell(2, 2), "n is pushed below wide")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// A large tile at the right edge on a dissolution is also clamped by the canvas and does not go beyond it.
    func testLargeRemainingTileAtRightEdgeStaysInsideCanvas() throws {
        let directory = TesseraTestDirectory()
        let valid = [CellFixtureFolder("f", .medium, 1, 4, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore([], folders: valid, in: directory)

        XCTAssertTrue(store.extractFromFolderToNewRow("x", columns: columns))

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(1, 2), "large 4×4 on 6 columns: the right edge is column 2")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: valid))
    }

    /// The size chosen by the user is kept (medium) and survives the write round trip;
    /// a smaller remaining tile leaves a hole on the folder's cells.
    func testRemainingTileKeepsCustomSizeAndLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .wide, 0, 0, contents: [("x", .small), ("y", .medium)])]
        let tiles = [CellFixtureTile("n", .small, 0, 4)]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .medium)
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertFalse(store.placements.values.contains(tesseraCell(0, 2)), "the right half of the wide folder is a hole")
        XCTAssertEqual(store.placement(of: "n"), tesseraCell(0, 4))
        try assertRoundTrip(store, catalog: ["n", "x", "y"], in: directory)
    }

    // MARK: - Unpin

    /// Unpinning a tile from a folder of two tiles: the folder is dissolved; the tile is
    /// among the unpinned ones; from three, the folder stays.
    func testUnpinInsideFolderLeavingOneDissolvesAndLeavingTwoKeeps() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
            CellFixtureFolder("g", .medium, 3, 0, contents: [("p", .small), ("q", .small), ("r", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.unpin("x", columns: columns))
        XCTAssertEqual(notifications(), 1)
        XCTAssertNil(store.folderContaining("y"))
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["x"])

        XCTAssertTrue(store.unpin("p", columns: columns))
        XCTAssertEqual(notifications(), 2)
        XCTAssertEqual(store.folderContaining("q")?.tiles.map { $0.id }, ["q", "r"])
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(3, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
        try assertRoundTrip(store, catalog: ["x", "y", "p", "q", "r"], in: directory)
    }

    // MARK: - Move between folders

    /// A source folder of two tiles is dissolved, the target receives the tile.
    func testMoveBetweenFoldersSourceLeftWithOneDissolves() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 0, 3, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))

        XCTAssertEqual(notifications(), 1)
        XCTAssertNil(store.placement(of: "f"))
        XCTAssertEqual(store.placement(of: "x2"), tesseraCell(0, 0))
        XCTAssertEqual(store.folderContaining("x")?.tiles.map { $0.id }, ["y", "y2", "x"])
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(0, 3))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// Step order: the remaining large tile in the place of the source folder
    /// pushes the target folder down, and the moved tile lands in it.
    func testMoveBetweenFoldersRemainingLargeTilePushesTargetFolderDown() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .large)]),
            CellFixtureFolder("g", .medium, 2, 2, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))

        XCTAssertEqual(store.placement(of: "x2"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(4, 2), "the target folder is pushed below large")
        XCTAssertEqual(store.folderContaining("x")?.id, AnyHashable("g"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    /// The remainder tile and the moved tile can end up in one folder in the next
    /// step: after the dissolution the remainder is a regular tile, and `addToFolder` accepts it.
    func testRemainingTileCanBeAddedToTargetFolderAfterDissolve() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 0, 3, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))
        XCTAssertTrue(store.addToFolder("x2", folderID: "g", columns: columns))

        XCTAssertEqual(store.folderContaining("x2")?.tiles.map { $0.id }, ["y", "y2", "x", "x2"])
        XCTAssertEqual(store.snapshot().folders.count, 1)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs([], folders: folders))
    }

    // MARK: - Catalog cleanup

    /// A tile disappeared from the catalog: from a folder of two tiles one is left, so the folder
    /// is dissolved (its cell is the folder's cell); from three it stays with two; if both
    /// disappeared, the folder vanishes. One notification per `setCatalog`.
    func testPruneAgainstCatalogDissolvesUnderfilledFolders() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .wide)]),
            CellFixtureFolder("g", .medium, 3, 0, contents: [("p", .small), ("q", .small), ("r", .small)]),
            CellFixtureFolder("h", .medium, 3, 3, contents: [("m", .small), ("n", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let notifications = countNotifications(store)

        let all = ["x", "y", "p", "q", "r", "m", "n"]
        let remaining = all.filter { $0 != "x" && $0 != "p" && $0 != "m" && $0 != "n" }
        store.setCatalog(remaining.map { tesseraTestTile($0, size: $0 == "y" ? .wide : .small) })

        XCTAssertEqual(notifications(), 1)
        XCTAssertNil(store.folderContaining("y"), "f is dissolved")
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: "y")?.size, .wide, "the remaining tile's size is kept")
        XCTAssertEqual(store.folderContaining("q")?.tiles.map { $0.id }, ["q", "r"], "g with two tiles stays")
        XCTAssertNil(store.placement(of: "h"), "h became empty and vanished")
        XCTAssertEqual(store.snapshot().folders.count, 1)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: remaining)
    }

    /// A large tile remaining after cleanup pushes neighbors down.
    func testPruneRemainingLargeTilePushesNeighborsDown() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 2, 0)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .large)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        store.setCatalog(["a", "y"].map { tesseraTestTile($0, size: $0 == "y" ? .large : .small) })

        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "y"])
    }

    /// A folder that cleanup did not touch is not affected by the rule (a transitional
    /// folder `createFolder(withTile:)` survives a repeated `setCatalog`).
    func testRepeatedSetCatalogKeepsTransientSingleTileFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1)]
        let store = try makeStore(tiles, in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))

        store.setCatalog(["a", "b"].map { tesseraTestTile($0, size: .small) })

        XCTAssertEqual(store.snapshot().folders.map { $0.id }, [folder.id])
        XCTAssertEqual(store.folderContaining("a")?.tiles.map { $0.id }, ["a"])
    }

    // MARK: - File loading

    /// A file with folders of 0 and 1 tiles when a catalog is registered:
    /// the empty one disappears, the single-tile one is dissolved: the tile is on the folder's cell.
    func testLoadRepairsZeroAndOneTileFolders() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [
            CellFixtureFolder("one", .medium, 0, 0, contents: [("x", .wide)]),
            CellFixtureFolder("empty", .medium, 2, 0, contents: []),
            CellFixtureFolder("ok", .medium, 4, 0, contents: [("p", .small), ("q", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertEqual(store.snapshot().folders.map { $0.id }, ["ok"])
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(0, 0), "x took the folder's cell with its own size")
        XCTAssertEqual(store.snapshot().item(withID: "x")?.size, .wide)
        XCTAssertNil(store.placement(of: "empty"))
        XCTAssertEqual(store.placement(of: "ok"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "x", "p", "q"])
    }

    /// A version 2 file is read before the catalog is registered: a single-tile folder waits for
    /// the catalog (which tiles exist is unknown) and is dissolved after `setCatalog`;
    /// if its tile is not in the catalog, it vanishes without a "ghost".
    func testLoadBeforeCatalogDefersDissolveUntilCatalogIsKnown() throws {
        for tileInCatalog in [true, false] {
            let directory = TesseraTestDirectory()
            try directory.create()
            let json = """
            {
              "version": 2, "columns": 6,
              "items": [
                {"kind": "tile", "key": "s:a", "row": 0, "column": 4},
                {"kind": "folder", "key": "s:f", "row": 0, "column": 0}
              ],
              "sizes": {"s:a": "small", "s:x": "medium"},
              "folders": [{"key": "s:f", "title": "F", "size": "medium", "tileKeys": ["s:x"]}]
            }
            """
            let store = TesseraTileStore(directoryURL: directory.url)
            store.autosaves = false
            try Data(json.utf8).write(to: store.fileURL)
            try store.load()
            XCTAssertEqual(store.canvasColumns, 6)

            store.setCatalog((tileInCatalog ? ["a", "x"] : ["a"]).map { tesseraTestTile($0, size: .small) })

            XCTAssertTrue(store.snapshot().folders.isEmpty, "tileInCatalog=\(tileInCatalog)")
            if tileInCatalog {
                XCTAssertEqual(store.placement(of: "x"), tesseraCell(0, 0))
                XCTAssertEqual(store.snapshot().item(withID: "x")?.size, .medium)
            } else {
                XCTAssertNil(store.placement(of: "x"), "the tile is not in the catalog: it does not linger even as an invisible key on the grid")
                XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a"])
            }
            tesseraAssertCellInvariants(store, columns: 6, catalogIDs: tileInCatalog ? ["a", "x"] : ["a"])
        }
    }

    /// A version 1 file (without cells): a single-tile folder is replaced by the tile in its place in the order.
    func testLoadVersionOneFileReplacesOneTileFolderInPlace() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let json = """
        {
          "version": 1,
          "items": [
            {"kind": "tile", "key": "s:a"},
            {"kind": "folder", "key": "s:f"},
            {"kind": "tile", "key": "s:b"}
          ],
          "sizes": {},
          "folders": [{"key": "s:f", "title": "F", "size": "medium", "tileKeys": ["s:x"]}]
        }
        """
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try Data(json.utf8).write(to: store.fileURL)
        store.setCatalog(["a", "b", "x"].map { tesseraTestTile($0, size: .small) })
        try store.load()

        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a", "x", "b"] as [AnyHashable])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
    }

    // MARK: - Transitional single-tile folder

    /// `createFolder(withTile:)` creates a transitional folder: it lives until
    /// `addToFolder`; removing its only tile removes the folder (a hole) instead of
    /// dissolving it into nothing.
    func testTransientSingleTileFolderLifecycle() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 3)]
        let store = try makeStore(tiles, in: directory)

        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertEqual(store.snapshot().folders.map { $0.id }, [folder.id], "the transitional folder lives")

        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertEqual(store.folderContaining("a")?.tiles.map { $0.id }, ["a", "b"])
    }

    /// A transitional folder vanishes when its only tile leaves.
    func testTransientFolderDisappearsWhenItsTileLeaves() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 3)]
        let store = try makeStore(tiles, in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))

        XCTAssertTrue(store.unpin("a", columns: columns))

        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertNil(store.placement(of: folder.id))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "b"])
    }

    // MARK: - Persistence

    /// A dissolution is a single save: the file after the operation describes the tile on the folder's
    /// cell and contains no folder.
    func testDissolveIsPersistedInOneWrite() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .medium)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))

        let data = try Data(contentsOf: store.fileURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["key"] as? String, "s:y")
        XCTAssertEqual(items.first?["kind"] as? String, "tile")
        XCTAssertEqual(items.first?["row"] as? Int, 0)
        XCTAssertEqual(items.first?["column"] as? Int, 0)
        XCTAssertEqual((object["folders"] as? [Any])?.count, 0)
        XCTAssertEqual((object["sizes"] as? [String: String])?["s:y"], "medium")
    }

    // MARK: - Property: after any operations and catalog cleanup there are no folders of fewer than two

    /// Random folders (2–4 tiles) and random catalog subsets: after
    /// `setCatalog` there is no folder of 0–1 tiles, tiles are not lost, there are no overlaps.
    func testRandomCatalogPruneNeverLeavesUnderfilledFolders() throws {
        for seed in 1...24 {
            var rng = TesseraTestSeededGenerator(seed: UInt64(seed))
            let directory = TesseraTestDirectory()
            let sizes: [TesseraTileSize] = [.small, .medium, .wide, .large]

            var folders: [CellFixtureFolder] = []
            var all: [String] = []
            let rows = [0, 4, 8]
            for index in 0..<3 {
                let count = 2 + rng.int(upperBound: 3)
                let ids = (0..<count).map { "f\(index)t\($0)" }
                all += ids
                folders.append(CellFixtureFolder(
                    "F\(index)", .medium, rows[index], 0,
                    contents: ids.map { ($0, sizes[rng.int(upperBound: 4)]) }
                ))
            }
            let store = try makeStore([], folders: folders, in: directory)

            let kept = all.filter { _ in rng.int(upperBound: 3) != 0 }
            var sizeByID: [String: TesseraTileSize] = [:]
            for folder in folders { for content in folder.contents { sizeByID[content.id] = content.size } }
            store.setCatalog(kept.map { tesseraTestTile($0, size: sizeByID[$0] ?? .small) })

            for folder in store.snapshot().folders {
                XCTAssertGreaterThanOrEqual(folder.tiles.count, 2, "seed \(seed)")
            }
            tesseraAssertCellInvariants(store, columns: columns, catalogIDs: kept, checkOrder: false)
        }
    }
}

#endif
