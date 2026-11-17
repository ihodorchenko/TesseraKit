//
//  PanoramaControllerCoverageTests.swift
//  TesseraPanoramaTests
//
//  Coverage of `TesseraPanoramaViewController` behavior on live
//  UIView/UIWindow.
//  Design document: docs/PANORAMA-IOS-DESIGN.md: §5 (vertical scroll
//  inside a section: variant B: horizontal goes to the panorama, vertical to the child),
//  §6 (performance: lazy loading with a ±1 window, prefetch before snapping),
//  §4 (geometry and core math: the single scalar t, the delegate) and
//  docs/CORE-IOS-DESIGN.md §2 (key contracts: arbitration, a single writer of
//  contentOffset).
//
//  What is checked:
//  - (a) lazy loading: only the current section and its ±1 neighbors are in memory, and
//    as child controllers; leaving the window unloads and detaches;
//  - (b) prefetch: the snap target and its neighbor are loaded in
//    `scrollViewWillEndDragging`, that is, before snapping starts and before `didShowSectionAt`;
//    the visible section is not unloaded meanwhile;
//  - (c) `reload(sections:)`: the current section is kept by `id`, the loaded
//    window is reused, and controllers of surviving `id`s are not recreated;
//  - (d) the delegate: `didShowSectionAt` is called exactly once per real change, with no
//    intermediate swipe frames; `didChangeProgress` is consistent with the offset;
//  - (e) variant B arbitration: horizontal belongs to the panorama, vertical to the
//    section's real `UIScrollView`; the public contract
//    `registerVerticalOwner(_:)` + `TesseraGestureArbiter` is checked (the pure decision by
//    axis and blocking of children for the duration of a horizontal gesture). The panorama's private
//    `.began` point is not accessible to tests.
//
//  Determinism: progress/show are synchronized by calling the scroll view's public
//  delegates (as in PanoramaControllerReviewTests), without sleep; waiting on the run loop
//  is not required. The end of the `setContentOffset(_:animated:)` animation does not occur in a
//  test process without a display, so it is emulated by setting the offset and
//  calling `scrollViewDidEndScrollingAnimation`, as in the existing tests.
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

// MARK: - Delegate spy

/// The panorama delegate spy: shows, progress, and snapshots of the loaded window.
private final class PanoramaCoverageSpy: TesseraPanoramaDelegate {
    /// The `didShowSectionAt` indexes in order of arrival.
    private(set) var shown: [Int] = []
    /// The `didChangeProgress` values.
    private(set) var progress: [CGFloat] = []
    /// The raw `contentOffset.x` at the moment of each `didChangeProgress`.
    private(set) var progressRawOffsets: [CGFloat] = []
    /// The loaded sections at the moment of each `didShowSectionAt`.
    private(set) var loadedAtShow: [Set<Int>] = []

    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int) {
        shown.append(index)
        loadedAtShow.append(Set(panorama.loadedSections.keys))
    }

    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat) {
        progress.append(t)
        progressRawOffsets.append(panorama.scrollView.contentOffset.x)
    }
}

// MARK: - Section content with a real vertical scroll

/// A section with a real vertical `UIScrollView` inside: the variant B scenario.
private final class VerticalSectionContentController: UIViewController {
    /// The content's vertical scroll view: registered with the panorama as an owner.
    let scrollView = UIScrollView()

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Fixed tall content: the size does not depend on when
        // UIKit sets the view's frame (test determinism).
        scrollView.contentSize = CGSize(width: 1_000, height: 3_000)
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
    }
}

final class PanoramaControllerCoverageTests: XCTestCase {

    private var window: UIWindow?

    /// A 390×700 window: at peek 48 the section step is 342 pt.
    private let screen = CGSize(width: 390, height: 700)
    private let itemWidth: CGFloat = 342

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Sections with factories that record controller creation.
    private func makeSections(
        count: Int,
        ids: [Int]? = nil,
        onMake: ((Int) -> Void)? = nil
    ) -> [TesseraPanoramaSection] {
        let identifiers = ids ?? Array(0..<count)
        return identifiers.map { id in
            TesseraPanoramaSection(id: id, title: "Section \(id)") {
                onMake?(id)
                return UIViewController()
            }
        }
    }

    /// Sections whose content contains a real vertical scroll.
    private func makeVerticalSections(count: Int) -> [TesseraPanoramaSection] {
        (0..<count).map { index in
            TesseraPanoramaSection(id: index, title: "Section \(index)") {
                VerticalSectionContentController()
            }
        }
    }

    /// The panorama in a real window: appearance and layout as in an app.
    private func makeWindowedPanorama(
        sections: [TesseraPanoramaSection],
        size: CGSize? = nil
    ) -> TesseraPanoramaViewController {
        let panorama = TesseraPanoramaViewController(sections: sections)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size ?? screen))
        window.rootViewController = panorama
        window.isHidden = false
        self.window = window
        panorama.view.frame = window.bounds
        panorama.view.layoutIfNeeded()
        return panorama
    }

    private func loadedIndices(_ panorama: TesseraPanoramaViewController) -> Set<Int> {
        Set(panorama.loadedSections.keys)
    }

    /// Drives a started snap animation/inertia to its target: the offset to the target and
    /// a synthetic end of the animation. If UIKit already completed the transition itself,
    /// the repeated `didShowSectionAt` is suppressed by the controller (lastShown), so
    /// the call is idempotent.
    private func completeTransitionIfNeeded(
        _ panorama: TesseraPanoramaViewController,
        to targetX: CGFloat
    ) {
        let scrollView = panorama.scrollView
        if abs(scrollView.contentOffset.x - targetX) > 0.001 {
            scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        }
        scrollView.scrollViewDidEndScrollingAnimation(scrollView)
    }

    /// Each `didChangeProgress` value is exactly the progress of the offset
    /// captured at the moment of the callback (the "single scalar t" invariant).
    private func assertProgressMatchesOffsets(
        _ spy: PanoramaCoverageSpy,
        _ panorama: TesseraPanoramaViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            spy.progress.count,
            spy.progressRawOffsets.count,
            "the number of progress callbacks and offset snapshots did not match",
            file: file,
            line: line
        )
        for (t, rawOffset) in zip(spy.progress, spy.progressRawOffsets) {
            XCTAssertEqual(
                t,
                panorama.scrollView.readingProgress(forRawOffset: rawOffset),
                accuracy: 0.000_001,
                "t=\(t) does not match offset=\(rawOffset)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - (a) Lazy loading with a ±1 window

    /// Showing 5 sections: child controllers only for the current section and its ±1 neighbors;
    /// the window's sections are not only created but also attached as children.
    func testLazyWindowLoadsOnlyCurrentAndNeighbourSections() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 0)
        XCTAssertEqual(loadedIndices(panorama), [0, 1], "only the current section and its neighbor must be in memory")
        XCTAssertEqual(panorama.children.count, 2, "there must be no child controllers outside the window")
        XCTAssertEqual(made.sorted(), [0, 1], "section factories outside the window must not be called")

        let first = try XCTUnwrap(panorama.loadedSections[0])
        let second = try XCTUnwrap(panorama.loadedSections[1])
        XCTAssertTrue(first.parent === panorama)
        XCTAssertTrue(second.parent === panorama)
        XCTAssertTrue(first.view.superview === panorama.scrollView)
        XCTAssertEqual(first.view.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(
            second.view.frame.minX,
            panorama.scrollView.alignmentOffset(forReadingIndex: 1),
            accuracy: 0.001
        )

        // Going to the middle section: the window moves, the departed one is unloaded.
        panorama.selectSection(at: 2, animated: false)

        XCTAssertEqual(panorama.currentSectionIndex, 2)
        XCTAssertEqual(loadedIndices(panorama), [1, 2, 3])
        XCTAssertEqual(panorama.children.count, 3)
        XCTAssertNil(first.parent, "a section outside the window must be unloaded")
        XCTAssertNil(panorama.loadedSections[0])
        XCTAssertFalse(panorama.children.contains { $0 === first })
        XCTAssertEqual(made.sorted(), [0, 1, 2, 3])

        // The strip's edge: the window is clamped, there are no extra neighbors.
        panorama.selectSection(at: 4, animated: false)

        XCTAssertEqual(loadedIndices(panorama), [3, 4])
        XCTAssertEqual(panorama.children.count, 2)
        XCTAssertEqual(panorama.currentSectionIndex, 4)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, panorama.scrollView.alignmentOffset(forReadingIndex: 4), accuracy: 0.5)
    }

    /// Unloaded sections are released: the controller's weak/strong references to
    /// them do not stop the window from moving (reloading yields a new instance).
    func testUnloadedSectionsAreRecreatedOnReturn() throws {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 4))
        let first = try XCTUnwrap(panorama.loadedSections[0])

        panorama.selectSection(at: 3, animated: false)
        XCTAssertNil(first.parent)
        XCTAssertNil(panorama.loadedSections[0])

        panorama.selectSection(at: 0, animated: false)
        let returned = try XCTUnwrap(panorama.loadedSections[0])
        XCTAssertFalse(returned === first, "an unloaded section must be created anew")
        XCTAssertTrue(returned.parent === panorama)
        XCTAssertEqual(loadedIndices(panorama), [0, 1])
    }

    // MARK: - (b) Prefetch before snapping

    /// A fast swipe: the snap target is known in `scrollViewWillEndDragging`, and its
    /// window is loaded **before** snapping and before `didShowSectionAt`, while the visible section
    /// stays in memory (otherwise the frame would have an empty slot).
    func testPrefetchLoadsSnapTargetBeforeDeceleration() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5) { made.append($0) })
        panorama.selectSection(at: 1, animated: false) // window {0, 1, 2}
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView
        let visible = [
            0: try XCTUnwrap(panorama.loadedSections[0]),
            1: try XCTUnwrap(panorama.loadedSections[1]),
            2: try XCTUnwrap(panorama.loadedSections[2]),
        ]

        // Reference points are taken from the scroll view's actual geometry (the snap policy
        // returns the section alignment), not from a literal: `contentOffset`
        // may align to the device pixel.
        let startOffsetX = scrollView.contentOffset.x
        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: startOffsetX + itemWidth * 0.4, y: 0)
        let draggedOffsetX = scrollView.contentOffset.x
        var target = scrollView.contentOffset
        // 2 pt/ms = 2000 pt/s > the 600 threshold -> a +1 step from starting section 1.
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 2.0, y: 0),
            targetContentOffset: &target
        )

        XCTAssertEqual(
            target.x,
            scrollView.alignmentOffset(forReadingIndex: 2),
            accuracy: 0.5,
            "the snap target is section 2"
        )
        XCTAssertEqual(
            scrollView.contentOffset.x,
            draggedOffsetX,
            accuracy: 0.5,
            "prefetch runs before snapping starts: the offset is still under the finger"
        )
        XCTAssertGreaterThan(
            abs(scrollView.contentOffset.x - target.x),
            1,
            "the offset must not jump to the target before snapping"
        )
        XCTAssertTrue(spy.shown.isEmpty, "didShowSectionAt must not fire before the transition completes")
        XCTAssertEqual(
            loadedIndices(panorama),
            [0, 1, 2, 3],
            "prefetch must load the snap target and its neighbor without unloading the current section"
        )
        XCTAssertTrue(panorama.loadedSections[0] === visible[0], "prefetch must not unload the visible section")
        XCTAssertTrue(panorama.loadedSections[1] === visible[1])
        XCTAssertTrue(panorama.loadedSections[2] === visible[2])
        XCTAssertNotNil(panorama.loadedSections[3])
        XCTAssertEqual(made.sorted(), [0, 1, 2, 3])

        // Inertia ended at the target: the window moves, and there is one show.
        scrollView.contentOffset = CGPoint(x: target.x, y: 0)
        scrollView.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(spy.shown, [2])
        XCTAssertEqual(loadedIndices(panorama), [1, 2, 3])
        XCTAssertNil(visible[0]?.parent, "a section outside the window is unloaded when the transition completes")
        XCTAssertTrue(spy.loadedAtShow.first?.isSuperset(of: [2, 3]) ?? false)
    }

    /// A reverse swipe: prefetch loads the section behind the window, symmetrically
    /// to the forward direction.
    func testPrefetchWorksBackwards() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        panorama.selectSection(at: 2, animated: false) // window {1, 2, 3}
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth * 1.7, y: 0)
        var target = scrollView.contentOffset
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: -2.0, y: 0),
            targetContentOffset: &target
        )

        XCTAssertEqual(
            target.x,
            scrollView.alignmentOffset(forReadingIndex: 1),
            accuracy: 0.5,
            "the snap target is section 1"
        )
        XCTAssertEqual(loadedIndices(panorama), [0, 1, 2, 3])
        XCTAssertTrue(spy.shown.isEmpty)

        scrollView.contentOffset = CGPoint(x: target.x, y: 0)
        scrollView.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(loadedIndices(panorama), [0, 1, 2])
    }

    // MARK: - (c) reload(sections:)

    /// A `reload` with the same `id`s: the current section, the offset, and the whole loaded window
    /// are kept, and controllers are reused (factories are not called).
    func testReloadWithSameIdentifiersReusesWindowAndCurrentSection() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 4) { made.append($0) })
        panorama.selectSection(at: 1, animated: false) // window {0, 1, 2}
        let before: [Int: UIViewController] = [
            0: try XCTUnwrap(panorama.loadedSections[0]),
            1: try XCTUnwrap(panorama.loadedSections[1]),
            2: try XCTUnwrap(panorama.loadedSections[2]),
        ]
        made.removeAll()
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy

        panorama.reload(sections: makeSections(count: 4) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 1, "the current section is kept")
        XCTAssertEqual(
            panorama.scrollView.contentOffset.x,
            panorama.scrollView.alignmentOffset(forReadingIndex: 1),
            accuracy: 0.5
        )
        XCTAssertEqual(loadedIndices(panorama), [0, 1, 2], "the loaded window is reused")
        for (index, controller) in before {
            XCTAssertTrue(
                panorama.loadedSections[index] === controller,
                "the controller of section \(index) was recreated"
            )
        }
        XCTAssertEqual(made, [], "factories of surviving ids must not be called")
        XCTAssertTrue(spy.shown.isEmpty, "a reload is not a section show")
    }

    /// A `reload` with a reorder: the current section is looked up by `id`, those that survive in
    /// the new window are reused and moved to new slots, those that left the
    /// window are unloaded, and a new one is created only for the window.
    func testReloadWithReorderKeepsCurrentByIDAndReusesSurvivors() throws {
        var made: [Int] = []
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5) { made.append($0) })
        panorama.selectSection(at: 2, animated: false) // window {1, 2, 3}
        let byID: [Int: UIViewController] = [
            1: try XCTUnwrap(panorama.loadedSections[1]),
            2: try XCTUnwrap(panorama.loadedSections[2]),
            3: try XCTUnwrap(panorama.loadedSections[3]),
        ]
        made.removeAll()

        // id 2 is current; in the new set it is index 2, with {4, 2, 1} around it;
        // id 3 falls out of the window, id 4 appears in the window.
        panorama.reload(sections: makeSections(count: 5, ids: [0, 4, 2, 1, 3]) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 2, "the current section must be kept by id")
        XCTAssertEqual(
            panorama.scrollView.contentOffset.x,
            panorama.scrollView.alignmentOffset(forReadingIndex: 2),
            accuracy: 0.5
        )
        XCTAssertEqual(loadedIndices(panorama), [1, 2, 3])
        XCTAssertTrue(panorama.loadedSections[2] === byID[2], "the current section was recreated")
        XCTAssertTrue(panorama.loadedSections[3] === byID[1], "a surviving id was recreated")
        XCTAssertEqual(
            panorama.loadedSections[3]?.view.frame.minX ?? -1,
            panorama.scrollView.alignmentOffset(forReadingIndex: 3),
            accuracy: 0.001,
            "a reused controller must move to the new slot"
        )
        XCTAssertEqual(made, [4], "only a section that was not in the window must be created")
        XCTAssertNil(byID[3]?.parent, "a section that left the window is unloaded")
        XCTAssertNil(panorama.loadedSections[4])
    }

    // MARK: - (d) Delegate: show and progress

    /// A programmatic transition: exactly one `didShowSectionAt` per real change,
    /// a repeated transition to the same section does not duplicate the event; a far
    /// instant transition gives one show and a progress jump to the target.
    func testProgrammaticTransitionReportsOneShowPerRealChange() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy

        panorama.selectSection(at: 1, animated: false)
        // The frame's hot path: UIKit in an app sends it on an offset
        // write; in the test process we duplicate the event explicitly (as in
        // PanoramaControllerReviewTests for the scroll delegates).
        panorama.scrollView.scrollViewDidScroll(panorama.scrollView)

        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(spy.progress.last ?? -1, 1, accuracy: 0.001)
        assertProgressMatchesOffsets(spy, panorama)

        // A transition "in place" is not a real change: there is no event.
        panorama.selectSection(at: 1, animated: false)
        XCTAssertEqual(spy.shown, [1], "a repeated show of the same section is a duplicate event")

        // A far instant transition: one show, and the progress is the target one at once.
        panorama.selectSection(at: 4, animated: false)
        panorama.scrollView.scrollViewDidScroll(panorama.scrollView)

        XCTAssertEqual(spy.shown, [1, 4])
        XCTAssertEqual(spy.progress.last ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(Set(panorama.loadedSections.keys), [3, 4])
        assertProgressMatchesOffsets(spy, panorama)
        XCTAssertEqual(
            spy.loadedAtShow.last,
            [3, 4],
            "by the time of the show the ±1 window must be loaded"
        )
    }

    /// An animated programmatic transition: the only show comes after
    /// the transition completes; progress does not leave the step's bounds.
    func testAnimatedProgrammaticTransitionReportsSingleShow() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        panorama.selectSection(at: 1, animated: false)
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy

        panorama.selectSection(at: 2, animated: true)
        // The snap point comes from the scroll view's actual geometry: `contentOffset` may
        // align to the device pixel.
        let snapX = panorama.scrollView.alignmentOffset(forReadingIndex: 2)
        // In the test process the animation may not advance, so we drive it
        // the way UIKit does in an app.
        completeTransitionIfNeeded(panorama, to: snapX)
        panorama.scrollView.scrollViewDidScroll(panorama.scrollView)

        XCTAssertEqual(spy.shown, [2], "no show is reported on animation frames")
        XCTAssertEqual(panorama.currentSectionIndex, 2)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, snapX, accuracy: 0.5)
        assertProgressMatchesOffsets(spy, panorama)
        for value in spy.progress {
        XCTAssertGreaterThanOrEqual(value, 1 - 0.001, "progress left the transition step: \(value)")
        XCTAssertLessThanOrEqual(value, 2 + 0.001, "progress left the transition step: \(value)")
        }
    }

    /// A swipe: intermediate frames (including ones crossing the adjacent section)
    /// give no show; exactly one `didShowSectionAt` comes after the
    /// transition completes. A gesture within the same section gives no repeated show.
    func testSwipeReportsShowOnlyAfterTransitionFinishes() {
        let panorama = makeWindowedPanorama(sections: makeSections(count: 5))
        panorama.selectSection(at: 1, animated: false)
        let spy = PanoramaCoverageSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        // A forward swipe with frames crossing section 2 and returning.
        scrollView.scrollViewWillBeginDragging(scrollView)
        for readingOffset: CGFloat in [1.3, 2.2, 1.6] {
            scrollView.contentOffset = CGPoint(x: itemWidth * readingOffset, y: 0)
            // We guarantee the event's hot path even if UIKit did not send it
            // on the programmatic offset write.
            scrollView.scrollViewDidScroll(scrollView)
        }
        XCTAssertEqual(spy.shown, [], "a show before the transition completes")
        var target = scrollView.contentOffset
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &target
        )
        let snapX = scrollView.alignmentOffset(forReadingIndex: 2)
        XCTAssertEqual(target.x, snapX, accuracy: 0.5, "snapping goes to the nearest section 2")
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        completeTransitionIfNeeded(panorama, to: snapX)

        XCTAssertEqual(spy.shown, [2], "exactly one show per real section change")
        XCTAssertEqual(panorama.currentSectionIndex, 2)
        assertProgressMatchesOffsets(spy, panorama)

        // A gesture within section 2: snapping returns to the same section, so there is no show.
        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth * 2.2, y: 0)
        scrollView.scrollViewDidScroll(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth * 1.85, y: 0)
        scrollView.scrollViewDidScroll(scrollView)
        var secondTarget = scrollView.contentOffset
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &secondTarget
        )
        XCTAssertEqual(secondTarget.x, snapX, accuracy: 0.5)
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        completeTransitionIfNeeded(panorama, to: snapX)

        XCTAssertEqual(spy.shown, [2], "a gesture within a section must not repeat the show")
        assertProgressMatchesOffsets(spy, panorama)
    }

    // MARK: - (e) Variant B arbitration

    /// Variant B on live objects: vertical goes to the section's real `UIScrollView`
    /// (its scrolling works), horizontal to the panorama (its pan is the horizontal
    /// owner of the arbiter; it has no vertical content). For the duration of a
    /// horizontal gesture the child is blocked and then restored:
    /// exactly the `TesseraGestureArbiter` contract, which the controller assembles on the pan's
    /// `.began`.
    func testVariantBHorizontalBelongsToPagerVerticalBelongsToSection() throws {
        let panorama = makeWindowedPanorama(sections: makeVerticalSections(count: 3))
        let content = try XCTUnwrap(
            panorama.loadedSections[0] as? VerticalSectionContentController,
            "section 0 must be loaded by the window"
        )
        content.view.layoutIfNeeded()
        let sectionScroll = content.scrollView
        XCTAssertTrue(sectionScroll.superview === content.view)
        XCTAssertGreaterThan(
            sectionScroll.contentSize.height,
            sectionScroll.bounds.height,
            "the section must have real vertical content"
        )

        // Public registration of the vertical owner (§5).
        panorama.registerVerticalOwner(sectionScroll)

        // Vertical is handled by the child: its offset changes, the panorama stays put.
        let panoramaOffsetBefore = panorama.scrollView.contentOffset
        sectionScroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        XCTAssertEqual(sectionScroll.contentOffset.y, 40, accuracy: 0.001)
        XCTAssertEqual(
            panorama.scrollView.contentOffset.x,
            panoramaOffsetBefore.x,
            accuracy: 0.001,
            "the section's vertical scroll must not move the panorama"
        )
        XCTAssertEqual(panorama.scrollView.contentOffset.y, 0, accuracy: 0.001)

        // Horizontal is handled by the panorama: the scroll view has no vertical
        // content, the direction is locked, and vertical bounce is off.
        XCTAssertTrue(panorama.scrollView.isDirectionalLockEnabled)
        XCTAssertFalse(panorama.scrollView.alwaysBounceVertical)
        XCTAssertEqual(
            panorama.scrollView.contentSize.height,
            panorama.scrollView.bounds.height,
            accuracy: 0.001,
            "the panorama's horizontal scroll view must have no vertical content"
        )

        // The decision by dominant axis is the same pure function that the controller
        // applies on the pan's first callback (`.began`).
        XCTAssertEqual(
            TesseraGestureArbiter.axisDecision(forVelocity: CGPoint(x: 12, y: 2)),
            .horizontal,
            "a horizontal gesture must go to the panorama"
        )
        XCTAssertEqual(
            TesseraGestureArbiter.axisDecision(forVelocity: CGPoint(x: 2, y: 12)),
            .vertical,
            "a vertical gesture must go to the section"
        )

        // The arbiter with live objects: the panorama's pan is the horizontal owner
        // (without direction data the gesture stays with it), children are blocked for
        // the duration of the horizontal gesture and restored afterwards.
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: panorama.scrollView,
            verticalOwners: [sectionScroll]
        )
        XCTAssertTrue(arbiter.shouldBegin(panorama.scrollView.panGestureRecognizer))
        XCTAssertTrue(arbiter.gestureRecognizerShouldBegin(panorama.scrollView.panGestureRecognizer))

        XCTAssertTrue(sectionScroll.isScrollEnabled)
        arbiter.prepareForHorizontalScroll()
        XCTAssertFalse(
            sectionScroll.isScrollEnabled,
            "during a horizontal gesture the section's vertical scroll is blocked"
        )
        XCTAssertTrue(
            panorama.scrollView.isScrollEnabled,
            "blocking children must not disable the horizontal owner itself"
        )
        arbiter.endHorizontalScroll()
        XCTAssertTrue(sectionScroll.isScrollEnabled, "the section's scroll must be restored")

        // Unregistering does not crash and does not touch the hierarchy (the references are weak).
        panorama.unregisterVerticalOwner(sectionScroll)
        XCTAssertTrue(sectionScroll.isScrollEnabled)
    }
}

#endif
