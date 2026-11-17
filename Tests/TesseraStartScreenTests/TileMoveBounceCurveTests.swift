//
//  TileMoveBounceCurveTests.swift
//  TesseraStartScreenTests
//
//  Tests for the tile move bounce curve.
//  Design document: docs/PLAN.md: neighbor movements during a reorder
//  end with a light "bounce" `cubic-bezier(0.175, 0.885, 0.32, 1.1)`,
//  without abrupt jumps.
//
//  The factory's control points and the chosen duration are checked:
//  pure logic, no UI cycle or timers needed. The folder panel curve
//  (`cubic-bezier(0.1, 0.9, 0.2, 1)`) is not changed by this and is not
//  checked here; its contract belongs to D17.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileMoveBounceCurveTests: XCTestCase {

    /// The factory's control points match the specification.
    func testBounceControlPointsMatchSpecification() {
        let timing = TesseraTileGridView.bounceTimingParameters()

        XCTAssertEqual(timing.controlPoint1.x, 0.175, accuracy: 1e-9)
        XCTAssertEqual(timing.controlPoint1.y, 0.885, accuracy: 1e-9)
        XCTAssertEqual(timing.controlPoint2.x, 0.32, accuracy: 1e-9)
        XCTAssertEqual(timing.controlPoint2.y, 1.1, accuracy: 1e-9)
    }

    /// `controlPoint2.y > 1`: the curve overshoots the target, so this is a real
    /// "bounce" and not an ordinary deceleration.
    func testCurveOvershootsTarget() {
        let timing = TesseraTileGridView.bounceTimingParameters()

        XCTAssertGreaterThan(
            timing.controlPoint2.y,
            1,
            "The curve must overshoot the target, otherwise there is no bounce"
        )
    }

    /// The duration falls into the documented window (0.22–0.28 s).
    func testTileMoveDurationIsInsideDocumentedWindow() {
        let duration = TesseraTileGridView.tileMoveDuration

        XCTAssertGreaterThanOrEqual(duration, 0.22)
        XCTAssertLessThanOrEqual(duration, 0.28)
    }

    /// The neighbors' move is shorter than the folder panel expansion: the D17 curve and duration
    /// (0.28 s) are not touched by this.
    func testTileMoveIsShorterThanFolderExpansion() {
        XCTAssertLessThan(
            TesseraTileGridView.tileMoveDuration,
            TesseraTileGridView.folderExpansionDuration
        )
    }

    /// The factory is deterministic: a repeated call gives the same control points.
    func testFactoryIsDeterministic() {
        let first = TesseraTileGridView.bounceTimingParameters()
        let second = TesseraTileGridView.bounceTimingParameters()

        XCTAssertEqual(first.controlPoint1, second.controlPoint1)
        XCTAssertEqual(first.controlPoint2, second.controlPoint2)
    }
}

#endif
