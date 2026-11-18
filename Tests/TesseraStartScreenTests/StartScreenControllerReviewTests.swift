//
//  StartScreenControllerReviewTests.swift
//  TesseraStartScreenTests
//
//  Regression tests of the desktop controller from the follow-up review.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md — §1 "Three pages"
//  (leading-edge policy, axis arbitration), §4 "Live tiles" (off-screen pauses),
//  §7 "Left page: the hook" (appear/disappear callbacks), §8 "Background
//  parallax" (wallpaper margin) and §9 "Accessibility" (page announcements).
//  Core pager contract: docs/CORE-IOS-DESIGN.md, "Behaviour of the implementation"
//  (reload by id, appearance only for the current page).
//
//  The screen is embedded into a window manually (without a rootViewController); the screen's
//  appearance is additionally driven by explicit `beginAppearanceTransition`/
//  `endAppearanceTransition` (a repeated appearance is idempotent for the
//  controller). The window is not attached to a scene, and scroll animations in it do not
//  tick: a swipe and the completion of the pager's programmatic animation are emulated
//  by calling its `UIScrollViewDelegate`, as UIKit would.
//

#if canImport(UIKit)

import UIKit
import XCTest
import TesseraCore
@testable import TesseraStartScreen

final class StartScreenControllerReviewTests: XCTestCase {

    // MARK: - Spies

    /// A hook provider that records appear/disappear callbacks (§7).
    private final class PanelSpy: TesseraQuickPanelProviding {
        let name: String
        private(set) var appearCount = 0
        private(set) var disappearCount = 0
        private(set) var makeCount = 0

        init(_ name: String) {
            self.name = name
        }

        func makeQuickPanelViewController() -> UIViewController {
            makeCount += 1
            return UIViewController()
        }

        func quickPanelWillAppear() {
            appearCount += 1
        }

        func quickPanelDidDisappear() {
            disappearCount += 1
        }
    }

    /// The screen's UIKit delegate: pages and hook visibility.
    private final class DelegateSpy: TesseraStartScreenDelegate {
        private(set) var pages: [TesseraStartScreenPage] = []
        private(set) var hookVisibility: [Bool] = []

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

    /// A live tile provider with a back side (flips are possible).
    private final class FlippingProvider: TesseraLiveTileContentProvider {
        var frontFace = TesseraLiveTileFace(title: "Front")
        var backFace: TesseraLiveTileFace? { TesseraLiveTileFace(title: "Back") }
    }

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

    private let screenSize = CGSize(width: 390, height: 844)

    /// Embeds the screen into a window and completes layout (without appearance).
    @discardableResult
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

    /// Completes the layout of the screen, the pager and the START page.
    private func layout(_ screen: TesseraStartScreenViewController) {
        screen.view.layoutIfNeeded()
        if let pager = try? pager(of: screen) {
            pager.view.frame = screen.view.bounds
            pager.view.layoutIfNeeded()
        }
        screen.gridView.superview?.layoutIfNeeded()
        screen.gridView.layoutIfNeeded()
    }

    private func appear(_ screen: TesseraStartScreenViewController) {
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
    }

    private func disappear(_ screen: TesseraStartScreenViewController) {
        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
    }

    private func pager(of screen: TesseraStartScreenViewController) throws -> TesseraPagerViewController {
        try XCTUnwrap(
            screen.children.compactMap { $0 as? TesseraPagerViewController }.first,
            "The screen must contain the Core pager"
        )
    }

    private func pagerScrollView(of screen: TesseraStartScreenViewController) throws -> UIScrollView {
        try XCTUnwrap(
            pager(of: screen).view.subviews.compactMap { $0 as? UIScrollView }.first,
            "The pager must contain a UIScrollView"
        )
    }

    private func gridCollectionView(of screen: TesseraStartScreenViewController) throws -> UICollectionView {
        try XCTUnwrap(
            screen.gridView.subviews.compactMap { $0 as? UICollectionView }.first,
            "The grid holds the collection"
        )
    }

    /// The horizontal position of the START page on screen (0 — START is visible).
    private func startPageScreenX(of screen: TesseraStartScreenViewController) -> CGFloat {
        screen.gridView.convert(screen.gridView.bounds, to: screen.view).minX
    }

    /// Spins the run loop for the given time.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits for a condition while spinning the run loop.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Emulates the completion of the pager's programmatic animation.
    ///
    /// The test process window is not attached to a scene, and the animation of
    /// `setContentOffset(_:animated: true)` does not tick in it: the test brings the
    /// offset to the target and tells the pager it finished, as UIKit would.
    private func completeAnimatedTransition(
        _ screen: TesseraStartScreenViewController,
        toReadingIndex readingIndex: Int
    ) throws {
        let pager = try pager(of: screen)
        let scrollView = try pagerScrollView(of: screen)
        scrollView.setContentOffset(
            CGPoint(x: CGFloat(readingIndex) * scrollView.bounds.width, y: 0),
            animated: false
        )
        pager.scrollViewDidEndScrollingAnimation(scrollView)
    }

    /// Emulates a completed pager swipe to the `readingIndex` page (LTR).
    private func swipe(_ screen: TesseraStartScreenViewController, toReadingIndex readingIndex: Int) throws {
        let pager = try pager(of: screen)
        let scrollView = try pagerScrollView(of: screen)
        pager.scrollViewWillBeginDragging(scrollView)
        scrollView.setContentOffset(
            CGPoint(x: CGFloat(readingIndex) * scrollView.bounds.width, y: 0),
            animated: false
        )
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        pager.scrollViewDidEndDecelerating(scrollView)
    }

    private func makeScreen(
        leftPanel: TesseraQuickPanelProviding?,
        rightPage: Bool = true
    ) -> TesseraStartScreenViewController {
        let screen = TesseraStartScreenViewController()
        screen.configure(
            leftPanel: leftPanel,
            rightPage: rightPage ? { UIViewController() } : nil
        )
        return screen
    }

    // MARK: - Pager resync after a rebuild

    /// Scenario A: the edge-yield policy, a programmatic hook show and a swipe to
    /// START. After the deferred "freeze" of the hook (a page rebuild) the screen shows
    /// START, not the apps list.
    func testEdgePolicyQuickPanelThenSwipeToStartKeepsStartOnScreen() throws {
        let panel = PanelSpy("A")
        let screen = makeScreen(leftPanel: panel)
        screen.yieldsLeftEdgeToSystemGesture = true
        host(screen)
        appear(screen)

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(screen.currentPage, .quickPanel)

        try swipe(screen, toReadingIndex: 1)
        XCTAssertEqual(screen.currentPage, .start)

        // Deferred rebuild: the hook drops out of the swipeable set.
        spin(0.1)
        layout(screen)

        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertFalse(screen.accessibilityScroll(.previous), "The hook is programmatic-only again")
        XCTAssertEqual(try pagerScrollView(of: screen).contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(startPageScreenX(of: screen), 0, accuracy: 0.5, "START is on screen")
    }

    /// Scenario B: `configure(leftPanel:)` on START adds a hook on the left — the screen
    /// stays on START (the index shifted by 1), and the hook did not "appear".
    func testConfigureAddingLeftPanelOnStartKeepsStartOnScreen() throws {
        let panel = PanelSpy("A")
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        appear(screen)

        screen.configure(leftPanel: panel, rightPage: { UIViewController() })
        layout(screen)

        let scrollView = try pagerScrollView(of: screen)
        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(scrollView.contentOffset.x, scrollView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(startPageScreenX(of: screen), 0, accuracy: 0.5, "START is on screen")
        XCTAssertEqual(panel.appearCount, 0, "The hook was not shown")
    }

    // MARK: - showPage under the edge-yield policy

    /// A programmatic hook show under the edge policy sends everything a transition
    /// should: the provider callback, delegate events and a VoiceOver announcement.
    func testShowQuickPanelUnderEdgePolicyNotifiesProviderDelegateAndVoiceOver() throws {
        let panel = PanelSpy("A")
        let delegate = DelegateSpy()
        var announcements: [String] = []
        let screen = makeScreen(leftPanel: panel)
        screen.pageAnnouncer = { announcements.append($0) }
        screen.delegate = delegate
        screen.yieldsLeftEdgeToSystemGesture = true
        host(screen)
        appear(screen)

        screen.showPage(.quickPanel, animated: false)

        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(panel.appearCount, 1)
        XCTAssertEqual(delegate.pages, [.quickPanel])
        XCTAssertEqual(delegate.hookVisibility, [true])
        XCTAssertEqual(announcements, [screen.quickPanelTitle])
    }

    // MARK: - currentPage only on pager confirmation

    /// An animated `showPage` does not write `currentPage` until the transition
    /// completes: the pager is the source of truth.
    func testAnimatedShowPageCommitsCurrentPageOnlyAfterPagerConfirms() throws {
        let screen = makeScreen(leftPanel: PanelSpy("A"))
        host(screen)
        appear(screen)

        screen.showPage(.applications, animated: true)
        XCTAssertEqual(screen.currentPage, .start, "The transition is not confirmed yet")

        try completeAnimatedTransition(screen, toReadingIndex: 2)
        XCTAssertEqual(screen.currentPage, .applications)
    }

    /// A finger intercepted the animated transition and returned the pager to START:
    /// `currentPage` stays START (it used to get stuck on the animation target).
    func testInterceptedAnimatedTransitionKeepsConfirmedPage() throws {
        let screen = makeScreen(leftPanel: PanelSpy("A"))
        host(screen)
        appear(screen)
        let pager = try pager(of: screen)
        let scrollView = try pagerScrollView(of: screen)

        screen.showPage(.applications, animated: true)

        pager.scrollViewWillBeginDragging(scrollView)
        scrollView.setContentOffset(CGPoint(x: scrollView.bounds.width, y: 0), animated: false)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        spin(0.5)

        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(startPageScreenX(of: screen), 0, accuracy: 0.5)
    }

    // MARK: - Hook callbacks (§7)

    /// `quickPanelWillAppear` arrives before the appearance: with an animated
    /// show — immediately, not on transition completion.
    func testQuickPanelWillAppearBeforeAnimatedTransitionCompletes() throws {
        let panel = PanelSpy("A")
        let screen = makeScreen(leftPanel: panel)
        host(screen)
        appear(screen)

        screen.showPage(.quickPanel, animated: true)
        XCTAssertEqual(panel.appearCount, 1, "willAppear — before the page appears")

        try completeAnimatedTransition(screen, toReadingIndex: 0)
        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(panel.appearCount, 1, "No repeated willAppear")
        XCTAssertEqual(panel.disappearCount, 0)
    }

    /// A hook requested before loading does not receive `quickPanelWillAppear` until
    /// the screen is shown; the delegate and VoiceOver stay silent too. The screen
    /// appearing and leaving give symmetric callbacks.
    func testHookCallbacksFollowScreenAppearanceNotViewDidLoad() throws {
        let panel = PanelSpy("A")
        let delegate = DelegateSpy()
        var announcements: [String] = []
        let screen = makeScreen(leftPanel: panel)
        screen.pageAnnouncer = { announcements.append($0) }
        screen.delegate = delegate
        screen.showPage(.quickPanel, animated: false)

        // Loading and layout without a window: `viewDidLoad` and layout are not an appearance.
        // (UIKit itself counts adding a view to a window as an appearance, so the window
        // comes only after the check.)
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(origin: .zero, size: screenSize)
        layout(screen)
        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(panel.appearCount, 0, "The screen is not shown yet")
        XCTAssertEqual(delegate.hookVisibility, [])

        host(screen)
        appear(screen)
        XCTAssertEqual(panel.appearCount, 1)
        XCTAssertEqual(delegate.hookVisibility, [true])

        disappear(screen)
        XCTAssertEqual(panel.disappearCount, 1)
        XCTAssertEqual(delegate.hookVisibility, [true, false])

        XCTAssertEqual(announcements, [], "The start page is not announced")
    }

    /// The start page is not announced from `viewDidLoad`.
    func testInitialPageIsNotAnnouncedOnLoad() {
        var announcements: [String] = []
        let screen = makeScreen(leftPanel: PanelSpy("A"))
        screen.pageAnnouncer = { announcements.append($0) }

        host(screen)
        appear(screen)

        XCTAssertEqual(announcements, [])
    }

    /// Replacing and removing the provider while the hook is on screen: the old one gets
    /// `didDisappear`, the new one — `willAppear`; the page is recreated by the new
    /// provider.
    func testReplacingAndRemovingProviderWhileHookVisibleIsSymmetric() throws {
        let first = PanelSpy("A")
        let second = PanelSpy("B")
        let screen = makeScreen(leftPanel: first)
        host(screen)
        appear(screen)
        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(first.appearCount, 1)

        screen.configure(leftPanel: second, rightPage: { UIViewController() })
        layout(screen)
        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(first.disappearCount, 1, "The old provider gets didDisappear")
        XCTAssertEqual(second.appearCount, 1, "The new provider gets willAppear")
        XCTAssertGreaterThanOrEqual(second.makeCount, 1, "The page was created by the new provider")

        screen.configure(leftPanel: nil, rightPage: { UIViewController() })
        layout(screen)
        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(second.disappearCount, 1, "The removed provider gets didDisappear")
        XCTAssertEqual(first.appearCount, 1)
        XCTAssertEqual(first.disappearCount, 1)
    }

    // MARK: - Axis arbitration vs. the folder's scroll lock

    /// A horizontal gesture began while the folder animation kept the grid
    /// disabled: after both completions the grid scrolls again.
    func testHorizontalGestureDuringFolderAnimationDoesNotFreezeGrid() throws {
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        let grid = screen.gridView
        let collectionView = try gridCollectionView(of: screen)

        // Folder animation: the snapshot is `true`, and `false` for the duration of the animation.
        let folderSnapshot = grid.isScrollEnabled
        grid.isScrollEnabled = false
        screen.beginHorizontalScroll(isHorizontal: true)
        grid.isScrollEnabled = folderSnapshot
        screen.endHorizontalScroll()

        XCTAssertTrue(grid.isScrollEnabled)
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
    }

    /// The folder animation began in the middle of a horizontal gesture and ended
    /// after it: the grid does not stay disabled forever.
    func testFolderAnimationStartedDuringHorizontalGestureDoesNotFreezeGrid() throws {
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        let grid = screen.gridView
        let collectionView = try gridCollectionView(of: screen)

        screen.beginHorizontalScroll(isHorizontal: true)
        let folderSnapshot = grid.isScrollEnabled
        grid.isScrollEnabled = false
        screen.endHorizontalScroll()
        grid.isScrollEnabled = folderSnapshot

        XCTAssertTrue(grid.isScrollEnabled)
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
    }

    /// The arbitration itself works: during a horizontal gesture the grid does not
    /// accept a vertical pan, and afterwards it does; a vertical gesture does not
    /// block the grid.
    func testHorizontalGestureBlocksGridPanOnlyWhileActive() throws {
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        let collectionView = try gridCollectionView(of: screen)

        screen.beginHorizontalScroll(isHorizontal: true)
        XCTAssertFalse(collectionView.panGestureRecognizer.isEnabled && screen.gridView.isScrollEnabled)
        screen.endHorizontalScroll()
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
        XCTAssertTrue(screen.gridView.isScrollEnabled)

        screen.beginHorizontalScroll(isHorizontal: false)
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
        XCTAssertTrue(screen.gridView.isScrollEnabled)
        screen.endHorizontalScroll()
    }

    // MARK: - Live tiles off screen (§4)

    /// While START is off screen, live tiles do not flip; returning to START
    /// resumes the schedule.
    func testLiveTilesDoNotFlipWhileStartIsOffScreen() throws {
        let screen = makeScreen(leftPanel: nil)
        screen.gridView.liveTileConfiguration = TesseraLiveTileEngine.Configuration(
            cycleInterval: 0.8,
            flipDuration: 0.1,
            batchSize: 10,
            batchStagger: 0,
            jitter: 0,
            seed: 1
        )
        let tile = TesseraTileDescriptor(
            id: "live",
            title: "Live",
            action: {},
            liveContent: FlippingProvider()
        )
        screen.reload(grid: TesseraTileGridSnapshot(items: [.tile(tile)], unpinned: []))
        host(screen)
        appear(screen)

        let liveView = try XCTUnwrap(
            firstSubview(of: TesseraLiveTileView.self, in: screen.gridView),
            "The live tile is shown on START"
        )
        XCTAssertEqual(liveView.side, .front)

        screen.showPage(.applications, animated: false)
        XCTAssertEqual(screen.currentPage, .applications)
        spin(1.3)

        XCTAssertEqual(liveView.side, .front, "START is off screen — no flips")
        XCTAssertFalse(liveView.isFlipping)

        screen.showPage(.start, animated: false)
        XCTAssertTrue(
            waitUntil(timeout: 3) { liveView.side == .back || liveView.isFlipping },
            "The flip schedule resumes on START"
        )
    }

    // MARK: - Wallpaper margin as content grows

    /// Growth of the content height through `grid.update` (without `reload(grid:)`)
    /// recomputes the wallpaper margin: at the end of scrolling the page is covered.
    func testWallpaperReserveFollowsContentGrowthWithoutReload() throws {
        let screen = makeScreen(leftPanel: nil, rightPage: false)
        screen.wallpaperParallaxFactor = 0.6
        screen.wallpaperImage = UIImage()
        let few = (0..<2).map { TesseraTileGridItem.tile(tesseraTestTile("t\($0)")) }
        screen.reload(grid: TesseraTileGridSnapshot(items: few, unpinned: []))
        host(screen)

        let many = (0..<60).map { TesseraTileGridItem.tile(tesseraTestTile("t\($0)")) }
        screen.gridView.update(snapshot: TesseraTileGridSnapshot(items: many, unpinned: []), animated: false)
        let collectionView = try gridCollectionView(of: screen)
        collectionView.layoutIfNeeded()
        layout(screen)

        try assertWallpaperCoversPageAtBottom(of: screen, collectionView: collectionView)
    }

    /// Expanding a folder (the panel lengthens the content) recomputes the wallpaper margin.
    func testWallpaperReserveFollowsFolderExpansion() throws {
        let screen = makeScreen(leftPanel: nil, rightPage: false)
        screen.wallpaperParallaxFactor = 0.6
        screen.wallpaperImage = UIImage()
        let folder = TesseraTileFolder(
            id: "folder",
            title: "Folder",
            // Six columns by default (D26): enough tiles are needed so that the panel
            // is twice the viewport.
            tiles: (0..<200).map { tesseraTestTile("f\($0)", size: .small) }
        )
        screen.reload(grid: TesseraTileGridSnapshot(items: [.folder(folder)], unpinned: []))
        host(screen)

        screen.gridView.openFolder(folder, animated: false)
        let collectionView = try gridCollectionView(of: screen)
        collectionView.layoutIfNeeded()
        layout(screen)

        try assertWallpaperCoversPageAtBottom(of: screen, collectionView: collectionView)
    }

    // MARK: - Helper checks

    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func assertWallpaperCoversPageAtBottom(
        of screen: TesseraStartScreenViewController,
        collectionView: UICollectionView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let layer = try XCTUnwrap(firstSubview(of: TesseraParallaxLayer.self, in: screen.view))
        layer.respectsReduceMotion = false
        let page = try XCTUnwrap(layer.superview)
        let imageView = try XCTUnwrap(layer.subviews.compactMap { $0 as? UIImageView }.first)

        let height = page.bounds.height
        let maximum = max(0, max(screen.gridView.contentSize.height, height) - height)
        XCTAssertGreaterThan(maximum, height, "The content must grow noticeably taller than the viewport", file: file, line: line)

        collectionView.contentOffset = CGPoint(x: 0, y: maximum)
        let rect = imageView.convert(imageView.bounds, to: page)
        XCTAssertLessThanOrEqual(rect.minY, 0.001, "Strip at the top", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, height - 0.001, "Strip at the bottom", file: file, line: line)
    }
}

#endif
