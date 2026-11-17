//
//  TileMergeZoneTests.swift
//  TesseraStartScreenTests
//
//  Folder creation by dragging: the merge zone, hysteresis and the dwell before
//  the push-down preview.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md ("Implementation deviations");
//  docs/W10M-STARTSCREEN.md §6.2; decisions D22 (hold of 600 ms / 10 pt,
//  unchanged), D50 in docs/STATE.md.
//
//  What is checked:
//  - zone geometry (`TesseraTileMergeZone`): entry is the frame's center with a side of
//    `max(50 %, 36 pt)` per axis, hold is the frame minus 6 pt at the edges;
//  - hysteresis: the `.group`/`.folder` target holds while the finger is in the
//    hold area and does not flicker at the border of the entry zone;
//  - the dwell before the push-down preview: while approaching a tile's center its neighbor does not
//    "run away", the preview appears after the dwell (and when the finger is still), a cell change
//    restarts the countdown, empty cells and "new row" apply immediately, a drop ignores the dwell,
//    and timers do not outlive a drag;
//  - the recorded scenario: five small tiles in a row, the fifth is dragged onto the third.
//
//  The timers are real (run loop), but all "not earlier than the dwell" checks are made
//  synchronously, before spinning the run loop, so they do not flake under load.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileMergeZoneTests: XCTestCase {

    // MARK: - Helpers

    /// A recording delegate: needs the created folders and the additions.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Created folders.
        var createdFolders: [TesseraTileFolder] = []

        /// Additions to a folder.
        var additions: [(id: AnyHashable, folder: AnyHashable)] = []

        /// Reorders on the grid.
        var moves: [(id: AnyHashable, cell: TesseraTileGridPlacement)] = []

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

    /// Configuration: hold of 0.3 s (D22 is unchanged; the value is shortened only
    /// for test speed), a configurable preview dwell, magnet off.
    private func configuration(
        dwell: TimeInterval = 0.5,
        hold: TimeInterval = 0.3,
        magnet: CGFloat = 0
    ) -> TesseraTileEditConfiguration {
        TesseraTileEditConfiguration(
            mergeHoverDuration: hold,
            magnetSnapRadius: magnet,
            reorderPreviewDwell: dwell
        )
    }

    /// Five small tiles `t1…t5` in a row, 6 columns (as in the Example, D26): the width is
    /// about 55 pt, as in the user's recording.
    private func makeRowHost(
        configuration: TesseraTileEditConfiguration? = nil
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: (0..<5).map { CellFixtureTile("t\($0 + 1)", .small, 0, $0) },
            columns: 6,
            configuration: configuration ?? self.configuration()
        )
    }

    /// Waits for the drop to finish: the session is gone and the grid matches the model.
    private func settle(
        _ host: TesseraTestDragHost,
        _ id: AnyHashable,
        columns: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil }, "Session finished", file: file, line: line)
        XCTAssertTrue(host.waitForDragCleanup(id), "The cell is visible again", file: file, line: line)
        XCTAssertTrue(
            host.waitUntil { host.gridCells == host.store.placements(forColumns: columns) },
            "The grid shows the model cells",
            file: file,
            line: line
        )
    }

    /// A point inside the frame at the given distance from its center.
    private func point(_ frame: CGRect, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: frame.midX + dx, y: frame.midY + dy)
    }

    // MARK: - Zone geometry

    /// A 55 pt small tile: the entry zone is 36 pt (it used to be 27.5 pt).
    func testEntryZoneOnSmallTileIsThirtySixPoints() {
        let frame = CGRect(x: 10, y: 20, width: 55, height: 55)
        let entry = TesseraTileMergeZone.entryRect(in: frame)

        XCTAssertEqual(entry.width, 36, accuracy: 0.001)
        XCTAssertEqual(entry.height, 36, accuracy: 0.001)
        XCTAssertEqual(entry.midX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(entry.midY, frame.midY, accuracy: 0.001)
    }

    /// A medium tile/folder of 118 pt: half the side is 59 pt (as before).
    func testEntryZoneOnMediumTileIsHalfOfSide() {
        let frame = CGRect(x: 0, y: 0, width: 118, height: 118)
        let entry = TesseraTileMergeZone.entryRect(in: frame)

        XCTAssertEqual(entry.width, 59, accuracy: 0.001)
        XCTAssertEqual(entry.height, 59, accuracy: 0.001)
    }

    /// The zone does not extend beyond the frame: for a tile below the minimum (30 pt) it equals the frame.
    func testEntryZoneIsClampedToTinyFrame() {
        let frame = CGRect(x: 5, y: 5, width: 30, height: 30)
        XCTAssertEqual(TesseraTileMergeZone.entryRect(in: frame), frame)
    }

    /// A wide tile: each axis is computed separately, and the zone is no smaller than the previous
    /// half of the frame on each axis.
    func testEntryZoneIsComputedPerAxisForWideTile() {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 118)
        let entry = TesseraTileMergeZone.entryRect(in: frame)

        XCTAssertEqual(entry.width, 120, accuracy: 0.001)
        XCTAssertEqual(entry.height, 59, accuracy: 0.001)

        let thin = CGRect(x: 0, y: 0, width: 240, height: 40)
        XCTAssertEqual(TesseraTileMergeZone.entryRect(in: thin).height, 36, accuracy: 0.001, "Minimum 36 pt, but no more than the side")
    }

    /// The hold area is the frame minus 6 pt at the edges, but no smaller than the entry zone.
    func testRetainZoneIsInsetFrameAndNeverSmallerThanEntry() {
        let frame = CGRect(x: 0, y: 0, width: 55, height: 55)
        let retain = TesseraTileMergeZone.retainRect(in: frame)
        XCTAssertEqual(retain, frame.insetBy(dx: 6, dy: 6))
        XCTAssertTrue(retain.contains(TesseraTileMergeZone.entryRect(in: frame)))

        let tiny = CGRect(x: 0, y: 0, width: 40, height: 40)
        XCTAssertEqual(
            TesseraTileMergeZone.retainRect(in: tiny),
            TesseraTileMergeZone.entryRect(in: tiny),
            "The frame minus 6 pt (28 pt) is smaller than the entry zone (36 pt), so the entry zone is used"
        )
    }

    /// A degenerate frame gives no zone.
    func testDegenerateFrameHasNoZone() {
        let frame = CGRect(x: 0, y: 0, width: 0, height: 20)
        XCTAssertFalse(TesseraTileMergeZone.contains(.zero, in: frame, isEngaged: false))
        XCTAssertFalse(TesseraTileMergeZone.contains(.zero, in: frame, isEngaged: true))
    }

    /// Live geometry: on a 6-column grid the entry zone of a small tile is 36 pt;
    /// with the finger 17 pt from the center along the axis the target becomes a merge, at 19 pt it does not.
    func testLiveSmallTileEntryZoneIsThirtySixPoints() throws {
        let host = try makeRowHost()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertEqual(frame.width, 55, accuracy: 6, "A small tile on 6 columns is about 55 pt")
        XCTAssertGreaterThanOrEqual(frame.width, 40, "A small tile is wider than the minimum zone")

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(frame, dx: 17))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "17 pt from the center is inside 36 pt")
        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(frame, dx: 19.5))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "19.5 pt from the center is outside the entry zone")
        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Hysteresis

    /// Entry is only through the entry zone, hold is almost across the whole tile:
    /// 7 pt from the edge (outside the entry zone, inside the hold area) does not clear the target,
    /// 3 pt from the edge does, and returning to 7 pt does not enable the merge again.
    func testHysteresisKeepsMergeTargetUntilFingerLeavesRetainZone() throws {
        let host = try makeRowHost()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let outsideEntry = CGPoint(x: frame.maxX - 7, y: frame.midY)
        XCTAssertFalse(TesseraTileMergeZone.entryRect(in: frame).contains(outsideEntry), "Control: outside the entry zone")
        XCTAssertTrue(TesseraTileMergeZone.retainRect(in: frame).contains(outsideEntry), "Control: inside the hold area")

        XCTAssertTrue(host.startDrag("t5"))
        // Without entering the zone the hold area does not work.
        host.coordinator.updateDrag(to: outsideEntry)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Entry is only through the entry zone")

        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        host.coordinator.updateDrag(to: outsideEntry)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "Hold: 7 pt from the edge")

        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Left the hold area")
        host.coordinator.updateDrag(to: outsideEntry)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Entry is again only through the entry zone")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Finger jitter at the border of the entry zone does not switch the target: the preview is the base,
    /// the target does not move, the hold is not re-armed (offset < 10 pt from the anchor),
    /// and in the end it is satisfied.
    func testJitterAtZoneBoundaryKeepsHighlightAndHoldRunning() throws {
        let host = try makeRowHost()
        let baseTable = try XCTUnwrap(host.gridCells)
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let entryHalf = TesseraTileMergeZone.entryRect(in: frame).width / 2
        XCTAssertTrue(host.startDrag("t5"))

        // The anchor is the entry point inside the zone; then oscillations across the border
        // of the entry zone (inside the hold area, < 10 pt from the anchor).
        host.coordinator.updateDrag(to: point(frame, dx: entryHalf - 1))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        let tracker = try XCTUnwrap(host.coordinator.mergeTracker)
        let anchor = tracker.anchor

        let retainHalf = TesseraTileMergeZone.retainRect(in: frame).width / 2
        XCTAssertGreaterThan(retainHalf, entryHalf + 1, "Control: the hold area is wider than the entry zone")
        for offset in [entryHalf + 1, entryHalf - 2, retainHalf - 0.5, entryHalf - 1, entryHalf + 1.5] {
            host.coordinator.updateDrag(to: point(frame, dx: offset))
            let session = try XCTUnwrap(host.coordinator.dragSession)
            XCTAssertEqual(session.hover, .group("t3"), "Does not flicker at offset \(offset)")
            XCTAssertEqual(session.previewPlacements, session.basePlacements, "The preview is the base")
            XCTAssertEqual(host.gridCells, baseTable, "The target is under the finger")
            XCTAssertEqual(host.coordinator.mergeTracker?.anchor, anchor, "The hold was not re-armed")
        }

        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true }, "Hold of 600 ms (0.3 s in the test) satisfied")
        let highlight = try XCTUnwrap(
            host.host.grid.subviews.compactMap { $0 as? TesseraTileDropHighlightView }.first { !$0.isHidden }
        )
        XCTAssertEqual(highlight.center.x, frame.midX, accuracy: 0.5)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Leaving the hold area: the target returns to the edge logic (`.cell`),
    /// and the hold and its timer are cleared.
    func testLeavingRetainZoneFallsBackToCellAndStopsHold() throws {
        let host = try makeRowHost()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        XCTAssertNotNil(host.coordinator.mergeTracker)
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.merge)

        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        XCTAssertNil(host.coordinator.mergeTracker)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Dwell before the push-down preview

    /// Approaching a neighbor from the side: until the finger has stood for the dwell at the target's edge, the target does not
    /// move; the preview appears after the dwell and pushes it down.
    func testNeighbourDoesNotMoveBeforeDwellAndIsPushedAfter() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.3))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        let started = CACurrentMediaTime()
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "The edge of an occupied cell")
        XCTAssertEqual(host.gridCells, baseTable, "Before the dwell the preview is the base: 't3' does not run away")
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "The dwell countdown is running")

        // The finger is still: there are no touch events, so the timer gives the preview.
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable }, "Preview after the dwell")
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - started, 0.28, "Not earlier than the dwell")
        XCTAssertEqual(host.gridCells?["t5"], at(0, 2), "The dragged item is on the target's cell")
        XCTAssertEqual(host.gridCells?["t3"], at(1, 2), "The target is pushed down")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "The timer fired")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// A cell change restarts the countdown: time spent on the previous cell is not
    /// credited to the new one.
    func testDwellRestartsWhenCellChanges() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.5))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t2 = try XCTUnwrap(host.host.grid.frame(forItemID: "t2"))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t2.maxX - 2, y: t2.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 1)))
        host.spin(0.3)
        XCTAssertEqual(host.gridCells, baseTable, "0.3 s < dwell 0.5 s")

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        host.spin(0.3)
        XCTAssertEqual(host.gridCells, baseTable, "0.6 s passed since the first cell but only 0.3 s since the second: the countdown was restarted")

        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })
        XCTAssertEqual(host.gridCells?["t3"], at(1, 2), "The second cell was pushed out")
        XCTAssertEqual(host.gridCells?["t2"], at(0, 1), "The first is untouched")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// Leaving a cell before the dwell cancels the preview: after returning the countdown starts anew.
    func testDwellIsDroppedWhenFingerLeavesCell() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.3))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        host.coordinator.updateDrag(to: point(t3))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "A merge clears the dwell countdown")

        host.spin(0.4)
        XCTAssertEqual(host.gridCells, baseTable, "Merge: the preview is the base, the dwell timer did not fire")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// An empty cell and "new row" push nobody out, so the preview is immediate, without
    /// a dwell timer.
    func testEmptyCellAndNewRowPreviewsAreImmediate() throws {
        // A tile in row 3 keeps rows 1–2 "inside" the canvas: cell (1, 3) is empty,
        // but it is not a "new row".
        let host = try TesseraTestDragHost(
            cells: (0..<5).map { CellFixtureTile("t\($0 + 1)", .small, 0, $0) }
                + [CellFixtureTile("z", .small, 3, 0)],
            columns: 6,
            configuration: configuration(dwell: 5)
        )
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 3)), "Empty cell")
        XCTAssertEqual(host.gridCells?["t5"], at(1, 3), "Immediate preview")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 5, column: 0)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        XCTAssertEqual(host.gridCells?["t5"], at(4, 0), "'New row' is immediate")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// A drop before the dwell fixes the same target cell as without a dwell: the item is on
    /// the target's cell, and the target is pushed down; the timer is cleared.
    func testDropBeforeDwellCommitsSameCellMove() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 5))
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.gridCells, baseTable, "The preview is not shown yet")
        host.coordinator.finishDrag(commit: true)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "The timer is cleared on drop")
        settle(host, "t5")

        XCTAssertEqual(host.store.placement(of: "t5"), at(0, 2), "The tile is on the target's cell")
        XCTAssertEqual(host.store.placement(of: "t3"), at(1, 2), "The target is pushed down (D31)")
        XCTAssertEqual(host.store.placement(of: "t4"), at(0, 3), "The rest are in place")
        XCTAssertEqual(recorder.moves.first?.id, AnyHashable("t5"))
    }

    /// A zero dwell restores the previous behavior: an immediate push-down preview.
    func testZeroDwellKeepsImmediatePreview() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0))
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertNotEqual(host.gridCells, baseTable)
        XCTAssertEqual(host.gridCells?["t3"], at(1, 2))
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    /// The default value is 0.2 s; a non-finite or negative value is treated as 0.
    func testConfigurationDefaultAndSanitizing() throws {
        XCTAssertEqual(TesseraTileEditConfiguration().reorderPreviewDwell, 0.2, accuracy: 0.0001)

        for bad in [TimeInterval.nan, -1, .infinity] {
            let host = try makeRowHost(configuration: configuration(dwell: bad))
            let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
            XCTAssertTrue(host.startDrag("t5"))
            host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
            // .infinity is not finite either: that also means "no dwell", not an infinite wait.
            XCTAssertEqual(host.gridCells?["t3"], at(1, 2), "Dwell \(bad) = no dwell")
            host.coordinator.finishDrag(commit: false)
            settle(host, "t5")
        }
    }

    /// Reduce Motion does not disable the dwell: it exists so that tiles are not moved.
    func testDwellStaysWithReduceMotion() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 0.3))
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertEqual(host.gridCells, baseTable, "The dwell stays with Reduce Motion")
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Timers do not outlive a drag

    /// Cancel, completion and leaving edit mode clear the dwell and hold timers.
    func testNoTimersLeftAfterCancelDropAndEndEditing() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 5, hold: 5))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))

        // Gesture cancellation during the dwell countdown.
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        host.coordinator.finishDrag(commit: false)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        settle(host, "t5")

        // A drop on a merge without a satisfied hold.
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(t3))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.merge)
        host.coordinator.finishDrag(commit: true)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)
        settle(host, "t5")

        // Leaving edit mode in the middle of a drag.
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)
    }

    /// Changing the configuration on the fly clears the dwell countdown; the next step arms it
    /// again.
    func testConfigurationChangeResetsDwell() throws {
        let host = try makeRowHost(configuration: configuration(dwell: 5))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 2, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.configuration = configuration(dwell: 5)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.updateDrag(to: CGPoint(x: t3.maxX - 3, y: t3.midY))
        XCTAssertTrue(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "The next step re-armed the countdown")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Recorded scenario

    /// A user recording: a row of small tiles, the fifth is dragged onto the third. The approach
    /// from the right passes over the fourth and the edge of the third: no tile moves
    /// from under the finger, at the center of the third the target is `.group`, the highlight does not flicker under
    /// jitter, the hold is satisfied, and the drop creates a folder from two tiles.
    func testRecordedScenarioDragFifthOntoThirdCreatesFolder() throws {
        let host = try makeRowHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let baseTable = try XCTUnwrap(host.gridCells)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let t5 = try XCTUnwrap(host.host.grid.frame(forItemID: "t5"))
        XCTAssertTrue(host.startDrag("t5"))

        // The path in 5 pt steps from the center of 't5' to the center of 't3'.
        var hovers: [HoverTarget] = []
        var x = t5.midX
        while x > t3.midX {
            x = max(t3.midX, x - 5)
            host.coordinator.updateDrag(to: CGPoint(x: x, y: t3.midY))
            let session = try XCTUnwrap(host.coordinator.dragSession)
            hovers.append(session.hover)
            // While the steps are faster than the dwell, the preview is the base: nothing runs away.
            XCTAssertEqual(host.gridCells, baseTable, "x = \(x): neighbors in place")
        }
        XCTAssertTrue(hovers.contains(.cell(at(0, 2))), "The finger crossed the edge of 't3'")
        XCTAssertEqual(hovers.last, .group("t3"), "The center of 't3' is a merge")

        // Jitter of ±8 pt (< 10 pt from the hold anchor) on both axes inside the tile:
        // the target and the hold are not disturbed. The anchor is where the hold was last
        // re-armed along the path (D22), not necessarily the center.
        let anchor = try XCTUnwrap(host.coordinator.mergeTracker?.anchor)
        for jitter in [CGPoint(x: 8, y: 0), CGPoint(x: -8, y: 3), CGPoint(x: 3, y: 8), CGPoint(x: -4, y: -8)] {
            host.coordinator.updateDrag(to: CGPoint(x: anchor.x + jitter.x, y: anchor.y + jitter.y))
            XCTAssertTrue(t3.insetBy(dx: 6, dy: 6).contains(host.coordinator.dragSession?.lastPoint ?? .zero), "Control: the point is inside the tile")
            XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
            XCTAssertEqual(host.gridCells, baseTable)
            XCTAssertEqual(host.coordinator.mergeTracker?.targetID, AnyHashable("t3"))
            XCTAssertEqual(host.coordinator.mergeTracker?.anchor, anchor, "Offset < 10 pt: the hold continues")
        }

        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { recorder.createdFolders.count == 1 })
        let folder = try XCTUnwrap(recorder.createdFolders.first)
        settle(host, folder.id)

        XCTAssertEqual(Set(folder.tiles.map { $0.id }), Set<AnyHashable>(["t3", "t5"]), "A folder of two tiles")
        XCTAssertEqual(folder.size, .medium, "A 2×2 folder (D20)")
        XCTAssertEqual(host.store.placement(of: folder.id), at(0, 2), "On the target's cell")
        XCTAssertEqual(host.store.placement(of: "t1"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "t2"), at(0, 1))
        XCTAssertNil(host.store.placement(of: "t5"), "The tile went into the folder")
    }

    /// The same approach "from above": the finger goes to the tile's center vertically, the target does not
    /// run away, and the merge is reachable.
    func testApproachFromAboveReachesMergeWithoutPush() throws {
        let host = try TesseraTestDragHost(
            cells: [
                CellFixtureTile("a", .small, 0, 2),
                CellFixtureTile("b", .small, 1, 2),
                CellFixtureTile("c", .small, 2, 4),
            ],
            columns: 6,
            configuration: configuration()
        )
        let baseTable = try XCTUnwrap(host.gridCells)
        let b = try XCTUnwrap(host.host.grid.frame(forItemID: "b"))
        let c = try XCTUnwrap(host.host.grid.frame(forItemID: "c"))
        XCTAssertTrue(host.startDrag("c"))

        var y = c.midY
        var last: HoverTarget = .none
        while y > b.midY {
            y = max(b.midY, y - 5)
            host.coordinator.updateDrag(to: CGPoint(x: b.midX, y: y))
            last = try XCTUnwrap(host.coordinator.dragSession).hover
            XCTAssertEqual(host.gridCells?["b"], baseTable["b"], "y = \(y): 'b' does not run away")
            XCTAssertEqual(host.gridCells?["a"], baseTable["a"], "y = \(y): 'a' is in place")
        }
        XCTAssertEqual(last, .group("b"))
        host.coordinator.finishDrag(commit: false)
        settle(host, "c")
    }

    // MARK: - Folder as a target

    /// The same rules for a folder: a 59 pt entry zone, hysteresis, a dwell before
    /// pushing a folder out from the edge.
    func testFolderTargetUsesSameZoneHysteresisAndDwell() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 5)],
            folders: [
                CellFixtureFolder("F", .medium, 1, 1, contents: [("f1", .small), ("f2", .small)]),
            ],
            columns: 6,
            configuration: configuration(dwell: 0.3)
        )
        let baseTable = try XCTUnwrap(host.gridCells)
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "F"))
        let entry = TesseraTileMergeZone.entryRect(in: frame)
        XCTAssertEqual(entry.width, frame.width / 2, accuracy: 0.5, "For 2×2 it is half the side, as before")

        XCTAssertTrue(host.startDrag("a"))
        // The folder's edge: a dwell, then the push-down.
        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 1)))
        XCTAssertEqual(host.gridCells, baseTable, "The folder does not run away before the dwell")
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })
        XCTAssertEqual(host.gridCells?["F"], at(2, 1), "The folder is pushed out after the dwell")

        // Center: the target is the folder, the preview is the base immediately.
        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("F"))
        XCTAssertEqual(host.gridCells, baseTable)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        // Hysteresis: 7 pt from the folder's edge is still `.folder`.
        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 7, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("F"))
        host.coordinator.updateDrag(to: CGPoint(x: frame.maxX - 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(1, 1)))

        host.coordinator.updateDrag(to: point(frame))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: false)
        settle(host, "a")
    }

    // MARK: - Tile from the panel

    /// A tile taken out of the panel: the same zone and dwell rules; a reorder inside
    /// the panel does not arm dwells.
    func testPanelTakeOutUsesDwellAndPanelReorderHasNoTimers() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("t", .small, 0, 2)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("f1", .small), ("f2", .small), ("f3", .small)]),
            ],
            columns: 6,
            configuration: configuration(dwell: 0.3)
        )
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == AnyHashable("F") })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: "F")?.shortcutCells.first?.accessibilityCustomActions != nil
        })

        // A reorder inside the panel: a long press on a panel tile, steps over the slots.
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let geometry = try XCTUnwrap(host.host.grid.panelShortcutGeometry())
        let slot0 = geometry.frames[0]
        let slot2 = geometry.frames[2]
        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: slot0.midX, y: slot0.midY))
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder)
        host.coordinator.updateDrag(to: CGPoint(x: slot2.midX, y: slot2.midY))
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell, "Reorder in the panel: no dwells")
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.merge)
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.spin(0.4)

        // Take-out: a tile from the panel over the edge of an occupied cell.
        let iconFrame = try XCTUnwrap(host.host.panelCell(folderID: "F")).shortcutCells[1].frame
        let iconCenter = try XCTUnwrap(host.host.panelCell(folderID: "F")?.shortcutCells[1].superview)
            .convert(CGPoint(x: iconFrame.midX, y: iconFrame.midY), to: host.host.grid)
        host.coordinator.startDragFromPanel(at: iconCenter)
        XCTAssertTrue(host.coordinator.isDragging)
        XCTAssertNil(host.coordinator.dragSession?.panelReorder)

        let tFrame = try XCTUnwrap(host.cellFrame(row: 0, column: 2))
        let baseTable = try XCTUnwrap(host.gridCells)
        host.coordinator.updateDrag(to: CGPoint(x: tFrame.maxX - 2, y: tFrame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)))
        XCTAssertEqual(host.gridCells, baseTable, "Before the dwell 't' does not run away")
        XCTAssertTrue(host.waitUntil { host.gridCells != baseTable })
        XCTAssertEqual(host.gridCells?["t"], at(1, 2), "After the dwell 't' is pushed out")

        // The center of the source folder is still `.sourceFolder` (the entry zone).
        let folderFrame = try XCTUnwrap(host.cellFrame(row: 0, column: 0, size: .medium))
        host.coordinator.updateDrag(to: point(folderFrame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .sourceFolder)
        XCTAssertFalse(host.coordinator.hasPendingDragTimersForTesting.reorderDwell)

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        host.coordinator.endEditing()
    }

    // MARK: - RTL

    /// RTL: the zone and hysteresis are computed from the item's frame, so they work
    /// mirrored; the target is a logical cell.
    func testRightToLeftZoneAndHysteresis() throws {
        let host = try makeRowHost()
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.layout()
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let t5 = try XCTUnwrap(host.host.grid.frame(forItemID: "t5"))
        XCTAssertLessThan(t5.minX, frame.minX, "RTL: 't5' is to the left of 't3'")

        XCTAssertTrue(host.startDrag("t5"))
        host.coordinator.updateDrag(to: point(frame, dx: -17))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "The entry zone is mirrored")
        // The edge of 't3' on the side of 't4' (on the left by 7 pt in RTL): hold.
        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 7, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 3, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 2)), "Logical cell (0, 2)")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }

    // MARK: - Magnet

    /// The magnet does not contend with the zone: over a merge target (including in the hold
    /// area) it is off, and the snapshot stays under the finger.
    func testMagnetStaysOffOverMergeTargetInsideRetainZone() throws {
        let host = try makeRowHost(configuration: configuration(magnet: 28))
        host.coordinator.isReduceMotionEnabled = { false }
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        XCTAssertTrue(host.startDrag("t5"))

        // Leaving the magnet's start zone, then entering the merge.
        host.coordinator.updateDrag(to: point(frame, dx: 40))
        host.coordinator.updateDrag(to: point(frame))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"))
        XCTAssertNil(host.coordinator.dragMagnetTargetForTesting(at: point(frame)), "No magnet over the center")

        let held = CGPoint(x: frame.maxX - 7, y: frame.midY)
        host.coordinator.updateDrag(to: held)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .group("t3"), "Hold")
        XCTAssertNil(host.coordinator.dragMagnetTargetForTesting(at: held), "No magnet in the hold area")

        host.coordinator.finishDrag(commit: false)
        settle(host, "t5")
    }
}

#endif
