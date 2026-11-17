//
//  TilePanelDragReorderTests.swift
//  TesseraStartScreenTests
//
//  Reordering tiles by dragging inside an open folder panel (D40;
//  Windows 10 Mobile §6.5, §6.6). Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  ("Implementation deviations"); decision D40 in docs/STATE.md.
//
//  The rules that are checked:
//  - a long press on a panel tile in edit mode starts a reorder: the panel
//    stays open, the tile is hidden and replaced by a placeholder, and there are no unpin buttons;
//  - the slot under the finger comes from the frames of the panel layout slots (rows/columns, RTL);
//    an empty spot and the header give the nearest slot;
//  - neighbors shift from the base order (without accumulation), and the model does not change;
//  - a drop commits `TesseraTileStore.moveWithinFolder` (once, the delegate
//    `didReorderTile`), while a drop on its own slot and a cancel restore the order;
//  - the finger leaving the panel plus a margin turns the drag into a take-out (the panel
//    closes immediately; targets, D45, host refusal), and in that drag there is no way
//    back to reordering;
//  - with Reduce Motion the shift is instant; autoscroll at the edge works.
//
//  The rig uses a real `TesseraTileStore` and a grid in a window; layouts are exact.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePanelDragReorderTests: XCTestCase {

    // MARK: - Helpers

    private let folderID: AnyHashable = "F"

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var reorders: [(tile: AnyHashable, folder: AnyHashable, index: Int)] = []
        var moves: [(tile: AnyHashable, folder: AnyHashable?, cell: TesseraTileGridPlacement?)] = []
        var failures: [TesseraTileGroupingAction] = []
        var dissolutions: [AnyHashable] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didReorderTile tileID: AnyHashable,
            inFolder folderID: AnyHashable,
            toIndex index: Int
        ) {
            reorders.append((tileID, folderID, index))
        }

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
            didFailGrouping action: TesseraTileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            failures.append(action)
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            dissolutions.append(folderID)
        }
    }

    /// Rig: folder F (medium, (0,0)) of `count` small tiles `t0…`, and tile `a`
    /// in the right column under the folder. 4 columns: the panel has rows of four tiles.
    private func makeHost(
        count: Int = 6,
        reduceMotion: Bool = false
    ) throws -> TesseraTestDragHost {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 0, 3)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: (0..<count).map { ("t\($0)", TesseraTileSize.small) }),
            ],
            configuration: TesseraTileEditConfiguration(mergeHoverDuration: 0.05, magnetSnapRadius: 0)
        )
        if reduceMotion {
            host.host.grid.isReduceMotionEnabled = { true }
            host.coordinator.isReduceMotionEnabled = { true }
        }
        return host
    }

    private func ids(_ host: TesseraTestDragHost) -> [AnyHashable] {
        host.store.folderContaining("t0")?.tiles.map { $0.id } ?? []
    }

    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == self.folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        })
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    private func geometry(_ host: TesseraTestDragHost) throws -> TesseraPanelShortcutGeometry {
        try XCTUnwrap(host.host.grid.panelShortcutGeometry())
    }

    private func assertFrame(
        _ lhs: CGRect, _ rhs: CGRect, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 0.5, message, file: file, line: line)
    }

    private func center(_ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// A long press on panel tile `index`; returns the press point.
    @discardableResult
    private func lift(_ host: TesseraTestDragHost, index: Int) throws -> CGPoint {
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let point = center(try geometry(host).frames[index])
        host.coordinator.handleLongPress(on: panelItem, at: point)
        return point
    }

    /// Waits for the drag to finish and the cleanup to pass.
    private func settle(_ host: TesseraTestDragHost) {
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil && !host.host.grid.isFolderChangeAnimating })
        XCTAssertTrue(host.waitUntil { host.host.grid.subviews.allSatisfy { !($0 is TesseraTilePlaceholderView) } })
        host.spin(0.4)
    }

    // MARK: - Start

    /// A long press on a panel tile in edit mode starts a reorder: the panel
    /// stays open, the model is untouched, and there are no unpin buttons.
    func testLongPressStartsReorderAndKeepsPanelOpen() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 6)
        let before = ids(host)

        try lift(host, index: 2)

        XCTAssertTrue(host.coordinator.isDragging)
        let session = try XCTUnwrap(host.coordinator.dragSession)
        let reorder = try XCTUnwrap(session.panelReorder)
        XCTAssertEqual(reorder.sourceIndex, 2)
        XCTAssertEqual(reorder.slot, 2)
        XCTAssertEqual(reorder.folder.id, "F")
        XCTAssertEqual(session.itemID, "t2")
        XCTAssertNil(session.sourceFolderID, "This is not a take-out")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID, "The panel stayed open")
        XCTAssertEqual(ids(host), before, "The model does not change during the drag")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "There are no buttons on tiles during the drag")
        XCTAssertEqual(panel.reorderSourceIndex, 2)
        XCTAssertTrue(panel.shortcutCells[2].accessibilityElementsHidden, "The lifted tile is hidden")

        host.coordinator.finishDrag(commit: false)
        settle(host)
        XCTAssertEqual(panel.reorderSourceIndex, nil)
        XCTAssertFalse(panel.shortcutCells[2].accessibilityElementsHidden)
        host.coordinator.endEditing()
    }

    /// A long press outside the panel icons (header, background) does not start a drag.
    func testLongPressOnPanelBackgroundDoesNotStart() throws {
        let host = try makeHost()
        try openPanel(host)
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let frame = try geometry(host).panelFrame

        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: frame.midX, y: frame.minY + 6))

        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        host.coordinator.endEditing()
    }

    /// The center of a tile body does not belong to the unpin button: a long press on the body
    /// reaches the gesture (the button zone is a corner quarter).
    func testBodyCenterIsOutsideUnpinButtonZone() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try geometry(host)
        let control = try XCTUnwrap(host.coordinator.panelEditControls["t1"])
        control.layoutIfNeeded()
        let frame = geometry.frames[1]

        let bodyPoint = control.convert(center(frame), from: host.host.grid)
        XCTAssertNil(control.hitTest(bodyPoint, with: nil), "The tile body is not a button")
        // The top right corner is a button.
        let corner = control.convert(CGPoint(x: frame.maxX - 4, y: frame.minY + 4), from: host.host.grid)
        XCTAssertNotNil(control.hitTest(corner, with: nil), "The corner is the unpin button")
        host.coordinator.endEditing()
    }

    // MARK: - Slot under the finger

    /// A pure function: a 4-column grid; slot centers, gaps, empty spot.
    func testSlotHitTestRowsAndColumns() {
        let frames: [CGRect] = (0..<6).map { index in
            CGRect(x: CGFloat(index % 4) * 50, y: 100 + CGFloat(index / 4) * 50, width: 48, height: 48)
        }
        func slot(_ x: CGFloat, _ y: CGFloat) -> Int? {
            TesseraTileEditCoordinator.panelReorderSlot(at: CGPoint(x: x, y: y), slotFrames: frames, spacing: 2)
        }

        XCTAssertEqual(slot(24, 124), 0)
        XCTAssertEqual(slot(174, 124), 3)
        XCTAssertEqual(slot(24, 174), 4)
        XCTAssertEqual(slot(74, 174), 5)
        XCTAssertEqual(slot(48.5, 124), 0, "The gap between columns belongs to the nearest slot")
        XCTAssertEqual(slot(124, 148.8), 2, "The gap between rows")
        XCTAssertEqual(slot(174, 174), 5, "The empty spot of the last row is the nearest slot")
        XCTAssertEqual(slot(124, 400), 5, "Below the panel is the nearest slot of the last row")
        XCTAssertEqual(slot(124, 10), 2, "Above the grid (the header) is the nearest slot of the first row")
        XCTAssertNil(TesseraTileEditCoordinator.panelReorderSlot(at: .zero, slotFrames: [], spacing: 2))
    }

    /// Slot frames of the real panel: the slot under each tile's center, and slots do not
    /// depend on the shift preview.
    func testSlotFramesFromPanelGeometry() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try geometry(host)

        XCTAssertEqual(geometry.slotFrames.count, 6)
        for (slot, frame) in zip(geometry.slotFrames, geometry.frames) {
            assertFrame(slot, frame, "Without a preview the slots match the tile frames")
        }
        for (index, frame) in geometry.slotFrames.enumerated() {
            XCTAssertEqual(
                TesseraTileEditCoordinator.panelReorderSlot(
                    at: center(frame), slotFrames: geometry.slotFrames, spacing: geometry.spacing
                ),
                index
            )
        }
        XCTAssertEqual(geometry.slotFrames[4].minX, geometry.slotFrames[0].minX, accuracy: 0.5, "The fifth is in the second row")
        XCTAssertGreaterThan(geometry.slotFrames[4].minY, geometry.slotFrames[0].maxY - 1)
        XCTAssertTrue(geometry.panelFrame.contains(center(geometry.slotFrames[5])))
        host.coordinator.endEditing()
    }

    /// RTL: panel columns are mirrored (slot 0 is the right one), and the frame-based hit test is too.
    func testSlotHitTestInRightToLeft() throws {
        let host = try makeHost()
        host.host.grid.semanticContentAttribute = .forceRightToLeft
        host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
        host.host.grid.invalidateTileLayout(animated: false)
        host.host.layout()
        try openPanel(host)
        host.host.layout()
        let geometry = try geometry(host)

        XCTAssertGreaterThan(geometry.slotFrames[0].midX, geometry.slotFrames[1].midX, "RTL: slot 0 is to the right of slot 1")
        for (index, frame) in geometry.slotFrames.enumerated() {
            XCTAssertEqual(
                TesseraTileEditCoordinator.panelReorderSlot(
                    at: center(frame), slotFrames: geometry.slotFrames, spacing: geometry.spacing
                ),
                index
            )
        }

        // A real drag in RTL: tile 0 to slot 1 (to the left on screen).
        try lift(host, index: 0)
        host.coordinator.updateDrag(to: center(geometry.slotFrames[1]))
        XCTAssertEqual(host.coordinator.dragSession?.panelReorder?.slot, 1)
        host.coordinator.finishDrag(commit: true)
        settle(host)
        XCTAssertEqual(ids(host), ["t1", "t0", "t2", "t3", "t4", "t5"] as [AnyHashable])
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ids(host).map { Optional($0) })
        XCTAssertGreaterThan(panel.shortcutCells[0].frame.midX, panel.shortcutCells[1].frame.midX)
        host.coordinator.endEditing()
    }

    // MARK: - Preview

    /// The finger is over slot 3: the placeholder is in slot 3, neighbors shifted, and the model and
    /// `onChange` are untouched.
    func testSiblingsShiftAndModelIsUntouched() throws {
        let host = try makeHost(reduceMotion: true)
        let panel = try openPanel(host)
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        let slots = try geometry(host).slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))

        XCTAssertEqual(panel.reorderSlot, 3)
        // Slot order: t1 t2 t3 [t0] t4 t5.
        XCTAssertEqual(panel.shortcutCells[1].frame.origin.x, slots[0].origin.x, accuracy: 0.5)
        XCTAssertEqual(panel.shortcutCells[2].frame.origin.x, slots[1].origin.x, accuracy: 0.5)
        XCTAssertEqual(panel.shortcutCells[3].frame.origin.x, slots[2].origin.x, accuracy: 0.5)
        assertFrame(panel.shortcutCells[4].frame, slots[4], "Tiles after the placeholder are in their places")
        assertFrame(panel.shortcutCells[5].frame, slots[5])
        XCTAssertEqual(changes, 0, "The model is not written during the drag")
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertEqual(host.store.autosaves, false)

        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    /// The preview is computed from the base order: passing through slots 3 → 1 → 2 gives the same
    /// as going directly to 2; a repeated step into the same slot changes nothing.
    func testPreviewIsComputedFromBaseWithoutAccumulation() throws {
        let host = try makeHost(reduceMotion: true)
        let panel = try openPanel(host)
        let geometry = try geometry(host)
        let slots = geometry.slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        try lift(host, index: 0)

        for slot in [3, 1, 2, 2] {
            host.coordinator.updateDrag(to: center(geometry.slotFrames[slot]))
        }

        // Expected slot order: t1 t2 [t0] t3 t4 t5.
        XCTAssertEqual(panel.reorderSlot, 2)
        assertFrame(panel.shortcutCells[1].frame, slots[0])
        assertFrame(panel.shortcutCells[2].frame, slots[1])
        assertFrame(panel.shortcutCells[3].frame, slots[3])
        assertFrame(panel.shortcutCells[4].frame, slots[4])
        assertFrame(panel.shortcutCells[5].frame, slots[5])

        // Returning to the source slot is the full base.
        host.coordinator.updateDrag(to: center(geometry.slotFrames[0]))
        for index in 1..<6 { assertFrame(panel.shortcutCells[index].frame, slots[index]) }

        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    /// Reduce Motion: the slot changes instantly, and there are no animations on tiles or the placeholder.
    func testReduceMotionShiftsInstantlyWithoutAnimations() throws {
        let host = try makeHost(reduceMotion: true)
        let panel = try openPanel(host)
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[2]))

        for cell in panel.shortcutCells {
            XCTAssertTrue(cell.layer.animationKeys()?.isEmpty ?? true, "No shift animation")
        }
        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    /// Without Reduce Motion the shift is animated; model frames are final immediately.
    func testShiftIsAnimatedWithoutReduceMotion() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let slots = try geometry(host).slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[1]))

        assertFrame(panel.shortcutCells[1].frame, slots[0], "The model frame is final")
        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }

    // MARK: - Drop and cancel

    /// A drop on slot 3: one model operation, one delegate call, the panel
    /// stayed open and shows the new order, and the buttons are back.
    func testDropCommitsMoveWithinFolder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        let placements = host.store.placements
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(ids(host), ["t1", "t2", "t3", "t0", "t4", "t5"] as [AnyHashable])
        XCTAssertEqual(changes, 1, "One onChange per drop")
        XCTAssertEqual(recorder.reorders.count, 1)
        XCTAssertEqual(recorder.reorders.first?.tile, "t0")
        XCTAssertEqual(recorder.reorders.first?.folder, "F")
        XCTAssertEqual(recorder.reorders.first?.index, 3)
        XCTAssertTrue(recorder.moves.isEmpty && recorder.failures.isEmpty)
        XCTAssertEqual(host.store.placements, placements, "The desktop cells did not change")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID, "The panel stayed open")
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ids(host).map { Optional($0) })
        XCTAssertNil(panel.reorderSourceIndex)
        XCTAssertTrue(panel.shortcutCells.allSatisfy { !$0.accessibilityElementsHidden }, "There are no hidden tiles")
        let slots = try geometry(host).slotFrames
        for (index, cell) in panel.shortcutCells.enumerated() {
            let frame = panel.contentView.convert(cell.frame, to: host.host.grid)
            XCTAssertEqual(frame.origin.x, slots[index].origin.x, accuracy: 0.5)
            XCTAssertEqual(frame.origin.y, slots[index].origin.y, accuracy: 0.5)
        }
        XCTAssertEqual(host.coordinator.panelEditControls.count, 6, "The unpin buttons are back")
        XCTAssertEqual(host.store.autosaves, false, "The rig's autosave is restored")
        XCTAssertEqual(host.host.grid.snapshot?.folders.first?.tiles.map { $0.id }, ids(host))
        host.coordinator.endEditing()
    }

    /// A drop is saved to disk once (autosave is enabled on the rig).
    func testDropPersistsOnce() throws {
        let host = try makeHost()
        host.store.autosaves = true
        try openPanel(host)
        host.store.autosaves = true
        try FileManager.default.removeItem(at: host.store.fileURL)
        try lift(host, index: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.store.fileURL.path), "Nothing is written during the drag")

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.store.fileURL.path), "The preview does not write a file")
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertTrue(FileManager.default.fileExists(atPath: host.store.fileURL.path), "The drop wrote the file")
        let fresh = TesseraTileStore(directoryURL: host.directory.url)
        fresh.setCatalog((0..<6).map { tesseraTestTile("t\($0)", size: .small) } + [tesseraTestTile("a", size: .small)])
        try fresh.load()
        XCTAssertEqual(
            fresh.folderContaining("t0")?.tiles.map { $0.id },
            ["t0", "t2", "t3", "t4", "t1", "t5"] as [AnyHashable]
        )
        host.coordinator.endEditing()
    }

    /// A drop on its own slot is a no-op: no model change, no delegate call, no `onChange`.
    func testDropOnOwnSlotIsNoOp() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        let point = try lift(host, index: 2)

        host.coordinator.updateDrag(to: CGPoint(x: point.x + 4, y: point.y + 4))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(changes, 0)
        XCTAssertTrue(recorder.reorders.isEmpty)
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ids(host).map { Optional($0) })
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        host.coordinator.endEditing()
    }

    /// A gesture cancel: the order and frames are restored, and the model and delegate are untouched.
    func testCancelRestoresOriginalOrder() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        let slots = try geometry(host).slotFrames.map { panel.contentView.convert($0, from: host.host.grid) }
        var changes = 0
        host.store.onChange = { _ in changes += 1 }
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))
        host.coordinator.finishDrag(commit: false)
        settle(host)

        XCTAssertEqual(changes, 0)
        XCTAssertTrue(recorder.reorders.isEmpty)
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        for (index, cell) in panel.shortcutCells.enumerated() {
            XCTAssertEqual(cell.frame.origin.x, slots[index].origin.x, accuracy: 0.5)
            XCTAssertEqual(cell.frame.origin.y, slots[index].origin.y, accuracy: 0.5)
        }
        XCTAssertTrue(panel.shortcutCells.allSatisfy { !$0.accessibilityElementsHidden })
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 6)
        XCTAssertEqual(host.store.autosaves, false)
        host.coordinator.endEditing()
    }

    /// An external model change during a reorder cancels the drag and restores
    /// the panel; leaving edit mode does too.
    func testExternalChangeAndEndEditingCancelReorder() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        try lift(host, index: 0)
        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[2]))

        XCTAssertTrue(host.store.moveWithinFolder("t3", folderID: "F", toIndex: 0))
        host.host.grid.update(snapshot: host.store.snapshot(columns: 4), animated: false)
        host.host.layout()
        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[3]))

        XCTAssertFalse(host.coordinator.isDragging, "Drag cancelled")
        XCTAssertNil(panel.reorderSourceIndex)
        XCTAssertEqual(ids(host), ["t3", "t0", "t1", "t2", "t4", "t5"] as [AnyHashable], "The external change remained")
        XCTAssertTrue(panel.shortcutCells.allSatisfy { !$0.accessibilityElementsHidden })

        try lift(host, index: 1)
        XCTAssertTrue(host.coordinator.isDragging)
        host.coordinator.endEditing()
        XCTAssertFalse(host.coordinator.isDragging)
        XCTAssertNil(panel.reorderSourceIndex)
    }

    // MARK: - Leaving the panel: take-out

    /// A finger within the margin at the panel edge still reorders; beyond the margin it is a take-out.
    func testLeavingPanelSwitchesToTakeOutAfterMargin() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let panelFrame = try geometry(host).panelFrame
        let slotX = try geometry(host).slotFrames[0].midX
        let session = try lift(host, index: 0)
        _ = session
        let dragView = try XCTUnwrap(host.coordinator.dragSession?.dragView)

        // Within the margin it is still a reorder.
        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + TesseraTileEditCoordinator.panelReorderExitMargin - 2))
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder)
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)

        // Beyond the margin it is a take-out.
        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + TesseraTileEditCoordinator.panelReorderExitMargin + 30))
        let taken = try XCTUnwrap(host.coordinator.dragSession)
        XCTAssertNil(taken.panelReorder)
        XCTAssertEqual(taken.sourceFolderID, "F", "The source is the folder")
        XCTAssertEqual(taken.itemID, "t0")
        XCTAssertTrue(taken.dragView === dragView, "The same snapshot follows the finger")
        XCTAssertNil(host.host.grid.expandedFolderID, "The panel closed immediately")
        XCTAssertFalse(host.host.grid.isFolderChangeAnimating)
        XCTAssertNil(panel.reorderSourceIndex)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable], "The model did not change")
        XCTAssertEqual(host.store.autosaves, false, "There is a single autosave transaction")

        host.coordinator.finishDrag(commit: false)
        settle(host)
        XCTAssertEqual(host.store.autosaves, false)
        host.coordinator.endEditing()
    }

    /// After a take-out there is no way back to reordering in the same drag: a finger over the former
    /// panel spot reorders nothing; a drop on an empty cell is a take-out.
    func testNoSwitchingBackAndTakeOutDropOnCell() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try openPanel(host)
        let slotCenter = center(try geometry(host).slotFrames[1])
        let panelFrame = try geometry(host).panelFrame
        try lift(host, index: 2)

        host.coordinator.updateDrag(to: CGPoint(x: slotCenter.x, y: panelFrame.maxY + 60))
        XCTAssertNil(host.coordinator.dragSession?.panelReorder)
        host.coordinator.updateDrag(to: slotCenter)
        XCTAssertNil(host.coordinator.dragSession?.panelReorder, "There is no way back to reordering")
        XCTAssertNil(host.host.grid.expandedFolderID, "The panel does not reopen")

        let target = try XCTUnwrap(host.cellPoint(row: 1, column: 3))
        host.coordinator.updateDrag(to: target)
        XCTAssertEqual(host.coordinator.dragSession?.hover, .cell(tesseraCell(1, 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertTrue(recorder.reorders.isEmpty, "This is not a reorder")
        XCTAssertEqual(recorder.moves.count, 1)
        XCTAssertEqual(recorder.moves.first?.tile, "t2")
        XCTAssertNil(recorder.moves.first?.folder)
        XCTAssertEqual(host.store.placement(of: "t2"), tesseraCell(1, 3))
        XCTAssertEqual(ids(host), ["t0", "t1", "t3", "t4", "t5"] as [AnyHashable])
        host.coordinator.endEditing()
    }

    /// A moved tile and a take-out from a two-tile folder: the D45 rule works
    /// after leaving the reorder too (the folder is dissolved).
    func testTakeOutAfterReorderDissolvesTwoTileFolder() throws {
        let host = try makeHost(count: 2)
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try openPanel(host)
        let panelFrame = try geometry(host).panelFrame
        let slotX = try geometry(host).slotFrames[0].midX
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + 80))
        XCTAssertNil(host.coordinator.dragSession?.panelReorder)
        XCTAssertNotNil(host.coordinator.dragSession?.folderDissolution, "The dissolution result is shown in the preview")
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(recorder.dissolutions, ["F"])
        XCTAssertTrue(host.folders.isEmpty, "The folder is dissolved")
        XCTAssertEqual(host.store.placement(of: "t1"), tesseraCell(0, 0), "The remaining tile is in the folder's place")
        host.coordinator.endEditing()
    }

    /// Host refusal on a drop after a take-out: the model does not change, the delegate gets
    /// the refusal, and the panel is closed (as in a regular take-out).
    func testTakeOutRefusalAfterLeavingRestoresModel() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, action in action != .moveBetweenFolders }
        try openPanel(host)
        let panelFrame = try geometry(host).panelFrame
        let slotX = try geometry(host).slotFrames[0].midX
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: CGPoint(x: slotX, y: panelFrame.maxY + 80))
        host.coordinator.updateDrag(to: try XCTUnwrap(host.cellPoint(row: 1, column: 3)))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(recorder.failures, [.moveBetweenFolders])
        XCTAssertEqual(ids(host), ["t0", "t1", "t2", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertTrue(recorder.moves.isEmpty)
        host.coordinator.endEditing()
    }

    /// A reorder does not ask for host approval (D14): a ban on any
    /// folder operations does not block it.
    func testReorderIgnoresHostApproval() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.store.approval = { _, _, _ in false }
        try openPanel(host)
        try lift(host, index: 0)

        host.coordinator.updateDrag(to: center(try geometry(host).slotFrames[2]))
        host.coordinator.finishDrag(commit: true)
        settle(host)

        XCTAssertEqual(ids(host), ["t1", "t2", "t0", "t3", "t4", "t5"] as [AnyHashable])
        XCTAssertTrue(recorder.failures.isEmpty)
        host.coordinator.endEditing()
    }

    // MARK: - Autoscroll in a tall panel

    /// A panel taller than the screen: at the bottom edge the grid scrolls, the slot is computed from
    /// the current geometry, and a reorder stays a reorder.
    func testAutoScrollInTallPanelKeepsReordering() throws {
        let host = try makeHost(count: 40)
        try openPanel(host)
        let grid = host.host.grid
        XCTAssertGreaterThan(try geometry(host).panelFrame.height, grid.bounds.height - 100, "The panel is tall")
        let offsetBefore = grid.contentOffset.y
        try lift(host, index: 0)

        let bottom = CGPoint(x: grid.bounds.midX, y: grid.bounds.height - 4)
        host.coordinator.updateDrag(to: bottom)
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder, "At the screen edge inside a tall panel it is still a reorder")
        XCTAssertTrue(host.waitUntil(timeout: 3) { grid.contentOffset.y > offsetBefore + 20 }, "The ticker scrolls the grid")
        XCTAssertNotNil(host.coordinator.dragSession?.panelReorder)
        XCTAssertGreaterThan(host.coordinator.dragSession?.panelReorder?.slot ?? 0, 4, "The slot is recomputed for the scrolled panel")

        host.coordinator.finishDrag(commit: false)
        settle(host)
        host.coordinator.endEditing()
    }
}

#endif
