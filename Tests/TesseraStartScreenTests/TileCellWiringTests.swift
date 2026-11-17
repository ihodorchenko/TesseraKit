//
//  TileCellWiringTests.swift
//  TesseraStartScreenTests
//
//  Live wiring of cells and the edit button to `TesseraTileStore` cell operations
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  "Implementation deviations"; decisions D30–D33 in docs/STATE.md.
//
//  What is checked:
//  - grid frames match the model's stored cells (including holes);
//  - unpinning leaves a hole, and only a fully empty row collapses (D31);
//  - the size arrow: growing pushes tiles down, shrinking leaves a hole or collapses the row;
//  - the grid width is reported to the store, including when the columns change (D32);
//  - a grid built by the host without a cell table catches up on entering edit mode;
//  - the store's `onChange` delivers a snapshot with a cell table once the width is known;
//  - the public `move(toCell:)`/`moveToNewRow`/`createFolder`/`addToFolder` work by cells.
//
//  Layouts are exact (`TileStoreCellFixture`), 4 columns; no `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileCellWiringTests: XCTestCase {

    // MARK: - Helpers

    /// A delegate that counts unpin, resize and move events.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// `didUnpin` events.
        var unpins: [AnyHashable] = []

        /// `didResize` events.
        var resizes: [(id: AnyHashable, size: TesseraTileSize)] = []

        /// `didMove(toCell:)` events.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            unpins.append(tileID)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didResize tileID: AnyHashable,
            to size: TesseraTileSize
        ) {
            resizes.append((tileID, size))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toCell cell: TesseraTileGridPlacement
        ) {
            moves.append((tileID, cell))
        }
    }

    /// A cell in short notation.
    private func at(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    /// Compares frames to within a fraction of a point.
    private func assertFrame(
        _ actual: CGRect?,
        _ expected: CGRect?,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual, let expected else {
            return XCTFail("No frame: \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    /// A layout with holes: `a (0,0)`, `b (0,2)`, `c (1,3)`, `w` wide `(2,0)`.
    private func makeHoleyHost() throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 2),
                CellFixtureTile("c", .small, 1, 3),
                CellFixtureTile("w", .wide, 2, 0),
            ]
        )
    }

    // MARK: - Live wiring

    /// A grid built from `TesseraTileStore.snapshot(columns:)` shows tiles exactly at the
    /// model's stored cells — with holes, with no back-filling.
    func testGridFramesEqualStoredPlacementsWithHoles() throws {
        let host = try makeHoleyHost()
        let sizes: [String: TesseraTileSize] = ["a": .small, "b": .small, "c": .small, "w": .wide]

        for (id, cell) in host.store.placements(forColumns: 4) {
            let key = try XCTUnwrap(id.base as? String)
            assertFrame(
                host.host.grid.frame(forItemID: id),
                host.host.grid.baseFrame(forCell: cell, size: try XCTUnwrap(sizes[key])),
                "\(key) at cell (\(cell.row), \(cell.column))"
            )
        }
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        XCTAssertEqual(host.store.placement(of: "b"), at(0, 2), "Hole (0, 1) is not filled")
    }

    /// First launch (no cells in the file yet): the regular path gives the same compact
    /// layout as packing in order, with no holes.
    func testFirstLaunchShowsCompactLayoutThroughCells() throws {
        let host = TesseraTestDragHost(
            descriptors: ["a", "b", "c", "d", "e"].map { tesseraTestTile($0, size: .small) }
        )
        let expected: [(String, Int, Int)] = [
            ("a", 0, 0), ("b", 0, 1), ("c", 0, 2), ("d", 0, 3), ("e", 1, 0),
        ]
        for (id, row, column) in expected {
            assertFrame(
                host.host.grid.frame(forItemID: AnyHashable(id)),
                host.cellFrame(row: row, column: column),
                id
            )
        }
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
    }

    /// A host that built the grid from `snapshot()` without a cell table gets, on entering
    /// edit mode, the same cells as in the model (without animation).
    func testEditingSyncsGridWhenHostOmittedCellTable() throws {
        let host = try makeHoleyHost()
        host.host.grid.reload(snapshot: host.store.snapshot())
        host.host.layout()
        XCTAssertNil(host.host.grid.snapshot?.placementTable, "The host shows order packing")

        host.coordinator.beginEditing()
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        assertFrame(host.host.grid.frame(forItemID: "b"), host.cellFrame(row: 0, column: 2))
        host.coordinator.endEditing()
    }

    /// The store's `onChange` delivers a snapshot with a cell table once the grid width is
    /// known (the coordinator reports it); without a width — the previous snapshot.
    func testOnChangeSnapshotCarriesCellTableWhenWidthIsKnown() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: 4,
            tiles: [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 2)],
            in: directory,
            autosaves: false
        )
        var snapshots: [TesseraTileGridSnapshot] = []
        store.onChange = { snapshots.append($0) }

        XCTAssertTrue(store.resize("a", to: .medium, columns: 4))
        XCTAssertEqual(snapshots.last?.placementTable?.columns, 4)
        XCTAssertEqual(snapshots.last?.placementTable?.cells["b"], at(0, 2))

        let bare = TesseraTileStore(directoryURL: TesseraTestDirectory().url)
        bare.autosaves = false
        bare.setCatalog([tesseraTestTile("a", size: .small)])
        var bareSnapshot: TesseraTileGridSnapshot?
        bare.onChange = { bareSnapshot = $0 }
        // A notification without an operation carrying `columns`: the grid width is unknown to the store.
        bare.setCatalog([tesseraTestTile("a", size: .small), tesseraTestTile("b", size: .small)])
        XCTAssertNotNil(bareSnapshot)
        XCTAssertNil(bareSnapshot?.placementTable, "A host without a width — the previous snapshot")
    }

    // MARK: - Unpin

    /// Unpinning leaves a hole: the other tiles do not move, the tile's cell
    /// is free; a row where other tiles remain does not collapse.
    func testUnpinLeavesHoleWithoutRepacking() throws {
        let host = try makeHoleyHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        let before = host.store.placements(forColumns: 4)
        let bFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        var expected = before
        expected["a"] = nil
        XCTAssertEqual(host.store.placements(forColumns: 4), expected, "Only a left; the others stay in place")
        XCTAssertTrue(host.waitUntil { host.gridCells == expected })
        assertFrame(host.host.grid.frame(forItemID: "b"), bFrame, "Neighbors do not move")
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "A hole where a was")
        host.coordinator.endEditing()
    }

    /// Unpinning the only tile of a row collapses the empty row (D31):
    /// the tiles below move up; holes inside the other rows remain.
    func testUnpinOfOnlyTileInRowCollapsesEmptyRow() throws {
        let host = try makeHoleyHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        host.coordinator.unpin("c")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "b"), at(0, 2), "The hole in row 0 remained")
        // Row 1 (where c was) became empty: w moves up into it.
        XCTAssertEqual(host.store.placement(of: "w"), at(1, 0))
        XCTAssertTrue(host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) })
        host.coordinator.endEditing()
    }

    /// A tile in a folder is unpinned without a fly-out (it is not on the grid): the last tile
    /// of a transitional folder (D45: a one-tile folder exists only after
    /// `createFolder(withTile:)`) removes the folder, and its cell remains a hole.
    func testUnpinOfSoleFolderTileLeavesHoleWhereFolderWas() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("f1", .small, 0, 0)]
        )
        XCTAssertNotNil(host.coordinator.createFolder(withTile: "f1"))
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        host.coordinator.unpin("f1")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placements(forColumns: 4), ["a": at(0, 3)], "A hole where the folder was, no repack")
        XCTAssertTrue(host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) })
        host.coordinator.endEditing()
    }

    // MARK: - Size

    /// The size arrow: growing in place pushes a blocking tile down in a cascade
    /// (D31), and the anchor cell stays.
    func testCycleSizeGrowthPushesNeighborDownAndKeepsAnchor() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 1),
                CellFixtureTile("z", .small, 0, 3),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        // In the full cycle (D28) small is followed by wide; this test is about growing to
        // 2×2 and pushing, so the set is narrowed to small/medium.
        host.coordinator.supportedSizesProvider = { _ in [.small, .medium] }
        host.coordinator.beginEditing()

        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .medium)
        XCTAssertEqual(recorder.resizes.count, 1)
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0), "The anchor stayed")
        XCTAssertEqual(host.store.placement(of: "b"), at(2, 1), "b is pushed below the 2×2 tile")
        XCTAssertEqual(host.store.placement(of: "z"), at(0, 3), "Untouched — in place")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        assertFrame(host.host.grid.frame(forItemID: "a"), host.cellFrame(row: 0, column: 0, size: .medium))
        host.coordinator.endEditing()
    }

    /// Shrinking a tile leaves a hole; if the rows it covered became empty,
    /// they collapse (D31).
    func testCycleSizeShrinkLeavesHoleAndCollapsesEmptyRows() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("big", .large, 0, 0),
                CellFixtureTile("x", .small, 4, 0),
            ]
        )
        host.coordinator.beginEditing()

        XCTAssertEqual(host.coordinator.cycleSize(of: "big"), .small, "large → small")
        XCTAssertEqual(host.store.placement(of: "big"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "x"), at(1, 0), "The empty rows 1–3 collapsed")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
        host.coordinator.endEditing()
    }

    // MARK: - Grid width

    /// A change in the column count is reported to the store; in edit mode the grid is rebuilt
    /// for the new width, and the file is not rewritten (the canvas keeps the old width, D32).
    func testColumnsChangeReportsWidthToStoreAndRebuildsGridWhileEditing() throws {
        let host = try makeHoleyHost()
        XCTAssertEqual(host.store.canvasColumns, 4)
        host.coordinator.beginEditing()

        host.host.grid.columns = 6
        XCTAssertEqual(host.store.effectiveColumns, 6, "The store learned the new width")
        XCTAssertEqual(host.store.canvasColumns, 4, "The file is not rewritten while the user edits nothing")
        XCTAssertEqual(host.host.grid.snapshot?.placementTable?.columns, 6, "The grid is rebuilt for 6 columns")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 6))
        XCTAssertEqual(host.gridCells?["b"], at(0, 1), "D32 projection: reading order without holes")

        host.host.grid.columns = 4
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4), "Returning to the canvas width brings the holes back")
        XCTAssertEqual(host.gridCells?["b"], at(0, 2))
        host.coordinator.endEditing()
    }

    /// A change of columns during a drag cancels it: the base was computed at the previous width.
    func testColumnsChangeDuringDragCancelsDrag() throws {
        let host = try makeHoleyHost()
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 1)))

        host.host.grid.columns = 6
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 6))
        XCTAssertGreaterThan(host.host.cell("a")?.contentView.alpha ?? 0, 0.9, "The cell is visible again")
    }

    // MARK: - Public coordinator operations

    /// The public `move(toCell:)` and `moveToNewRow` work by cells: the item
    /// lands on the cell (clamped to the canvas), blocking tiles are pushed down;
    /// a new row goes at the end of the canvas; an empty row collapses; the delegate
    /// receives the resulting cell.
    func testPublicMoveToCellAndNewRowUseCells() throws {
        let host = try makeHoleyHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        // Reading order: a (0,0), b (0,2), c (1,3), w (2,0).

        XCTAssertTrue(host.coordinator.move("w", toCell: at(0, 2)), "w onto b's cell")
        XCTAssertEqual(host.store.placement(of: "w"), at(0, 0), "4×2 is clamped to the canvas, to column 0")
        XCTAssertEqual(host.storeIDs.first, AnyHashable("w"))
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.cell, at(0, 0))

        XCTAssertTrue(host.coordinator.moveToNewRow("a"))
        XCTAssertEqual(host.storeIDs.last, AnyHashable("a"), "A new row at the end of the canvas")
        XCTAssertEqual(host.store.placement(of: "a")?.column, 0)
        XCTAssertEqual(recorder.moves.last?.cell, host.store.placement(of: "a"))
        XCTAssertFalse(host.coordinator.moveToNewRow("a"), "Already alone in the bottom row")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
    }

    /// The public `createFolder(withTile:)` and `addToFolder` do not lose holes: cells
    /// are computed by the engine, not by order packing.
    func testPublicFolderOperationsKeepHoles() throws {
        let host = try makeHoleyHost()

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "b", title: "G"))
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 2), "A 2×2 folder on the tile's cell")
        XCTAssertEqual(host.store.placement(of: "c"), at(2, 3), "c is covered by the folder and pushed down")
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0), "a is in place, hole (0, 1) remained")

        XCTAssertTrue(host.coordinator.addToFolder("a", folderID: folder.id))
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "a's cell is a hole")
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 2), "The folder did not move")
        XCTAssertEqual(host.gridCells, host.store.placements(forColumns: 4))
    }
}

#endif
