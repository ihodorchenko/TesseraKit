//
//  PanoScrollViewVelocityTests.swift
//  TesseraPanoramaTests
//
//  Место вызова снапа в панораме (E10.11, волна W1): `PanoScrollView` получает
//  скорость от UIKit в points/ms, переводит её в pt/s (`× 1000`) для
//  `TesseraSnapPolicy` и передаёт стартовый offset жеста из
//  `scrollViewWillBeginDragging`, чтобы шаг ±1 считался от секции начала жеста.
//  Проектный документ: docs/PANORAMA-IOS-DESIGN.md §4 «Геометрия и математика
//  ядра» (снап: ближайший центр + порог скорости) и раздел «Отступления
//  реализации».
//
//  Регрессии, которые ловят тесты:
//  - без перевода единиц короткий быстрый флик (1 pt/ms = 1000 pt/s) ниже
//    порога 600 pt/s и откатывается на секцию 0;
//  - без опоры на стартовую секцию шаг считается от `nearest(proposed)` и
//    перескакивает через секцию (цель 2 вместо 1).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPanorama

final class PanoScrollViewVelocityTests: XCTestCase {

    /// Ширина экрана (как в `PanoSnapTests`).
    private let screenWidth: CGFloat = 390

    /// Peek (§4: 16…64 pt); шаг секции — `390 − 48 = 342` pt.
    private let peek: CGFloat = 48

    // MARK: - Вспомогательные средства

    private func makeScrollView(sectionCount: Int = 4) -> PanoScrollView {
        let scrollView = PanoScrollView(peek: peek)
        scrollView.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 700)
        scrollView.sectionCount = sectionCount
        scrollView.contentSize = scrollView.requiredContentSize
        return scrollView
    }

    /// Проигрывает жест так, как его отдаёт UIKit: начало drag на `startX`,
    /// протяжка до `startX + dragDistance`, окончание drag со скоростью
    /// `velocityPointsPerMs` (points/ms). Если `proposedX` не задан, предложенная
    /// цель оценивается по формуле инерции UIKit:
    /// `offset + v × r / (1 − r)`, где `r` — `decelerationRate` скролла (`.fast`).
    ///
    /// - Returns: цель снапа, записанная скролл-вью в `targetContentOffset`.
    private func simulateDrag(
        _ scrollView: PanoScrollView,
        startX: CGFloat = 0,
        dragDistance: CGFloat,
        velocityPointsPerMs: CGFloat,
        proposedX: CGFloat? = nil
    ) -> CGFloat {
        scrollView.contentOffset = CGPoint(x: startX, y: 0)
        scrollView.scrollViewWillBeginDragging(scrollView)

        let releaseX = startX + dragDistance
        scrollView.contentOffset = CGPoint(x: releaseX, y: 0)

        let rate = scrollView.decelerationRate.rawValue
        let inertia = velocityPointsPerMs * rate / (1 - rate)
        var target = CGPoint(x: proposedX ?? (releaseX + inertia), y: 0)
        scrollView.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: velocityPointsPerMs, y: 0),
            targetContentOffset: &target
        )
        return target.x
    }

    // MARK: - Тесты

    /// Протяжка ~100 pt от секции 0 и отпускание на 3 pt/ms (3000 pt/s):
    /// цель — ровно секция 1. Ни перескока на секцию 2 (шаг от
    /// `nearest(proposed)`), ни отката на 0.
    func testFastFlickFromFirstSectionLandsOnNextSection() {
        let scrollView = makeScrollView()
        let itemWidth = scrollView.itemWidth
        XCTAssertEqual(itemWidth, screenWidth - peek, accuracy: 0.000_001)

        let target = simulateDrag(
            scrollView,
            dragDistance: 100,
            velocityPointsPerMs: 3
        )

        XCTAssertEqual(target, itemWidth, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: target), 1)
    }

    /// Та же протяжка, но система предложила цель с длинной инерцией (около
    /// секции 2): один жест всё равно сдвигает не дальше чем на одну секцию от
    /// стартовой.
    func testFastFlickWithLongInertiaDoesNotSkipSection() {
        let scrollView = makeScrollView()
        let itemWidth = scrollView.itemWidth

        let target = simulateDrag(
            scrollView,
            dragDistance: 100,
            velocityPointsPerMs: 3,
            proposedX: 2 * itemWidth
        )

        XCTAssertEqual(target, itemWidth, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: target), 1)
    }

    /// Короткий флик: 50 pt и 1 pt/ms (1000 pt/s > порога 600 pt/s). Ближайшая к
    /// предложенной цели секция — 0, но скорость выше порога: цель — секция 1.
    /// Без перевода points/ms → pt/s флик откатился бы назад.
    func testShortQuickFlickAdvancesToNextSection() {
        let scrollView = makeScrollView()
        let itemWidth = scrollView.itemWidth

        let target = simulateDrag(
            scrollView,
            dragDistance: 50,
            velocityPointsPerMs: 1
        )

        XCTAssertEqual(target, itemWidth, accuracy: 0.000_001)
        XCTAssertEqual(scrollView.readingIndex(forRawOffset: target), 1)
    }
}

#endif
