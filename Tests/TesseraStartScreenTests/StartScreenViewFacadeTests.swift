//
//  StartScreenViewFacadeTests.swift
//  TesseraStartScreenTests
//
//  Regression tests for the SwiftUI start screen facade, from the review
//  (see docs/PLAN.md).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, §2 "Architecture"
//  (TesseraStartScreenView -> StartScreenViewController, TesseraStartScreenDelegate), §4
//  "Live tiles", §7 "Left page: the hook" and §14 (D12: a tap is an event, the action
//  is performed by the host).
//
//  The facade is embedded through `UIHostingController` in a window; the live
//  `TesseraStartScreenViewController` is found by walking the hosting children.
//  A SwiftUI redraw is emulated by replacing `rootView` and running a layout pass.
//

#if canImport(UIKit) && canImport(SwiftUI)

import SwiftUI
import UIKit
import XCTest
import TesseraCore
@testable import TesseraStartScreen

final class StartScreenViewFacadeTests: XCTestCase {

    // MARK: - Spies

    private final class DelegateSpy: TesseraStartScreenDelegate {
        private(set) var tappedShortcuts: [TesseraTileDescriptor] = []
        private(set) var hookVisibility: [Bool] = []
        private(set) var pages: [TesseraStartScreenPage] = []

        func startScreen(
            _ screen: TesseraStartScreenViewController,
            didTapShortcut shortcut: TesseraTileDescriptor
        ) {
            tappedShortcuts.append(shortcut)
        }

        func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangePage page: TesseraStartScreenPage,
            index: Int
        ) {
            pages.append(page)
        }

        func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangeHookVisibility isVisible: Bool
        ) {
            hookVisibility.append(isVisible)
        }
    }

    private final class StaticProvider: TesseraLiveTileContentProvider {
        var frontFace = TesseraLiveTileFace(title: "Front")
    }

    // MARK: - Environment

    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.rootViewController = nil
            window.isHidden = true
        }
        windows.removeAll()
        super.tearDown()
    }

    private func host(_ view: TesseraStartScreenView) -> UIHostingController<TesseraStartScreenView> {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.isHidden = false
        windows.append(window)
        render(hosting)
        return hosting
    }

    private func render(_ hosting: UIHostingController<TesseraStartScreenView>) {
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.view.layoutIfNeeded()
    }

    private func screen(in hosting: UIViewController) throws -> TesseraStartScreenViewController {
        func find(_ controller: UIViewController) -> TesseraStartScreenViewController? {
            if let screen = controller as? TesseraStartScreenViewController { return screen }
            for child in controller.children {
                if let match = find(child) { return match }
            }
            return nil
        }
        return try XCTUnwrap(find(hosting), "The facade must create the start screen controller")
    }

    private func pagerScrollView(of screen: TesseraStartScreenViewController) throws -> UIScrollView {
        let pager = try XCTUnwrap(screen.children.compactMap { $0 as? TesseraPagerViewController }.first)
        return try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
    }

    private func folderSnapshot(innerBadge: TesseraTileBadge, innerTitle: String) -> TesseraTileGridSnapshot {
        let inner = TesseraTileDescriptor(id: "inner", title: innerTitle, action: {}, badge: innerBadge)
        let folder = TesseraTileFolder(id: "folder", title: "Folder", tiles: [inner])
        return TesseraTileGridSnapshot(items: [.folder(folder)], unpinned: [])
    }

    // MARK: - Snapshot signature: folder contents

    /// A badge and a tile caption inside a folder reach the grid.
    func testFolderContentBadgeAndTitleChangesReachGrid() throws {
        let hosting = host(TesseraStartScreenView(snapshot: folderSnapshot(innerBadge: .none, innerTitle: "Mail")))
        let screen = try screen(in: hosting)

        hosting.rootView = TesseraStartScreenView(snapshot: folderSnapshot(innerBadge: .count(3), innerTitle: "Inbox"))
        render(hosting)

        guard case .folder(let folder)? = screen.gridView.items.first else {
            return XCTFail("A folder was expected")
        }
        XCTAssertEqual(folder.tiles.first?.badge, .count(3))
        XCTAssertEqual(folder.tiles.first?.title, "Inbox")
    }

    // MARK: - Snapshot cell table

    /// A snapshot with the same items but different cells (for example, a hole
    /// left after unpinning) reaches the grid; a snapshot without a table does not
    /// overwrite the displayed table (a host that does not know about cells).
    func testPlacementTableChangeReachesGridAndTablelessSnapshotKeepsIt() throws {
        func snapshot(secondColumn: Int?) -> TesseraTileGridSnapshot {
            let items: [TesseraTileGridItem] = ["a", "b"].map {
                .tile(TesseraTileDescriptor(id: $0, title: $0, action: {}, size: .small))
            }
            guard let secondColumn else { return TesseraTileGridSnapshot(items: items, unpinned: []) }
            let table = TesseraTileGridPlacementTable(
                cells: [
                    "a": TesseraTileGridPlacement(row: 0, column: 0),
                    "b": TesseraTileGridPlacement(row: 0, column: secondColumn),
                ],
                columns: TesseraTileLayoutEngine.defaultColumns
            )
            return TesseraTileGridSnapshot(items: items, unpinned: [], placementTable: table)
        }

        let hosting = host(TesseraStartScreenView(snapshot: snapshot(secondColumn: 1)))
        let screen = try screen(in: hosting)
        XCTAssertEqual(screen.gridView.snapshot?.placementTable?.cells["b"], TesseraTileGridPlacement(row: 0, column: 1))

        hosting.rootView = TesseraStartScreenView(snapshot: snapshot(secondColumn: 3))
        render(hosting)
        XCTAssertEqual(
            screen.gridView.snapshot?.placementTable?.cells["b"],
            TesseraTileGridPlacement(row: 0, column: 3),
            "Different cells with the same items were applied"
        )

        hosting.rootView = TesseraStartScreenView(snapshot: snapshot(secondColumn: nil))
        render(hosting)
        XCTAssertEqual(
            screen.gridView.snapshot?.placementTable?.cells["b"],
            TesseraTileGridPlacement(row: 0, column: 3),
            "A snapshot without a table does not overwrite the displayed cells"
        )
    }

    // MARK: - Snapshot signature: liveContent and action

    /// A `liveContent` appearing on a tile with the same `id` reaches the grid:
    /// the tile becomes live.
    func testLiveContentChangeReachesGrid() throws {
        let plain = TesseraTileDescriptor(id: "t", title: "T", action: {})
        let hosting = host(TesseraStartScreenView(snapshot: TesseraTileGridSnapshot(items: [.tile(plain)], unpinned: [])))
        let screen = try screen(in: hosting)

        let provider = StaticProvider()
        let live = TesseraTileDescriptor(id: "t", title: "T", action: {}, liveContent: provider)
        hosting.rootView = TesseraStartScreenView(snapshot: TesseraTileGridSnapshot(items: [.tile(live)], unpinned: []))
        render(hosting)

        guard case .tile(let shortcut)? = screen.gridView.items.first else {
            return XCTFail("A tile was expected")
        }
        XCTAssertTrue(shortcut.liveContent === provider)
    }

    /// The delegate receives the tile with the current `action` closure, even if
    /// nothing else in the tile changed (D12: the action is performed by the host).
    func testTapDeliversShortcutWithLatestAction() throws {
        let delegate = DelegateSpy()
        var calls: [String] = []
        let old = TesseraTileDescriptor(id: "t", title: "T", action: { calls.append("old") })
        let hosting = host(TesseraStartScreenView(
            snapshot: TesseraTileGridSnapshot(items: [.tile(old)], unpinned: []),
            delegate: delegate
        ))
        let screen = try screen(in: hosting)

        let fresh = TesseraTileDescriptor(id: "t", title: "T", action: { calls.append("new") })
        hosting.rootView = TesseraStartScreenView(
            snapshot: TesseraTileGridSnapshot(items: [.tile(fresh)], unpinned: []),
            delegate: delegate
        )
        render(hosting)

        let item = try XCTUnwrap(screen.gridView.items.first)
        screen.gridView.onTap?(item)

        let tapped = try XCTUnwrap(delegate.tappedShortcuts.last)
        tapped.action()
        XCTAssertEqual(calls, ["new"])
    }

    // MARK: - Hook provider from body

    /// A hook provider recreated in `body` on every redraw does not
    /// rebuild the pager: an ongoing swipe (offset between pages) is not
    /// reset.
    func testQuickPanelProviderRecreatedPerRenderDoesNotRebuildPager() throws {
        let snapshot = TesseraTileGridSnapshot(items: [], unpinned: [])
        let hosting = host(TesseraStartScreenView(
            snapshot: snapshot,
            leftPanel: TesseraQuickPanelProvider { UIViewController() },
            rightPage: { UIViewController() }
        ))
        let screen = try screen(in: hosting)
        let scrollView = try pagerScrollView(of: screen)
        let midOffset = scrollView.bounds.width * 1.5
        scrollView.contentOffset = CGPoint(x: midOffset, y: 0)

        hosting.rootView = TesseraStartScreenView(
            snapshot: snapshot,
            leftPanel: TesseraQuickPanelProvider { UIViewController() },
            rightPage: { UIViewController() }
        )
        render(hosting)

        XCTAssertEqual(scrollView.contentOffset.x, midOffset, accuracy: 0.5, "The pager was not rebuilt")
        XCTAssertEqual(screen.currentPage, .start)
    }

    // MARK: - Hook visibility when the screen appears

    /// `didChangeHookVisibility` arrives when a screen with an open hook
    /// leaves and comes back (viewDidDisappear/viewWillAppear).
    func testHookVisibilityFollowsScreenAppearance() throws {
        let delegate = DelegateSpy()
        let hosting = host(TesseraStartScreenView(
            snapshot: TesseraTileGridSnapshot(items: [], unpinned: []),
            leftPanel: TesseraQuickPanelProvider { UIViewController() },
            delegate: delegate
        ))
        let screen = try screen(in: hosting)
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(delegate.hookVisibility, [true])
        XCTAssertEqual(delegate.pages, [.quickPanel])

        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
        XCTAssertEqual(delegate.hookVisibility, [true, false])

        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        XCTAssertEqual(delegate.hookVisibility, [true, false, true])
    }
}

#endif
