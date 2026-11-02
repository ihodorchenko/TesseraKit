//
//  StartScreenViewFacadeTests.swift
//  TesseraStartScreenTests
//
//  Регрессионные тесты SwiftUI-фасада рабочего стола по ревью (E10.8, E9.8б;
//  трек T1 в docs/PLAN.md).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md — §2 «Архитектура»
//  (StartScreenView → StartScreenViewController, StartScreenDelegate), §4
//  «Live-плитки», §7 «Страница слева: хук» и §14 (D12: тап — событие, действие
//  выполняет хост).
//
//  Фасад встраивается через `UIHostingController` в окно; живой
//  `TesseraStartScreenViewController` находится обходом детей хостинга.
//  Перерисовка SwiftUI эмулируется заменой `rootView` и проходом layout'а.
//

#if canImport(UIKit) && canImport(SwiftUI)

import SwiftUI
import UIKit
import XCTest
import TesseraCore
@testable import TesseraStartScreen

final class StartScreenViewFacadeTests: XCTestCase {

    // MARK: - Шпионы

    private final class DelegateSpy: StartScreenDelegate {
        private(set) var tappedShortcuts: [TileDescriptor] = []
        private(set) var hookVisibility: [Bool] = []
        private(set) var pages: [TesseraStartScreenPage] = []

        func startScreen(
            _ screen: TesseraStartScreenViewController,
            didTapShortcut shortcut: TileDescriptor
        ) {
            tappedShortcuts.append(shortcut)
        }

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

    private final class StaticProvider: TesseraLiveTileContentProvider {
        var frontFace = TesseraLiveTileFace(title: "Front")
    }

    // MARK: - Окружение

    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows {
            window.rootViewController = nil
            window.isHidden = true
        }
        windows.removeAll()
        super.tearDown()
    }

    private func host(_ view: StartScreenView) -> UIHostingController<StartScreenView> {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.isHidden = false
        windows.append(window)
        render(hosting)
        return hosting
    }

    private func render(_ hosting: UIHostingController<StartScreenView>) {
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.view.layoutIfNeeded()
    }

    private func screen(in hosting: UIViewController) throws -> TesseraStartScreenViewController {
        func find(_ controller: UIViewController) -> TesseraStartScreenViewController? {
            if let screen = controller as? TesseraStartScreenViewController { return screen }
            for child in controller.children {
                if let match = find(child) { return match }
            }
            return nil
        }
        return try XCTUnwrap(find(hosting), "Фасад обязан создать контроллер рабочего стола")
    }

    private func pagerScrollView(of screen: TesseraStartScreenViewController) throws -> UIScrollView {
        let pager = try XCTUnwrap(screen.children.compactMap { $0 as? TesseraPagerViewController }.first)
        return try XCTUnwrap(pager.view.subviews.compactMap { $0 as? UIScrollView }.first)
    }

    private func folderSnapshot(innerBadge: TileBadge, innerTitle: String) -> TileGridSnapshot {
        let inner = TileDescriptor(id: "inner", title: innerTitle, action: {}, badge: innerBadge)
        let folder = TileFolder(id: "folder", title: "Folder", tiles: [inner])
        return TileGridSnapshot(items: [.folder(folder)], unpinned: [])
    }

    // MARK: - Сигнатура снимка: содержимое папок (E9.8б)

    /// Бейдж и подпись ярлыка внутри папки доходят до сетки.
    func testFolderContentBadgeAndTitleChangesReachGrid() throws {
        let hosting = host(StartScreenView(snapshot: folderSnapshot(innerBadge: .none, innerTitle: "Mail")))
        let screen = try screen(in: hosting)

        hosting.rootView = StartScreenView(snapshot: folderSnapshot(innerBadge: .count(3), innerTitle: "Inbox"))
        render(hosting)

        guard case .folder(let folder)? = screen.gridView.items.first else {
            return XCTFail("Ожидалась папка")
        }
        XCTAssertEqual(folder.tiles.first?.badge, .count(3))
        XCTAssertEqual(folder.tiles.first?.title, "Inbox")
    }

    // MARK: - Сигнатура снимка: liveContent и action (E10.8)

    /// Появление `liveContent` у ярлыка с тем же `id` доходит до сетки —
    /// плитка становится живой.
    func testLiveContentChangeReachesGrid() throws {
        let plain = TileDescriptor(id: "t", title: "T", action: {})
        let hosting = host(StartScreenView(snapshot: TileGridSnapshot(items: [.tile(plain)], unpinned: [])))
        let screen = try screen(in: hosting)

        let provider = StaticProvider()
        let live = TileDescriptor(id: "t", title: "T", action: {}, liveContent: provider)
        hosting.rootView = StartScreenView(snapshot: TileGridSnapshot(items: [.tile(live)], unpinned: []))
        render(hosting)

        guard case .tile(let shortcut)? = screen.gridView.items.first else {
            return XCTFail("Ожидался ярлык")
        }
        XCTAssertTrue(shortcut.liveContent === provider)
    }

    /// Делегат получает ярлык с актуальным замыканием `action`, даже если
    /// остальное в ярлыке не менялось (D12: действие выполняет хост).
    func testTapDeliversShortcutWithLatestAction() throws {
        let delegate = DelegateSpy()
        var calls: [String] = []
        let old = TileDescriptor(id: "t", title: "T", action: { calls.append("old") })
        let hosting = host(StartScreenView(
            snapshot: TileGridSnapshot(items: [.tile(old)], unpinned: []),
            delegate: delegate
        ))
        let screen = try screen(in: hosting)

        let fresh = TileDescriptor(id: "t", title: "T", action: { calls.append("new") })
        hosting.rootView = StartScreenView(
            snapshot: TileGridSnapshot(items: [.tile(fresh)], unpinned: []),
            delegate: delegate
        )
        render(hosting)

        let item = try XCTUnwrap(screen.gridView.items.first)
        screen.gridView.onTap?(item)

        let tapped = try XCTUnwrap(delegate.tappedShortcuts.last)
        tapped.action()
        XCTAssertEqual(calls, ["new"])
    }

    // MARK: - Поставщик хука из body (E10.8)

    /// Поставщик хука, создаваемый в `body` заново на каждой перерисовке, не
    /// пересобирает пейджер: идущий свайп (offset между страницами) не
    /// сбрасывается.
    func testQuickPanelProviderRecreatedPerRenderDoesNotRebuildPager() throws {
        let snapshot = TileGridSnapshot(items: [], unpinned: [])
        let hosting = host(StartScreenView(
            snapshot: snapshot,
            leftPanel: QuickPanelProvider { UIViewController() },
            rightPage: { UIViewController() }
        ))
        let screen = try screen(in: hosting)
        let scrollView = try pagerScrollView(of: screen)
        let midOffset = scrollView.bounds.width * 1.5
        scrollView.contentOffset = CGPoint(x: midOffset, y: 0)

        hosting.rootView = StartScreenView(
            snapshot: snapshot,
            leftPanel: QuickPanelProvider { UIViewController() },
            rightPage: { UIViewController() }
        )
        render(hosting)

        XCTAssertEqual(scrollView.contentOffset.x, midOffset, accuracy: 0.5, "Пейджер не пересобирался")
        XCTAssertEqual(screen.currentPage, .start)
    }

    // MARK: - Видимость хука при появлении экрана (E10.8)

    /// `didChangeHookVisibility` приходит, когда экран с открытым хуком
    /// уходит и возвращается (viewDidDisappear/viewWillAppear).
    func testHookVisibilityFollowsScreenAppearance() throws {
        let delegate = DelegateSpy()
        let hosting = host(StartScreenView(
            snapshot: TileGridSnapshot(items: [], unpinned: []),
            leftPanel: QuickPanelProvider { UIViewController() },
            delegate: delegate
        ))
        let screen = try screen(in: hosting)
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()

        screen.showPage(.quickPanel, animated: false)
        XCTAssertEqual(delegate.hookVisibility, [true])
        XCTAssertEqual(delegate.pages, [.quickPanel])

        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
        XCTAssertEqual(delegate.hookVisibility, [true, false])

        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        XCTAssertEqual(delegate.hookVisibility, [true, false, true])
    }
}

#endif
