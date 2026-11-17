//
//  PivotTransitionTests.swift
//  TesseraPivotTests
//
//  Contract tests for pivot transitions and strip geometry from the review follow-up.
//  Scenarios: a false didShow on interception, an animated far tap, strip centering.
//  Design document: docs/PIVOT-IOS-DESIGN.md §4 (core math:
//  auto-centering only if the header is beyond the edge), §5 (strip and pager
//  synchronization: the strip is animated by the pager's progress, with no separate
//  indicator animation), §8 (RTL), §9 (adaptivity: rotation).
//
//  Environment: the test process has no `UIWindowScene`, so `UIScrollView`
//  animations (`setContentOffset(_:animated: true)`) do not advance:
//  an animated transition "gets stuck" at the start. This is used deliberately:
//  the animation frames and its completion are fed by the test manually through the
//  `TesseraPagerDelegate` callbacks, and interrupting a stuck animation with a new transition
//  reproduces the real UIKit scenario (a synchronous
//  `scrollViewDidEndScrollingAnimation` for an interrupted animation).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPivot

/// A pivot delegate spy for the transition tests.
final class PivotTransitionSpy: TesseraPivotDelegate {
    var selectedIndexes: [Int] = []
    var progressValues: [CGFloat] = []
    var shownIndexes: [Int] = []

    func pivot(_ pivot: TesseraPivotViewController, didSelectSectionAt index: Int) {
        selectedIndexes.append(index)
    }

    func pivot(_ pivot: TesseraPivotViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }

    func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int) {
        shownIndexes.append(index)
    }
}

final class PivotTransitionTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func spinRunLoop(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeSections(count: Int, longTitles: Bool = false) -> [TesseraPivotSection] {
        (0..<count).map { index in
            TesseraPivotSection(
                id: index,
                title: longTitles ? "Long section title \(index)" : "S\(index)"
            ) {
                UIViewController()
            }
        }
    }

    /// A pivot in a window: appearance and the pager's pan as in an app.
    private func makeWindowedPivot(
        sectionCount: Int = 6,
        longTitles: Bool = false,
        size: CGSize = CGSize(width: 320, height: 640)
    ) throws -> (pivot: TesseraPivotViewController, scrollView: UIScrollView, spy: PivotTransitionSpy) {
        let pivot = TesseraPivotViewController(
            sections: makeSections(count: sectionCount, longTitles: longTitles)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = pivot
        window.isHidden = false
        pivot.view.layoutIfNeeded()
        self.window = window

        let spy = PivotTransitionSpy()
        pivot.delegate = spy
        spinRunLoop()

        let scrollView = try XCTUnwrap(pivot.pagerScrollView)
        return (pivot, scrollView, spy)
    }

    private func collectionView(of strip: TesseraPivotHeaderStripView) throws -> UICollectionView {
        try XCTUnwrap(strip.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    private func itemFrame(_ index: Int, in collectionView: UICollectionView) throws -> CGRect {
        try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        )
    }

    private func isFullyVisible(_ frame: CGRect, in collectionView: UICollectionView) -> Bool {
        frame.minX >= collectionView.bounds.minX - 0.5
            && frame.maxX <= collectionView.bounds.maxX + 0.5
    }

    private func skipIfReduceMotion() throws {
        try XCTSkipIf(
            TesseraAccessibility.isReduceMotionEnabled,
            "Under Reduce Motion transitions are not animated (§8)"
        )
    }

    // MARK: - A false didShow when an animated transition is intercepted

    /// An animated transition intercepted by another animated transition
    /// does not produce `didShowSectionAt` for the intermediate section: UIKit synchronously
    /// completes the interrupted animation, and the pager reports the page where
    /// it was interrupted (previously `[3]` for targets 4 → 1).
    func testSupersededAnimatedTransitionDoesNotReportIntermediateSection() throws {
        try skipIfReduceMotion()
        let (pivot, scrollView, spy) = try makeWindowedPivot()
        let pageWidth = scrollView.bounds.width

        pivot.selectSection(at: 4, animated: true)
        pivot.selectSection(at: 1, animated: true)

        XCTAssertEqual(spy.shownIndexes, [], "The tail of an intercepted transition must not reach the delegate")
        XCTAssertTrue(pivot.isTransitionInFlight)

        // The animation's completion at the target, as the pager reports it. (Writing the
        // offset from the test would itself interrupt the stuck animation and produce
        // one more tail that does not exist in an app.)
        _ = pageWidth
        pivot.pager(pivot.pagerViewController, didChangeProgress: 1)
        pivot.pager(pivot.pagerViewController, didShowPageAt: 1)

        XCTAssertEqual(spy.shownIndexes, [1])
        XCTAssertEqual(pivot.currentSectionIndex, 1)
        XCTAssertFalse(pivot.isTransitionInFlight)
    }

    /// An animated transition intercepted by a non-animated transition: the delegate
    /// sees only the final section (previously `[…, 3, 0]`).
    func testAnimatedTransitionInterruptedByJumpReportsOnlyFinalSection() throws {
        try skipIfReduceMotion()
        let (pivot, scrollView, spy) = try makeWindowedPivot()

        pivot.selectSection(at: 4, animated: true)
        pivot.selectSection(at: 0, animated: false)

        XCTAssertEqual(spy.shownIndexes, [0])
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(pivot.headerStripView.lastProgress, 0, accuracy: 0.001)
        XCTAssertFalse(pivot.isTransitionInFlight)
    }

    /// A gesture intercepts an animated transition: the completion where
    /// the finger stopped is real, not false, and reaches the delegate.
    func testUserDragAfterAnimatedTransitionReportsActualSection() throws {
        try skipIfReduceMotion()
        let (pivot, scrollView, spy) = try makeWindowedPivot()
        let pageWidth = scrollView.bounds.width

        pivot.selectSection(at: 1, animated: true)
        // The pager was intercepted by the gesture and settled on section 2 after inertia.
        pivot.pagerViewController.scrollViewWillBeginDragging(scrollView)
        scrollView.setContentOffset(CGPoint(x: pageWidth * 2, y: 0), animated: false)
        pivot.pagerViewController.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(spy.shownIndexes.last, 2)
        XCTAssertEqual(pivot.currentSectionIndex, 2)
    }

    // MARK: - The strip is not animated on selectSection(animated: false)

    /// A transition without animation does not start an animated re-centering of the strip:
    /// previously `didShowPageAt` always called `scrollToCenter(animated: true)`.
    func testNonAnimatedSelectionDoesNotAnimateStrip() throws {
        let (pivot, _, _) = try makeWindowedPivot(sectionCount: 8, longTitles: true)
        let strip = pivot.headerStripView
        let collectionView = try collectionView(of: strip)
        let before = strip.animatedCenteringCount

        pivot.selectSection(at: 6, animated: false)

        XCTAssertEqual(strip.animatedCenteringCount, before, "The strip must not be animated")
        XCTAssertTrue(isFullyVisible(try itemFrame(6, in: collectionView), in: collectionView))
    }

    // MARK: - scrollToCenter only if the header is beyond the edge (§4)

    /// A visible header does not move an overflowing strip; a header beyond the edge
    /// is re-centered.
    func testScrollToCenterMovesStripOnlyForHeaderBeyondEdge() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = (0..<8).map { "Section title \($0)" }
        strip.layoutIfNeeded()
        let collectionView = try collectionView(of: strip)

        XCTAssertGreaterThan(collectionView.contentSize.width, 320, "The strip must be overflowing")
        let visibleFrame = try itemFrame(1, in: collectionView)
        XCTAssertTrue(isFullyVisible(visibleFrame, in: collectionView), "Precondition: header 1 is visible")
        XCTAssertGreaterThan(visibleFrame.midX, 160, "Precondition: centering would shift the strip")

        strip.scrollToCenter(index: 1, animated: false)
        XCTAssertEqual(collectionView.contentOffset.x, 0, accuracy: 0.5, "A visible header does not move the strip")

        strip.scrollToCenter(index: 6, animated: false)
        let farFrame = try itemFrame(6, in: collectionView)
        XCTAssertGreaterThan(collectionView.contentOffset.x, 0)
        XCTAssertTrue(isFullyVisible(farFrame, in: collectionView))
        XCTAssertEqual(
            farFrame.midX - collectionView.contentOffset.x,
            160,
            accuracy: 1,
            "A header beyond the edge is re-centered"
        )
    }

    // MARK: - Re-centering on rotation (§9)

    /// After the strip narrows (rotation) the selected header is visible again.
    func testStripKeepsSelectedHeaderVisibleAfterWidthChange() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 800, height: 48))
        strip.titles = (0..<8).map { "Long section title \($0)" }
        strip.layoutIfNeeded()
        let collectionView = try collectionView(of: strip)

        strip.select(index: 6)
        strip.scrollToCenter(index: 6, animated: false)
        XCTAssertTrue(isFullyVisible(try itemFrame(6, in: collectionView), in: collectionView))

        strip.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        strip.layoutIfNeeded()

        XCTAssertTrue(
            isFullyVisible(try itemFrame(6, in: collectionView), in: collectionView),
            "After rotation the selected header must stay in the visible area"
        )
    }

    /// The strip is no longer overflowing (rotation to a wider width): the residual
    /// offset is reset, and all headers are in place.
    func testStripResetsOffsetWhenNoLongerOverflowing() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = (0..<4).map { "Section title \($0)" }
        strip.layoutIfNeeded()
        let collectionView = try collectionView(of: strip)

        strip.select(index: 3)
        strip.scrollToCenter(index: 3, animated: false)
        XCTAssertGreaterThan(collectionView.contentOffset.x, 0, "Precondition: the strip is scrolled")

        strip.frame = CGRect(x: 0, y: 0, width: 1000, height: 48)
        strip.layoutIfNeeded()

        XCTAssertEqual(collectionView.contentOffset.x, 0, accuracy: 0.5)
    }

    // MARK: - Layout direction change (§8)

    /// A `semanticContentAttribute` change on the strip on the fly: the collection is mirrored, and
    /// the indicator is recomputed for the actual header (previously the centers
    /// stayed from the old direction, since the size did not change).
    func testStripRebuildsGeometryWhenSemanticDirectionChanges() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = ["One", "Two", "Three"]
        strip.layoutIfNeeded()
        strip.apply(progress: 0)
        let collectionView = try collectionView(of: strip)

        let ltrFrame = try itemFrame(0, in: collectionView)
        XCTAssertLessThan(ltrFrame.midX, 160)
        XCTAssertEqual(strip.indicator.frame.midX, ltrFrame.midX, accuracy: 1)

        strip.semanticContentAttribute = .forceRightToLeft
        strip.layoutIfNeeded()

        XCTAssertEqual(collectionView.effectiveUserInterfaceLayoutDirection, .rightToLeft)
        XCTAssertTrue(
            collectionView.collectionViewLayout.flipsHorizontallyInOppositeLayoutDirection,
            "The strip layout must be mirrored in RTL (UICollectionViewFlowLayout defaults to false)"
        )
        let rtlFrame = try itemFrame(0, in: collectionView)
        let rtlCenter = collectionView.convert(CGPoint(x: rtlFrame.midX, y: 0), to: strip).x
        XCTAssertGreaterThan(rtlCenter, 160, "In RTL the first reading section is on the right")
        XCTAssertEqual(
            strip.indicator.frame.midX,
            rtlCenter,
            accuracy: 1,
            "The indicator must sit under header 0 in the new direction"
        )
    }

    /// A direction change from the environment (the `layoutDirection` trait via
    /// a parent's override) rebuilds the strip geometry.
    func testStripRebuildsGeometryWhenTraitDirectionChanges() throws {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = parent
        window.isHidden = false
        self.window = window

        child.view.frame = parent.view.bounds
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = ["One", "Two", "Three"]
        child.view.addSubview(strip)
        strip.layoutIfNeeded()
        strip.apply(progress: 0)
        let collectionView = try collectionView(of: strip)
        XCTAssertEqual(collectionView.effectiveUserInterfaceLayoutDirection, .leftToRight)

        parent.setOverrideTraitCollection(
            UITraitCollection(layoutDirection: .rightToLeft),
            forChild: child
        )
        parent.view.layoutIfNeeded()
        strip.layoutIfNeeded()

        try XCTSkipUnless(
            collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            "The environment did not propagate the trait direction to the collection"
        )
        let rtlFrame = try itemFrame(0, in: collectionView)
        let rtlCenter = collectionView.convert(CGPoint(x: rtlFrame.midX, y: 0), to: strip).x
        XCTAssertGreaterThan(rtlCenter, 160)
        XCTAssertEqual(strip.indicator.frame.midX, rtlCenter, accuracy: 1)
    }

    // MARK: - The indicator on an animated tap

    /// An animated tap to an adjacent section does not put the indicator on the target
    /// ahead of time: previously the strip jumped to the target for a frame, and the animation's first frame
    /// pulled it back. Now the strip is driven by the pager's progress.
    func testAnimatedTapDoesNotPreselectIndicator() throws {
        try skipIfReduceMotion()
        let (pivot, _, _) = try makeWindowedPivot()
        let strip = pivot.headerStripView
        let pager = pivot.pagerViewController

        let onSelect = try XCTUnwrap(strip.onSelect)
        onSelect(1)

        XCTAssertEqual(strip.lastProgress, 0, accuracy: 0.001, "The indicator does not jump to the target before the animation")

        pivot.pager(pager, didChangeProgress: 0.4)
        XCTAssertEqual(strip.lastProgress, 0.4, accuracy: 0.001)

        pivot.pager(pager, didChangeProgress: 1)
        pivot.pager(pager, didShowPageAt: 1)
        XCTAssertEqual(strip.lastProgress, 1, accuracy: 0.001)
        XCTAssertEqual(strip.selectedIndex, 1)
    }

    /// A far animated tap: the pager sets the offset to the target's neighbor
    /// and animates one step. The strip does not teleport to the neighbor but
    /// moves continuously from the source header to the target one; the delegate receives
    /// the pager's raw progress.
    func testFarAnimatedTapMovesIndicatorContinuouslyFromOrigin() throws {
        try skipIfReduceMotion()
        let (pivot, _, spy) = try makeWindowedPivot()
        let strip = pivot.headerStripView
        let pager = pivot.pagerViewController

        let onSelect = try XCTUnwrap(strip.onSelect)
        onSelect(4)

        XCTAssertEqual(spy.progressValues.last ?? -1, 3, accuracy: 0.001, "The delegate sees the raw jump to the neighbor")
        XCTAssertEqual(strip.lastProgress, 0, accuracy: 0.001, "The strip stays on the source header")

        pivot.pager(pager, didChangeProgress: 3.5)
        XCTAssertEqual(strip.lastProgress, 2, accuracy: 0.001, "The middle of the step is the middle of the strip's path")

        pivot.pager(pager, didChangeProgress: 4)
        XCTAssertEqual(strip.lastProgress, 4, accuracy: 0.001)

        pivot.pager(pager, didShowPageAt: 4)
        // The remap is cleared: the next swipe drives the strip by the raw progress.
        pivot.pager(pager, didChangeProgress: 3.5)
        XCTAssertEqual(strip.lastProgress, 3.5, accuracy: 0.001)
    }

    /// A far animated tap backward: the same remap in the reverse direction.
    func testFarAnimatedTapBackwardsMovesIndicatorContinuously() throws {
        try skipIfReduceMotion()
        let (pivot, _, _) = try makeWindowedPivot()
        let strip = pivot.headerStripView
        let pager = pivot.pagerViewController

        pivot.selectSection(at: 4, animated: false)
        pivot.selectSection(at: 0, animated: true)
        XCTAssertEqual(strip.lastProgress, 4, accuracy: 0.001)

        pivot.pager(pager, didChangeProgress: 0.5)
        XCTAssertEqual(strip.lastProgress, 2, accuracy: 0.001)
    }

    // MARK: - Page appearance

    /// A page that counts appearance callbacks.
    private final class AppearanceCountingPage: UIViewController {
        var didAppearCount = 0
        var didDisappearCount = 0

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppearCount += 1
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            didDisappearCount += 1
        }
    }

    /// The pager's contract that the above relies on: `viewDidAppear` is received only by
    /// the current section, and ±1 neighbors are loaded without appearance. So
    /// registering a vertical scroll view in `viewDidAppear` is too late for a neighbor:
    /// the `registerVerticalOwner(_:)` documentation recommends `viewDidLoad`.
    func testOnlyCurrentSectionReceivesAppearanceCallbacks() throws {
        var pages: [Int: AppearanceCountingPage] = [:]
        let sections = (0..<3).map { (index: Int) -> TesseraPivotSection in
            TesseraPivotSection(id: index, title: "S\(index)") { () -> UIViewController in
                let page = AppearanceCountingPage()
                pages[index] = page
                return page
            }
        }
        let pivot = TesseraPivotViewController(sections: sections)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = pivot
        window.isHidden = false
        pivot.view.layoutIfNeeded()
        self.window = window
        spinRunLoop()

        let first = try XCTUnwrap(pages[0])
        let neighbour = try XCTUnwrap(pages[1], "The ±1 neighbor is loaded in advance")
        XCTAssertEqual(first.didAppearCount, 1)
        XCTAssertEqual(neighbour.didAppearCount, 0, "The neighbor does not receive viewDidAppear on load")
        XCTAssertTrue(neighbour.isViewLoaded, "The neighbor's viewDidLoad has already run: the registration point")

        pivot.selectSection(at: 1, animated: false)

        XCTAssertEqual(neighbour.didAppearCount, 1)
        XCTAssertEqual(first.didDisappearCount, 1)
    }

    /// Strip progress remap: the segment's edges and clamping beyond it.
    func testStripProgressRemapMath() {
        let remap = TesseraPivotViewController.StripProgressRemap(from: 0, neighbour: 3, target: 4)

        XCTAssertEqual(remap.stripProgress(forPagerProgress: 3), 0, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 3.25), 1, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 4), 4, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 4.3), 4, accuracy: 0.0001)
    }
}

#endif
