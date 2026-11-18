//
//  TileStoreVisibleOrderTests.swift
//  TesseraStartScreenTests
//
//  Tests for visible and invisible grid keys in `TesseraTileStore`, on
//  cell-based operations.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid",
//  "Implementation notes and deviations".
//
//  Checked:
//  - tiles outside the catalog (invisible keys) keep their cells and places in the
//    file when visible items are moved, pinned and unpinned, and an
//    invisible key cannot be reordered (it is not in the snapshot);
//  - the snapshot order after operations is the reading order of the visible items' cells.
//
//  The index-based API (`move(toIndex:)`, `pin(at:)`) no longer exists (D33):
//  the former tests of this file that relied on it were replaced. Coverage of
//  the former scenarios: `TileStoreCellOperationsTests` (move, clamping, no-op),
//  `TileStoreCellPropertyTests` (snapshot order = reading order after any
//  sequence of operations) and `TileStoreCellPersistenceTests` (invisible
//  keys, canvas, write round trip).
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreVisibleOrderTests: XCTestCase {

    // MARK: - Helpers

    private let columns = 6

    private func ids(_ store: TesseraTileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// The catalog [a, b, c, d]: all small in row 0 (columns 0…3); the layout
    /// is written as a version 2 file. The store's catalog is trimmed to `visible`, so the
    /// remaining keys are invisible.
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

    /// Brings up a store with the full catalog on top of the file written by `store`.
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

    // MARK: - Invisible keys on move

    /// The catalog [a, b, c, d] with b removed from the catalog: moving `a` onto the cell of `c`
    /// pushes `c` down, the snapshot order is the cell reading order, and
    /// the invisible `b` keeps its cell and, after returning to the catalog, stays
    /// on it.
    func testMoveItemToCellKeepsHiddenKeyCell() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["b"], in: directory)
        XCTAssertEqual(ids(store), ["a", "c", "d"])

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(0, 2), columns: columns))
        // a goes to (0,2); c is pushed to (1,2); d to (0,3): reading order a, d, c.
        XCTAssertEqual(ids(store), ["a", "d", "c"])
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 2))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 2))

        let reloaded = try reloadWithFullCatalog(savedBy: store, in: directory)
        XCTAssertEqual(reloaded.placement(of: "b"), tesseraCell(0, 1), "the invisible b stayed on its cell")
        XCTAssertEqual(reloaded.placement(of: "a"), tesseraCell(0, 2))
        XCTAssertEqual(reloaded.placement(of: "c"), tesseraCell(1, 2))
    }

    /// The cell of an invisible key does not take part in collisions: moving a visible
    /// item onto it does not push the invisible key out, and a key that returns to the catalog
    /// goes into a new row (its cell was taken).
    func testMoveOntoHiddenKeyCellDoesNotPushHiddenKey() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["b"], in: directory)

        XCTAssertTrue(store.moveItem("d", toCell: tesseraCell(0, 1), columns: columns))
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(0, 1))
        XCTAssertEqual(ids(store), ["a", "d", "c"])

        // "b" returns to the catalog: its cell was taken, so it goes into a new
        // row at the end of the canvas, and visible items do not move.
        store.setCatalog(["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) })
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(1, 0))
    }

    /// An invisible key cannot be reordered, changed or unpinned: it is not in the
    /// snapshot, so operations return `false` and write nothing.
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

    // MARK: - Invisible keys on pinning

    /// Pinning goes into a new row and does not touch the cells of invisible keys;
    /// unpinning leaves a hole, and returning to the same row through a new row
    /// does not break the reading order.
    func testPinAndUnpinKeepHiddenKeyCell() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStoreHiding(["b"], in: directory)

        XCTAssertTrue(store.unpin("d", columns: columns))
        XCTAssertEqual(ids(store), ["a", "c"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["d"])

        XCTAssertTrue(store.pinTile("d", columns: columns))
        XCTAssertEqual(ids(store), ["a", "c", "d"])
        XCTAssertEqual(store.placement(of: "d"), tesseraCell(1, 0), "pinning is a new row at the end of the canvas")

        let reloaded = try reloadWithFullCatalog(savedBy: store, in: directory)
        XCTAssertEqual(reloaded.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(reloaded.placement(of: "d"), tesseraCell(1, 0))
    }

    // MARK: - Snapshot order = cell reading order

    /// After a move, growth and unpinning, the order of `snapshot().items` and
    /// `placementReadingOrder` match (the store does not canonicalize the order:
    /// it is derived from cells).
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
        // Reading order: a(0,0), s(0,2), w(2,0).
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
