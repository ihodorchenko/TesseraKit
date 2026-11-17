//
//  TileCellDragTests.swift
//  TesseraStartScreenTests
//
//  Cell-based drag: the target is the cell under the finger, the preview is computed from base placements,
//  and the drop is committed by `TesseraTileStore` cell operations.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, "Implementation deviations";
//  decisions D20, D21, D22, D30–D33 in docs/STATE.md.
//
//  User acceptance scenarios:
//  - A: a tile taken out of a folder panel (or dragged across the grid) and
//    released over an EMPTY cell lands exactly in it, not in the topmost hole;
//  - B: while the finger is over the center of a tile/folder (`.group`/`.folder`), the preview is the base
//    layout: the target stays under the finger and the highlight is drawn on it;
//  - C: a folder made of a 1×1 tile takes the target's 2×2 cell, neighbors are pushed
//    down instead of being sent far down with random holes.
//
//  The layouts are exact: a version 2 schema file with holes (`TileStoreCellFixture`) and a grid
//  from `TesseraTileStore.snapshot(columns:)`, 4 columns. No `sleep`: completion is awaited by
//  spinning the run loop (`waitUntil`).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileCellDragTests: XCTestCase {

    // MARK: - Helpers

    /// A delegate that records coordinator events.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Reorders within the grid.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

        /// Take-out/move between folders.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?, cell: TesseraTileGridPlacement?)] = []

        /// Created folders.
        var createdFolders: [TesseraTileFolder] = []

        /// Additions to a folder.
        var additions: [(id: AnyHashable, folder: AnyHashable)] = []

        /// Rejections by the approval function.
        var failures: [TesseraTileGroupingAction] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toCell cell: TesseraTileGridPlacement
        ) {
            moves.append((tileID, cell))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TesseraTileGridPlacement?
        ) {
            folderMoves.append((tileID, folderID, cell))
        }

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TesseraTileFolder) {
            createdFolders.append(folder)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didAdd tileID: AnyHashable,
            toFolder folderID: AnyHashable
        ) {
            additions.append((tileID, folderID))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TesseraTileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            failures.append(action)
        }
    }

    /// A cell in short notation.
    private func at(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    /// Six small tiles: `a b c d` in row 0, `e f` in row 1.
    private func makeSixTilesHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0,
            reorderPreviewDwell: 0
        )
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 1),
                CellFixtureTile("c", .small, 0, 2),
                CellFixtureTile("d", .small, 0, 3),
                CellFixtureTile("e", .small, 1, 0),
                CellFixtureTile("f", .small, 1, 1),
            ],
            configuration: configuration
        )
    }

    /// Compares frames to within fractions of a point (the layout's pixel grid).
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

    /// Waits for the drop to finish: no session, the snapshot view is gone, the grid matches the model.
    private func settle(_ host: TesseraTestDragHost, _ id: AnyHashable, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, "Session finished", file: file, line: line)
        XCTAssertTrue(host.waitForDragCleanup(id), "The cell is visible again", file: file, line: line)
        XCTAssertTrue(
            host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) },
            "The grid shows the model cells",
            file: file,
            line: line
        )
    }

    /// Enters edit mode, expands a folder panel and takes a panel icon.
    private func startPanelDrag(
        _ host: TesseraTestDragHost,
        folderID: AnyHashable,
        iconIndex: Int
    ) throws {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        // Enter the take-out right away (a long press on the panel starts a reorder).
        host.coordinator.startDragFromPanel(at: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
    }

    // MARK: - Scenario A: an empty cell, not the topmost hole

    /// A tile from a folder panel released over the empty area to the right of a 2×2 folder
    /// when the next tile is wide: lands **exactly in the cell under the finger**
    /// (1, 3), not in the topmost hole (0, 2).
    func testScenarioAPanelTileReleasedOverEmptyCellNextToFolderLandsExactlyThere() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("w", .wide, 2, 0)],
            folders: [
                CellFixtureFolder(
                    "F", .medium, 0, 0,
                    contents: [("f1", .small), ("f2", .small), ("f3", .small)]
                ),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try startPanelDrag(host, folderID: "F", iconIndex: 2)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)), "The cell under the finger")

        host.coordinator.finishDrag(commit: true)
        settle(host, "f3")

        XCTAssertEqual(host.store.placement(of: "f3"), at(1, 3), "Exactly in the cell under the finger")
        XCTAssertNotEqual(host.store.placement(of: "f3"), at(0, 2), "Not in the topmost hole")
        XCTAssertEqual(host.store.placement(of: "F"), at(0, 0), "The folder stays in place")
        XCTAssertEqual(host.store.placement(of: "w"), at(2, 0), "The wide tile stays in place")
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
        XCTAssertEqual(recorder.folderMoves.count, 1)
    }

    /// The same for a drag across the grid: a tile released over the empty cell (1, 3)
    /// lands in it and is not "pulled up" into the hole (0, 3) above.
    func testScenarioAGridTileReleasedOverEmptyCellLandsExactlyThere() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("b", .small, 0, 1),
                CellFixtureTile("c", .small, 0, 2),
                CellFixtureTile("d", .small, 1, 0),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("d"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host, "d")

        XCTAssertEqual(host.store.placement(of: "d"), at(1, 3))
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "b"), at(0, 1))
        XCTAssertEqual(host.store.placement(of: "c"), at(0, 2))
        XCTAssertFalse(
            host.store.placements(forColumns: 4).values.contains(at(0, 3)),
            "The hole (0, 3) stayed empty: there is no backfill"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("d"))
    }

    // MARK: - Scenario B: the merge target stays under the finger

    /// Over the center of a tile (`.group`) the preview is the base layout: a tile that
    /// the reorder preview had moved earlier returns under the finger, and the highlight
    /// is drawn on its base frame.
    func testScenarioBGroupTargetStaysUnderFingerAndIsHighlighted() throws {
        let host = try makeSixTilesHost()
        let baseB = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let baseTable = try XCTUnwrap(host.gridCells)

        XCTAssertTrue(host.startDrag("a"))
        // Over the edge of "c": the placement preview pushes "c" down.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2, fx: 0.1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        XCTAssertNotEqual(host.gridCells, baseTable, "The preview shifted the layout")

        // Over the center of "b": the preview is the whole base, "b" is under the finger.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(session.hover, .group("b"))
        XCTAssertEqual(session.previewPlacements, session.basePlacements, "No stale preview")
        XCTAssertEqual(host.gridCells, baseTable, "The grid shows the base cells")
        assertFrame(host.host.grid.frame(forItemID: "b"), baseB, "The target does not run away")
        let highlight = try XCTUnwrap(
            host.host.grid.subviews.compactMap { $0 as? TesseraTileDropHighlightView }.first { !$0.isHidden }
        )
        XCTAssertEqual(highlight.center.x, baseB.midX, accuracy: 0.5)
        XCTAssertEqual(highlight.center.y, baseB.midY, accuracy: 0.5)

        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }

    /// The same for the center of a folder (`.folder`): the target is under the finger, after the hold
    /// the drop adds the tile to the folder, and the tile's cell is left as a hole.
    func testScenarioBFolderTargetStaysUnderFingerAndDropAddsTile() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("x", .small, 0, 3),
            ],
            folders: [
                CellFixtureFolder("F", .medium, 1, 1, contents: [("f1", .small), ("f2", .small)]),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let baseF = try XCTUnwrap(host.host.grid.frame(forItemID: "F"))
        let baseTable = try XCTUnwrap(host.gridCells)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 1, fx: 0.1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 1)), "The folder edge is the folder cell")
        XCTAssertNotEqual(host.gridCells, baseTable)

        host.coordinator.updateDrag(to: CGPoint(x: baseF.midX, y: baseF.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("F"))
        XCTAssertEqual(host.gridCells, baseTable)
        assertFrame(host.host.grid.frame(forItemID: "F"), baseF)
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        settle(host, "F")
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["f1", "f2", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "F"), at(1, 1), "The folder stays in place")
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "The cell of \"a\" is a hole")
    }

    // MARK: - Scenario C: a 2×2 folder on the target cell, neighbors pushed down

    /// Merging two small tiles: a 2×2 folder takes the target cell of "b" (0, 1),
    /// the covered neighbors are pushed down in a cascade (D31), the cell of "a" stays
    /// a hole instead of "the folder flies far down with random holes".
    func testScenarioCFolderFromSmallTileStandsOnTargetCellAndPushesNeighborsDown() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        let folder = try XCTUnwrap(recorder.createdFolders.first)
        settle(host, folder.id)

        XCTAssertEqual(folder.size, .medium, "The folder is always 2×2 (D20)")
        XCTAssertEqual(folder.tiles.map { $0.id }, ["b", "a"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 1), "On the target cell")
        XCTAssertEqual(host.store.placement(of: "c"), at(2, 2), "\"c\" is pushed down (covered by the folder)")
        XCTAssertEqual(host.store.placement(of: "f"), at(2, 1), "\"f\" is pushed down (covered by the folder)")
        XCTAssertEqual(host.store.placement(of: "d"), at(0, 3), "Unaffected tiles stay in place")
        XCTAssertEqual(host.store.placement(of: "e"), at(1, 0), "Unaffected tiles stay in place")
        XCTAssertFalse(host.store.placements(forColumns: 4).values.contains(at(0, 0)), "The cell of \"a\" is a hole")
        // Live connection: grid frames follow the model cells.
        let folderFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id))
        assertFrame(folderFrame, host.cellFrame(row: 0, column: 1, size: .medium), "Frames follow the model cells")
    }

    // MARK: - Hit test: the cell under the finger

    /// The edge of a wide target tile is its cell (not the cell under the finger): the tile
    /// takes its place and the wide one goes down.
    func testWideTargetEdgeResolvesToItsOriginCell() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("w", .wide, 0, 0),
                CellFixtureTile("x", .small, 2, 3),
            ]
        )
        XCTAssertTrue(host.startDrag("x"))
        // The right part of the wide tile (cell (0, 3)), at the very edge.
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "w"))
        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 0)), "The cell of the target item")

        host.coordinator.finishDrag(commit: true)
        settle(host, "x")
        XCTAssertEqual(host.store.placement(of: "x"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "w"), at(1, 0), "The wide tile is pushed down")
    }

    /// An empty cell is the "this cell" target; the target's own base cell does not count.
    func testEmptyCellIsTargetAndOwnBaseCellIsNot() throws {
        let host = try makeSixTilesHost()
        XCTAssertTrue(host.startDrag("e"))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 2)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow, "Below the last occupied row")

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 0, fx: 0.4, fy: 0.6)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none, "Its own base cell")
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(session.previewPlacements, session.basePlacements, "The preview is the base")

        host.coordinator.finishDrag(commit: true)
        settle(host, "e")
        XCTAssertEqual(host.store.placement(of: "e"), at(1, 0), "No-op: stays in place")
        XCTAssertEqual(host.store.placements(forColumns: 4).count, 6)
    }

    /// A finger below the last occupied row is the "new row" target: the drop puts
    /// the item in column 0 of the new row (`moveItemToNewRow`).
    func testBelowLastRowDropsIntoNewRow() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        XCTAssertTrue(host.startDrag("b"))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 3, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        assertFrame(previewFrame, host.cellFrame(row: 2, column: 0), "The preview is the start of the new row")

        host.coordinator.finishDrag(commit: true)
        settle(host, "b")
        XCTAssertEqual(host.store.placement(of: "b"), at(2, 0))
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0), "The rest stay in place, the hole (0, 1) remains")
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("b"))
    }

    /// At the right edge a cell is limited by the canvas: cell (0, 3) for a 2×2
    /// becomes (0, 2), both in the preview and on drop; the target keeps the finger's cell.
    func testRightEdgeCellIsClampedByPreviewAndDrop() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("m", .medium, 2, 0),
            ]
        )
        XCTAssertTrue(host.startDrag("m"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 3)), "The finger's cell without clamping")
        assertFrame(
            host.host.grid.frame(forItemID: "m"),
            host.cellFrame(row: 0, column: 2, size: .medium),
            "The preview is on the clamped cell"
        )

        host.coordinator.finishDrag(commit: true)
        settle(host, "m")
        XCTAssertEqual(host.store.placement(of: "m"), at(0, 2))
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 0))
        // Rows 2–3 became empty and collapsed (on drop), row 1 is covered by "m".
        XCTAssertEqual(host.store.placements(forColumns: 4).count, 2)
    }

    /// RTL: the finger's cell is computed in logical coordinates: the edge of an occupied
    /// cell gives its logical cell, an empty cell gives the logical row and column.
    func testRightToLeftResolvesLogicalCells() throws {
        let host = try makeSixTilesHost()
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.layout()
        let c = try XCTUnwrap(host.host.grid.frame(forItemID: "c"))
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        XCTAssertLessThan(c.minX, b.minX, "RTL: \"c\" is to the left of \"b\"")

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: CGPoint(x: c.minX + 3, y: c.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Edge of \"c\": logical cell (0, 2)")

        // The empty cell (1, 3): on screen two steps to the left of "f" (logical column 1).
        let f = try XCTUnwrap(host.host.grid.frame(forItemID: "f"))
        let pitch = b.minX - c.minX
        host.coordinator.updateDrag(to: CGPoint(x: f.midX - 2 * pitch, y: f.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")
        XCTAssertEqual(host.store.placement(of: "a"), at(1, 3))
    }

    /// A folder dropped on the center of another folder does not merge (no nesting);
    /// it is a placement on its cell.
    func testFolderOverFolderCenterIsPlacementNotMerge() throws {
        let host = try TesseraTestDragHost(
            cells: [],
            folders: [
                CellFixtureFolder("F1", .medium, 0, 0, contents: [("a", .small), ("a2", .small)]),
                CellFixtureFolder("F2", .medium, 0, 2, contents: [("b", .small), ("b2", .small)]),
            ]
        )
        XCTAssertTrue(host.startDrag("F1"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("F2", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        host.coordinator.finishDrag(commit: false)
        settle(host, "F1")
    }

    // MARK: - Preview from the base

    /// The preview is computed from the base placements, not from the previous preview: after
    /// "b" -> "c" only "c" is shifted and "b" returned to its place; returning to its own
    /// cell gives the whole base. The order of the grid snapshot items follows the
    /// preview cells, and the host is not notified of the changes.
    func testPreviewIsComputedFromBaseWithoutAccumulation() throws {
        let host = try makeSixTilesHost()
        var notifications = 0
        host.store.onChange = { _ in notifications += 1 }
        let baseCells = try XCTUnwrap(host.gridCells)
        let baseOrder = host.gridIDs

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1, fx: 0.1)))
        XCTAssertEqual(host.gridCells?["b"], at(1, 1), "\"b\" is pushed down, \"f\" below it in a cascade")
        XCTAssertEqual(host.gridCells?["f"], at(2, 1))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2, fx: 0.1)))
        XCTAssertEqual(host.gridCells?["b"], at(0, 1), "\"b\" returned: shifts do not accumulate")
        XCTAssertEqual(host.gridCells?["f"], at(1, 1), "\"f\" returned")
        XCTAssertEqual(host.gridCells?["c"], at(1, 2), "Only the target is shifted")
        XCTAssertEqual(host.gridCells?["a"], at(0, 2), "The tile is on the target cell")
        XCTAssertEqual(
            host.gridIDs,
            ["b", "a", "d", "e", "f", "c"] as [AnyHashable],
            "The snapshot order is the reading order of the preview cells"
        )

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 0)))
        XCTAssertEqual(host.gridCells, baseCells, "Returning to its own cell gives the base")
        XCTAssertEqual(host.gridIDs, baseOrder, "The snapshot order is the base")
        XCTAssertEqual(notifications, 0, "The store is not written during the drag")
        XCTAssertEqual(host.store.placements(forColumns: 4), baseCells)

        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }

    /// Empty rows do not collapse during a drag (D31): tiles below do not
    /// move up until the item is dropped; on drop the row collapses.
    func testEmptyRowsAreNotCollapsedDuringDragButCollapseOnDrop() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 0),
                CellFixtureTile("c", .small, 1, 0),
                CellFixtureTile("d", .small, 2, 0),
            ]
        )
        XCTAssertTrue(host.startDrag("c"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 3)))
        XCTAssertEqual(host.gridCells?["c"], at(0, 3))
        XCTAssertEqual(host.gridCells?["d"], at(2, 0), "Row 1 became empty but does not collapse during the drag")

        host.coordinator.finishDrag(commit: true)
        settle(host, "c")
        XCTAssertEqual(host.store.placement(of: "c"), at(0, 3))
        XCTAssertEqual(host.store.placement(of: "d"), at(1, 0), "The empty row collapsed on drop")
    }

    // MARK: - Committing the drop by target kind

    /// Without a sustained hold the tile center is a no-op: the model cells and the delegate
    /// are untouched, and the grid returns to the model.
    func testGroupWithoutHoldDropIsNoOp() throws {
        let host = try makeSixTilesHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let before = host.store.placements(forColumns: 4)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")

        XCTAssertEqual(host.store.placements(forColumns: 4), before)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    /// The host rejects the merge: the model is as before the drop, the delegate receives
    /// `didFailGrouping`, and the grid returns to the model.
    func testGroupDeniedByApprovalKeepsModelAndReportsFailure() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .createFolder }
        let before = host.store.placements(forColumns: 4)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 1)))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        settle(host, "a")

        XCTAssertEqual(host.store.placements(forColumns: 4), before)
        XCTAssertEqual(recorder.failures, [.createFolder])
        XCTAssertTrue(host.folders.isEmpty)
    }

    /// Cancelling (and leaving edit mode) in the middle of a drag returns the base layout and does not
    /// write to the model.
    func testCancelRestoresBaseAndLeavesModelUntouched() throws {
        let host = try makeSixTilesHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        var notifications = 0
        host.store.onChange = { _ in notifications += 1 }
        let before = host.store.placements(forColumns: 4)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertNotEqual(host.gridCells, before)
        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
        XCTAssertEqual(host.gridCells, before)
        XCTAssertEqual(host.store.placements(forColumns: 4), before)
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(recorder.moves.isEmpty)

        XCTAssertTrue(host.startDrag("b"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 3, column: 0)))
        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.waitUntil { host.gridCells == before })
        XCTAssertEqual(host.store.placements(forColumns: 4), before)
    }

    /// A tile from the panel onto the center of a regular tile is not a merge but a take-out onto the cell
    /// of that tile (it is pushed down); a drop on the center of its own folder is a no-op.
    func testPanelTileOnPlainTileCenterIsPlacementAndOnSourceFolderIsNoOp() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("t", .small, 0, 2)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small), ("f2", .small)]),
            ]
        )
        try startPanelDrag(host, folderID: "F", iconIndex: 0)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "The tile center is not a group")
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")
        XCTAssertEqual(host.store.placement(of: "f1"), at(0, 2))
        XCTAssertEqual(host.store.placement(of: "t"), at(1, 2), "Pushed down")

        let host2 = try TesseraTestDragHost(
            cells: [],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small), ("f2", .small)]),
            ]
        )
        try startPanelDrag(host2, folderID: "F", iconIndex: 0)
        host2.coordinator.updateDrag(to: try XCTUnwrap(host2.point("F", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host2.coordinator.dragSession?.hover, .sourceFolder)
        host2.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host2.waitUntil { host2.coordinator.dragSession == nil })
        XCTAssertEqual(host2.folders.first?.tiles.map { $0.id }, ["f1", "f2"] as [AnyHashable])
    }

    /// A tile from the panel into a new row (D45): the folder has two tiles, it is dissolved,
    /// the remaining one (large) takes its cell with its own size; the "new row"
    /// preview is computed with it already, like the store operation, so the tile lands
    /// exactly where the preview showed it (a folder with a single tile used to vanish).
    func testPanelTileToNewRowDissolvesFolderAndLandsWherePreviewShowed() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [
                CellFixtureFolder("F", .small, 1, 0, contents: [("f1", .small), ("f2", .large)]),
            ]
        )
        try startPanelDrag(host, folderID: "F", iconIndex: 0)
        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 20))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        let previewFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "f1"))
        XCTAssertNotNil(host.host.grid.frame(forItemID: "f2"), "The preview showed the dissolution: the remaining tile is in the folder's place")
        XCTAssertNil(host.host.grid.frame(forItemID: "F"), "There is no folder in the preview")
        host.coordinator.finishDrag(commit: true)
        settle(host, "f1")

        XCTAssertTrue(host.folders.isEmpty, "The folder was dissolved")
        XCTAssertEqual(host.store.placement(of: "a"), at(0, 3))
        XCTAssertEqual(host.store.placement(of: "f2"), at(1, 0), "The remaining tile is on the folder's cell")
        XCTAssertEqual(host.store.snapshot().item(withID: "f2")?.size, .large, "with its own size")
        XCTAssertEqual(host.store.placement(of: "f1"), at(5, 0), "The new row is computed with the remaining tile")
        assertFrame(host.host.grid.frame(forItemID: "f1"), previewFrame, "The tile landed where the preview showed")
    }

    // MARK: - External changes and the magnet

    /// An external edit that only moved tiles (same composition) makes
    /// the base stale: the drag is safely cancelled.
    func testExternalCellOnlyChangeCancelsDrag() throws {
        let host = try makeSixTilesHost()
        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 2, fx: 0.1)))
        XCTAssertTrue(host.coordinator.isDragging)

        XCTAssertTrue(host.store.moveItem("f", toCell: at(3, 3), columns: 4))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 0, column: 3, fx: 0.1)))

        XCTAssertFalse(host.coordinator.isDragging, "The drag was cancelled")
        XCTAssertTrue(host.waitUntil { host.gridCells == host.store.placements(forColumns: 4) })
        XCTAssertEqual(host.store.placement(of: "f"), at(3, 3), "The external edit was not rolled back")
        XCTAssertGreaterThan(host.host.cell("a")?.contentView.alpha ?? 0, 0.9, "The cell is visible")
    }

    /// Magnet: the snapshot view is pulled to the frame of the target cell (for its own size) and
    /// is not pulled over merge targets.
    func testMagnetSnapsToTargetCellFrameAndNotOverMergeTargets() throws {
        let host = try makeSixTilesHost(
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 40,
                magnetSpringDuration: 0
            )
        )
        XCTAssertTrue(host.startDrag("a"))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        session.hasLeftOriginSlot = true

        // The empty cell (1, 3), the finger slightly left of and above the center (within the pull radius).
        let center = try XCTUnwrap(host.cellFrame(row: 1, column: 3)).center
        let finger = CGPoint(
            x: center.x - session.grabOffset.x + 6,
            y: center.y - session.grabOffset.y - 6
        )
        host.coordinator.updateDrag(to: finger)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)))
        let target = try XCTUnwrap(host.coordinator.dragMagnetTargetForTesting(at: finger))
        XCTAssertEqual(target.x, center.x, accuracy: 0.001, "Center of the target cell's frame")
        XCTAssertEqual(target.y, center.y, accuracy: 0.001)

        // Over the center of "b" (a merge target) there is no pull.
        let bCenter = try XCTUnwrap(host.cellPoint(row: 0, column: 1))
        host.coordinator.updateDrag(to: bCenter)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))
        XCTAssertNil(host.coordinator.dragMagnetTargetForTesting(at: bCenter))

        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }
}

private extension CGRect {

    /// The center of a frame.
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

#endif
