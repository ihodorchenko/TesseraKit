//
//  TesseraPagerTests.swift
//  TesseraCoreTests
//
//  Контрактные тесты пейджера (задача E1.7).
//  Проектный документ: docs/Core-iOS-Design.md §2 «Ключевые контракты»
//  (инвариант t, один писатель contentOffset, два режима пейджера, дисциплина
//  производительности) и §3 «Концептуальная поверхность API»
//  (TesseraPagerViewController, TesseraPageDescriptor, TesseraPagerDelegate).
//
//  Проверяются: конфигурация UIScrollView для режимов paged/snapping,
//  геометрия contentSize, программный переход go(toPage:), инвариант
//  t = contentOffset.x / pageWidth (LTR и RTL), интеграция снапа и ленивая
//  загрузка окна ±1. Тесты работают без окна и без прогона UI-цикла:
//  контроллер загружает вид и раскладывается вручную.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// Шпион делегата: фиксирует порядок и значения колбэков пейджера.
private final class TesseraPagerDelegateSpy: TesseraPagerDelegate {
    private(set) var shownIndexes: [Int] = []
    private(set) var progressValues: [CGFloat] = []

    var lastShownIndex: Int? { shownIndexes.last }
    var lastProgress: CGFloat? { progressValues.last }

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }

    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }
}

final class TesseraPagerTests: XCTestCase {

    private let pageWidth: CGFloat = 320
    private let pageHeight: CGFloat = 480

    // MARK: - Вспомогательные фабрики

    private func makePages(count: Int) -> [TesseraPageDescriptor] {
        (0..<count).map { (index: Int) -> TesseraPageDescriptor in
            TesseraPageDescriptor(id: index, title: "Страница \(index)") {
                UIViewController()
            }
        }
    }

    /// Загружает пейджер, задаёт размер вида, раскладывает и возвращает
    /// внутренний UIScrollView (единственный прямой потомок корневого вида).
    private func makeLoadedPager(
        mode: TesseraPagerMode = .paged,
        pageCount: Int
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: mode, pages: makePages(count: pageCount))
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first,
            "Пейджер обязан содержать UIScrollView"
        )
        return (pager, scrollView)
    }

    // MARK: - Конфигурация режимов

    /// `.paged`: включён `isPagingEnabled`, обычная децелерация, выключены
    /// индикаторы, делегат — сам пейджер.
    func testPagedModeConfiguresScrollView() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertTrue(scrollView.isPagingEnabled)
        XCTAssertEqual(scrollView.decelerationRate, .normal)
        XCTAssertEqual(scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(scrollView.showsHorizontalScrollIndicator)
        XCTAssertFalse(scrollView.showsVerticalScrollIndicator)
        XCTAssertTrue(scrollView.alwaysBounceHorizontal)
        XCTAssertTrue(scrollView.delegate === pager)
    }

    /// `.snapping`: `isPagingEnabled` выключен, децелерация `.fast` — снап
    /// выполняет `TesseraSnapPolicy` (Core §2, «Два режима пейджера»).
    func testSnappingModeConfiguresScrollView() throws {
        let pager = TesseraPagerViewController(mode: .snapping, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertFalse(scrollView.isPagingEnabled)
        XCTAssertEqual(scrollView.decelerationRate, .fast)
    }

    // MARK: - Геометрия

    /// `contentSize` — `pageWidth × pageCount` по горизонтали и высота вида.
    func testLayoutSetsContentSizeForAllPages() throws {
        let (_, scrollView) = try makeLoadedPager(pageCount: 4)

        XCTAssertEqual(scrollView.bounds.width, pageWidth)
        XCTAssertEqual(scrollView.contentSize.width, pageWidth * 4)
        XCTAssertEqual(scrollView.contentSize.height, pageHeight)
    }

    /// Страницы-дети получают полноширинный фрейм высотой со скролл-вью.
    func testLoadedPageFramesFillScrollView() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 3)

        XCTAssertEqual(pager.children.count, 2)
        for child in pager.children {
            XCTAssertEqual(child.view.frame.width, scrollView.bounds.width)
            XCTAssertEqual(child.view.frame.height, scrollView.bounds.height)
        }
    }

    /// Пустой набор страниц: `contentSize` нулевой, переход и accessibility
    /// не падают.
    func testEmptyPagerKeepsZeroContentSize() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 0)

        XCTAssertEqual(scrollView.contentSize, .zero)
        XCTAssertTrue(pager.children.isEmpty)

        pager.go(toPage: 0, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
        XCTAssertFalse(pager.accessibilityScroll(.right))
    }

    // MARK: - go(toPage:)

    /// Программный переход выставляет offset по индексу в порядке чтения (LTR):
    /// `index × pageWidth`, индекс клампится в границы набора.
    func testGoToPageSetsContentOffsetInLTR() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 4)

        pager.go(toPage: 2, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)

        pager.go(toPage: 3, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3)

        pager.go(toPage: 0, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
    }

    /// Индекс вне диапазона зажимается: 99 → последняя страница, -5 → первая.
    func testGoToPageClampsOutOfRangeIndexes() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 4)

        pager.go(toPage: 99, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3)

        pager.go(toPage: -5, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
    }

    /// Переход до загрузки вида запоминается и применяется на первом layout'е —
    /// без промежуточного скачка на первую страницу.
    func testPendingGoToPageIsAppliedOnFirstLayout() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 4))

        pager.go(toPage: 2, animated: false)

        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
    }

    /// Нулевая ширина вида откладывает переход до появления геометрии.
    func testGoToPageWithZeroWidthDefersUntilLayout() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 4))
        pager.loadViewIfNeeded()
        pager.view.frame = .zero
        pager.view.layoutIfNeeded()

        pager.go(toPage: 2, animated: false)

        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)
    }

    /// В RTL физический слот страницы зеркалится: индекс 0 — крайняя правая
    /// страница, `pageCount - 1` — крайняя левая (Core §2, инвариант t).
    func testGoToPageUsesMirroredSlotsInRTL() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 4))
        pager.loadViewIfNeeded()
        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )

        // Стартовая страница чтения 0 занимает физический слот 3.
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 3)

        pager.go(toPage: 1, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2)

        pager.go(toPage: 3, animated: false)
        XCTAssertEqual(scrollView.contentOffset.x, 0)
    }

    // MARK: - Инвариант t

    /// LTR: `t = contentOffset.x / pageWidth` без изменений; дробная часть —
    /// прогресс перехода (Core §2, «Инвариант прогресса»).
    func testProgressInLTRFollowsRawOffset() throws {
        let (pager, scrollView) = try makeLoadedPager(pageCount: 3)
        let spy = TesseraPagerDelegateSpy()
        pager.delegate = spy

        scrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 1, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 0, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth * 1.5, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 1.5, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth * 2, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 2, accuracy: 0.0001)
    }

    /// RTL: тот же сырой offset нормализуется от направления чтения:
    /// левый край — последняя страница чтения (Core §2, инвариант t).
    func testProgressInRTLIsMirroredToReadingDirection() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first
        )
        let spy = TesseraPagerDelegateSpy()
        pager.delegate = spy

        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 2, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 1, accuracy: 0.0001)

        scrollView.contentOffset = CGPoint(x: pageWidth * 2, y: 0)
        XCTAssertEqual(try XCTUnwrap(spy.lastProgress), 0, accuracy: 0.0001)
    }

    // MARK: - Интеграция снапа

    /// `.snapping`: целевой offset считается `TesseraSnapPolicy` от фактической
    /// ширины страницы и скорости жеста.
    func testSnappingModeAppliesSnapPolicy() throws {
        let (pager, scrollView) = try makeLoadedPager(mode: .snapping, pageCount: 3)

        var fastTarget = CGPoint(x: 100, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 1000, y: 0),
            targetContentOffset: &fastTarget
        )
        XCTAssertEqual(fastTarget.x, pageWidth)

        var slowTarget = CGPoint(x: 100, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &slowTarget
        )
        XCTAssertEqual(slowTarget.x, 0)

        var lastPageTarget = CGPoint(x: 500, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: .zero,
            targetContentOffset: &lastPageTarget
        )
        XCTAssertEqual(lastPageTarget.x, pageWidth * 2)
    }

    /// `.paged`: снап выполняет `isPagingEnabled`, метод делегата не меняет
    /// предложенный offset.
    func testPagedModeDoesNotOverrideProposedOffset() throws {
        let (pager, scrollView) = try makeLoadedPager(mode: .paged, pageCount: 3)

        var target = CGPoint(x: 100, y: 0)
        pager.scrollViewWillEndDragging(
            scrollView,
            withVelocity: CGPoint(x: 1000, y: 0),
            targetContentOffset: &target
        )

        XCTAssertEqual(target.x, 100)
    }

    // MARK: - Ленивая загрузка ±1

    /// В памяти держится текущая страница и соседи ±1; при переходе окно
    /// сдвигается, а освободившиеся контроллеры не пересоздаются повторно.
    func testLazyLoadingKeepsCurrentPageAndNeighbours() throws {
        var createdPages: [Int] = []
        let pages = (0..<5).map { (index: Int) -> TesseraPageDescriptor in
            TesseraPageDescriptor(id: index, title: "Страница \(index)") {
                createdPages.append(index)
                return UIViewController()
            }
        }

        let pager = TesseraPagerViewController(mode: .paged, pages: pages)
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()

        // Первая страница и её правый сосед.
        XCTAssertEqual(createdPages, [0, 1])
        XCTAssertEqual(pager.children.count, 2)

        // Переход на 3: окно 2...4, страницы 0 и 1 выгружаются.
        pager.go(toPage: 3, animated: false)
        XCTAssertEqual(createdPages, [0, 1, 2, 3, 4])
        XCTAssertEqual(pager.children.count, 3)

        // Переход на 4: нужны только 3 и 4, страница 2 выгружается.
        pager.go(toPage: 4, animated: false)
        XCTAssertEqual(createdPages, [0, 1, 2, 3, 4])
        XCTAssertEqual(pager.children.count, 2)
    }

    // MARK: - Делегат

    /// Мгновенный переход сообщает `didShowPageAt` ровно один раз.
    func testImmediateGoReportsShownPageOnce() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)
        let spy = TesseraPagerDelegateSpy()
        pager.delegate = spy

        pager.go(toPage: 1, animated: false)

        XCTAssertEqual(spy.shownIndexes, [1])
    }

    // MARK: - Accessibility

    /// Вертикальные направления и выход за границы в LTR не обрабатываются
    /// пейджером (pageStep = 0 или индекс за пределами набора).
    func testAccessibilityScrollRejectsVerticalAndOutOfBoundsGestures() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)

        XCTAssertFalse(pager.accessibilityScroll(.up))
        XCTAssertFalse(pager.accessibilityScroll(.down))
        // Первая страница: назад (свайп вправо в LTR) некуда.
        XCTAssertFalse(pager.accessibilityScroll(.right))
    }

    /// В LTR трёхпальцевый свайп влево уводит на следующую страницу
    /// (конвенция UIKit, E9.3), свайп вправо возвращает назад.
    ///
    /// Направление проверяется на границах набора, чтобы не зависеть от
    /// анимации перехода: с первой страницы вперёд можно, назад — нет;
    /// с последней — наоборот.
    func testAccessibilityScrollMovesForwardInLTR() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)

        XCTAssertTrue(pager.accessibilityScroll(.left), "Свайп влево в LTR листает вперёд")
    }

    /// В LTR свайп вправо листает назад: с последней страницы назад можно,
    /// вперёд (свайп влево) — нет.
    func testAccessibilityScrollMovesBackwardInLTR() throws {
        let (pager, _) = try makeLoadedPager(pageCount: 3)
        pager.go(toPage: 2, animated: false)

        XCTAssertFalse(pager.accessibilityScroll(.left), "С последней страницы вперёд некуда")
        XCTAssertTrue(pager.accessibilityScroll(.right), "Свайп вправо в LTR листает назад")
    }

    /// В RTL физическое направление инвертируется: с первой страницы жест
    /// «вправо» ведёт вперёд, «влево» — назад (за границу).
    func testAccessibilityScrollRespectsRTL() throws {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(count: 3))
        pager.loadViewIfNeeded()
        pager.view.semanticContentAttribute = .forceRightToLeft
        pager.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        pager.view.layoutIfNeeded()

        XCTAssertFalse(pager.accessibilityScroll(.left))
        XCTAssertTrue(pager.accessibilityScroll(.right))
    }
}

#endif
