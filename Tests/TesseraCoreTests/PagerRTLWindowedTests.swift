//
//  PagerRTLWindowedTests.swift
//  TesseraCoreTests
//
//  Покрытие E9.10 (W5-B): пейджер Core в настоящем `UIWindow` с принудительным
//  направлением чтения (`semanticContentAttribute = .forceRightToLeft`) и
//  LTR-контраст.
//  Проектный документ: docs/CORE-IOS-DESIGN.md §2 «Ключевые контракты»
//  (инвариант `t = contentOffset.x / pageWidth` с нормализацией по направлению
//  чтения; один писатель `contentOffset`) и §1/§3 (`TesseraAccessibility`:
//  `accessibilityScroll` в RTL инвертирует физические `.left`/`.right`).
//
//  Что проверяется (в окне, с реальными child-контроллерами и layout):
//  - экранный порядок: в RTL страница чтения 0 занимает крайний правый
//    физический слот (`pageCount − 1 − index`), в LTR — левый;
//  - выравнивание: offset страницы чтения 0 в RTL — правый край ленты
//    (`contentSize.width − bounds.width`), в LTR — `0`;
//  - прогресс по направлению чтения: `TesseraRTL.normalizedProgress`
//    (в RTL `t = (pageCount − 1) − raw`, в LTR — без изменений);
//  - `accessibilityScroll` в RTL: `.right` листает вперёд по порядку чтения,
//    `.left` — назад; на границах жест возвращает `false`; в LTR — обратное
//    соответствие (конвенция UIKit: `.left` — вперёд).
//
//  Детерминизм: layout форсируется `layoutIfNeeded`, а конец программной
//  анимации `setContentOffset(_:animated:)` (в тестовом процессе без дисплея
//  может не наступить) эмулируется постановкой offset'а и вызовом
//  `scrollViewDidEndScrollingAnimation` — тот же приём, что в
//  TesseraPagerReloadTests. Sleep и ожидание run loop не используются.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

// MARK: - Контроллер страницы с идентификатором

/// Страница пейджера: идентификатор позволяет проверить, в каком физическом
/// слоте оказался порядок чтения.
private final class WindowedRLTPageController: UIViewController {
    let pageID: String

    init(pageID: String) {
        self.pageID = pageID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Шпион делегата пейджера

/// Шпион делегата пейджера: показы и прогресс вместе с сырым offset'ом.
///
/// Сам `scrollView` пейджера приватный, поэтому сырой offset в момент колбэка
/// снимается переданным замыканием.
private final class WindowedPagerSpy: TesseraPagerDelegate {
    private let rawOffsetProvider: () -> CGFloat

    private(set) var shownIndexes: [Int] = []
    private(set) var progressValues: [CGFloat] = []
    private(set) var progressRawOffsets: [CGFloat] = []

    init(rawOffsetProvider: @escaping () -> CGFloat) {
        self.rawOffsetProvider = rawOffsetProvider
    }

    func pager(_ pager: TesseraPagerViewController, didShowPageAt index: Int) {
        shownIndexes.append(index)
    }

    func pager(_ pager: TesseraPagerViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
        progressRawOffsets.append(rawOffsetProvider())
    }

    /// Сбрасывает записанные события.
    ///
    /// Нужен, чтобы отделить начальный показ страницы (контракт первого показа,
    /// не являющийся переходом) от событий самого теста.
    func clearRecordedEvents() {
        shownIndexes.removeAll()
        progressValues.removeAll()
        progressRawOffsets.removeAll()
    }
}

final class PagerRTLWindowedTests: XCTestCase {

    private var window: UIWindow?

    /// Окно 320×480: одна страница пейджера — на всю ширину (полностраничный
    /// режим `.paged`).
    private let pageSize = CGSize(width: 320, height: 480)
    private let pageCount = 3
    private var pageWidth: CGFloat { pageSize.width }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Вспомогательные средства

    private func makePages(ids: [String]) -> [TesseraPageDescriptor] {
        ids.map { id in
            TesseraPageDescriptor(id: id, title: id) {
                WindowedRLTPageController(pageID: id)
            }
        }
    }

    /// Пейджер в настоящем окне с принудительным направлением чтения.
    private func makeWindowedPager(
        ids: [String],
        direction: UIUserInterfaceLayoutDirection
    ) throws -> (pager: TesseraPagerViewController, scrollView: UIScrollView) {
        let pager = TesseraPagerViewController(mode: .paged, pages: makePages(ids: ids))
        let window = UIWindow(frame: CGRect(origin: .zero, size: pageSize))
        // Направление задаётся и окну, и корневому виду: результат не должен
        // зависеть от языка/направления симулятора.
        window.semanticContentAttribute = direction == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        window.rootViewController = pager
        window.isHidden = false
        self.window = window

        pager.view.semanticContentAttribute = direction == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        pager.view.frame = CGRect(origin: .zero, size: pageSize)
        pager.view.layoutIfNeeded()

        // Предусловие всех проверок: направление действительно применилось.
        XCTAssertEqual(
            pager.view.effectiveUserInterfaceLayoutDirection,
            direction,
            "направление чтения не применилось к виду пейджера"
        )

        let scrollView = try XCTUnwrap(
            pager.view.subviews.compactMap { $0 as? UIScrollView }.first,
            "Пейджер обязан содержать UIScrollView"
        )
        return (pager, scrollView)
    }

    private func pageController(
        _ id: String,
        in pager: TesseraPagerViewController
    ) throws -> WindowedRLTPageController {
        try XCTUnwrap(
            pager.children
                .compactMap { $0 as? WindowedRLTPageController }
                .first { $0.pageID == id },
            "Страница \(id) не загружена пейджером"
        )
    }

    private func loadedPageIDs(_ pager: TesseraPagerViewController) -> Set<String> {
        Set(pager.children.compactMap { ($0 as? WindowedRLTPageController)?.pageID })
    }

    /// Доводит программную анимацию offset'а до цели, если UIKit не завершил
    /// её синхронно в тестовом процессе. Повторный конец перехода идемпотентен:
    /// пейджер подавляет дубль `didShowPageAt` (lastShownPageIndex).
    private func completeAnimationIfNeeded(
        _ pager: TesseraPagerViewController,
        scrollView: UIScrollView,
        to targetX: CGFloat
    ) {
        if abs(scrollView.contentOffset.x - targetX) > 0.001 {
            scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        }
        pager.scrollViewDidEndScrollingAnimation(scrollView)
    }

    /// Прогресс в порядке чтения по сырому offset'у — тем же контрактом Core,
    /// которым обязан пользоваться пейджер.
    private func expectedProgress(
        rawOffsetX: CGFloat,
        direction: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        TesseraRTL.normalizedProgress(
            rawOffsetX / pageWidth,
            pageCount: pageCount,
            layoutDirection: direction
        )
    }

    // MARK: - Экранный порядок страниц

    /// RTL: порядок чтения зеркалится в физических слотах — страница чтения 0
    /// стоит в крайнем правом слоте (`pageCount − 1 − index`), страница 2 —
    /// в левом. Ширина окна и полноширинные страницы проверяются здесь же.
    func testRTLLayoutPlacesReadingPageZeroAtRightEdge() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )

        XCTAssertEqual(scrollView.bounds.width, pageWidth, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentSize.width, pageWidth * 3, accuracy: 0.001)
        XCTAssertEqual(pager.currentPageIndex, 0)
        // Лента разложена зеркально; страница чтения 0 выровнена у правого края.
        XCTAssertEqual(
            scrollView.contentOffset.x,
            scrollView.contentSize.width - scrollView.bounds.width,
            accuracy: 0.001,
            "в RTL выравнивание страницы чтения 0 — правый край ленты"
        )
        XCTAssertEqual(loadedPageIDs(pager), ["A", "B"], "в памяти текущая страница и сосед ±1")

        // Переход на страницу 1 догружает весь набор из трёх и даёт проверить
        // кадры всех слотов.
        pager.go(toPage: 1, animated: false)
        pager.view.layoutIfNeeded()

        let a = try pageController("A", in: pager)
        let b = try pageController("B", in: pager)
        let c = try pageController("C", in: pager)
        XCTAssertEqual(a.view.frame.minX, pageWidth * 2, accuracy: 0.001, "страница чтения 0 — правый слот")
        XCTAssertEqual(b.view.frame.minX, pageWidth, accuracy: 0.001)
        XCTAssertEqual(c.view.frame.minX, 0, accuracy: 0.001, "страница чтения 2 — левый слот")
        for controller in [a, b, c] {
            XCTAssertEqual(controller.view.frame.width, pageWidth, accuracy: 0.001)
            XCTAssertEqual(controller.view.frame.height, pageSize.height, accuracy: 0.001)
        }
        XCTAssertTrue(a.view.superview === scrollView)
    }

    /// LTR-контраст: та же троица страниц лежит в порядке чтения слева направо.
    func testLTRLayoutPlacesReadingPageZeroAtLeftEdge() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .leftToRight
        )

        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)
        pager.go(toPage: 1, animated: false)
        pager.view.layoutIfNeeded()

        let a = try pageController("A", in: pager)
        let b = try pageController("B", in: pager)
        let c = try pageController("C", in: pager)
        XCTAssertEqual(a.view.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(b.view.frame.minX, pageWidth, accuracy: 0.001)
        XCTAssertEqual(c.view.frame.minX, pageWidth * 2, accuracy: 0.001)
    }

    /// RTL: выравнивание по порядку чтения — страница 0 у правого края,
    /// страница 2 у левого, страница 1 — в середине; в каждом случае offset
    /// равен левому краю видимой страницы.
    func testRTLAlignmentOffsetsFollowReadingOrder() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )

        // После первого layout уже показана страница чтения 0 (правый край).
        pager.go(toPage: 0, animated: false)
        pager.view.layoutIfNeeded()
        let a = try pageController("A", in: pager)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.001)
        XCTAssertEqual(a.view.frame.minX, scrollView.contentOffset.x, accuracy: 0.001)

        pager.go(toPage: 2, animated: false)
        pager.view.layoutIfNeeded()
        let c = try pageController("C", in: pager)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001, "страница чтения 2 — у левого края")
        XCTAssertEqual(c.view.frame.minX, 0, accuracy: 0.001)

        pager.go(toPage: 1, animated: false)
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pager.currentPageIndex, 1)
    }

    // MARK: - Нормализованный прогресс

    /// RTL: прогресс делегата нормализован по направлению чтения —
    /// `0` у страницы чтения 0 (правый край) и `pageCount − 1` у последней.
    func testRTLProgressIsNormalizedByReadingDirection() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (pageWidth * 2, 0),
            (pageWidth * 1.5, 0.5),
            (pageWidth, 1),
            (pageWidth * 0.5, 1.5),
            (0, 2),
        ]

        for entry in cases {
            scrollView.contentOffset = CGPoint(x: entry.raw, y: 0)
            pager.scrollViewDidScroll(scrollView)

            let value = try XCTUnwrap(spy.progressValues.last)
            XCTAssertEqual(value, entry.expected, accuracy: 0.000_001, "RTL-прогресс для offset \(entry.raw)")
            XCTAssertEqual(
                value,
                expectedProgress(rawOffsetX: entry.raw, direction: .rightToLeft),
                accuracy: 0.000_001,
                "пейджер должен нормализовать t через TesseraRTL"
            )
        }
        XCTAssertEqual(spy.progressValues.count, spy.progressRawOffsets.count)
    }

    /// LTR-контраст: сырой `t` отдаётся без зеркалирования.
    func testLTRProgressMatchesRawOffset() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .leftToRight
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy

        let cases: [(raw: CGFloat, expected: CGFloat)] = [
            (0, 0),
            (pageWidth * 0.5, 0.5),
            (pageWidth, 1),
            (pageWidth * 1.5, 1.5),
            (pageWidth * 2, 2),
        ]

        for entry in cases {
            scrollView.contentOffset = CGPoint(x: entry.raw, y: 0)
            pager.scrollViewDidScroll(scrollView)

            let value = try XCTUnwrap(spy.progressValues.last)
            XCTAssertEqual(value, entry.expected, accuracy: 0.000_001, "LTR-прогресс для offset \(entry.raw)")
            XCTAssertEqual(
                value,
                expectedProgress(rawOffsetX: entry.raw, direction: .leftToRight),
                accuracy: 0.000_001
            )
        }
    }

    /// Показы страниц без начального показа 0.
    ///
    /// Пейджер публикует страницу 0 при первом появлении (контракт первого
    /// показа: страница видима, хотя перехода не было). В windowed-окружении
    /// это событие может прийти и после «прогрева» — например, при первом
    /// программном завершении перехода. Тест проверяет только новые показы,
    /// вызванные accessibilityScroll, поэтому начальный 0 отбрасывается; ошибка
    /// «вместо целевой страницы показана 0» всё равно поймается следующей
    /// проверкой последовательности.
    private func pageShows(_ spy: WindowedPagerSpy) -> [Int] {
        var shows = spy.shownIndexes
        if shows.first == 0 {
            shows.removeFirst()
        }
        return shows
    }

    // MARK: - accessibilityScroll в RTL и LTR

    /// RTL: физические направления трёхпальцевого свайпа инвертированы —
    /// `.right` листает вперёд по порядку чтения (вправо = к предыдущему
    /// физическому слоту), `.left` — назад. На границах жест не обрабатывается.
    func testRTLAccessibilityScrollInvertsPhysicalDirections() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .rightToLeft
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy
        XCTAssertEqual(pager.currentPageIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.001)

        // Начальный показ страницы 0 — контракт первого показа, не переход.
        // «Прогреваем» его на текущей странице и очищаем рекордер: дальше
        // проверяются ровно новые показы, вызванные accessibilityScroll.
        pager.go(toPage: 0, animated: false)
        XCTAssertTrue(
            spy.shownIndexes.isEmpty || spy.shownIndexes == [0],
            "до жестов возможен только начальный показ 0: \(spy.shownIndexes)"
        )
        spy.clearRecordedEvents()

        // Страница чтения 0: предыдущей нет, следующая — 1.
        XCTAssertFalse(pager.accessibilityScroll(.left), "в RTL .left — назад, предыдущей страницы нет")
        XCTAssertTrue(pager.accessibilityScroll(.right), "в RTL .right — вперёд по порядку чтения")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1], "на один accessibilityScroll — ровно один новый показ")

        // Последняя страница чтения (2): следующей нет, предыдущая — 1.
        pager.go(toPage: 2, animated: false)
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)
        XCTAssertFalse(pager.accessibilityScroll(.right), "в RTL .right — вперёд, последней страницы нет")
        XCTAssertTrue(pager.accessibilityScroll(.left), "в RTL .left — назад по порядку чтения")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1, 2, 1], "на каждый accessibilityScroll — ровно один новый показ")
    }

    /// LTR-контраст: `.left` листает вперёд, `.right` — назад; на границах
    /// жест не обрабатывается (конвенция UIKit, как у `UIPageViewController`).
    func testLTRAccessibilityScrollKeepsPhysicalDirections() throws {
        let (pager, scrollView) = try makeWindowedPager(
            ids: ["A", "B", "C"],
            direction: .leftToRight
        )
        let spy = WindowedPagerSpy { scrollView.contentOffset.x }
        pager.delegate = spy
        XCTAssertEqual(pager.currentPageIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.001)

        // Начальный показ страницы 0 — контракт первого показа, не переход.
        // «Прогреваем» его на текущей странице и очищаем рекордер: дальше
        // проверяются ровно новые показы, вызванные accessibilityScroll.
        pager.go(toPage: 0, animated: false)
        XCTAssertTrue(
            spy.shownIndexes.isEmpty || spy.shownIndexes == [0],
            "до жестов возможен только начальный показ 0: \(spy.shownIndexes)"
        )
        spy.clearRecordedEvents()

        XCTAssertFalse(pager.accessibilityScroll(.right), "в LTR .right — назад, предыдущей страницы нет")
        XCTAssertTrue(pager.accessibilityScroll(.left), "в LTR .left — вперёд")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1], "на один accessibilityScroll — ровно один новый показ")

        pager.go(toPage: 2, animated: false)
        pager.view.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth * 2, accuracy: 0.001)
        XCTAssertFalse(pager.accessibilityScroll(.left), "в LTR .left — вперёд, последней страницы нет")
        XCTAssertTrue(pager.accessibilityScroll(.right), "в LTR .right — назад")
        completeAnimationIfNeeded(pager, scrollView: scrollView, to: pageWidth)
        XCTAssertEqual(pager.currentPageIndex, 1)
        XCTAssertEqual(scrollView.contentOffset.x, pageWidth, accuracy: 0.001)
        XCTAssertEqual(pageShows(spy), [1, 2, 1], "на каждый accessibilityScroll — ровно один новый показ")
    }
}

#endif
