//
//  PanoRTLTests.swift
//  TesseraPanoramaTests
//
//  Contract tests for the panorama's RTL geometry.
//  Design document: docs/PANORAMA-IOS-DESIGN.md §7 (accessibility and
//  system integration: "RTL: progress t and the snap direction are computed from
//  the reading direction") and §4 (geometry and core math: the section step
//  `itemWidth = screenWidth − peek`, not the screen width).
//
//  Checked: normalizing progress and indexes via `TesseraRTL` in LTR and
//  RTL for `itemWidth ≠ screenWidth`; mirroring of physical slots and
//  insets; reversibility of `readingProgress ↔ rawOffset`; edge cases
//  (a single section, an empty strip).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoRTLTests: XCTestCase {

    private let ltr = UIUserInterfaceLayoutDirection.leftToRight
    private let rtl = UIUserInterfaceLayoutDirection.rightToLeft

    /// §4: the screen width and peek from which the section step is derived.
    private let screenWidth: CGFloat = 390
    private let peek: CGFloat = 48
    private let pageCount = 4

    /// The section step `itemWidth = screenWidth − peek = 342` is deliberately not 390:
    /// the RTL tests must catch the step being replaced by the screen width.
    private var itemWidth: CGFloat { screenWidth - peek }

    /// The strip's upper bound: `(pageCount − 1) × itemWidth`.
    private var maxOffset: CGFloat { CGFloat(pageCount - 1) * itemWidth }

    // MARK: - Helpers

    /// A scroll view with a forced reading direction: the simulator's system
    /// language must not affect the checks (§7).
    private func makeScrollView(
        sectionCount: Int? = nil,
        direction: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> TesseraPanoScrollView {
        let scrollView = TesseraPanoScrollView(peek: peek)
        scrollView.frame = CGRect(
            x: 0,
            y: 0,
            width: screenWidth,
            height: 700
        )
        scrollView.semanticContentAttribute = direction == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        scrollView.sectionCount = sectionCount ?? pageCount
        scrollView.contentSize = scrollView.requiredContentSize
        return scrollView
    }

    /// The expected progress in reading order for a raw offset, using the same Core
    /// contract that the panorama applies (§7).
    private func expectedReadingProgress(
        rawOffset: CGFloat,
        direction: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        TesseraRTL.normalizedProgress(
            rawOffset / itemWidth,
            pageCount: pageCount,
            layoutDirection: direction
        )
    }

    // MARK: - Layout direction

    /// `resolvedLayoutDirection` follows `semanticContentAttribute`: all
    /// further RTL checks rely on this.
    func testResolvedLayoutDirectionFollowsSemanticAttribute() {
        XCTAssertEqual(
            makeScrollView(direction: .leftToRight).resolvedLayoutDirection,
            .leftToRight
        )
        XCTAssertEqual(
            makeScrollView(direction: .rightToLeft).resolvedLayoutDirection,
            .rightToLeft
        )
    }

    // MARK: - The section step is not the screen width (§4)

    /// In both directions `itemWidth = 342` and `contentSize = 4 × 342 + 48`:
    /// peek is subtracted the same way, and the reading direction changes only the slots.
    func testItemWidthIsScreenWidthMinusPeekInBothDirections() {
        for direction in [ltr, rtl] {
            let scrollView = makeScrollView(direction: direction)

            XCTAssertEqual(
                scrollView.itemWidth,
                itemWidth,
                accuracy: 0.000_001,
                "direction \(direction): section step"
            )
            XCTAssertNotEqual(
                scrollView.itemWidth,
                screenWidth,
                "peek must reduce the step relative to the screen (§4)"
            )
            XCTAssertEqual(
                scrollView.contentSize.width,
                CGFloat(pageCount) * itemWidth + peek,
                accuracy: 0.000_001,
                "direction \(direction): contentSize"
            )
            XCTAssertEqual(
                scrollView.maximumOffsetX,
                maxOffset,
                accuracy: 0.000_001,
                "direction \(direction): strip bound"
            )
        }
    }

    // MARK: - LTR: slots, progress, and indexes

    /// LTR: the slot matches the reading index, the alignment is `index × itemWidth`,
    /// and the section frame is the same coordinate with a width of 342 (§4).
    func testLTRAlignmentStepsByItemWidth() {
        let scrollView = makeScrollView(direction: .leftToRight)

        for index in 0..<pageCount {
            XCTAssertEqual(scrollView.physicalSlot(forReadingIndex: index), index)
            XCTAssertEqual(
                scrollView.alignmentOffset(forReadingIndex: index),
                CGFloat(index) * itemWidth,
                accuracy: 0.000_001,
                "LTR: section offset \(index)"
            )

            let rect = scrollView.rect(forReadingIndex: index)
            XCTAssertEqual(
                rect.minX,
                CGFloat(index) * itemWidth,
                accuracy: 0.000_001,
                "LTR: section x \(index)"
            )
            XCTAssertEqual(rect.width, itemWidth, accuracy: 0.000_001)
        }
    }

    /// LTR: `t = offset / itemWidth` with no mirroring; the integer part is the index,
    /// the fractional part is the transition progress (§4).
    func testLTRReadingProgressUsesItemWidth() {
        let scrollView = makeScrollView(direction: .leftToRight)

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (171, 0.5),
            (342, 1),
            (513, 1.5),
            (684, 2),
            (1_026, 3),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: entry.raw),
                entry.expected,
                accuracy: 0.000_001,
                "LTR progress for raw \(entry.raw)"
            )
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: entry.raw),
                expectedReadingProgress(rawOffset: entry.raw, direction: ltr),
                accuracy: 0.000_001,
                "the panorama must match TesseraRTL in LTR"
            )
        }

        // The raw `currentProgress()` is the physical `t`; in LTR it is also the one in
        // reading order (§4).
        scrollView.contentOffset = CGPoint(x: 342, y: 0)
        XCTAssertEqual(scrollView.currentProgress(), 1, accuracy: 0.000_001)
    }

    /// LTR: the index is the rounded physical slot with a clamp; at the 0.5 boundary
    /// rounding goes up (the standard Swift rule, §4).
    func testLTRReadingIndexRoundsToNearestSlot() {
        let scrollView = makeScrollView(direction: .leftToRight)

        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 0),
            (170, 0),
            (171, 1),
            (342, 1),
            (513, 2),
            (683, 2),
            (684, 2),
            (855, 3),
            (1_026, 3),
            (1_200, 3),
            (-100, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingIndex(forRawOffset: entry.raw),
                entry.expected,
                "LTR index for raw \(entry.raw)"
            )
        }
    }

    // MARK: - RTL: mirrored slots (§7)

    /// RTL: reading section `0` lives in the rightmost physical slot
    /// (`pageCount − 1 − index`), while the alignment remains `slot × itemWidth`.
    func testRTLPhysicalSlotsAreMirrored() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        for index in 0..<pageCount {
            let slot = pageCount - 1 - index

            XCTAssertEqual(
                scrollView.physicalSlot(forReadingIndex: index),
                slot,
                "RTL: physical slot of reading section \(index)"
            )
            XCTAssertEqual(
                scrollView.alignmentOffset(forReadingIndex: index),
                CGFloat(slot) * itemWidth,
                accuracy: 0.000_001,
                "RTL: offset of reading section \(index)"
            )
            XCTAssertEqual(
                scrollView.alignmentOffset(forReadingIndex: index),
                scrollView.maximumOffsetX - CGFloat(index) * itemWidth,
                accuracy: 0.000_001,
                "RTL: the last reading section must stand at the right edge"
            )
        }
    }

    /// RTL: sections are shifted right by the `peek` band: the mirrored strip
    /// starts with a margin so that the peek is on the leading side.
    func testRTLSectionRectsAreShiftedByPeek() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        for index in 0..<pageCount {
            let slot = pageCount - 1 - index
            let rect = scrollView.rect(forReadingIndex: index)

            XCTAssertEqual(
                rect.minX,
                peek + CGFloat(slot) * itemWidth,
                accuracy: 0.000_001,
                "RTL: x of reading section \(index)"
            )
            XCTAssertEqual(rect.width, itemWidth, accuracy: 0.000_001)
            XCTAssertEqual(rect.height, scrollView.bounds.height, accuracy: 0.000_001)
        }

        // The rightmost reading section 0 abuts the end of contentSize.
        XCTAssertEqual(
            scrollView.rect(forReadingIndex: 0).maxX,
            scrollView.contentSize.width,
            accuracy: 0.000_001
        )
    }

    // MARK: - RTL: progress and indexes via TesseraRTL (§7)

    /// RTL: the raw progress is mirrored as `(pageCount − 1) − t`; the values
    /// match a direct call to `TesseraRTL.normalizedProgress` (the panorama does not
    /// duplicate the mirroring).
    func testRTLReadingProgressMirrorsRawOffset() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 3),
            (171, 2.5),
            (342, 2),
            (513, 1.5),
            (684, 1),
            (1_026, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: entry.raw),
                entry.expected,
                accuracy: 0.000_001,
                "RTL progress for raw \(entry.raw)"
            )
        }

        // Bounce: RTL normalization does not clamp, per the §4 contract: "the consumer
        // decides how to limit it".
        for raw: CGFloat in [-100, 1_200] {
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: raw),
                expectedReadingProgress(rawOffset: raw, direction: rtl),
                accuracy: 0.000_001,
                "RTL progress on bounce for raw \(raw)"
            )
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: raw),
                CGFloat(pageCount - 1) - raw / itemWidth,
                accuracy: 0.000_001
            )
        }
    }

    /// RTL: the index is computed from the physical slot (rounding + clamp) and then
    /// mirrored into reading order; this is the `TesseraRTL.pageIndex` rule (§7).
    func testRTLReadingIndexMirrorsPhysicalSlot() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        let cases: [(raw: CGFloat, expected: Int)] = [
            (0, 3),
            (170, 3),
            (171, 2),
            (342, 2),
            (513, 1),
            (683, 1),
            (684, 1),
            (855, 0),
            (1_026, 0),
            (1_200, 0),
            (-100, 3),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.readingIndex(forRawOffset: entry.raw),
                entry.expected,
                "RTL index for raw \(entry.raw)"
            )
        }
    }

    /// `rawOffset(forReadingProgress:)` is the inverse of `readingProgress(forRawOffset:)`
    /// over the RTL range and is clamped at the strip's boundaries (§8).
    func testRTLRawOffsetRoundTripsReadingProgress() {
        let scrollView = makeScrollView(direction: .rightToLeft)

        var progress: CGFloat = 0
        while progress <= 3 {
            let raw = scrollView.rawOffset(forReadingProgress: progress)
            XCTAssertEqual(
                scrollView.readingProgress(forRawOffset: raw),
                progress,
                accuracy: 0.000_001,
                "round-trip of progress \(progress) via raw \(raw)"
            )
            progress += 0.25
        }

        let cases: [(progress: CGFloat, expected: CGFloat)] = [
            (0, maxOffset),
            (1.5, 513),
            (3, 0),
            (-1, maxOffset),
            (10, 0),
        ]

        for entry in cases {
            XCTAssertEqual(
                scrollView.rawOffset(forReadingProgress: entry.progress),
                entry.expected,
                accuracy: 0.000_001,
                "RTL raw offset for progress \(entry.progress)"
            )
        }
    }

    /// A mirroring property: for the same physical offset
    /// the LTR and RTL progresses add up to `pageCount − 1`.
    func testLTRAndRTLProgressSumToPageCountMinusOne() {
        let ltrScrollView = makeScrollView(direction: .leftToRight)
        let rtlScrollView = makeScrollView(direction: .rightToLeft)

        for raw: CGFloat in [0, 100, 171, 342, 513, 684, 855, 1_026, -100, 1_200] {
            let ltrProgress = ltrScrollView.readingProgress(forRawOffset: raw)
            let rtlProgress = rtlScrollView.readingProgress(forRawOffset: raw)

            XCTAssertEqual(
                ltrProgress + rtlProgress,
                CGFloat(pageCount - 1),
                accuracy: 0.000_001,
                "sum of LTR/RTL progress for raw \(raw)"
            )
        }
    }

    // MARK: - A single section and an empty strip (§8)

    /// A single section in RTL: peek is not subtracted, the strip is the viewport, and the progress and
    /// index are always 0, the section frame is the whole canvas.
    func testRTLSingleSectionUsesFullWidth() {
        let scrollView = makeScrollView(sectionCount: 1, direction: .rightToLeft)

        XCTAssertEqual(scrollView.itemWidth, screenWidth, accuracy: 0.000_001)
        XCTAssertEqual(
            scrollView.contentSize.width,
            screenWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(scrollView.alignmentOffset(forReadingIndex: 0), 0)
        XCTAssertEqual(scrollView.readingProgress(forRawOffset: 0), 0)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: 500), 0)
        XCTAssertEqual(scrollView.physicalSlot(forReadingIndex: 0), 0)

        let rect = scrollView.rect(forReadingIndex: 0)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: scrollView.bounds.size))
    }

    /// An empty strip: there is no geometry, but progress and index do not crash (§8).
    func testEmptyPanoramaHasNoGeometry() {
        let scrollView = makeScrollView(sectionCount: 0, direction: .rightToLeft)

        XCTAssertEqual(scrollView.contentSize, .zero)
        XCTAssertEqual(scrollView.alignmentOffset(forReadingIndex: 0), 0)
        XCTAssertEqual(scrollView.readingProgress(forRawOffset: 300), 0)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: 300), 0)
        XCTAssertEqual(scrollView.rect(forReadingIndex: 0), .zero)
    }
}

#endif
