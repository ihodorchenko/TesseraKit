//
//  PanoScrollViewVelocityTests.swift
//  TesseraPanoramaTests
//
//  Where the panorama invokes snapping: `TesseraPanoScrollView` receives the
//  velocity from UIKit in points/ms, converts it to pt/s (`× 1000`) for
//  `TesseraSnapPolicy`, and passes the gesture's starting offset from
//  `scrollViewWillBeginDragging`, so that the ±1 step is counted from the section where the gesture began.
//  Design document: docs/PANORAMA-IOS-DESIGN.md §4 (geometry and core
//  math: snapping is nearest center + velocity threshold) and the section on implementation
//  deviations.
//
//  Regressions these tests catch:
//  - without unit conversion a short fast flick (1 pt/ms = 1000 pt/s) falls below
//    the 600 pt/s threshold and rolls back to section 0;
//  - without anchoring on the starting section the step is counted from `nearest(proposed)` and
//    overshoots a section (target 2 instead of 1).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoScrollViewVelocityTests: XCTestCase {

    /// The screen width (as in `PanoSnapTests`).
    private let screenWidth: CGFloat = 390

    /// Peek (§4: 16…64 pt); the section step is `390 − 48 = 342` pt.
    private let peek: CGFloat = 48

    // MARK: - Helpers

    private func makeScrollView(sectionCount: Int = 4) -> TesseraPanoScrollView {
        let scrollView = TesseraPanoScrollView(peek: peek)
        scrollView.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 700)
        scrollView.sectionCount = sectionCount
        scrollView.contentSize = scrollView.requiredContentSize
        return scrollView
    }

    /// Replays a gesture the way UIKit delivers it: drag begins at `startX`,
    /// the drag runs to `startX + dragDistance`, and drag ends with velocity
    /// `velocityPointsPerMs` (points/ms). If `proposedX` is not given, the proposed
    /// target is estimated with UIKit's inertia formula:
    /// `offset + v × r / (1 − r)`, where `r` is the scroll view's `decelerationRate` (`.fast`).
    ///
    /// - Returns: the snap target written by the scroll view into `targetContentOffset`.
    private func simulateDrag(
        _ scrollView: TesseraPanoScrollView,
        startX: CGFloat = 0,
        dragDistance: CGFloat,
        velocityPointsPerMs: CGFloat,
        proposedX: CGFloat? = nil
    ) -> CGFloat {
        scrollView.contentOffset = CGPoint(x: startX, y: 0)
        scrollView.scrollViewWillBeginDragging(scrollView)

        let releaseX = startX + dragDistance
        scrollView.contentOffset = CGPoint(x: releaseX, y: 0)

        let rate = scrollView.decelerationRate.rawValue
        let inertia = velocityPointsPerMs * rate / (1 - rate)
        var target = CGPoint(x: proposedX ?? (releaseX + inertia), y: 0)
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: velocityPointsPerMs, y: 0),
            targetContentOffset: &target
        )
        return target.x
    }

    // MARK: - Tests

    /// A drag of ~100 pt from section 0 and a release at 3 pt/ms (3000 pt/s):
    /// the target is exactly section 1. Neither an overshoot to section 2 (a step from
    /// `nearest(proposed)`) nor a rollback to 0.
    func testFastFlickFromFirstSectionLandsOnNextSection() {
        let scrollView = makeScrollView()
        let itemWidth = scrollView.itemWidth
        XCTAssertEqual(itemWidth, screenWidth - peek, accuracy: 0.000_001)

        let target = simulateDrag(
            scrollView,
            dragDistance: 100,
            velocityPointsPerMs: 3
        )

        XCTAssertEqual(target, itemWidth, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: target), 1)
    }

    /// The same drag, but the system proposed a target with long inertia (around
    /// section 2): one gesture still moves no farther than one section from
    /// the starting one.
    func testFastFlickWithLongInertiaDoesNotSkipSection() {
        let scrollView = makeScrollView()
        let itemWidth = scrollView.itemWidth

        let target = simulateDrag(
            scrollView,
            dragDistance: 100,
            velocityPointsPerMs: 3,
            proposedX: 2 * itemWidth
        )

        XCTAssertEqual(target, itemWidth, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: target), 1)
    }

    /// A short flick: 50 pt and 1 pt/ms (1000 pt/s > the 600 pt/s threshold). The section nearest to
    /// the proposed target is 0, but the velocity is above the threshold: the target is section 1.
    /// Without the points/ms → pt/s conversion the flick would roll back.
    func testShortQuickFlickAdvancesToNextSection() {
        let scrollView = makeScrollView()
        let itemWidth = scrollView.itemWidth

        let target = simulateDrag(
            scrollView,
            dragDistance: 50,
            velocityPointsPerMs: 1
        )

        XCTAssertEqual(target, itemWidth, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: target), 1)
    }
}

#endif
