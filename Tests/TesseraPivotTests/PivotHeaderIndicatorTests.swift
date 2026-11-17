//
//  PivotHeaderIndicatorTests.swift
//  TesseraPivotTests
//
//  Contract tests for the pivot indicator math.
//  Design document: docs/PIVOT-IOS-DESIGN.md §4 (core math:
//  `indicatorCenter = lerp(center[i], center[i + 1], frac(t))`; coloring is
//  by the header's distance from `t`), §7 (performance: the indicator
//  is driven by a transform only), §11 (risks: interpolation with different
//  header widths is the most likely area of visual bugs, mitigated
//  by tests on random sets).
//
//  Both functions under test are static and read no state, so no UI run loop,
//  window, or main thread is needed for them.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPivot

final class PivotHeaderIndicatorTests: XCTestCase {

    // MARK: - Helpers

    /// A deterministic generator (SplitMix64): random sets must be
    /// reproducible when a test fails, otherwise the bug cannot be localized.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Header centers of varying widths in strip content coordinates (§4):
    /// the cell width plus gaps and outer insets.
    private func makeCenters(
        widths: [CGFloat],
        inset: CGFloat = 16,
        spacing: CGFloat = 20
    ) -> [CGFloat] {
        var centers: [CGFloat] = []
        centers.reserveCapacity(widths.count)

        var originX = inset
        for width in widths {
            centers.append(originX + width / 2)
            originX += width + spacing
        }
        return centers
    }

    // MARK: - indicatorCenter: boundaries (t = 0, t = count - 1, out of range)

    /// An empty set of centers: there is no strip, the indicator is hidden and sits at zero.
    func testEmptyCentersReturnZero() {
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: [], progress: 0),
            0
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: [], progress: 3.5),
            0
        )
    }

    /// A single header (`count < 2`): there is nothing to interpolate with, so it is always its center,
    /// even for progress out of range and for `NaN`.
    func testSingleCenterIsReturnedForAnyProgress() {
        let centers: [CGFloat] = [123.5]

        for progress: CGFloat in [0, 0.25, 1, 10, -10, .nan, .infinity, -.infinity] {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: progress),
                123.5,
                "the only center must be returned at t=\(progress)"
            )
        }
    }

    /// `t = 0` is the first center, `t = count - 1` is the last (§4).
    func testFirstAndLastCentersAtBounds() {
        let centers = makeCenters(widths: [40, 120, 64])

        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: 0),
            centers[0]
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: CGFloat(centers.count - 1)),
            centers[2]
        )
    }

    /// During a bounce the progress goes out of range, but the indicator must not move
    /// past the edge headers: a clamp to `0...count - 1` (§4).
    func testOutOfRangeProgressClampsToEdgeCenters() {
        let centers = makeCenters(widths: [40, 120, 64, 200])

        for progress: CGFloat in [-0.001, -1, -100, -CGFloat.greatestFiniteMagnitude] {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: progress),
                centers[0],
                "t=\(progress) must clamp to the first center"
            )
        }

        for progress: CGFloat in [4.001, 4.5, 100, CGFloat.greatestFiniteMagnitude] {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: progress),
                centers[3],
                "t=\(progress) must clamp to the last center"
            )
        }
    }

    /// `NaN`: undefined progress is treated as the start of the strip.
    func testNaNProgressReturnsFirstCenter() {
        let centers = makeCenters(widths: [40, 120, 64])
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: .nan),
            centers[0]
        )
    }

    /// Infinities are clamped to the bounds (and do not overflow the conversion to `Int`).
    func testInfiniteProgressClampsToEdgeCenters() {
        let centers = makeCenters(widths: [40, 120, 64, 200])
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: .infinity),
            centers[3]
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: -.infinity),
            centers[0]
        )
    }

    // MARK: - indicatorCenter: interpolation between centers of different widths

    /// At whole `t` the indicator sits exactly at the corresponding header's center:
    /// the §4 subtlety matters: centers are interpolated, not `t × constWidth`.
    func testIntegerProgressReturnsExactCenter() {
        let centers = makeCenters(widths: [36, 120, 64, 200, 88])

        for index in centers.indices {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(
                    centers: centers,
                    progress: CGFloat(index)
                ),
                centers[index],
                accuracy: 0.000_001,
                "t=\(index) must give the center of header \(index)"
            )
        }
    }

    /// Half a transition between headers of different widths is exactly the midpoint
    /// of the segment between their centers, not the point "t × average width" (§4).
    func testInterpolationFollowsCentersNotConstantWidthSteps() {
        let widths: [CGFloat] = [40, 160, 60, 220]
        let centers = makeCenters(widths: widths)

        let midpoint = TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: 0.5)
        XCTAssertEqual(midpoint, (centers[0] + centers[1]) / 2, accuracy: 0.000_001)

        // The false "equal steps" model would give a noticeably different value
        // at these widths: the indicator would "drift" away from the text in the middle of a swipe.
        let averageStep = (centers[centers.count - 1] - centers[0]) / CGFloat(centers.count - 1)
        let constantStepMidpoint = centers[0] + averageStep * 0.5
        XCTAssertGreaterThan(
            abs(midpoint - constantStepMidpoint),
            1,
            "the centers interpolation must differ from a linear step at different widths"
        )
    }

    /// Fractional progress gives `lerp(center[i], center[i + 1], frac(t))`, where
    /// `i = floor(t)`, and on the last transition the fractional part is taken from
    /// the clamped progress (otherwise the indicator would go past the last header).
    func testInterpolationUsesFractionOfClampedProgress() {
        let centers = makeCenters(widths: [40, 120, 64])

        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: 0.25),
            centers[0] + (centers[1] - centers[0]) * 0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: 1.25),
            centers[1] + (centers[2] - centers[1]) * 0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: 1.75),
            centers[1] + (centers[2] - centers[1]) * 0.75,
            accuracy: 0.000_001
        )
        // t = count - 1 + 0.5 clamps to the last center and does not interpolate
        // again from the last pair with a fractional part of 1.5.
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: 2.5),
            centers[2],
            accuracy: 0.000_001
        )
    }

    /// At an integer index boundary the function is continuous: to the left and right of `t = i`
    /// the values coincide within a small neighborhood.
    func testIndicatorCenterIsContinuousAcrossIntegerBoundary() {
        let centers = makeCenters(widths: [50, 140, 70, 210])

        for index in 1..<centers.count {
            let epsilon: CGFloat = 0.000_001
            let left = TesseraPivotHeaderIndicator.indicatorCenter(
                centers: centers,
                progress: CGFloat(index) - epsilon
            )
            let right = TesseraPivotHeaderIndicator.indicatorCenter(
                centers: centers,
                progress: CGFloat(index) + epsilon
            )

            XCTAssertEqual(left, centers[index], accuracy: 0.001)
            XCTAssertEqual(right, centers[index], accuracy: 0.001)
        }
    }

    /// Random sets of centers with arbitrary widths and gaps:
    /// the result must match an independent `lerp(frac)` computation, where `t`
    /// is built as `i + frac`, not the other way around.
    func testRandomUnevenCenterSetsFollowLerp() {
        var generator = SeededGenerator(seed: 0x5EED_1234)

        for _ in 0..<50 {
            let count = Int.random(in: 2...8, using: &generator)
            var centers: [CGFloat] = []
            centers.reserveCapacity(count)

            var position = CGFloat.random(in: 0...40, using: &generator)
            for _ in 0..<count {
                let width = CGFloat.random(in: 20...180, using: &generator)
                centers.append(position + width / 2)
                position += width + CGFloat.random(in: 4...40, using: &generator)
            }

            for _ in 0..<10 {
                let lowerIndex = Int.random(in: 0..<(count - 1), using: &generator)
                let fraction = CGFloat.random(in: 0...1, using: &generator)
                let progress = CGFloat(lowerIndex) + fraction

                let expected = centers[lowerIndex] * (1 - fraction)
                    + centers[lowerIndex + 1] * fraction
                let actual = TesseraPivotHeaderIndicator.indicatorCenter(
                    centers: centers,
                    progress: progress
                )

                XCTAssertEqual(
                    actual,
                    expected,
                    accuracy: 0.000_001,
                    "lerp on random centers \(centers), t=\(progress)"
                )

                // The indicator does not leave the segment between adjacent centers.
                let lowerCenter = min(centers[lowerIndex], centers[lowerIndex + 1])
                let upperCenter = max(centers[lowerIndex], centers[lowerIndex + 1])
                XCTAssertGreaterThanOrEqual(actual, lowerCenter - 0.000_001)
                XCTAssertLessThanOrEqual(actual, upperCenter + 0.000_001)
            }
        }
    }

    /// Random progress values out of range on random sets
    /// clamp to the edge centers.
    func testRandomOutOfRangeProgressClamps() {
        var generator = SeededGenerator(seed: 0xC0FF_EE01)

        for _ in 0..<25 {
            let count = Int.random(in: 2...7, using: &generator)
            var centers: [CGFloat] = []
            centers.reserveCapacity(count)

            var position = CGFloat.random(in: 0...30, using: &generator)
            for _ in 0..<count {
                let width = CGFloat.random(in: 30...160, using: &generator)
                centers.append(position + width / 2)
                position += width + CGFloat.random(in: 5...35, using: &generator)
            }

            let below = -CGFloat.random(in: 0.001...100, using: &generator)
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: below),
                centers[0]
            )

            let above = CGFloat(count - 1) + CGFloat.random(in: 0.001...100, using: &generator)
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: above),
                centers[count - 1]
            )
        }
    }

    /// On ascending sets of centers the indicator moves monotonically left to right:
    /// no jerks backward and no "teleports" over headers (§4).
    func testRandomSortedCentersProduceMonotonicPositions() {
        var generator = SeededGenerator(seed: 0xB16_5EED)

        for _ in 0..<20 {
            let count = Int.random(in: 2...7, using: &generator)
            var centers: [CGFloat] = []
            centers.reserveCapacity(count)

            var position = CGFloat.random(in: 0...30, using: &generator)
            for _ in 0..<count {
                let width = CGFloat.random(in: 30...200, using: &generator)
                centers.append(position + width / 2)
                position += width + CGFloat.random(in: 8...40, using: &generator)
            }

            var previous = -CGFloat.greatestFiniteMagnitude
            let steps = 200

            for step in 0...steps {
                let progress = CGFloat(step) / CGFloat(steps) * CGFloat(count - 1)
                let center = TesseraPivotHeaderIndicator.indicatorCenter(
                    centers: centers,
                    progress: progress
                )

                XCTAssertGreaterThanOrEqual(
                    center,
                    previous - 0.000_001,
                    "the indicator moved backward at t=\(progress), centers \(centers)"
                )
                previous = center
            }
        }
    }

    // MARK: - blendFactor: coloring by distance from t (§4)

    /// At the point `t` the header is fully active: a factor of `1` means
    /// the full accent color (§4, text coloring). The contract is inverted
    /// relative to the wording "0 at distance 0": in code and in the document
    /// `1` is the accent and `0` is the inactive state.
    func testBlendFactorIsFullAccentAtZeroDistance() {
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0), 1)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: -0), 1)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0, span: 3), 1)
    }

    /// At a distance of `span` and beyond there is no highlight: the factor is `0`.
    func testBlendFactorReachesZeroAtSpan() {
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 1), 0)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: -1), 0)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 5), 0)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: -5), 0)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 2, span: 2), 0)
    }

    /// Within `span` the factor is linear and symmetric in the sign of the distance.
    func testBlendFactorIsSymmetricAndLinearWithinSpan() {
        for distance: CGFloat in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let expected = 1 - distance
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: distance),
                expected,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: -distance),
                expected,
                accuracy: 0.000_001
            )
        }
    }

    /// The factor decreases monotonically with distance and stays in `0...1`:
    /// the accent smoothly "passes" from the outgoing header to the incoming one.
    func testBlendFactorIsMonotonicallyDecreasing() {
        var previous = TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0)

        for step in 1...40 {
            let distance = CGFloat(step) * 0.05
            let factor = TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: distance)

            XCTAssertLessThanOrEqual(factor, previous + 0.000_001)
            XCTAssertGreaterThanOrEqual(factor, 0)
            XCTAssertLessThanOrEqual(factor, 1)
            previous = factor
        }
    }

    /// The highlight radius scales the distance: with `span = 2` half the
    /// accent is at a distance of `1`.
    func testBlendFactorHonoursCustomSpan() {
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0.5, span: 2),
            0.75,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 1, span: 2),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 1.5, span: 2),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 3, span: 2),
            0,
            accuracy: 0.000_001
        )
    }

    /// `span <= 0` means "nothing to blur": `1` exactly at the point and `0` in all other
    /// cases (the defensive contract is documented on the method).
    func testBlendFactorWithNonPositiveSpanDegradesToBinary() {
        for span: CGFloat in [0, -1, -0.5] {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0, span: span),
                1
            )
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0.1, span: span),
                0
            )
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: -2, span: span),
                0
            )
        }
    }

    /// `NaN` and an infinite distance: an unknown header is treated as
    /// inactive (`0`), without crashing and without "poisoning" the color.
    func testBlendFactorRejectsNaNAndInfiniteDistance() {
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: .nan), 0)
        XCTAssertEqual(
            TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: 0.5, span: .nan),
            0
        )
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: .infinity), 0)
        XCTAssertEqual(TesseraPivotHeaderIndicator.blendFactor(distanceFromProgress: -.infinity), 0)
    }

    // MARK: - Indicator view (§3, §7, §8)

    /// View defaults: a 24×3 pt underline, the accent color, decorative:
    /// the indicator does not catch events and is not in the accessibility tree (§8).
    func testViewDefaults() {
        let indicator = TesseraPivotHeaderIndicator()

        XCTAssertEqual(indicator.barWidth, 24)
        XCTAssertEqual(indicator.barHeight, 3)
        XCTAssertEqual(indicator.activeColor, .systemBlue)
        XCTAssertEqual(indicator.backgroundColor, .systemBlue)
        XCTAssertFalse(indicator.isUserInteractionEnabled)
        XCTAssertFalse(indicator.isAccessibilityElement)
        XCTAssertTrue(indicator.isHidden)
    }

    /// `placeBar(inStripBounds:)` is the only place where the indicator's
    /// `bounds`/`center` are set; the position is pinned to the strip's bottom edge.
    func testPlaceBarSetsBaseGeometry() {
        let indicator = TesseraPivotHeaderIndicator()
        indicator.placeBar(inStripBounds: CGRect(x: 10, y: 20, width: 320, height: 48))

        XCTAssertEqual(indicator.bounds.width, 24)
        XCTAssertEqual(indicator.bounds.height, 3)
        XCTAssertEqual(indicator.center.x, 12)
        // The strip's bottom edge: maxY - barHeight / 2.
        XCTAssertEqual(indicator.center.y, 66.5, accuracy: 0.000_001)
        XCTAssertEqual(indicator.layer.cornerRadius, 1.5)
        XCTAssertEqual(indicator.transform, .identity)
    }

    /// The hot path (§4, §7): `move(toCenterX:)` changes only `transform`,
    /// leaving `bounds`/`center` alone and not triggering layout.
    func testMoveChangesOnlyTransform() {
        let indicator = TesseraPivotHeaderIndicator()
        indicator.placeBar(inStripBounds: CGRect(x: 0, y: 0, width: 320, height: 48))

        let boundsBefore = indicator.bounds
        let centerBefore = indicator.center

        indicator.move(toCenterX: 100)

        XCTAssertEqual(indicator.transform.tx, 100 - 24 / 2, accuracy: 0.000_001)
        XCTAssertEqual(indicator.bounds, boundsBefore)
        XCTAssertEqual(indicator.center, centerBefore)

        indicator.move(toCenterX: 250)

        XCTAssertEqual(indicator.transform.tx, 250 - 24 / 2, accuracy: 0.000_001)
        XCTAssertEqual(indicator.bounds, boundsBefore)
        XCTAssertEqual(indicator.center, centerBefore)
    }
}

#endif
