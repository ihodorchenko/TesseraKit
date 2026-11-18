//
//  TileAccessibilityOrderTests.swift
//  TesseraStartScreenTests
//
//  VoiceOver order by cells and focus after edit operations.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §9 "Accessibility" and
//  "Implementation notes and deviations"; decisions D30–D33 in docs/DECISIONS.md.
//
//  VoiceOver traversal order is the order of collection indexes (the grid does not set
//  `accessibilityElements`; the layout supplies attributes by index), so the tests
//  check the order of the snapshot and of the collection's item set, and also that the
//  element frames run in the same order (rows top to bottom, then columns in
//  the reading direction): this way the index order also matches what a
//  frame-based traversal would see. There is no real VoiceOver here — the check is structural.
//
//  Covered: holes in a row, tall and wide tiles, a file not in reading order,
//  v1 → v2 migration, projection to another width, `setCatalog`, a grid without a
//  `TesseraTileStore` (only a cell table), fallback to packing, column changes, RTL,
//  the panel of an opened folder; focus after unpin (next/previous/the grid),
//  resize, a drop into a hole, merging into a folder, take-out from a folder; custom actions.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileAccessibilityOrderTests: XCTestCase {

    // MARK: - Helpers

    private func small(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .small)) }
    private func medium(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .medium)) }
    private func wide(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .wide)) }

    private func ids(_ items: [TesseraTileGridItem]) -> [AnyHashable] { items.map { $0.id } }

    /// A snapshot with a cell table for a grid of the given width.
    private func snapshot(
        _ items: [TesseraTileGridItem],
        cells: [AnyHashable: TesseraTileGridPlacement],
        columns: Int? = 4
    ) -> TesseraTileGridSnapshot {
        TesseraTileGridSnapshot(
            items: items,
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(cells: cells, columns: columns)
        )
    }

    /// Collection item frames run in reading order: rows top to bottom, then
    /// columns in the reading direction (right to left in RTL). The panel of an opened
    /// folder is part of the check on a par with tiles.
    private func assertFramesFollowReadingOrder(
        _ host: TesseraTestWindowedGrid,
        rightToLeft: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        host.layout()
        let collectionView = try XCTUnwrap(host.collectionView, file: file, line: line)
        let count = host.grid.displayItems.count
        var frames: [CGRect] = []
        for index in 0..<count {
            let attributes = try XCTUnwrap(
                collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
                "attributes \(index)", file: file, line: line
            )
            frames.append(attributes.frame)
        }
        for index in 1..<max(count, 1) {
            let previous = frames[index - 1]
            let current = frames[index]
            let sameRow = abs(previous.minY - current.minY) < 0.5
            if sameRow {
                let inReadingDirection = rightToLeft
                    ? previous.minX > current.minX
                    : previous.minX < current.minX
                XCTAssertTrue(
                    inReadingDirection,
                    "items \(index - 1) and \(index) in one row run against the reading direction",
                    file: file, line: line
                )
            } else {
                XCTAssertLessThan(
                    previous.minY, current.minY,
                    "item \(index) is above item \(index - 1)", file: file, line: line
                )
            }
        }
    }

    // MARK: - Grid: order by cell table (without TesseraTileStore)

    /// A hole in a row: items supplied by the host in a shuffled order go in the
    /// cells' reading order — in the grid snapshot and in the collection's item set.
    func testGridOrdersItemsByCellsWithHoleInRow() throws {
        let cells: [AnyHashable: TesseraTileGridPlacement] = [
            "a": tesseraCell(0, 0), "b": tesseraCell(0, 3), "c": tesseraCell(3, 1),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot([medium("c"), small("b"), small("a")], cells: cells)
        )

        XCTAssertEqual(host.grid.items.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        XCTAssertEqual(host.grid.index(ofItemID: "b"), 1)
        try assertFramesFollowReadingOrder(host)
    }

    /// Tall and wide tiles: the order is the row, then the column of the top-left
    /// corner, not "bottom to top by height".
    func testGridOrdersTallAndWideTilesByTopLeftCell() throws {
        let cells: [AnyHashable: TesseraTileGridPlacement] = [
            "m": tesseraCell(0, 0), "s1": tesseraCell(0, 2), "s3": tesseraCell(0, 3),
            "s2": tesseraCell(1, 2), "w": tesseraCell(2, 0), "t": tesseraCell(4, 3),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot(
                [small("t"), wide("w"), small("s2"), small("s3"), small("s1"), medium("m")],
                cells: cells
            )
        )

        XCTAssertEqual(
            host.grid.displayItems.map { $0.id },
            ["m", "s1", "s3", "s2", "w", "t"] as [AnyHashable]
        )
        try assertFramesFollowReadingOrder(host)
    }

    /// The snapshot order is already correct — the grid snapshot is the same, with no reordering.
    func testGridKeepsOrderedSnapshotAsIs() {
        let cells: [AnyHashable: TesseraTileGridPlacement] = ["a": tesseraCell(0, 0), "b": tesseraCell(1, 0)]
        let ordered = snapshot([small("a"), small("b")], cells: cells)
        let result = ordered.readingOrdered(columns: 4)
        XCTAssertEqual(result.items.map { $0.id }, ["a", "b"] as [AnyHashable])
        XCTAssertEqual(result.placementTable, ordered.placementTable)
    }

    /// Without an applicable table the order stays as the host supplied it: `pack`
    /// packing follows the snapshot order. These are a table for another width, an incomplete one,
    /// and a missing one.
    func testGridKeepsGivenOrderWhenTableIsNotApplicable() {
        let items = [small("c"), small("a"), small("b")]

        // The table is computed for 6 columns, the grid has 4.
        let otherWidth = TesseraTestWindowedGrid(
            snapshot: snapshot(
                items,
                cells: ["a": tesseraCell(0, 0), "b": tesseraCell(0, 1), "c": tesseraCell(1, 0)],
                columns: 6
            )
        )
        XCTAssertEqual(otherWidth.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])

        // Incomplete: there is no cell for "b".
        let partial = TesseraTestWindowedGrid(
            snapshot: snapshot(items, cells: ["a": tesseraCell(0, 0), "c": tesseraCell(1, 0)])
        )
        XCTAssertEqual(partial.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])

        // With an overlap: the cells fail validation.
        let overlapping = TesseraTestWindowedGrid(
            snapshot: snapshot(
                items,
                cells: ["a": tesseraCell(0, 0), "b": tesseraCell(0, 0), "c": tesseraCell(1, 0)]
            )
        )
        XCTAssertEqual(overlapping.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])

        // Without a table.
        let noTable = TesseraTestWindowedGrid(items: items)
        XCTAssertEqual(noTable.grid.items.map { $0.id }, ["c", "a", "b"] as [AnyHashable])
    }

    /// `update(snapshot:animated:)` orders the items the same way as `reload`.
    func testUpdateAlsoOrdersByCells() {
        let host = TesseraTestWindowedGrid(items: [small("a")])
        let cells: [AnyHashable: TesseraTileGridPlacement] = [
            "a": tesseraCell(2, 0), "b": tesseraCell(0, 2), "c": tesseraCell(1, 1),
        ]
        host.grid.update(
            snapshot: snapshot([small("a"), small("b"), small("c")], cells: cells),
            animated: false
        )
        host.layout()
        XCTAssertEqual(host.grid.items.map { $0.id }, ["b", "c", "a"] as [AnyHashable])
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["b", "c", "a"] as [AnyHashable])
    }

    /// A change in the column count makes the table applicable: the order is rebuilt
    /// from it (before that, the host's order packing was used).
    func testColumnsChangeReordersWhenTableBecomesApplicable() throws {
        let cells: [AnyHashable: TesseraTileGridPlacement] = [
            "a": tesseraCell(0, 0), "b": tesseraCell(0, 1), "c": tesseraCell(1, 0),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot([small("c"), small("b"), small("a")], cells: cells, columns: 6),
            columns: 4
        )
        XCTAssertEqual(host.grid.items.map { $0.id }, ["c", "b", "a"] as [AnyHashable], "the width did not match")

        host.grid.columns = 6
        host.layout()
        XCTAssertEqual(host.grid.items.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["a", "b", "c"] as [AnyHashable])
        try assertFramesFollowReadingOrder(host)
    }

    // MARK: - RTL

    /// RTL: columns are logical, the order is the same (column 0 is on the right), and the frames run
    /// right to left.
    func testRightToLeftOrderUsesLogicalColumns() throws {
        let cells: [AnyHashable: TesseraTileGridPlacement] = [
            "a": tesseraCell(0, 0), "b": tesseraCell(0, 3), "c": tesseraCell(1, 2), "d": tesseraCell(2, 0),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot([small("d"), small("c"), small("b"), small("a")], cells: cells)
        )
        host.grid.semanticContentAttribute = .forceRightToLeft
        host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.grid.reload(snapshot: snapshot([small("d"), small("c"), small("b"), small("a")], cells: cells))
        host.layout()

        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["a", "b", "c", "d"] as [AnyHashable])
        let aFrame = try XCTUnwrap(host.grid.frame(forItemID: "a"))
        let bFrame = try XCTUnwrap(host.grid.frame(forItemID: "b"))
        XCTAssertGreaterThan(aFrame.midX, bFrame.midX, "column 0 is at the right edge")
        try assertFramesFollowReadingOrder(host, rightToLeft: true)
    }

    // MARK: - Opened folder panel

    /// The panel comes right after the last element of the folder band (in reading
    /// order), tiles below are read after it; the folder's tiles are read inside
    /// the panel, that is, after the folder tile.
    func testFolderPanelFollowsBandAndKeepsOrder() throws {
        let folder = TesseraTileFolder(
            id: "f",
            title: "Work",
            tiles: ["x1", "x2", "x3"].map { tesseraTestTile($0, size: .small) },
            size: .medium
        )
        let cells: [AnyHashable: TesseraTileGridPlacement] = [
            "f": tesseraCell(0, 0), "s1": tesseraCell(0, 2), "s3": tesseraCell(0, 3),
            "s2": tesseraCell(1, 2), "x": tesseraCell(2, 0), "y": tesseraCell(2, 1),
        ]
        let host = TesseraTestWindowedGrid(
            snapshot: snapshot(
                [small("y"), small("x"), small("s2"), small("s3"), small("s1"), .folder(folder)],
                cells: cells
            )
        )
        host.grid.openFolder(folder, animated: false)
        host.layout()

        let display = host.grid.displayItems
        XCTAssertEqual(
            display.map { $0.isFolderPanel ? "panel" : "\($0.id)" },
            ["f", "s1", "s3", "s2", "panel", "x", "y"]
        )
        XCTAssertEqual(host.grid.items.count, 6, "the snapshot has no panel")
        try assertFramesFollowReadingOrder(host)

        let panel = try XCTUnwrap(host.panelCell(folderID: "f"))
        panel.layoutIfNeeded()
        XCTAssertEqual(
            panel.shortcutCells.compactMap { $0.accessibilityLabel },
            ["x1", "x2", "x3"],
            "the folder's tiles are read in the folder's order"
        )
    }

    // MARK: - TesseraTileStore: snapshot order by cells

    private func makeStore(
        catalog: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(catalog)
        return store
    }

    private func write(_ document: [String: Any], to store: TesseraTileStore, in directory: TesseraTestDirectory) throws {
        try directory.create()
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: store.fileURL)
    }

    /// The snapshot order matches the reading order of the cells for a given width.
    private func assertSnapshotIsReadingOrdered(
        _ store: TesseraTileStore,
        columns: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cells = store.placements(forColumns: columns)
        let expected = cells
            .sorted { TesseraTileGridPlacement.isReadingOrdered($0.value, before: $1.value) }
            .map { $0.key }
        XCTAssertEqual(
            store.snapshot(columns: columns).items.map { $0.id }, expected,
            "snapshot(columns:) goes in the cells' reading order", file: file, line: line
        )
        XCTAssertEqual(
            store.placementReadingOrder(forColumns: columns), expected,
            file: file, line: line
        )
    }

    /// A version 2 file whose items are written not in reading order: after
    /// `load()` the snapshot follows the cells, not the file order.
    func testStoreSnapshotAfterLoadOfUnorderedFileFollowsCells() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(catalog: ["a", "b", "c"].map { tesseraTestTile($0, size: .small) }, in: directory)
        try write(
            [
                "version": 2,
                "columns": 4,
                "items": [
                    ["kind": "tile", "key": "s:c", "row": 1, "column": 0],
                    ["kind": "tile", "key": "s:a", "row": 0, "column": 2],
                    ["kind": "tile", "key": "s:b", "row": 0, "column": 0],
                ],
                "sizes": ["s:a": "small", "s:b": "small", "s:c": "small"],
                "folders": [],
            ],
            to: store,
            in: directory
        )
        try store.load()

        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["b", "a", "c"] as [AnyHashable])
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["b", "a", "c"] as [AnyHashable])
        assertSnapshotIsReadingOrdered(store, columns: 4)

        // A grid built from such a snapshot shows the same order.
        let host = TesseraTestWindowedGrid(snapshot: store.snapshot(columns: 4))
        XCTAssertEqual(host.grid.items.map { $0.id }, ["b", "a", "c"] as [AnyHashable])
    }

    /// v1 → v2 migration: `packCompact` fills the hole to the right of a medium tile
    /// with a later small one, and the reading order diverges from the v1 file order — the snapshot
    /// follows the cells.
    func testStoreSnapshotAfterV1MigrationFollowsCells() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(
            catalog: [
                tesseraTestTile("m", size: .medium),
                tesseraTestTile("w", size: .wide),
                tesseraTestTile("s", size: .small),
            ],
            in: directory
        )
        try write(
            [
                "version": 1,
                "items": [
                    ["kind": "tile", "key": "s:m"],
                    ["kind": "tile", "key": "s:w"],
                    ["kind": "tile", "key": "s:s"],
                ],
                "sizes": ["s:m": "medium", "s:w": "wide", "s:s": "small"],
                "folders": [],
            ],
            to: store,
            in: directory
        )
        try store.load()
        XCTAssertTrue(store.placeItems(columns: 4))

        XCTAssertEqual(store.placement(of: "s"), tesseraCell(0, 2), "the small tile took the hole above the wide one")
        XCTAssertEqual(store.placement(of: "w"), tesseraCell(2, 0))
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["m", "s", "w"] as [AnyHashable])
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["m", "s", "w"] as [AnyHashable])
        assertSnapshotIsReadingOrdered(store, columns: 4)
    }

    /// Projection to another width (D32): the snapshot for the host width follows the cells of the
    /// projection, for the canvas width — the stored ones; the file is not rewritten.
    func testStoreSnapshotForOtherWidthFollowsProjectedCells() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: 6,
            tiles: [
                CellFixtureTile("m", .medium, 0, 0),
                CellFixtureTile("w", .wide, 0, 2),
                CellFixtureTile("s", .small, 2, 0),
            ],
            in: directory
        )
        let stored = try Data(contentsOf: store.fileURL)

        XCTAssertEqual(store.snapshot(columns: 6).items.map { $0.id }, ["m", "w", "s"] as [AnyHashable])
        XCTAssertEqual(
            store.snapshot(columns: 4).items.map { $0.id }, ["m", "s", "w"] as [AnyHashable],
            "in the 4-column projection the small tile sits to the right of the medium one, the wide one below"
        )
        assertSnapshotIsReadingOrdered(store, columns: 6)
        assertSnapshotIsReadingOrdered(store, columns: 4)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), stored, "a projection does not write the file")

        // A host grid with 4 columns receives the projection table and the same order.
        let host = TesseraTestWindowedGrid(snapshot: store.snapshot(columns: 4), columns: 4)
        XCTAssertEqual(host.grid.displayItems.map { $0.id }, ["m", "s", "w"] as [AnyHashable])
        try assertFramesFollowReadingOrder(host)
    }

    /// `setCatalog`: a tile that returns to the catalog at its former place above
    /// the others lands in reading order, not at the end of the model order.
    func testStoreSnapshotAfterSetCatalogFollowsCells() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(catalog: [tesseraTestTile("a", size: .small)], in: directory)
        try write(
            [
                "version": 2,
                "columns": 4,
                "items": [
                    ["kind": "tile", "key": "s:a", "row": 0, "column": 1],
                    ["kind": "tile", "key": "s:g", "row": 0, "column": 0],
                ],
                "sizes": ["s:a": "small", "s:g": "small"],
                "folders": [],
            ],
            to: store,
            in: directory
        )
        try store.load()
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["a"] as [AnyHashable], "g is not in the catalog")

        store.setCatalog([tesseraTestTile("a", size: .small), tesseraTestTile("g", size: .small)])
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["g", "a"] as [AnyHashable])
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["g", "a"] as [AnyHashable])
        assertSnapshotIsReadingOrdered(store, columns: 4)
    }

    /// Folders are top-level items on a par with tiles: the order follows the folder's
    /// cells, not its number in the catalog.
    func testStoreSnapshotOrdersFoldersLikeTiles() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: 4,
            tiles: [CellFixtureTile("a", .small, 0, 2), CellFixtureTile("z", .small, 3, 0)],
            folders: [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])],
            in: directory
        )
        XCTAssertEqual(store.snapshot(columns: 4).items.map { $0.id }, ["f", "a", "z"] as [AnyHashable])
    }

    // MARK: - Focus after edit operations (.layoutChanged)

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func record(_ host: TesseraTestDragHost) -> PostRecorder {
        let recorder = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            recorder.posts.append((notification, argument))
        }
        return recorder
    }

    /// A layout with holes: a(0,0), b(0,3), c(4,0); the rest is empty.
    private func makeHoleHost() throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 3),
                CellFixtureTile("c", .small, 4, 0),
            ]
        )
    }

    private func assertFocus(
        _ recorder: PostRecorder,
        on view: UIView?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(recorder.posts.last?.0, UIAccessibility.Notification.layoutChanged, file: file, line: line)
        XCTAssertNotNil(view, "the target cell exists: \(message)", file: file, line: line)
        XCTAssertTrue((recorder.posts.last?.1 as? UIView) === view, message, file: file, line: line)
    }

    /// Unpin: focus goes to the next one in reading order, even if an empty cell is left
    /// where the removed tile was.
    func testFocusAfterUnpinGoesToNextInReadingOrder() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty }, "the notification is posted")
        XCTAssertFalse(host.store.isPinned("a"))
        assertFocus(recorder, on: host.host.cell("b"), "the one after a is b")

        // In the middle: b is removed — c follows, although five empty rows lie between them.
        let middle = try makeHoleHost()
        let middleRecorder = record(middle)
        middle.coordinator.unpin("b")
        XCTAssertTrue(middle.waitUntil { !middleRecorder.posts.isEmpty })
        assertFocus(middleRecorder, on: middle.host.cell("c"), "the one after b is c")
    }

    /// Unpin of the last item: focus goes to the previous one.
    func testFocusAfterUnpinOfLastGoesToPrevious() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        host.coordinator.unpin("c")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertFalse(host.store.isPinned("c"))
        assertFocus(recorder, on: host.host.cell("b"), "after the last one — the previous")
    }

    /// Unpin of the only item: nothing is left on the grid, focus goes to the grid itself.
    func testFocusAfterUnpinOfOnlyItemGoesToGrid() throws {
        let host = try TesseraTestDragHost(cells: [CellFixtureTile("a", .small, 0, 0)])
        let recorder = record(host)

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertTrue(host.gridIDs.isEmpty)
        XCTAssertEqual(recorder.posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue((recorder.posts.last?.1 as? UIView) === host.host.grid, "focus is on the grid itself")
    }

    /// Unpin of a tile that is not on the grid (it lies in a two-tile folder): the folder
    /// is dissolved (D45), focus goes to the remaining tile that became a grid item
    /// (it used to go to the last grid item); it does not go to a nonexistent tile.
    func testFocusAfterUnpinOfTileInsideFolderGoesToRemainingTile() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("z", .small, 3, 0)],
            folders: [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        )
        let recorder = record(host)

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertFalse(host.store.isPinned("x"))
        assertFocus(recorder, on: host.host.cell("y"), "the remaining tile in place of the dissolved folder")
    }

    /// Resize: focus goes to the changed tile, and it stays on its cell
    /// (holes do not collapse).
    func testFocusAfterResizeStaysOnResizedTile() throws {
        let host = try makeHoleHost()
        let recorder = record(host)
        // In the full cycle (D28) the order is small → wide → medium; the test checks growth to 2×2 in place,
        // so the host narrows the set to small/medium (the former small → medium step).
        host.coordinator.supportedSizesProvider = { _ in [.small, .medium] }

        host.coordinator.beginEditing()
        XCTAssertEqual(host.coordinator.cycleSize(of: "b"), .medium)
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        assertFocus(recorder, on: host.host.cell("b"), "focus on b")
        XCTAssertEqual(host.store.placement(of: "b"), tesseraCell(0, 2), "growth shifted the column left, the cell stays")
        host.coordinator.endEditing()
    }

    /// A drop into a hole: focus goes to the tile that moved; the snapshot order is the
    /// reading order of the new cells.
    func testFocusAfterMoveIntoHoleGoesToMovedTile() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        XCTAssertTrue(host.coordinator.move("c", toCell: tesseraCell(0, 1)))
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertEqual(host.store.placement(of: "c"), tesseraCell(0, 1))
        XCTAssertEqual(host.gridIDs, ["a", "c", "b"] as [AnyHashable], "the order follows the cells")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        assertFocus(recorder, on: host.host.cell("c"), "focus on c")
    }

    /// Merging into a folder: focus goes to the created folder; adding to an existing one —
    /// to the target folder.
    func testFocusAfterMergeIntoFolderGoesToFolder() throws {
        let host = try makeHoleHost()
        let recorder = record(host)

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "b"))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        assertFocus(recorder, on: host.host.cell(folder.id), "focus on the created folder")

        recorder.posts.removeAll()
        XCTAssertTrue(host.coordinator.addToFolder("a", folderID: folder.id))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        assertFocus(recorder, on: host.host.cell(folder.id), "focus on the target folder")
    }

    /// Take-out from a folder: focus goes to the tile taken out (it is on the grid).
    func testFocusAfterExtractFromFolderGoesToTile() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("z", .small, 3, 0)],
            folders: [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        )
        let recorder = record(host)

        XCTAssertTrue(host.coordinator.moveBetweenFolders("y", to: nil))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !recorder.posts.isEmpty })
        XCTAssertTrue(host.gridIDs.contains("y"))
        assertFocus(recorder, on: host.host.cell("y"), "focus on the tile taken out")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
    }

    // MARK: - Custom actions on the new operations

    /// "Unpin" and "Change size" work by cells: unpinning leaves
    /// a hole (neighbors do not move), and the size changes in place.
    func testCustomActionsUnpinAndResizeUseCellOperations() throws {
        let host = try makeHoleHost()
        let recorder = record(host)
        // In the D28 cycle the small/medium set keeps the former small → medium step
        // (in the full cycle small is followed by wide); the test is about cell operations.
        host.coordinator.supportedSizesProvider = { _ in [.small, .medium] }
        host.coordinator.beginEditing()

        func action(_ name: String, in id: AnyHashable) -> UIAccessibilityCustomAction? {
            host.host.cell(id)?.accessibilityCustomActions?.first { $0.name == name }
        }
        let resizeName = TesseraStartScreenStrings.string(.a11yActionResize)
        let unpinName = TesseraStartScreenStrings.string(.a11yActionUnpin)
        XCTAssertTrue(host.waitUntil { action(resizeName, in: "a") != nil && action(unpinName, in: "b") != nil })

        let resize = try XCTUnwrap(action(resizeName, in: "a"))
        XCTAssertEqual(resize.actionHandler?(resize), true)
        let resizedA = host.store.snapshot().items.first { $0.id == AnyHashable("a") }
        XCTAssertEqual(resizedA?.size, .medium)
        XCTAssertEqual(host.store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertEqual(host.store.placement(of: "b"), tesseraCell(0, 3), "the neighbor stays on its cell")

        let unpin = try XCTUnwrap(action(unpinName, in: "b"))
        XCTAssertEqual(unpin.actionHandler?(unpin), true)
        XCTAssertTrue(host.waitUntil { !host.store.isPinned("b") })
        XCTAssertEqual(host.store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertEqual(host.store.placement(of: "c"), tesseraCell(2, 0), "empty rows collapsed, the order is preserved")
        XCTAssertTrue(host.waitUntil { recorder.posts.contains { ($0.1 as? UIView) === host.host.cell("c") } },
                      "after unpinning, focus goes to the next one in reading order")
        host.coordinator.endEditing()
    }
}

#endif
