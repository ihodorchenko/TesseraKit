//
//  PivotHeaderStripViewTests.swift
//  TesseraPivotTests
//
//  Contract tests for the pivot header strip.
//  Design document: docs/PIVOT-IOS-DESIGN.md §3 (architecture: strip modes:
//  content width and equal widths), §4 (core math: selection is the
//  section nearest to the progress), §5 (strip and pager synchronization: the strip is
//  a reader only: `onSelect` reports an intent but moves nothing),
//  §7 (performance: only the indicator's `transform` is on the hot path,
//  with no layout and no write to `contentOffset`), §8 (accessibility: a minimum of
//  44 pt per tappable header button).
//
//  The strip's public surface has no pure functions for choosing the mode/order
//  (that is the private `effectiveMode` geometry), so the modes are checked through
//  the public layout delegate, without a UI run loop and without a window.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraPivot

final class PivotHeaderStripViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeStrip(
        width: CGFloat = 320,
        height: CGFloat = 48,
        titles: [String] = []
    ) -> TesseraPivotHeaderStripView {
        let strip = TesseraPivotHeaderStripView(
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
        strip.titles = titles
        return strip
    }

    private func collectionView(
        of strip: TesseraPivotHeaderStripView
    ) throws -> UICollectionView {
        try XCTUnwrap(
            strip.subviews.compactMap { $0 as? UICollectionView }.first,
            "The strip must contain a UICollectionView of headers"
        )
    }

    /// The cell width from the public layout delegate (without a window or a UI run loop).
    private func itemWidth(
        of strip: TesseraPivotHeaderStripView,
        at index: Int
    ) throws -> CGFloat {
        let collectionView = try collectionView(of: strip)
        let layout = try XCTUnwrap(
            collectionView.collectionViewLayout as? UICollectionViewFlowLayout
        )
        return strip.collectionView(
            collectionView,
            layout: layout,
            sizeForItemAt: IndexPath(item: index, section: 0)
        ).width
    }

    // MARK: - Configuration

    /// Strip defaults: an empty set, content-width mode, an indicator hidden until
    /// layout, insets, and the minimum cell width (§3, §8).
    func testDefaultConfiguration() {
        let strip = TesseraPivotHeaderStripView(frame: .zero)

        XCTAssertTrue(strip.titles.isEmpty)
        if case .content = strip.mode {
            // The expected default mode (§3).
        } else {
            XCTFail("By default the strip must be in .content mode")
        }
        XCTAssertEqual(strip.selectedIndex, 0)
        XCTAssertTrue(strip.showsIndicator)
        XCTAssertEqual(strip.highlightSpan, 1)
        XCTAssertEqual(strip.horizontalInset, 16)
        XCTAssertEqual(strip.interItemSpacing, 20)
        XCTAssertEqual(strip.horizontalTextPadding, 8)
        XCTAssertEqual(strip.minimumItemWidth, 44)
        XCTAssertTrue(strip.indicator.isHidden)
        XCTAssertNil(strip.onSelect)
    }

    /// An empty strip is a valid state (§9, single section / empty): progress,
    /// selection, and auto-centering do not crash and create no headers.
    func testEmptyTitlesStaySafe() {
        let strip = makeStrip()

        strip.apply(progress: 3.5)
        XCTAssertEqual(strip.selectedIndex, 0)

        strip.select(index: 4)
        XCTAssertEqual(strip.selectedIndex, 0)

        strip.scrollToCenter(index: 2, animated: true)
        strip.scrollToCenter(index: -1, animated: false)

        XCTAssertTrue(strip.titles.isEmpty)
        XCTAssertTrue(strip.indicator.isHidden)
    }

    // MARK: - Selection by progress (§4)

    /// The "active" section is the one nearest to the progress: up to 0.5 it is the current one, from 0.5
    /// the next one (§4).
    func testApplyProgressSelectsNearestSection() {
        let strip = makeStrip(titles: ["One", "Two", "Three", "Four", "Five"])

        let cases: [(progress: CGFloat, expected: Int)] = [
            (0, 0),
            (0.49, 0),
            (0.5, 1),
            (1, 1),
            (1.49, 1),
            (1.5, 2),
            (2.5, 3),
            (4, 4),
        ]

        for entry in cases {
            strip.apply(progress: entry.progress)
            XCTAssertEqual(
                strip.selectedIndex,
                entry.expected,
                "t=\(entry.progress) must select section \(entry.expected)"
            )
        }
    }

    /// Progress out of range (bounce) and `NaN` are clamped to the edge
    /// sections: the strip does not "hang" outside the set (§4).
    func testApplyProgressClampsOutOfRangeValues() {
        let strip = makeStrip(titles: ["One", "Two", "Three", "Four"])

        strip.apply(progress: -5)
        XCTAssertEqual(strip.selectedIndex, 0)

        strip.apply(progress: 99)
        XCTAssertEqual(strip.selectedIndex, 3)

        strip.apply(progress: .nan)
        XCTAssertEqual(strip.selectedIndex, 0)
    }

    /// `select(index:)` is `apply(progress:)` with an integer `t`: the index is clamped,
    /// and `onSelect` is not called (a programmatic selection is not a user tap).
    func testSelectIndexClampsAndDoesNotNotifySelection() {
        let strip = makeStrip(titles: ["One", "Two", "Three"])
        var selections: [Int] = []
        strip.onSelect = { selections.append($0) }

        strip.select(index: 2)
        XCTAssertEqual(strip.selectedIndex, 2)

        strip.select(index: 99)
        XCTAssertEqual(strip.selectedIndex, 2)
        XCTAssertEqual(strip.selectedIndex, strip.titles.count - 1)

        strip.select(index: -10)
        XCTAssertEqual(strip.selectedIndex, 0)

        XCTAssertTrue(selections.isEmpty, "a programmatic select must not call onSelect")
    }

    /// Changing the set of headers clamps the stored progress to the new range:
    /// after sections are removed the strip does not point to a nonexistent header.
    func testTitlesUpdateClampsSelectionToNewRange() {
        let strip = makeStrip(titles: ["0", "1", "2", "3", "4"])

        strip.apply(progress: 4)
        XCTAssertEqual(strip.selectedIndex, 4)

        strip.titles = ["A", "B"]
        XCTAssertEqual(strip.selectedIndex, 1)
        XCTAssertEqual(strip.titles, ["A", "B"])

        strip.titles = ["A"]
        XCTAssertEqual(strip.selectedIndex, 0)
    }

    /// A tap on a header is only `onSelect` with the index in reading order;
    /// the strip does not change the selection or move the pager itself (§5).
    func testTapReportsSelectionWithoutChangingState() throws {
        let strip = makeStrip(titles: ["One", "Two", "Three"])
        var selections: [Int] = []
        strip.onSelect = { selections.append($0) }

        let collectionView = try collectionView(of: strip)
        strip.collectionView(
            collectionView,
            didSelectItemAt: IndexPath(item: 2, section: 0)
        )

        XCTAssertEqual(selections, [2])
        XCTAssertEqual(strip.selectedIndex, 0, "a tap must not change the selection directly")
    }

    // MARK: - Width modes (§3)

    /// `.content`: the cell width follows the text, so headers of different length
    /// get different widths, and short ones hit the 44 pt minimum (§3, §8).
    func testContentModeSizesFollowText() throws {
        let strip = makeStrip(
            titles: ["A", "A long section title", "BB"]
        )

        let widths = try (0..<strip.titles.count).map { try itemWidth(of: strip, at: $0) }

        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThan(Set(widths.map { Int($0.rounded()) }).count, 1)
        for width in widths {
            XCTAssertGreaterThanOrEqual(
                width,
                strip.minimumItemWidth - 0.000_001,
                "a cell narrower than \(strip.minimumItemWidth) pt stops being a tappable button"
            )
        }
    }

    /// `.fill`: headers share the strip's width equally, and gaps are subtracted before
    /// the division (§3).
    func testFillModeSplitsWidthEqually() throws {
        let strip = makeStrip(
            width: 320,
            titles: ["One", "Two", "Three"]
        )
        strip.mode = .fill

        let expected = (320 - strip.interItemSpacing * 2) / 3
        let widths = try (0..<3).map { try itemWidth(of: strip, at: $0) }

        for width in widths {
            XCTAssertEqual(width, expected, accuracy: 0.000_001)
        }
    }

    /// Equal cells that are too narrow are not buttons: `.fill` yields to `.content`,
    /// and the width returns to the text with a minimum (§8, Dynamic Type).
    func testFillModeFallsBackWhenCellsWouldBeTooNarrow() throws {
        let strip = makeStrip(
            width: 90,
            titles: ["One", "Two", "Three", "Four"]
        )
        strip.mode = .fill

        // (90 - 20 * 3) / 4 = 7.5 pt: unreadable and not tappable.
        let widths = try (0..<4).map { try itemWidth(of: strip, at: $0) }

        for width in widths {
            XCTAssertGreaterThanOrEqual(
                width,
                strip.minimumItemWidth - 0.000_001,
                "on a narrow strip the .fill mode must fall back to .content (§8)"
            )
        }
    }

    // MARK: - Indicator: view and hot path (§4, §7)

    /// The active header's color from the style reaches the underline indicator.
    func testActiveColorPropagatesToIndicator() {
        let strip = makeStrip(titles: ["One", "Two"])

        strip.activeColor = .systemRed

        XCTAssertEqual(strip.indicator.activeColor, .systemRed)
        XCTAssertEqual(strip.indicator.backgroundColor, .systemRed)
    }

    /// After a layout pass the indicator is shown and pinned to the strip's bottom edge.
    func testLayoutPlacesAndShowsIndicator() {
        let strip = makeStrip(titles: ["One", "Two", "Three"])

        strip.layoutSubviews()

        XCTAssertFalse(strip.indicator.isHidden)
        XCTAssertEqual(strip.indicator.center.y, strip.bounds.maxY - 1.5, accuracy: 0.000_001)

        strip.showsIndicator = false
        XCTAssertTrue(strip.indicator.isHidden)

        strip.showsIndicator = true
        strip.layoutSubviews()
        XCTAssertFalse(strip.indicator.isHidden)
    }

    /// The swipe hot path: `apply(progress:)` moves only the indicator's `transform`:
    /// `bounds`/`center` do not change, the collection does not scroll, and
    /// `contentOffset` is not written (§4, §5, §7).
    func testApplyProgressMovesIndicatorOnlyByTransform() throws {
        let strip = makeStrip(
            width: 640,
            titles: ["One", "Two", "Three", "Four"]
        )
        strip.layoutSubviews()

        let indicator = strip.indicator
        let collectionView = try collectionView(of: strip)
        let boundsBefore = indicator.bounds
        let centerBefore = indicator.center

        strip.apply(progress: 0)
        let firstPosition = indicator.center.x + indicator.transform.tx

        strip.apply(progress: 1)
        let secondPosition = indicator.center.x + indicator.transform.tx

        XCTAssertEqual(indicator.bounds, boundsBefore)
        XCTAssertEqual(indicator.center, centerBefore)
        XCTAssertNotEqual(secondPosition, firstPosition)
        XCTAssertEqual(collectionView.contentOffset.x, 0, accuracy: 0.000_001)
    }
}

#endif
