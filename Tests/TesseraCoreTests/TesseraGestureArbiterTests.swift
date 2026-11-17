//
//  TesseraGestureArbiterTests.swift
//  TesseraCoreTests
//
//  Contract tests for gesture arbitration.
//  Design document: docs/CORE-IOS-DESIGN.md §2 (key contracts,
//  "Arbitration": horizontal goes to the pager, vertical to the child; the decision is made by the
//  dominant axis) and §3 (conceptual API surface:
//  TesseraGestureArbiter registers children and decides by axis).
//
//  Checks the pure axis decision, blocking of several vertical
//  children for the duration of a horizontal gesture, and restoring the original
//  `isScrollEnabled` values without a UI run loop.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

final class TesseraGestureArbiterTests: XCTestCase {

    private func makeScrollView(enabled: Bool = true) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.isScrollEnabled = enabled
        return scrollView
    }

    // MARK: - axisDecision: the pure axis decision

    /// Horizontal wins when the magnitude of `dx` is strictly greater than that of `dy`.
    /// The sign of the velocity does not affect the axis choice; magnitudes are compared.
    func testHorizontalDominatesWhenAbsDXIsGreater() {
        let velocities: [CGPoint] = [
            CGPoint(x: 10, y: 3),
            CGPoint(x: -10, y: 3),
            CGPoint(x: 10, y: -3),
            CGPoint(x: -10, y: -3),
            CGPoint(x: 0.5, y: 0.49),
        ]

        for velocity in velocities {
            XCTAssertEqual(
                TesseraGestureArbiter.axisDecision(forVelocity: velocity),
                .horizontal,
                "Expected horizontal for velocity \(velocity)"
            )
        }
    }

    /// Vertical wins when the magnitude of `dy` is strictly greater than that of `dx`.
    func testVerticalDominatesWhenAbsDYIsGreater() {
        let velocities: [CGPoint] = [
            CGPoint(x: 3, y: 10),
            CGPoint(x: -3, y: 10),
            CGPoint(x: 3, y: -10),
            CGPoint(x: -3, y: -10),
            CGPoint(x: 0, y: 0.1),
        ]

        for velocity in velocities {
            XCTAssertEqual(
                TesseraGestureArbiter.axisDecision(forVelocity: velocity),
                .vertical,
                "Expected vertical for velocity \(velocity)"
            )
        }
    }

    /// When magnitudes are equal (including zero velocity), horizontal is chosen
    /// deliberately: with no dominance data the gesture stays with the pager.
    func testEqualMagnitudesChooseHorizontal() {
        let velocities: [CGPoint] = [
            .zero,
            CGPoint(x: 5, y: 5),
            CGPoint(x: -5, y: 5),
            CGPoint(x: 5, y: -5),
            CGPoint(x: -5, y: -5),
            CGPoint(x: 0.001, y: -0.001),
        ]

        for velocity in velocities {
            XCTAssertEqual(
                TesseraGestureArbiter.axisDecision(forVelocity: velocity),
                .horizontal,
                "Expected horizontal for equal magnitudes \(velocity)"
            )
        }
    }

    // MARK: - Blocking several vertical children

    /// `prepareForHorizontalScroll` blocks all children, and
    /// `endHorizontalScroll` restores each one's original value: a child that
    /// was disabled initially stays disabled.
    func testPrepareBlocksAllChildrenAndEndRestoresStates() {
        let owner = makeScrollView()
        let first = makeScrollView(enabled: true)
        let second = makeScrollView(enabled: false)
        let third = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: owner,
            verticalOwners: [first, second, third]
        )

        arbiter.prepareForHorizontalScroll()
        XCTAssertFalse(first.isScrollEnabled)
        XCTAssertFalse(second.isScrollEnabled)
        XCTAssertFalse(third.isScrollEnabled)

        arbiter.endHorizontalScroll()
        XCTAssertTrue(first.isScrollEnabled)
        XCTAssertFalse(second.isScrollEnabled)
        XCTAssertTrue(third.isScrollEnabled)
    }

    /// The horizontal owner is excluded from the child list: its scrolling is not
    /// blocked even if it is passed in `verticalOwners`.
    func testHorizontalOwnerIsNeverBlocked() {
        let owner = makeScrollView(enabled: true)
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: owner,
            verticalOwners: [owner, child]
        )

        arbiter.prepareForHorizontalScroll()

        XCTAssertTrue(owner.isScrollEnabled)
        XCTAssertFalse(child.isScrollEnabled)

        arbiter.endHorizontalScroll()
        XCTAssertTrue(owner.isScrollEnabled)
        XCTAssertTrue(child.isScrollEnabled)
    }

    /// A repeated `prepareForHorizontalScroll` is idempotent: the snapshot is not
    /// overwritten and the original values are not lost.
    func testPrepareIsIdempotent() {
        let owner = makeScrollView()
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [child])

        arbiter.prepareForHorizontalScroll()
        arbiter.prepareForHorizontalScroll()
        XCTAssertFalse(child.isScrollEnabled)

        arbiter.endHorizontalScroll()
        XCTAssertTrue(child.isScrollEnabled)
    }

    /// `endHorizontalScroll` without a preceding `prepare` is a no-op.
    func testEndWithoutPrepareIsNoOp() {
        let owner = makeScrollView()
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [child])

        arbiter.endHorizontalScroll()

        XCTAssertTrue(child.isScrollEnabled)
    }

    /// A repeated `endHorizontalScroll` is a no-op: the children's state is no longer
    /// overwritten after restoration.
    func testEndTwiceIsNoOp() {
        let owner = makeScrollView()
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [child])

        arbiter.prepareForHorizontalScroll()
        arbiter.endHorizontalScroll()
        child.isScrollEnabled = true

        arbiter.endHorizontalScroll()

        XCTAssertTrue(child.isScrollEnabled)
    }

    /// Duplicates of the same child do not break state restoration.
    func testDuplicateChildrenAreSafe() {
        let owner = makeScrollView()
        let child = makeScrollView(enabled: false)
        let arbiter = TesseraGestureArbiter(
            horizontalOwner: owner,
            verticalOwners: [child, child, child]
        )

        arbiter.prepareForHorizontalScroll()
        XCTAssertFalse(child.isScrollEnabled)

        arbiter.endHorizontalScroll()
        XCTAssertFalse(child.isScrollEnabled)
    }

    /// An empty child list: blocking and restoring are no-ops, and the owner
    /// stays active.
    func testEmptyVerticalOwnersAreSafe() {
        let owner = makeScrollView()
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [])

        arbiter.prepareForHorizontalScroll()

        // The owner is not in the child list and is not blocked.
        XCTAssertTrue(owner.isScrollEnabled)

        arbiter.endHorizontalScroll()
        XCTAssertTrue(owner.isScrollEnabled)
    }

    // MARK: - UIGestureRecognizerDelegate

    /// The arbiter does not restrict foreign gestures: it returns `true`.
    func testShouldBeginReturnsTrueForForeignGesture() {
        let owner = makeScrollView()
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [])
        let tap = UITapGestureRecognizer()

        XCTAssertTrue(arbiter.shouldBegin(tap))
        XCTAssertTrue(arbiter.gestureRecognizerShouldBegin(tap))
    }

    /// A pan of the horizontal owner without movement is treated as horizontal
    /// (the equal-magnitude rule), so the gesture is allowed.
    func testShouldBeginForIdleOwnerPanDefaultsToHorizontal() {
        let owner = makeScrollView()
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [])

        XCTAssertTrue(arbiter.shouldBegin(owner.panGestureRecognizer))
        XCTAssertTrue(arbiter.gestureRecognizerShouldBegin(owner.panGestureRecognizer))
    }

    /// Blocking children does not disable scrolling of the pager itself.
    func testPrepareDoesNotDisableHorizontalOwner() {
        let owner = makeScrollView(enabled: true)
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [child])

        arbiter.prepareForHorizontalScroll()

        XCTAssertTrue(owner.isScrollEnabled)
    }
}

#endif
