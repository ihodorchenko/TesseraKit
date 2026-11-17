//
//  TesseraRTLTests.swift
//  TesseraCoreTests
//
//  Contract tests for progress normalization by reading direction.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  "Progress invariant: t = offset.x / pageWidth; in RTL, t is normalized by
//  the reading direction") and §3 (conceptual API surface:
//  TesseraAccessibility / TesseraRTL utilities).
//
//  Both pure functions are checked: the continuous `normalizedProgress` and the discrete
//  `pageIndex`, in LTR and RTL, at the boundaries and for `pageCount <= 1`.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraRTLTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft

    // MARK: - normalizedProgress: LTR

    /// In LTR the raw progress is returned unchanged, including fractional values
    /// and out-of-range values during a bounce.
    func testNormalizedProgressIsIdentityInLTR() {
        let values: [CGFloat] = [-0.5, 0, 0.25, 1, 1.5, 2, 3.75, 4, 4.5]

        for value in values {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(value, pageCount: 5, layoutDirection: ltr),
                value,
                "LTR must not change the progress \(value)"
            )
        }
    }

    // MARK: - normalizedProgress: RTL

    /// In RTL the progress is mirrored about the middle of the strip:
    /// `pageCount - 1 - t`; continuity and sign are preserved.
    func testNormalizedProgressMirrorsInRTL() {
        let cases: [(input: CGFloat, expected: CGFloat)] = [
            (0, 4),
            (0.5, 3.5),
            (1, 3),
            (1.5, 2.5),
            (2, 2),
            (3.25, 0.75),
            (4, 0),
            (4.5, -0.5),
            (-0.5, 4.5),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(
                    entry.input,
                    pageCount: 5,
                    layoutDirection: rtl
                ),
                entry.expected,
                "RTL progress mirroring \(entry.input)"
            )
        }
    }

    /// For two pages, RTL mirroring reduces to `1 - t`.
    func testNormalizedProgressMirrorsTwoPagesInRTL() {
        XCTAssertEqual(
            TesseraRTL.normalizedProgress(0, pageCount: 2, layoutDirection: rtl),
            1
        )
        XCTAssertEqual(
            TesseraRTL.normalizedProgress(0.5, pageCount: 2, layoutDirection: rtl),
            0.5
        )
        XCTAssertEqual(
            TesseraRTL.normalizedProgress(1, pageCount: 2, layoutDirection: rtl),
            0
        )
    }

    /// `pageCount <= 1`: there is nothing to normalize, so the progress is returned as is
    /// in both directions.
    func testNormalizedProgressWithSinglePageIsIdentity() {
        for count in [1, 0, -3] {
            for direction in [ltr, rtl] {
                XCTAssertEqual(
                    TesseraRTL.normalizedProgress(0.75, pageCount: count, layoutDirection: direction),
                    0.75,
                    "count=\(count), direction=\(direction)"
                )
            }
        }
    }

    // MARK: - pageIndex: LTR

    /// LTR: the index is the integer part of the progress, clamped to `0...pageCount - 1`.
    func testPageIndexInLTRFloorsAndClamps() {
        let cases: [(input: CGFloat, expected: Int)] = [
            (0, 0),
            (0.99, 0),
            (1, 1),
            (1.99, 1),
            (2.5, 2),
            (4, 4),
            (4.99, 4),
            (100, 4),
            (-100, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.input, pageCount: 5, layoutDirection: ltr),
                entry.expected,
                "LTR index for t=\(entry.input)"
            )
        }
    }

    // MARK: - pageIndex: RTL

    /// RTL: first the physical index is taken (floor + clamp), then it
    /// is mirrored into reading order: `pageCount - 1 - index`.
    func testPageIndexInRTLMirrorsPhysicalIndex() {
        let cases: [(input: CGFloat, expected: Int)] = [
            (0, 4),
            (0.99, 4),
            (1, 3),
            (1.99, 3),
            (2, 2),
            (3, 1),
            (4, 0),
            (4.99, 0),
            (-0.5, 4),
            (-10, 4),
            (10, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.input, pageCount: 5, layoutDirection: rtl),
                entry.expected,
                "RTL index for t=\(entry.input)"
            )
        }
    }

    /// For two pages the RTL index is `1 - floor(t)` within bounds.
    func testPageIndexWithTwoPagesInRTL() {
        XCTAssertEqual(TesseraRTL.pageIndex(for: 0, pageCount: 2, layoutDirection: rtl), 1)
        XCTAssertEqual(TesseraRTL.pageIndex(for: 0.9, pageCount: 2, layoutDirection: rtl), 1)
        XCTAssertEqual(TesseraRTL.pageIndex(for: 1, pageCount: 2, layoutDirection: rtl), 0)
        XCTAssertEqual(TesseraRTL.pageIndex(for: 1.5, pageCount: 2, layoutDirection: rtl), 0)
    }

    // MARK: - pageIndex: defensive cases

    /// `pageCount <= 1`: the index is always 0, since the single page is both
    /// the first and the last.
    func testPageIndexWithSinglePageIsAlwaysZero() {
        for count in [1, 0, -3] {
            for direction in [ltr, rtl] {
                XCTAssertEqual(
                    TesseraRTL.pageIndex(for: 2.5, pageCount: count, layoutDirection: direction),
                    0,
                    "count=\(count), direction=\(direction)"
                )
            }
        }
    }

    /// `NaN` in LTR is treated as the first page (0).
    func testPageIndexNaNIsZeroInLTR() {
        XCTAssertEqual(
            TesseraRTL.pageIndex(for: .nan, pageCount: 5, layoutDirection: ltr),
            0
        )
    }

    /// Infinities are clamped to the bounds without `Int` overflow.
    func testPageIndexInfinityClampsToBoundaries() {
        XCTAssertEqual(
            TesseraRTL.pageIndex(for: .infinity, pageCount: 5, layoutDirection: ltr),
            4
        )
        XCTAssertEqual(
            TesseraRTL.pageIndex(for: -.infinity, pageCount: 5, layoutDirection: ltr),
            0
        )
    }
}

#endif
