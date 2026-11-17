//
//  FolderStaggerTests.swift
//  TesseraStartScreenTests
//
//  Tests for the icon cascade of the expanded folder panel (D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, section "Tile grid",
//  section "Reduce Motion"; D17 in docs/STATE.md: icons appear in a cascade
//  of ~35 ms per index.
//
//  `TesseraTileGridView.staggerDelay(index:)` is a pure function: the tests check
//  non-negativity, monotonicity, linearity and determinism. No timers or
//  UI loop are needed.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderStaggerTests: XCTestCase {

    /// Zero and negative indices do not delay the icon appearance.
    func testZeroAndNegativeIndicesHaveNoDelay() {
        XCTAssertEqual(TesseraTileGridView.staggerDelay(index: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(TesseraTileGridView.staggerDelay(index: -1), 0, accuracy: 1e-12)
        XCTAssertEqual(TesseraTileGridView.staggerDelay(index: -100), 0, accuracy: 1e-12)
    }

    /// The delay is linear in the index: `index × folderIconStagger`.
    func testDelayIsLinearInIndex() {
        for index in 0...12 {
            XCTAssertEqual(
                TesseraTileGridView.staggerDelay(index: index),
                TimeInterval(index) * TesseraTileGridView.folderIconStagger,
                accuracy: 1e-12,
                "Index \(index)"
            )
        }
    }

    /// The delay is non-negative and does not decrease as the index grows.
    func testDelayIsNonNegativeAndMonotonic() {
        var previous: TimeInterval = 0

        for index in 0...64 {
            let delay = TesseraTileGridView.staggerDelay(index: index)
            XCTAssertGreaterThanOrEqual(delay, 0, "Index \(index)")
            XCTAssertGreaterThanOrEqual(delay, previous, "Index \(index)")
            previous = delay
        }
    }

    /// The function is deterministic: a repeated call gives the same value.
    func testDelayIsDeterministic() {
        for index in [0, 1, 3, 4, 9, 25, 100] {
            XCTAssertEqual(
                TesseraTileGridView.staggerDelay(index: index),
                TesseraTileGridView.staggerDelay(index: index)
            )
        }
    }

    /// The cascade constant is the positive micro-delay from D17 (35 ms).
    func testStaggerConstantIsMicroDelay() {
        XCTAssertEqual(TesseraTileGridView.folderIconStagger, 0.035, accuracy: 1e-9)
        XCTAssertGreaterThan(TesseraTileGridView.folderIconStagger, 0)
        XCTAssertLessThan(TesseraTileGridView.folderIconStagger, 0.1)
    }
}

#endif
