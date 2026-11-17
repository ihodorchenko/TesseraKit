//
//  PanoramaControllerReviewTests.swift
//  TesseraPanoramaTests
//
//  Panorama controller tests from the review follow-up.
//  Design document: docs/PANORAMA-IOS-DESIGN.md: §4 (snapping),
//  §6 (lazy loading), §7 (accessibility: VoiceOver, RTL), §8
//  (adaptivity: rotation, deferred layout, navigation bar).
//
//  Each test reproduces a defect scenario:
//  - a gesture without velocity left the offset between snap points;
//  - a VoiceOver swipe from the header did not page; `contentInsetAdjustmentBehavior`
//    was not configurable through the style;
//  - deferred layout was not applied; an LTR↔RTL change opened
//    the mirrored section; a `peek` change left the section between snap points;
//    `reload` recreated surviving sections; a far `selectSection` flew through
//    empty slots; the same style was reapplied; rotation sent false progress;
//  - SwiftUI section content with the same `id`/title was not updated.
//
//  The `setContentOffset(_:animated:)` animation behaves differently in a test process without a window
//  (UIKit may complete it synchronously), so the tests
//  accept both outcomes: synchronous completion or emulating the end of the animation
//  by calling `scrollViewDidEndScrollingAnimation`.
//

#if canImport(UIKit)

import SwiftUI
import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

/// A delegate spy: section shows and progress (with the section window's state).
private final class PanoramaSpy: TesseraPanoramaDelegate {
    var shown: [Int] = []
    var progress: [CGFloat] = []
    /// The loaded sections at the moment of each `didChangeProgress`.
    var loadedAtProgress: [Set<Int>] = []

    func panorama(_ panorama: TesseraPanoramaViewController, didShowSectionAt index: Int) {
        shown.append(index)
    }

    func panorama(_ panorama: TesseraPanoramaViewController, didChangeProgress t: CGFloat) {
        progress.append(t)
        loadedAtProgress.append(Set(panorama.loadedSections.keys))
    }
}

/// SwiftUI section content with a checkable value.
private struct ProbeView: View {
    let value: Int

    var body: some View {
        Text("\(value)")
    }
}

final class PanoramaControllerReviewTests: XCTestCase {

    private let screen = CGSize(width: 390, height: 700)

    /// The section step at peek 48: `390 − 48 = 342`.
    private let itemWidth: CGFloat = 342

    // MARK: - Helpers

    private func makeSections(
        count: Int,
        ids: [Int]? = nil,
        onMake: ((Int) -> Void)? = nil
    ) -> [TesseraPanoramaSection] {
        (ids ?? Array(0..<count)).map { id in
            TesseraPanoramaSection(id: id, title: "Section \(id)") {
                onMake?(id)
                return UIViewController()
            }
        }
    }

    private func makeSwiftUISections(count: Int, value: Int) -> [TesseraPanoramaSection] {
        (0..<count).map { id in
            TesseraPanoramaSection(
                id: id,
                title: "Section \(id)",
                content: TesseraSwiftUIContentProvider { ProbeView(value: value) }
            )
        }
    }

    private func makePanorama(
        sections: [TesseraPanoramaSection],
        style: TesseraPanoramaStyle = TesseraPanoramaStyle(),
        size: CGSize? = nil
    ) -> TesseraPanoramaViewController {
        let panorama = TesseraPanoramaViewController(sections: sections, style: style)
        panorama.loadViewIfNeeded()
        panorama.view.frame = CGRect(origin: .zero, size: size ?? screen)
        panorama.view.layoutIfNeeded()
        return panorama
    }

    private func makePanorama(count: Int = 4) -> TesseraPanoramaViewController {
        makePanorama(sections: makeSections(count: count))
    }

    /// Drives the programmatic offset animation to its end if UIKit did not complete
    /// it synchronously.
    private func finishAnimationIfNeeded(
        _ panorama: TesseraPanoramaViewController,
        to targetX: CGFloat,
        spy: PanoramaSpy,
        expectedShown: Int
    ) {
        guard !spy.shown.contains(expectedShown) else { return }
        let scrollView = panorama.scrollView
        scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        scrollView.scrollViewDidEndScrollingAnimation(scrollView)
    }

    // MARK: - Snap settling without inertia

    /// The gesture ended with no velocity at 200 pt: the policy picks section 1
    /// (342), but UIKit ignores the target at zero velocity. The panorama itself
    /// drives the offset to 342 and only then reports the section show.
    func testDragWithoutVelocityAlignsOffset() {
        let panorama = makePanorama()
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.contentOffset = .zero
        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: 200, y: 0)
        var target = CGPoint(x: 200, y: 0)
        scrollView.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.x, itemWidth, accuracy: 0.001)

        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        // Either the animation completed synchronously (the offset is aligned, the show is 1),
        // or it is still running and no show was reported. A show at an unaligned
        // offset is a defect.
        XCTAssertTrue(
            spy.shown.isEmpty || abs(scrollView.contentOffset.x - itemWidth) < 0.001,
            "section show \(spy.shown) at unaligned offset \(scrollView.contentOffset.x)"
        )
        finishAnimationIfNeeded(panorama, to: itemWidth, spy: spy, expectedShown: 1)

        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001, "offset is not aligned after a drag with no velocity")
        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(panorama.currentSectionIndex, 1)
    }

    /// Without a policy target (a gesture without `willEndDragging`) settling goes to the nearest
    /// section: 442 pt (1.29 sections) goes back to section 1, not "as is".
    func testDragWithoutVelocityAndWithoutPolicyTargetAlignsToNearest() {
        let panorama = makePanorama()
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.contentOffset = CGPoint(x: itemWidth + 100, y: 0)
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertTrue(
            spy.shown.isEmpty || abs(scrollView.contentOffset.x - itemWidth) < 0.001,
            "section show \(spy.shown) at unaligned offset \(scrollView.contentOffset.x)"
        )
        finishAnimationIfNeeded(panorama, to: itemWidth, spy: spy, expectedShown: 1)

        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
        XCTAssertEqual(spy.shown, [1])
    }

    /// An already aligned offset: no settling is needed, the transition completes at once.
    func testDragEndingAlignedFinishesImmediately() {
        let panorama = makePanorama()
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let scrollView = panorama.scrollView

        scrollView.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: itemWidth, y: 0)
        var target = CGPoint(x: itemWidth, y: 0)
        scrollView.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        scrollView.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertEqual(spy.shown, [1])
        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
    }

    // MARK: - VoiceOver from the header, contentInsetAdjustmentBehavior

    /// VoiceOver focus on the header layer: a three-finger swipe left (forward
    /// in LTR by the UIKit convention) pages to the next section.
    func testAccessibilityScrollFromHeaderPagesSections() {
        let panorama = makePanorama()
        panorama.view.semanticContentAttribute = .forceLeftToRight
        panorama.view.layoutIfNeeded()
        let spy = PanoramaSpy()
        panorama.delegate = spy

        XCTAssertTrue(panorama.headerView.accessibilityScroll(.left), "a gesture from the header must page")
        finishAnimationIfNeeded(panorama, to: itemWidth, spy: spy, expectedShown: 1)

        XCTAssertEqual(panorama.currentSectionIndex, 1)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, itemWidth, accuracy: 0.001)

        // A vertical gesture is not section paging.
        XCTAssertFalse(panorama.headerView.accessibilityScroll(.up))
    }

    /// §8: the section strip's inset adjustment is taken from the style and changes on the fly.
    func testContentInsetAdjustmentBehaviorComesFromStyle() {
        let panorama = makePanorama()
        XCTAssertEqual(panorama.scrollView.contentInsetAdjustmentBehavior, .never)

        var style = TesseraPanoramaStyle()
        style.contentInsetAdjustmentBehavior = .always
        panorama.style = style
        XCTAssertEqual(panorama.scrollView.contentInsetAdjustmentBehavior, .always)

        let configured = makePanorama(
            sections: makeSections(count: 2),
            style: TesseraPanoramaStyle(contentInsetAdjustmentBehavior: .scrollableAxes)
        )
        XCTAssertEqual(configured.scrollView.contentInsetAdjustmentBehavior, .scrollableAxes)
    }

    // MARK: - Deferred layout

    /// A rotation during a gesture is deferred (§8), and when inertia ends
    /// it must be applied: the strip's frame and the offset match the new width.
    func testDeferredLayoutIsAppliedWhenScrollEnds() {
        let panorama = makePanorama()
        panorama.selectSection(at: 1, animated: false)
        let scrollView = panorama.scrollView

        scrollView.interactionOverrideForTesting = true
        panorama.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        panorama.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.frame.width, screen.width, "layout is deferred during a gesture")

        scrollView.interactionOverrideForTesting = false
        scrollView.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(scrollView.frame.width, 844, "the deferred layout was not applied")
        XCTAssertEqual(scrollView.contentOffset.x, scrollView.alignmentOffset(forReadingIndex: 1), accuracy: 0.001)
        XCTAssertEqual(panorama.currentSectionIndex, 1)
    }

    // MARK: - Reading direction change on the fly

    /// LTR → RTL → LTR via the root view's `semanticContentAttribute`:
    /// the same section in reading order stays, not the mirrored one.
    func testSemanticDirectionChangeKeepsReadingSection() {
        let panorama = makePanorama()
        panorama.view.semanticContentAttribute = .forceLeftToRight
        panorama.view.layoutIfNeeded()
        panorama.selectSection(at: 1, animated: false)
        let scrollView = panorama.scrollView
        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)

        panorama.view.semanticContentAttribute = .forceRightToLeft
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.resolvedLayoutDirection, .rightToLeft)
        XCTAssertEqual(panorama.currentSectionIndex, 1, "the direction change opened a different section")
        // RTL: section 1 is physical slot 4 − 1 − 1 = 2.
        XCTAssertEqual(scrollView.contentOffset.x, 2 * itemWidth, accuracy: 0.001)
        XCTAssertNotNil(panorama.loadedSections[1])

        panorama.view.semanticContentAttribute = .forceLeftToRight
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.resolvedLayoutDirection, .leftToRight)
        XCTAssertEqual(panorama.currentSectionIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
    }

    /// The same via the trait environment (the interface direction from the parent).
    func testTraitDirectionChangeKeepsReadingSection() {
        // The trait environment propagates only through a hierarchy with a window.
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        parent.view.frame = CGRect(origin: .zero, size: screen)
        let panorama = TesseraPanoramaViewController(sections: makeSections(count: 4))
        parent.addChild(panorama)
        parent.view.addSubview(panorama.view)
        panorama.didMove(toParent: parent)
        parent.setOverrideTraitCollection(UITraitCollection(layoutDirection: .leftToRight), forChild: panorama)
        panorama.view.frame = CGRect(origin: .zero, size: screen)
        panorama.view.layoutIfNeeded()
        panorama.selectSection(at: 0, animated: false)
        let scrollView = panorama.scrollView
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)

        parent.setOverrideTraitCollection(UITraitCollection(layoutDirection: .rightToLeft), forChild: panorama)
        panorama.view.setNeedsLayout()
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.resolvedLayoutDirection, .rightToLeft, "the trait direction did not reach the scroll view")
        XCTAssertEqual(panorama.currentSectionIndex, 0, "the direction change opened the mirrored section")
        XCTAssertEqual(scrollView.contentOffset.x, 3 * itemWidth, accuracy: 0.001)
    }

    // MARK: - Peek change on the fly

    /// A `peek` change alters the section step; the section stays aligned to the new
    /// snap point, not between them.
    func testPeekChangeKeepsSectionAligned() {
        let panorama = makePanorama()
        panorama.selectSection(at: 2, animated: false)
        let scrollView = panorama.scrollView
        XCTAssertEqual(scrollView.contentOffset.x, 2 * itemWidth, accuracy: 0.001)

        panorama.style = TesseraPanoramaStyle(peek: 16)
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(scrollView.itemWidth, 374, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.x, 2 * 374, accuracy: 0.001, "the section is between snap points")
        XCTAssertEqual(panorama.currentSectionIndex, 2)
    }

    // MARK: - reload reuses sections

    /// A `reload` with the same `id`s: the loaded controllers are the same instances,
    /// and the factories are not called again.
    func testReloadReusesSurvivingSections() {
        var made: [Int] = []
        let panorama = makePanorama(sections: makeSections(count: 4) { made.append($0) })
        let before0 = panorama.loadedSections[0]
        let before1 = panorama.loadedSections[1]
        XCTAssertNotNil(before0)
        XCTAssertEqual(made.sorted(), [0, 1])

        panorama.reload(sections: makeSections(count: 4) { made.append($0) })

        XCTAssertTrue(panorama.loadedSections[0] === before0, "section 0 was recreated")
        XCTAssertTrue(panorama.loadedSections[1] === before1, "section 1 was recreated")
        XCTAssertEqual(made.sorted(), [0, 1], "the factories of survivors must not be called")
        XCTAssertTrue(before0?.parent === panorama)
    }

    /// A reorder: the current section is looked up by `id`, survivors in the new window
    /// are reused, and those that left the window or disappeared are unloaded.
    func testReloadWithReorderKeepsCurrentAndReusesWindow() {
        var made: [Int] = []
        let panorama = makePanorama(sections: makeSections(count: 4) { made.append($0) })
        panorama.selectSection(at: 1, animated: false)
        let byID: [Int: UIViewController] = [
            0: panorama.loadedSections[0]!,
            1: panorama.loadedSections[1]!,
            2: panorama.loadedSections[2]!,
        ]
        made.removeAll()

        panorama.reload(sections: makeSections(count: 4, ids: [3, 1, 0, 2]) { made.append($0) })

        XCTAssertEqual(panorama.currentSectionIndex, 1, "the current section is the one with id 1")
        XCTAssertEqual(panorama.scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
        XCTAssertTrue(panorama.loadedSections[1] === byID[1])
        XCTAssertTrue(panorama.loadedSections[2] === byID[0])
        XCTAssertEqual(made, [3], "only the section that is new in the window is created")
        XCTAssertNil(byID[2]?.parent, "the section that left the window is unloaded")
    }

    // MARK: - A far animated selectSection

    /// A 0 → 5 transition with animation: on no progress frame are there
    /// unloaded sections in the frame, and only the last step 4 → 5 is animated.
    func testAnimatedFarSelectDoesNotFlyOverEmptySlots() {
        let panorama = makePanorama(count: 6)
        let spy = PanoramaSpy()
        panorama.delegate = spy

        panorama.selectSection(at: 5, animated: true)
        finishAnimationIfNeeded(panorama, to: 5 * itemWidth, spy: spy, expectedShown: 5)

        XCTAssertFalse(spy.progress.isEmpty)
        for (progress, loaded) in zip(spy.progress, spy.loadedAtProgress) {
            let visible = Set([Int(progress.rounded(.down)), Int(progress.rounded(.up))])
            XCTAssertTrue(
                visible.isSubset(of: loaded),
                "progress \(progress): sections \(visible) in the frame, loaded \(loaded.sorted())"
            )
            XCTAssertGreaterThanOrEqual(progress, 4 - 0.001, "the animation flies through intermediate slots")
        }
        XCTAssertEqual(panorama.currentSectionIndex, 5)
        XCTAssertEqual(spy.shown, [5])
        XCTAssertEqual(Set(panorama.loadedSections.keys), [4, 5])
    }

    // MARK: - The same style is not reapplied

    /// SwiftUI assigns the style on every update: an equal style does not
    /// trigger layout and does not touch the layers.
    func testAssigningEquivalentStyleIsNoOp() {
        let image = UIImage()
        let panorama = makePanorama(
            sections: makeSections(count: 3),
            style: TesseraPanoramaStyle(backgroundBehavior: .image(image))
        )
        XCTAssertFalse(panorama.view.layer.needsLayout())

        panorama.style = TesseraPanoramaStyle(backgroundBehavior: .image(image))
        XCTAssertFalse(panorama.view.layer.needsLayout(), "the same style was reapplied")

        panorama.style = TesseraPanoramaStyle(peek: 20, backgroundBehavior: .image(image))
        XCTAssertTrue(panorama.view.layer.needsLayout(), "a new style must be applied")
    }

    /// Style comparison takes every field into account.
    func testStyleEquivalenceCoversAllFields() {
        let base = TesseraPanoramaStyle()
        XCTAssertTrue(base.isEquivalent(to: TesseraPanoramaStyle()))

        var changed = base
        changed.parallaxFactor = 0.42
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.headerFont = .systemFont(ofSize: 20)
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.headerColor = .red
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.headerActiveColor = .red
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.contentInsetAdjustmentBehavior = .always
        XCTAssertFalse(base.isEquivalent(to: changed))
        changed = base
        changed.backgroundBehavior = .image(nil)
        XCTAssertFalse(base.isEquivalent(to: changed))
        XCTAssertFalse(
            TesseraPanoramaStyle(backgroundBehavior: .image(UIImage()))
                .isEquivalent(to: TesseraPanoramaStyle(backgroundBehavior: .image(UIImage()))),
            "images are compared by identity"
        )
    }

    // MARK: - Rotation without false progress

    /// Rotation is a geometry recomputation, not user progress: the delegate does not
    /// receive `didChangeProgress`, and the section is kept.
    func testRotationDoesNotReportProgress() {
        let panorama = makePanorama()
        panorama.selectSection(at: 3, animated: false)
        let spy = PanoramaSpy()
        panorama.delegate = spy

        panorama.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        panorama.view.layoutIfNeeded()
        panorama.view.frame = CGRect(origin: .zero, size: screen)
        panorama.view.layoutIfNeeded()

        XCTAssertEqual(spy.progress, [], "false didChangeProgress on rotation")
        XCTAssertEqual(panorama.currentSectionIndex, 3)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, 3 * itemWidth, accuracy: 0.001)
    }

    // MARK: - SwiftUI section content with the same id

    /// The same `id`s/titles, new content: loaded SwiftUI sections
    /// are updated in place: the same controller, a new `rootView`; the offset and
    /// the current section do not change, and the delegate stays silent.
    func testUpdateContentRefreshesLoadedSwiftUISectionsInPlace() throws {
        let panorama = makePanorama(sections: makeSwiftUISections(count: 4, value: 1))
        panorama.selectSection(at: 1, animated: false)
        let spy = PanoramaSpy()
        panorama.delegate = spy
        let before = try XCTUnwrap(panorama.loadedSections[1] as? UIHostingController<ProbeView>)
        XCTAssertEqual(before.rootView.value, 1)

        panorama.updateContent(of: makeSwiftUISections(count: 4, value: 2))

        let after = try XCTUnwrap(panorama.loadedSections[1] as? UIHostingController<ProbeView>)
        XCTAssertTrue(after === before, "the section controller was recreated")
        XCTAssertEqual(after.rootView.value, 2, "the content was not updated")
        XCTAssertEqual(
            (panorama.loadedSections[0] as? UIHostingController<ProbeView>)?.rootView.value,
            2
        )
        XCTAssertEqual(panorama.currentSectionIndex, 1)
        XCTAssertEqual(panorama.scrollView.contentOffset.x, itemWidth, accuracy: 0.001)
        XCTAssertEqual(spy.shown, [])
        XCTAssertEqual(spy.progress, [])

        // An unloaded section is created from the new provider.
        panorama.selectSection(at: 3, animated: false)
        XCTAssertEqual((panorama.loadedSections[3] as? UIHostingController<ProbeView>)?.rootView.value, 2)
    }

    /// End-to-end scenario of the facade: redrawing `TesseraPanoramaView` with the same
    /// `id`s/titles delivers the new content to the section.
    func testPanoramaViewPropagatesContentForSameIdentifiers() throws {
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        let host = UIHostingController(rootView: TesseraPanoramaView(sections: makeSwiftUISections(count: 3, value: 1)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let panorama = try XCTUnwrap(Self.findPanorama(in: host), "TesseraPanoramaViewController not found")
        panorama.view.layoutIfNeeded()
        let before = try XCTUnwrap(panorama.loadedSections[0] as? UIHostingController<ProbeView>)
        XCTAssertEqual(before.rootView.value, 1)

        host.rootView = TesseraPanoramaView(sections: makeSwiftUISections(count: 3, value: 7))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let after = try XCTUnwrap(panorama.loadedSections[0] as? UIHostingController<ProbeView>)
        XCTAssertTrue(after === before)
        XCTAssertEqual(after.rootView.value, 7, "the SwiftUI section content with the same id was not updated")
    }

    private static func findPanorama(in controller: UIViewController) -> TesseraPanoramaViewController? {
        if let panorama = controller as? TesseraPanoramaViewController { return panorama }
        for child in controller.children {
            if let found = findPanorama(in: child) { return found }
        }
        return nil
    }
}

#endif
