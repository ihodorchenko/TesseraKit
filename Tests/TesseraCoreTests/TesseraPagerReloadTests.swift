//
//  TesseraPagerReloadTests.swift
//  TesseraCoreTests
//
//  Regression tests for the pager from the repeated review.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts:
//  the `t` invariant, a single writer of contentOffset) and docs/PIVOT-IOS-DESIGN.md §1
//  ("direct jump without flying through intermediate pages").
//
//  Scenarios: `reload(pages:)` keeps the current page by `id` and does not
//  recreate controllers whose `id` survived; rotation (a width change) does not
//  disturb the current page; a direction change on the fly re-lays out the slots;
//  appearance callbacks arrive according to visibility; an animated far transition
//  does not fly through the intermediate pages.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// A page controller that counts appearance callbacks.
private final class AppearanceSpyController: UIViewController {
    let pageID: String

    private(set) var willAppearCount = 0
    private(set) var didAppearCount = 0
    private(set) var willDisappearCount = 0
    private(set) var didDisappearCount = 0

    init(pageID: String) {
        self.pageID = pageID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        willAppearCount += 1
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppearCount += 1
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        willDisappearCount += 1
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        didDisappearCount += 1
    }

    /// Whether the page is visible according to the callback counters.
    var isAppeared: Bool { didAppearCount > didDisappearCount }

    /// will/did pairs are balanced (no "dangling" transitions).
    var isBalanced: Bool {
        willAppearCount == didAppearCount && willDisappearCount == didDisappearCount
    }
}

/// A page factory: remembers every created controller by `id`.
private final class PageFactory {
    private(set) var created: [String: [AppearanceSpyController]] = [:]

    func descriptors(_ ids: [String]) -> [TesseraPageDescriptor] {
        ids.map { id in
            TesseraPageDescriptor(id: id, title: id) { [unowned self] in
                let controller = AppearanceSpyController(pageID: id)
                self.created[id, default: []].append(controller)
                return controller
            }
        }
    }

    func creationCount(_ id: String) -> Int { created[id]?.count ?? 0 }

    func controller(_ id: String) -> AppearanceSpyController? { created[id]?.last }
}

/// A delegate spy: indexes of the shown pages and progress values.
private final class PagerDelegateSpy: TesseraPagerDelegate {
    var shownIndexes: [Int] = []
    var progressValues: [CGFloat] = []

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }

    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }
}

final class TesseraPagerReloadTests: XCTestCase {

    private let pageWidth: CGFloat = 320
    private let pageHeight: CGFloat = 480

    // MARK: - Helpers

    private func makeLoadedPager(
        _ pages: [TesseraPageDescriptor],
        width: CGFloat? = nil,
        height: CGFloat? = nil
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: .paged, pages: pages)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(
            x: 0,
            y: 0,
            width: width ?? pageWidth,
            height: height ?? pageHeight
        )
        pager.view.layoutIfNeeded()
        return (pager, try scrollView(of: pager))
    }

    private func scrollView(of pager: TesseraPagerViewController) throws -> UIScrollView {
        try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first,
            "The pager must contain a UIScrollView"
        )
    }

    private func loadedIDs(_ pager: TesseraPagerViewController) -> Set<String> {
        Set(pager.children.compactMap { ($0 as? AppearanceSpyController)?.pageID })
    }

    private func appear(_ pager: TesseraPagerViewController) {
        pager.beginAppearanceTransition(true, animated: false)
        pager.endAppearanceTransition()
    }

    private func disappear(_ pager: TesseraPagerViewController) {
        pager.beginAppearanceTransition(false, animated: false)
        pager.endAppearanceTransition()
    }

    // MARK: - reload(pages:): current page by id

    /// `[A, B, C]`, current is B; `reload([X, A, B, C])` leaves B current
    /// (now at index 2), and the offset and progress correspond to it.
    func testReloadWithInsertedLeadingPageKeepsCurrentPageByID() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 1, animated: false)
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.reload(pages: factory.descriptors(["X", "A", "B", "C"]))

        XCTAssertEqual(pager.currentPageIndex, 2)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
        XCTAssertEqual(try XCTUnwrap(spy.progressValues.last), 2, accuracy: 0.0001)
        XCTAssertEqual(loadedIDs(pager), ["A", "B", "C"])
    }

    /// The current `id` disappeared: the previous index is kept, clamped.
    func testReloadWithoutCurrentIDKeepsClampedIndex() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 2, animated: false)

        pager.reload(pages: factory.descriptors(["X", "Y"]))

        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
    }

    // MARK: - reload(pages:): controller reuse

    /// Controllers whose `id` survived are not recreated: the same instance before and
    /// after `reload`, with its frame in the new slot; a page outside the ±1 window is not created.
    func testReloadReusesControllersOfSurvivingIDs() throws {
        let factory = PageFactory()
        let (pager, _) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 1, animated: false)
        let originalA = try XCTUnwrap(factory.controller("A"))
        let originalB = try XCTUnwrap(factory.controller("B"))
        let originalC = try XCTUnwrap(factory.controller("C"))

        pager.reload(pages: factory.descriptors(["X", "A", "B", "C"]))

        XCTAssertEqual(factory.creationCount("A"), 1)
        XCTAssertEqual(factory.creationCount("B"), 1)
        XCTAssertEqual(factory.creationCount("C"), 1)
        XCTAssertEqual(factory.creationCount("X"), 0, "X is outside the ±1 window around B")
        XCTAssertTrue(pager.children.contains { $0 === originalA })
        XCTAssertTrue(pager.children.contains { $0 === originalB })
        XCTAssertTrue(pager.children.contains { $0 === originalC })
        XCTAssertEqual(originalB.view.frame.minX, pageWidth * 2)
        XCTAssertEqual(originalA.view.frame.minX, pageWidth)
    }

    /// Ids that disappeared are unloaded; the one that survived is the same instance.
    func testReloadDetachesRemovedIDsAndKeepsSurvivor() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        pager.go(toPage: 1, animated: false)
        let originalA = try XCTUnwrap(factory.controller("A"))
        let originalB = try XCTUnwrap(factory.controller("B"))

        pager.reload(pages: factory.descriptors(["B", "D"]))

        XCTAssertNil(originalA.parent)
        XCTAssertTrue(originalB.parent === pager)
        XCTAssertEqual(factory.creationCount("B"), 1)
        XCTAssertEqual(pager.currentPageIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
        XCTAssertEqual(loadedIDs(pager), ["B", "D"])
    }

    // MARK: - Rotation

    /// 3 pages, the current one is the last; width 390 → 844 (rotation).
    /// UIKit clamping the offset on a frame change must not disturb the page.
    func testWidthChangeKeepsLastPage() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(
            factory.descriptors(["A", "B", "C"]),
            width: 390,
            height: 844
        )
        pager.go(toPage: 2, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 390 * 2)
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 2)
        XCTAssertEqual(scrollView.contentOffset.x, 844 * 2)
        XCTAssertEqual(scrollView.contentSize.width, 844 * 3)
        XCTAssertEqual(try XCTUnwrap(spy.progressValues.last), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(factory.controller("C")).view.frame.minX, 844 * 2)

        // The reverse rotation also keeps the page.
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 2)
        XCTAssertEqual(scrollView.contentOffset.x, 390 * 2)
    }

    // MARK: - Direction change on the fly

    /// A `semanticContentAttribute` change without an explicit `setNeedsLayout`: the slots
    /// are re-laid out, and the current page is kept by reading order.
    func testSemanticContentAttributeChangeRelayoutsSlots() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C", "D"]))
        pager.go(toPage: 1, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)

        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.layoutIfNeeded()

        // RTL: reading page 1 is physical slot 4 − 1 − 1 = 2.
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
        XCTAssertEqual(try XCTUnwrap(factory.controller("B")).view.frame.minX, pageWidth * 2)
        XCTAssertEqual(try XCTUnwrap(factory.controller("A")).view.frame.minX, pageWidth * 3)

        pager.view.semanticContentAttribute = .forceLeftToRight
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
        XCTAssertEqual(try XCTUnwrap(factory.controller("B")).view.frame.minX, pageWidth)
    }

    /// The direction changed, and before layout the pager managed to synchronize
    /// the index from the offset (the pager being shown): the offset still sits in the slots
    /// of the old direction and must not be interpreted as a mirrored page.
    func testDirectionChangeBeforeLayoutKeepsReadingPage() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C", "D"]))
        pager.go(toPage: 1, animated: false)

        pager.view.semanticContentAttribute = .forceRightToLeft
        appear(pager)
        pager.view.layoutIfNeeded()

        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
        XCTAssertTrue(try XCTUnwrap(factory.controller("B")).isAppeared)
    }

    // MARK: - Appearance by visibility

    /// When the pager is shown, only the current page receives appear; after
    /// a swipe the new page gets appear and the old one disappear; the ±1 neighbors get no callbacks.
    func testAppearanceCallbacksFollowVisiblePage() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        let pageA = try XCTUnwrap(factory.controller("A"))
        let pageB = try XCTUnwrap(factory.controller("B"))

        appear(pager)

        XCTAssertEqual(pageA.willAppearCount, 1)
        XCTAssertEqual(pageA.didAppearCount, 1)
        XCTAssertEqual(pageB.willAppearCount, 0, "the ±1 neighbor is not visible")
        XCTAssertEqual(pageB.didAppearCount, 0)

        // Swipe to B.
        scrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        pager.scrollViewDidEndDecelerating(scrollView)

        let pageC = try XCTUnwrap(factory.controller("C"))
        XCTAssertTrue(pageB.isAppeared)
        XCTAssertFalse(pageA.isAppeared)
        XCTAssertEqual(pageA.didDisappearCount, 1)
        XCTAssertEqual(pageC.willAppearCount, 0, "the new ±1 neighbor is not visible")

        disappear(pager)

        for page in [pageA, pageB, pageC] {
            XCTAssertFalse(page.isAppeared, "page \(page.pageID) stayed visible")
            XCTAssertTrue(page.isBalanced, "unbalanced callbacks for \(page.pageID)")
        }
        XCTAssertEqual(pageB.didDisappearCount, 1)
    }

    /// An instant far transition: the previous current page is unloaded with a
    /// balanced disappear, and the target receives appear.
    func testAppearanceOnFarImmediateJumpAndReload() throws {
        let factory = PageFactory()
        let (pager, _) = try makeLoadedPager(factory.descriptors(["A", "B", "C", "D", "E"]))
        let pageA = try XCTUnwrap(factory.controller("A"))
        appear(pager)

        pager.go(toPage: 4, animated: false)

        let pageE = try XCTUnwrap(factory.controller("E"))
        XCTAssertNil(pageA.parent)
        XCTAssertFalse(pageA.isAppeared)
        XCTAssertTrue(pageA.isBalanced)
        XCTAssertTrue(pageE.isAppeared)

        // A reload that keeps the current page's id does not touch its appearance.
        pager.reload(pages: factory.descriptors(["E", "F"]))
        XCTAssertEqual(pageE.didAppearCount, 1)
        XCTAssertEqual(pageE.didDisappearCount, 0)
        XCTAssertTrue(pageE.isAppeared)

        disappear(pager)
        XCTAssertFalse(pageE.isAppeared)
        XCTAssertTrue(pageE.isBalanced)
    }

    // MARK: - Animated far transition

    /// `go(toPage:animated:true)` beyond ±1: without flying through the intermediate
    /// pages, the offset is set at once to the target's neighbor, the ±1 window around
    /// the target is loaded before the animation, and `didShowPageAt` arrives once, for the target.
    ///
    /// The `setContentOffset(_:animated:)` animation behaves differently in a test process
    /// without an app (without a window it completes synchronously, in a
    /// window without a display it does not advance), so its end is emulated
    /// when needed: the offset is set to the target, then `didEndScrollingAnimation`.
    func testAnimatedFarJumpSkipsIntermediatePages() throws {
        let factory = PageFactory()
        let (pager, scrollView) = try makeLoadedPager(
            factory.descriptors(["A", "B", "C", "D", "E", "F"])
        )
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.go(toPage: 5, animated: true)

        // Before the animation: the offset is already at the target's neighbor, the window around the target is loaded,
        // and the intermediate pages were not created.
        XCTAssertGreaterThanOrEqual(scrollView.contentOffset.x, pageWidth * 4)
        XCTAssertEqual(loadedIDs(pager), ["E", "F"])
        XCTAssertEqual(factory.creationCount("C"), 0)
        XCTAssertEqual(factory.creationCount("D"), 0)
        XCTAssertTrue(
            spy.shownIndexes.allSatisfy { $0 == 5 },
            "spurious didShowPage for an intermediate page: \(spy.shownIndexes)"
        )

        // Without a window UIKit may complete the animation synchronously; otherwise we emulate
        // the last frame. A repeated completion does not duplicate didShowPage.
        if spy.shownIndexes.isEmpty {
            scrollView.setContentOffset(CGPoint(x: pageWidth * 5, y: 0), animated: false)
            pager.scrollViewDidEndScrollingAnimation(scrollView)
        }

        XCTAssertEqual(spy.shownIndexes, [5])
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 5)
        XCTAssertEqual(factory.creationCount("B"), 1)
        XCTAssertEqual(factory.creationCount("C"), 0)
        XCTAssertEqual(factory.creationCount("D"), 0)
        XCTAssertFalse(spy.progressValues.isEmpty)
        for value in spy.progressValues {
            XCTAssertGreaterThanOrEqual(value, 4 - 0.0001, "flew through an intermediate page: t = \(value)")
            XCTAssertLessThanOrEqual(value, 5 + 0.0001)
        }
    }

    /// An animated transition to the current page does not hang: UIKit does not
    /// send `didEndScrollingAnimation` for a zero-length path, so the transition
    /// completes at once.
    func testAnimatedGoToCurrentPageFinishesImmediately() throws {
        let factory = PageFactory()
        let (pager, _) = try makeLoadedPager(factory.descriptors(["A", "B", "C"]))
        let spy = PagerDelegateSpy()
        pager.delegate = spy

        pager.go(toPage: 0, animated: true)

        XCTAssertEqual(spy.shownIndexes, [0])
    }
}

#endif
