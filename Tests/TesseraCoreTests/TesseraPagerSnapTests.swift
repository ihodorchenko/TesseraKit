//
//  TesseraPagerSnapTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты снапа пейджера в режиме `.snapping` (E10.11, E9.2а).
//  Проектный документ: docs/CORE-IOS-DESIGN.md §2 «Ключевые контракты»
//  («Два режима пейджера»: ближайший центр + порог скорости; «Один писатель»).
//
//  Проверяются: перевод скорости UIKit (points/ms) в pt/s политики; шаг ±1 от
//  страницы, с которой начался жест; доводка offset'а самим пейджером, когда
//  жест закончился без инерции на невыровненном offset'е.
//
//  Анимация `setContentOffset(_:animated:)` в тестовом процессе без приложения
//  ведёт себя по-разному (без окна UIKit завершает её синхронно), поэтому
//  тесты допускают оба исхода: синхронное завершение либо имитацию конца
//  анимации вызовом `scrollViewDidEndScrollingAnimation`.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// Шпион делегата: индексы показанных страниц.
private final class SnapDelegateSpy: TesseraPagerDelegate {
    var shownIndexes: [Int] = []

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }
}

final class TesseraPagerSnapTests: XCTestCase {

    private let pageWidth: CGFloat = 320
    private let pageHeight: CGFloat = 480

    // MARK: - Вспомогательные средства

    private func makePages(count: Int) -> [TesseraPageDescriptor] {
        (0..<count).map { index in
            TesseraPageDescriptor(id: index, title: "Страница \(index)") { UIViewController() }
        }
    }

    private func makeLoadedPager(
        mode: TesseraPagerMode = .snapping,
        pageCount: Int = 5
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: mode, pages: makePages(count: pageCount))
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )
        return (pager, scrollView)
    }

    /// Имитирует жест: старт на `start`, протяжка до `end`, отпускание со
    /// скоростью UIKit `velocity` (points/ms) и предложенной целью `proposed`.
    /// Возвращает цель, которую пейджер подставил системе.
    @discardableResult
    private func drag(
        _ pager: TesseraPagerViewController,
        _ scrollView: UIScrollView,
        from start: CGFloat,
        to end: CGFloat,
        velocity: CGFloat,
        proposed: CGFloat
    ) -> CGFloat {
        scrollView.contentOffset = CGPoint(x: start, y: 0)
        pager.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: end, y: 0)
        var target = CGPoint(x: proposed, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: velocity, y: 0),
            targetContentOffset: &target
        )
        return target.x
    }

    // MARK: - Единицы скорости и стартовая страница (E10.11)

    /// Протяжка 50 и флик 1 pt/ms (= 1000 pt/s > порога 600): соседняя
    /// страница. До перевода единиц 1 «pt/s» было ниже порога — откат.
    func testShortFastFlickMovesToNeighbourPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        let target = drag(pager, scrollView, from: 0, to: 50, velocity: 1, proposed: 149)

        XCTAssertEqual(target, pageWidth)
    }

    /// Старт 0, протяжка 100, флик 3 pt/ms (инерция предлагает ≈397):
    /// страница 1, а не 2 — шаг от страницы начала жеста.
    func testStrongFlickDoesNotSkipPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        let target = drag(pager, scrollView, from: 0, to: 100, velocity: 3, proposed: 397)

        XCTAssertEqual(target, pageWidth)
    }

    /// Флик назад со страницы 2: страница 1, а не 0.
    func testStrongBackwardFlickDoesNotSkipPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        let target = drag(pager, scrollView, from: 640, to: 540, velocity: -3, proposed: 243)

        XCTAssertEqual(target, pageWidth)
    }

    /// Медленный жест (0,4 pt/ms = 400 pt/s): ближайшая страница.
    func testSlowDragSnapsToNearestPage() throws {
        let (pager, scrollView) = try makeLoadedPager()

        XCTAssertEqual(drag(pager, scrollView, from: 0, to: 50, velocity: 0.4, proposed: 90), 0)
        XCTAssertEqual(drag(pager, scrollView, from: 0, to: 200, velocity: 0.4, proposed: 240), pageWidth)
    }

    /// Стартовый offset одного жеста не переносится на следующий.
    func testStartOffsetIsConsumedByOneGesture() throws {
        let (pager, scrollView) = try makeLoadedPager()
        drag(pager, scrollView, from: 0, to: 100, velocity: 3, proposed: 397)

        // Следующий «жест» без willBeginDragging: опора — ближайшая к proposed.
        var target = CGPoint(x: 397, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 3, y: 0),
            targetContentOffset: &target
        )
        XCTAssertEqual(target.x, pageWidth * 2)
    }

    // MARK: - Доводка без инерции (E9.2а)

    /// Жест закончился без скорости на невыровненном offset'е: UIKit не
    /// двигает offset к цели, пейджер сам запускает анимацию к ближайшей
    /// странице и завершает переход по её окончании.
    func testDragWithoutVelocityAlignsOffset() throws {
        let (pager, scrollView) = try makeLoadedPager()
        let spy = SnapDelegateSpy()
        pager.delegate = spy
        pager.go(toPage: 0, animated: false)
        spy.shownIndexes.removeAll()

        let target = drag(pager, scrollView, from: 0, to: 200, velocity: 0, proposed: 200)
        XCTAssertEqual(target, pageWidth)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        // Пейджер сам повёл offset к странице 1: без окна UIKit завершает
        // анимацию синхронно; иначе имитируем её конец.
        XCTAssertTrue(spy.shownIndexes.allSatisfy { $0 == 1 })
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, "offset не выровнен после drag без скорости")
        if spy.shownIndexes.isEmpty {
            scrollView.setContentOffset(CGPoint(x: pageWidth, y: 0), animated: false)
            pager.scrollViewDidEndScrollingAnimation(scrollView)
        }

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
        XCTAssertEqual(spy.shownIndexes, [1])
    }

    /// Уже выровненный offset: доводка не нужна, переход завершается сразу.
    func testDragEndingAlignedFinishesImmediately() throws {
        let (pager, scrollView) = try makeLoadedPager()
        let spy = SnapDelegateSpy()
        pager.delegate = spy

        drag(pager, scrollView, from: 0, to: pageWidth, velocity: 0, proposed: pageWidth)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertEqual(spy.shownIndexes, [1])
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth)
    }

    /// `.paged`: доводку выполняет `isPagingEnabled`, пейджер завершает
    /// переход сразу и offset не трогает.
    func testPagedModeDoesNotAlignAfterDrag() throws {
        let (pager, scrollView) = try makeLoadedPager(mode: .paged)
        let spy = SnapDelegateSpy()
        pager.delegate = spy

        drag(pager, scrollView, from: 0, to: 100, velocity: 0, proposed: 100)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)

        XCTAssertEqual(scrollView.contentOffset.x, 100)
        XCTAssertEqual(spy.shownIndexes, [0])
    }
}

#endif
