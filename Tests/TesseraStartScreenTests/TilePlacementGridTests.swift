//
//  TilePlacementGridTests.swift
//  TesseraStartScreenTests
//
//  A grid with a snapshot carrying a table of explicit cells (D30). Design
//  document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid" and "Implementation
//  deviations"; decisions D30–D33 in docs/STATE.md.
//
//  `TesseraTileGridView` is checked:
//  - `baseContentFrames(for:placementTable:)` takes slots from the same source
//    as the layout: the frames match what the grid draws, for a snapshot with
//    holes, when falling back to packing, and in RTL;
//  - expanding a folder on a snapshot with holes: the panel index is computed from cells, and rows
//    below the band shift without repacking;
//  - snapshot diff: a change of cells only (the same items in the same order) is
//    a layout change and is animated as a reorder; the same snapshot does not change
//    frames;
//  - `TesseraTileStore.snapshot(columns:)` for a different grid width is ignored (packing
//    frames); equality of grid frames and model cells after operations is checked in
//    `TileCellWiringTests` (operations now leave holes, so the former
//    "table = packing" comparison lost its meaning);
//  - magnet centers without a table stay on order-based packing.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePlacementGridTests: XCTestCase {

    // MARK: - Helpers

    private func cell(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    private func small(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .small)) }
    private func medium(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .medium)) }

    private func layoutGrid(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    private func makeGrid(
        columns: Int = 4,
        width: CGFloat = 390,
        rightToLeft: Bool = false
    ) -> TesseraTileGridView {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        grid.columns = columns
        if rightToLeft {
            grid.semanticContentAttribute = .forceRightToLeft
            grid.subviews
                .compactMap { $0 as? UICollectionView }
                .forEach { $0.semanticContentAttribute = .forceRightToLeft }
        }
        return grid
    }

    /// A snapshot with holes: a and b in the first row with a gap, c below and to the right.
    private func holeSnapshot(columns: Int = 4) -> TesseraTileGridSnapshot {
        TesseraTileGridSnapshot(
            items: [small("a"), small("b"), medium("c")],
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(
                cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(3, 1)],
                columns: columns
            )
        )
    }

    private func assertClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 0.01, "\(message): x", file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 0.01, "\(message): y", file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.01, "\(message): w", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 0.01, "\(message): h", file: file, line: line)
    }

    /// Grid frames by identifier (grid coordinates).
    private func gridFrames(_ grid: TesseraTileGridView, ids: [AnyHashable]) throws -> [AnyHashable: CGRect] {
        var result: [AnyHashable: CGRect] = [:]
        for id in ids { result[id] = try XCTUnwrap(grid.frame(forItemID: id), "frame \(id)") }
        return result
    }

    // MARK: - baseContentFrames

    /// Base layout frames match what the grid draws, for a snapshot with
    /// holes; without a table they are the previous ones (packing), which is a different picture.
    func testBaseContentFramesMatchLayoutForSnapshotWithHoles() throws {
        let grid = makeGrid()
        let snapshot = holeSnapshot()
        grid.reload(snapshot: snapshot)
        layoutGrid(grid)

        let ids = snapshot.items.map { $0.id }
        let drawn = try gridFrames(grid, ids: ids)
        let base = try XCTUnwrap(grid.baseContentFrames(for: snapshot.items, placementTable: snapshot.placementTable))
        for id in ids {
            assertClose(grid.gridFrame(fromContentFrame: try XCTUnwrap(base[id])), try XCTUnwrap(drawn[id]), "\(id)")
        }

        // Without a table, order-based packing: c moves up next to a and b.
        let packed = try XCTUnwrap(grid.baseContentFrames(for: snapshot.items))
        XCTAssertLessThan(try XCTUnwrap(packed["c"]).minY, try XCTUnwrap(base["c"]).minY)
    }

    /// An invalid table: both the grid's and the base layout's frames are order-based packing.
    func testInvalidTableFallsBackInGridAndBaseFrames() throws {
        let items: [TesseraTileGridItem] = [small("a"), small("b"), medium("c")]
        let broken = TesseraTileGridPlacementTable(
            cells: ["a": cell(0, 0), "b": cell(0, 0), "c": cell(3, 1)],
            columns: 4
        )

        let reference = makeGrid()
        reference.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layoutGrid(reference)

        let grid = makeGrid()
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: [], placementTable: broken))
        layoutGrid(grid)

        let base = try XCTUnwrap(grid.baseContentFrames(for: items, placementTable: broken))
        for item in items {
            assertClose(
                try XCTUnwrap(grid.frame(forItemID: item.id)),
                try XCTUnwrap(reference.frame(forItemID: item.id)),
                "grid \(item.id)"
            )
            assertClose(
                grid.gridFrame(fromContentFrame: try XCTUnwrap(base[item.id])),
                try XCTUnwrap(reference.frame(forItemID: item.id)),
                "base layout \(item.id)"
            )
        }
    }

    /// RTL: base frames with holes match the mirrored grid layout.
    func testBaseContentFramesMatchLayoutInRightToLeft() throws {
        let grid = makeGrid(rightToLeft: true)
        let snapshot = holeSnapshot()
        grid.reload(snapshot: snapshot)
        layoutGrid(grid)

        let base = try XCTUnwrap(grid.baseContentFrames(for: snapshot.items, placementTable: snapshot.placementTable))
        for item in snapshot.items {
            assertClose(
                grid.gridFrame(fromContentFrame: try XCTUnwrap(base[item.id])),
                try XCTUnwrap(grid.frame(forItemID: item.id)),
                "\(item.id)"
            )
        }
        // Logical column 0 in RTL is the right one: a is to the right of b.
        XCTAssertGreaterThan(try XCTUnwrap(base["a"]).minX, try XCTUnwrap(base["b"]).minX)
    }

    // MARK: - Folder expansion

    /// Expanding a folder on a snapshot with holes: the panel index is by cells, rows
    /// below the band are shifted by the panel without repacking; the magnet with an open folder
    /// is still empty.
    func testOpeningFolderKeepsHolesBelowBand() throws {
        let folder = tesseraTestFolder("f", tileCount: 6)
        let items: [TesseraTileGridItem] = [.folder(folder), small("s"), small("x"), small("y")]
        let table = TesseraTileGridPlacementTable(
            cells: ["f": cell(0, 0), "s": cell(0, 2), "x": cell(5, 0), "y": cell(8, 3)],
            columns: 4
        )
        let grid = makeGrid()
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: [], placementTable: table))
        layoutGrid(grid)

        let closedX = try XCTUnwrap(grid.frame(forItemID: "x"))
        let closedY = try XCTUnwrap(grid.frame(forItemID: "y"))

        grid.openFolder(folder, animated: false)
        layoutGrid(grid)

        // The panel goes after s (the last band tile), before x and y.
        let panelIndex = try XCTUnwrap(grid.displayItems.firstIndex { $0.isFolderPanel })
        XCTAssertEqual(
            panelIndex,
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: items.map { TesseraTilePlacedItem(id: $0.id, size: $0.size, cell: table.cells[$0.id]!) },
                columns: 4,
                expandedFolderID: folder.id
            )
        )
        XCTAssertEqual(panelIndex, 2)

        let openX = try XCTUnwrap(grid.frame(forItemID: "x"))
        let openY = try XCTUnwrap(grid.frame(forItemID: "y"))
        XCTAssertEqual(openX.minY - closedX.minY, openY.minY - closedY.minY, accuracy: 0.01, "both are shifted equally")
        XCTAssertGreaterThan(openX.minY - closedX.minY, 0, "shifted down by the panel")
        XCTAssertEqual(openY.minY - openX.minY, closedY.minY - closedX.minY, accuracy: 0.01, "the hole between x and y is preserved")
        XCTAssertTrue(grid.magnetSlotCenters(for: .small).isEmpty, "the magnet is empty with an open folder")

        grid.closeFolder(animated: false)
        layoutGrid(grid)
        assertClose(try XCTUnwrap(grid.frame(forItemID: "x")), closedX, "x came back")
        assertClose(try XCTUnwrap(grid.frame(forItemID: "y")), closedY, "y came back")
    }

    // MARK: - Snapshot diff

    /// A change of cells only (the same items in the same order) is a layout
    /// change: it takes the "same composition" branch with a batch animation (not a crossfade and
    /// not instant) and arrives at the new frames.
    func testCellOnlyChangeIsDetectedAndAnimatesLikeReorder() throws {
        let host = TesseraTestWindowedGrid(columns: 4)
        host.grid.isReduceMotionEnabled = { false }
        host.grid.reload(snapshot: holeSnapshot())
        host.layout()

        let beforeC = try XCTUnwrap(host.grid.frame(forItemID: "c"))
        let beforeA = try XCTUnwrap(host.grid.frame(forItemID: "a"))

        let moved = TesseraTileGridSnapshot(
            items: holeSnapshot().items,
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(
                cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(6, 0)],
                columns: 4
            )
        )
        host.grid.update(snapshot: moved, animated: true)

        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade, "a move, not a crossfade")
        XCTAssertFalse(host.grid.didApplyLastSnapshotWithoutAnimation, "the move is animated")

        let arrived = host.waitUntil(timeout: 3) {
            guard let frame = host.grid.frame(forItemID: "c") else { return false }
            return frame.minY > beforeC.minY + 1
        }
        XCTAssertTrue(arrived, "c arrived at the new cell")
        host.layout()
        let afterC = try XCTUnwrap(host.grid.frame(forItemID: "c"))
        XCTAssertGreaterThan(afterC.minY, beforeC.minY)
        XCTAssertEqual(afterC.minX, try XCTUnwrap(host.grid.baseContentFrames(for: moved.items, placementTable: moved.placementTable)?["c"]).minX, accuracy: 0.01)
        assertClose(try XCTUnwrap(host.grid.frame(forItemID: "a")), beforeA, "a did not move")
    }

    /// The same snapshot does not change frames: neither with an animated nor with a
    /// non-animated application.
    func testUnchangedSnapshotDoesNotMoveAnything() throws {
        let host = TesseraTestWindowedGrid(columns: 4)
        host.grid.isReduceMotionEnabled = { false }
        let snapshot = holeSnapshot()
        host.grid.reload(snapshot: snapshot)
        host.layout()
        let ids = snapshot.items.map { $0.id }
        let before = try gridFrames(host.grid, ids: ids)

        host.grid.update(snapshot: snapshot, animated: true)
        host.spin(0.5)
        host.layout()
        host.grid.update(snapshot: snapshot, animated: false)
        host.layout()

        let after = try gridFrames(host.grid, ids: ids)
        for id in ids {
            assertClose(try XCTUnwrap(after[id]), try XCTUnwrap(before[id]), "\(id)")
        }
    }

    /// A non-animated change of cells is applied immediately (`reload`): the frames are new
    /// without waiting for an animation.
    func testCellOnlyChangeAppliesImmediatelyWithoutAnimation() throws {
        let grid = makeGrid()
        grid.reload(snapshot: holeSnapshot())
        layoutGrid(grid)
        let before = try XCTUnwrap(grid.frame(forItemID: "c"))

        grid.reload(snapshot: TesseraTileGridSnapshot(
            items: holeSnapshot().items,
            unpinned: [],
            placementTable: TesseraTileGridPlacementTable(
                cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(5, 1)],
                columns: 4
            )
        ))
        layoutGrid(grid)
        XCTAssertGreaterThan(try XCTUnwrap(grid.frame(forItemID: "c")).minY, before.minY)
    }

    // MARK: - Magnet

    /// `magnetSlotCenters` on a snapshot without a table stays on order-based
    /// packing (the fallback): a snapshot with holes passed without a table does not
    /// break it. `baseInsertionIndex` (the order-based insertion position) was removed.
    func testMagnetStaysPackBasedOnSnapshotWithoutTable() throws {
        let grid = makeGrid()
        let snapshot = holeSnapshot()
        grid.reload(snapshot: snapshot)
        layoutGrid(grid)

        XCTAssertFalse(grid.magnetSlotCenters(for: .small).isEmpty)
    }

    // MARK: - Store snapshot

    /// A random catalog: tiles of different sizes (small ones more often).
    private func randomCatalog(seed: UInt64, count: Int) -> [TesseraTileDescriptor] {
        var generator = TesseraTestSeededGenerator(seed: seed)
        let sizes: [TesseraTileSize] = [.small, .small, .medium, .medium, .wide, .large]
        return (0..<count).map { index in
            tesseraTestTile("t\(index)", size: sizes[generator.int(upperBound: sizes.count)])
        }
    }

    /// A table for a different grid width is ignored: the frames are the previous ones.
    func testStoreSnapshotForOtherWidthFallsBackToPack() throws {
        let directory = TesseraTestDirectory()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(randomCatalog(seed: 5, count: 12))
        store.placeItems(columns: 6)

        let legacy = makeGrid(columns: 4)
        legacy.reload(snapshot: store.snapshot())
        layoutGrid(legacy)

        let grid = makeGrid(columns: 4)
        grid.reload(snapshot: store.snapshot(columns: 6))
        layoutGrid(grid)

        for item in store.snapshot().items {
            assertClose(
                try XCTUnwrap(grid.frame(forItemID: item.id)),
                try XCTUnwrap(legacy.frame(forItemID: item.id)),
                "\(item.id)"
            )
        }
        XCTAssertNil(store.snapshot(columns: 0).placementTable)
    }
}

#endif
