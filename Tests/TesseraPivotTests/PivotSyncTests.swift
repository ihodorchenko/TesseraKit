//
//  PivotSyncTests.swift
//  TesseraPivotTests
//
//  Контрактные тесты синхронизации ленты и пейджера пивота (задача E2.7).
//  Проектный документ: docs/PIVOT-IOS-DESIGN.md §5 «Синхронизация ленты и
//  пейджера» (один источник истины и один писатель `contentOffset`:
//  свайп → лента без обратной записи, тап → `setContentOffset(animated:)`),
//  §4 «Математика ядра» (завершение перехода → выделение и автоцентрирование
//  ленты), §8 «Accessibility» (Reduce Motion отключает анимацию перехода,
//  VoiceOver-жест листает секции).
//
//  Проверки идут через публичный API (`selectSection(at:animated:)`,
//  `accessibilityScroll`, колбэки делегата) и `@testable`-доступ к ленте и
//  пейджеру; окно и прогон UI-цикла не нужны — вид загружается и
//  раскладывается вручную, как в контрактных тестах Core (D10).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPivot

/// Шпион делегата пивота: фиксирует порядок и значения всех трёх колбэков.
private final class PivotDelegateSpy: PivotDelegate {
    private(set) var selectedIndexes: [Int] = []
    private(set) var progressValues: [CGFloat] = []
    private(set) var shownIndexes: [Int] = []

    func pivot(_ pivot: PivotViewController, didSelectSectionAt index: Int) {
        selectedIndexes.append(index)
    }

    func pivot(_ pivot: PivotViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }

    func pivot(_ pivot: PivotViewController, didShowSectionAt index: Int) {
        shownIndexes.append(index)
    }
}

final class PivotSyncTests: XCTestCase {

    private let pivotSize = CGSize(width: 320, height: 640)

    // MARK: - Вспомогательные средства

    private func makeSections(count: Int) -> [PivotSection] {
        (0..<count).map { index in
            PivotSection(id: index, title: "Секция \(index)") {
                UIViewController()
            }
        }
    }

    /// Загружает пивот, задаёт размер и раскладывает его. Возвращает внутренний
    /// скролл-вью пейджера: он — единственный писатель `contentOffset` (§5).
    private func makeLoadedPivot(
        sectionCount: Int = 4
    ) throws -> (pivot: PivotViewController, scrollView: UIScrollView) {
        let pivot = PivotViewController(sections: makeSections(count: sectionCount))
        pivot.loadViewIfNeeded()
        pivot.view.frame = CGRect(origin: .zero, size: pivotSize)
        pivot.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            pivot.pagerViewController.view.subviews
                .compactMap { $0 as? UIScrollView }
                .first,
            "Пейджер пивота обязан содержать UIScrollView"
        )
        return (pivot, scrollView)
    }

    // MARK: - Компоновка и режим пейджера (§2, §3)

    /// Пивот использует пейджер Core в режиме `.paged`: снап даёт
    /// `isPagingEnabled`, кастомный снап не нужен (§2).
    func testPagerRunsInPagedMode() throws {
        let (pivot, scrollView) = try makeLoadedPivot()

        if case .paged = pivot.pagerViewController.mode {
            // Ожидаемый режим (docs/PIVOT-IOS-DESIGN.md §2).
        } else {
            XCTFail("Пивот должен работать в режиме .paged")
        }

        // Пейджер найден обходом иерархии для арбитража вертикального скролла (§6).
        XCTAssertTrue(pivot.pagerScrollView === scrollView)
        XCTAssertTrue(scrollView.isPagingEnabled)
    }

    /// Заголовки ленты — это заголовки секций в порядке чтения (§3).
    func testStripTitlesMirrorSections() throws {
        let (pivot, _) = try makeLoadedPivot(sectionCount: 4)

        XCTAssertEqual(pivot.headerStripView.titles, pivot.sections.map(\.title))
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 0)
    }

    // MARK: - Тап → переход (§5)

    /// Программный переход (тот же путь, которым пользуется тап) сразу ставит
    /// `contentOffset` на страницу, обновляет индекс и выделение ленты;
    /// пейджер сообщает о показанной секции.
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

    /// Индекс вне диапазона зажимается: 99 → последняя секция, -5 → первая.
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

    /// Тап по заголовку: лента сообщает намерение через `onSelect`, контроллер
    /// сначала уведомляет делегата и только потом переходит (§5). Синхронно
    /// проверяются намерение, индекс и выделение; завершение перехода при
    /// анимации приходит отдельным колбэком.
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

    /// Reduce Motion: при включённой системной настройке тап переходит без
    /// анимации — `contentOffset` ставится сразу и завершение приходит
    /// синхронно (§8, «прыжок по тапу — без анимации»). При выключенной
    /// настройке переход анимируется, поэтому синхронно проверяем только
    /// намерение и выделение: завершение придёт от пейджера на кадрах.
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

    // MARK: - Свайп → лента: без обратной записи в contentOffset (§5)

    /// Свайп (запись `contentOffset` самим скролл-вью) обновляет ленту через
    /// `didChangeProgress`, но обратной записи нет: offset остаётся ровно тем,
    /// что поставил жест.
    func testSwipeProgressUpdatesStripWithoutWritingContentOffset() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let pageWidth = scrollView.bounds.width

        scrollView.contentOffset = CGPoint(x: pageWidth * 1.5, y: 0)

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 1.5, accuracy: 0.5)
        XCTAssertEqual(pivot.currentSectionIndex, 2)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 2)
    }

    /// Колбэк прогресса, вызванный пейджером напрямую, — только чтение:
    /// `contentOffset` не меняется, выделение ленты следует за `t` (§5).
    func testProgressCallbackFromPagerIsReadOnly() throws {
        let (pivot, scrollView) = try makeLoadedPivot()
        let offsetBefore = scrollView.contentOffset

        pivot.pager(pivot.pagerViewController, didChangeProgress: 1.25)

        XCTAssertEqual(scrollView.contentOffset, offsetBefore)
        XCTAssertEqual(pivot.headerStripView.selectedIndex, 1)
        XCTAssertEqual(pivot.currentSectionIndex, 1)
    }

    /// Непрерывный прогресс пробрасывается внешнему делегату (§3).
    func testProgressIsForwardedToExternalDelegate() throws {
        let (pivot, _) = try makeLoadedPivot()
        let spy = PivotDelegateSpy()
        pivot.delegate = spy

        pivot.pager(pivot.pagerViewController, didChangeProgress: 1.5)

        XCTAssertEqual(spy.progressValues, [1.5])
    }

    /// Завершение перехода выделяет показанную секцию и доцентровывает ленту,
    /// но не двигает пейджер: `contentOffset` по-прежнему пишет только пейджер
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

    /// VoiceOver-жест «вперёд» в LTR уводит на следующую секцию, «назад» с
    /// первой секции не обрабатывается; жест идёт через тот же
    /// `selectSection(at:animated:)` — единственный программный писатель.
    func testAccessibilityScrollUsesSingleWriterInLTR() throws {
        let (pivot, _) = try makeLoadedPivot()

        // Конвенция UIKit (E9.3): в LTR свайп вправо — назад, влево — вперёд.
        XCTAssertFalse(pivot.accessibilityScroll(.right), "С первой секции назад некуда")
        XCTAssertTrue(pivot.accessibilityScroll(.left))
        XCTAssertEqual(pivot.currentSectionIndex, 1)
    }

    /// Reduce Motion читается в момент решения и не кешируется (§8): флаг
    /// компонента — это системная настройка, а не сохранённое значение.
    func testReduceMotionFlagIsLive() {
        XCTAssertEqual(
            TesseraAccessibility.isReduceMotionEnabled,
            UIAccessibility.isReduceMotionEnabled
        )
    }
}

#endif
