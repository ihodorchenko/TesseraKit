//
//  TileFolderDissolveUITests.swift
//  TesseraStartScreenTests
//
//  A folder never holds 0–1 tiles: coordinator and grid (D45).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md "Implementation
//  deviations"; decision D45 in docs/STATE.md.
//
//  Checked on a real `TesseraTileStore` and a grid in a window (`TesseraTestDragHost`):
//  - unpinning a tile of an opened panel in a two-tile folder: the panel closes,
//    the remaining tile takes the folder's place, VoiceOver focus goes to it;
//  - unpin in a three-tile folder: the panel stays, focus goes to the next tile of the panel,
//    for the last one — to the previous; with the panel closed — to the folder tile;
//  - the VoiceOver "Unpin" action on a panel tile;
//  - the public `moveBetweenFolders(_:to: nil)` dissolves a two-tile folder;
//  - drag out of a two-tile folder: the target-placement preview shows the outcome (the folder
//    is replaced by the remaining tile), over a merge/the home folder — the base; a drop puts
//    the tiles exactly where the preview showed; cancellation and a host refusal restore
//    the folder; a drop on the center of another folder dissolves the source;
//  - the delegate: `didDissolveFolder` after the main callback, exactly once.
//
//  Layouts are exact (`TileStoreCellFixture`), 4 columns; no `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderDissolveUITests: XCTestCase {

    // MARK: - Helpers

    /// A delegate that records events in a single stream: the order matters.
    private final class Recorder: TesseraTileEditCoordinatorDelegate {

        /// Events: `unpin:id`, `move:id>folder|nil@cell`, `dissolve:folder>tile`.
        var events: [String] = []

        /// Refusals of the approval function.
        var failures: [TesseraTileGroupingAction] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            events.append("unpin:\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didMove tileID: AnyHashable,
            toFolder folderID: AnyHashable?,
            atCell cell: TesseraTileGridPlacement?
        ) {
            let target = folderID.map { "\($0)" } ?? "nil"
            let at = cell.map { "(\($0.row),\($0.column))" } ?? "-"
            events.append("move:\(tileID)>\(target)@\(at)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            events.append("dissolve:\(folderID)>\(tileID)")
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

    private func at(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    /// The focus of the last post is on the given view.
    private func assertFocus(
        _ recorder: PostRecorder,
        on view: UIView?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(recorder.posts.last?.0, UIAccessibility.Notification.layoutChanged, file: file, line: line)
        XCTAssertNotNil(view, "the focus target exists: \(message)", file: file, line: line)
        XCTAssertTrue((recorder.posts.last?.1 as? UIView) === view, message, file: file, line: line)
    }

    /// Enters edit mode and opens the folder panel without animation.
    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost, folderID: AnyHashable) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        }, "The panel tiles' actions are set by the deferred reconciliation")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    /// A long press on a panel icon: a drag of a tile out of the folder.
    private func startPanelDrag(_ host: TesseraTestDragHost, folderID: AnyHashable, iconIndex: Int) throws {
        try openPanel(host, folderID: folderID)
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        let icon = try XCTUnwrap(panel.shortcutCells[iconIndex] as TesseraTileCell?)
        let iconFrame = try XCTUnwrap(icon.superview).convert(icon.frame, to: host.host.grid)
        // A long press on the panel starts a reorder, and the take-out is entered immediately.
        host.coordinator.startDragFromPanel(at: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
        XCTAssertTrue(host.coordinator.isDragging)
    }

    /// An item frame in the **base** layout of the drag session (grid coordinates): the grid's
    /// own frames right after the lift are still following the batch animation of the displayed snapshot.
    private func baseFrame(_ host: TesseraTestDragHost, _ id: AnyHashable) throws -> CGRect {
        let session = try XCTUnwrap(host.coordinator.dragSession)
        let content = try XCTUnwrap(host.host.grid.baseContentFrames(
            for: session.baseSnapshot.items,
            placementTable: session.baseSnapshot.placementTable
        ))
        return host.host.grid.gridFrame(fromContentFrame: try XCTUnwrap(content[id]))
    }

    private func basePoint(_ host: TesseraTestDragHost, _ id: AnyHashable) throws -> CGPoint {
        let frame = try baseFrame(host, id)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func settle(_ host: TesseraTestDragHost, _ id: AnyHashable) {
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs }, "The grid equals the model")
        XCTAssertTrue(host.waitForDragCleanup(id))
        XCTAssertNil(host.coordinator.dragSession)
    }

    private func assertFrame(
        _ actual: CGRect?,
        _ expected: CGRect?,
        _ message: String,
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

    /// The test bench: folder F (medium, (0,0)) made of `contents`, tiles `a` (0,3) and `b` (2,3).
    private func makeHost(
        contents: [(String, TesseraTileSize)] = [("x", .small), ("y", .medium)],
        extraFolders: [CellFixtureFolder] = []
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("b", .small, 2, 3)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)] + extraFolders
        )
    }

    // MARK: - Unpin in the panel

    /// A two-tile folder: unpinning a tile of the opened panel closes the panel (animated),
    /// the remaining tile takes the folder's place, focus goes to it; the delegate receives
    /// `didUnpin`, then `didDissolveFolder`.
    func testUnpinInsideTwoTileFolderPanelClosesAndFocusesRemainingTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host, folderID: "F")
        let folderCell = try XCTUnwrap(host.store.placement(of: "F"))

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty }, "focus is posted")
        XCTAssertTrue(host.waitForFolderTransitionDone())

        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertFalse(host.gridIDs.contains("F"), "There is no folder tile on the grid")
        XCTAssertEqual(host.store.placement(of: "y"), folderCell, "The remaining tile is on the folder's cell")
        XCTAssertEqual(host.store.snapshot().item(withID: "y")?.size, .medium)
        XCTAssertEqual(host.gridIDs, host.storeIDs)
        assertFocus(posts, on: host.host.cell("y"), "focus is on the remaining tile (the new grid item)")
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
        XCTAssertFalse(host.store.isPinned("x"))
        host.coordinator.endEditing()
    }

    /// Reduce Motion: the panel closes instantly, the result is the same.
    func testUnpinInsideTwoTileFolderWithReduceMotionClosesPanelInstantly() throws {
        let host = try makeHost()
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        let posts = record(host)
        try openPanel(host, folderID: "F")

        host.coordinator.unpin("y")
        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed immediately")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertTrue(host.folders.isEmpty)
        assertFocus(posts, on: host.host.cell("x"), "focus is on the remaining tile")
        host.coordinator.endEditing()
    }

    /// A three-tile folder: the panel stays, focus goes to the next tile of the panel.
    func testUnpinInsideThreeTileFolderKeepsPanelAndFocusesNextTile() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host, folderID: "F")

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertEqual(host.host.grid.expandedFolderID, "F", "The panel stayed")
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["y", "z"] as [AnyHashable])
        let panel = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertEqual(panel.shortcutCells.count, 2)
        assertFocus(posts, on: panel.shortcutCells[0], "the one after x is y (first in the panel)")
        XCTAssertEqual(recorder.events, ["unpin:x"], "The folder did not dissolve — no dissolve event")
        host.coordinator.endEditing()
    }

    /// The last tile of the panel: focus goes to the previous one; the middle one — to the next.
    func testUnpinInsideThreeTileFolderFocusesPreviousForLastAndNextForMiddle() throws {
        let last = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let lastPosts = record(last)
        try openPanel(last, folderID: "F")
        last.coordinator.unpin("z")
        XCTAssertTrue(last.waitUntil { !lastPosts.posts.isEmpty })
        let lastPanel = try XCTUnwrap(last.host.panelCell(folderID: "F"))
        XCTAssertEqual(last.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable])
        assertFocus(lastPosts, on: lastPanel.shortcutCells[1], "for the last one — the previous y")

        let middle = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let middlePosts = record(middle)
        try openPanel(middle, folderID: "F")
        middle.coordinator.unpin("y")
        XCTAssertTrue(middle.waitUntil { !middlePosts.posts.isEmpty })
        let middlePanel = try XCTUnwrap(middle.host.panelCell(folderID: "F"))
        assertFocus(middlePosts, on: middlePanel.shortcutCells[1], "the one after y is z, now second")
        last.coordinator.endEditing()
        middle.coordinator.endEditing()
    }

    /// The panel is closed: focus goes to the folder tile (it does not go to a missing cell).
    func testUnpinInsideClosedThreeTileFolderFocusesFolderTile() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        let posts = record(host)

        host.coordinator.unpin("y")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "z"] as [AnyHashable])
        assertFocus(posts, on: host.host.cell("F"), "no panel — focus on the folder tile")
    }

    /// A closed two-tile folder: dissolving without a panel — focus on the remaining tile.
    func testUnpinInsideClosedTwoTileFolderFocusesRemainingTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)

        host.coordinator.unpin("x")
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertTrue(host.folders.isEmpty)
        assertFocus(posts, on: host.host.cell("y"), "the remaining tile")
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
    }

    /// The VoiceOver "Unpin" action on a panel tile follows the same route.
    func testVoiceOverUnpinActionOnPanelTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        let panel = try openPanel(host, folderID: "F")
        let unpinName = TesseraStartScreenStrings.string(.a11yActionUnpin)
        let actions = panel.shortcutCells[0].accessibilityCustomActions ?? []
        XCTAssertTrue(actions.contains { $0.name == unpinName }, "the \"Unpin\" action on a panel tile")
        let unpin = try XCTUnwrap(actions.first { $0.name == unpinName })

        XCTAssertEqual(unpin.actionHandler?(unpin), true)
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
        host.coordinator.endEditing()
    }

    // MARK: - Public take-out without a gesture

    /// `moveBetweenFolders(_:to: nil)` on a two-tile folder: the panel closes,
    /// the remaining tile is in the folder's place, the tile taken out is on the first free cell
    /// after it; `didMove`, then `didDissolveFolder`; focus goes to the tile taken out.
    func testPublicMoveToDesktopDissolvesTwoTileFolder() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small)])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host, folderID: "F")

        XCTAssertTrue(host.coordinator.moveBetweenFolders("x", to: nil))
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        XCTAssertTrue(host.waitForFolderTransitionDone())

        XCTAssertNil(host.host.grid.expandedFolderID)
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placement(of: "y"), at(0, 0), "the remaining one is on the folder's cell")
        let moved = try XCTUnwrap(host.store.placement(of: "x"))
        XCTAssertNotEqual(moved, at(0, 0), "the tile taken out did not land on the remaining one")
        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertTrue(recorder.events.first?.hasPrefix("move:x>nil@") == true)
        XCTAssertEqual(recorder.events.last, "dissolve:F>y")
        assertFocus(posts, on: host.host.cell("x"), "focus is on the tile taken out")
        host.coordinator.endEditing()
    }

    // MARK: - Drag from the panel: preview

    /// A two-tile folder: over a placement cell the preview shows the outcome (the folder is replaced
    /// by the remaining tile on its cell, the tile taken out is on the cell), over the home folder and
    /// a merge — the base (the folder), cancellation restores the folder with both tiles.
    func testPreviewShowsDissolvedPictureOverCellAndBaseOverSourceFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        // Start: the base is the folder with the remaining tile and a synthetic tile.
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"))
        XCTAssertNil(host.host.grid.frame(forItemID: "y"), "the remaining tile is still inside the folder")
        XCTAssertEqual(host.store.snapshot().folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable])
        let baseFolderFrame = try baseFrame(host, "F")

        // A placement cell (an empty cell inside occupied rows): the outcome.
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(2, 1)))
        XCTAssertNil(host.host.grid.frame(forItemID: "F"), "Preview: no folder")
        assertFrame(host.host.grid.frame(forItemID: "y"), baseFolderFrame, "Preview: the remaining tile is on the folder's cell")
        assertFrame(
            host.host.grid.frame(forItemID: "x"),
            host.cellFrame(row: 2, column: 1),
            "Preview: the tile taken out is on the cell"
        )
        XCTAssertEqual(host.store.snapshot().folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable], "The model does not change during the drag")

        // Over the home folder — the base.
        host.coordinator.updateDrag(to: try basePoint(host, "F"))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .sourceFolder)
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"), "Over the home folder — the base: the folder is in place")
        XCTAssertNil(host.host.grid.frame(forItemID: "y"))

        // On a cell again — the outcome (the preview is computed from the base, without accumulation).
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 2)))
        XCTAssertNil(host.host.grid.frame(forItemID: "F"))
        assertFrame(host.host.grid.frame(forItemID: "y"), baseFolderFrame, "the remaining tile is in place")
        assertFrame(host.host.grid.frame(forItemID: "x"), host.cellFrame(row: 2, column: 2), "the tile taken out is on the new cell")

        // Cancellation: the folder with both tiles, grid = model, no event.
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable], "The folder is restored")
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"))
        XCTAssertNil(host.host.grid.frame(forItemID: "y"))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    /// A three-tile folder: the target-placement preview does not dissolve the folder.
    func testPreviewOfThreeTileFolderKeepsFolder() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small)])
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))

        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(2, 1)))
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"), "The three-tile folder remained")
        XCTAssertNil(host.host.grid.frame(forItemID: "y"))
        XCTAssertNil(host.coordinator.dragSession?.folderDissolution)
        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
    }

    // MARK: - Drag from the panel: drop

    /// A drop on an empty cell: tiles land exactly where the preview showed (frames
    /// and the cell table are equal), the folder is dissolved, the delegate receives `didMove`, then
    /// `didDissolveFolder`.
    func testDropOnHoleCommitsPreviewAndDissolvesFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(2, 1)))
        let previewCells = try XCTUnwrap(host.gridCells)
        let previewY = try XCTUnwrap(host.host.grid.frame(forItemID: "y"))
        let previewX = try XCTUnwrap(host.host.grid.frame(forItemID: "x"))
        XCTAssertEqual(changes, 0, "The model is not written during the drag")

        host.coordinator.finishDrag(commit: true)
        settle(host, "x")

        XCTAssertEqual(changes, 1, "One notification per operation")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placements(forColumns: 4), previewCells, "Model = preview")
        assertFrame(host.host.grid.frame(forItemID: "y"), previewY, "the remaining tile is where the preview showed")
        assertFrame(host.host.grid.frame(forItemID: "x"), previewX, "the tile taken out is where the preview showed")
        XCTAssertEqual(host.store.placement(of: "x"), at(2, 1))
        XCTAssertEqual(host.store.placement(of: "y"), at(0, 0))
        XCTAssertEqual(recorder.events, ["move:x>nil@(2,1)", "dissolve:F>y"])
    }

    /// A drop on the edge of the home folder: the tile taken out takes the folder's cell, the remaining one
    /// is pushed down (the usual placement rules) — the model equals the preview.
    func testDropOnSourceFolderEdgeMatchesPreview() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small)])
        try startPanelDrag(host, folderID: "F", iconIndex: 0)
        let frame = try XCTUnwrap(host.host.grid.frame(forItemID: "F"))

        host.coordinator.updateDrag(to: CGPoint(x: frame.minX + 2, y: frame.midY))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(at(0, 0)))
        let previewCells = try XCTUnwrap(host.gridCells)
        host.coordinator.finishDrag(commit: true)
        settle(host, "x")

        XCTAssertEqual(host.store.placement(of: "x"), at(0, 0))
        XCTAssertEqual(host.store.placement(of: "y"), at(1, 0), "the remaining one is pushed down")
        XCTAssertEqual(host.store.placements(forColumns: 4), previewCells, "Model = preview")
        XCTAssertTrue(host.folders.isEmpty)
    }

    /// A drop on the center of another folder (after a hold): the source is dissolved, the target received the
    /// tile; the delegate: `didMove`, then `didDissolveFolder`.
    func testDropOnOtherFolderDissolvesSourceFolder() throws {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
                CellFixtureFolder("G", .medium, 3, 0, contents: [("p", .small), ("q", .small)]),
            ]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try basePoint(host, "G"))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .folder("G"))
        XCTAssertTrue(host.waitUntil { host.coordinator.mergeTracker?.isMergeReady == true })
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })

        XCTAssertEqual(host.folders.map { $0.id }, ["G"] as [AnyHashable])
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["p", "q", "x"] as [AnyHashable])
        XCTAssertEqual(host.store.placement(of: "y"), at(0, 0), "the remaining tile is in F's place")
        XCTAssertEqual(recorder.events, ["move:x>G@-", "dissolve:F>y"])
    }

    /// The host refused the take-out: the model did not change, the folder is restored, no dissolve.
    func testHostRejectionRestoresFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .moveBetweenFolders }
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 2, column: 1)))
        XCTAssertNil(host.host.grid.frame(forItemID: "F"), "in the preview the folder is already dissolved")
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.waitUntil { host.gridIDs == host.storeIDs })

        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable], "The folder is restored")
        XCTAssertNotNil(host.host.grid.frame(forItemID: "F"))
        XCTAssertEqual(recorder.failures, [.moveBetweenFolders])
        XCTAssertFalse(recorder.events.contains { $0.hasPrefix("dissolve") })
    }

    /// A new row: the preview is computed with the remaining tile in the folder's place.
    func testDropToNewRowMatchesPreview() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .large)])
        try startPanelDrag(host, folderID: "F", iconIndex: 0)

        let bounds = host.host.grid.bounds
        host.coordinator.updateDrag(to: CGPoint(x: bounds.midX, y: bounds.maxY - 3))
        XCTAssertEqual(host.coordinator.dragSession?.hover, .newRow)
        let previewCells = try XCTUnwrap(host.gridCells)
        host.coordinator.finishDrag(commit: true)
        settle(host, "x")

        XCTAssertEqual(host.store.placements(forColumns: 4), previewCells, "Model = preview")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.snapshot().item(withID: "y")?.size, .large)
    }
}

private extension TesseraTestDragHost {

    /// Waits until the folder panel finishes its transition and the grid applies the deferred snapshot.
    func waitForFolderTransitionDone() -> Bool {
        host.waitForFolderTransition() && waitUntil { self.gridIDs == self.storeIDs }
    }
}

#endif
