//
//  StartScreenControllerReviewTests.swift
//  TesseraStartScreenTests
//
//  Регрессионные тесты контроллера рабочего стола по повторному ревью
//  (E10.6, трек T1 в docs/PLAN.md).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §1 «Три страницы»
//  (политика ведущей кромки, арбитраж осей), §4 «Live-плитки» (паузы вне
//  экрана), §7 «Страница слева: хук» (колбэки появления/скрытия), §8
//  «Параллакс фона» (запас обоев) и §9 «Accessibility» (озвучивание страниц).
//  Core-контракт пейджера после W1: docs/CORE-IOS-DESIGN.md, «Отступления
//  реализации», пп. 6–7 (reload по id, appearance только текущей странице).
//
//  Экран встраивается в окно вручную (без rootViewController); появление
//  экрана дополнительно задаётся явными `beginAppearanceTransition`/
//  `endAppearanceTransition` (повторное появление для контроллера
//  идемпотентно). Окно не привязано к сцене, анимации прокрутки в нём не
//  тикают: свайп и завершение программной анимации пейджера эмулируются
//  вызовами его `UIScrollViewDelegate`, как это сделал бы UIKit.
//

#if canImport(UIKit)

import UIKit
import XCTest
import TesseraCore
@testable import TesseraStartScreen

final class StartScreenControllerReviewTests: XCTestCase {

    // MARK: - Шпионы

    /// Поставщик хука, записывающий колбэки появления/скрытия (§7).
    private final class PanelSpy: QuickPanelProviding {
        let name: String
        private(set) var appearCount = 0
        private(set) var disappearCount = 0
        private(set) var makeCount = 0

        init(_ name: String) {
            self.name = name
        }

        func makeQuickPanelViewController() -> UIViewController {
            makeCount += 1
            return UIViewController()
        }

        func quickPanelWillAppear() {
            appearCount += 1
        }

        func quickPanelDidDisappear() {
            disappearCount += 1
        }
    }

    /// UIKit-делегат экрана: страницы и видимость хука.
    private final class DelegateSpy: StartScreenDelegate {
        private(set) var pages: [TesseraStartScreenPage] = []
        private(set) var hookVisibility: [Bool] = []

        func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangePage page: TesseraStartScreenPage,
            index: Int
        ) {
            pages.append(page)
        }

        func startScreen(
            _ screen: TesseraStartScreenViewController,
            didChangeHookVisibility isVisible: Bool
        ) {
            hookVisibility.append(isVisible)
        }
    }

    /// Провайдер live-плитки с обратной стороной (флипы возможны).
    private final class FlippingProvider: TesseraLiveTileContentProvider {
        var frontFace = TesseraLiveTileFace(title: "Front")
        var backFace: TesseraLiveTileFace? { TesseraLiveTileFace(title: "Back") }
    }

    // MARK: - Окружение

    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        windows.removeAll()
        super.tearDown()
    }

    private let screenSize = CGSize(width: 390, height: 844)

    /// Встраивает экран в окно и доводит раскладку (без appearance).
    @discardableResult
    private func host(_ screen: TesseraStartScreenViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: screenSize))
        window.isHidden = false
        windows.append(window)

        screen.loadViewIfNeeded()
        screen.view.frame = window.bounds
        window.addSubview(screen.view)
        layout(screen)
        return window
    }

    /// Доводит раскладку экрана, пейджера и START-страницы.
    private func layout(_ screen: TesseraStartScreenViewController) {
        screen.view.layoutIfNeeded()
        if let pager = try? pager(of: screen) {
            pager.view.frame = screen.view.bounds
            pager.view.layoutIfNeeded()
        }
        screen.gridView.superview?.layoutIfNeeded()
        screen.gridView.layoutIfNeeded()
    }

    private func appear(_ screen: TesseraStartScreenViewController) {
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
    }

    private func disappear(_ screen: TesseraStartScreenViewController) {
        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
    }

    private func pager(of screen: TesseraStartScreenViewController) throws -> TesseraPagerViewController {
        try XCTUnwrap(
            screen.children.compactMap { $0 as? TesseraPagerViewController }.first,
            "Экран обязан содержать пейджер Core"
        )
    }

    private func pagerScrollView(of screen: TesseraStartScreenViewController) throws -> UIScrollView {
        try XCTUnwrap(
            pager(of: screen).view.subviews.compactMap { $0 as? UIScrollView }.first,
            "Пейджер обязан содержать UIScrollView"
        )
    }

    private func gridCollectionView(of screen: TesseraStartScreenViewController) throws -> UICollectionView {
        try XCTUnwrap(
            screen.gridView.subviews.compactMap { $0 as? UICollectionView }.first,
            "Сетка держит коллекцию"
        )
    }

    /// Горизонтальное положение START-страницы на экране (0 — START видна).
    private func startPageScreenX(of screen: TesseraStartScreenViewController) -> CGFloat {
        screen.gridView.convert(screen.gridView.bounds, to: screen.view).minX
    }

    /// Прокручивает run loop заданное время.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Ждёт условия, прокручивая run loop.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Эмулирует завершение программной анимации пейджера.
    ///
    /// Окно тестового процесса не привязано к сцене, и анимация
    /// `setContentOffset(_:animated: true)` в нём не тикает: тест доводит
    /// offset до цели и сообщает пейджеру о завершении, как сделал бы UIKit.
    private func completeAnimatedTransition(
        _ screen: TesseraStartScreenViewController,
        toReadingIndex readingIndex: Int
    ) throws {
        let pager = try pager(of: screen)
        let scrollView = try pagerScrollView(of: screen)
        scrollView.setContentOffset(
            CGPoint(x: CGFloat(readingIndex) * scrollView.bounds.width, y: 0),
            animated: false
        )
        pager.scrollViewDidEndScrollingAnimation(scrollView)
    }

    /// Эмулирует завершённый свайп пейджера на страницу `readingIndex` (LTR).
    private func swipe(_ screen: TesseraStartScreenViewController, toReadingIndex readingIndex: Int) throws {
        let pager = try pager(of: screen)
        let scrollView = try pagerScrollView(of: screen)
        pager.scrollViewWillBeginDragging(scrollView)
        scrollView.setContentOffset(
            CGPoint(x: CGFloat(readingIndex) * scrollView.bounds.width, y: 0),
            animated: false
        )
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        pager.scrollViewDidEndDecelerating(scrollView)
    }

    private func makeScreen(
        leftPanel: QuickPanelProviding?,
        rightPage: Bool = true
    ) -> TesseraStartScreenViewController {
        let screen = TesseraStartScreenViewController()
        screen.configure(
            leftPanel: leftPanel,
            rightPage: rightPage ? { UIViewController() } : nil
        )
        return screen
    }

    // MARK: - Досинхронизация пейджера после пересборки (E10.6)

    /// Сценарий А: политика уступки края, программный показ хука и свайп на
    /// START. После отложенной «заморозки» хука (пересборка страниц) на экране
    /// START, а не список приложений.
    func testEdgePolicyQuickPanelThenSwipeToStartKeepsStartOnScreen() throws {
        let panel = PanelSpy("A")
        let screen = makeScreen(leftPanel: panel)
        screen.yieldsLeftEdgeToSystemGesture = true
        host(screen)
        appear(screen)

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(screen.currentPage, .quickPanel)

        try swipe(screen, toReadingIndex: 1)
        XCTAssertEqual(screen.currentPage, .start)

        // Отложенная пересборка: хук выпадает из свайпаемого набора.
        spin(0.1)
        layout(screen)

        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertFalse(screen.accessibilityScroll(.previous), "Хук снова только программный")
        XCTAssertEqual(try pagerScrollView(of: screen).contentOffset.x, 0, accuracy: 0.5)
        XCTAssertEqual(startPageScreenX(of: screen), 0, accuracy: 0.5, "На экране START")
    }

    /// Сценарий Б: `configure(leftPanel:)` на START добавляет хук слева — на
    /// экране остаётся START (индекс сдвинулся на 1), хук не «появлялся».
    func testConfigureAddingLeftPanelOnStartKeepsStartOnScreen() throws {
        let panel = PanelSpy("A")
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        appear(screen)

        screen.configure(leftPanel: panel, rightPage: { UIViewController() })
        layout(screen)

        let scrollView = try pagerScrollView(of: screen)
        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(scrollView.contentOffset.x, scrollView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(startPageScreenX(of: screen), 0, accuracy: 0.5, "На экране START")
        XCTAssertEqual(panel.appearCount, 0, "Хук не показывался")
    }

    // MARK: - showPage при политике уступки края (E10.6)

    /// Программный показ хука при политике края шлёт всё, что положено
    /// переходу: колбэк поставщика, события делегата и анонс VoiceOver.
    func testShowQuickPanelUnderEdgePolicyNotifiesProviderDelegateAndVoiceOver() throws {
        let panel = PanelSpy("A")
        let delegate = DelegateSpy()
        var announcements: [String] = []
        let screen = makeScreen(leftPanel: panel)
        screen.pageAnnouncer = { announcements.append($0) }
        screen.delegate = delegate
        screen.yieldsLeftEdgeToSystemGesture = true
        host(screen)
        appear(screen)

        screen.showPage(.quickPanel, animated: false)

        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(panel.appearCount, 1)
        XCTAssertEqual(delegate.pages, [.quickPanel])
        XCTAssertEqual(delegate.hookVisibility, [true])
        XCTAssertEqual(announcements, [screen.quickPanelTitle])
    }

    // MARK: - currentPage только по подтверждению пейджера (E10.6)

    /// Анимированный `showPage` не записывает `currentPage` до завершения
    /// перехода: источник истины — пейджер.
    func testAnimatedShowPageCommitsCurrentPageOnlyAfterPagerConfirms() throws {
        let screen = makeScreen(leftPanel: PanelSpy("A"))
        host(screen)
        appear(screen)

        screen.showPage(.applications, animated: true)
        XCTAssertEqual(screen.currentPage, .start, "Переход ещё не подтверждён")

        try completeAnimatedTransition(screen, toReadingIndex: 2)
        XCTAssertEqual(screen.currentPage, .applications)
    }

    /// Палец перехватил анимированный переход и вернул пейджер на START:
    /// `currentPage` остаётся START (раньше «залипал» на цели анимации).
    func testInterceptedAnimatedTransitionKeepsConfirmedPage() throws {
        let screen = makeScreen(leftPanel: PanelSpy("A"))
        host(screen)
        appear(screen)
        let pager = try pager(of: screen)
        let scrollView = try pagerScrollView(of: screen)

        screen.showPage(.applications, animated: true)

        pager.scrollViewWillBeginDragging(scrollView)
        scrollView.setContentOffset(CGPoint(x: scrollView.bounds.width, y: 0), animated: false)
        pager.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        spin(0.5)

        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(startPageScreenX(of: screen), 0, accuracy: 0.5)
    }

    // MARK: - Колбэки хука (§7, E10.6)

    /// `quickPanelWillAppear` приходит до появления: при анимированном
    /// показе — сразу, а не по завершении перехода.
    func testQuickPanelWillAppearBeforeAnimatedTransitionCompletes() throws {
        let panel = PanelSpy("A")
        let screen = makeScreen(leftPanel: panel)
        host(screen)
        appear(screen)

        screen.showPage(.quickPanel, animated: true)
        XCTAssertEqual(panel.appearCount, 1, "willAppear — до появления страницы")

        try completeAnimatedTransition(screen, toReadingIndex: 0)
        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(panel.appearCount, 1, "Повторного willAppear нет")
        XCTAssertEqual(panel.disappearCount, 0)
    }

    /// Хук, запрошенный до загрузки, не получает `quickPanelWillAppear`, пока
    /// экран не показан; делегат и VoiceOver тоже молчат. Появление и уход
    /// экрана дают симметричные колбэки.
    func testHookCallbacksFollowScreenAppearanceNotViewDidLoad() throws {
        let panel = PanelSpy("A")
        let delegate = DelegateSpy()
        var announcements: [String] = []
        let screen = makeScreen(leftPanel: panel)
        screen.pageAnnouncer = { announcements.append($0) }
        screen.delegate = delegate
        screen.showPage(.quickPanel, animated: false)

        // Загрузка и раскладка без окна: `viewDidLoad` и layout — не появление.
        // (Добавление вида в окно UIKit сам считает появлением, поэтому окно —
        // только после проверки.)
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(origin: .zero, size: screenSize)
        layout(screen)
        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(panel.appearCount, 0, "Экран ещё не показан")
        XCTAssertEqual(delegate.hookVisibility, [])

        host(screen)
        appear(screen)
        XCTAssertEqual(panel.appearCount, 1)
        XCTAssertEqual(delegate.hookVisibility, [true])

        disappear(screen)
        XCTAssertEqual(panel.disappearCount, 1)
        XCTAssertEqual(delegate.hookVisibility, [true, false])

        XCTAssertEqual(announcements, [], "Стартовая страница не озвучивается")
    }

    /// Стартовая страница не озвучивается из `viewDidLoad`.
    func testInitialPageIsNotAnnouncedOnLoad() {
        var announcements: [String] = []
        let screen = makeScreen(leftPanel: PanelSpy("A"))
        screen.pageAnnouncer = { announcements.append($0) }

        host(screen)
        appear(screen)

        XCTAssertEqual(announcements, [])
    }

    /// Замена и удаление поставщика, пока хук на экране: прежний получает
    /// `didDisappear`, новый — `willAppear`; страница пересоздаётся новым
    /// поставщиком.
    func testReplacingAndRemovingProviderWhileHookVisibleIsSymmetric() throws {
        let first = PanelSpy("A")
        let second = PanelSpy("B")
        let screen = makeScreen(leftPanel: first)
        host(screen)
        appear(screen)
        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(first.appearCount, 1)

        screen.configure(leftPanel: second, rightPage: { UIViewController() })
        layout(screen)
        XCTAssertEqual(screen.currentPage, .quickPanel)
        XCTAssertEqual(first.disappearCount, 1, "Прежний поставщик получает didDisappear")
        XCTAssertEqual(second.appearCount, 1, "Новый поставщик получает willAppear")
        XCTAssertGreaterThanOrEqual(second.makeCount, 1, "Страница создана новым поставщиком")

        screen.configure(leftPanel: nil, rightPage: { UIViewController() })
        layout(screen)
        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(second.disappearCount, 1, "Удалённый поставщик получает didDisappear")
        XCTAssertEqual(first.appearCount, 1)
        XCTAssertEqual(first.disappearCount, 1)
    }

    // MARK: - Арбитраж осей против блокировки скролла папкой (E10.6)

    /// Горизонтальный жест начался, пока анимация папки держала сетку
    /// выключенной: после обоих завершений сетка снова прокручивается.
    func testHorizontalGestureDuringFolderAnimationDoesNotFreezeGrid() throws {
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        let grid = screen.gridView
        let collectionView = try gridCollectionView(of: screen)

        // Анимация папки: снимок `true`, на время анимации — `false`.
        let folderSnapshot = grid.isScrollEnabled
        grid.isScrollEnabled = false
        screen.beginHorizontalScroll(isHorizontal: true)
        grid.isScrollEnabled = folderSnapshot
        screen.endHorizontalScroll()

        XCTAssertTrue(grid.isScrollEnabled)
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
    }

    /// Анимация папки началась посреди горизонтального жеста и закончилась
    /// после него: сетка не остаётся выключенной навсегда.
    func testFolderAnimationStartedDuringHorizontalGestureDoesNotFreezeGrid() throws {
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        let grid = screen.gridView
        let collectionView = try gridCollectionView(of: screen)

        screen.beginHorizontalScroll(isHorizontal: true)
        let folderSnapshot = grid.isScrollEnabled
        grid.isScrollEnabled = false
        screen.endHorizontalScroll()
        grid.isScrollEnabled = folderSnapshot

        XCTAssertTrue(grid.isScrollEnabled)
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
    }

    /// Сам арбитраж работает: на время горизонтального жеста сетка не
    /// принимает вертикальный пан, после — принимает; вертикальный жест сетку
    /// не блокирует.
    func testHorizontalGestureBlocksGridPanOnlyWhileActive() throws {
        let screen = makeScreen(leftPanel: nil)
        host(screen)
        let collectionView = try gridCollectionView(of: screen)

        screen.beginHorizontalScroll(isHorizontal: true)
        XCTAssertFalse(collectionView.panGestureRecognizer.isEnabled && screen.gridView.isScrollEnabled)
        screen.endHorizontalScroll()
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
        XCTAssertTrue(screen.gridView.isScrollEnabled)

        screen.beginHorizontalScroll(isHorizontal: false)
        XCTAssertTrue(collectionView.panGestureRecognizer.isEnabled)
        XCTAssertTrue(screen.gridView.isScrollEnabled)
        screen.endHorizontalScroll()
    }

    // MARK: - Live-плитки вне экрана (§4, E10.6)

    /// Пока START за кадром, live-плитки не флипаются; возврат на START
    /// возобновляет расписание.
    func testLiveTilesDoNotFlipWhileStartIsOffScreen() throws {
        let screen = makeScreen(leftPanel: nil)
        screen.gridView.liveTileConfiguration = TesseraLiveTileEngine.Configuration(
            cycleInterval: 0.8,
            flipDuration: 0.1,
            batchSize: 10,
            batchStagger: 0,
            jitter: 0,
            seed: 1
        )
        let tile = TileDescriptor(
            id: "live",
            title: "Live",
            action: {},
            liveContent: FlippingProvider()
        )
        screen.reload(grid: TileGridSnapshot(items: [.tile(tile)], unpinned: []))
        host(screen)
        appear(screen)

        let liveView = try XCTUnwrap(
            firstSubview(of: TesseraLiveTileView.self, in: screen.gridView),
            "Live-плитка показана на START"
        )
        XCTAssertEqual(liveView.side, .front)

        screen.showPage(.applications, animated: false)
        XCTAssertEqual(screen.currentPage, .applications)
        spin(1.3)

        XCTAssertEqual(liveView.side, .front, "START за кадром — флипов нет")
        XCTAssertFalse(liveView.isFlipping)

        screen.showPage(.start, animated: false)
        XCTAssertTrue(
            waitUntil(timeout: 3) { liveView.side == .back || liveView.isFlipping },
            "На START расписание флипов возобновляется"
        )
    }

    // MARK: - Запас обоев при росте контента (§8, E10.6)

    /// Рост высоты контента через `grid.update` (без `reload(grid:)`)
    /// пересчитывает запас обоев: в конце прокрутки страница закрыта.
    func testWallpaperReserveFollowsContentGrowthWithoutReload() throws {
        let screen = makeScreen(leftPanel: nil, rightPage: false)
        screen.wallpaperParallaxFactor = 0.6
        screen.wallpaperImage = UIImage()
        let few = (0..<2).map { TileGridItem.tile(tesseraTestTile("t\($0)")) }
        screen.reload(grid: TileGridSnapshot(items: few, unpinned: []))
        host(screen)

        let many = (0..<60).map { TileGridItem.tile(tesseraTestTile("t\($0)")) }
        screen.gridView.update(snapshot: TileGridSnapshot(items: many, unpinned: []), animated: false)
        let collectionView = try gridCollectionView(of: screen)
        collectionView.layoutIfNeeded()
        layout(screen)

        try assertWallpaperCoversPageAtBottom(of: screen, collectionView: collectionView)
    }

    /// Раскрытие папки (панель удлиняет контент) пересчитывает запас обоев.
    func testWallpaperReserveFollowsFolderExpansion() throws {
        let screen = makeScreen(leftPanel: nil, rightPage: false)
        screen.wallpaperParallaxFactor = 0.6
        screen.wallpaperImage = UIImage()
        let folder = TileFolder(
            id: "folder",
            title: "Folder",
            // Шесть колонок по умолчанию (D26): плиток нужно столько, чтобы панель
            // вдвое превысила вьюпорт.
            tiles: (0..<200).map { tesseraTestTile("f\($0)", size: .small) }
        )
        screen.reload(grid: TileGridSnapshot(items: [.folder(folder)], unpinned: []))
        host(screen)

        screen.gridView.openFolder(folder, animated: false)
        let collectionView = try gridCollectionView(of: screen)
        collectionView.layoutIfNeeded()
        layout(screen)

        try assertWallpaperCoversPageAtBottom(of: screen, collectionView: collectionView)
    }

    // MARK: - Вспомогательные проверки

    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func assertWallpaperCoversPageAtBottom(
        of screen: TesseraStartScreenViewController,
        collectionView: UICollectionView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let layer = try XCTUnwrap(firstSubview(of: TesseraParallaxLayer.self, in: screen.view))
        layer.respectsReduceMotion = false
        let page = try XCTUnwrap(layer.superview)
        let imageView = try XCTUnwrap(layer.subviews.compactMap { $0 as? UIImageView }.first)

        let height = page.bounds.height
        let maximum = max(0, max(screen.gridView.contentSize.height, height) - height)
        XCTAssertGreaterThan(maximum, height, "Контент обязан вырасти заметно выше вьюпорта", file: file, line: line)

        collectionView.contentOffset = CGPoint(x: 0, y: maximum)
        let rect = imageView.convert(imageView.bounds, to: page)
        XCTAssertLessThanOrEqual(rect.minY, 0.001, "Полоса сверху", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, height - 0.001, "Полоса снизу", file: file, line: line)
    }
}

#endif
