//
//  PivotTransitionTests.swift
//  TesseraPivotTests
//
//  Контрактные тесты переходов пивота и геометрии ленты по ревью E9/E10
//  (задачи E9.6, E10.12а).
//  Проектный документ: docs/PIVOT-IOS-DESIGN.md §4 «Математика ядра»
//  (автоцентрирование — только если заголовок за краем), §5 «Синхронизация
//  ленты и пейджера» (лента анимируется прогрессом пейджера, отдельной
//  анимации индикатора нет), §8 (RTL), §9 «Адаптивность» (поворот).
//
//  Окружение: тестовый процесс без `UIWindowScene`, поэтому анимации
//  `UIScrollView` (`setContentOffset(_:animated: true)`) не продвигаются —
//  анимированный переход «застревает» в начале. Это используется намеренно:
//  кадры анимации и её завершение подаются тестом вручную через колбэки
//  `TesseraPagerDelegate`, а перехват застрявшей анимации новым переходом
//  воспроизводит реальный UIKit-сценарий (синхронный
//  `scrollViewDidEndScrollingAnimation` для прерванной анимации).
//

#if canImport(UIKit)

import XCTest
import UIKit
import TesseraCore
@testable import TesseraPivot

/// Шпион делегата пивота для тестов переходов.
final class PivotTransitionSpy: TesseraPivotDelegate {
    var selectedIndexes: [Int] = []
    var progressValues: [CGFloat] = []
    var shownIndexes: [Int] = []

    func pivot(_ pivot: TesseraPivotViewController, didSelectSectionAt index: Int) {
        selectedIndexes.append(index)
    }

    func pivot(_ pivot: TesseraPivotViewController, didChangeProgress t: CGFloat) {
        progressValues.append(t)
    }

    func pivot(_ pivot: TesseraPivotViewController, didShowSectionAt index: Int) {
        shownIndexes.append(index)
    }
}

final class PivotTransitionTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Вспомогательные средства

    private func spinRunLoop(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeSections(count: Int, longTitles: Bool = false) -> [TesseraPivotSection] {
        (0..<count).map { index in
            TesseraPivotSection(
                id: index,
                title: longTitles ? "Длинный заголовок \(index)" : "S\(index)"
            ) {
                UIViewController()
            }
        }
    }

    /// Пивот в окне: appearance и пан пейджера — как в приложении.
    private func makeWindowedPivot(
        sectionCount: Int = 6,
        longTitles: Bool = false,
        size: CGSize = CGSize(width: 320, height: 640)
    ) throws -> (pivot: TesseraPivotViewController, scrollView: UIScrollView, spy: PivotTransitionSpy) {
        let pivot = TesseraPivotViewController(
            sections: makeSections(count: sectionCount, longTitles: longTitles)
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = pivot
        window.isHidden = false
        pivot.view.layoutIfNeeded()
        self.window = window

        let spy = PivotTransitionSpy()
        pivot.delegate = spy
        spinRunLoop()

        let scrollView = try XCTUnwrap(pivot.pagerScrollView)
        return (pivot, scrollView, spy)
    }

    private func collectionView(of strip: TesseraPivotHeaderStripView) throws -> UICollectionView {
        try XCTUnwrap(strip.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    private func itemFrame(_ index: Int, in collectionView: UICollectionView) throws -> CGRect {
        try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        )
    }

    private func isFullyVisible(_ frame: CGRect, in collectionView: UICollectionView) -> Bool {
        frame.minX >= collectionView.bounds.minX - 0.5
            && frame.maxX <= collectionView.bounds.maxX + 0.5
    }

    private func skipIfReduceMotion() throws {
        try XCTSkipIf(
            TesseraAccessibility.isReduceMotionEnabled,
            "При Reduce Motion переходы не анимируются (§8)"
        )
    }

    // MARK: - E9.6: ложный didShow при перехвате анимированного перехода

    /// Анимированный переход, перехваченный другим анимированным переходом,
    /// не даёт `didShowSectionAt` для промежуточной секции: UIKit синхронно
    /// завершает прерванную анимацию, и пейджер сообщает страницу, на которой
    /// её прервали (до E9.6 — `[3]` при целях 4 → 1).
    func testSupersededAnimatedTransitionDoesNotReportIntermediateSection() throws {
        try skipIfReduceMotion()
        let (pivot, scrollView, spy) = try makeWindowedPivot()
        let pageWidth = scrollView.bounds.width

        pivot.selectSection(at: 4, animated: true)
        pivot.selectSection(at: 1, animated: true)

        XCTAssertEqual(spy.shownIndexes, [], "Хвост перехваченного перехода не должен доходить до делегата")
        XCTAssertTrue(pivot.isTransitionInFlight)

        // Завершение анимации к цели — так, как его сообщает пейджер. (Запись
        // offset'а из теста сама прервала бы застрявшую анимацию и породила бы
        // ещё один хвост, которого в приложении нет.)
        _ = pageWidth
        pivot.pager(pivot.pagerViewController, didChangeProgress: 1)
        pivot.pager(pivot.pagerViewController, didShowPageAt: 1)

        XCTAssertEqual(spy.shownIndexes, [1])
        XCTAssertEqual(pivot.currentSectionIndex, 1)
        XCTAssertFalse(pivot.isTransitionInFlight)
    }

    /// Анимированный переход, перехваченный переходом без анимации: делегат
    /// видит только итоговую секцию (до E9.6 — `[…, 3, 0]`).
    func testAnimatedTransitionInterruptedByJumpReportsOnlyFinalSection() throws {
        try skipIfReduceMotion()
        let (pivot, scrollView, spy) = try makeWindowedPivot()

        pivot.selectSection(at: 4, animated: true)
        pivot.selectSection(at: 0, animated: false)

        XCTAssertEqual(spy.shownIndexes, [0])
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(pivot.headerStripView.lastProgress, 0, accuracy: 0.001)
        XCTAssertFalse(pivot.isTransitionInFlight)
    }

    /// Жест перехватывает анимированный переход: завершение там, где
    /// остановил палец, — настоящее, а не ложное, и доходит до делегата.
    func testUserDragAfterAnimatedTransitionReportsActualSection() throws {
        try skipIfReduceMotion()
        let (pivot, scrollView, spy) = try makeWindowedPivot()
        let pageWidth = scrollView.bounds.width

        pivot.selectSection(at: 1, animated: true)
        // Пейджер перехвачен жестом и после инерции встал на секцию 2.
        pivot.pagerViewController.scrollViewWillBeginDragging(scrollView)
        scrollView.setContentOffset(CGPoint(x: pageWidth * 2, y: 0), animated: false)
        pivot.pagerViewController.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(spy.shownIndexes.last, 2)
        XCTAssertEqual(pivot.currentSectionIndex, 2)
    }

    // MARK: - E9.6: лента не анимируется при selectSection(animated: false)

    /// Переход без анимации не запускает анимированную доцентровку ленты:
    /// до E9.6 `didShowPageAt` всегда звал `scrollToCenter(animated: true)`.
    func testNonAnimatedSelectionDoesNotAnimateStrip() throws {
        let (pivot, _, _) = try makeWindowedPivot(sectionCount: 8, longTitles: true)
        let strip = pivot.headerStripView
        let collectionView = try collectionView(of: strip)
        let before = strip.animatedCenteringCount

        pivot.selectSection(at: 6, animated: false)

        XCTAssertEqual(strip.animatedCenteringCount, before, "Лента не должна анимироваться")
        XCTAssertTrue(isFullyVisible(try itemFrame(6, in: collectionView), in: collectionView))
    }

    // MARK: - E9.6: scrollToCenter — только если заголовок за краем (§4)

    /// Видимый заголовок не двигает переполненную ленту; заголовок за краем
    /// доцентровывается.
    func testScrollToCenterMovesStripOnlyForHeaderBeyondEdge() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = (0..<8).map { "Заголовок \($0)" }
        strip.layoutIfNeeded()
        let collectionView = try collectionView(of: strip)

        XCTAssertGreaterThan(collectionView.contentSize.width, 320, "Лента должна быть переполнена")
        let visibleFrame = try itemFrame(1, in: collectionView)
        XCTAssertTrue(isFullyVisible(visibleFrame, in: collectionView), "Предусловие: заголовок 1 виден")
        XCTAssertGreaterThan(visibleFrame.midX, 160, "Предусловие: центрирование сдвинуло бы ленту")

        strip.scrollToCenter(index: 1, animated: false)
        XCTAssertEqual(collectionView.contentOffset.x, 0, accuracy: 0.5, "Видимый заголовок не двигает ленту")

        strip.scrollToCenter(index: 6, animated: false)
        let farFrame = try itemFrame(6, in: collectionView)
        XCTAssertGreaterThan(collectionView.contentOffset.x, 0)
        XCTAssertTrue(isFullyVisible(farFrame, in: collectionView))
        XCTAssertEqual(
            farFrame.midX - collectionView.contentOffset.x,
            160,
            accuracy: 1,
            "Заголовок за краем доцентровывается"
        )
    }

    // MARK: - E9.6: доцентровка при повороте (§9)

    /// После сужения ленты (поворот) выделенный заголовок снова виден.
    func testStripKeepsSelectedHeaderVisibleAfterWidthChange() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 800, height: 48))
        strip.titles = (0..<8).map { "Длинный заголовок \($0)" }
        strip.layoutIfNeeded()
        let collectionView = try collectionView(of: strip)

        strip.select(index: 6)
        strip.scrollToCenter(index: 6, animated: false)
        XCTAssertTrue(isFullyVisible(try itemFrame(6, in: collectionView), in: collectionView))

        strip.frame = CGRect(x: 0, y: 0, width: 320, height: 48)
        strip.layoutIfNeeded()

        XCTAssertTrue(
            isFullyVisible(try itemFrame(6, in: collectionView), in: collectionView),
            "После поворота выделенный заголовок должен остаться в видимой области"
        )
    }

    /// Лента перестала быть переполненной (поворот в ширину) — остаточный
    /// offset сбрасывается, все заголовки на месте.
    func testStripResetsOffsetWhenNoLongerOverflowing() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = (0..<4).map { "Заголовок \($0)" }
        strip.layoutIfNeeded()
        let collectionView = try collectionView(of: strip)

        strip.select(index: 3)
        strip.scrollToCenter(index: 3, animated: false)
        XCTAssertGreaterThan(collectionView.contentOffset.x, 0, "Предусловие: лента прокручена")

        strip.frame = CGRect(x: 0, y: 0, width: 1000, height: 48)
        strip.layoutIfNeeded()

        XCTAssertEqual(collectionView.contentOffset.x, 0, accuracy: 0.5)
    }

    // MARK: - E9.6: смена направления раскладки (§8)

    /// Смена `semanticContentAttribute` ленты на лету: коллекция зеркалится, а
    /// индикатор пересчитывается под фактический заголовок (до E9.6 центры
    /// оставались от прежнего направления — размер-то не менялся).
    func testStripRebuildsGeometryWhenSemanticDirectionChanges() throws {
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = ["Один", "Два", "Три"]
        strip.layoutIfNeeded()
        strip.apply(progress: 0)
        let collectionView = try collectionView(of: strip)

        let ltrFrame = try itemFrame(0, in: collectionView)
        XCTAssertLessThan(ltrFrame.midX, 160)
        XCTAssertEqual(strip.indicator.frame.midX, ltrFrame.midX, accuracy: 1)

        strip.semanticContentAttribute = .forceRightToLeft
        strip.layoutIfNeeded()

        XCTAssertEqual(collectionView.effectiveUserInterfaceLayoutDirection, .rightToLeft)
        XCTAssertTrue(
            collectionView.collectionViewLayout.flipsHorizontallyInOppositeLayoutDirection,
            "Раскладка ленты обязана зеркалиться в RTL (у UICollectionViewFlowLayout по умолчанию false)"
        )
        let rtlFrame = try itemFrame(0, in: collectionView)
        let rtlCenter = collectionView.convert(CGPoint(x: rtlFrame.midX, y: 0), to: strip).x
        XCTAssertGreaterThan(rtlCenter, 160, "В RTL первая секция чтения — справа")
        XCTAssertEqual(
            strip.indicator.frame.midX,
            rtlCenter,
            accuracy: 1,
            "Индикатор должен стоять под заголовком 0 в новом направлении"
        )
    }

    /// Смена направления из окружения (trait `layoutDirection` через
    /// переопределение родителем) пересобирает геометрию ленты.
    func testStripRebuildsGeometryWhenTraitDirectionChanges() throws {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = parent
        window.isHidden = false
        self.window = window

        child.view.frame = parent.view.bounds
        let strip = TesseraPivotHeaderStripView(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        strip.titles = ["Один", "Два", "Три"]
        child.view.addSubview(strip)
        strip.layoutIfNeeded()
        strip.apply(progress: 0)
        let collectionView = try collectionView(of: strip)
        XCTAssertEqual(collectionView.effectiveUserInterfaceLayoutDirection, .leftToRight)

        parent.setOverrideTraitCollection(
            UITraitCollection(layoutDirection: .rightToLeft),
            forChild: child
        )
        parent.view.layoutIfNeeded()
        strip.layoutIfNeeded()

        try XCTSkipUnless(
            collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            "Окружение не распространило trait-направление до коллекции"
        )
        let rtlFrame = try itemFrame(0, in: collectionView)
        let rtlCenter = collectionView.convert(CGPoint(x: rtlFrame.midX, y: 0), to: strip).x
        XCTAssertGreaterThan(rtlCenter, 160)
        XCTAssertEqual(strip.indicator.frame.midX, rtlCenter, accuracy: 1)
    }

    // MARK: - E10.12а: индикатор при анимированном тапе

    /// Анимированный тап на соседнюю секцию не ставит индикатор на цель
    /// заранее: до E10.12а лента на кадр прыгала к цели, а первый кадр
    /// анимации возвращал её назад. Теперь ленту ведёт прогресс пейджера.
    func testAnimatedTapDoesNotPreselectIndicator() throws {
        try skipIfReduceMotion()
        let (pivot, _, _) = try makeWindowedPivot()
        let strip = pivot.headerStripView
        let pager = pivot.pagerViewController

        let onSelect = try XCTUnwrap(strip.onSelect)
        onSelect(1)

        XCTAssertEqual(strip.lastProgress, 0, accuracy: 0.001, "Индикатор не прыгает к цели до анимации")

        pivot.pager(pager, didChangeProgress: 0.4)
        XCTAssertEqual(strip.lastProgress, 0.4, accuracy: 0.001)

        pivot.pager(pager, didChangeProgress: 1)
        pivot.pager(pager, didShowPageAt: 1)
        XCTAssertEqual(strip.lastProgress, 1, accuracy: 0.001)
        XCTAssertEqual(strip.selectedIndex, 1)
    }

    /// Дальний анимированный тап: пейджер (W1) переставляет offset на соседа
    /// цели и анимирует один шаг. Лента не телепортируется на соседа, а
    /// непрерывно едет от исходного заголовка к целевому; делегат получает
    /// сырой прогресс пейджера.
    func testFarAnimatedTapMovesIndicatorContinuouslyFromOrigin() throws {
        try skipIfReduceMotion()
        let (pivot, _, spy) = try makeWindowedPivot()
        let strip = pivot.headerStripView
        let pager = pivot.pagerViewController

        let onSelect = try XCTUnwrap(strip.onSelect)
        onSelect(4)

        XCTAssertEqual(spy.progressValues.last ?? -1, 3, accuracy: 0.001, "Делегат видит сырой скачок на соседа")
        XCTAssertEqual(strip.lastProgress, 0, accuracy: 0.001, "Лента остаётся на исходном заголовке")

        pivot.pager(pager, didChangeProgress: 3.5)
        XCTAssertEqual(strip.lastProgress, 2, accuracy: 0.001, "Середина шага — середина пути ленты")

        pivot.pager(pager, didChangeProgress: 4)
        XCTAssertEqual(strip.lastProgress, 4, accuracy: 0.001)

        pivot.pager(pager, didShowPageAt: 4)
        // Перенос снят: следующий свайп ведёт ленту сырым прогрессом.
        pivot.pager(pager, didChangeProgress: 3.5)
        XCTAssertEqual(strip.lastProgress, 3.5, accuracy: 0.001)
    }

    /// Дальний анимированный тап назад — тот же перенос в обратную сторону.
    func testFarAnimatedTapBackwardsMovesIndicatorContinuously() throws {
        try skipIfReduceMotion()
        let (pivot, _, _) = try makeWindowedPivot()
        let strip = pivot.headerStripView
        let pager = pivot.pagerViewController

        pivot.selectSection(at: 4, animated: false)
        pivot.selectSection(at: 0, animated: true)
        XCTAssertEqual(strip.lastProgress, 4, accuracy: 0.001)

        pivot.pager(pager, didChangeProgress: 0.5)
        XCTAssertEqual(strip.lastProgress, 2, accuracy: 0.001)
    }

    // MARK: - §6: appearance страниц после W1

    /// Страница-счётчик appearance-коллбэков.
    private final class AppearanceCountingPage: UIViewController {
        var didAppearCount = 0
        var didDisappearCount = 0

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppearCount += 1
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            didDisappearCount += 1
        }
    }

    /// Контракт W1, на который опирается §6: `viewDidAppear` получает только
    /// текущая секция, соседи ±1 загружены без appearance. Поэтому
    /// регистрировать вертикальный скролл в `viewDidAppear` поздно для соседа —
    /// документация `registerVerticalOwner(_:)` рекомендует `viewDidLoad`.
    func testOnlyCurrentSectionReceivesAppearanceCallbacks() throws {
        var pages: [Int: AppearanceCountingPage] = [:]
        let sections = (0..<3).map { (index: Int) -> TesseraPivotSection in
            TesseraPivotSection(id: index, title: "S\(index)") { () -> UIViewController in
                let page = AppearanceCountingPage()
                pages[index] = page
                return page
            }
        }
        let pivot = TesseraPivotViewController(sections: sections)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = pivot
        window.isHidden = false
        pivot.view.layoutIfNeeded()
        self.window = window
        spinRunLoop()

        let first = try XCTUnwrap(pages[0])
        let neighbour = try XCTUnwrap(pages[1], "Сосед ±1 загружен заранее")
        XCTAssertEqual(first.didAppearCount, 1)
        XCTAssertEqual(neighbour.didAppearCount, 0, "Сосед не получает viewDidAppear при загрузке")
        XCTAssertTrue(neighbour.isViewLoaded, "viewDidLoad соседа уже выполнен — точка регистрации")

        pivot.selectSection(at: 1, animated: false)

        XCTAssertEqual(neighbour.didAppearCount, 1)
        XCTAssertEqual(first.didDisappearCount, 1)
    }

    /// Перенос прогресса ленты: края отрезка и зажим за его пределами.
    func testStripProgressRemapMath() {
        let remap = TesseraPivotViewController.StripProgressRemap(from: 0, neighbour: 3, target: 4)

        XCTAssertEqual(remap.stripProgress(forPagerProgress: 3), 0, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 3.25), 1, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 4), 4, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(remap.stripProgress(forPagerProgress: 4.3), 4, accuracy: 0.0001)
    }
}

#endif
