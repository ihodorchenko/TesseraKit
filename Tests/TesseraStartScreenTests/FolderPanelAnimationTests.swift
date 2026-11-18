//
//  FolderPanelAnimationTests.swift
//  TesseraStartScreenTests
//
//  Animations of the expanded folder panel.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, section "Tile grid",
//  section "Edit mode" (scroll locking), section "Accessibility"
//  (state announcements, `.layoutChanged`, Dynamic Type); D17/D18 in
//  docs/DECISIONS.md: the panel expands inline, at most one folder is
//  open at a time.
//
//  These tests cover the serialization of panel transitions:
//  - switching folder A -> B does not mix `reloadData` and `performBatchUpdates` in
//    one run loop pass (otherwise `NSInternalInconsistencyException`);
//  - `update(snapshot:)` in the middle of an open/close is remembered and applied
//    after the transition finishes;
//  - `isScrollEnabled` has a single owner: the drag coordinator's lock
//    survives the end of the panel animation;
//  - `clampContentOffsetAfterCollapse` also works in the non-animated close
//    branch;
//  - `.layoutChanged` is posted in all four branches (open/close ×
//    animated/non-animated), including Reduce Motion;
//  - the folder's `accessibilityValue` reports "expanded" without losing the tile count;
//  - the panel title font scales with Dynamic Type and fits into the
//    fixed row height of the panel.
//
//  The animations are real (UIViewPropertyAnimator + batch updates), so the
//  tests use a window: `TesseraTestWindowedGrid`. Transition completion is awaited by
//  spinning the run loop (`waitForFolderTransition`), without fixed pauses.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderPanelAnimationTests: XCTestCase {

    // MARK: - Helpers

    /// Grid without a window: non-animated branches and geometry without the UI loop.
    ///
    /// - Parameter items: Snapshot items in display order.
    /// - Returns: The laid-out grid.
    private func makeGrid(_ items: [TesseraTileGridItem]) -> TesseraTileGridView {
        let grid = TesseraTileGridView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        grid.columns = 4
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layout(grid)
        return grid
    }

    /// Runs layout of the grid and its collection: cells and frames are up to date.
    ///
    /// - Parameter grid: Grid.
    private func layout(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    /// Indices of the expanded folder panels in the collection's set.
    ///
    /// - Parameter grid: Grid.
    /// - Returns: Indices of the `folderContent` items.
    private func panelIndices(in grid: TesseraTileGridView) -> [Int] {
        grid.displayItems.indices.filter { grid.displayItems[$0].isFolderPanel }
    }

    // MARK: - Switching folder A -> B

    /// While folder A is open, a repeated tap on B must not trigger
    /// `reloadData` and `performBatchUpdates` in one run loop pass: A
    /// collapses immediately, B opens on the next pass. The result is exactly
    /// one open folder, and the host events come as a pair "A closed, B opened".
    func testOpeningAnotherFolderSerializesTransitions() {
        let first = tesseraTestFolder("first", tileCount: 4)
        let second = tesseraTestFolder("second", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(first), .folder(second)])

        var events: [(id: AnyHashable, expanded: Bool)] = []
        host.grid.onFolderExpansionChanged = { folder, expanded in
            events.append((folder.id, expanded))
        }

        host.grid.openFolder(first)
        XCTAssertTrue(host.waitForFolderTransition(), "Opening A finished")
        XCTAssertEqual(host.grid.expandedFolderID, first.id)

        host.grid.openFolder(second)
        XCTAssertTrue(
            host.waitUntil { host.grid.expandedFolderID == second.id },
            "Deferred opening of B was performed"
        )
        XCTAssertTrue(host.waitForFolderTransition(), "Opening B finished")
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, second.id)
        XCTAssertEqual(panelIndices(in: host.grid).count, 1, "Only B has a panel")
        let panels = panelIndices(in: host.grid)
        XCTAssertEqual(host.grid.displayItems[panels[0]].id, second.id)
        XCTAssertEqual(events.map { $0.id }, [first.id, first.id, second.id])
        XCTAssertEqual(events.map { $0.expanded }, [true, false, true])
    }

    // MARK: - Snapshot in the middle of an animation

    /// `update(snapshot:)` during the panel opening is not lost and does not land
    /// inside an unfinished batch update: it is applied after the transition,
    /// the expansion is kept, and the new item appears in the set.
    func testUpdateDuringOpeningAppliesAfterTransition() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let tile = tesseraTestTile("a", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(items: [.tile(tile), .folder(folder)])

        var events: [Bool] = []
        host.grid.onFolderExpansionChanged = { _, expanded in events.append(expanded) }

        host.grid.openFolder(folder)
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Opening animation is running")

        // The snapshot arrives in the middle of the 280 ms: the set is busy with the batch insertion of the panel.
        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [.tile(tile), .folder(folder), .tile(extra)],
                unpinned: []
            ),
            animated: true
        )
        XCTAssertFalse(
            host.grid.items.contains { $0.id == extra.id },
            "The snapshot waits for the transition to finish instead of being applied on top of the batch"
        )

        XCTAssertTrue(host.waitForFolderTransition(), "Transition finished")
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, folder.id, "Expansion is kept")
        XCTAssertEqual(host.grid.items.count, 3)
        XCTAssertTrue(host.grid.items.contains { $0.id == extra.id })
        XCTAssertEqual(panelIndices(in: host.grid).count, 1)
        XCTAssertEqual(events, [true], "The deferred snapshot did not close the folder")
    }

    /// `update(snapshot:)` during the panel closing is applied after the transition:
    /// the panel goes away, and the updated contents and the close event are not lost.
    func testUpdateDuringClosingAppliesAfterTransition() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let tile = tesseraTestTile("a", size: .small)
        let extra = tesseraTestTile("extra", size: .small)
        let host = TesseraTestWindowedGrid(
            items: [.tile(tile), .folder(folder), .tile(extra)]
        )

        var events: [Bool] = []
        host.grid.onFolderExpansionChanged = { _, expanded in events.append(expanded) }

        host.grid.openFolder(folder, animated: false)
        host.layout()
        XCTAssertEqual(host.grid.expandedFolderID, folder.id)

        host.grid.closeFolder()
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Closing animation is running")

        host.grid.update(
            snapshot: TesseraTileGridSnapshot(items: [.tile(tile), .folder(folder)], unpinned: []),
            animated: false
        )

        XCTAssertTrue(host.waitForFolderTransition(), "Closing finished")
        host.layout()

        XCTAssertNil(host.grid.expandedFolderID)
        XCTAssertEqual(panelIndices(in: host.grid).count, 0)
        XCTAssertEqual(host.grid.items.count, 2, "The deferred snapshot was applied")
        XCTAssertEqual(events, [true, false])
    }

    /// If the deferred snapshot was applied through `reloadData` (a fallback when
    /// the order of shared items changes), the deferred panel target is not executed in
    /// the same stack: otherwise `reloadData` + `performBatchUpdates` would again occur
    /// in one run loop pass. The target is rescheduled to the next pass.
    func testDeferredSnapshotAndFolderTargetDoNotShareRunLoopPass() {
        let first = tesseraTestFolder("first", tileCount: 3)
        let second = tesseraTestFolder("second", tileCount: 3)
        let tileA = tesseraTestTile("a", size: .small)
        let tileB = tesseraTestTile("b", size: .small)
        let host = TesseraTestWindowedGrid(
            items: [.folder(first), .tile(tileA), .tile(tileB), .folder(second)]
        )

        host.grid.openFolder(first)
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Opening A is running")

        // While the transition runs: the panel target (B) and a snapshot that removes A and
        // reorders the shared tiles, so it is applied through the fallback via
        // reloadData.
        host.grid.openFolder(second)
        host.grid.update(
            snapshot: TesseraTileGridSnapshot(
                items: [.tile(tileB), .tile(tileA), .folder(second)],
                unpinned: []
            ),
            animated: false
        )

        XCTAssertTrue(
            host.waitUntil(timeout: 3) {
                host.grid.expandedFolderID == second.id
                    && !host.grid.isFolderChangeAnimating
            },
            "The snapshot and the panel target are applied sequentially, without a crash"
        )
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, second.id)
        XCTAssertEqual(panelIndices(in: host.grid).count, 1)
        XCTAssertEqual(host.grid.items.map { $0.id }, [tileB.id, tileA.id, second.id])
        XCTAssertFalse(host.grid.isFolderChangeAnimating)
    }

    /// A repeated tap on a folder within the first ~0.12 s of closing is a target
    /// "open again", not a lost tap: the last target wins.
    func testRetapWhileClosingReopensFolder() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let tile = tesseraTestTile("a", size: .small)
        let host = TesseraTestWindowedGrid(items: [.folder(folder), .tile(tile)])

        host.grid.openFolder(folder, animated: false)
        host.layout()
        XCTAssertEqual(host.grid.expandedFolderID, folder.id)

        host.grid.closeFolder()
        XCTAssertTrue(host.grid.isFolderChangeAnimating, "Closing is running")

        // The folder is still counted as expanded (icons fade), but the user has already
        // changed their mind: the repeated tap must schedule an opening.
        host.grid.toggleFolder(folder)

        XCTAssertTrue(
            host.waitUntil(timeout: 3) {
                host.grid.expandedFolderID == folder.id
                    && !host.grid.isFolderChangeAnimating
            },
            "A repeated tap during closing brings the panel back"
        )
        host.layout()
        XCTAssertEqual(panelIndices(in: host.grid).count, 1)
    }

    // MARK: - Owner of isScrollEnabled

    /// The drag coordinator's scroll lock survives the end of the panel
    /// animation: the grid does not restore a stale `isScrollEnabled` snapshot.
    func testScrollLockSurvivesDragLockDuringPanelAnimation() {
        let folder = tesseraTestFolder("folder", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        host.grid.openFolder(folder)
        XCTAssertFalse(
            host.grid.isScrollEnabled,
            "Scrolling is locked for the duration of the panel animation"
        )

        // The drag coordinator enabled the lock while the panel is still growing.
        host.grid.isScrollEnabled = false
        XCTAssertTrue(host.waitForFolderTransition(), "Opening finished")

        XCTAssertFalse(
            host.grid.isScrollEnabled,
            "Releasing the panel's lock must not enable scrolling against the drag"
        )

        host.grid.isScrollEnabled = true
        XCTAssertTrue(host.grid.isScrollEnabled)
    }

    /// Without an external lock, scrolling returns right after the panel
    /// animation instead of staying disabled forever.
    func testScrollRestoredAfterPanelAnimation() {
        let folder = tesseraTestFolder("folder", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        host.grid.openFolder(folder)
        XCTAssertTrue(host.waitForFolderTransition())
        XCTAssertTrue(host.grid.isScrollEnabled)
    }

    // MARK: - contentOffset clamp

    /// A non-animated panel close (Reduce Motion / no window) also clamps
    /// `contentOffset`: the content became shorter, and the scroll position does not stay beyond
    /// its end.
    func testNonAnimatedCloseClampsContentOffset() {
        let folder = tesseraTestFolder("big", tileCount: 64)
        let grid = makeGrid([.folder(folder)])

        grid.openFolder(folder, animated: false)
        layout(grid)

        let expandedMaximum = max(0, grid.contentSize.height - grid.bounds.height)
        XCTAssertGreaterThan(expandedMaximum, 0, "The panel must make the content longer")

        grid.setContentOffset(
            CGPoint(x: 0, y: expandedMaximum),
            animated: false
        )
        XCTAssertEqual(grid.contentOffset.y, expandedMaximum, accuracy: 0.5)

        grid.closeFolder(animated: false)
        layout(grid)

        let collapsedMaximum = max(0, grid.contentSize.height - grid.bounds.height)
        XCTAssertEqual(
            grid.contentOffset.y,
            collapsedMaximum,
            accuracy: 0.5,
            "Non-animated close clamps the offset"
        )
        XCTAssertLessThan(grid.contentOffset.y, expandedMaximum)
    }

    // MARK: - .layoutChanged in all branches

    /// `.layoutChanged` is posted in both the animated and the non-animated
    /// expand/collapse branches, including Reduce Motion.
    func testLayoutChangedPostedInAllExpansionBranches() {
        let folder = tesseraTestFolder("folder", tileCount: 4)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        var posts: [UIAccessibility.Notification] = []
        var arguments: [Any?] = []
        host.grid.accessibilityNotificationPoster = { notification, argument in
            posts.append(notification)
            arguments.append(argument)
        }

        // Animated opening.
        host.grid.openFolder(folder)
        XCTAssertTrue(host.waitForFolderTransition())
        XCTAssertEqual(posts.count, 1)
        XCTAssertNotNil(arguments.first ?? nil, "Focus moves to the panel")

        // Animated closing.
        host.grid.closeFolder()
        XCTAssertTrue(host.waitForFolderTransition())
        XCTAssertEqual(posts.count, 2)
        XCTAssertNotNil(arguments.last ?? nil, "Focus returns to the folder")

        // Non-animated opening and closing.
        host.grid.openFolder(folder, animated: false)
        XCTAssertEqual(posts.count, 3)
        host.grid.closeFolder(animated: false)
        XCTAssertEqual(posts.count, 4)

        // Reduce Motion: the animated call goes through the non-animated branch, but
        // the notification and the host event are required.
        host.grid.isReduceMotionEnabled = { true }
        host.grid.openFolder(folder, animated: true)
        XCTAssertEqual(posts.count, 5)
        host.grid.closeFolder(animated: true)
        XCTAssertEqual(posts.count, 6)

        XCTAssertEqual(
            posts,
            Array(repeating: UIAccessibility.Notification.layoutChanged, count: 6)
        )
        XCTAssertFalse(host.grid.isFolderChangeAnimating)
    }

    // MARK: - Announcing "folder expanded"

    /// The folder's `accessibilityValue` reports "expanded" without losing the tile count;
    /// closing restores the previous value.
    func testFolderAccessibilityValueAnnouncesExpanded() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        cell.configure(with: .folder(folder), liveTileEngine: nil, isVisible: false)

        XCTAssertEqual(cell.accessibilityLabel, "folder")
        XCTAssertEqual(cell.accessibilityValue, "3")

        cell.setFolderExpanded(true)
        XCTAssertEqual(cell.accessibilityValue, "3, \(TesseraStartScreenStrings.string(.panelExpanded))")

        cell.setFolderExpanded(false)
        XCTAssertEqual(cell.accessibilityValue, "3")

        // Empty folder: there is no count, the state is announced separately.
        let empty = TesseraTileFolder(id: "empty", title: "empty")
        cell.configure(with: .folder(empty), liveTileEngine: nil, isVisible: false)
        XCTAssertNil(cell.accessibilityValue)
        cell.setFolderExpanded(true)
        XCTAssertEqual(cell.accessibilityValue, TesseraStartScreenStrings.string(.panelExpanded))
    }

    /// The same pair "tile count + expanded" arrives on a real cell after
    /// the panel is expanded in the grid.
    func testFolderCellValueAfterExpansionInGrid() {
        let folder = tesseraTestFolder("folder", tileCount: 5)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])

        host.grid.openFolder(folder, animated: false)
        host.layout()

        XCTAssertEqual(
            host.cell(folder.id)?.accessibilityValue,
            "5, \(TesseraStartScreenStrings.string(.panelExpanded))"
        )
    }

    // MARK: - Dynamic Type of the panel title

    /// The panel title font scales with Dynamic Type but does not exceed
    /// the ceiling and fits into the fixed height of the panel title row,
    /// otherwise the title would be clipped at accessibility sizes.
    func testPanelTitleFontScalesWithinHeaderHeight() {
        let defaultFont = TesseraFolderPanelCell.makeTitleFont(compatibleWith: nil)
        let smallFont = TesseraFolderPanelCell.makeTitleFont(
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraSmall)
        )
        let accessibilityFont = TesseraFolderPanelCell.makeTitleFont(
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
            )
        )

        XCTAssertLessThanOrEqual(smallFont.pointSize, defaultFont.pointSize)
        XCTAssertGreaterThan(accessibilityFont.pointSize, defaultFont.pointSize)
        XCTAssertLessThanOrEqual(accessibilityFont.pointSize, 28)
        XCTAssertLessThanOrEqual(
            accessibilityFont.lineHeight,
            TesseraTileLayoutEngine.panelHeaderHeight + 0.001,
            "The title row must fit into the panel height"
        )
        XCTAssertLessThanOrEqual(
            defaultFont.lineHeight,
            TesseraTileLayoutEngine.panelHeaderHeight + 0.001
        )
    }
}

#endif
