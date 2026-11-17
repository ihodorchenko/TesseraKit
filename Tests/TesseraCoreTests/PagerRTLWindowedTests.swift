//
//  PagerRTLWindowedTests.swift
//  TesseraCoreTests
//
//  Coverage of the Core pager in a real `UIWindow` with a forced
//  reading direction (`semanticContentAttribute = .forceRightToLeft`) and
//  an LTR contrast.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  the invariant `t = contentOffset.x / pageWidth` normalized by the reading
//  direction; a single writer of `contentOffset`) and §1/§3 (`TesseraAccessibility`:
//  `accessibilityScroll` inverts the physical `.left`/`.right` in RTL).
//
//  What is checked (in a window, with real child controllers and layout):
//  - on-screen order: in RTL reading page 0 occupies the rightmost
//    physical slot (`pageCount − 1 − index`), in LTR the leftmost;
//  - alignment: the offset of reading page 0 in RTL is the right edge of the strip
//    (`contentSize.width − bounds.width`), in LTR it is `0`;
//  - progress in reading direction: `TesseraRTL.normalizedProgress`
//    (in RTL `t = (pageCount − 1) − raw`, unchanged in LTR);
//  - `accessibilityScroll` in RTL: `.right` pages forward in reading order,
//    `.left` pages backward; at the boundaries the gesture returns `false`; in LTR the
//    mapping is reversed (the UIKit convention: `.left` goes forward).
//
//  Determinism: layout is forced with `layoutIfNeeded`, and the end of the programmatic
//  `setContentOffset(_:animated:)` animation (which may never occur in a test process
//  without a display) is emulated by setting the offset and calling
//  `scrollViewDidEndScrollingAnimation`, the same technique as in
//  TesseraPagerReloadTests. Neither sleep nor run-loop waiting is used.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

// MARK: - Page controller with an identifier

/// A pager page: the identifier makes it possible to check which physical
/// slot the reading order ended up in.
private final class WindowedRLTPageController: UIViewController {
    let pageID: String

    init(pageID: String) {
        self.pageID = pageID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Pager delegate spy

/// A pager delegate spy: shown pages and progress together with the raw offset.
///
/// The pager's own `scrollView` is private, so the raw offset at the moment of the callback
/// is captured by a closure passed in.
private final class WindowedPagerSpy: TesseraPagerDelegate {
    private let rawOffsetProvider: () -> CGFloat

    private(set) var shownIndexes: [Int] = []
    private(set) var progressValues: [CGFloat] = []
    private(set) var progressRawOffsets: [CGFloat] = []

    init(rawOffsetProvider: @escaping () -> CGFloat) {
        self.rawOffsetProvider = rawOffsetProvider
    }

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }

    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
        progressRawOffsets.append(rawOffsetProvider())
    }

    /// Resets the recorded events.
    ///
    /// Needed to separate the initial page show (the first-show contract,
    /// which is not a transition) from the test's own events.
    func clearRecordedEvents() {
        shownIndexes.removeAll()
        progressValues.removeAll()
        progressRawOffsets.removeAll()
    }
}

final class PagerRTLWindowedTests: XCTestCase {

    private var window: UIWindow?

    /// A 320×480 window: one pager page spans the full width (the full-page
    /// `.paged` mode).
    private let pageSize = CGSize(width: 320, height: 480)
    private let pageCount = 3
    private var pageWidth: CGFloat { pageSize.width }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePages(ids: [String]) -> [TesseraPageDescriptor] {
        ids.map { id in
            TesseraPageDescriptor(id: id, title: id) {
                WindowedRLTPageController(pageID: id)
            }
        }
    }

    /// A pager in a real window with a forced reading direction.
    private func makeWindowedPager(
        ids: [String],
        direction: UIUserInterfaceLayoutDirection
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(ids: ids))
        let window = UIWindow(frame: CGRect(origin: .zero, size: pageSize))
        // The direction is set on both the window and the root view: the result must not
        // depend on the simulator's language/direction.
        window.semanticContentAttribute = direction == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        window.rootViewController = pager
        window.isHidden = false
        self.window = window

        pager.view.semanticContentAttribute = direction == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        pager.view.frame = CGRect(origin: .zero, size: pageSize)
        pager.view.layoutIfNeeded()

        // Precondition of all checks: the direction was actually applied.
        XCTAssertEqual(
            pager.view.effectiveUserInterfaceLayoutDirection,
            direction,
            "the reading direction was not applied to the pager view"
        )

        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first,
            "The pager must contain a UIScrollView"
        )
        return (pager, scrollView)
    }

    private func pageController(
        _ id: String,
        in pager: TesseraPagerViewController
    ) throws -> WindowedRLTPageController {
        try XCTUnwrap(
            pager.children
                .compactMap { $0 as? WindowedRLTPageController }
                .first { $0.pageID == id },
            "Page \(id) was not loaded by the pager"
        )
    }

    private func loadedPageIDs(_ pager: TesseraPagerViewController) -> Set<String> {
        Set(pager.children.compactMap { ($0 as? WindowedRLTPageController)?.pageID })
    }

    /// Drives the programmatic offset animation to its target if UIKit did not complete
    /// it synchronously in the test process. A repeated transition end is idempotent:
    /// the pager suppresses the duplicate `didShowPageAt` (lastShownPageIndex).
    private func completeAnimationIfNeeded(
        _ pager: TesseraPagerViewController,
        scrollView: UIScrollView,
        to targetX: CGFloat
    ) {
        if abs(scrollView.contentOffset.x - targetX) > 0.001 {
            scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        }
        pager.scrollViewDidEndScrollingAnimation(scrollView)
    }

    /// Progress in reading order from the raw offset, using the same Core contract
    /// that the pager is required to use.
    private func expectedProgress(
        rawOffsetX: CGFloat,
        direction: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        TesseraRTL.normalizedProgress(
            rawOffsetX / pageWidth,
            pageCount: pageCount,
            layoutDirection: direction
        )
    }

    // MARK: - On-screen page order

    /// RTL: the reading order is mirrored in the physical slots: reading page 0
    /// sits in the rightmost slot (`pageCount − 1 − index`), page 2
    /// in the left one. The window width and full-width pages are checked here too.
    func testRTLLayoutPlacesReadingPageZeroAtRightEdge() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )

        XCTAssertEqual(scrollView.bounds.width, pageWidth, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentSize.width, pageWidth * 3, accuracy: 0.001)
        XCTAssertEqual(pager.currentPageIndex, 0)
        // The strip is laid out mirrored; reading page 0 is aligned to the right edge.
        XCTAssertEqual(
            scrollView.contentOffset.x,
            scrollView.contentSize.width - scrollView.bounds.width,
            accuracy: 0.001,
            "in RTL, the alignment of reading page 0 is the right edge of the strip"
        )
        XCTAssertEqual(loadedPageIDs(pager), ["A", "B"], "the current page and the ±1 neighbor are in memory")

        // Going to page 1 loads the whole set of three and makes it possible to check
        // the frames of all slots.
        pager.go(toPage: 1, animated: false)
        pager.view.layoutIfNeeded()

        let a = try pageController("A", in: pager)
        let b = try pageController("B", in: pager)
        let c = try pageController("C", in: pager)
        XCTAssertEqual(a.view.frame.minX, pageWidth * 2, accuracy: 0.001, "reading page 0 is the right slot")
        XCTAssertEqual(b.view.frame.minX, pageWidth, accuracy: 0.001)
        XCTAssertEqual(c.view.frame.minX, 0, accuracy: 0.001, "reading page 2 is the left slot")
        for controller in [a, b, c] {
            XCTAssertEqual(controller.view.frame.width, pageWidth, accuracy: 0.001)
            XCTAssertEqual(controller.view.frame.height, pageSize.height, accuracy: 0.001)
        }
        XCTAssertTrue(a.view.superview === scrollView)
    }

    /// LTR contrast: the same three pages lie in reading order from left to right.
    func testLTRLayoutPlacesReadingPageZeroAtLeftEdge() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .leftToRight
        )

        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)
        pager.go(toPage: 1, animated: false)
        pager.view.layoutIfNeeded()

        let a = try pageController("A", in: pager)
        let b = try pageController("B", in: pager)
        let c = try pageController("C", in: pager)
        XCTAssertEqual(a.view.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(b.view.frame.minX, pageWidth, accuracy: 0.001)
        XCTAssertEqual(c.view.frame.minX, pageWidth * 2, accuracy: 0.001)
    }

    /// RTL: alignment by reading order: page 0 at the right edge,
    /// page 2 at the left, page 1 in the middle; in each case the offset
    /// equals the left edge of the visible page.
    func testRTLAlignmentOffsetsFollowReadingOrder() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )

        // After the first layout, reading page 0 is already shown (the right edge).
        pager.go(toPage: 0, animated: false)
        pager.view.layoutIfNeeded()
        let a = try pageController("A", in: pager)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.001)
        XCTAssertEqual(a.view.frame.minX, scrollView.contentOffset.x, accuracy: 0.001)

        pager.go(toPage: 2, animated: false)
        pager.view.layoutIfNeeded()
        let c = try pageController("C", in: pager)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001, "reading page 2 is at the left edge")
        XCTAssertEqual(c.view.frame.minX, 0, accuracy: 0.001)

        pager.go(toPage: 1, animated: false)
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pager.currentPageIndex, 1)
    }

    // MARK: - Normalized progress

    /// RTL: the delegate's progress is normalized by reading direction:
    /// `0` at reading page 0 (the right edge) and `pageCount − 1` at the last one.
    func testRTLProgressIsNormalizedByReadingDirection() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (pageWidth * 2, 0),
            (pageWidth * 1.5, 0.5),
            (pageWidth, 1),
            (pageWidth * 0.5, 1.5),
            (0, 2),
        ]

        for entry in cases {
            scrollView.contentOffset = CGPoint(x: entry.raw, y: 0)
            pager.scrollViewDidScroll(scrollView)

            let value = try XCTUnwrap(spy.progressValues.last)
            XCTAssertEqual(value, entry.expected, accuracy: 0.000_001, "RTL progress for offset \(entry.raw)")
            XCTAssertEqual(
                value,
                expectedProgress(rawOffsetX: entry.raw, direction: .rightToLeft),
                accuracy: 0.000_001,
                "the pager must normalize t via TesseraRTL"
            )
        }
        XCTAssertEqual(spy.progressValues.count, spy.progressRawOffsets.count)
    }

    /// LTR contrast: the raw `t` is reported without mirroring.
    func testLTRProgressMatchesRawOffset() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .leftToRight
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (pageWidth * 0.5, 0.5),
            (pageWidth, 1),
            (pageWidth * 1.5, 1.5),
            (pageWidth * 2, 2),
        ]

        for entry in cases {
            scrollView.contentOffset = CGPoint(x: entry.raw, y: 0)
            pager.scrollViewDidScroll(scrollView)

            let value = try XCTUnwrap(spy.progressValues.last)
            XCTAssertEqual(value, entry.expected, accuracy: 0.000_001, "LTR progress for offset \(entry.raw)")
            XCTAssertEqual(
                value,
                expectedProgress(rawOffsetX: entry.raw, direction: .leftToRight),
                accuracy: 0.000_001
            )
        }
    }

    /// Page shows without the initial show of page 0.
    ///
    /// The pager publishes page 0 on first appearance (the first-show
    /// contract: the page is visible although there was no transition). In a windowed environment
    /// this event may also arrive after a "warm-up", for example on the first
    /// programmatic transition completion. The test checks only new shows
    /// caused by accessibilityScroll, so the initial 0 is dropped; the error
    /// "0 was shown instead of the target page" is still caught by the next
    /// sequence check.
    private func pageShows(_ spy: WindowedPagerSpy) -> [Int] {
        var shows = spy.shownIndexes
        if shows.first == 0 {
            shows.removeFirst()
        }
        return shows
    }

    // MARK: - accessibilityScroll in RTL and LTR

    /// RTL: the physical directions of the three-finger swipe are inverted:
    /// `.right` pages forward in reading order (right = toward the previous
    /// physical slot), `.left` pages backward. The gesture is not handled at the boundaries.
    func testRTLAccessibilityScrollInvertsPhysicalDirections() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy
        XCTAssertEqual(pager.currentPageIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.001)

        // The initial show of page 0 is the first-show contract, not a transition.
        // We "warm it up" on the current page and clear the recorder: from here on
        // exactly the new shows caused by accessibilityScroll are checked.
        pager.go(toPage: 0, animated: false)
        XCTAssertTrue(
            spy.shownIndexes.isEmpty || spy.shownIndexes == [0],
            "before the gestures only the initial show of 0 is possible: \(spy.shownIndexes)"
        )
        spy.clearRecordedEvents()

        // Reading page 0: no previous page, the next is 1.
        XCTAssertFalse(pager.accessibilityScroll(.left), "in RTL .left is backward, there is no previous page")
        XCTAssertTrue(pager.accessibilityScroll(.right), "in RTL .right is forward in reading order")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1], "one accessibilityScroll gives exactly one new show")

        // The last reading page (2): no next page, the previous is 1.
        pager.go(toPage: 2, animated: false)
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)
        XCTAssertFalse(pager.accessibilityScroll(.right), "in RTL .right is forward, there is no last page")
        XCTAssertTrue(pager.accessibilityScroll(.left), "in RTL .left is backward in reading order")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1, 2, 1], "each accessibilityScroll gives exactly one new show")
    }

    /// LTR contrast: `.left` pages forward, `.right` pages backward; at the boundaries
    /// the gesture is not handled (the UIKit convention, as in `UIPageViewController`).
    func testLTRAccessibilityScrollKeepsPhysicalDirections() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .leftToRight
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy
        XCTAssertEqual(pager.currentPageIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)

        // The initial show of page 0 is the first-show contract, not a transition.
        // We "warm it up" on the current page and clear the recorder: from here on
        // exactly the new shows caused by accessibilityScroll are checked.
        pager.go(toPage: 0, animated: false)
        XCTAssertTrue(
            spy.shownIndexes.isEmpty || spy.shownIndexes == [0],
            "before the gestures only the initial show of 0 is possible: \(spy.shownIndexes)"
        )
        spy.clearRecordedEvents()

        XCTAssertFalse(pager.accessibilityScroll(.right), "in LTR .right is backward, there is no previous page")
        XCTAssertTrue(pager.accessibilityScroll(.left), "in LTR .left is forward")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1], "one accessibilityScroll gives exactly one new show")

        pager.go(toPage: 2, animated: false)
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.001)
        XCTAssertFalse(pager.accessibilityScroll(.left), "in LTR .left is forward, there is no last page")
        XCTAssertTrue(pager.accessibilityScroll(.right), "in LTR .right is backward")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1, 2, 1], "each accessibilityScroll gives exactly one new show")
    }
}

#endif
