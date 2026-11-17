//
//  PanoSnapTests.swift
//  TesseraPanoramaTests
//
//  Contract tests for the panorama's snapping with peek.
//  Design document: docs/PANORAMA-IOS-DESIGN.md §4 (geometry and core
//  math: `itemWidth = screenWidth − peek`; snapping is nearest center + velocity
//  threshold; `pagingEnabled` does not fit; clamp at the boundaries) and §8
//  (adaptivity and edge cases: a single section means no snapping; an empty list).
//
//  Checked: the section width "screen minus peek", the pure
//  `TesseraSnapPolicy` at this width (nearest center, velocity threshold, boundary
//  clamp, degenerate inputs), and the same policy combined with `TesseraPanoScrollView`.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoSnapTests: XCTestCase {

    /// The screen width for which the geometry is computed (§4).
    private let screenWidth: CGFloat = 390

    /// The peek margin of the next section (§4: 16…64 pt).
    private let peek: CGFloat = 48

    /// §4: `itemWidth = screenWidth − peek`; 342 pt for a 390 screen and peek 48.
    /// The snap step must equal this value, not the screen width.
    private var itemWidth: CGFloat { screenWidth - peek }

    // MARK: - Helpers

    private func makeScrollView(
        sectionCount: Int = 4,
        width: CGFloat? = nil
    ) -> TesseraPanoScrollView {
        let scrollView = TesseraPanoScrollView(peek: peek)
        scrollView.frame = CGRect(
            x: 0,
            y: 0,
            width: width ?? screenWidth,
            height: 700
        )
        scrollView.sectionCount = sectionCount
        scrollView.contentSize = scrollView.requiredContentSize
        return scrollView
    }

    /// The pure snap policy at the panorama's section width (§4).
    private func snapTarget(
        proposed: CGFloat,
        velocity: CGFloat = 0,
        width: CGFloat? = nil,
        pageCount: Int = 4,
        policy: TesseraSnapPolicy = TesseraSnapPolicy()
    ) -> CGFloat {
        policy.targetContentOffset(
            proposedOffset: proposed,
            velocity: velocity,
            itemWidth: width ?? itemWidth,
            pageCount: pageCount
        )
    }

    /// The snap target that `TesseraPanoScrollView` hands to the system.
    private func scrollViewTarget(
        _ scrollView: TesseraPanoScrollView,
        proposed: CGFloat,
        velocity: CGFloat = 0
    ) -> CGFloat {
        var target = CGPoint(x: proposed, y: 0)
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: velocity, y: 0),
            targetContentOffset: &target
        )
        return target.x
    }

    // MARK: - Geometry: itemWidth = screen − peek (§4)

    /// The section width and `contentSize` are computed from peek: 4 sections at a 390 screen
    /// and peek 48 give a step of 342 pt and a strip of `4 × 342 + 48 = 1416` pt. The upper
    /// bound of the offset matches the last snap step (§4, snapping).
    func testItemWidthAndContentSizeFollowPeek() {
        let scrollView = makeScrollView()

        XCTAssertEqual(scrollView.itemWidth, itemWidth, accuracy: 0.000_001)
        XCTAssertNotEqual(
            scrollView.itemWidth,
            screenWidth,
            "peek must reduce the section width relative to the screen (§4)"
        )
        XCTAssertEqual(
            scrollView.contentSize.width,
            CGFloat(4) * itemWidth + peek,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollView.maximumOffsetX,
            CGFloat(3) * itemWidth,
            accuracy: 0.000_001
        )
    }

    // MARK: - Nearest center (§4, snapping)

    /// `.center` rounds the position to the nearest section in steps of `itemWidth`, not
    /// the screen width: the transition boundary is 171 pt (half of 342).
    func testCenterAlignmentRoundsToNearestPeekSection() {
        let cases: [(proposed: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (100, 0),
            (170, 0),
            (171, 342),
            (300, 342),
            (512, 342),
            (513, 684),
            (683, 684),
            (684, 684),
            (855, 1_026),
            (1_000, 1_026),
        ]

        for entry in cases {
            XCTAssertEqual(
                snapTarget(proposed: entry.proposed),
                entry.expected,
                accuracy: 0.000_001,
                "offset \(entry.proposed) must snap to \(entry.expected)"
            )
        }
    }

    // MARK: - Velocity threshold (§4, snapping)

    /// A fast swipe moves exactly one section from the nearest one: the threshold is strict
    /// (`abs(velocity) > threshold`), and exactly at the 600 pt/s threshold we stay in place.
    func testVelocityThresholdIsStrict() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: 600, policy: policy),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: -600, policy: policy),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: 601, policy: policy),
            CGFloat(2) * itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: itemWidth, velocity: -601, policy: policy),
            0,
            accuracy: 0.000_001
        )
    }

    /// A fast swipe steps a section in the direction of movement even from an "undershoot":
    /// at 100 pt (nearest section 0) a positive velocity leads to 342.
    func testFastSwipeStepsToNeighbourOfNearestSection() {
        XCTAssertEqual(
            snapTarget(proposed: 100, velocity: 700),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: 600, velocity: -700),
            itemWidth,
            accuracy: 0.000_001
        )
    }

    // MARK: - Boundary clamp (§4)

    /// Snapping does not go beyond `0...((pageCount − 1) × itemWidth)`: past the strip's edge
    /// the standard bounce remains, and the policy does not interfere with it (§4).
    func testSnapClampsToSectionBounds() {
        let cases: [(proposed: CGFloat, velocity: CGFloat, pageCount: Int, expected: CGFloat)] = [
            (5_000, 0, 4, 1_026),
            (1_026, 2_000, 4, 1_026),
            (-100, 0, 4, 0),
            (-100, -2_000, 4, 0),
            (5_000, 2_000, 3, 684),
            (-5_000, -2_000, 3, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                snapTarget(
                    proposed: entry.proposed,
                    velocity: entry.velocity,
                    pageCount: entry.pageCount
                ),
                entry.expected,
                accuracy: 0.000_001,
                "snap outside [0, (n − 1) × itemWidth] for proposed \(entry.proposed)"
            )
        }
    }

    // MARK: - A single section (§8)

    /// A single section has nothing to page to: the section width equals the screen (peek is not
    /// subtracted), `contentSize` is the viewport, and snapping always goes to zero.
    func testSingleSectionHasNoSnap() {
        XCTAssertEqual(
            snapTarget(proposed: 500, velocity: 2_000, pageCount: 1),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapTarget(proposed: -500, velocity: -2_000, pageCount: 1),
            0,
            accuracy: 0.000_001
        )

        let scrollView = makeScrollView(sectionCount: 1)
        XCTAssertEqual(scrollView.itemWidth, screenWidth, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollView.contentSize.width,
            screenWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 300, velocity: 2_000),
            0,
            accuracy: 0.000_001
        )
    }

    /// An empty set of sections: the section width formally equals the screen, but
    /// `contentSize` is empty and the system's proposed target is not rewritten.
    func testEmptyPanoramaHasNoSnapTarget() {
        let scrollView = makeScrollView(sectionCount: 0)

        XCTAssertEqual(scrollView.contentSize, .zero)
        XCTAssertEqual(scrollView.itemWidth, screenWidth, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 300),
            300,
            accuracy: 0.000_001
        )
    }

    // MARK: - Degenerate policy inputs

    /// `itemWidth <= 0` (including `NaN`): there is nothing to snap to, and the system's
    /// proposal is returned unchanged (the `TesseraSnapPolicy` contract).
    func testDegenerateItemWidthReturnsProposal() {
        let proposals: [CGFloat] = [123.456, -50, 0]

        for width: CGFloat in [0, -itemWidth, .nan] {
            for proposed in proposals {
                XCTAssertEqual(
                    snapTarget(proposed: proposed, width: width),
                    proposed,
                    accuracy: 0.000_001,
                    "width \(width), proposed \(proposed): expected the original offset"
                )
            }
        }
    }

    /// `pageCount <= 0`: the system's proposal is returned unchanged.
    func testDegeneratePageCountReturnsProposal() {
        for count in [0, -2] {
            XCTAssertEqual(
                snapTarget(proposed: 400, velocity: 1_000, pageCount: count),
                400,
                accuracy: 0.000_001,
                "pageCount \(count): nothing to snap to"
            )
        }
    }

    /// While there is no width yet (the view is outside the hierarchy), `itemWidth == 0` and the scroll view
    /// does not rewrite the snap target.
    func testZeroWidthScrollViewReturnsProposal() {
        let scrollView = makeScrollView(sectionCount: 4, width: 0)

        XCTAssertEqual(scrollView.itemWidth, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 300),
            300,
            accuracy: 0.000_001
        )
    }

    // MARK: - Scroll view configuration (§4, snapping)

    /// §4: `pagingEnabled` is off (full-page paging cannot do peek),
    /// deceleration is `.fast`, the direction is locked, and bounce is enabled only
    /// when there is more than one section (§8).
    func testSnapConfigurationMatchesDocument() {
        let scrollView = TesseraPanoScrollView(frame: .zero)

        XCTAssertFalse(scrollView.isPagingEnabled)
        XCTAssertEqual(scrollView.decelerationRate, .fast)
        XCTAssertTrue(scrollView.isDirectionalLockEnabled)
        XCTAssertEqual(scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(scrollView.alwaysBounceHorizontal)

        scrollView.sectionCount = 2
        XCTAssertTrue(scrollView.alwaysBounceHorizontal)

        scrollView.sectionCount = 1
        XCTAssertFalse(scrollView.alwaysBounceHorizontal)
    }

    // MARK: - Snapping combined with TesseraPanoScrollView

    /// `TesseraPanoScrollView` feeds the policy exactly `itemWidth = screen − peek`:
    /// 400 pt at a step of 342 is section 1, whereas at a step of 390 it would be 0.
    func testScrollViewSnapUsesPeekItemWidth() {
        let scrollView = makeScrollView()

        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 400),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 380),
            itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 513),
            CGFloat(2) * itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: itemWidth, velocity: 601),
            CGFloat(2) * itemWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: itemWidth, velocity: -601),
            0,
            accuracy: 0.000_001
        )
    }

    /// The scroll view's strip boundaries match the policy's clamp boundaries:
    /// the last step `3 × 342 = 1026` is also `maximumOffsetX`.
    func testScrollViewSnapClampsAtEdges() {
        let scrollView = makeScrollView()

        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 5_000),
            scrollView.maximumOffsetX,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: -100),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            scrollViewTarget(scrollView, proposed: 1_026, velocity: 2_000),
            scrollView.maximumOffsetX,
            accuracy: 0.000_001
        )
    }
}

#endif
