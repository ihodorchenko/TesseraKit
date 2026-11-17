//
//  TesseraPagerSnapTests.swift
//  TesseraCoreTests
//
//  Contract tests for the pager's snapping in `.snapping` mode.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  "Two pager modes": nearest center + velocity threshold; "Single writer").
//
//  Checked: converting UIKit velocity (points/ms) to the policy's pt/s; a ±1 step from
//  the page where the gesture began; the pager settling the offset itself when
//  a gesture ended without inertia at an unaligned offset.
//
//  The `setContentOffset(_:animated:)` animation behaves differently in a test process
//  without an app (without a window UIKit completes it synchronously), so
//  the tests accept both outcomes: synchronous completion or emulating the end of
//  the animation by calling `scrollViewDidEndScrollingAnimation`.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// A delegate spy: indexes of the shown pages.
private final class SnapDelegateSpy: TesseraPagerDelegate {
    var shownIndexes: [Int] = []

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }
}

final class TesseraPagerSnapTests: XCTestCase {

    private let pageWidth: CGFloat = 320
    private let pageHeight: CGFloat = 480

    // MARK: - Helpers

    private func makePages(count: Int) -> [TesseraPageDescriptor] {
        (0..<count).map { index in
            TesseraPageDescriptor(id: index, title: "Page \(index)") { UIViewController() }
        }
    }

    private func makeLoadedPager(
        mode: TesseraPagerMode = .snapping,
        pageCount: Int = 5
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: mode, pages: makePages(count: pageCount))
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )
        return (pager, scrollView)
    }

    /// Simulates a gesture: start at `start`, drag to `end`, release with
    /// UIKit velocity `velocity` (points/ms) and the proposed target `proposed`.
    /// Returns the target that the pager handed to the system.
    @discardableResult
    private func drag(
        _ pager: TesseraPagerViewController,
        _ scrollView: UIScrollView,
        from start: CGFloat,
        to end: CGFloat,
        velocity: CGFloat,
        proposed: CGFloat
    ) -> CGFloat {
        scrollView.contentOffset = CGPoint(x: start, y: 0)
        pager.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: end, y: 0)
        var target = CGPoint(x: proposed, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: velocity, y: 0),
            targetContentOffset: &target
        )
        return target.x
    }

    // MARK: - Velocity units and the starting page

    /// A 50 drag and a 1 pt/ms flick (= 1000 pt/s > the 600 threshold): the adjacent
    /// page. Before unit conversion, 1 "pt/s" was below the threshold: a rollback.
    func testShortFastFlickMovesToNeighbourPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        let target = drag(pager, scrollView, from: 0, to: 50, velocity: 1, proposed: 149)

        XCTAssertEqual(target, pageWidth)
    }

    /// Start 0, drag 100, flick 3 pt/ms (inertia proposes ≈397):
    /// page 1, not 2: the step is from the page where the gesture began.
    func testStrongFlickDoesNotSkipPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        let target = drag(pager, scrollView, from: 0, to: 100, velocity: 3, proposed: 397)

        XCTAssertEqual(target, pageWidth)
    }

    /// A backward flick from page 2: page 1, not 0.
    func testStrongBackwardFlickDoesNotSkipPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        let target = drag(pager, scrollView, from: 640, to: 540, velocity: -3, proposed: 243)

        XCTAssertEqual(target, pageWidth)
    }

    /// A slow gesture (0.4 pt/ms = 400 pt/s): the nearest page.
    func testSlowDragSnapsToNearestPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        XCTAssertEqual(drag(pager, scrollView, from: 0, to: 50, velocity: 0.4, proposed: 90), 0)
        XCTAssertEqual(drag(pager, scrollView, from: 0, to: 200, velocity: 0.4, proposed: 240), pageWidth)
    }

    /// One gesture's starting offset is not carried over to the next one.
    func testStartOffsetIsConsumedByOneGesture() throws {
        let (pager, scrollView) = try makeLoadedPager()
        drag(pager, scrollView, from: 0, to: 100, velocity: 3, proposed: 397)

        // The next "gesture" without willBeginDragging: the anchor is the one nearest to proposed.
        var target = CGPoint(x: 397, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 3, y: 0),
            targetContentOffset: &target
        )
        XCTAssertEqual(target.x, pageWidth * 2)
    }

    // MARK: - Settling without inertia

    /// The gesture ended with no velocity at an unaligned offset: UIKit does not
    /// move the offset to the target, so the pager itself starts an animation to the nearest
    /// page and completes the transition when it ends.
    func testDragWithoutVelocityAlignsOffset() throws {
        let (pager, scrollView) = try makeLoadedPager()
        let spy = SnapDelegateSpy()
        pager.delegate = spy
        pager.go(toPage: 0, animated: false)
        spy.shownIndexes.removeAll()

        let target = drag(pager, scrollView, from: 0, to: 200, velocity: 0, proposed: 200)
        XCTAssertEqual(target, pageWidth)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        // The pager itself drove the offset to page 1: without a window UIKit completes
        // the animation synchronously; otherwise we emulate its end.
        XCTAssertTrue(spy.shownIndexes.allSatisfy { $0 == 1 })
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, "offset is not aligned after a drag with no velocity")
        if spy.shownIndexes.isEmpty {
            scrollView.setContentOffset(CGPoint(x: pageWidth, y: 0), animated: false)
            pager.scrollViewDidEndScrollingAnimation(scrollView)
        }

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
        XCTAssertEqual(spy.shownIndexes, [1])
    }

    /// An already aligned offset: no settling is needed, the transition completes at once.
    func testDragEndingAlignedFinishesImmediately() throws {
        let (pager, scrollView) = try makeLoadedPager()
        let spy = SnapDelegateSpy()
        pager.delegate = spy

        drag(pager, scrollView, from: 0, to: pageWidth, velocity: 0, proposed: pageWidth)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertEqual(spy.shownIndexes, [1])
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
    }

    /// `.paged`: `isPagingEnabled` does the settling, and the pager completes
    /// the transition at once and leaves the offset alone.
    func testPagedModeDoesNotAlignAfterDrag() throws {
        let (pager, scrollView) = try makeLoadedPager(mode: .paged)
        let spy = SnapDelegateSpy()
        pager.delegate = spy

        drag(pager, scrollView, from: 0, to: 100, velocity: 0, proposed: 100)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertEqual(scrollView.contentOffset.x, 100)
        XCTAssertEqual(spy.shownIndexes, [0])
    }
}

#endif
