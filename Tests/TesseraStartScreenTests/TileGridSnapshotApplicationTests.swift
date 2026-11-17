//
//  TileGridSnapshotApplicationTests.swift
//  TesseraStartScreenTests
//
//  Diff-based snapshot application and grid cell state.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3
//  "Tile grid" (invalidation and batch updates), §4 "Live tiles"
//  (flips, pauses), §5 "Edit mode" (dim 0.7), §8 "Parallax"
//  (pausing off-screen live content), §9 "Accessibility"; D12 (a tile is an
//  action), D17 (folder panel); also the dim, the magnet and pixel
//  alignment (`gridMetrics`).
//
//  What is tested:
//  - a snapshot with a changed composition is applied as a diff: cells keep
//    the live tile registration (the flip is not reset to the front side) and
//    the idle flip phase of the folder preview;
//  - the owner of the 0.7 dim is the grid: the dim survives update/resize/drop;
//  - a tile of an expanded folder panel is activated through the shared `onTap` route and is not
//    activated in edit mode;
//  - `magnetSlotCenters(for:)` matches the layout frames to the pixel
//    (`TesseraTileLayoutEngine.gridMetrics`);
//  - the public live content pause is not lifted by `grid.update` bypassing
//    the controller while START is off screen.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridSnapshotApplicationTests: XCTestCase {

    // MARK: - Environment

    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Snapshot diff: live tiles

    /// A composition change no longer goes through `reloadData`: the live cell is kept
    /// together with its container, so a flip to the back side is not reset to the
    /// front side (this used to break live tiles on every badge update).
    func testSnapshotDiffPreservesLiveTileFlip() throws {
        let live = tesseraTestLiveTile(
            "live",
            front: TesseraLiveTileFace(title: "Front"),
            back: TesseraLiveTileFace(title: "Back"),
            size: .medium
        )
        let other = tesseraTestTile("other", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(live), .tile(other)])
        host.layout()

        let liveView = try XCTUnwrap(
            host.firstSubview(of: TesseraLiveTileView.self),
            "The live tile is on screen"
        )
        let liveCell = try XCTUnwrap(host.cell(live.id))
        liveView.show(.back, animated: false)
        XCTAssertEqual(liveView.side, .back)

        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [.tile(live), .tile(other), .tile(extra)],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        let liveViewAfter = try XCTUnwrap(host.firstSubview(of: TesseraLiveTileView.self))
        XCTAssertTrue(liveViewAfter === liveView, "The live tile container is kept")
        XCTAssertTrue(host.cell(live.id) === liveCell, "The cell is kept by the diff")
        XCTAssertEqual(
            liveViewAfter.side,
            .back,
            "The flip is not reset to the front side on a composition change"
        )
        XCTAssertFalse(liveViewAfter.isFlipping)
    }

    // MARK: - Snapshot diff: folder preview

    /// The closed folder preview keeps its idle flip: cell reuse on
    /// `reloadData` used to reset the mini-tiles to icons, now the composition is applied
    /// as a diff and the preview state is not restarted.
    func testSnapshotDiffPreservesFolderPreviewFlip() throws {
        // The idle flip of the preview is possible only for a tile with a visible
        // badge: `TesseraFolderMiniTileView.showBadge` ignores `.none`.
        let folder = TesseraTileFolder(
            id: "folder",
            title: "folder",
            tiles: (0..<4).map {
                tesseraTestTile("folder-tile\($0)", size: .small, badge: .count($0 + 1))
            }
        )
        let other = tesseraTestTile("other", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(items: [.folder(folder), .tile(other)])
        host.layout()

        let cell = try XCTUnwrap(host.cell(folder.id))
        let preview = try XCTUnwrap(cell.folderPreviewView)
        let miniTile = try XCTUnwrap(preview.miniTileViews.first)
        XCTAssertTrue(miniTile.hasVisibleBadge, "The folder tile has a badge")
        miniTile.showBadge(animated: false)
        XCTAssertTrue(miniTile.showsBadgeSide, "The mini-tile flipped to the badge")

        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [.folder(folder), .tile(other), .tile(extra)],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        let cellAfter = try XCTUnwrap(host.cell(folder.id))
        let previewAfter = try XCTUnwrap(cellAfter.folderPreviewView)
        let miniTileAfter = try XCTUnwrap(previewAfter.miniTileViews.first)
        XCTAssertTrue(cellAfter === cell, "The folder cell is kept")
        XCTAssertTrue(previewAfter === preview, "The folder preview is not recreated")
        XCTAssertTrue(miniTileAfter === miniTile)
        XCTAssertTrue(
            miniTileAfter.showsBadgeSide,
            "The idle flip of the preview is not reset to the icon"
        )
    }

    // MARK: - The "no animation" contract

    /// `reload(snapshot:)` and `update(animated: false)` must apply a composition change
    /// without animation: otherwise `performBatchUpdates` animates
    /// insert/delete with the default UIKit duration (about 0.25 s) and the
    /// "snapshot without animation" contract is broken. An internal flag is pinned
    /// by `UIView.performWithoutAnimation`; the animated path goes through a crossfade.
    func testNonAnimatedSnapshotApplicationDoesNotAnimateDiff() {
        let host = TesseraTestWindowedGrid(
            items: [.tile(tesseraTestTile("a", size: .small))]
        )
        host.layout()

        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [
                    .tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small)),
                ],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        XCTAssertTrue(
            host.grid.didApplyLastSnapshotWithoutAnimation,
            "The non-animated path is applied through UIView.performWithoutAnimation"
        )
        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertEqual(host.grid.items.count, 2)

        // reload(snapshot:) is also without animation.
        host.grid.reload(
            snapshot: TesseraTileGridSnapshot(
                items: [
                    .tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small)),
                    .tile(tesseraTestTile("c", size: .small)),
                ],
                unpinned: []
            )
        )
        host.layout()
        XCTAssertTrue(host.grid.didApplyLastSnapshotWithoutAnimation)

        // The animated path is a crossfade, not "without animation".
        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [
                    .tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small)),
                    .tile(tesseraTestTile("c", size: .small)),
                    .tile(tesseraTestTile("d", size: .small)),
                ],
                unpinned: []
            ),
            animated: true
        )
        host.layout()
        XCTAssertTrue(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertFalse(host.grid.didApplyLastSnapshotWithoutAnimation)
        XCTAssertEqual(host.grid.items.count, 4)
    }

    // MARK: - Dim owner

    /// The 0.7 edit mode dim survives a snapshot update, resize and
    /// returning from hiding for the duration of a drag: the opacity owner is the grid, not
    /// the cell's `configure`.
    func testEditDimmingSurvivesSnapshotUpdateResizeAndDrop() throws {
        let first = tesseraTestTile("first", size: .small)
        let second = tesseraTestTile("second", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(first), .tile(second)])
        host.layout()

        let targets: [AnyHashable: CGFloat] = [
            first.id: TesseraTileGridView.dimmedTileAlpha,
            second.id: TesseraTileGridView.dimmedTileAlpha,
        ]
        host.grid.setEditDimming(targets, animated: false)
        let cell = try XCTUnwrap(host.cell(first.id))
        XCTAssertEqual(
            cell.contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001
        )

        // 1) Snapshot update: only the content (badge) changes.
        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [
                    .tile(TesseraTileDescriptor(
                        id: first.id,
                        title: first.title,
                        action: {},
                        badge: .dot,
                        size: .small
                    )),
                    .tile(second),
                ],
                unpinned: []
            ),
            animated: false
        )
        host.layout()
        XCTAssertEqual(
            try XCTUnwrap(host.cell(first.id)).contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "The dim survived the update"
        )

        // 2) Resize: a size change repacks the grid.
        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [.tile(first), .tile(tesseraTestTile("second", size: .medium))],
                unpinned: []
            ),
            animated: false
        )
        host.layout()
        XCTAssertEqual(
            try XCTUnwrap(host.cell(first.id)).contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "The dim survived the resize"
        )

        // 3) Drop/unpin: hiding for the duration of a drag must not "raise" the tile to 1.
        host.grid.setItemHidden(true, forItemID: first.id)
        XCTAssertEqual(try XCTUnwrap(host.cell(first.id)).contentView.alpha, 0, accuracy: 0.001)
        host.grid.setItemHidden(false, forItemID: first.id)
        XCTAssertEqual(
            try XCTUnwrap(host.cell(first.id)).contentView.alpha,
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "After returning from hiding the dim remains, not full brightness"
        )

        // 4) Removing the dim returns full brightness.
        host.grid.setEditDimming(
            [first.id: 1, second.id: 1],
            animated: false
        )
        XCTAssertEqual(try XCTUnwrap(host.cell(first.id)).contentView.alpha, 1, accuracy: 0.001)
    }

    /// A real coordinator entering edit mode applies the dim through the grid, and
    /// a snapshot update in edit mode does not erase it.
    func testCoordinatorDimmingSurvivesGridUpdate() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false

        let first = tesseraTestTile("first", size: .small)
        let second = tesseraTestTile("second", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(first), .tile(second)])
        host.layout()

        let coordinator = TesseraTileEditCoordinator(grid: host.grid, store: store)
        coordinator.beginEditing()
        host.layout()

        XCTAssertTrue(
            host.waitUntil { [self] in
                let alpha = self.alpha(of: first.id, in: host)
                return abs(alpha - TesseraTileGridView.dimmedTileAlpha) < 0.001
            },
            "The edit mode dim is applied to the cells"
        )
        defer { coordinator.endEditing() }

        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [
                    .tile(TesseraTileDescriptor(
                        id: first.id,
                        title: first.title,
                        action: {},
                        badge: .count(2),
                        size: .small
                    )),
                    .tile(second),
                ],
                unpinned: []
            ),
            animated: false
        )
        host.layout()

        XCTAssertEqual(
            alpha(of: first.id, in: host),
            TesseraTileGridView.dimmedTileAlpha,
            accuracy: 0.001,
            "update in edit mode does not erase the dim"
        )
    }

    /// The opacity of an item's cell content.
    ///
    /// - Parameters:
    ///   - id: Item identifier.
    ///   - host: The window with the grid.
    /// - Returns: `contentView.alpha` of the visible cell, or 1 if there is none.
    private func alpha(of id: AnyHashable, in host: TesseraTestWindowedGrid) -> CGFloat {
        host.cell(id)?.contentView.alpha ?? 1
    }

    // MARK: - Tiles of the expanded folder panel

    /// Activating a tile inside the panel goes through the shared `onTap` route (the tile
    /// action is performed by the host, D12), not by calling `action` bypassing the event.
    func testPanelShortcutActivationGoesThroughOnTap() throws {
        var actionCalls = 0
        let inFolder = TesseraTileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        let folder = TesseraTileFolder(id: "folder", title: "Folder", tiles: [inFolder])
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])
        host.grid.openFolder(folder, animated: false)
        host.layout()

        let panel = try XCTUnwrap(host.panelCell(folderID: folder.id))
        let shortcut = try XCTUnwrap(panel.shortcutCells.first)

        var tapped: [TesseraTileGridItem] = []
        host.grid.onTap = { tapped.append($0) }

        XCTAssertTrue(shortcut.accessibilityActivate())
        XCTAssertEqual(tapped.count, 1, "The activation arrived in onTap")
        XCTAssertEqual(tapped.first?.tile?.id, inFolder.id)
        XCTAssertEqual(actionCalls, 0, "The panel does not call action directly")
        XCTAssertEqual(
            host.grid.expandedFolderID,
            folder.id,
            "Activating a tile does not close the folder"
        )
    }

    /// In edit mode the panel does not activate the tile action: the tap
    /// belongs to the coordinator.
    func testPanelShortcutDoesNotActivateInEditMode() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false

        var actionCalls = 0
        let inFolder = TesseraTileDescriptor(
            id: "in-folder",
            title: "Inside",
            action: { actionCalls += 1 },
            size: .small
        )
        let folder = TesseraTileFolder(id: "folder", title: "Folder", tiles: [inFolder])
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])
        host.grid.openFolder(folder, animated: false)
        host.layout()

        let coordinator = TesseraTileEditCoordinator(grid: host.grid, store: store)
        coordinator.beginEditing()
        host.layout()
        defer { coordinator.endEditing() }

        let panel = try XCTUnwrap(host.panelCell(folderID: folder.id))
        let shortcut = try XCTUnwrap(panel.shortcutCells.first)

        var tapped: [TesseraTileGridItem] = []
        host.grid.onTap = { tapped.append($0) }

        _ = shortcut.accessibilityActivate()

        XCTAssertTrue(tapped.isEmpty, "In edit mode the action is not activated")
        XCTAssertEqual(actionCalls, 0)
    }

    // MARK: - Magnet: slot centers = layout frames

    /// `magnetSlotCenters(for:)` computes the geometry through
    /// `TesseraTileLayoutEngine.gridMetrics`, so slot centers match the
    /// centers of the actual layout frames to the pixel (an unaligned unit
    /// used to diverge from the layout).
    func testMagnetSlotCentersMatchLayoutFrames() throws {
        let smallItems = (0..<5).map {
            TesseraTileGridItem.tile(tesseraTestTile("s\($0)", size: .small))
        }
        let host = TesseraTestWindowedGrid(items: smallItems)
        host.layout()

        let centers = host.grid.magnetSlotCenters(for: .small)
        XCTAssertEqual(centers.count, 4 * 2, "Four columns by two occupied rows")

        // A slot center need not be on the pixel grid (with an odd
        // unit width it lands on half a pixel). Alignment is guaranteed by
        // the layout, so the item frames are checked, and the slot centers are only compared
        // with the centers of those frames below.
        let scale = host.grid.traitCollection.displayScale > 0
            ? host.grid.traitCollection.displayScale
            : UIScreen.main.scale
        for item in smallItems {
            let frame = try XCTUnwrap(host.grid.frame(forItemID: item.id))
            for (value, label) in [
                (frame.minX, "minX"), (frame.minY, "minY"),
                (frame.width, "width"), (frame.height, "height"),
            ] {
                XCTAssertEqual(
                    (value * scale).rounded(),
                    value * scale,
                    accuracy: 1e-6,
                    "Frame \(item.id): \(label) on the pixel grid"
                )
            }
        }

        // The first row is occupied by four small tiles: their slot centers are
        // exactly the centers of the layout frames.
        for index in 0..<4 {
            let frame = try XCTUnwrap(host.grid.frame(forItemID: "s\(index)"))
            XCTAssertEqual(centers[index].x, frame.midX, accuracy: 1e-6)
            XCTAssertEqual(centers[index].y, frame.midY, accuracy: 1e-6)
        }
    }

    /// For a medium tile the slot center matches the center of its frame (2×2 units), including
    /// with non-standard insets: the horizontal follows the layout.
    func testMagnetSlotCentersMatchLayoutFramesWithInsets() throws {
        let medium = tesseraTestTile("m", size: .medium)
        let items: [TesseraTileGridItem] = [
            .tile(medium),
            .tile(tesseraTestTile("s0", size: .small)),
            .tile(tesseraTestTile("s1", size: .small)),
        ]
        let host = TesseraTestWindowedGrid(items: items)
        host.grid.contentInsets = UIEdgeInsets(top: 10, left: 21, bottom: 10, right: 9)
        host.grid.invalidateTileLayout(animated: false)
        host.layout()

        let centers = host.grid.magnetSlotCenters(for: .medium)
        XCTAssertEqual(centers.count, 3, "Two rows: a medium tile fits in three columns")

        let expected = try XCTUnwrap(host.grid.frame(forItemID: medium.id))
        XCTAssertEqual(centers[0].x, expected.midX, accuracy: 1e-6)
        XCTAssertEqual(centers[0].y, expected.midY, accuracy: 1e-6)
    }

    // MARK: - Public live content pause

    /// While START is off screen, `grid.update` bypassing the controller does not resume
    /// live tiles: the pause belongs to the grid and is accounted for in the cell configuration.
    func testLiveTilesStayPausedAfterGridUpdateWhileStartOffScreen() throws {
        let screen = TesseraStartScreenViewController()
        screen.configure(leftPanel: nil, rightPage: { UIViewController() })
        screen.gridView.liveTileConfiguration = TesseraLiveTileEngine.Configuration(
            cycleInterval: 0.8,
            flipDuration: 0.1,
            batchSize: 10,
            batchStagger: 0,
            jitter: 0,
            seed: 1
        )

        let live = tesseraTestLiveTile(
            "live",
            front: TesseraLiveTileFace(title: "Front"),
            back: TesseraLiveTileFace(title: "Back")
        )
        let first = tesseraTestTile("first", size: .small)
        let second = tesseraTestTile("second", size: .small)
        // Medium live + small in the same row: adding a second small does not
        // change the content height: the layout is not
        // restarted, only the grid applies the pause.
        screen.reload(grid: TesseraTileGridSnapshot(items: [.tile(live), .tile(first)], unpinned: []))
        let window = host(screen)
        appear(screen)

        let liveView = try XCTUnwrap(
            firstSubview(of: TesseraLiveTileView.self, in: screen.gridView),
            "The live tile is shown on START"
        )
        XCTAssertEqual(liveView.side, .front)

        screen.showPage(.applications, animated: false)
        layout(screen)
        XCTAssertEqual(screen.currentPage, .applications)
        XCTAssertTrue(
            screen.gridView.isLiveContentPaused,
            "START is off screen: the public live content pause is on"
        )

        // An update bypassing the controller: previously `willDisplay`
        // of a new cell registered it as visible and the flip resumed.
        screen.gridView.update(
            snapshot: TesseraTileGridSnapshot(
                items: [.tile(live), .tile(first), .tile(second)],
                unpinned: []
            ),
            animated: false
        )
        spin(1.3)

        let liveViewAfter = try XCTUnwrap(
            firstSubview(of: TesseraLiveTileView.self, in: screen.gridView)
        )
        XCTAssertTrue(liveViewAfter === liveView, "The live tile cell is kept")
        XCTAssertEqual(liveViewAfter.side, .front, "START is off screen: no flips")
        XCTAssertFalse(liveViewAfter.isFlipping)

        // Returning to START resumes the schedule.
        screen.showPage(.start, animated: false)
        XCTAssertFalse(screen.gridView.isLiveContentPaused)
        XCTAssertTrue(
            waitUntil(timeout: 3) { liveView.side == .back || liveView.isFlipping },
            "On START the flip schedule resumes"
        )
        window.isHidden = true
    }

    // MARK: - Controller helpers

    private let screenSize = CGSize(width: 390, height: 844)

    /// Embeds the screen in a window and finishes the layout (without appearance).
    ///
    /// - Parameter screen: The start screen.
    /// - Returns: The window, retained until `tearDown`.
    private func host(_ screen: TesseraStartScreenViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: screenSize))
        window.isHidden = false
        windows.append(window)

        screen.loadViewIfNeeded()
        screen.view.frame = window.bounds
        window.addSubview(screen.view)
        layout(screen)
        return window
    }

    /// Finishes the layout of the screen and its grid.
    ///
    /// - Parameter screen: The start screen.
    private func layout(_ screen: TesseraStartScreenViewController) {
        screen.view.layoutIfNeeded()
        screen.gridView.superview?.layoutIfNeeded()
        screen.gridView.layoutIfNeeded()
        screen.gridView.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    /// Notifies the screen of appearance (a double appearance is idempotent).
    ///
    /// - Parameter screen: The start screen.
    private func appear(_ screen: TesseraStartScreenViewController) {
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
    }

    /// Spins the run loop for the given time.
    ///
    /// - Parameter seconds: Wait duration.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits for a condition to hold, spinning the run loop.
    ///
    /// - Parameters:
    ///   - timeout: Maximum wait.
    ///   - condition: Readiness condition.
    /// - Returns: `true` if the condition was met.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// The first subview of the given type in the hierarchy.
    ///
    /// - Parameters:
    ///   - type: Subview type.
    ///   - root: Search root.
    /// - Returns: The found view or `nil`.
    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

#endif
