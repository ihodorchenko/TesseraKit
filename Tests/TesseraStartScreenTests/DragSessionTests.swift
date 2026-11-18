//
//  DragSessionTests.swift
//  TesseraStartScreenTests
//
//  Full drag sessions of edit mode.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit mode"
//  (the own drag coordinator: snapshot, placeholder, push preview, magnet,
//  merge into a folder by hold, unpin/resize) and §3 "Tile grid".
//
//  Checked on real cells and a real `TesseraTileStore` in a window
//  (`TesseraTestWindowedGrid` + `TesseraTestDragHost`):
//  - the edge zones of a folder tile reorder it, the central one adds
//    a tile after the hold; a source folder is not dragged into a folder;
//  - the magnet computes the slot from the snapshot center (`grabOffset`), not from the finger;
//  - the hold is re-armed after the finger returns within the slop;
//  - entering edit mode closes the folder panel, and a drag does not start from the panel;
//  - an external model/snapshot during a drag — a safe cancel without a rollback to
//    a stale base;
//  - `deinit`/fly-out restore the hidden cell, scrolling and autosaves;
//  - a double quick unpin — one fly-out and one callback;
//  - a configuration change on the fly rebuilds the controls and the jiggle;
//  - the jiggle and the dim survive unpin and folder creation;
//  - `.layoutChanged` after unpin/resize;
//  - the delegate receives the actual (canvas-clamped) cell, the grid
//    syncs with the store snapshot (instead of an index);
//  - the model order is the cells' reading order after unpin/folder operations;
//  - the folder screen activates a tile through the shared `grid.onTap` route;
//  - a drop on the center without a hold — a return to the original place (no-op);
//  - defaults for the strict bounds and the jiggle of ±1.2°;
//  - drag of a tile from the panel of an opened folder (take-out onto the grid at the preview
//    position, dissolving a one-tile folder, a move to another folder by
//    hold, no-op without a hold / on the home folder / on cancel), a tap on a
//    folder in edit mode opens the panel.
//
//  - taking the only tile out into a "hole" of the model does not put it into a
//    neighboring folder (not reproduced; guard tests, a hold over B does not
//    survive the finger leaving);
//  - the drag target is the cell under the finger (`HoverTarget.cell`/`.newRow`,
//    a drop where the preview showed): a separate `DropSlotTests` suite;
//  - the drag target is a cell by the base layout (the edge of an occupied cell is the cell of
//    the target item, the center is a merge), the preview shows the same items on other cells
//    (the snapshot order does not change), a merge center shows the base layout;
//  - atomic folder creation by a drop — a failure of the second step rolls back
//    the first (the model as before the drop, only `didFailGrouping`), `didCreateFolder`
//    arrives after both steps and before `didAdd`.
//
//  Determinism: no `sleep`; completion by spinning the run loop (`waitUntil`),
//  hold timers in tests are shortened through the configuration.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class DragSessionTests: XCTestCase {

    // MARK: - Helpers

    /// A delegate that records coordinator events.
    private final class DragDelegateRecorder: TesseraTileEditCoordinatorDelegate {

        /// `didMove(toCell:)` events in order of arrival.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

        /// `didUnpin` events.
        var unpins: [AnyHashable] = []

        /// `didResize` events.
        var resizes: [(id: AnyHashable, size: TesseraTileSize)] = []

        /// `didCreateFolder` events.
        var createdFolders: [TesseraTileFolder] = []

        /// `didAdd(toFolder:)` events.
        var additions: [(id: AnyHashable, folder: AnyHashable)] = []

        /// `didMove(toFolder:)` events.
        var folderMoves: [(id: AnyHashable, folder: AnyHashable?)] = []

        /// `didFailGrouping` events.
        var failures: [TesseraTileGroupingAction] = []

        /// The order of folder delegate events: "create" / "add".
        var folderEventLog: [String] = []

        /// How many times the coordinator entered/left editing.
        var beginEditingCount = 0
        var endEditingCount = 0

        func tileEditCoordinatorDidBeginEditing(_ coordinator: TesseraTileEditCoordinator) {
            beginEditingCount += 1
        }

        func tileEditCoordinatorDidEndEditing(_ coordinator: TesseraTileEditCoordinator) {
            endEditingCount += 1
        }

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

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didCreateFolder folder: TesseraTileFolder) {
            createdFolders.append(folder)
            folderEventLog.append("create")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didAdd tileID: AnyHashable,
            toFolder folderID: AnyHashable
        ) {
            additions.append((tileID, folderID))
            folderEventLog.append("add")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?
        ) {
            folderMoves.append((tileID, folderID))
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

    /// A bench with a folder made of tile "b" (grid order: "a", the folder).
    ///
    /// - Parameters:
    ///   - configuration: Editing parameters.
    /// - Returns: A ready bench.
    private func makeFolderHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration()
    ) -> TesseraTestDragHost {
        TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: configuration,
            prepare: { store, columns in
                _ = store.createFolder(withTile: "b", columns: columns)
            }
        )
    }

    /// The alpha of a cell's content.
    ///
    /// - Parameters:
    ///   - id: The item identifier.
    ///   - host: The bench.
    /// - Returns: `contentView.alpha`, or 1 if there is no cell.
    private func alpha(of id: AnyHashable, in host: TesseraTestDragHost) -> CGFloat {
        host.host.cell(id)?.contentView.alpha ?? 1
    }

    /// An item's cell in the model — it is also the drag's base cell: the model does not
    /// change during a drag.
    ///
    /// - Parameters:
    ///   - id: The item identifier.
    ///   - host: The bench.
    /// - Returns: The cell from `TesseraTileStore`.
    private func cell(_ id: AnyHashable, in host: TesseraTestDragHost) throws -> TesseraTileGridPlacement {
        // The cells the grid sees (for the grid width): the file may have been built
        // by operations at another canvas width, in which case this is a projection (D32).
        try XCTUnwrap(
            host.store.placements(forColumns: host.host.grid.columns)[id],
            "\(id) has no cell in the model"
        )
    }

    /// The current jiggle animation on a cell.
    ///
    /// - Parameters:
    ///   - id: The item identifier.
    ///   - host: The bench.
    /// - Returns: The animation or `nil`.
    private func jiggle(of id: AnyHashable, in host: TesseraTestDragHost) -> CAAnimation? {
        host.host.cell(id)?.contentView.layer.animation(
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    // MARK: - Default configuration

    /// The hold and jiggle bounds: 600 ms / 10 pt and ±1.2° are the defaults;
    /// the jiggle itself is off (D39).
    func testDragConfigurationDefaultsMatchApprovedDecisions() {
        let configuration = TesseraTileEditConfiguration()

        XCTAssertFalse(configuration.isJiggleEnabled)
        XCTAssertEqual(configuration.mergeHoverDuration, 0.6, accuracy: 0.0001)
        XCTAssertEqual(configuration.mergeHoverDisplacement, 10, accuracy: 0.0001)
        XCTAssertEqual(configuration.jiggleAngle, 1.2, accuracy: 0.0001)
        XCTAssertEqual(configuration.jiggleDuration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(configuration.controlDiameter, 28, accuracy: 0.0001)
    }

    // MARK: - Edge zones of a folder tile

    /// The left/right half of a folder tile is a placement zone: the tile lands on
    /// the folder's cell, and the folder is pushed down (D31).
    func testFolderEdgeZoneReordersTileInsteadOfAdding() throws {
        let host = makeFolderHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))

        let folderCell = try cell(folderID, in: host)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(folderCell),
            "A folder edge is a placement target with the folder's cell"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(
            host.waitUntil { recorder.moves.count == 1 },
            "A drop in the edge zone ended with a move"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.cell, folderCell, "The actual cell")
        XCTAssertEqual(host.store.placement(of: "a"), folderCell, "The tile is on the folder's cell")
        XCTAssertEqual(
            host.store.placement(of: folderID),
            TesseraTileGridPlacement(row: folderCell.row + 1, column: folderCell.column),
            "The folder is pushed down (D31)"
        )
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// Dragging a folder across the grid is an ordinary placement in any zone:
    /// a folder cannot be dropped into a folder (`session.isTile == false`).
    func testFolderAsSourceIsNeverGrouped() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag(folderID))
        XCTAssertEqual(host.coordinator.dragSession?.isTile, false)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("a", in: host)),
            "A folder over a tile's center — placement onto its cell, not grouping"
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup(folderID))
    }

    /// The central zone of a folder without a hold is a no-op: the model and the grid do not
    /// change, the delegate receives no events.
    func testFolderCenterZoneWithoutHoldReturnsToOriginalPlace() throws {
        let host = makeFolderHost(configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0))
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folderTilesBefore = try XCTUnwrap(host.folders.first).tiles.map { $0.id }

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(folderID))

        host.coordinator.finishDrag(commit: true)
        XCTAssertEqual(host.storeIDs, ["a", folderID], "The model did not change")
        XCTAssertEqual(
            try XCTUnwrap(host.folders.first).tiles.map { $0.id },
            folderTilesBefore,
            "The tile is not added to the folder without a hold"
        )
        XCTAssertTrue(recorder.additions.isEmpty)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// The central zone of a folder with a completed hold — the tile goes
    /// into the folder (D14), and the grid is left with a single folder tile.
    func testFolderCenterZoneAfterHoldAddsTileToFolder() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5)))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "The hold over the folder's central zone is completed"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        XCTAssertEqual(recorder.additions.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.additions.first?.folder, folderID)
        XCTAssertEqual(host.storeIDs, [folderID], "The tile went into the folder")
        XCTAssertTrue(
            host.waitUntil {
                host.folders.first?.tiles.contains { $0.id == AnyHashable("a") } == true
            },
            "The tile in the folder model"
        )
    }

    /// When a folder is created the snapshot collapses into the frame of the new folder tile,
    /// not into the placeholder slot (the frame is read after `render`).
    func testNewFolderDropCollapsesIntoFolderFrame() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("x", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        let placeholderFrame = try XCTUnwrap(host.coordinator.dragSession?.placeholder.frame)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "The hold over the tile's center is completed"
        )
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })

        let folderID = try XCTUnwrap(host.firstFolderID)
        let target = try XCTUnwrap(host.coordinator.lastCollapseTargetFrame)
        let folderFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folderID))
        XCTAssertEqual(target, folderFrame, "The flight target is the new folder's frame")
        XCTAssertNotEqual(target, placeholderFrame, "Not the old placeholder slot")
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, "The drag is finished")
    }

    // MARK: - Magnet from the snapshot center (grabOffset)

    /// The magnet measures the distance from the snapshot center, not from the finger: a tile
    /// grabbed by a corner is attracted to a slot even though the finger is farther from it than the
    /// radius; the snapshot does not jump.
    func testMagnetUsesSnapshotCenterNotFingerPoint() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<4).map { tesseraTestTile("s\($0)", size: .small) },
            configuration: TesseraTileEditConfiguration(
                magnetSnapRadius: 28,
                magnetSpringDuration: 0
            )
        )
        let slotCenters = host.host.grid.magnetSlotCenters(for: .small)
        XCTAssertEqual(slotCenters.count, 4, "One row of four small slots")
        let slotCenter = slotCenters[2]

        // Grabbing by a corner: grabOffset ≈ 0.4 of the tile side, longer than the radius.
        XCTAssertTrue(host.startDrag("s0", fx: 0.1, fy: 0.1))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertGreaterThan(
            hypot(session.grabOffset.x, session.grabOffset.y),
            host.coordinator.configuration.magnetSnapRadius,
            "The grab is not at the center — the old (finger-based) magnet would not have fired here"
        )

        // Place the finger so that the snapshot's CENTER lands on the slot's center.
        let point = CGPoint(
            x: slotCenter.x - session.grabOffset.x,
            y: slotCenter.y - session.grabOffset.y
        )
        XCTAssertGreaterThan(
            hypot(point.x - slotCenter.x, point.y - slotCenter.y),
            host.coordinator.configuration.magnetSnapRadius,
            "The finger is farther than the radius from the slot"
        )
        host.coordinator.updateDrag(to: point)

        let sessionAfter = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(sessionAfter.magnetTarget, slotCenter, "The magnet target is the slot's center")
        XCTAssertEqual(
            sessionAfter.dragView.center.x,
            slotCenter.x,
            accuracy: 0.001,
            "The snapshot is attracted to the slot's center"
        )
        XCTAssertEqual(sessionAfter.dragView.center.y, slotCenter.y, accuracy: 0.001)
        let followCenter = CGPoint(
            x: point.x + sessionAfter.grabOffset.x,
            y: point.y + sessionAfter.grabOffset.y
        )
        XCTAssertLessThanOrEqual(
            hypot(
                sessionAfter.dragView.center.x - followCenter.x,
                sessionAfter.dragView.center.y - followCenter.y
            ),
            host.coordinator.configuration.magnetSnapRadius + 0.001,
            "The snapshot moved toward the slot by no more than the radius"
        )

        // Move the finger far away: the magnet is released, and the snapshot is under the finger 1:1 again.
        let farPoint = CGPoint(x: point.x, y: point.y + 150)
        host.coordinator.updateDrag(to: farPoint)
        let sessionFar = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertNil(sessionFar.magnetTarget, "There are no slots nearby")
        XCTAssertEqual(
            sessionFar.dragView.center.x,
            farPoint.x + sessionFar.grabOffset.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sessionFar.dragView.center.y,
            farPoint.y + sessionFar.grabOffset.y,
            accuracy: 0.001
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("s0"))
    }

    // MARK: - Hold re-arm

    /// A movement beyond the slop cancels the hold and moves the anchor to the current point
    /// (it replaced the earlier behavior): returning to the old anchor is a movement again, that
    /// is a new 600 ms countdown; a drop after a completed new countdown creates a folder.
    func testMergeHoldRearmsAfterReturningToTolerance() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let center = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: center)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertEqual(host.coordinator.mergeTracker?.anchor, center)

        // A 15 pt movement inside the central zone: the anchor moves to the new point.
        let moved = CGPoint(x: center.x + 15, y: center.y)
        host.coordinator.updateDrag(to: moved)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertEqual(host.coordinator.mergeTracker?.anchor, moved)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)

        // Returning to the old point is a 15 pt movement again: another re-arm,
        // not an instant readiness.
        host.coordinator.updateDrag(to: center)
        XCTAssertEqual(host.coordinator.mergeTracker?.state, .armed)
        XCTAssertEqual(host.coordinator.mergeTracker?.anchor, center)
        XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true)
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "The new 600 ms countdown is completed"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        XCTAssertEqual(host.folders.count, 1, "The folder is created after the re-arm")
    }

    // MARK: - Folder panel and entering edit mode

    /// Entering edit mode closes an opened folder panel with the standard
    /// `closeFolder`.
    func testBeginEditingClosesExpandedFolder() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        host.coordinator.beginEditing()
        XCTAssertTrue(
            host.host.waitForFolderTransition(),
            "The panel closing finished"
        )
        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed on entering edit mode")
        XCTAssertTrue(host.host.grid.isScrollEnabled)
        host.coordinator.endEditing()
    }

    /// A drag does not start from the cells of an opened folder's panel:
    /// the panel is a presentation, its place is fixed by the layout.
    func testDragDoesNotStartFromExpandedFolderPanel() throws {
        let host = makeFolderHost()
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        host.coordinator.beginEditing()
        // The host explicitly opens the panel already in edit mode (allowed).
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        let panelItem = try XCTUnwrap(
            host.host.grid.displayItems.first { $0.isFolderPanel }
        )
        let panelCell = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let panelCenter = panelCell.convert(
            CGPoint(x: panelCell.bounds.midX, y: panelCell.bounds.midY),
            to: host.host.grid
        )

        host.coordinator.handleLongPress(on: panelItem, at: panelCenter)

        XCTAssertFalse(host.coordinator.isDragging, "The panel is not dragged")
        XCTAssertEqual(
            host.host.grid.expandedFolderID,
            folderID,
            "The panel stayed open"
        )
        XCTAssertEqual(host.storeIDs, ["a", folderID], "The model is untouched")
        host.coordinator.endEditing()
    }

    // MARK: - External changes during a drag

    /// An external model mutation (unpin from the apps list) during a drag:
    /// the session is cancelled safely, the grid syncs with the model, nothing is
    /// rolled back to a stale base.
    func testExternalModelChangeCancelsDragWithoutStaleRestore() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        // The host changes the model and applies a snapshot while the finger still holds the tile.
        XCTAssertTrue(host.store.unpin("c", columns: host.host.grid.columns))
        host.host.grid.update(snapshot: host.store.snapshot(), animated: false)
        host.host.layout()

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))

        XCTAssertFalse(host.coordinator.isDragging, "The drag is cancelled")
        XCTAssertEqual(host.storeIDs, ["a", "b"], "The model did not roll back to the base")
        XCTAssertEqual(host.gridIDs, host.storeIDs, "The grid is synced with the model")
        XCTAssertTrue(host.host.grid.isScrollEnabled, "Scrolling is restored")
        XCTAssertGreaterThan(alpha(of: AnyHashable("a"), in: host), 0.9, "The cell is visible again")
        XCTAssertTrue(recorder.moves.isEmpty, "The delegate did not receive a move")
        XCTAssertTrue(host.store.autosaves == false, "The bench's autosave did not turn on")
    }

    /// An external `grid.update` bypassing the coordinator (a snapshot missing some items)
    /// also cancels the drag and returns the grid to the model.
    func testExternalGridUpdateCancelsDragAndRestoresModel() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        // A foreign snapshot with the same composition but a shuffled order.
        let reversed = Array(host.store.snapshot().items.reversed())
        host.host.grid.update(
            snapshot: TesseraTileGridSnapshot(items: reversed, unpinned: []),
            animated: false
        )
        host.host.layout()
        XCTAssertEqual(host.gridIDs, reversed.map { $0.id })

        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5)))

        XCTAssertFalse(host.coordinator.isDragging, "The drag is cancelled")
        XCTAssertEqual(host.gridIDs, host.storeIDs, "The model order is restored")
        XCTAssertEqual(host.gridIDs, ["a", "b", "c"])
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    // MARK: - deinit and fly-out

    /// `deinit` of an active drag session returns the hidden cell, scrolling,
    /// autosave and removes the overlays.
    func testDeinitRestoresHiddenCellScrollAndAutosaves() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = true
        store.setCatalog([
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .small),
        ])
        let windowed = TesseraTestWindowedGrid(items: store.snapshot().items)
        windowed.layout()

        var editor: TesseraTileEditCoordinator? = TesseraTileEditCoordinator(
            grid: windowed.grid,
            store: store
        )
        editor?.isReduceMotionEnabled = { false }
        windowed.grid.isReduceMotionEnabled = { false }
        let item = try XCTUnwrap(windowed.grid.items.first { $0.id == AnyHashable("a") })
        let frame = try XCTUnwrap(windowed.grid.frame(forItemID: "a"))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        editor?.handleLongPress(on: item, at: center)

        XCTAssertTrue(try XCTUnwrap(editor).isDragging)
        XCTAssertFalse(store.autosaves, "The drag transaction turned autosave off")
        XCTAssertFalse(windowed.grid.isScrollEnabled, "Scrolling is off during the drag")
        XCTAssertEqual(
            try XCTUnwrap(windowed.cell("a")).contentView.alpha,
            0,
            accuracy: 0.001,
            "The source cell is hidden"
        )

        editor = nil

        XCTAssertTrue(store.autosaves, "Autosave is restored")
        XCTAssertTrue(windowed.grid.isScrollEnabled, "Scrolling is restored")
        XCTAssertEqual(windowed.grid.items.map { $0.id }, store.snapshot().items.map { $0.id })
        XCTAssertEqual(
            try XCTUnwrap(windowed.cell("a")).contentView.alpha,
            1,
            accuracy: 0.001,
            "The hidden cell is returned"
        )
        XCTAssertNil(
            windowed.firstSubview(of: TesseraTilePlaceholderView.self),
            "The placeholder is removed"
        )
        XCTAssertNil(
            windowed.firstSubview(of: TesseraTileDropHighlightView.self),
            "The target highlight is removed"
        )
    }

    /// `deinit` in the middle of a fly-out: the cell is still returned, and the unpin mutation
    /// does not happen (the animation is cancelled).
    func testFlyOutCompletionRestoresCellAfterCoordinatorDeinit() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .small),
        ])
        let windowed = TesseraTestWindowedGrid(items: store.snapshot().items)
        windowed.layout()

        var editor: TesseraTileEditCoordinator? = TesseraTileEditCoordinator(
            grid: windowed.grid,
            store: store
        )
        editor?.isReduceMotionEnabled = { false }
        windowed.grid.isReduceMotionEnabled = { false }
        editor?.unpin("a")
        XCTAssertEqual(
            try XCTUnwrap(windowed.cell("a")).contentView.alpha,
            0,
            accuracy: 0.001,
            "The fly-out hid the cell"
        )

        editor = nil

        XCTAssertTrue(
            windowed.waitUntil {
                (windowed.cell("a")?.contentView.alpha ?? 0) > 0
            },
            "The cell is returned after the coordinator disappears"
        )
        XCTAssertTrue(store.isPinned("a"), "The mutation was not performed — the model is untouched")
        XCTAssertEqual(windowed.grid.items.map { $0.id }.contains(AnyHashable("a")), true)
    }

    // MARK: - Double quick unpin

    /// A repeated unpin during a fly-out starts no second animation, no second
    /// mutation and no second callback.
    func testDoubleUnpinRunsSingleFlyOut() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        host.coordinator.unpin("a")
        let subviewsAfterFirst = Set(host.host.grid.subviews.map { ObjectIdentifier($0) })
        host.coordinator.unpin("a")
        let subviewsAfterSecond = Set(host.host.grid.subviews.map { ObjectIdentifier($0) })
        XCTAssertEqual(
            subviewsAfterFirst,
            subviewsAfterSecond,
            "No second fly-out was created"
        )

        XCTAssertTrue(
            host.waitUntil { recorder.unpins.count == 1 },
            "Exactly one unpin callback"
        )
        XCTAssertEqual(host.storeIDs, ["b"])
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        XCTAssertEqual(host.store.isPinned("a"), false)
    }

    // MARK: - Configuration change on the fly

    /// Changing `controlDiameter`/`jiggleDuration` on the fly recreates the controls and
    /// restarts the jiggle.
    func testConfigurationChangeRebuildsControlsAndJiggle() throws {
        // The jiggle is enabled explicitly — the test checks its restart.
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(isJiggleEnabled: true)
        )
        host.coordinator.beginEditing()
        let firstControl = try XCTUnwrap(host.coordinator.editControls[AnyHashable("a")])
        XCTAssertEqual(firstControl.diameter, 28, accuracy: 0.001)

        var configuration = host.coordinator.configuration
        configuration.controlDiameter = 44
        configuration.jiggleDuration = 0.8
        configuration.jiggleAngle = 2
        host.coordinator.configuration = configuration

        let secondControl = try XCTUnwrap(host.coordinator.editControls[AnyHashable("a")])
        XCTAssertFalse(secondControl === firstControl, "The control is recreated for the new diameter")
        XCTAssertEqual(secondControl.diameter, 44, accuracy: 0.001)

        let animation = try XCTUnwrap(jiggle(of: AnyHashable("a"), in: host))
        let duration = try XCTUnwrap(animation.duration)
        XCTAssertGreaterThanOrEqual(duration, 0.8 * 0.85 - 0.001)
        XCTAssertLessThanOrEqual(duration, 0.8 * 1.15 + 0.001)
        host.coordinator.endEditing()
    }

    // MARK: - Jiggle and dim after unpin/folder creation

    /// After unpin and folder creation the grid reapplies the jiggle and the dim: tiles do not
    /// freeze and do not lose their opacity.
    func testJiggleAndDimmingSurviveUnpinAndFolderCreation() throws {
        // The jiggle is enabled explicitly — the test checks its reapplication after render.
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(isJiggleEnabled: true)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()

        XCTAssertTrue(
            host.waitUntil {
                abs(self.alpha(of: AnyHashable("a"), in: host) - TesseraTileGridView.dimmedTileAlpha) < 0.01
                    && self.jiggle(of: AnyHashable("a"), in: host) != nil
            },
            "Entering edit mode: dim and jiggle"
        )

        host.coordinator.unpin("b")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        XCTAssertTrue(
            host.waitUntil {
                abs(self.alpha(of: AnyHashable("a"), in: host) - TesseraTileGridView.dimmedTileAlpha) < 0.01
                    && self.jiggle(of: AnyHashable("a"), in: host) != nil
            },
            "After unpin the neighboring tile did not freeze or lose its dim"
        )

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "a"))
        // New cells are created in the collection's layout pass — bring it up to date before
        // checking the jiggle/dim on the folder cell.
        host.host.layout()
        XCTAssertTrue(
            host.waitUntil {
                let cell = host.host.cell(folder.id)
                return cell != nil
                    && abs((cell?.contentView.alpha ?? 0) - TesseraTileGridView.dimmedTileAlpha) < 0.01
                    && self.jiggle(of: folder.id, in: host) != nil
            },
            "The folder cell got the dim and the jiggle after reload"
        )
        host.coordinator.endEditing()
    }

    // MARK: - .layoutChanged after unpin/resize

    /// After unpin `.layoutChanged` is posted with focus on the item that took
    /// the removed one's place.
    func testLayoutChangedPostedAfterUnpin() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }

        host.coordinator.unpin("a")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        XCTAssertTrue(host.waitUntil { !posts.isEmpty }, "The notification is posted")
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue(
            (posts.last?.1 as? UIView) === host.host.cell("b"),
            "Focus on the item that took the removed one's place"
        )
    }

    /// After resize `.layoutChanged` is posted with focus on
    /// the changed tile.
    func testLayoutChangedPostedAfterResize() throws {
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small)]
        )
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }

        host.coordinator.beginEditing()
        // In the D28 cycle, small leads to wide (it used to lead to medium).
        XCTAssertEqual(host.coordinator.cycleSize(of: "a"), .wide)
        XCTAssertTrue(host.waitUntil { !posts.isEmpty })
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue(
            (posts.last?.1 as? UIView) === host.host.cell("a"),
            "Focus on the changed tile"
        )
        host.coordinator.endEditing()
    }

    // MARK: - Actual cell from the store

    /// A drop gives the delegate the item's actual cell after
    /// `TesseraTileStore.moveItem(_:toCell:columns:)`, and the grid syncs with the store
    /// snapshot: `a` lands on the cell of `c`, and `c`
    /// is pushed down.
    func testDropReportsActualCellFromStore() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { recorder.moves.count == 1 })
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.cell, TesseraTileGridPlacement(row: 0, column: 2), "The actual cell: the former c")
        XCTAssertEqual(host.store.placement(of: "c"), TesseraTileGridPlacement(row: 1, column: 2), "c is pushed down")
        XCTAssertEqual(host.storeIDs, ["b", "a", "c"])
        XCTAssertEqual(host.gridIDs, host.storeIDs, "The grid is synced with the store")
    }

    /// The public `move(_:toCell:)` clamps the cell to the canvas and gives the delegate
    /// the actual cell, not the requested one.
    func testPublicMoveClampsAndReportsActualCell() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.move("a", toCell: tesseraCell(0, 99)))
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.cell, tesseraCell(0, 3), "The column is clamped by the 4-column canvas")
        XCTAssertEqual(host.storeIDs, ["b", "c", "a"])
        XCTAssertEqual(host.gridIDs, host.storeIDs)
    }

    /// A drop: the grid matches the store snapshot even if pushing down
    /// reshuffled the neighbors; the delegate receives the cell from
    /// the store.
    func testDropSyncsGridWithStoreOrder() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
                tesseraTestTile("T", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.startDrag("S"))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("A", fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { recorder.moves.count == 1 })
        let storeIDs = host.storeIDs
        XCTAssertEqual(host.gridIDs, storeIDs, "The grid matches the store snapshot")
        XCTAssertEqual(
            storeIDs,
            host.store.placementReadingOrder(forColumns: 4),
            "The model order is the cells' reading order"
        )
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("S"))
        XCTAssertEqual(
            recorder.moves.first?.cell,
            host.store.placement(of: "S"),
            "The delegate received the cell from the store"
        )
    }

    // MARK: - Model order = cells' reading order

    /// After unpin the model order stays the cells' reading order: the remaining
    /// items do not move.
    func testUnpinKeepsReadingOrderOfCells() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
                tesseraTestTile("T", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        defer { host.coordinator.endEditing() }

        host.coordinator.unpin("T")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })

        XCTAssertEqual(
            host.storeIDs,
            ["A", "S", "W"],
            "The cells' reading order without the unpinned one"
        )
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
    }

    /// Folder creation keeps the model order equal to
    /// the cells' reading order.
    func testFolderCreationKeepsReadingOrderOfCells() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
            ]
        )
        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "S"))
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.storeIDs, ["A", folder.id, "W"], "Reading order after folder creation")
        XCTAssertEqual(host.storeIDs, host.store.placementReadingOrder(forColumns: 4))
    }

    /// Moving a tile from a folder to the desktop keeps the model order equal to
    /// the cells' reading order and goes through the approval function (D14):
    /// the last tile takes the cell of the vanished folder.
    func testMoveFromFolderToDesktopKeepsReadingOrderOfCells() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
            ],
            prepare: { store, columns in
                _ = store.createFolder(withTile: "S", columns: columns)
            }
        )
        let folderID = try XCTUnwrap(host.firstFolderID)
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.moveBetweenFolders("S", to: nil))
        XCTAssertTrue(host.waitUntil { recorder.folderMoves.count == 1 })
        XCTAssertEqual(host.storeIDs, ["A", "S", "W"], "Reading order after the return")
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.folders.isEmpty, true, "The emptied folder is dissolved")
        XCTAssertFalse(host.storeIDs.contains(folderID))
    }

    /// Taking a tile out of a folder without an index puts the tile on the first free
    /// cell after the folder (next to it), not at the end; the model order is the
    /// cells' reading order. D45: the folder holds three tiles ("a", "b", "e"), and after "b" is taken out
    /// it is left with two.
    func testMoveOutOfFolderLandsAfterFolderThroughCoordinator() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
                tesseraTestTile("d", size: .small),
                tesseraTestTile("e", size: .small),
            ],
            prepare: { store, columns in
                if let folder = store.createFolder(withTile: "a", columns: columns) {
                    _ = store.addToFolder("b", folderID: folder.id, columns: columns)
                    _ = store.addToFolder("e", folderID: folder.id, columns: columns)
                }
            }
        )
        let folderID = try XCTUnwrap(host.firstFolderID)

        let folderCell = try cell(folderID, in: host)
        XCTAssertTrue(host.coordinator.moveBetweenFolders("b", to: nil))
        // A 2×2 folder at (0, 0), "c" and "d" to the right in row 0; the first free
        // cell after the folder is (1, 2), under "c".
        XCTAssertEqual(host.store.placement(of: "b"), TesseraTileGridPlacement(row: folderCell.row + 1, column: 2))
        XCTAssertEqual(host.storeIDs, [folderID, "c", "d", "b"])
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["a", "e"] as [AnyHashable])
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
    }

    // MARK: - Folder screen via onTap

    /// A tap on a tile of the built-in folder screen goes through the shared `grid.onTap` route
    /// (the host performs the action), not by calling `action` directly.
    func testFolderScreenTapRoutesThroughGridOnTap() throws {
        var actionCalls = 0
        var folderTile = TesseraTileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        folderTile.badge = .none
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small), folderTile],
            prepare: { store, columns in
                _ = store.createFolder(withTile: "in-folder", columns: columns)
            }
        )
        var tapped: [TesseraTileGridItem] = []
        host.host.grid.onTap = { tapped.append($0) }

        let folder = try XCTUnwrap(host.folders.first)
        let tile = try XCTUnwrap(folder.tiles.first)
        let screen = TesseraFolderViewController(
            folder: folder,
            store: host.store,
            coordinator: host.coordinator
        )

        XCTAssertTrue(screen.activateTile(tile), "The tap is passed to the coordinator")
        XCTAssertEqual(tapped.count, 1, "The event went to grid.onTap")
        XCTAssertEqual(tapped.first?.tile?.id, tile.id)
        XCTAssertEqual(actionCalls, 0, "The folder screen does not call action directly")
    }

    /// In edit mode the folder screen does not activate a tile.
    func testFolderScreenTapDoesNotActivateInEditMode() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            prepare: { store, columns in
                _ = store.createFolder(withTile: "b", columns: columns)
            }
        )
        var tapped: [TesseraTileGridItem] = []
        host.host.grid.onTap = { tapped.append($0) }
        let folder = try XCTUnwrap(host.folders.first)
        let tile = try XCTUnwrap(folder.tiles.first)

        host.coordinator.beginEditing()
        defer { host.coordinator.endEditing() }

        XCTAssertFalse(host.coordinator.activateTileFromFolder(tile))
        XCTAssertTrue(tapped.isEmpty, "In edit mode the action is not activated")
    }

    // MARK: - Center without a hold = no-op

    /// A drop on a tile's center without a hold returns the tile to its original place,
    /// even if the finger had visited the reorder zone before.
    func testDropOnTileCenterWithoutHoldReturnsToOriginalPlace() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let baseIDs = host.storeIDs
        // The center of "b" is taken from the base layout — after the preview "b" is drawn
        // on the slot of "a", while the zone is decided by the base frame.
        let baseCenterOfB = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))

        XCTAssertTrue(host.startDrag("a"))
        // First — over the edge of c: a placement preview (a on c's cell, c down).
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("c", fx: 0.1, fy: 0.5)))
        host.host.layout()
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(try cell("c", in: host)))

        // Then — the center of b: the merge zone, the hold is not completed.
        host.coordinator.updateDrag(to: baseCenterOfB)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))
        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(host.storeIDs, baseIDs, "The model did not change")
        XCTAssertTrue(recorder.moves.isEmpty)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(
            host.waitUntil { host.host.grid.snapshot?.placementTable == host.store.snapshot(columns: 4).placementTable },
            "The placement preview is removed, the cells returned to the model ones"
        )
        XCTAssertEqual(host.gridIDs, baseIDs)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    // MARK: - Deferred preview while the panel is closing

    /// Prepares a drag on top of an ongoing animated closing of the folder panel.
    ///
    /// The public `beginEditing()` closes the panel with animation; while the transition
    /// runs, the grid defers the preview (`pendingSnapshot`) and does not apply it.
    /// A long press on a tile at this moment starts a drag on the "shifted" layout.
    ///
    /// - Parameter host: A bench with a closed panel.
    /// - Returns: The target folder identifier.
    private func startDragDuringAnimatedFolderClose(
        _ host: TesseraTestDragHost
    ) throws -> AnyHashable {
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()

        host.coordinator.beginEditing()
        XCTAssertTrue(
            host.host.grid.isFolderChangeAnimating,
            "The animated panel closing started"
        )
        XCTAssertNotNil(host.host.grid.expandedFolderID)

        let item = try XCTUnwrap(host.host.grid.items.first { $0.id == AnyHashable("a") })
        host.coordinator.handleLongPress(on: item, at: try XCTUnwrap(host.point("a")))
        XCTAssertTrue(host.coordinator.isDragging)
        XCTAssertTrue(
            host.host.grid.isFolderChangeAnimating,
            "The panel transition is still running — the grid will defer the following previews"
        )

        // A placement preview: the finger is on the folder's edge (the panel is still open — the target
        // is looked up by grid frames, the cell is taken from the base placements).
        host.coordinator.updateDrag(
            to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5))
        )
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell(folderID, in: host))
        )
        return folderID
    }

    /// Cancelling a drag during the animated panel closing leaves no
    /// deferred preview: after the transition the grid equals the model.
    func testCancelDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        host.coordinator.finishDrag(commit: false)
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(
            host.host.grid.items.map { $0.id },
            host.storeIDs,
            "After the transition the grid does not show a stale preview"
        )
        XCTAssertNil(host.host.grid.expandedFolderID)
    }

    /// A no-op drop onto a folder's center (without a hold) during the panel closing also
    /// replaces the deferred preview with a model snapshot.
    func testNoOpCenterDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let folderID = try startDragDuringAnimatedFolderClose(host)

        host.coordinator.updateDrag(
            to: try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5))
        )
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(folderID))

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID], "No-op: the model did not change")
    }

    /// `endEditing()` during the panel closing does not leave the grid with a preview
    /// after the transition finishes.
    func testEndEditingDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isEditing)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.host.grid.items.map { $0.id }, host.storeIDs)
    }

    /// A long press with an open panel closes it instantly, the drag starts
    /// on the regular layout, and the drop after that syncs the grid and the model.
    func testLongPressClosesExpandedFolderInstantlyAndDropStaysConsistent() throws {
        let host = makeFolderHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        let item = try XCTUnwrap(host.host.grid.items.first { $0.id == AnyHashable("a") })
        host.coordinator.handleLongPress(on: item, at: try XCTUnwrap(host.point("a")))

        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed instantly")
        XCTAssertFalse(host.host.grid.isFolderChangeAnimating)
        XCTAssertTrue(host.coordinator.isDragging)

        host.host.layout()
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { recorder.moves.count == 1 })
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID], "a is on the folder's cell, the folder is below")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
    }

    // MARK: - Synchronous host onChange

    /// The public `move` computes the order change BEFORE the mutation: if the host
    /// applies `store.onChange` to the grid synchronously, `didMove` and `.layoutChanged`
    /// still arrive, and the method returns `true`.
    func testPublicMoveWithSynchronousStoreOnChangeReportsMove() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ]
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }
        // The host as in the Example: the store snapshot is applied to the grid synchronously.
        // Only the grid is captured (not host/store) — there is no "store → onChange →
        // host → store" cycle.
        let grid = host.host.grid
        host.store.onChange = { snapshot in
            grid.update(snapshot: snapshot, animated: false)
        }

        XCTAssertTrue(host.coordinator.move("a", toCell: tesseraCell(0, 3)), "The layout changed")
        XCTAssertEqual(recorder.moves.count, 1, "didMove arrived despite the synchronous onChange")
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("a"))
        XCTAssertEqual(recorder.moves.first?.cell, tesseraCell(0, 3), "The actual cell")
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        XCTAssertTrue(host.waitUntil { !posts.isEmpty }, ".layoutChanged is posted")
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
    }

    // MARK: - Folder screen, fallback without a coordinator

    /// If the coordinator/grid is gone, the folder screen performs the tile's action
    /// directly (the fallback) instead of losing the tap.
    func testFolderScreenFallbackActionWithoutCoordinator() throws {
        var actionCalls = 0
        let folderTile = TesseraTileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small), folderTile],
            prepare: { store, columns in
                _ = store.createFolder(withTile: "in-folder", columns: columns)
            }
        )
        let folder = try XCTUnwrap(host.folders.first)
        let tile = try XCTUnwrap(folder.tiles.first)

        // The temporary coordinator lives only for the screen's initialization:
        // the weak reference in the controller becomes nil.
        var temporaryCoordinator: TesseraTileEditCoordinator? = TesseraTileEditCoordinator(
            grid: host.host.grid,
            store: host.store
        )
        let screen = TesseraFolderViewController(
            folder: folder,
            store: host.store,
            coordinator: try XCTUnwrap(temporaryCoordinator)
        )
        temporaryCoordinator = nil

        screen.performActivation(tile)
        XCTAssertEqual(actionCalls, 1, "The fallback performed the tile's action")
    }

    // MARK: - Bounds of the central zone

    /// Bounds of the merge entry zone (`TesseraTileMergeZone.entryRect`):
    /// half-open — the left/top bounds are inclusive, the right/bottom ones are not.
    /// The zone is `max(50 %, 36 pt)` along the axis (on this grid
    /// that is the former half of the frame), and after entering, the target is held by hysteresis.
    /// The right/bottom bounds are checked from a clean state (`.cell`), otherwise
    /// the merge hold (6 pt from the edge) would not release them.
    func testDropCenterZoneBoundariesAreHalfOpen() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("a"))
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let central = TesseraTileMergeZone.entryRect(in: frame)
        XCTAssertEqual(central.width, frame.width / 2, accuracy: 0.5, "Control: on this grid the zone is half the frame")

        // The right bound is already outside the entry zone.
        host.coordinator.updateDrag(to: CGPoint(x: central.maxX, y: central.midY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("b", in: host))
        )
        // The zone is decided by the BASE frame of "b" (it does not shift along with the
        // preview), so the bottom bound is computed from the same `frame`/`central`.
        host.coordinator.updateDrag(to: CGPoint(x: central.midX, y: central.maxY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("b", in: host))
        )

        // The left and top bounds are inclusive.
        host.coordinator.updateDrag(to: CGPoint(x: central.minX, y: central.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))
        host.coordinator.updateDrag(to: CGPoint(x: central.midX, y: central.minY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))

        // Hysteresis: already on the merge target, 1 pt beyond the zone's bound —
        // still a merge (the hold area is wider than the entry one).
        host.coordinator.updateDrag(to: CGPoint(x: central.minX - 1, y: central.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group(AnyHashable("b")))
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    // MARK: - Magnet in RTL and with Reduce Motion

    /// In RTL the magnet computes slot centers with the same geometry and attracts the snapshot
    /// to the slot's center: the layout mirrors, not the computation.
    func testMagnetUsesSlotCentersInRTL() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<8).map { tesseraTestTile("s\($0)", size: .small) },
            configuration: TesseraTileEditConfiguration(
                magnetSnapRadius: 40,
                magnetSpringDuration: 0
            )
        )
        // The direction is set on the collection directly: the layout reads it
        // `effectiveUserInterfaceLayoutDirection`.
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.grid.invalidateTileLayout(animated: false)
        host.host.layout()

        // The columns really are mirrored: s0 is to the right of s3.
        let firstFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "s0"))
        let thirdFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "s3"))
        XCTAssertGreaterThan(
            firstFrame.minX,
            thirdFrame.minX,
            "RTL mirrors the layout's columns"
        )

        XCTAssertTrue(host.startDrag("s0", fx: 0.9, fy: 0.9))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        session.hasLeftOriginSlot = true
        // The attraction is to the target cell's frame. The last center in the list
        // (bottom right on screen) in RTL is the logical cell (1, 0): column 0
        // is the start of reading, that is, the right edge.
        session.hover = .cell(TesseraTileGridPlacement(row: 1, column: 0))

        let centers = host.host.grid.magnetSlotCenters(for: .small)
        XCTAssertEqual(centers.count, 8, "Two rows of four small slots")
        let target = try XCTUnwrap(centers.last)
        let point = CGPoint(
            x: target.x - session.grabOffset.x,
            y: target.y - session.grabOffset.y
        )
        XCTAssertEqual(
            host.coordinator.dragMagnetTargetForTesting(at: point),
            target,
            "The snapshot center on the slot — attraction to it in RTL"
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("s0"))
    }

    /// With Reduce Motion the magnet is disabled entirely.
    func testMagnetDisabledByReduceMotion() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ]
        )
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.isReduceMotionEnabled = { true }
        XCTAssertTrue(host.startDrag("a", fx: 0.9, fy: 0.9))
        let session = try XCTUnwrap(host.coordinator.dragSession)
        session.hasLeftOriginSlot = true
        session.hover = .none

        let centers = host.host.grid.magnetSlotCenters(for: .small)
        let target = try XCTUnwrap(centers.last)
        let point = CGPoint(
            x: target.x - session.grabOffset.x,
            y: target.y - session.grabOffset.y
        )
        XCTAssertNil(
            host.coordinator.dragMagnetTargetForTesting(at: point),
            "Reduce Motion disables the attraction"
        )
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    // MARK: - .layoutChanged after folder operations

    /// After folder creation `.layoutChanged` is posted with focus
    /// on its cell.
    func testLayoutChangedPostedAfterFolderCreation() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("A", size: .medium),
                tesseraTestTile("W", size: .wide),
                tesseraTestTile("S", size: .small),
            ]
        )
        var posts: [(UIAccessibility.Notification, Any?)] = []
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.append((notification, argument))
        }

        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "S"))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { !posts.isEmpty })
        XCTAssertEqual(posts.last?.0, UIAccessibility.Notification.layoutChanged)
        XCTAssertTrue(
            (posts.last?.1 as? UIView) === host.host.cell(folder.id),
            "Focus on the created folder's cell"
        )
    }
    /// A drop "in place" (the host released the tile, the order did not change) during
    /// the panel closing: the default branch of `finishDrag` syncs the grid with
    /// the model, and the deferred preview is not applied after the transition.
    func testDropInPlaceDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        // Move the finger to an empty spot: the target is `.none`, the drop fixes the index
        // "in place" (the default branch of finishDrag).
        host.coordinator.updateDrag(to: CGPoint(x: 10, y: 700))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.none)
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.host.grid.items.map { $0.id }, host.storeIDs)
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), try XCTUnwrap(host.firstFolderID)])
    }

    /// The app going to the background during the panel closing cancels the drag and also does not
    /// leave a deferred preview (the background is the cancelDragImmediately path).
    func testBackgroundDuringAnimatedFolderCloseReplacesDeferredPreview() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        _ = try startDragDuringAnimatedFolderClose(host)

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.host.grid.items.map { $0.id }, host.storeIDs)
    }

    // MARK: - Drop over an opened folder panel — no-op

    /// A drop over an opened folder's panel does not commit the last push preview:
    /// the host opens the panel during the drag, and releasing returns the tile to its
    /// original place.
    func testDropOverExpandedFolderPanelIsNoOp() throws {
        // No dwell before the preview, otherwise the push-out preview would not have time
        // to appear before the host opens the panel.
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0, reorderPreviewDwell: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        XCTAssertTrue(host.startDrag("a"))
        // A placement preview: the tile lands on the folder's cell, the folder goes down.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell(folderID, in: host))
        )
        let modelTable = host.store.snapshot(columns: 4).placementTable
        XCTAssertNotEqual(host.host.grid.snapshot?.placementTable, modelTable, "The preview differs from the model")

        // The host opens the panel during the drag (a long press would have closed it).
        host.host.grid.openFolder(folder, animated: true)
        XCTAssertTrue(host.host.waitForFolderTransition())
        host.host.layout()
        let panelCell = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let panelPoint = panelCell.convert(
            CGPoint(x: panelCell.bounds.midX, y: panelCell.bounds.midY),
            to: host.host.grid
        )

        host.coordinator.updateDrag(to: panelPoint)
        XCTAssertTrue(
            host.coordinator.dragSession?.isOverFolderPanel == true,
            "The \"over the panel\" flag is set"
        )
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            HoverTarget.none,
            "The panel is not a drop target"
        )
        XCTAssertEqual(
            host.host.grid.snapshot?.placementTable,
            modelTable,
            "Over the panel the preview returns to the base layout: there is nothing to commit"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { host.host.grid.snapshot?.placementTable == modelTable })
        XCTAssertEqual(
            host.storeIDs,
            [AnyHashable("a"), folderID],
            "The store did not change: a drop over the panel is a no-op"
        )
        XCTAssertTrue(recorder.moves.isEmpty, "didMove did not arrive")
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(host.waitForDragCleanup("a"))
        XCTAssertEqual(
            host.host.grid.expandedFolderID,
            folderID,
            "The panel stays open — the drop does not close it"
        )
    }

    /// A panel opened by the host already **under the finger** (without a drag step after
    /// opening) also gives a no-op on release: the flag is checked against
    /// the last point, not only the last `updateDrag`.
    func testDropOverPanelOpenedUnderFingerIsNoOp() throws {
        let host = makeFolderHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let folderID = try XCTUnwrap(host.firstFolderID)
        let folder = try XCTUnwrap(host.folders.first)

        // Remember the panel center's coordinates in the same layout, then
        // close it: during the drag the panel will open in the same place.
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panelCell = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let panelPoint = panelCell.convert(
            CGPoint(x: panelCell.bounds.midX, y: panelCell.bounds.midY),
            to: host.host.grid
        )
        host.host.grid.closeFolder(animated: false)
        host.host.layout()

        XCTAssertTrue(host.startDrag("a"))
        // A placement preview, then the finger to an empty spot where the panel will appear.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5)))
        host.coordinator.updateDrag(to: panelPoint)
        // Below the last occupied row the target is a "new row"; there is no panel
        // under the finger yet.
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.newRow)
        XCTAssertFalse(host.coordinator.dragSession?.isOverFolderPanel == true)

        // The panel appears under the finger without a new drag step.
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.storeIDs, [AnyHashable("a"), folderID])
        XCTAssertTrue(recorder.moves.isEmpty, "didMove did not arrive")
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }


    // MARK: - Drag of a tile from a folder panel

    /// A delegate implementing only the cell callback: `didMove(toFolder:)`
    /// is not called in this case (exactly one of the two).
    private final class IndexedMoveRecorder: TesseraTileEditCoordinatorDelegate {

        /// `didMove(toFolder:atCell:)` events.
        var moves: [(id: AnyHashable, folder: AnyHashable?, cell: TesseraTileGridPlacement?)] = []

        /// `didDissolveFolder` events (D45).
        var dissolutions: [(folder: AnyHashable, remaining: AnyHashable)] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TesseraTileGridPlacement?
        ) {
            moves.append((tileID, folderID, cell))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            dissolutions.append((folderID, tileID))
        }
    }

    /// The bench: the grid order is "a", folder F1 ("b", "c", "g"), "d", folder F2
    /// ("e", "h"). D45: F1 holds three tiles (taking one out leaves the folder), F2 holds two
    /// (taking one out dissolves it; previously F2 held a single "e" and F1 two).
    private func makePanelHost(
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0
        )
    ) throws -> TesseraTestDragHost {
        // A compact layout as before the cell-based model (`packed`); folders are small:
        // the geometry of these tests is computed for small folder tiles.
        try TesseraTestDragHost(
            packed: [
                .tile("a", .small),
                .folder("F1", .small, [("b", .small), ("c", .small), ("g", .small)]),
                .tile("d", .small),
                .folder("F2", .small, [("e", .small), ("h", .small)]),
            ],
            configuration: configuration
        )
    }

    /// The bench's folder identifiers in order: (F1, F2).
    private func panelHostFolderIDs(_ host: TesseraTestDragHost) throws -> (AnyHashable, AnyHashable) {
        let folders = host.folders
        XCTAssertEqual(folders.count, 2)
        return (try XCTUnwrap(folders.first).id, try XCTUnwrap(folders.last).id)
    }

    /// Enters edit mode, opens the folder panel and starts dragging a panel icon.
    ///
    /// - Returns: The grab point in grid coordinates.
    @discardableResult
    private func startPanelDrag(
        _ host: TesseraTestDragHost,
        folderID: AnyHashable,
        iconIndex: Int,
        grab: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) throws -> CGPoint {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        // `grab` is a fraction of the icon's frame (grabbing by the center and by the edges).
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        let point = CGPoint(
            x: iconFrame.minX + iconFrame.width * grab.x,
            y: iconFrame.minY + iconFrame.height * grab.y
        )

        // A long press on a panel tile now starts a reorder
        // inside the panel; these scenarios test take-out, so they enter it
        // directly (the "finger left the panel" transition is covered by TilePanelDragReorderTests).
        host.coordinator.startDragFromPanel(at: point)
        return point
    }

    /// A point in the empty area of the grid (the bottom right corner, below all tiles).
    private func emptyPoint(in host: TesseraTestDragHost) -> CGPoint {
        let bounds = host.host.grid.bounds
        return CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3)
    }

    /// A long press on a panel icon in edit mode: the panel closes instantly,
    /// a drag starts with the folder as the source; the model does not change during the drag,
    /// the grid shows the displayed snapshot with the tile after the folder.
    func testLongPressOnPanelIconStartsDragFromFolder() throws {
        let host = try makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        let before = host.storeIDs

        try startPanelDrag(host, folderID: f1, iconIndex: 1)

        XCTAssertTrue(host.coordinator.isDragging)
        let session = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertEqual(session.sourceFolderID, f1)
        XCTAssertEqual(session.itemID, AnyHashable("c"))
        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed instantly")
        XCTAssertFalse(host.host.grid.isFolderChangeAnimating)
        XCTAssertEqual(host.storeIDs, before, "The model does not change during the drag")
        XCTAssertEqual(
            host.gridIDs,
            ["a", f1, "d", host.folders[1].id, "c"] as [AnyHashable],
            "The synthetic tile is on the first free cell after the folder (row 1); the grid order is the cells' reading order"
        )
        XCTAssertEqual(
            host.folders.first?.tiles.map { $0.id },
            ["b", "c", "g"] as [AnyHashable],
            "The folder's composition in the model is unchanged"
        )
        host.coordinator.endEditing()
        XCTAssertEqual(host.gridIDs, before, "Cancel returns the model order to the grid")
    }

    /// Take-out onto the grid: the tile lands on the preview cell, the delegate receives
    /// `didMove(toFolder: nil, atCell:)`, the old callback is not called.
    func testDropOutOfFolderLandsAtPreviewCell() throws {
        let host = try makePanelHost()
        let recorder = IndexedMoveRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)
        let aFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "a"))
        let aCell = try cell("a", in: host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.1, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(aCell))
        // The push-out preview of "a" — after a 0.2 s dwell, on the cell.
        XCTAssertTrue(host.waitUntil { host.host.grid.frame(forItemID: "c") == aFrame }, "Preview: the tile is on the target's place")
        XCTAssertEqual(
            host.host.grid.frame(forItemID: "c"),
            aFrame,
            "Preview: the tile is on the target's place"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("c"))
        XCTAssertNil(recorder.moves.first?.folder ?? nil)
        XCTAssertEqual(recorder.moves.first?.cell, aCell)
        XCTAssertEqual(host.storeIDs.first, AnyHashable("c"))
        XCTAssertEqual(host.store.placement(of: "c"), aCell)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "g"] as [AnyHashable])
        XCTAssertTrue(recorder.dissolutions.isEmpty, "The three-tile folder did not dissolve")
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("c"))
        XCTAssertNil(host.coordinator.dragSession)
        // The frame the snapshot flies to is the frame of the tile taken out, after render.
        XCTAssertNotNil(host.host.grid.frame(forItemID: "c"))
    }

    /// Taking out one of two tiles (D45): the folder is dissolved, the remaining "h" takes
    /// its place, the tile taken out "e" goes to a new row; the delegate receives the resulting
    /// cell of the tile and then `didDissolveFolder`.
    func testDropOfOneOfTwoTilesDissolvesFolderAndReportsCell() throws {
        let host = try makePanelHost()
        let recorder = IndexedMoveRecorder()
        host.coordinator.delegate = recorder
        let (_, f2) = try panelHostFolderIDs(host)
        let folderCell = try XCTUnwrap(host.store.placement(of: f2))

        try startPanelDrag(host, folderID: f2, iconIndex: 0)
        XCTAssertEqual(host.coordinator.dragSession?.sourceFolderID, f2)
        // Empty space below the tiles: the target is a "new row".
        host.coordinator.updateDrag(to: emptyPoint(in: host))
        XCTAssertEqual(host.coordinator.dragSession?.hover, HoverTarget.newRow)

        host.coordinator.finishDrag(commit: true)

        XCTAssertFalse(host.storeIDs.contains(f2), "The folder dissolved")
        XCTAssertEqual(host.store.placement(of: "h"), folderCell, "The remaining tile is on the folder's place")
        XCTAssertEqual(host.storeIDs.last, AnyHashable("e"), "The tile taken out is in a new row")
        XCTAssertEqual(host.store.placement(of: "e")?.column, 0)
        XCTAssertEqual(recorder.moves.first?.cell, host.store.placement(of: "e"))
        XCTAssertEqual(recorder.dissolutions.count, 1)
        XCTAssertEqual(recorder.dissolutions.first?.folder, f2)
        XCTAssertEqual(recorder.dissolutions.first?.remaining, AnyHashable("h"))
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitForDragCleanup("e"))
    }

    /// A move to another folder: the center of the target folder with a completed hold.
    /// The old callback works too (a delegate unaware of the index).
    func testDropOnOtherFolderCenterAfterHoldMovesTile() throws {
        let host = try makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, f2) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(f2, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "The hold over the center of another folder is completed"
        )

        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(recorder.folderMoves.count, 1, "The old callback received the event")
        XCTAssertEqual(recorder.folderMoves.first?.id, AnyHashable("c"))
        XCTAssertEqual(recorder.folderMoves.first?.folder, f2)
        XCTAssertEqual(host.folders.first { $0.id == f1 }?.tiles.map { $0.id }, ["b", "g"] as [AnyHashable])
        XCTAssertEqual(host.folders.first { $0.id == f2 }?.tiles.map { $0.id }, ["e", "h", "c"] as [AnyHashable])
        let target = try XCTUnwrap(host.coordinator.lastCollapseTargetFrame)
        XCTAssertEqual(target, host.host.grid.frame(forItemID: f2), "The flight is into the target folder's frame")
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
    }

    /// Without a hold a drop on the center of another folder is a no-op: the model is untouched,
    /// there are no callbacks, and the grid returns to the model order.
    func testDropOnOtherFolderCenterWithoutHoldIsNoOp() throws {
        let host = try makePanelHost(
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, f2) = try panelHostFolderIDs(host)
        let before = host.storeIDs

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(f2, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.mergeTracker?.isMergeReady, false)
        host.coordinator.finishDrag(commit: true)

        XCTAssertEqual(host.storeIDs, before)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "c", "g"] as [AnyHashable])
        XCTAssertTrue(recorder.folderMoves.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertTrue(host.waitUntil { host.gridIDs == before })
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
    }

    /// The center of the home folder (even with a completed hold) and a cancelled gesture
    /// return the tile: the model and the delegate are not affected.
    func testDropOnSourceFolderCenterAndCancelLeaveModelUntouched() throws {
        let host = try makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)
        let before = host.storeIDs

        // The center of the home folder.
        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(f1, fx: 0.5, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .sourceFolder)
        host.spin(0.12)
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == before })
        XCTAssertEqual(host.storeIDs, before)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "c", "g"] as [AnyHashable])

        // Cancel after the preview.
        try startPanelDrag(host, folderID: f1, iconIndex: 0)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.1, fy: 0.5)))
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == before })
        XCTAssertEqual(host.storeIDs, before)
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["b", "c", "g"] as [AnyHashable])

        XCTAssertTrue(recorder.folderMoves.isEmpty)
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertTrue(recorder.moves.isEmpty)
    }

    /// The center of an ordinary tile does not create a folder for a tile from a folder: it works
    /// as a placement onto its cell (take-out onto the grid).
    func testCenterOfPlainTileDoesNotCreateFolderForFolderSource() throws {
        let host = try makePanelHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        let (f1, _) = try panelHostFolderIDs(host)

        try startPanelDrag(host, folderID: f1, iconIndex: 1)
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5)))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell("a", in: host)),
            "A tile's center — placement onto its cell, not grouping"
        )
        host.spin(0.12)
        host.coordinator.finishDrag(commit: true)

        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertEqual(recorder.folderMoves.count, 1)
        XCTAssertEqual(host.folders.count, 2)
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
    }

    /// A long press on the panel's heading/background does not start a drag in edit mode.
    func testLongPressOnPanelBackgroundDoesNotStartDrag() throws {
        let host = try makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        host.coordinator.beginEditing()
        host.host.grid.openFolder(try XCTUnwrap(host.folders.first), animated: false)
        host.host.layout()
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let panel = try XCTUnwrap(host.host.panelCell(folderID: f1))
        let point = panel.convert(CGPoint(x: panel.bounds.midX, y: 8), to: host.host.grid)

        host.coordinator.handleLongPress(on: panelItem, at: point)

        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertEqual(host.host.grid.expandedFolderID, f1, "The panel stayed open")
        host.coordinator.endEditing()
    }

    /// A tap on a folder in edit mode opens the native panel, edit
    /// mode is not interrupted, and `onTap` arrives.
    func testTapOnFolderInEditModeOpensPanelWithoutLeavingEdit() throws {
        let host = try makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        var tapped: [AnyHashable] = []
        host.host.grid.onTap = { tapped.append($0.id) }
        host.coordinator.beginEditing()

        let collectionView = try XCTUnwrap(host.host.collectionView)
        let index = try XCTUnwrap(host.host.grid.displayItems.firstIndex { $0.id == f1 })
        host.host.grid.collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))

        XCTAssertEqual(host.host.grid.expandedFolderID, f1)
        XCTAssertTrue(host.coordinator.isEditing)
        XCTAssertEqual(tapped, [f1])
        host.coordinator.endEditing()
    }

    /// The `folderTapHandler` interceptor works in edit mode as outside it: `true`
    /// cancels the expansion and `onTap`.
    func testFolderTapHandlerInterceptsInEditMode() throws {
        let host = try makePanelHost()
        let (f1, _) = try panelHostFolderIDs(host)
        var tapped = 0
        var intercepted = 0
        host.host.grid.onTap = { _ in tapped += 1 }
        host.host.grid.folderTapHandler = { _ in
            intercepted += 1
            return true
        }
        host.coordinator.beginEditing()

        let collectionView = try XCTUnwrap(host.host.collectionView)
        let index = try XCTUnwrap(host.host.grid.displayItems.firstIndex { $0.id == f1 })
        host.host.grid.collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))

        XCTAssertEqual(intercepted, 1)
        XCTAssertEqual(tapped, 0)
        XCTAssertNil(host.host.grid.expandedFolderID)
        host.coordinator.endEditing()
    }


    // MARK: - Atomic folder creation

    /// A drop on a tile's center with a completed hold.
    private func dropOnCenterAfterHold(_ host: TesseraTestDragHost, dragged: AnyHashable, target: AnyHashable) throws {
        XCTAssertTrue(host.startDrag(dragged))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point(target, fx: 0.5, fy: 0.5)))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "The hold over the tile's center is completed"
        )
        host.coordinator.finishDrag(commit: true)
    }

    /// A failure of the second step (`addToFolder`) rolls back the folder creation: the model and
    /// the grid are as before the drop, the delegate receives only `didFailGrouping`
    /// (without `didCreateFolder`/`didAdd`), and the host receives no `onChange` for
    /// the intermediate state or for the rollback.
    func testDeniedSecondStepRollsBackFolderCreation() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("x", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .addToFolder }
        let before = host.storeIDs
        var changeCount = 0
        host.store.onChange = { _ in changeCount += 1 }

        try dropOnCenterAfterHold(host, dragged: "a", target: "b")

        XCTAssertTrue(host.waitUntil { recorder.failures.count == 1 })
        XCTAssertEqual(recorder.failures, [.addToFolder])
        XCTAssertTrue(recorder.createdFolders.isEmpty, "didCreateFolder is not sent")
        XCTAssertTrue(recorder.additions.isEmpty)
        XCTAssertEqual(host.storeIDs, before, "The model order is unchanged")
        XCTAssertTrue(host.folders.isEmpty, "There is no folder record")
        XCTAssertEqual(host.store.snapshot().items.map { $0.id }, before)
        XCTAssertEqual(changeCount, 0, "Neither an intermediate state nor a rollback")
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertEqual(host.gridIDs, before, "The grid is as before the drop")
    }

    /// The rollback returns the target tile to its place and keeps its size.
    func testRollbackKeepsTargetSizeAndPosition() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .wide),
            ],
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: 0
            )
        )
        host.store.approval = { _, _, action in action != .addToFolder }
        let before = host.store.snapshot()

        let result = host.store.createFolder(from: "a", onto: "b", columns: 4)
        guard case .addDenied = result else {
            return XCTFail("Expected a rollback of the second step, got \(result)")
        }
        let after = host.store.snapshot()
        XCTAssertEqual(after.items.map { $0.id }, before.items.map { $0.id })
        XCTAssertEqual(after.items.last?.tile?.size, .wide)
        XCTAssertTrue(after.folders.isEmpty)
        // The store stays operational: creating again after the prohibition is lifted.
        host.store.approval = { _, _, _ in true }
        guard case .created(let folder) = host.store.createFolder(from: "a", onto: "b", columns: 4) else {
            return XCTFail("Creating again must succeed")
        }
        XCTAssertEqual(folder.tiles.map { $0.id }, ["b", "a"] as [AnyHashable])
    }

    /// A failure of the first step: the delegate receives `didFailGrouping(.createFolder)`,
    /// the model is untouched.
    func testDeniedFirstStepLeavesModelUntouched() throws {
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("a", size: .small), tesseraTestTile("b", size: .small)],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05, magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .createFolder }
        let before = host.storeIDs

        try dropOnCenterAfterHold(host, dragged: "a", target: "b")

        XCTAssertTrue(host.waitUntil { recorder.failures.count == 1 })
        XCTAssertEqual(recorder.failures, [.createFolder])
        XCTAssertTrue(recorder.createdFolders.isEmpty)
        XCTAssertEqual(host.storeIDs, before)
    }

    /// Success: `didCreateFolder` arrives after both steps and strictly before
    /// `didAdd`; the host's `onChange` fires once.
    func testSuccessfulCreationSendsCreateThenAddAfterBothSteps() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05, magnetSnapRadius: 0)
        )
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        var changeCount = 0
        host.store.onChange = { _ in changeCount += 1 }

        try dropOnCenterAfterHold(host, dragged: "a", target: "b")

        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        XCTAssertEqual(recorder.folderEventLog, ["create", "add"])
        XCTAssertEqual(recorder.createdFolders.first?.tiles.map { $0.id }, ["b", "a"] as [AnyHashable],
                       "By the time of didCreateFolder the folder holds both tiles")
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(changeCount, 1, "One notification per operation")
        XCTAssertEqual(host.folders.count, 1)
    }

    // MARK: - Taking the only tile out into a hole

    /// The bench (4 columns): `s0` (col. 0), folder "Work" with two tiles
    /// `mail`, `mail2` (col. 1; D45: a one-tile folder does not exist, taking out
    /// `mail` dissolves it), a medium `cal` (cols 2–3), folder B of `m`,`n`,`p` — in
    /// the model a hole remains at the lower left under "Work".
    private func makeMoveOutHost(columns: Int = 4, magnet: CGFloat = 0) throws -> TesseraTestDragHost {
        // A compact layout as before the cell-based model (`packed`): new folders are medium.
        try TesseraTestDragHost(
            packed: [
                .tile("s0", .small),
                .folder("Work", .medium, [("mail", .small), ("mail2", .small)]),
                .tile("cal", .medium),
                .folder("B", .medium, [("m", .small), ("n", .small), ("p", .small)]),
            ],
            columns: columns,
            configuration: TesseraTileEditConfiguration(
                mergeHoverDuration: 0.05,
                magnetSnapRadius: magnet
            )
        )
    }

    /// The center point of the cell "row 1, column 1" of the model layout (under "Work").
    private func moveOutHolePoint(_ host: TesseraTestDragHost, work: AnyHashable) throws -> CGPoint {
        let s0 = try XCTUnwrap(host.host.grid.frame(forItemID: "s0"))
        let workFrame = try XCTUnwrap(host.host.grid.frame(forItemID: work))
        let gap = workFrame.minX - s0.maxX
        return CGPoint(x: workFrame.midX, y: workFrame.midY + workFrame.height + gap)
    }

    /// Checks the take-out outcome: "Work" is dissolved (D45: `mail2` remained), `mail` is
    /// an ordinary tile, B is intact.
    private func assertMailIsPlainTile(
        _ host: TesseraTestDragHost,
        folderB: AnyHashable,
        work: AnyHashable,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(host.storeIDs.contains(work), "Work dissolved: \(message)", file: file, line: line)
        XCTAssertTrue(host.storeIDs.contains("mail"), "mail is an ordinary grid tile: \(message)", file: file, line: line)
        XCTAssertTrue(host.storeIDs.contains("mail2"), "mail2 took the folder's place: \(message)", file: file, line: line)
        XCTAssertEqual(
            host.folders.first { $0.id == folderB }?.tiles.map { $0.id },
            ["m", "n", "p"] as [AnyHashable],
            "The composition of folder B did not change: \(message)",
            file: file,
            line: line
        )
    }

    /// Not reproduced manually: taking the only tile out into a model "hole"
    /// with a ~0.8 s hold does not put it into the neighboring folder B — at 4, nor
    /// at 5/6 columns. The displayed snapshot (an empty "Work" + a synthetic
    /// tile) rebuilds the packing: the medium and B move away, and the point above the model's
    /// "hole" lands on the tile that took its place in the base layout — this is
    /// a reorder, not a merge.
    func testDropOfSoleFolderTileIntoModelHoleNeverEntersNeighborFolder() throws {
        for columns in [4, 5, 6] {
            let host = try makeMoveOutHost(columns: columns)
            let (work, folderB) = try panelHostFolderIDs(host)
            let hole = try moveOutHolePoint(host, work: work)

            try startPanelDrag(host, folderID: work, iconIndex: 0)
            host.coordinator.updateDrag(to: hole)
            host.spin(0.12) // the hold in the test is 0.05 s
            XCTAssertNotEqual(
                host.coordinator.dragSession?.hover,
                .folder(folderB),
                "cols=\(columns): above the model's hole the target is not folder B"
            )
            XCTAssertNotEqual(host.coordinator.mergeTracker?.isMergeReady, true, "cols=\(columns)")
            host.coordinator.finishDrag(commit: true)
            host.spin(0.3)
            assertMailIsPlainTile(host, folderB: folderB, work: work, "cols=\(columns)")
        }
    }

    /// A hold armed (and even completed) over B does not survive the finger
    /// leaving — a drop in the "hole" after it is not a merge. Covered: leaving to an empty
    /// spot, to the edge zone of B itself (within its frame) and to the "hole".
    func testHoldOverNeighborFolderDoesNotSurviveMovingAway() throws {
        for columns in [4, 5, 6] {
            for waitForFire in [false, true] {
                let host = try makeMoveOutHost(columns: columns)
                let (work, folderB) = try panelHostFolderIDs(host)
                let hole = try moveOutHolePoint(host, work: work)
                let empty = emptyPoint(in: host)

                try startPanelDrag(host, folderID: work, iconIndex: 0)
                let session = try XCTUnwrap(host.coordinator.dragSession)
                // The center of B in the base layout (it differs from the model one).
                let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
                let bFrame = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[folderB]))

                host.coordinator.updateDrag(to: CGPoint(x: bFrame.midX, y: bFrame.midY))
                XCTAssertEqual(session.hover, .folder(folderB), "cols=\(columns): the finger is over B's center")
                if waitForFire {
                    XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
                }

                for away in [
                    CGPoint(x: bFrame.minX + 2, y: bFrame.midY), // the edge of B itself
                    hole,
                    empty
                ] {
                    host.coordinator.updateDrag(to: away)
                    XCTAssertNotEqual(session.hover, .folder(folderB), "cols=\(columns) \(away)")
                    XCTAssertNil(host.coordinator.mergeTracker, "The hold is reset on leaving: cols=\(columns) \(away)")
                    // Returning to B's center is a new countdown, not "already ready".
                    host.coordinator.updateDrag(to: CGPoint(x: bFrame.midX, y: bFrame.midY))
                    XCTAssertEqual(host.coordinator.mergeTracker?.isMergeReady, false, "cols=\(columns) \(away)")
                }

                host.coordinator.updateDrag(to: hole)
                host.coordinator.finishDrag(commit: true)
                host.spin(0.3)
                assertMailIsPlainTile(host, folderB: folderB, work: work, "cols=\(columns) fire=\(waitForFire)")
            }
        }
    }

    // MARK: - Hit test by the base layout

    /// The bench: a row `a b c d` (small) and a folder F (small) with tiles `f`, `g`
    /// in the second row, 4 columns.
    private func makeBaseHitHost() throws -> TesseraTestDragHost {
        // A compact layout as before the cell-based model (`packed`); the folder is small.
        try TesseraTestDragHost(
            packed: [
                .tile("a", .small), .tile("b", .small), .tile("c", .small), .tile("d", .small),
                .folder("F", .small, [("f", .small), ("g", .small)]),
            ],
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
    }

    /// Reproduction: a folder that moved out from under the finger because of a placement preview
    /// stays the target by the base frame — the center is reachable when approaching in
    /// the direction of the shift, and the preview then returns to the base layout: the target
    /// stays under the finger, and the highlight is drawn on it.
    func testFolderCenterReachableAfterPreviewShiftedItAway() throws {
        let host = try makeBaseHitHost()
        let folderID = try XCTUnwrap(host.firstFolderID)
        let baseCenter = try XCTUnwrap(host.point(folderID, fx: 0.5, fy: 0.5))
        let baseEdge = try XCTUnwrap(host.point(folderID, fx: 0.1, fy: 0.5))
        let baseFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folderID))

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: baseEdge)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .cell(try cell(folderID, in: host)),
            "A folder's edge — placement onto its cell, the preview shifts the folder"
        )
        XCTAssertTrue(host.waitUntil {
            host.host.grid.frame(forItemID: folderID) != baseFrame
        }, "The folder moved off the base slot")

        host.coordinator.updateDrag(to: baseCenter)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .folder(folderID),
            "The center of the folder's base frame is .folder, not .none over the placeholder"
        )

        // Over the folder's center the preview returned to the base
        // layout — the folder is back in place under the finger, and the highlight is on it.
        XCTAssertEqual(
            host.host.grid.frame(forItemID: folderID),
            baseFrame,
            "The merge target does not \"run away\" from under the finger"
        )
        let highlight = try XCTUnwrap(
            host.host.grid.subviews.compactMap { $0 as? TesseraTileDropHighlightView }
                .first { !$0.isHidden }
        )
        XCTAssertEqual(highlight.center.x, baseFrame.midX, accuracy: 0.5)
        XCTAssertEqual(highlight.center.y, baseFrame.midY, accuracy: 0.5)
        XCTAssertEqual(highlight.bounds.size, baseFrame.size)
        XCTAssertTrue(baseFrame.contains(baseCenter), "The finger is over the highlighted target")

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// `.group` fires only inside the center of the target's BASE frame; not at the place
    /// the target moved to after the preview (pushed down, D31), nor over its
    /// own cell.
    func testGroupFiresOnlyInsideBaseFrameCenter() throws {
        let host = try makeBaseHitHost()
        let baseCenter = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))
        let baseEdge = try XCTUnwrap(host.point("b", fx: 0.9, fy: 0.5))
        let ownSlotCenter = try XCTUnwrap(host.point("a", fx: 0.5, fy: 0.5))
        let baseFrameOfB = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let bCell = try cell("b", in: host)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: baseEdge)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(bCell))
        XCTAssertTrue(host.waitUntil {
            host.host.grid.frame(forItemID: "b").map { $0.minY > baseFrameOfB.minY + 1 } ?? false
        }, "b is pushed down")

        // The center of the visible "b" (it is lower now) — in the base layout there is nothing there:
        // it is a cell, not a group.
        let shiftedCenter = try XCTUnwrap(host.point("b", fx: 0.5, fy: 0.5))
        host.coordinator.updateDrag(to: shiftedCenter)
        XCTAssertNotEqual(host.coordinator.dragSession?.hover, .group("b"), "Not by the base frame")

        // Its own base cell — there is no target, the preview is the base.
        host.coordinator.updateDrag(to: ownSlotCenter)
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            HoverTarget.none,
            "Over its own base cell — .none"
        )

        // The center of the base frame of "b" is a group, even though "b" is still moving back.
        host.coordinator.updateDrag(to: baseCenter)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("b"))

        // The base edge of "b" is still a placement onto its cell. After
        // a merge the target is held across almost the whole tile (hysteresis), so the edge
        // is taken from a clean state — through its own cell.
        host.coordinator.updateDrag(to: ownSlotCenter)
        host.coordinator.updateDrag(to: baseEdge)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(bCell))

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitForDragCleanup("a"))
    }

    /// Auto-scroll/`contentOffset`: base frames are stored in content
    /// coordinates, so after scrolling the target is found by the same tile.
    func testBaseHitTestFollowsContentOffset() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<48).map { tesseraTestTile("t\($0)", size: .small) },
            configuration: TesseraTileEditConfiguration(magnetSnapRadius: 0)
        )
        XCTAssertTrue(host.startDrag("t0"))
        let grid = host.host.grid

        grid.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        host.host.layout()
        let centerBefore = try XCTUnwrap(host.point("t21", fx: 0.5, fy: 0.5))
        host.coordinator.updateDrag(to: centerBefore)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t21"))

        // The preview shifts the grid; then the content moves another 100 pt.
        // 0.97 is outside the merge hold area (the frame minus 6 pt), otherwise the target would have stayed `.group`.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.point("t21", fx: 0.97, fy: 0.5)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(try cell("t21", in: host)))
        grid.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        host.host.layout()

        let session = try XCTUnwrap(host.coordinator.dragSession)
        let content = try XCTUnwrap(grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
        let frame = grid.gridFrame(fromContentFrame: try XCTUnwrap(content["t21"]))
        XCTAssertEqual(frame.midY, centerBefore.y - 100, accuracy: 0.5, "The frame shifted with the offset")

        host.coordinator.updateDrag(to: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertEqual(
            host.coordinator.dragSession?.hover,
            .group("t21"),
            "The hit test accounts for the current contentOffset"
        )

        host.coordinator.finishDrag(commit: false)
        grid.setContentOffset(.zero, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitForDragCleanup("t0"))
    }

    // MARK: - Moving from the panel onto the center of another folder

    /// A panel icon → the center of another folder (by the base layout) with
    /// a hold merges with the standard magnet (28 pt) — both when grabbed by the
    /// icon's center and by its edges; the snapshot does not move away from under the finger.
    func testPanelIconToOtherFolderCenterMergesWithMagnet() throws {
        let grabs: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.05, y: 0.05),
            CGPoint(x: 0.95, y: 0.95),
            CGPoint(x: 0.05, y: 0.95),
            CGPoint(x: 0.95, y: 0.05)
        ]
        for grab in grabs {
            let host = try makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05))
            let (f1, f2) = try panelHostFolderIDs(host)
            let start = try startPanelDrag(host, folderID: f1, iconIndex: 1, grab: grab)
            let session = try XCTUnwrap(host.coordinator.dragSession)
            let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
            let base = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[f2]))
            let target = CGPoint(x: base.midX, y: base.midY)

            // The finger goes to the center in one event (the start is in the panel, outside the grid):
            // the test isolates the magnet from the hold's slop anchor (see the design doc).
            XCTAssertNotEqual(start, target)
            host.coordinator.updateDrag(to: target)
            host.spin(0.02)
            XCTAssertEqual(session.hover, .folder(f2), "grab=\(grab): the finger is over F2's center")
            XCTAssertTrue(
                host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
                "grab=\(grab): the hold is completed"
            )
            // The snapshot is under the finger (not attracted to a slot).
            XCTAssertEqual(session.dragView.center.x, target.x + session.grabOffset.x, accuracy: 0.5, "grab=\(grab)")
            XCTAssertEqual(session.dragView.center.y, target.y + session.grabOffset.y, accuracy: 0.5, "grab=\(grab)")

            host.coordinator.finishDrag(commit: true)
            host.spin(0.3)
            XCTAssertEqual(
                host.folders.first { $0.id == f2 }?.tiles.map { $0.id },
                ["e", "h", "c"] as [AnyHashable],
                "grab=\(grab): the tile merged with F2"
            )
        }
    }

    /// A hypothesis about the grab: taking the only tile out into a model "hole" with
    /// the standard magnet and a grab by the icon's edges does not put it into the neighboring
    /// folder; the finger is over the model's "hole", and the snapshot does not move away from it farther than
    /// the magnet radius.
    func testSoleFolderTileEdgeGrabIntoHoleNeverEntersNeighborFolderWithMagnet() throws {
        let grabs = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.95, y: 0.05)]
        for columns in [4, 5, 6] {
            for grab in grabs {
                let host = try makeMoveOutHost(columns: columns, magnet: 28)
                let (work, folderB) = try panelHostFolderIDs(host)
                let hole = try moveOutHolePoint(host, work: work)

                try startPanelDrag(host, folderID: work, iconIndex: 0, grab: grab)
                let session = try XCTUnwrap(host.coordinator.dragSession)
                host.coordinator.updateDrag(to: CGPoint(x: hole.x - 30, y: hole.y))
                host.coordinator.updateDrag(to: hole)
                host.spin(0.12)
                XCTAssertNotEqual(session.hover, .folder(folderB), "cols=\(columns) grab=\(grab)")
                XCTAssertNotEqual(host.coordinator.mergeTracker?.isMergeReady, true, "cols=\(columns) grab=\(grab)")
                host.coordinator.finishDrag(commit: true)
                host.spin(0.3)
                assertMailIsPlainTile(host, folderB: folderB, work: work, "cols=\(columns) grab=\(grab)")
            }
        }
    }

    // MARK: - The hold is counted from the last noticeable movement

    /// Moves the finger from `start` to `end` in equal steps (one event per step), without pauses.
    private func walk(
        _ host: TesseraTestDragHost,
        from start: CGPoint,
        to end: CGPoint,
        steps: Int
    ) {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            host.coordinator.updateDrag(to: CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            ))
        }
    }

    /// 14 steps from a panel icon to the center of B, then a stop — a merge
    /// (reproducing a manual run: on entering the zone the anchor was set at
    /// the first point of the zone, and a finger that moved farther than 10 pt was never re-armed).
    /// The magnet is the default (28 pt); a grab by both the icon's center and a corner.
    func testPanelIconWalkToOtherFolderCenterMerges() throws {
        let grabs = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.95)]
        for grab in grabs {
            let host = try makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1))
            let (f1, f2) = try panelHostFolderIDs(host)
            let start = try startPanelDrag(host, folderID: f1, iconIndex: 1, grab: grab)
            let session = try XCTUnwrap(host.coordinator.dragSession)
            let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
            let base = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[f2]))
            let target = CGPoint(x: base.midX, y: base.midY)

            walk(host, from: start, to: target, steps: 14)
            XCTAssertEqual(session.hover, .folder(f2), "grab=\(grab): the finger is over F2's center")
            XCTAssertTrue(
                host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
                "grab=\(grab): the hold is completed after the stop"
            )

            host.coordinator.finishDrag(commit: true)
            host.spin(0.3)
            XCTAssertEqual(
                host.folders.first { $0.id == f2 }?.tiles.map { $0.id },
                ["e", "h", "c"] as [AnyHashable],
                "grab=\(grab): the tile merged with F2"
            )
        }
    }

    /// The same 14-step approach from a grid tile (folder creation and
    /// adding to an existing one) ends in a merge.
    func testGridTileWalkToFolderCenterMerges() throws {
        let host = try makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1))
        let (_, f2) = try panelHostFolderIDs(host)
        let start = try XCTUnwrap(host.point("a"))
        let target = try XCTUnwrap(host.point(f2))

        XCTAssertTrue(host.startDrag("a"))
        walk(host, from: start, to: target, steps: 14)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })

        host.coordinator.finishDrag(commit: true)
        host.spin(0.3)
        XCTAssertEqual(
            host.folders.first { $0.id == f2 }?.tiles.map { $0.id },
            ["e", "h", "a"] as [AnyHashable]
        )
    }

    /// Constant slow movement inside the central zone (each
    /// step ≥10 pt) does not make the hold ready, even when the total time is long
    /// past the threshold.
    func testContinuousMovementOverFolderCenterNeverBecomesReady() throws {
        let host = try makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.3))
        let (_, f2) = try panelHostFolderIDs(host)
        let center = try XCTUnwrap(host.point(f2))

        XCTAssertTrue(host.startDrag("a"))
        // Entering the zone at −8 pt from the center; then steps of ±8 pt (16 pt between neighbors).
        host.coordinator.updateDrag(to: CGPoint(x: center.x - 8, y: center.y))
        for step in 0..<24 {
            let dx: CGFloat = step % 2 == 0 ? 8 : -8
            host.coordinator.updateDrag(to: CGPoint(x: center.x + dx, y: center.y))
            XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2), "step \(step)")
            host.spin(0.05)
            XCTAssertFalse(host.coordinator.mergeTracker?.isMergeReady == true, "step \(step)")
        }

        // A stop — after the threshold since the last movement the readiness arrives.
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: false)
        host.spin(0.3)
    }

    /// Moving 15 pt and returning to the old point — readiness comes no
    /// earlier than the threshold since the last re-arm.
    func testReturnToOldAnchorDoesNotMergeEarlierThanHoldFromLastMove() throws {
        let host = try makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.4))
        let (_, f2) = try panelHostFolderIDs(host)
        let center = try XCTUnwrap(host.point(f2))
        let a = CGPoint(x: center.x - 8, y: center.y)
        let b = CGPoint(x: center.x + 7, y: center.y)

        XCTAssertTrue(host.startDrag("a"))
        host.coordinator.updateDrag(to: a)
        host.spin(0.25)
        host.coordinator.updateDrag(to: b)
        host.spin(0.25)
        // Returning to the old anchor A: a 15 pt shift from B — a new countdown.
        let reanchoredAt = Date()
        host.coordinator.updateDrag(to: a)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder(f2))
        host.spin(0.2)
        XCTAssertFalse(
            host.coordinator.mergeTracker?.isMergeReady == true,
            "0.2 s after the last re-arm there is no readiness yet"
        )
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        XCTAssertGreaterThan(Date().timeIntervalSince(reanchoredAt), 0.4)

        host.coordinator.finishDrag(commit: false)
        host.spin(0.3)
    }

    /// Tail case: a drop without readiness on a folder's center leaves no preview
    /// of an earlier reorder — the grid order equals the model, and the tile is not on a foreign slot.
    func testNotReadyDropOnFolderCenterLeavesNoPushPreview() throws {
        let host = try makePanelHost(configuration: TesseraTileEditConfiguration(mergeHoverDuration: 5))
        let (f1, f2) = try panelHostFolderIDs(host)
        let modelBefore = host.storeIDs
        let start = try startPanelDrag(host, folderID: f1, iconIndex: 1)
        let session = try XCTUnwrap(host.coordinator.dragSession)
        let content = try XCTUnwrap(host.host.grid.baseContentFrames(for: session.baseSnapshot.items, placementTable: session.baseSnapshot.placementTable))
        let base = host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[f2]))
        let target = CGPoint(x: base.midX, y: base.midY)

        walk(host, from: start, to: target, steps: 14)
        XCTAssertEqual(session.hover, .folder(f2))
        XCTAssertNotEqual(host.coordinator.mergeTracker?.isMergeReady, true)

        host.coordinator.finishDrag(commit: true)
        host.spin(0.5)
        XCTAssertEqual(host.storeIDs, modelBefore, "The model did not change")
        XCTAssertEqual(host.gridIDs, modelBefore, "The grid returned to the model order")
    }

    // MARK: - A folder from a wide/large/small target (always medium)

    /// The bench: a target of any size + the dragged tile + a "tail" of small tiles.
    private func makeWideTargetHost(
        target: TesseraTileSize,
        source: TesseraTileSize,
        sourceFirst: Bool
    ) -> TesseraTestDragHost {
        let pair = [
            tesseraTestTile("t", size: target),
            tesseraTestTile("s", size: source),
        ]
        return TesseraTestDragHost(
            descriptors: (sourceFirst ? pair.reversed() : pair) + [
                tesseraTestTile("x1", size: .small),
                tesseraTestTile("x2", size: .small),
                tesseraTestTile("x3", size: .small),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1)
        )
    }

    /// A merge onto the center of a wide/large/small target with a hold creates
    /// a folder; the folder is always medium (Windows 10 Mobile), both with a finger that arrived in several
    /// steps and with a "jump" straight to the center. The model and the grid are consistent.
    func testMergeOnTargetCenterCreatesMediumFolder() throws {
        let cases: [(target: TesseraTileSize, source: TesseraTileSize)] = [
            (.wide, .medium), (.wide, .small), (.large, .medium), (.large, .small),
            (.small, .medium), (.medium, .small),
        ]
        for walking in [true, false] {
          for sourceFirst in [false, true] {
            for item in cases {
                let label = "target=\(item.target) source=\(item.source) walking=\(walking) sourceFirst=\(sourceFirst)"
                let host = makeWideTargetHost(target: item.target, source: item.source, sourceFirst: sourceFirst)
                let recorder = DragDelegateRecorder()
                host.coordinator.delegate = recorder
                let start = try XCTUnwrap(host.point("s"))
                let center = try XCTUnwrap(host.point("t"))

                XCTAssertTrue(host.startDrag("s"), label)
                if walking {
                    walk(host, from: start, to: center, steps: 14)
                } else {
                    host.coordinator.updateDrag(to: center)
                }
                XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t"), label)
                XCTAssertTrue(
                    host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
                    "The hold is completed: \(label)"
                )

                host.coordinator.finishDrag(commit: true)
                XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 }, label)
                let folder = try XCTUnwrap(host.folders.first, label)
                XCTAssertEqual(folder.size, .medium, "The folder is always medium: \(label)")
                XCTAssertEqual(folder.tiles.map { $0.id }, ["t", "s"] as [AnyHashable], label)
                XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, label)
                host.spin(0.3)
                XCTAssertEqual(host.gridIDs, host.storeIDs, "Grid = model: \(label)")
                XCTAssertEqual(host.storeIDs.count, 4, "The folder + three small ones: \(label)")

                // The layout is sane: a 2×2 folder, the snapshot flew into its frame, the frames
                // do not overlap.
                let frame = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id), label)
                let small = try XCTUnwrap(host.host.grid.frame(forItemID: "x1"), label)
                XCTAssertGreaterThan(frame.width, small.width * 1.5, "The folder is larger than a small one: \(label)")
                XCTAssertLessThan(frame.width, small.width * 3, "The folder is not wide: \(label)")
                XCTAssertEqual(host.coordinator.lastCollapseTargetFrame, frame, label)
                let frames = host.storeIDs.compactMap { host.host.grid.frame(forItemID: $0) }
                for (i, a) in frames.enumerated() {
                    for b in frames[(i + 1)...] {
                        XCTAssertFalse(a.intersects(b.insetBy(dx: 1, dy: 1)), "Overlap: \(label)")
                    }
                }
            }
          }
        }
    }
    // MARK: - Drag from normal mode with a non-canonical model order

    /// A bench like "Start" in the Example: a small "Mail", a medium "Calendar", a wide
    /// "Weather", a folder "Work" (of "Notes" and "Photos"), a large "Music" and a small
    /// "Settings" **last in the model** — packing lifts them into the "hole" to the right
    /// of the calendar, that is, the model order does not match the reading order.
    private func makeStartLikeHost() throws -> TesseraTestDragHost {
        // A compact layout as before the cell-based model (`packed`): "Settings" is last
        // in the packing order, but packing lifts them into the "hole" to the right of the calendar.
        try TesseraTestDragHost(
            packed: [
                .tile("mail", .small),
                .tile("calendar", .medium),
                .tile("weather", .wide),
                .folder("Work", .medium, [("notes", .small), ("photos", .small)]),
                .tile("music", .large),
                .tile("settings", .small),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.1)
        )
    }

    /// A fresh start, edit is off; a single gesture — a long press on
    /// "Mail" (entering edit + a drag) and without lifting onto "Settings" with a hold.
    /// A 2×2 folder lands on the target's cell (D20), not at the end of the grid; "Settings"
    /// sits in the last column (0, 3), a 2×2 does not fit there, so the cell
    /// shifts left to (0, 2), and the calendar that it covers goes
    /// down in a cascade (D31). The cell of "Mail" remains a hole.
    func testStartFromNormalModeMergeOntoHoleFillingTileKeepsTargetSlot() throws {
        let host = try makeStartLikeHost()
        let recorder = DragDelegateRecorder()
        host.coordinator.delegate = recorder
        XCTAssertFalse(host.coordinator.isEditing)
        let start = try XCTUnwrap(host.point("mail"))
        let target = try XCTUnwrap(host.point("settings"))
        let targetFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "settings"))
        let calendarFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "calendar"))
        XCTAssertGreaterThan(targetFrame.minX, calendarFrame.maxX, "\"Settings\" sits in the hole to the right of the calendar")
        XCTAssertEqual(targetFrame.minY, calendarFrame.minY, accuracy: 1)

        XCTAssertTrue(host.startDrag("mail"))
        XCTAssertTrue(host.coordinator.isEditing)
        walk(host, from: start, to: target, steps: 14)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("settings"))
        XCTAssertTrue(
            host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true },
            "The hold is completed"
        )

        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.additions.count == 1 })
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.spin(0.3)

        let folder = try XCTUnwrap(host.folders.first { $0.tiles.map { $0.id } == ["settings", "mail"] as [AnyHashable] })
        XCTAssertEqual(host.gridIDs, host.storeIDs, "Grid = model")
        XCTAssertEqual(folder.size, .medium)
        // The folder is in the target's row (not at the end of the grid), the cell is shifted left to 2.
        XCTAssertEqual(host.store.placement(of: folder.id), TesseraTileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(host.storeIDs.first, folder.id, "The folder is first in reading order, not at the end")
        let folderFrame = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id))
        XCTAssertEqual(folderFrame.minY, targetFrame.minY, accuracy: 1, "In the target's row")
        // The calendar, covered by the folder, is pushed down (D31); the hole of "Mail" remained.
        let newCalendarFrame = try XCTUnwrap(host.host.grid.frame(forItemID: "calendar"))
        XCTAssertGreaterThan(newCalendarFrame.minY, folderFrame.maxY - 1)
        XCTAssertNil(host.store.placements(forColumns: 4).values.first { $0 == TesseraTileGridPlacement(row: 0, column: 0) }, "The cell of \"Mail\" is a hole")
    }

    /// A drag start (including from an already enabled edit mode and on a return
    /// without a merge) changes neither the model nor the visible layout: cell coordinates are
    /// the model itself, "Settings" stays in the hole to the right of the calendar.
    func testDragStartKeepsModelAndLayoutUntouched() throws {
        for editFirst in [false, true] {
            let host = try makeStartLikeHost()
            let before = host.storeIDs.compactMap { host.host.grid.frame(forItemID: $0) }
            let idsBefore = host.storeIDs
            let cellsBefore = host.store.placements(forColumns: 4)
            if editFirst { host.coordinator.beginEditing() }
            XCTAssertTrue(host.startDrag("mail"), "editFirst=\(editFirst)")
            XCTAssertEqual(host.storeIDs, idsBefore, "The model order is untouched: editFirst=\(editFirst)")
            XCTAssertEqual(host.store.placements(forColumns: 4), cellsBefore, "The cells are untouched: editFirst=\(editFirst)")
            XCTAssertEqual(host.gridIDs, host.storeIDs, "editFirst=\(editFirst)")
            host.coordinator.finishDrag(commit: false)
            XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
            host.spin(0.3)
            let after = host.storeIDs.compactMap { host.host.grid.frame(forItemID: $0) }
            XCTAssertEqual(before.count, after.count)
            // Compare the set of frames: the order of identifiers changed, the layout did not.
            let key: (CGRect) -> String = { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())),\(Int($0.width.rounded()))" }
            XCTAssertEqual(Set(before.map(key)), Set(after.map(key)), "editFirst=\(editFirst)")
        }
    }
}

#endif
