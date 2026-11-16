//
//  PagerPagesTests.swift
//  TesseraStartScreenTests
//
//  Тесты конфигурации страниц рабочего стола (задача E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §1 «Ключевая
//  архитектурная идея: три страницы» (START в центре, слева — хук, справа —
//  список приложений; политика ведущей кромки) и §14 «Уточнения MVP» п. 2
//  (D13: обе боковые страницы опциональны, пейджер масштабируется от одной до
//  трёх страниц).
//
//  Тесты не гоняют UI-цикл и не эмулируют касания: контроллер загружает вид,
//  раскладывается вручную, а число страниц проверяется по публичной иерархии
//  Core-пейджера (его `children` — страницы окна ±1). Доступность страниц
//  проверяется через `showPage` и `accessibilityScroll`, которые опираются на
//  порядок страниц, а не на физическую прокрутку.
//

#if canImport(UIKit)

import UIKit
import XCTest
import TesseraCore
@testable import TesseraStartScreen

final class PagerPagesTests: XCTestCase {

    // MARK: - Вспомогательные средства

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

    /// Загружает экран без окна и возвращает пейджер Core.
    ///
    /// - Parameter screen: Экран рабочего стола.
    /// - Returns: Пейджер, содержащий загруженные страницы.
    private func loadedPager(
        of screen: TesseraStartScreenViewController
    ) throws -> TesseraPagerViewController {
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        screen.view.layoutIfNeeded()

        let pager = try XCTUnwrap(
            screen.children.compactMap { $0 as? TesseraPagerViewController }.first,
            "Экран обязан содержать пейджер Core"
        )
        // Экран мог ещё не разложить пейджер (нулевая ширина страницы не даёт
        // загрузить страницы) — доводим геометрию вручную, как в тестах Core.
        pager.view.frame = screen.view.bounds
        pager.view.layoutIfNeeded()
        return pager
    }

    /// Число страниц в пейджере.
    ///
    /// Пейджер держит в памяти текущую страницу и соседей ±1, а страниц не
    /// больше трёх, поэтому `children.count` совпадает с числом страниц.
    ///
    /// - Parameter screen: Экран рабочего стола.
    /// - Returns: Число страниц: 1...3 (D13).
    private func pageCount(of screen: TesseraStartScreenViewController) throws -> Int {
        try loadedPager(of: screen).children.count
    }

    // MARK: - Состав страниц (D13)

    /// Без боковых панелей существует только START.
    func testDefaultScreenHasOnlyStartPage() throws {
        let screen = makeScreen()

        XCTAssertEqual(screen.currentPage, .start)
        XCTAssertEqual(try pageCount(of: screen), 1)
    }

    /// Левая панель добавляет вторую страницу.
    func testLeftPanelAddsSecondPage() throws {
        let screen = makeScreen(leftPanel: makeLeftPanel())

        XCTAssertEqual(try pageCount(of: screen), 2)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Правая страница добавляет вторую страницу.
    func testRightPageAddsSecondPage() throws {
        let screen = makeScreen(rightPage: { UIViewController() })

        XCTAssertEqual(try pageCount(of: screen), 2)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Обе панели дают ровно три страницы (D13: от 1 до 3).
    func testBothSidePagesAddThirdPage() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )

        XCTAssertEqual(try pageCount(of: screen), 3)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Пересборка конфигурации убирает страницу, которой больше нет, и
    /// возвращает пользователя на START.
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

    // MARK: - Доступность страниц до загрузки вида

    /// Не заданные хостом страницы не открываются программно (D13): намерение
    /// отклоняется, текущая страница остаётся START.
    func testUnavailablePagesRejectProgrammaticShowBeforeLoad() {
        let screen = TesseraStartScreenViewController()

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(screen.currentPage, .start)

        screen.showPage(.applications, animated: false)
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Заданные страницы доступны программно до загрузки вида; намерение
    /// запоминается и применяется первым layout'ом.
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

    // MARK: - Свайп и порядок чтения

    /// При трёх страницах от START можно листнуть назад — на хук (§1).
    func testThreePagesScrollBackwardsFromStart() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        _ = try loadedPager(of: screen)

        XCTAssertTrue(screen.accessibilityScroll(.previous))
        XCTAssertEqual(screen.currentPage, .quickPanel)
    }

    /// При трёх страницах от START можно листнуть вперёд — в список приложений.
    func testThreePagesScrollForwardsFromStart() throws {
        let screen = makeScreen(
            leftPanel: makeLeftPanel(),
            rightPage: { UIViewController() }
        )
        _ = try loadedPager(of: screen)

        XCTAssertTrue(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .applications)
    }

    /// При одной странице листать некуда.
    func testSinglePageDoesNotScroll() throws {
        let screen = makeScreen()
        _ = try loadedPager(of: screen)

        XCTAssertFalse(screen.accessibilityScroll(.previous))
        XCTAssertFalse(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .start)
    }

    /// Только левая панель: назад можно, вперёд — нет.
    func testLeftPanelOnlyScrollsBackwards() throws {
        let screen = makeScreen(leftPanel: makeLeftPanel())
        _ = try loadedPager(of: screen)

        XCTAssertFalse(screen.accessibilityScroll(.next))
        XCTAssertTrue(screen.accessibilityScroll(.previous))
        XCTAssertEqual(screen.currentPage, .quickPanel)
    }

    /// Только правая страница: вперёд можно, назад — нет.
    func testRightPageOnlyScrollsForwards() throws {
        let screen = makeScreen(rightPage: { UIViewController() })
        _ = try loadedPager(of: screen)

        XCTAssertFalse(screen.accessibilityScroll(.previous))
        XCTAssertTrue(screen.accessibilityScroll(.next))
        XCTAssertEqual(screen.currentPage, .applications)
    }

    // MARK: - Политика ведущей кромки (§1)

    /// При `yieldsLeftEdgeToSystemGesture` хук исключается из свайпаемого
    /// набора: из START нельзя уйти назад, но правая страница остаётся.
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

    /// При политике края хук всё равно открывается программно (§1):
    /// `showPage` разворачивает его в пейджере.
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
