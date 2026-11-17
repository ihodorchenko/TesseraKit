//
//  PivotContentUpdateTests.swift
//  TesseraPivotTests
//
//  Contract tests for section content updates.
//  Design document: docs/PIVOT-IOS-DESIGN.md §3 (architecture: the SwiftUI facade
//  `TesseraPivotView`), §5 (synchronization: a single writer of `contentOffset`),
//  docs/CORE-IOS-DESIGN.md, implementation deviations (the pager's `reload`
//  keeps the page and controllers by `id`, SwiftUI content is updated through
//  `TesseraContentHosting`).
//
//  Checked: new content with the same `id`s/titles reaches the pages
//  (both via `TesseraPivotView` and via the controller); the page, controllers, scroll view, and
//  the content's `@StateObject` are preserved; during a transition the update
//  is deferred; the progress callback is not called synchronously inside `reload`.
//

#if canImport(UIKit) && canImport(SwiftUI)

import XCTest
import UIKit
import SwiftUI
import TesseraCore
@testable import TesseraPivot

/// A creation counter for SwiftUI page state: recreating a `@StateObject`
/// means losing the content's `@State`.
final class PivotProbeToken: ObservableObject {
    static var createdCount = 0

    init() {
        Self.createdCount += 1
    }
}

/// SwiftUI page content with an observable value and its own state.
struct PivotProbeContent: View {
    let value: String
    @StateObject private var token = PivotProbeToken()

    var body: some View {
        ScrollView {
            Text(value)
        }
    }
}

/// The SwiftUI harness store: changing the value redraws `TesseraPivotView`.
final class PivotProbeStore: ObservableObject {
    @Published var value = "A"
}

/// The facade harness: sections with the same `id`s/titles, with content depending on
/// the store's state.
struct PivotProbeHarness: View {
    @ObservedObject var store: PivotProbeStore
    let delegate: TesseraPivotDelegate?

    var body: some View {
        let value = store.value
        return TesseraPivotView(
            sections: (0..<3).map { index in
                TesseraPivotSection(
                    id: index,
                    title: "S\(index)",
                    content: TesseraSwiftUIContentProvider {
                        PivotProbeContent(value: "\(value)-\(index)")
                    }
                )
            },
            delegate: delegate
        )
    }
}

final class PivotContentUpdateTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func spinRunLoop(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeSections(value: String, count: Int = 4) -> [TesseraPivotSection] {
        (0..<count).map { index in
            TesseraPivotSection(
                id: index,
                title: "S\(index)",
                content: TesseraSwiftUIContentProvider {
                    PivotProbeContent(value: "\(value)-\(index)")
                }
            )
        }
    }

    private func host(_ controller: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        self.window = window
        spinRunLoop()
    }

    /// The pager's SwiftUI pages by their content value.
    private func pageHosts(
        of pivot: TesseraPivotViewController
    ) -> [UIHostingController<PivotProbeContent>] {
        pivot.pagerViewController.children.compactMap {
            $0 as? UIHostingController<PivotProbeContent>
        }
    }

    private func pageHost(
        _ index: Int,
        of pivot: TesseraPivotViewController
    ) -> UIHostingController<PivotProbeContent>? {
        pageHosts(of: pivot).first { $0.rootView.value.hasSuffix("-\(index)") }
    }

    // MARK: - Controller: content update without losing state

    /// The same set of `id`s/titles with new content: the page stays
    /// the same, controllers are reused, and `rootView` is updated.
    func testRefreshSectionContentUpdatesExistingPagesInPlace() throws {
        let pivot = TesseraPivotViewController(sections: makeSections(value: "A"))
        host(pivot)
        pivot.selectSection(at: 2, animated: false)
        let scrollView = try XCTUnwrap(pivot.pagerScrollView)
        let offsetBefore = scrollView.contentOffset
        let hostBefore = try XCTUnwrap(pageHost(2, of: pivot))

        pivot.refreshSectionContent(makeSections(value: "B"))

        let hostAfter = try XCTUnwrap(pageHost(2, of: pivot))
        XCTAssertTrue(hostAfter === hostBefore, "The page controller is reused")
        XCTAssertEqual(hostAfter.rootView.value, "B-2")
        XCTAssertEqual(pageHost(1, of: pivot)?.rootView.value, "B-1")
        XCTAssertEqual(pivot.currentSectionIndex, 2)
        XCTAssertEqual(scrollView.contentOffset, offsetBefore)
    }

    /// An update during an animated transition is deferred (the pager's reload
    /// would cut the animation short) and applied when it completes.
    func testRefreshSectionContentIsDeferredDuringAnimatedTransition() throws {
        try XCTSkipIf(TesseraAccessibility.isReduceMotionEnabled, "An animated transition is required")
        let pivot = TesseraPivotViewController(sections: makeSections(value: "A"))
        host(pivot)

        pivot.selectSection(at: 1, animated: true)
        XCTAssertTrue(pivot.isTransitionInFlight)

        pivot.refreshSectionContent(makeSections(value: "B"))
        XCTAssertEqual(pageHost(0, of: pivot)?.rootView.value, "A-0", "The content is not touched during the transition")

        pivot.pager(pivot.pagerViewController, didShowPageAt: 1)

        XCTAssertFalse(pivot.isTransitionInFlight)
        XCTAssertEqual(pageHost(1, of: pivot)?.rootView.value, "B-1", "The deferred content is applied")
    }

    // MARK: - Progress is not called synchronously inside reload

    /// A `reload` that changes the current section's position does not call
    /// `didChangeProgress` synchronously; the final value arrives on the next
    /// pass of the main queue.
    func testReloadDefersProgressCallback() throws {
        let pivot = TesseraPivotViewController(sections: makeSections(value: "A"))
        host(pivot)
        pivot.selectSection(at: 2, animated: false)
        let spy = PivotTransitionSpy()
        pivot.delegate = spy

        // Section 2 moves to the start: the progress changes 2 → 0.
        let reordered = makeSections(value: "A")
        pivot.reload(sections: [reordered[2], reordered[0], reordered[1], reordered[3]])

        XCTAssertEqual(spy.progressValues, [], "The progress callback must not be called inside reload")
        XCTAssertEqual(pivot.currentSectionIndex, 0)

        spinRunLoop(0.05)
        XCTAssertEqual(spy.progressValues, [0])
    }

    /// A `reload` with the same position produces no progress callbacks at all:
    /// there is no "callback → SwiftUI state → update → reload" cycle.
    func testReloadWithUnchangedProgressDoesNotNotifyDelegate() throws {
        let pivot = TesseraPivotViewController(sections: makeSections(value: "A"))
        host(pivot)
        pivot.selectSection(at: 1, animated: false)
        let spy = PivotTransitionSpy()
        pivot.delegate = spy

        pivot.reload(sections: makeSections(value: "B"))
        spinRunLoop(0.05)

        XCTAssertEqual(spy.progressValues, [])
    }

    // MARK: - SwiftUI facade

    /// `TesseraPivotView` delivers new section content with the same `id`s/titles
    /// (previously `sectionsDiffer` compared only `id`+`title` and reload was not
    /// called): the page, hosting controller, and `@StateObject` are preserved.
    func testPivotViewPropagatesContentForSameIdentifiers() throws {
        let store = PivotProbeStore()
        let spy = PivotTransitionSpy()
        let hosting = UIHostingController(rootView: PivotProbeHarness(store: store, delegate: spy))
        host(hosting)

        let pivot = try XCTUnwrap(
            hosting.children.compactMap { $0 as? TesseraPivotViewController }.first,
            "TesseraPivotView must embed TesseraPivotViewController"
        )
        pivot.selectSection(at: 1, animated: false)
        spinRunLoop()

        let hostBefore = try XCTUnwrap(pageHost(1, of: pivot))
        XCTAssertEqual(hostBefore.rootView.value, "A-1")
        let tokensBefore = PivotProbeToken.createdCount
        XCTAssertGreaterThan(tokensBefore, 0, "Precondition: the SwiftUI page is rendered and created a @StateObject")
        let progressCountBefore = spy.progressValues.count

        store.value = "B"
        spinRunLoop()
        hosting.view.layoutIfNeeded()

        let hostAfter = try XCTUnwrap(pageHost(1, of: pivot))
        XCTAssertTrue(hostAfter === hostBefore, "The page hosting is reused")
        XCTAssertEqual(hostAfter.rootView.value, "B-1", "The new content reached the page")
        XCTAssertEqual(pivot.currentSectionIndex, 1, "The current section is preserved")
        XCTAssertEqual(PivotProbeToken.createdCount, tokensBefore, "The content's @StateObject was not recreated")
        XCTAssertEqual(spy.progressValues.count, progressCountBefore, "A content update does not send progress")
    }
}

#endif
