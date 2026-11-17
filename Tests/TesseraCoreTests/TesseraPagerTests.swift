//
//  TesseraPagerTests.swift
//  TesseraCoreTests
//
//  Contract tests for the pager.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  the `t` invariant, a single writer of contentOffset, two pager modes, performance
//  discipline) and §3 (conceptual API surface):
//  (TesseraPagerViewController, TesseraPageDescriptor, TesseraPagerDelegate).
//
//  Checked: UIScrollView configuration for the paged/snapping modes,
//  `contentSize` geometry, the programmatic `go(toPage:)` transition, the invariant
//  t = contentOffset.x / pageWidth (LTR and RTL), snapping integration, and lazy
//  loading of the ±1 window. The tests run without a window and without spinning a run loop:
//  the controller loads its view and is laid out manually.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// A delegate spy: records the order and values of the pager's callbacks.
private final class TesseraPagerDelegateSpy: TesseraPagerDelegate {
    private(set) var shownIndexes: [Int] = []
    private(set) var progressValues: [CGFloat] = []

    var lastShownIndex: Int? { shownIndexes.last }
    var lastProgress: CGFloat? { progressValues.last }

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }

    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }
}

final class TesseraPagerTests: XCTestCase {

    private let pageWidth: CGFloat = 320
    private let pageHeight: CGFloat = 480

    // MARK: - Factory helpers

    private func makePages(count: Int) -> [TesseraPageDescriptor] {
        (0..<count).map { (index: Int) -> TesseraPageDescriptor in
            TesseraPageDescriptor(id: index, title: "Page \(index)") {
                UIViewController()
            }
        }
    }

    /// Loads the pager, sets the view size, lays it out, and returns
    /// the inner UIScrollView (the only direct child of the root view).
    private func makeLoadedPager(
        mode: TesseraPagerMode = .paged,
        pageCount: Int
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: mode, pages: makePages(count: pageCount))
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first,
            "The pager must contain a UIScrollView"
        )
        return (pager, scrollView)
    }

    // MARK: - Mode configuration

    /// `.paged`: `isPagingEnabled` is on, normal deceleration, indicators are
    /// off, and the delegate is the pager itself.
    func testPagedModeConfiguresScrollView() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertTrue(scrollView.isPagingEnabled)
        XCTAssertEqual(scrollView.decelerationRate, .normal)
        XCTAssertEqual(scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(scrollView.showsHorizontalScrollIndicator)
        XCTAssertFalse(scrollView.showsVerticalScrollIndicator)
        XCTAssertTrue(scrollView.alwaysBounceHorizontal)
        XCTAssertTrue(scrollView.delegate === pager)
    }

    /// `.snapping`: `isPagingEnabled` is off, deceleration is `.fast`; snapping
    /// is done by `TesseraSnapPolicy` (Core §2, "Two pager modes").
    func testSnappingModeConfiguresScrollView() throws {
        let pager = TesseraPagerViewController(mode: .snapping, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertFalse(scrollView.isPagingEnabled)
        XCTAssertEqual(scrollView.decelerationRate, .fast)
    }

    // MARK: - Geometry

    /// `contentSize` is `pageWidth × pageCount` horizontally and the view's height.
    func testLayoutSetsContentSizeForAllPages() throws {
        let (_, scrollView) = try makeLoadedPager(pageCount: 4)

        XCTAssertEqual(scrollView.bounds.width, pageWidth)
        XCTAssertEqual(scrollView.contentSize.width, pageWidth * 4)
        XCTAssertEqual(scrollView.contentSize.height, pageHeight)
    }

    /// Child pages get a full-width frame as tall as the scroll view.
    func testLoadedPageFramesFillScrollView() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 3)

        XCTAssertEqual(pager.children.count, 2)
        for child in pager.children {
            XCTAssertEqual(child.view.frame.width, scrollView.bounds.width)
            XCTAssertEqual(child.view.frame.height, scrollView.bounds.height)
        }
    }

    /// An empty page set: `contentSize` is zero, and transitions and accessibility
    /// do not crash.
    func testEmptyPagerKeepsZeroContentSize() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 0)

        XCTAssertEqual(scrollView.contentSize, .zero)
        XCTAssertTrue(pager.children.isEmpty)

        pager.go(toPage: 0, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
        XCTAssertFalse(pager.accessibilityScroll(.right))
    }

    // MARK: - go(toPage:)

    /// A programmatic transition sets the offset by the index in reading order (LTR):
    /// `index × pageWidth`, and the index is clamped to the set's bounds.
    func testGoToPageSetsContentOffsetInLTR() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 4)

        pager.go(toPage: 2, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)

        pager.go(toPage: 3, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3)

        pager.go(toPage: 0, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
    }

    /// An out-of-range index is clamped: 99 → the last page, -5 → the first.
    func testGoToPageClampsOutOfRangeIndexes() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 4)

        pager.go(toPage: 99, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3)

        pager.go(toPage: -5, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
    }

    /// A transition requested before the view loads is remembered and applied on the first layout,
    /// without an intermediate jump to the first page.
    func testPendingGoToPageIsAppliedOnFirstLayout() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 4))

        pager.go(toPage: 2, animated: false)

        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
    }

    /// A zero view width defers the transition until geometry appears.
    func testGoToPageWithZeroWidthDefersUntilLayout() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 4))
        pager.loadViewIfNeeded()
        pager.view.frame = .zero
        pager.view.layoutIfNeeded()

        pager.go(toPage: 2, animated: false)

        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
    }

    /// In RTL the page's physical slot is mirrored: index 0 is the rightmost
    /// page, `pageCount - 1` the leftmost (Core §2, the `t` invariant).
    func testGoToPageUsesMirroredSlotsInRTL() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 4))
        pager.loadViewIfNeeded()
        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        // The starting reading page 0 occupies physical slot 3.
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3)

        pager.go(toPage: 1, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)

        pager.go(toPage: 3, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
    }

    // MARK: - The t invariant

    /// LTR: `t = contentOffset.x / pageWidth` unchanged; the fractional part is
    /// the transition progress (Core §2, "Progress invariant").
    func testProgressInLTRFollowsRawOffset() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 3)
        let spy = TesseraPagerDelegateSpy()
        pager.delegate = spy

        scrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 1, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 0, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth * 1.5, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 1.5, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth * 2, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 2, accuracy: 0.0001)
    }

    /// RTL: the same raw offset is normalized from the reading direction:
    /// the left edge is the last reading page (Core §2, the `t` invariant).
    func testProgressInRTLIsMirroredToReadingDirection() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )
        let spy = TesseraPagerDelegateSpy()
        pager.delegate = spy

        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 2, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 1, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth * 2, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 0, accuracy: 0.0001)
    }

    // MARK: - Snapping integration

    /// `.snapping`: the target offset is computed by `TesseraSnapPolicy` from the actual
    /// page width and the gesture velocity.
    func testSnappingModeAppliesSnapPolicy() throws {
        let (pager, scrollView) = try makeLoadedPager(mode: .snapping, pageCount: 3)

        var fastTarget = CGPoint(x: 100, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 1000, y: 0),
            targetContentOffset: &fastTarget
        )
        XCTAssertEqual(fastTarget.x, pageWidth)

        var slowTarget = CGPoint(x: 100, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &slowTarget
        )
        XCTAssertEqual(slowTarget.x, 0)

        var lastPageTarget = CGPoint(x: 500, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &lastPageTarget
        )
        XCTAssertEqual(lastPageTarget.x, pageWidth * 2)
    }

    /// `.paged`: `isPagingEnabled` does the snapping, and the delegate method does not change
    /// the proposed offset.
    func testPagedModeDoesNotOverrideProposedOffset() throws {
        let (pager, scrollView) = try makeLoadedPager(mode: .paged, pageCount: 3)

        var target = CGPoint(x: 100, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 1000, y: 0),
            targetContentOffset: &target
        )

        XCTAssertEqual(target.x, 100)
    }

    // MARK: - Lazy loading of ±1

    /// Memory holds the current page and its ±1 neighbors; on a transition the window
    /// shifts, and controllers that were freed are not recreated again.
    func testLazyLoadingKeepsCurrentPageAndNeighbours() throws {
        var createdPages: [Int] = []
        let pages = (0..<5).map { (index: Int) -> TesseraPageDescriptor in
            TesseraPageDescriptor(id: index, title: "Page \(index)") {
                createdPages.append(index)
                return UIViewController()
            }
        }

        let pager = TesseraPagerViewController(mode: .paged, pages: pages)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()

        // The first page and its right neighbor.
        XCTAssertEqual(createdPages, [0, 1])
        XCTAssertEqual(pager.children.count, 2)

        // Go to 3: the window is 2...4, pages 0 and 1 are unloaded.
        pager.go(toPage: 3, animated: false)
        XCTAssertEqual(createdPages, [0, 1, 2, 3, 4])
        XCTAssertEqual(pager.children.count, 3)

        // Go to 4: only 3 and 4 are needed, page 2 is unloaded.
        pager.go(toPage: 4, animated: false)
        XCTAssertEqual(createdPages, [0, 1, 2, 3, 4])
        XCTAssertEqual(pager.children.count, 2)
    }

    // MARK: - Delegate

    /// An instant transition reports `didShowPageAt` exactly once.
    func testImmediateGoReportsShownPageOnce() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)
        let spy = TesseraPagerDelegateSpy()
        pager.delegate = spy

        pager.go(toPage: 1, animated: false)

        XCTAssertEqual(spy.shownIndexes, [1])
    }

    // MARK: - Accessibility

    /// Vertical directions and going out of bounds in LTR are not handled
    /// by the pager (pageStep = 0 or an index outside the set).
    func testAccessibilityScrollRejectsVerticalAndOutOfBoundsGestures() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)

        XCTAssertFalse(pager.accessibilityScroll(.up))
        XCTAssertFalse(pager.accessibilityScroll(.down))
        // First page: there is nowhere to go back (swipe right in LTR).
        XCTAssertFalse(pager.accessibilityScroll(.right))
    }

    /// In LTR a three-finger swipe left goes to the next page
    /// (the UIKit convention), and a swipe right goes back.
    ///
    /// Direction is checked at the set's boundaries so as not to depend on
    /// the transition animation: from the first page forward is possible, backward is not;
    /// from the last page it is the opposite.
    func testAccessibilityScrollMovesForwardInLTR() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)

        XCTAssertTrue(pager.accessibilityScroll(.left), "A swipe left in LTR pages forward")
    }

    /// In LTR a swipe right pages backward: from the last page backward is possible,
    /// forward (swipe left) is not.
    func testAccessibilityScrollMovesBackwardInLTR() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)
        pager.go(toPage: 2, animated: false)

        XCTAssertFalse(pager.accessibilityScroll(.left), "There is nowhere forward from the last page")
        XCTAssertTrue(pager.accessibilityScroll(.right), "A swipe right in LTR pages backward")
    }

    /// In RTL the physical direction is inverted: from the first page the "right"
    /// gesture leads forward and "left" leads backward (out of bounds).
    func testAccessibilityScrollRespectsRTL() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()

        XCTAssertFalse(pager.accessibilityScroll(.left))
        XCTAssertTrue(pager.accessibilityScroll(.right))
    }
}

#endif
