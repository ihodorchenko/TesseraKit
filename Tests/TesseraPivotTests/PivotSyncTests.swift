//
//  PivotSyncTests.swift
//  TesseraPivotTests
//
//  Contract tests for synchronizing the pivot's strip and pager.
//  Design document: docs/PIVOT-IOS-DESIGN.md §5 (strip and pager
//  synchronization: a single source of truth and a single writer of `contentOffset`:
//  swipe → strip with no write back, tap → `setContentOffset(animated:)`),
//  §4 (core math: transition completion → strip selection and auto-centering),
//  §8 (accessibility: Reduce Motion disables the transition animation,
//  the VoiceOver gesture pages through sections).
//
//  The checks go through the public API (`selectSection(at:animated:)`,
//  `accessibilityScroll`, delegate callbacks) and `@testable` access to the strip and
//  the pager; no window or UI run loop is needed: the view is loaded and
//  laid out manually, as in the Core contract tests (D10).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPivot

/// A pivot delegate spy: records the order and values of all three callbacks.
private final class PivotDelegateSpy: TesseraPivotDelegate {
    private(set) var selectedIndexes: [Int] = []
    private(set) var progressValues: [CGFloat] = []
    private(set) var shownIndexes: [Int] = []

    func pivot(_ pivot: TesseraPivotViewController, didSelectSectionAt index: Int) {
        selectedIndexes.append(index)
    }

    func pivot(_ pivot: TesseraPivotViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }

    func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int) {
        shownIndexes.append(index)
    }
}

final class PivotSyncTests: XCTestCase {

    private let pivotSize = CGSize(width: 320, height: 640)

    // MARK: - Helpers

    private func makeSections(count: Int) -> [TesseraPivotSection] {
        (0..<count).map { index in
            TesseraPivotSection(id: index, title: "Section \(index)") {
                UIViewController()
            }
        }
    }

    /// Loads the pivot, sets its size, and lays it out. Returns the pager's inner
    /// scroll view: it is the only writer of `contentOffset` (§5).
    private func makeLoadedPivot(
        sectionCount: Int = 4
    ) throws -> (pivot: TesseraPivotViewController, scrollView: UIScrollView) {
        let pivot = TesseraPivotViewController(sections: makeSections(count: sectionCount))
        pivot.loadViewIfNeeded()
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

    // MARK: - Layout and pager mode (§2, §3)

    /// The pivot uses the Core pager in `.paged` mode: snapping is provided by
    /// `isPagingEnabled`, and custom snapping is not needed (§2).
    func testPagerRunsInPagedMode() throws {
        let (pivot, scrollView) = try makeLoadedPivot()

        if case .paged = pivot.pagerViewController.mode {
            // The expected mode (docs/PIVOT-IOS-DESIGN.md §2).
        } else {
            XCTFail("The pivot must work in .paged mode")
        }

        // The pager is found by walking the hierarchy, for vertical scroll arbitration (§6).
        XCTAssertTrue(pivot.pagerScrollView === scrollView)
        XCTAssertTrue(scrollView.isPagingEnabled)
    }

    /// The strip's titles are the sections' titles in reading order (§3).
    func testStripTitlesMirrorSections() throws {
        let (pivot, _) = try makeLoadedPivot(sectionCount: 4)

        XCTAssertEqual(pivot.headerStripView.titles, pivot.sections.map(\.title))
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 0)
    }

    // MARK: - Tap → transition (§5)

    /// A programmatic transition (the same path a tap uses) immediately sets
    /// `contentOffset` to the page and updates the index and the strip's selection;
    /// the pager reports the shown section.
    func testSelectSectionWithoutAnimationJumpsAndReportsShownSection() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let spy = PivotDelegateSpy()
        pivot.delegate = spy

        let pageWidth = scrollView.bounds.width
        pivot.selectSection(at: 2, animated: false)

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 2)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 2)
        XCTAssertEqual(spy.shownIndexes, [2])
    }

    /// An out-of-range index is clamped: 99 → the last section, -5 → the first.
    func testSelectSectionClampsOutOfRangeIndexes() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let pageWidth = scrollView.bounds.width

        pivot.selectSection(at: 99, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 3)

        pivot.selectSection(at: -5, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 0)
    }

    /// A tap on a header: the strip reports an intent via `onSelect`, and the controller
    /// first notifies the delegate and only then transitions (§5). The intent, the index, and the selection
    /// are checked synchronously; with animation the transition's completion
    /// arrives as a separate callback.
    func testHeaderTapReportsSelectionAndUpdatesState() throws {
        let (pivot, _) = try makeLoadedPivot()
        let spy = PivotDelegateSpy()
        pivot.delegate = spy

        let onSelect = try XCTUnwrap(pivot.headerStripView.onSelect)
        onSelect(2)

        XCTAssertEqual(spy.selectedIndexes, [2])
        XCTAssertEqual(pivot.currentSectionIndex, 2)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 2)
    }

    /// Reduce Motion: with the system setting on, a tap transitions without
    /// animation: `contentOffset` is set at once and completion arrives
    /// synchronously (§8, "a tap jump has no animation"). With the setting
    /// off the transition is animated, so only the intent and the selection are checked
    /// synchronously: completion will come from the pager on the frames.
    func testTapTransitionHonoursReduceMotionGate() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let spy = PivotDelegateSpy()
        pivot.delegate = spy
        let pageWidth = scrollView.bounds.width
        let reduceMotion = TesseraAccessibility.isReduceMotionEnabled

        let onSelect = try XCTUnwrap(pivot.headerStripView.onSelect)
        onSelect(2)

        if reduceMotion {
            XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.5)
            XCTAssertEqual(spy.shownIndexes.last, 2)
        } else {
            XCTAssertEqual(pivot.currentSectionIndex, 2)
            XCTAssertEqual(pivot.headerStripView.selectedIndex, 2)
        }
    }

    // MARK: - Swipe → strip: no write back to contentOffset (§5)

    /// A swipe (a `contentOffset` write by the scroll view itself) updates the strip via
    /// `didChangeProgress`, but there is no write back: the offset stays exactly what
    /// the gesture set.
    func testSwipeProgressUpdatesStripWithoutWritingContentOffset() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let pageWidth = scrollView.bounds.width

        scrollView.contentOffset = CGPoint(x: pageWidth * 1.5, y: 0)

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 1.5, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 2)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 2)
    }

    /// A progress callback invoked by the pager directly is read-only:
    /// `contentOffset` does not change, and the strip's selection follows `t` (§5).
    func testProgressCallbackFromPagerIsReadOnly() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let offsetBefore = scrollView.contentOffset

        pivot.pager(pivot.pagerViewController, didChangeProgress: 1.25)

        XCTAssertEqual(scrollView.contentOffset, offsetBefore)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 1)
        XCTAssertEqual(pivot.currentSectionIndex, 1)
    }

    /// Continuous progress is forwarded to the external delegate (§3).
    func testProgressIsForwardedToExternalDelegate() throws {
        let (pivot, _) = try makeLoadedPivot()
        let spy = PivotDelegateSpy()
        pivot.delegate = spy

        pivot.pager(pivot.pagerViewController, didChangeProgress: 1.5)

        XCTAssertEqual(spy.progressValues, [1.5])
    }

    /// Transition completion selects the shown section and re-centers the strip,
    /// but does not move the pager: `contentOffset` is still written only by the pager
    /// (§4, §5).
    func testDidShowPageAtSelectsSectionWithoutMovingPager() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let spy = PivotDelegateSpy()
        pivot.delegate = spy
        let offsetBefore = scrollView.contentOffset

        pivot.pager(pivot.pagerViewController, didShowPageAt: 3)

        XCTAssertEqual(pivot.currentSectionIndex, 3)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 3)
        XCTAssertEqual(spy.shownIndexes, [3])
        XCTAssertEqual(scrollView.contentOffset, offsetBefore)
    }

    // MARK: - Accessibility (§8)

    /// The VoiceOver "forward" gesture in LTR goes to the next section, "backward" from
    /// the first section is not handled; the gesture goes through the same
    /// `selectSection(at:animated:)`, the only programmatic writer.
    func testAccessibilityScrollUsesSingleWriterInLTR() throws {
        let (pivot, _) = try makeLoadedPivot()

        // The UIKit convention: in LTR a swipe right is backward, left is forward.
        XCTAssertFalse(pivot.accessibilityScroll(.right), "There is nowhere to go back from the first section")
        XCTAssertTrue(pivot.accessibilityScroll(.left))
        XCTAssertEqual(pivot.currentSectionIndex, 1)
    }

    /// Reduce Motion is read at decision time and is not cached (§8): the component's
    /// flag is the system setting, not a stored value.
    func testReduceMotionFlagIsLive() {
        XCTAssertEqual(
            TesseraAccessibility.isReduceMotionEnabled,
            UIAccessibility.isReduceMotionEnabled
        )
    }
}

#endif
