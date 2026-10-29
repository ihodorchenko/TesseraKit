//
//  TesseraGestureArbiterTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты арбитража жестов (задача E1.7).
//  Проектный документ: docs/Core-iOS-Design.md §2 «Ключевые контракты»
//  (пункт «Арбитраж»: горизонталь — пейджеру, вертикаль — ребёнку; решение по
//  доминирующей оси) и §3 «Концептуальная поверхность API»
//  (TesseraGestureArbiter — регистрация детей, решение по осям).
//
//  Проверяются чистое решение по оси, блокировка нескольких вертикальных
//  детей на время горизонтального жеста и восстановление исходных значений
//  `isScrollEnabled` без UI-цикла.
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

    // MARK: - axisDecision: чистое решение по оси

    /// Горизонталь побеждает, когда модуль `dx` строго больше модуля `dy`.
    /// Знак скорости на выбор оси не влияет — сравниваются модули.
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
                "Ожидалась горизонталь для velocity \(velocity)"
            )
        }
    }

    /// Вертикаль побеждает, когда модуль `dy` строго больше модуля `dx`.
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
                "Ожидалась вертикаль для velocity \(velocity)"
            )
        }
    }

    /// При равенстве модулей (включая нулевую скорость) осознанно выбирается
    /// горизонталь: без данных о доминировании жест остаётся у пейджера.
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
                "Ожидалась горизонталь при равенстве модулей \(velocity)"
            )
        }
    }

    // MARK: - Блокировка нескольких вертикальных детей

    /// `prepareForHorizontalScroll` блокирует всех детей, а
    /// `endHorizontalScroll` возвращает каждому исходное значение: изначально
    /// выключенный ребёнок остаётся выключенным.
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

    /// Горизонтальный владелец исключается из списка детей: его прокрутка не
    /// блокируется даже если он передан в `verticalOwners`.
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

    /// Повторный `prepareForHorizontalScroll` идемпотентен: снимок не
    /// перезаписывается, исходные значения не теряются.
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

    /// `endHorizontalScroll` без предшествующего `prepare` — no-op.
    func testEndWithoutPrepareIsNoOp() {
        let owner = makeScrollView()
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [child])

        arbiter.endHorizontalScroll()

        XCTAssertTrue(child.isScrollEnabled)
    }

    /// Повторный `endHorizontalScroll` — no-op: состояние детей после
    /// восстановления больше не перезаписывается.
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

    /// Дубли одного и того же ребёнка не ломают восстановление состояния.
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

    /// Пустой список детей: блокировка и восстановление — no-op, владелец
    /// остаётся активным.
    func testEmptyVerticalOwnersAreSafe() {
        let owner = makeScrollView()
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [])

        arbiter.prepareForHorizontalScroll()

        // Владелец не входит в список детей и не блокируется.
        XCTAssertTrue(owner.isScrollEnabled)

        arbiter.endHorizontalScroll()
        XCTAssertTrue(owner.isScrollEnabled)
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Чужие жесты арбитр не ограничивает: возвращается `true`.
    func testShouldBeginReturnsTrueForForeignGesture() {
        let owner = makeScrollView()
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [])
        let tap = UITapGestureRecognizer()

        XCTAssertTrue(arbiter.shouldBegin(tap))
        XCTAssertTrue(arbiter.gestureRecognizerShouldBegin(tap))
    }

    /// Пан горизонтального владельца без движения трактуется как горизонталь
    /// (правило равенства модулей) — жест разрешён.
    func testShouldBeginForIdleOwnerPanDefaultsToHorizontal() {
        let owner = makeScrollView()
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [])

        XCTAssertTrue(arbiter.shouldBegin(owner.panGestureRecognizer))
        XCTAssertTrue(arbiter.gestureRecognizerShouldBegin(owner.panGestureRecognizer))
    }

    /// Блокировка детей не выключает прокрутку самого пейджера.
    func testPrepareDoesNotDisableHorizontalOwner() {
        let owner = makeScrollView(enabled: true)
        let child = makeScrollView(enabled: true)
        let arbiter = TesseraGestureArbiter(horizontalOwner: owner, verticalOwners: [child])

        arbiter.prepareForHorizontalScroll()

        XCTAssertTrue(owner.isScrollEnabled)
    }
}

#endif
