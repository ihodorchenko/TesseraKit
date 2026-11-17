//
//  TesseraSnapPolicyTests.swift
//  TesseraCoreTests
//
//  Contract tests for snapping.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  "Two pager modes": nearest center + velocity threshold) and §3
//  (conceptual API surface: TesseraSnapPolicy is the snapping config).
//
//  Checks the pure function `targetContentOffset(...)`: it does not depend on UIKit and
//  therefore runs both on iOS and on a macOS host (the file does not require UIKit).
//  Velocity scenarios are expressed in UIKit units (points/ms) and converted
//  to pt/s the same way the policy's consumers do it.
//

import XCTest
@testable import TesseraCore

/// The `UIScrollView.DecelerationRate.fast` coefficient (0.99 per millisecond):
/// the constant is duplicated so that the file does not depend on UIKit.
private enum UIScrollViewFastDecelerationRateForTests {
    static let value: CGFloat = 0.99
}

final class TesseraSnapPolicyTests: XCTestCase {

    /// The default snap step for tests: 100 pt.
    private let itemWidth: CGFloat = 100

    /// A generic policy call with default parameters.
    private func targetOffset(
        proposed: CGFloat,
        velocity: CGFloat = 0,
        itemWidth: CGFloat? = nil,
        pageCount: Int = 5,
        policy: TesseraSnapPolicy = TesseraSnapPolicy()
    ) -> CGFloat {
        policy.targetContentOffset(
            proposedOffset: proposed,
            velocity: velocity,
            itemWidth: itemWidth ?? self.itemWidth,
            pageCount: pageCount
        )
    }

    // MARK: - .center alignment

    /// `.center` rounds to the nearest section; half-integer values go up
    /// (the standard `CGFloat.rounded()` rule: away from zero).
    func testCenterAlignmentRoundsToNearestSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600, alignment: .center)

        XCTAssertEqual(targetOffset(proposed: 0, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 49, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 50, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 51, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 149, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 150, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 249, policy: policy), 200)
    }

    /// Half-integer indexes (0.5, 1.5, 2.5) are rounded away from zero with `.center`.
    func testCenterAlignmentRoundsHalfValuesAwayFromZero() {
        let policy = TesseraSnapPolicy(alignment: .center)

        XCTAssertEqual(targetOffset(proposed: 50, pageCount: 4, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 150, pageCount: 4, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 250, pageCount: 4, policy: policy), 300)
    }

    // MARK: - .leading alignment

    /// `.leading` computes the index as `floor(offset / itemWidth + 0.5)`: half-integers
    /// always go up, unlike rounding "away from zero" on negative values.
    func testLeadingAlignmentRoundsHalfUp() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600, alignment: .leading)

        XCTAssertEqual(targetOffset(proposed: 0, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 49.9, policy: policy), 0)
        XCTAssertEqual(targetOffset(proposed: 50, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 99.9, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 149.9, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 150, policy: policy), 200)
    }

    /// For non-negative offsets the `.center` and `.leading` formulas coincide
    /// (this is recorded in the documentation of `targetContentOffset`).
    func testAlignmentsAgreeOnNonNegativeOffsets() {
        let center = TesseraSnapPolicy(alignment: .center)
        let leading = TesseraSnapPolicy(alignment: .leading)
        let proposals: [CGFloat] = [0, 12.5, 25, 37.5, 50, 62.5, 75, 87.5, 100,
                                    250, 500, 750, 1000]

        for proposed in proposals {
            XCTAssertEqual(
                targetOffset(proposed: proposed, policy: center),
                targetOffset(proposed: proposed, policy: leading),
                "The alignment formulas diverged at non-negative offset \(proposed)"
            )
        }
    }

    /// A negative offset is clamped to zero with any alignment: there is nothing to snap to
    /// left of the first section.
    func testNegativeOffsetsClampToFirstSection() {
        let center = TesseraSnapPolicy(alignment: .center)
        let leading = TesseraSnapPolicy(alignment: .leading)

        for proposed: CGFloat in [-10, -50, -60, -150, -250] {
            XCTAssertEqual(targetOffset(proposed: proposed, policy: center), 0)
            XCTAssertEqual(targetOffset(proposed: proposed, policy: leading), 0)
        }
    }

    // MARK: - Velocity threshold: real scenarios
    //
    // UIKit reports velocity in points/ms, while the policy expects pt/s: the consumer
    // converts it with `× 1000`. A flick's `proposedOffset` already includes inertia:
    // for `.fast` (0.99/ms) the projection is ≈ `offset + v(pt/ms) × 0.99 / 0.01`.

    /// UIKit velocity (points/ms) in the policy's units (pt/s).
    private func pointsPerSecond(_ pointsPerMillisecond: CGFloat) -> CGFloat {
        pointsPerMillisecond * 1000
    }

    /// The UIKit inertia target with `decelerationRate = .fast`.
    private func projectedOffset(from offset: CGFloat, pointsPerMillisecond velocity: CGFloat) -> CGFloat {
        let rate = UIScrollViewFastDecelerationRateForTests.value
        return offset + velocity * rate / (1 - rate)
    }

    /// Start 0, drag 100, flick 3 pt/ms (3000 pt/s) with a section width of 320:
    /// inertia proposes ≈397 (the nearest is 1), but the step is counted from the starting
    /// section, so the result is 1, not 2 (a section overshoot).
    func testFastFlickStepsOneSectionFromGestureStart() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 100, pointsPerMillisecond: 3)
        XCTAssertEqual(proposed, 397, accuracy: 0.5)

        let target = TesseraSnapPolicy().targetContentOffset(
            proposedOffset: proposed,
            velocity: pointsPerSecond(3),
            itemWidth: width,
            pageCount: 5,
            startOffset: 0
        )
        XCTAssertEqual(target, width, "one gesture goes no farther than the adjacent section")

        // Without a starting offset the anchor is the one nearest to proposed: an overshoot.
        let legacy = TesseraSnapPolicy().targetContentOffset(
            proposedOffset: proposed,
            velocity: pointsPerSecond(3),
            itemWidth: width,
            pageCount: 5
        )
        XCTAssertEqual(legacy, width * 2)
    }

    /// A short drag of 50 and a flick of 1 pt/ms (1000 pt/s > 600): the adjacent section,
    /// although inertia proposes ≈149 (the nearest is the current 0).
    func testShortFastFlickMovesToNeighbour() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 50, pointsPerMillisecond: 1)

        XCTAssertEqual(
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: proposed,
                velocity: pointsPerSecond(1),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            width
        )
    }

    /// The same short drag below the threshold (0.4 pt/ms = 400 pt/s):
    /// a rollback to the nearest section.
    func testShortSlowDragReturnsToNearest() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 50, pointsPerMillisecond: 0.4)

        XCTAssertEqual(
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: proposed,
                velocity: pointsPerSecond(0.4),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            0
        )
    }

    /// A backward flick starting at section 2: drag −100, −3 pt/ms: the result is 1,
    /// not 0.
    func testFastBackwardFlickStepsOneSectionFromGestureStart() {
        let width: CGFloat = 320
        let proposed = projectedOffset(from: 540, pointsPerMillisecond: -3)

        XCTAssertEqual(
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: proposed,
                velocity: pointsPerSecond(-3),
                itemWidth: width,
                pageCount: 5,
                startOffset: 640
            ),
            width
        )
    }

    /// A flick against the drag direction: dragged forward, flicked backward:
    /// a step from the starting section by the velocity's sign (clamped to zero at the first).
    func testFlickAgainstDragDirectionUsesVelocitySign() {
        let width: CGFloat = 320
        let policy = TesseraSnapPolicy()

        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 380, pointsPerMillisecond: -1),
                velocity: pointsPerSecond(-1),
                itemWidth: width,
                pageCount: 5,
                startOffset: 320
            ),
            0
        )
        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 80, pointsPerMillisecond: -2),
                velocity: pointsPerSecond(-2),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            0
        )
    }

    /// A non-numeric starting offset is ignored: the anchor is the nearest one.
    func testNonFiniteStartOffsetFallsBackToNearest() {
        XCTAssertEqual(
            targetOffset(proposed: 100, velocity: 1000),
            TesseraSnapPolicy().targetContentOffset(
                proposedOffset: 100,
                velocity: 1000,
                itemWidth: itemWidth,
                pageCount: 5,
                startOffset: .nan
            )
        )
    }

    /// The threshold is strict (`abs(velocity) > threshold`): exactly at the threshold we stay on
    /// the nearest section; slightly above it, a step from the starting one.
    func testVelocityAtThresholdKeepsNearestSection() {
        let policy = TesseraSnapPolicy(velocityThreshold: 600)

        for start: CGFloat? in [nil, 100] {
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 130, velocity: 600, itemWidth: itemWidth, pageCount: 5, startOffset: start), 100)
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 70, velocity: -600, itemWidth: itemWidth, pageCount: 5, startOffset: start), 100)
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 130, velocity: 600.5, itemWidth: itemWidth, pageCount: 5, startOffset: start), 200)
            XCTAssertEqual(policy.targetContentOffset(proposedOffset: 70, velocity: -600.5, itemWidth: itemWidth, pageCount: 5, startOffset: start), 0)
        }
    }

    /// A negative threshold is normalized to zero: any nonzero velocity
    /// counts as a fast swipe, zero velocity does not.
    func testNegativeVelocityThresholdIsTreatedAsZero() {
        let policy = TesseraSnapPolicy(velocityThreshold: -100)

        XCTAssertEqual(targetOffset(proposed: 100, velocity: 0, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 5, policy: policy), 200)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: -5, policy: policy), 0)
    }

    /// A custom threshold in pt/s: 1500 pt/s (1.5 pt/ms): a 1 pt/ms flick
    /// is already "slow", 2 pt/ms is fast.
    func testCustomVelocityThreshold() {
        let width: CGFloat = 320
        let policy = TesseraSnapPolicy(velocityThreshold: 1500)

        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 50, pointsPerMillisecond: 1),
                velocity: pointsPerSecond(1),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            0
        )
        XCTAssertEqual(
            policy.targetContentOffset(
                proposedOffset: projectedOffset(from: 50, pointsPerMillisecond: 2),
                velocity: pointsPerSecond(2),
                itemWidth: width,
                pageCount: 5,
                startOffset: 0
            ),
            width
        )
    }

    // MARK: - Clamp to [0, (pageCount - 1) * itemWidth]

    /// The offset does not go beyond the last section.
    func testUpperBoundClamp() {
        XCTAssertEqual(targetOffset(proposed: 200, velocity: 2000, pageCount: 3), 200)
        XCTAssertEqual(targetOffset(proposed: 1000, velocity: 0, pageCount: 3), 200)
        XCTAssertEqual(targetOffset(proposed: 250, velocity: 0, pageCount: 3), 200)
    }

    /// The offset does not go below the first section.
    func testLowerBoundClamp() {
        XCTAssertEqual(targetOffset(proposed: 0, velocity: -2000, pageCount: 3), 0)
        XCTAssertEqual(targetOffset(proposed: -1000, velocity: 0, pageCount: 3), 0)
    }

    /// For a single page only a zero offset is valid.
    func testSinglePageAlwaysReturnsZero() {
        XCTAssertEqual(targetOffset(proposed: 500, velocity: 2000, pageCount: 1), 0)
        XCTAssertEqual(targetOffset(proposed: -500, velocity: -2000, pageCount: 1), 0)
        XCTAssertEqual(targetOffset(proposed: 0, velocity: 0, pageCount: 1), 0)
    }

    // MARK: - Degenerate inputs

    /// An invalid section width (0, negative, NaN): there is nothing to snap to,
    /// and the system's proposal is returned unchanged.
    func testDegenerateItemWidthReturnsProposedOffset() {
        let proposals: [CGFloat] = [123.456, -50, 0]

        for width: CGFloat in [0, -100, .nan] {
            for proposed in proposals {
                XCTAssertEqual(
                    targetOffset(proposed: proposed, itemWidth: width),
                    proposed,
                    "Width \(width), proposed \(proposed): expected the original offset"
                )
            }
        }
    }

    /// An invalid page count (0, negative): the system's proposal is returned
    /// unchanged.
    func testDegeneratePageCountReturnsProposedOffset() {
        for count in [0, -2] {
            XCTAssertEqual(
                targetOffset(proposed: 123.456, velocity: 1000, pageCount: count),
                123.456
            )
        }
    }

    // MARK: - Default configuration

    /// Defaults: a threshold of 600 pt/s and `.center` alignment.
    func testDefaultConfiguration() {
        let policy = TesseraSnapPolicy()

        XCTAssertEqual(policy.velocityThreshold, 600)
        XCTAssertEqual(policy.alignment, .center)

        // A behavioral check of the default threshold.
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 600, policy: policy), 100)
        XCTAssertEqual(targetOffset(proposed: 100, velocity: 601, policy: policy), 200)
    }
}
