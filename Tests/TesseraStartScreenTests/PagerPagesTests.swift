//
//  PagerPagesTests.swift
//  TesseraStartScreenTests
//
//  Tests for the start screen page configuration.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §1 "The key
//  architectural idea: three pages" (START in the center, the hook on the left, the
//  app list on the right; leading edge policy) and §14 "MVP clarifications"
//  (D13: both side pages are optional, the pager scales from one to
//  three pages).
//
//  The tests do not spin the UI loop and do not emulate touches: the controller loads its view,
//  is laid out manually, and the page count is checked through the public hierarchy
//  of the Core pager (its `children` are the pages of the window ±1). Page accessibility
//  is checked through `showPage` and `accessibilityScroll`, which rely on
//  the page order, not on physical scrolling.
//

#if canImport(UIKit)

import UIKit
import XCTest
import TesseraCore
@testable import TesseraStartScreen

final class PagerPagesTests: XCTestCase {

    // MARK: - Helpers

    private func makeLeftPanel() -> TesseraQuickPanelProviding {
        TesseraQuickPanelProvider { UIViewController() }
    }

    private func makeScreen(
        leftPanel: TesseraQuickPanelProviding? = nil,
        rightPage: (() -> UIViewController)? = nil
    ) -> TesseraStartScreenViewController {
        let screen = TesseraStartScreenViewController()
        screen.configure(leftPanel: leftPanel, rightPage: rightPage)
        return screen
    }

    /// Loads the screen without a window and returns the Core pager.
    ///
    /// - Parameter screen: The start screen.
    /// - Returns: The pager that contains the loaded pages.
    private func loadedPager(
        of screen: TesseraStartScreenViewController
    ) throws -> TesseraPagerViewController {
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        screen.view.layoutIfNeeded()

        let pager = try XCTUnwrap(
            screen.children.compactMap { $0 as? TesseraPagerViewController }.first,
            "The screen must contain a Core pager"
        )
        // The screen may not have laid out the pager yet (zero page width prevents
        // loading pages), so the geometry is finished manually, as in the Core tests.
        pager.view.frame = screen.view.bounds
        pager.view.layoutIfNeeded()
        return pager
    }

    /// Number of pages in the pager.
    ///
    /// The pager keeps the current page and its ±1 neighbors in memory, and there are at most
    /// three pages, so `children.count` equals the page count.
    ///
    /// - Parameter screen: The start screen.
    /// - Returns: The page count: 1...3 (D13).
    private func pageCount(of screen: TesseraStartScreenViewController) throws -> Int {
        try loadedPager(of: screen).children.count
    }

    // MARK: - Page composition (D13)

    /// Without side panels only START exists.
    func testDefaultScreenHasOnlyStartPage() throws {
        let screen = makeScreen()

        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(try pageCount(of: screen), 1)
    }

    /// The left panel adds a second page.
    func testLeftPanelAddsSecondPage() throws {
        let screen = makeScreen(leftPanel: makeLeftPanel())

        XCTAssertEqual(try pageCount(of: screen), 2)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// The right page adds a second page.
    func testRightPageAddsSecondPage() throws {
        let screen = makeScreen(rightPage: { UIViewController() })

        XCTAssertEqual(try pageCount(of: screen), 2)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Both panels give exactly three pages (D13: from 1 to 3).
    func testBothSidePagesAddThirdPage() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )

        XCTAssertEqual(try pageCount(of: screen), 3)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Rebuilding the configuration removes a page that no longer exists and
    /// returns the user to START.
    func testConfigureRemovesPagesAndFallsBackToStart() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        _ = try loadedPager(of: screen)

        screen.showPage(.applications, animated: false)
        XCTAssertEqual(screen.currentPage, .applications)

        screen.configure(leftPanel: nil, rightPage: nil)
        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(try pageCount(of: screen), 1)
    }

    // MARK: - Page accessibility before the view loads

    /// Pages not provided by the host are not opened programmatically (D13): the intent
    /// is rejected, the current page stays START.
    func testUnavailablePagesRejectProgrammaticShowBeforeLoad() {
        let screen = TesseraStartScreenViewController()

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(screen.currentPage, .start)

        screen.showPage(.applications, animated: false)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Provided pages are available programmatically before the view loads; the intent
    /// is remembered and applied by the first layout.
    func testConfiguredPagesAcceptProgrammaticShowBeforeLoad() {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )

        screen.showPage(.applications, animated: false)
        XCTAssertEqual(screen.currentPage, .applications)

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(screen.currentPage, .quickPanel)

        screen.showPage(.start, animated: false)
        XCTAssertEqual(screen.currentPage, .start)
    }

    // MARK: - Swipe and reading order

    /// With three pages you can swipe back from START to the hook (§1).
    func testThreePagesScrollBackwardsFromStart() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        _ = try loadedPager(of: screen)

        XCTAssertTrue(screen.accessibilityScroll(.previous))
        XCTAssertEqual(screen.currentPage, .quickPanel)
    }

    /// With three pages you can swipe forward from START to the app list.
    func testThreePagesScrollForwardsFromStart() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        _ = try loadedPager(of: screen)

        XCTAssertTrue(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .applications)
    }

    /// With a single page there is nowhere to swipe.
    func testSinglePageDoesNotScroll() throws {
        let screen = makeScreen()
        _ = try loadedPager(of: screen)

        XCTAssertFalse(screen.accessibilityScroll(.previous))
        XCTAssertFalse(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Only the left panel: going back is possible, going forward is not.
    func testLeftPanelOnlyScrollsBackwards() throws {
        let screen = makeScreen(leftPanel: makeLeftPanel())
        _ = try loadedPager(of: screen)

        XCTAssertFalse(screen.accessibilityScroll(.next))
        XCTAssertTrue(screen.accessibilityScroll(.previous))
        XCTAssertEqual(screen.currentPage, .quickPanel)
    }

    /// Only the right page: going forward is possible, going back is not.
    func testRightPageOnlyScrollsForwards() throws {
        let screen = makeScreen(rightPage: { UIViewController() })
        _ = try loadedPager(of: screen)

        XCTAssertFalse(screen.accessibilityScroll(.previous))
        XCTAssertTrue(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .applications)
    }

    // MARK: - Leading edge policy (§1)

    /// With `yieldsLeftEdgeToSystemGesture` the hook is excluded from the swipeable
    /// set: you cannot go back from START, but the right page remains.
    func testEdgePolicyExcludesQuickPanelFromSwipe() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        screen.yieldsLeftEdgeToSystemGesture = true

        XCTAssertEqual(try pageCount(of: screen), 2)
        XCTAssertFalse(screen.accessibilityScroll(.previous))
        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertTrue(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .applications)
    }

    /// With the edge policy the hook still opens programmatically (§1):
    /// `showPage` unfolds it in the pager.
    func testEdgePolicyAllowsProgrammaticQuickPanel() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        screen.yieldsLeftEdgeToSystemGesture = true
        _ = try loadedPager(of: screen)

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(screen.currentPage, .quickPanel)
    }
}

#endif
