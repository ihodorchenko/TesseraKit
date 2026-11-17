//
//  PivotRTLTests.swift
//  TesseraPivotTests
//
//  Contract tests for Pivot RTL.
//  Design document: docs/PIVOT-IOS-DESIGN.md §8 (accessibility and system
//  integration: in RTL everything is mirrored, both the header order and the swipe direction)
//  and §4 (core math: the indicator is interpolated by centers in reading
//  order). Normalizing progress and indexes is a shared Core contract
//  (docs/CORE-IOS-DESIGN.md §2, progress invariant): Pivot does not duplicate
//  the mirroring, but works with `TesseraRTL`-normalized values.
//
//  Checked: normalizing `t` and indexes via `TesseraRTL` in LTR and RTL;
//  reading headers/selection in reading order; mirroring of the pager's physical
//  slots on a programmatic transition; inversion of the VoiceOver gesture in RTL.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPivot

final class PivotRTLTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft
    private let pivotSize = CGSize(width: 320, height: 640)

    // MARK: - Helpers

    private func makeSections(count: Int) -> [TesseraPivotSection] {
        (0..<count).map { index in
            TesseraPivotSection(id: index, title: "Section \(index)") {
                UIViewController()
            }
        }
    }

    /// A Pivot with forced RTL: the direction is set before the first layout,
    /// because the pages' physical slots are computed in it (§8).
    private func makeLoadedRTLPivot(
        sectionCount: Int = 4
    ) throws -> (pivot: TesseraPivotViewController, scrollView: UIScrollView) {
        let pivot = TesseraPivotViewController(sections: makeSections(count: sectionCount))
        pivot.loadViewIfNeeded()

        pivot.view.semanticContentAttribute = .forceRightToLeft
        pivot.pagerViewController.view.semanticContentAttribute = .forceRightToLeft

        pivot.view.frame = CGRect(origin: .zero, size: pivotSize)
        pivot.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            pivot.pagerViewController.view.subviews
                .compactMap { $0 as? UIScrollView }
                .first,
            "The Pivot pager must contain a UIScrollView"
        )
        return (pivot, scrollView)
    }

    // MARK: - Progress normalization (§4, TesseraRTL)

    /// LTR: the section progress is the raw `contentOffset.x / pageWidth`, unchanged.
    func testNormalizedProgressIsIdentityInLTR() {
        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (0.5, 0.5),
            (1, 1),
            (1.5, 1.5),
            (2, 2),
            (2.5, 2.5),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(
                    entry.raw,
                    pageCount: 3,
                    layoutDirection: ltr
                ),
                entry.expected,
                "LTR must not mirror t=\(entry.raw)"
            )
        }
    }

    /// RTL: the progress is mirrored about the middle of the strip:
    /// `pageCount - 1 - t`, so `0` stays the first section for
    /// the user (§8, §4).
    func testNormalizedProgressMirrorsSectionsInRTL() {
        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 2),
            (0.5, 1.5),
            (1, 1),
            (1.5, 0.5),
            (2, 0),
            (-0.5, 2.5),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.normalizedProgress(
                    entry.raw,
                    pageCount: 3,
                    layoutDirection: rtl
                ),
                entry.expected,
                "RTL mirroring of t=\(entry.raw)"
            )
        }
    }

    /// LTR: the index is the integer part of the progress with a clamp (the rule "the integer part is
    /// the index", docs/CORE-IOS-DESIGN.md §2).
    func testPageIndexInLTRFloorsRawProgress() {
        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 0),
            (0.99, 0),
            (1, 1),
            (1.99, 1),
            (2.5, 2),
            (3, 3),
            (3.99, 3),
            (99, 3),
            (-1, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.raw, pageCount: 4, layoutDirection: ltr),
                entry.expected,
                "LTR index for t=\(entry.raw)"
            )
        }
    }

    /// RTL: first the physical slot is taken (floor + clamp), then it is
    /// mirrored into reading order: the index is always in reading order (§8).
    func testPageIndexInRTLMapsPhysicalSlotToReadingIndex() {
        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 3),
            (0.99, 3),
            (1, 2),
            (2, 1),
            (3, 0),
            (99, 0),
            (-1, 3),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraRTL.pageIndex(for: entry.raw, pageCount: 4, layoutDirection: rtl),
                entry.expected,
                "RTL index for t=\(entry.raw)"
            )
        }
    }

    // MARK: - The indicator in reading order (§4)

    /// In RTL the header centers arrive in reading order, that is, they decrease in
    /// coordinate: section `0` is the rightmost. Interpolation must work
    /// with these centers as is, without mirroring again.
    func testIndicatorInterpolatesMirroredCentersInReadingOrder() {
        // Sections 0, 1, 2: centers in the RTL strip's content coordinates.
        let centers: [CGFloat] = [300, 160, 40]

        let cases: [(t: CGFloat, expected: CGFloat)] = [
            (0, 300),
            (0.5, 230),
            (1, 160),
            (1.5, 100),
            (2, 40),
            // A clamp on bounce: beyond the bounds are the edge sections, not a "drift".
            (3.5, 40),
            (-1, 300),
        ]

        for entry in cases {
            XCTAssertEqual(
                TesseraPivotHeaderIndicator.indicatorCenter(centers: centers, progress: entry.t),
                entry.expected,
                accuracy: 0.000_001,
                "t=\(entry.t) in RTL geometry"
            )
        }
    }

    // MARK: - The strip: reading order in LTR and RTL

    /// `titles` is always in reading order: RTL changes only the visual
    /// layout, not the data model (§8).
    func testStripKeepsTitlesInReadingOrderInBothDirections() {
        for attribute: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
            let strip = TesseraPivotHeaderStripView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 48)
            )
            strip.semanticContentAttribute = attribute
            strip.titles = ["One", "Two", "Three"]

            XCTAssertEqual(
                strip.titles,
                ["One", "Two", "Three"],
                "the header order does not depend on the layout direction"
            )
        }
    }

    /// The strip's selection is in reading order: the progress `t` in RTL mode is already
    /// normalized by Core, so `selectedIndex` does not depend on the direction.
    func testStripSelectionUsesReadingOrderInRTL() {
        let strip = TesseraPivotHeaderStripView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 48)
        )
        strip.semanticContentAttribute = .forceRightToLeft
        strip.titles = ["One", "Two", "Three", "Four"]

        let cases: [(t: CGFloat, expected: Int)] = [
            (0, 0),
            (0.49, 0),
            (0.5, 1),
            (1.5, 2),
            (3, 3),
            (10, 3),
        ]

        for entry in cases {
            strip.apply(progress: entry.t)
            XCTAssertEqual(
                strip.selectedIndex,
                entry.expected,
                "t=\(entry.t) in RTL must select reading section \(entry.expected)"
            )
        }
    }

    // MARK: - Pivot in RTL: physical slots and the VoiceOver gesture

    /// A programmatic transition uses mirrored physical slots: reading section
    /// `0` lives in the rightmost slot, while `index` stays in
    /// reading order outward (§5, §8).
    func testPivotSelectSectionUsesMirroredSlotsInRTL() throws {
        let (pivot, scrollView) = try makeLoadedRTLPivot(sectionCount: 4)
        let pageWidth = scrollView.bounds.width

        // The starting reading section 0 occupies physical slot 3.
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3, accuracy: 0.5)

        pivot.selectSection(at: 1, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 1, "the index is in reading order")
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 1)

        pivot.selectSection(at: 3, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 3)
    }

    /// The VoiceOver gesture is inverted in RTL relative to LTR: in LTR a swipe left
    /// pages forward (the UIKit convention), so in RTL "right" leads forward
    /// in reading order, and "left" from the first section goes backward, past the set's boundary (§8).
    func testPivotAccessibilityScrollInvertsDirectionInRTL() throws {
        let (pivot, _) = try makeLoadedRTLPivot(sectionCount: 3)

        XCTAssertFalse(
            pivot.accessibilityScroll(.left),
            "In RTL, left is backward, and there is nowhere to go from the first section"
        )
        XCTAssertTrue(pivot.accessibilityScroll(.right))
        XCTAssertEqual(pivot.currentSectionIndex, 1)

        XCTAssertTrue(pivot.accessibilityScroll(.left))
        XCTAssertEqual(pivot.currentSectionIndex, 0)
    }
}

#endif
