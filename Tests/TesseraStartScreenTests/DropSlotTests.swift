//
//  DropSlotTests.swift
//  TesseraStartScreenTests
//
//  Drop position: the cell under the finger.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid",
//  §5 "Drag: position over an empty spot" and "Drag targets: the cell
//  under the finger" (D21, D31, D33).
//
//  Observation: a tile taken out of a folder panel used to "fall into the first free
//  spot", so the position could not be chosen. Over an empty spot the target was first
//  an order slot (`HoverTarget.slot`) and is now the cell under the finger
//  (`HoverTarget.cell`): the item lands **exactly in that cell**, holes
//  are preserved, interfering tiles are pushed down (D31), and below the tiles
//  the target is "new row" (`HoverTarget.newRow`). The preview follows the finger (the same
//  items on other cells), and the drop puts the item where the
//  preview showed it.
//
//  Verified on real cells and a real `TesseraTileStore` in a window
//  (`TesseraTestDragHost`), without `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class DropSlotTests: XCTestCase {

    // MARK: - Helpers

    /// A delegate that catches only `didMove(toFolder:atCell:)` and `didMove(toCell:)`.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Take-out/move: the tile, the target folder and the actual cell.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?, cell: TesseraTileGridPlacement?)] = []

        /// Reorder on the grid: the tile and the actual cell.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TesseraTileGridPlacement?
        ) {
            folderMoves.append((tileID, folderID, cell))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toCell cell: TesseraTileGridPlacement
        ) {
            moves.append((tileID, cell))
        }
    }

    /// Test rig: the `plain` tiles (in reading order); folder "F" with tiles
    /// `folderTiles` (small) sits in the order at position `folderAt`.
    ///
    /// The layout is compact, as order-based operations produced it before explicit cells
    /// (`TesseraTestDragHost(packed:)`); the folder is small.
    private func makeHost(
        plain: [(String, TesseraTileSize)],
        folderTiles: [String],
        folderAt: Int,
        columns: Int = 4
    ) throws -> TesseraTestDragHost {
        var entries: [TesseraTestPackedEntry] = plain.map { .tile($0.0, $0.1) }
        entries.insert(.folder("F", .small, folderTiles.map { ($0, TesseraTileSize.small) }), at: min(folderAt, entries.count))
        return try TesseraTestDragHost(packed: entries, columns: columns)
    }

    /// Enters edit mode, expands the folder panel and grabs the panel icon.
    private func startPanelDrag(
        _ host: TesseraTestDragHost,
        iconIndex: Int
    ) throws -> AnyHashable {
        let folderID = try XCTUnwrap(host.firstFolderID)
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        // Enter take-out right away (a long press on the panel starts a reorder).
        host.coordinator.startDragFromPanel(at: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
        return folderID
    }

    /// Geometry of the small-tile grid before the drag: origin (0, 0), unit and cell step.
    private struct Cells {
        let origin: CGPoint
        let unit: CGFloat
        let pitch: CGFloat

        /// A point in a cell (column, row); `fx`/`fy` are the fraction of the cell.
        func point(column: Int, row: Int, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(column) * pitch + unit * fx,
                y: origin.y + CGFloat(row) * pitch + unit * fy
            )
        }
    }

    /// Cells of two adjacent small tiles in the first row (before the drag).
    private func cells(_ host: TesseraTestDragHost, first: AnyHashable, second: AnyHashable) throws -> Cells {
        let a = try XCTUnwrap(host.host.grid.frame(forItemID: first))
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: second))
        return Cells(origin: a.origin, unit: a.width, pitch: b.minX - a.minX)
    }

    /// Waits until the grid catches up with the model after the drop and the snapshot goes away.
    private func settle(_ host: TesseraTestDragHost, _ id: AnyHashable) {
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "Grid = model")
        XCTAssertTrue(host.waitForDragCleanup(id))
        XCTAssertNil(host.coordinator.dragSession)
    }

    // MARK: - Drag from the panel

    /// Order "a F b c d" (4 columns): row 0 is a F b c, row 1 is d. A tile from the
    /// panel is dropped to the right of "d" (empty cell (1, 3)): it lands **exactly in that
    /// cell**, the one the preview showed, not "after the folder".
    func testPanelDropRightOfLastTileLandsAtEnd() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        XCTAssertEqual(host.storeIDs.count, 5)
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let folderID = try startPanelDrag(host, iconIndex: 2)

        // Displayed snapshot: the tile follows the folder in snapshot order, and on the grid it is on
        // the free cell after the folder. The finger is on the empty cell (column 3,
        // row 1), to the right of "d"; there is nothing there in the base layout either.
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TesseraTileGridPlacement(row: 1, column: 3)),
            "The target is the cell under the finger"
        )
        XCTAssertEqual(
            host.gridIDs,
            ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable],
            "Snapshot order is the reading order of the preview cells: 'f3' on cell (1, 3) comes after 'd'"
        )
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        let dFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "d"))
        XCTAssertEqual(previewFrame.minY, dFrame.minY, accuracy: 0.5, "The preview is in the row of 'd', right after it")
        XCTAssertGreaterThan(previewFrame.minX, dFrame.maxX)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")

        XCTAssertEqual(host.storeIDs, ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "f3"), TesseraTileGridPlacement(row: 1, column: 3))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
        XCTAssertEqual(recorder.folderMoves.count, 1)
        XCTAssertEqual(recorder.folderMoves.first?.cell, TesseraTileGridPlacement(row: 1, column: 3))
        let landed = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        XCTAssertEqual(landed, previewFrame, "The tile landed exactly where the preview showed it")
    }

    /// The finger is in the gap between cells (not over a tile itself): the gap belongs to the
    /// cell on the left, which is the edge of the occupied cell "d", so the take-out lands on cell
    /// "d" and "d" is pushed down (D31), not "right after the folder".
    func testPanelDropBetweenTwoTilesInGapInsertsBetween() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)

        // Base layout: row 0 is a F b c, row 1 is d (1, 0), f3 (1, 1). The gap
        // between cells (1, 0) and (1, 1) is the tail of cell "d".
        let gap = CGPoint(
            x: grid.origin.x + grid.pitch - (grid.pitch - grid.unit) / 2,
            y: grid.point(column: 0, row: 1).y
        )
        host.coordinator.updateDrag(to: gap)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TesseraTileGridPlacement(row: 1, column: 0)),
            "The gap is the edge of cell 'd': cell 'd'"
        )

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")
        XCTAssertEqual(host.storeIDs, ["a", folderID, "b", "c", "f3", "d"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "f3"), TesseraTileGridPlacement(row: 1, column: 0))
        XCTAssertEqual(host.store.placement(of: "d"), TesseraTileGridPlacement(row: 2, column: 0), "'d' pushed down")
    }

    /// The finger is left of/above the first cell (the top margin zone): the tile lands on the first
    /// cell "a" (0, 0), and "a" is pushed down (D31).
    func testPanelDropAboveFirstRowLandsAtStart() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        host.host.grid.contentInsets = UIEdgeInsets(top: 60, left: 16, bottom: 0, right: 16)
        host.host.layout()
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)

        host.coordinator.updateDrag(to: CGPoint(x: grid.origin.x + 4, y: grid.origin.y - 30))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TesseraTileGridPlacement(row: 0, column: 0)),
            "Above the margins the row is clamped to 0: the edge of cell 'a'"
        )

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")
        XCTAssertEqual(host.store.placement(of: "f3"), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(host.store.placement(of: "a"), TesseraTileGridPlacement(row: 1, column: 0), "'a' pushed down")
        XCTAssertEqual(
            host.storeIDs,
            ["f3", folderID, "b", "c", "a", "d"] as [AnyHashable],
            "Model order is the cell reading order"
        )
        let landed = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        let aFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        XCTAssertLessThan(landed.minY, aFrame.minY, "The tile is the first cell of the first row, 'a' is below")
    }

    /// The empty area below the tiles (the finger is below the last row): the target is "new
    /// row", and the tile lands at the start of a new row at the end of the canvas.
    func testPanelDropBelowAllTilesLandsAtEnd() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let folderID = try startPanelDrag(host, iconIndex: 0)
        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 30))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")
        XCTAssertEqual(host.store.placement(of: "f1"), TesseraTileGridPlacement(row: 2, column: 0), "New row after the row of 'd'")
        XCTAssertEqual(host.storeIDs.last, AnyHashable("f1"))
        XCTAssertEqual(host.storeIDs.first, AnyHashable("a"))
        XCTAssertTrue(host.storeIDs.contains(folderID))
    }

    /// A hole in the layout: "m" (2×2), folder F and "s" to its right, a free 2×1
    /// area below them, "w" (wide) lower. The finger is on the free cell (1, 3): a tile from the
    /// panel lands **exactly in it** (the cell under the finger, not the nearest
    /// order slot); the drop puts it where the preview showed it.
    func testPanelDropIntoHoleLandsInNearestReachableCell() throws {
        let host = try makeHost(
            plain: [("m", .medium), ("s", .small), ("w", .wide)],
            folderTiles: ["f1", "f2"],
            folderAt: 1
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folderCell = try XCTUnwrap(host.store.placement(of: folderID))
        XCTAssertEqual(host.storeIDs, ["m", folderID, "s", "w"] as [AnyHashable])
        // Cells of the small tiles: F is (0, 2), s is (0, 3).
        let grid = try cells(host, first: folderID, second: "s")
        let origin = try XCTUnwrap(host.host.grid.frame(forItemID: "m")).origin
        let cell = Cells(origin: origin, unit: grid.unit, pitch: grid.pitch)

        _ = try startPanelDrag(host, iconIndex: 1)
        // Snapshot base layout: m, F (0,2), f2 (0,3), s (1,2); (1,3) is free.

        host.coordinator.updateDrag(to: cell.point(column: 3, row: 1, fx: 0.1))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(TesseraTileGridPlacement(row: 1, column: 3)),
            "The cell under the finger"
        )
        let preview = try XCTUnwrap(host.host.grid.frame(forItemID: "f2"))
        XCTAssertEqual(preview.minX, cell.point(column: 3, row: 1, fx: 0).x, accuracy: 0.5)
        XCTAssertEqual(preview.minY, cell.point(column: 3, row: 1, fy: 0).y, accuracy: 0.5)

        host.coordinator.finishDrag(commit: true)
        settle(host, "f2")
        // D45: of the two tiles in folder F only "f1" is left, so the folder is dissolved and it takes its place.
        XCTAssertEqual(host.storeIDs, ["m", "f1", "s", "f2", "w"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "f1"), folderCell, "f1 took the folder's cell")
        XCTAssertEqual(host.store.placement(of: "f2"), TesseraTileGridPlacement(row: 1, column: 3))
        XCTAssertEqual(host.host.grid.frame(forItemID: "f2"), preview)
    }

    /// Taking out one of two tiles (D45: the folder is dissolved, and the remaining "f2" takes
    /// its cell) to the cell right of "d": the taken-out tile is last in reading order.
    func testPanelDropOfOneOfTwoTilesToEndDissolvesFolder() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2"],
            folderAt: 1
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folderCell = try XCTUnwrap(host.store.placement(of: folderID))
        let grid = try cells(host, first: "a", second: folderID)
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        _ = try startPanelDrag(host, iconIndex: 0)

        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")

        XCTAssertEqual(host.storeIDs, ["a", "f2", "b", "c", "d", "f1"] as [AnyHashable], "The folder was dissolved")
        XCTAssertEqual(host.store.placement(of: "f2"), folderCell, "f2 is in the folder's place")
        XCTAssertEqual(host.store.placement(of: "b"), TesseraTileGridPlacement(row: 0, column: 2), "The rest are not repacked")
        XCTAssertEqual(recorder.folderMoves.first?.cell, TesseraTileGridPlacement(row: 1, column: 3))
    }

    // MARK: - Drag on the grid (same branch)

    /// A regular drag: the finger is on an empty cell to the right of the last tile, and the item
    /// lands exactly in that cell; its old spot stays a hole.
    func testGridDragToEmptyCellAfterLastTileMovesToEnd() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e", "f"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let grid = try cells(host, first: "a", second: "b")
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TesseraTileGridPlacement(row: 1, column: 3)))
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        XCTAssertEqual(previewFrame.minX, grid.point(column: 3, row: 1, fx: 0).x, accuracy: 0.5)
        XCTAssertEqual(previewFrame.minY, grid.point(column: 3, row: 1, fy: 0).y, accuracy: 0.5)

        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.storeIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "a"), TesseraTileGridPlacement(row: 1, column: 3))
        XCTAssertEqual(host.store.placement(of: "b"), TesseraTileGridPlacement(row: 0, column: 1), "The hole at 'a' remains")
        XCTAssertEqual(recorder.moves.first?.cell, TesseraTileGridPlacement(row: 1, column: 3))
    }

    /// Over its own base cell there is no target (`.none`): the preview is the base layout, and a drop
    /// without a layout change does not write to the model.
    func testGridDragOverOwnSlotKeepsOrder() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e", "f"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let grid = try cells(host, first: "a", second: "b")
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("e"))
        host.coordinator.updateDrag(to: grid.point(column: 0, row: 1, fx: 0.4, fy: 0.6))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none)
        host.coordinator.finishDrag(commit: true)
        settle(host, "e")
        XCTAssertEqual(host.storeIDs, ["a", "b", "c", "d", "e", "f"] as [AnyHashable])
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    /// Over a tile's edge the target is its cell (`.cell` with the cell of "c"), not the cell
    /// under the finger: the item lands in the place of "c", and "c" moves down.
    func testGridDragOverTileStillReorders() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TesseraTileGridPlacement(row: 0, column: 2)))
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// At lift the finger is at the panel icon's position (after the panel closes it is an
    /// empty spot below the tiles): the placeholder does not "run away" from under the finger until the
    /// finger moves noticeably (`emptySlotActivationDistance`); then the preview
    /// follows the finger, and repeating the same cell does not change the preview.
    func testPanelLiftOverEmptySpaceKeepsDefaultSlotUntilFingerMoves() throws {
        let host = try makeHost(
            plain: [("a", .small), ("b", .small), ("c", .small), ("d", .small)],
            folderTiles: ["f1", "f2", "f3"],
            folderAt: 1
        )
        let grid = try cells(host, first: "a", second: host.storeIDs[1])
        let folderID = try startPanelDrag(host, iconIndex: 2)
        // The panel icon was below the tiles; after the panel closes the spot is empty.
        let origin = try XCTUnwrap(host.coordinator.dragSession?.originPoint)
        XCTAssertEqual(
            host.gridIDs,
            ["a", folderID, "b", "c", "d", "f3"] as [AnyHashable],
            "At lift the tile sits on the first free cell after the folder; order is the cell reading order"
        )

        let liftFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        host.coordinator.updateDrag(to: CGPoint(x: origin.x + 4, y: origin.y - 3))
        XCTAssertEqual(
            host.host.grid.frame(forItemID: "f3"),
            liftFrame,
            "Finger jitter does not touch the preview"
        )

        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TesseraTileGridPlacement(row: 1, column: 3)))
        let moved = try XCTUnwrap(host.host.grid.frame(forItemID: "f3"))
        XCTAssertNotEqual(moved, liftFrame, "The placeholder followed the finger")
        host.coordinator.updateDrag(to: grid.point(column: 3, row: 1, fx: 0.3, fy: 0.7))
        XCTAssertEqual(host.host.grid.frame(forItemID: "f3"), moved, "The same cell gives the same preview")
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "Cancel: grid = model")
        XCTAssertNil(host.coordinator.dragSession)
    }

    /// RTL: the finger's cell is computed in logical (not mirrored) coordinates:
    /// the empty cell to the right of the last tile in reading order (that is,
    /// to its left on screen) is logical column 2 of row 1.
    func testGridDragToEmptyCellInRightToLeftLandsAtEnd() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e", "f"].map { tesseraTestTile($0, size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.layout()
        let a = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        XCTAssertLessThan(b.minX, a.minX, "RTL: the second tile is to the left of the first")
        let pitch = a.minX - b.minX
        let f = try XCTUnwrap(host.host.grid.frame(forItemID: "f"))

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: CGPoint(x: f.midX - pitch, y: f.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(TesseraTileGridPlacement(row: 1, column: 2)))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.storeIDs, ["b", "c", "d", "e", "f", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "a"), TesseraTileGridPlacement(row: 1, column: 2))
    }
}

#endif
