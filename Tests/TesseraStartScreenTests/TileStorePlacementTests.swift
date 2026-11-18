//
//  TileStorePlacementTests.swift
//  TesseraStartScreenTests
//
//  Tests for the model with explicit cells and the `tiles.json` version 2 schema.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid"
//  (TesseraTileStore persistence) and "Implementation notes and deviations"; decisions D30–D33 in
//  docs/DECISIONS.md.
//
//  Checked:
//  - the v1 → v2 migration: lazy, one-time, cells equal `packCompact` by the
//    old order; the file is not overwritten before `load()`;
//  - the v2 write/read round trip, first-launch layout, a new row for
//    new keys, returning/moving invisible keys;
//  - projection for a different width (D32): without rewriting the file, returning to the
//    previous width brings the holes back, the first edit adopts the new canvas;
//  - repairing offenders on load (overlaps, bounds, garbage),
//    a partial set of cells, a version newer than supported;
//  - folders have cells, folder contents do not.
//
//  The transitional rule ("cells after an operation equal order packing")
//  was removed together with the index-based API: holes after operations are checked by
//  `TileStoreCellOperationsTests`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStorePlacementTests: XCTestCase {

    // MARK: - Helpers

    private func descriptors() -> [TesseraTileDescriptor] {
        [
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .medium),
            tesseraTestTile("d", size: .small),
        ]
    }

    private func makeStore(
        _ catalog: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory,
        autosaves: Bool = true
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(catalog)
        return store
    }

    private func write(_ json: String, to store: TesseraTileStore, directory: TesseraTestDirectory) throws {
        try directory.create()
        try Data(json.utf8).write(to: store.fileURL)
    }

    /// Expected cells: the former `packCompact` by snapshot order.
    private func packedExpectation(
        _ store: TesseraTileStore,
        columns: Int
    ) -> [AnyHashable: TesseraTileGridPlacement] {
        let items = store.snapshot().layoutItems.map {
            (id: $0.id, size: TesseraTileLayoutEngine.fittingSize($0.size, columns: columns))
        }
        var result: [AnyHashable: TesseraTileGridPlacement] = [:]
        for slot in TesseraTileLayoutEngine.packCompact(items: items, columns: columns, unit: 1) {
            result[slot.id] = TesseraTileGridPlacement(row: slot.row, column: slot.column)
        }
        return result
    }

    private func jsonObject(_ store: TesseraTileStore) throws -> [String: Any] {
        let data = try Data(contentsOf: store.fileURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fileItems(_ store: TesseraTileStore) throws -> [[String: Any]] {
        try XCTUnwrap(try jsonObject(store)["items"] as? [[String: Any]])
    }

    /// No overlaps of visible items and all rectangles are inside the canvas.
    private func assertNoOverlapsAndInBounds(
        _ store: TesseraTileStore,
        columns: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cells = store.placements
        let sizes = Dictionary(uniqueKeysWithValues: store.snapshot().items.map { ($0.id, $0.size) })
        var rects: [(id: AnyHashable, rect: CGRect)] = []
        for (id, cell) in cells {
            let size = TesseraTileLayoutEngine.fittingSize(sizes[id] ?? .medium, columns: columns)
            let rect = CGRect(x: cell.column, y: cell.row, width: size.unitColumns, height: size.unitRows)
            XCTAssertGreaterThanOrEqual(cell.row, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(cell.column, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, CGFloat(columns), file: file, line: line)
            rects.append((id, rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(
                    rects[i].rect.intersects(rects[j].rect),
                    "\(rects[i].id) overlaps \(rects[j].id)",
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertEqual(Set(cells.keys), Set(store.snapshot().items.map { $0.id }), file: file, line: line)
    }

    private let v1Json = """
    {
      "version": 1,
      "items": [
        {"kind": "tile", "key": "s:a"},
        {"kind": "tile", "key": "s:b"},
        {"kind": "tile", "key": "s:c"},
        {"kind": "tile", "key": "s:d"}
      ],
      "sizes": {"s:a": "small", "s:b": "medium", "s:c": "medium", "s:d": "small"},
      "folders": []
    }
    """

    // MARK: - v1 → v2 migration

    /// A version 1 file migrates lazily: `load()` gives no cells, and the first call with a
    /// width assigns them with the former `packCompact` and immediately writes version 2.
    func testV1MigratesLazilyOnceAndPersists() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        try write(v1Json, to: store, directory: directory)
        let originalData = try Data(contentsOf: store.fileURL)

        try store.load()
        XCTAssertNil(store.canvasColumns)
        XCTAssertTrue(store.placements.isEmpty)
        XCTAssertNil(store.placement(of: "a"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData, "load() does not rewrite the file")

        XCTAssertTrue(store.placeItems(columns: 6))
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        XCTAssertEqual(store.placement(of: "a"), TesseraTileGridPlacement(row: 0, column: 0))

        // Written immediately: version 2, the canvas width, cells for every item.
        let object = try jsonObject(store)
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["columns"] as? Int, 6)
        let items = try fileItems(store)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0["row"] is Int && $0["column"] is Int })
        let migratedData = try Data(contentsOf: store.fileURL)

        // One-time: a repeated call and a different width do not touch the file.
        XCTAssertFalse(store.placeItems(columns: 6))
        XCTAssertFalse(store.placeItems(columns: 4))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), migratedData)
        XCTAssertEqual(store.canvasColumns, 6)

        let reloaded = makeStore(descriptors(), in: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.canvasColumns, 6)
        XCTAssertEqual(reloaded.placements, store.placements)
    }

    /// If the width is known before `load()`, the migration runs at the end of `load()`.
    func testV1MigratesAtLoadWhenWidthAlreadyKnown() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        try write(v1Json, to: store, directory: directory)
        let originalData = try Data(contentsOf: store.fileURL)

        // Before load() the store has only the catalog seed: the v1 file must not be overwritten.
        XCTAssertTrue(store.placeItems(columns: 4))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)

        try store.load()
        XCTAssertEqual(store.canvasColumns, 4)
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 4))
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL), originalData)
        XCTAssertEqual(try jsonObject(store)["version"] as? Int, 2)
    }

    /// The migration waits for the catalog: invisible tiles must not take the canvas.
    func testMigrationWaitsForCatalog() throws {
        let directory = TesseraTestDirectory()
        let store = TesseraTileStore(directoryURL: directory.url)
        try write(v1Json, to: store, directory: directory)
        try store.load()

        XCTAssertFalse(store.placeItems(columns: 6), "there is no catalog yet")
        XCTAssertNil(store.canvasColumns)

        store.setCatalog(descriptors())
        XCTAssertTrue(store.placeItems(columns: 6))
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
    }

    /// Invisible tiles of a v1 file get cells in rows after the visible ones and do not
    /// shift the visible ones.
    func testV1InvisibleKeysGoBelowVisible() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small), tesseraTestTile("b", size: .medium)], in: directory)
        try write(v1Json, to: store, directory: directory)
        try store.load()
        store.placeItems(columns: 6)

        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        let items = try fileItems(store)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0["row"] is Int }, "invisible ones have cells too")

        // The returned invisible tile "c" is in its own place, which is free.
        store.setCatalog(descriptors())
        let c = try XCTUnwrap(store.placement(of: "c"))
        XCTAssertGreaterThanOrEqual(c.row, 2)
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    // MARK: - v2 round trip, first launch, new keys

    func testSeedIsPackedWhenWidthKnown() {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)

        XCTAssertNil(store.canvasColumns, "there are no cells before the width")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        XCTAssertTrue(store.placeItems(columns: 6))
        XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        XCTAssertEqual(store.placement(of: "a"), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(store.placement(of: "b"), TesseraTileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(store.placement(of: "d"), TesseraTileGridPlacement(row: 0, column: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testPlaceItemsOnEmptyStoreWritesNothing() {
        let directory = TesseraTestDirectory()
        let store = TesseraTileStore(directoryURL: directory.url)
        XCTAssertFalse(store.placeItems(columns: 6))
        XCTAssertFalse(store.placeItems(columns: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The v2 round trip: write → read gives the same cells, order and canvas width;
    /// JSON keys are sorted.
    func testRoundTripOfSchemaV2() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)
        XCTAssertTrue(store.resize("a", to: .wide, columns: 6))
        try store.save()

        let reloaded = makeStore(descriptors(), in: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.canvasColumns, 6)
        XCTAssertEqual(reloaded.placements, store.placements)
        XCTAssertEqual(reloaded.snapshot().items.map { $0.id }, store.snapshot().items.map { $0.id })

        let text = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        let columnsRange = try XCTUnwrap(text.range(of: "\"columns\""))
        let itemsRange = try XCTUnwrap(text.range(of: "\"items\""))
        let versionRange = try XCTUnwrap(text.range(of: "\"version\""))
        XCTAssertLessThan(columnsRange.lowerBound, itemsRange.lowerBound)
        XCTAssertLessThan(itemsRange.lowerBound, versionRange.lowerBound)
    }

    /// A new catalog key after cells appear goes into a new row at the end.
    func testNewCatalogKeyGoesToNewRowAtEnd() {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)
        let before = store.placements

        store.setCatalog(descriptors() + [tesseraTestTile("e", size: .wide)])
        // Rows 0–1 are occupied (two medium tiles): the new row is 2.
        XCTAssertEqual(store.placement(of: "e"), TesseraTileGridPlacement(row: 2, column: 0))
        for (id, cell) in before {
            XCTAssertEqual(store.placement(of: id), cell, "the previous cells do not move")
        }

        store.setCatalog(descriptors() + [
            tesseraTestTile("e", size: .wide),
            tesseraTestTile("f", size: .small),
        ])
        XCTAssertEqual(store.placement(of: "f"), TesseraTileGridPlacement(row: 4, column: 0))
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    // MARK: - Invisible keys

    private func storeWithInvisibleD(_ directory: TesseraTestDirectory) throws -> TesseraTileStore {
        let first = makeStore(descriptors(), in: directory)
        first.placeItems(columns: 6)
        try first.save()

        let store = makeStore(Array(descriptors().prefix(3)), in: directory)
        try store.load()
        return store
    }

    /// An invisible tile keeps its cell; when it returns to a free spot, it takes it.
    func testInvisibleKeyReturnsToFreeCell() throws {
        let directory = TesseraTestDirectory()
        let store = try storeWithInvisibleD(directory)
        XCTAssertNil(store.placement(of: "d"), "invisible ones are not in the visible cells")
        XCTAssertEqual(store.placements.count, 3)

        XCTAssertTrue(store.unpin("a", columns: 6))
        XCTAssertTrue(try fileItems(store).contains { ($0["key"] as? String) == "s:d" && $0["row"] is Int },
                      "the invisible tile's cell is saved in the file")

        store.setCatalog(descriptors())
        XCTAssertEqual(store.placement(of: "d"), TesseraTileGridPlacement(row: 0, column: 5))
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    /// If the spot is taken by a visible item, the returning key goes into a new row.
    func testInvisibleKeyRelocatesWhenCellIsTaken() throws {
        let directory = TesseraTestDirectory()
        let store = try storeWithInvisibleD(directory)

        // "c" (2×2) moves to column 5 and is clamped to the canvas up to column 4:
        // it takes columns 4–5 of rows 0–1, that is, the cell (0, 5) of the invisible "d".
        XCTAssertTrue(store.moveItem("c", toCell: TesseraTileGridPlacement(row: 0, column: 5), columns: 6))
        XCTAssertEqual(store.placement(of: "c"), TesseraTileGridPlacement(row: 0, column: 4))

        store.setCatalog(descriptors())
        let d = try XCTUnwrap(store.placement(of: "d"))
        XCTAssertEqual(d, TesseraTileGridPlacement(row: 2, column: 0), "the row after the last occupied one")
        assertNoOverlapsAndInBounds(store, columns: 6)
    }

    // MARK: - Different width (D32)

    /// A file with holes on a canvas of 6.
    private let holesJson = """
    {
      "version": 2,
      "columns": 6,
      "items": [
        {"kind": "tile", "key": "s:a", "row": 0, "column": 0},
        {"kind": "tile", "key": "s:b", "row": 2, "column": 3},
        {"kind": "tile", "key": "s:c", "row": 4, "column": 1}
      ],
      "sizes": {"s:a": "small", "s:b": "small", "s:c": "medium"},
      "folders": []
    }
    """

    private func holesStore(_ directory: TesseraTestDirectory) throws -> TesseraTileStore {
        let store = makeStore(
            [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .medium),
            ],
            in: directory
        )
        try write(holesJson, to: store, directory: directory)
        try store.load()
        return store
    }

    func testProjectionForOtherWidthDoesNotRewriteFileAndRestoresHoles() throws {
        let directory = TesseraTestDirectory()
        let store = try holesStore(directory)
        let originalData = try Data(contentsOf: store.fileURL)

        // The holes are preserved for the canvas width.
        let stored = store.placements(forColumns: 6)
        XCTAssertEqual(stored["b"], TesseraTileGridPlacement(row: 2, column: 3))
        XCTAssertEqual(stored["c"], TesseraTileGridPlacement(row: 4, column: 1))
        XCTAssertEqual(stored, store.placements)

        // Width 4: a repack in reading order without holes.
        let projected = store.placements(forColumns: 4)
        XCTAssertEqual(projected["a"], TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(projected["b"], TesseraTileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(projected["c"], TesseraTileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(store.placementReadingOrder(forColumns: 4), ["a", "b", "c"])

        // The host reported width 4: the file is untouched, the canvas is the previous one.
        XCTAssertFalse(store.placeItems(columns: 4))
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)

        // Returning to the previous width without edits brings the holes back.
        XCTAssertEqual(store.placements(forColumns: 6), stored)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)
    }

    func testFirstMutationInMismatchedWidthAdoptsNewCanvas() throws {
        let directory = TesseraTestDirectory()
        let store = try holesStore(directory)
        store.placeItems(columns: 4)
        let originalData = try Data(contentsOf: store.fileURL)

        XCTAssertTrue(store.resize("b", to: .medium, columns: 4))
        XCTAssertEqual(store.canvasColumns, 4)
        XCTAssertNotEqual(try Data(contentsOf: store.fileURL), originalData)
        XCTAssertEqual(try jsonObject(store)["columns"] as? Int, 4)
        // Projection: a (0,0), b (0,1), c (0,2); growing "b" to 2×2 in place covers
        // "c", and it is pushed down (D31).
        XCTAssertEqual(store.placement(of: "a"), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(store.placement(of: "b"), TesseraTileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(store.placement(of: "c"), TesseraTileGridPlacement(row: 2, column: 2))
        assertNoOverlapsAndInBounds(store, columns: 4)

        // Now the projection is needed for 6, and the previous holes are lost.
        XCTAssertNotEqual(store.placements(forColumns: 6)["c"], TesseraTileGridPlacement(row: 4, column: 1))
    }

    /// Without cells the projection is a packing of the current order.
    func testProjectionWithoutPlacementsPacksCurrentOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        XCTAssertEqual(store.placements(forColumns: 6), packedExpectation(store, columns: 6))
        XCTAssertEqual(store.placements(forColumns: 4), packedExpectation(store, columns: 4))
        XCTAssertNil(store.canvasColumns)
        XCTAssertTrue(store.placements(forColumns: 0).isEmpty)
    }

    // MARK: - File repair

    /// Overlaps, out-of-bounds and negative cells: the offenders go
    /// into new rows at the end; settled items stay in place.
    func testLoadRepairsOverlapsAndOutOfBounds() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory, autosaves: false)
        let json = """
        {
          "version": 2,
          "columns": 6,
          "items": [
            {"kind": "tile", "key": "s:a", "row": 0, "column": 0},
            {"kind": "tile", "key": "s:b", "row": 0, "column": 0},
            {"kind": "tile", "key": "s:c", "row": 0, "column": 5},
            {"kind": "tile", "key": "s:d", "row": -1, "column": 2}
          ],
          "sizes": {"s:a": "small", "s:b": "medium", "s:c": "medium", "s:d": "small"},
          "folders": []
        }
        """
        try write(json, to: store, directory: directory)
        try store.load()

        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(store.placement(of: "a"), TesseraTileGridPlacement(row: 0, column: 0))
        assertNoOverlapsAndInBounds(store, columns: 6)
        // The offenders are below the occupied a (one row), in grid order.
        for id in ["b", "c", "d"] {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.placement(of: id)).row, 1)
        }
        XCTAssertEqual(store.placement(of: "b"), TesseraTileGridPlacement(row: 1, column: 0))
    }

    /// No canvas width or a partial set of cells: the file is read as
    /// a non-layout state rather than rejected.
    func testCorruptedOrPartialPlacementsFallBackToUnplaced() throws {
        let directory = TesseraTestDirectory()
        let partial = """
        {
          "version": 2,
          "columns": 6,
          "items": [
            {"kind": "tile", "key": "s:a", "row": 0, "column": 0},
            {"kind": "tile", "key": "s:b"},
            {"kind": "tile", "key": "s:c", "row": 3, "column": 3},
            {"kind": "tile", "key": "s:d", "row": 5, "column": 1}
          ],
          "sizes": {"s:a": "small", "s:b": "medium", "s:c": "medium", "s:d": "small"},
          "folders": []
        }
        """
        let noWidth = partial.replacingOccurrences(of: "\"columns\": 6,", with: "")
        for json in [partial, noWidth] {
            let store = makeStore(descriptors(), in: directory, autosaves: false)
            try write(json, to: store, directory: directory)
            XCTAssertNoThrow(try store.load())
            XCTAssertNil(store.canvasColumns)
            XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a", "b", "c", "d"])

            XCTAssertTrue(store.placeItems(columns: 6))
            XCTAssertEqual(store.placements, packedExpectation(store, columns: 6))
        }
    }

    /// A version newer than supported: a backup copy, the state is untouched.
    func testFutureVersionKeepsStateUntouched() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)
        let placements = store.placements
        let future = Data(#"{"version":3,"columns":6,"items":[],"sizes":{},"folders":[]}"#.utf8)
        try future.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case TesseraTileStoreError.unsupportedSchemaVersion(let version)? = error as? TesseraTileStoreError else {
                return XCTFail("Expected unsupportedSchemaVersion: \(error)")
            }
            XCTAssertEqual(version, 3)
        }
        XCTAssertEqual(store.placements, placements)
        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertNotNil(store.lastUnreadableFileBackupURL)
    }

    // MARK: - Folders

    func testFoldersKeepPlacementsAndContentsHaveNone() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(descriptors(), in: directory)
        store.placeItems(columns: 6)

        let folder = try XCTUnwrap(store.createFolder(withTile: "b", columns: 6))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: 6))

        XCTAssertNotNil(store.placement(of: folder.id))
        XCTAssertNil(store.placement(of: "b"))
        XCTAssertNil(store.placement(of: "c"))
        XCTAssertEqual(store.placements.count, 3)
        // The folder took the cell of "b"; the cell of "c" stayed a hole (no repack).
        XCTAssertEqual(store.placement(of: folder.id), TesseraTileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(store.placement(of: "d"), TesseraTileGridPlacement(row: 0, column: 5))

        let items = try fileItems(store)
        let folderItem = try XCTUnwrap(items.first { ($0["kind"] as? String) == "folder" })
        XCTAssertNotNil(folderItem["row"] as? Int)
        XCTAssertNotNil(folderItem["column"] as? Int)
        XCTAssertFalse(items.contains { ($0["key"] as? String) == "s:b" })

        let reloaded = makeStore(descriptors(), in: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.placements, store.placements)
        XCTAssertEqual(reloaded.placement(of: folder.id), store.placement(of: folder.id))
    }
}

#endif
