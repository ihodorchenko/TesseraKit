//
//  TesseraAccessibilityTests.swift
//  TesseraCoreTests
//
//  Contract tests for the accessibility utilities.
//  Design document: docs/CORE-IOS-DESIGN.md §1 (package composition)
//  (TesseraAccessibilityKit: pagination, page-change announcements, RTL normalization)
//  and §2 (key contracts: in RTL, "forward" follows the reading direction).
//
//  Checks `pageStep(for:layoutDirection:)` for every VoiceOver gesture direction
//  in LTR and RTL: the physical `.left`/`.right` are inverted, the ordinal
//  `.next`/`.previous` are not (otherwise the mirroring would be applied twice).
//
//  Convention for physical directions: a three-finger swipe left
//  (`.left`) in LTR pages forward, like the system `UIPageViewController`
//  (its accessibility implementation takes the next controller on `.left`
//  and the previous one on `.right`).
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraAccessibilityTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft

    // MARK: - Physical directions

    /// LTR: swipe left goes to the next page, swipe right to the previous one
    /// (the UIKit convention, as in `UIPageViewController`).
    func testPhysicalDirectionsInLTR() {
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .left, layoutDirection: ltr), 1)
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .right, layoutDirection: ltr), -1)
    }

    /// RTL: physical directions are inverted. The next page in reading
    /// order lies on the left, so a swipe right leads forward.
    func testPhysicalDirectionsInRTL() {
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .right, layoutDirection: rtl), 1)
        XCTAssertEqual(TesseraAccessibility.pageStep(for: .left, layoutDirection: rtl), -1)
    }

    // MARK: - Ordinal directions

    /// `.next`/`.previous` are defined in reading order and are not mirrored again
    /// in RTL (otherwise a "back" gesture would page forward).
    func testOrdinalDirectionsAreIndependentOfLayoutDirection() {
        for direction in [ltr, rtl] {
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .next, layoutDirection: direction),
                1,
                "next, direction=\(direction)"
            )
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .previous, layoutDirection: direction),
                -1,
                "previous, direction=\(direction)"
            )
        }
    }

    // MARK: - Vertical directions

    /// Vertical gestures are not addressed to the horizontal pager, so the step is 0
    /// in both layout directions.
    func testVerticalDirectionsProduceZeroStep() {
        for direction in [ltr, rtl] {
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .up, layoutDirection: direction),
                0,
                "up, direction=\(direction)"
            )
            XCTAssertEqual(
                TesseraAccessibility.pageStep(for: .down, layoutDirection: direction),
                0,
                "down, direction=\(direction)"
            )
        }
    }

    // MARK: - Full direction table

    /// Combined check of all supported directions in both layout directions.
    func testPageStepTable() {
        let cases: [(direction: UIAccessibilityScrollDirection,
                     layout: UIUserInterfaceLayoutDirection,
                     expected: Int)] = [
            (.left, ltr, 1),
            (.left, rtl, -1),
            (.right, ltr, -1),
            (.right, rtl, 1),
            (.next, ltr, 1),
            (.next, rtl, 1),
            (.previous, ltr, -1),
            (.previous, rtl, -1),
            (.up, ltr, 0),
            (.up, rtl, 0),
            (.down, ltr, 0),
            (.down, rtl, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraAccessibility.pageStep(
                    for: entry.direction,
                    layoutDirection: entry.layout
                ),
                entry.expected,
                "direction=\(entry.direction), layout=\(entry.layout)"
            )
        }
    }

    // MARK: - Reduce Motion

    /// The Reduce Motion utility reads the system setting (type
    /// `Bool`); the value is neither cached nor overridden.
    func testReduceMotionFlagIsReadable() {
        let value = TesseraAccessibility.isReduceMotionEnabled
        XCTAssertEqual(value, UIAccessibility.isReduceMotionEnabled)
    }

    /// An empty announcement string is ignored: the method does not crash and posts nothing.
    func testEmptyAnnouncementIsIgnored() {
        TesseraAccessibility.announcePageChange("")
    }
}

#endif
