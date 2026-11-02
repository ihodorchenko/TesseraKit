//
//  PivotContentUpdateTests.swift
//  TesseraPivotTests
//
//  Контрактные тесты обновления контента секций (задача E10.12а).
//  Проектный документ: docs/PIVOT-IOS-DESIGN.md §3 «Архитектура» (SwiftUI-фасад
//  `PivotView`), §5 «Синхронизация» (один писатель `contentOffset`),
//  docs/CORE-IOS-DESIGN.md «Отступления реализации» п. 7 (W1: `reload` пейджера
//  сохраняет страницу и контроллеры по `id`, SwiftUI-контент обновляется через
//  `TesseraContentHosting`).
//
//  Проверяются: новый контент при тех же `id`/заголовках доходит до страниц
//  (и через `PivotView`, и через контроллер); страница, контроллеры, скролл и
//  `@StateObject` контента сохраняются; во время перехода обновление
//  откладывается; колбэк прогресса не вызывается синхронно внутри `reload`.
//

#if canImport(UIKit) && canImport(SwiftUI)

import XCTest
import UIKit
import SwiftUI
import TesseraCore
@testable import TesseraPivot

/// Счётчик созданий состояния SwiftUI-страницы: пересоздание `@StateObject`
/// означает потерю `@State` контента.
final class PivotProbeToken: ObservableObject {
    static var createdCount = 0

    init() {
        Self.createdCount += 1
    }
}

/// SwiftUI-контент страницы с наблюдаемым значением и собственным состоянием.
struct PivotProbeContent: View {
    let value: String
    @StateObject private var token = PivotProbeToken()

    var body: some View {
        ScrollView {
            Text(value)
        }
    }
}

/// Хранилище SwiftUI-харнесса: смена значения перерисовывает `PivotView`.
final class PivotProbeStore: ObservableObject {
    @Published var value = "A"
}

/// Харнесс фасада: секции с теми же `id`/заголовками, контент зависит от
/// состояния хранилища.
struct PivotProbeHarness: View {
    @ObservedObject var store: PivotProbeStore
    let delegate: PivotDelegate?

    var body: some View {
        let value = store.value
        return PivotView(
            sections: (0..<3).map { index in
                PivotSection(
                    id: index,
                    title: "S\(index)",
                    content: TesseraSwiftUIContentProvider {
                        PivotProbeContent(value: "\(value)-\(index)")
                    }
                )
            },
            delegate: delegate
        )
    }
}

final class PivotContentUpdateTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    // MARK: - Вспомогательные средства

    private func spinRunLoop(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeSections(value: String, count: Int = 4) -> [PivotSection] {
        (0..<count).map { index in
            PivotSection(
                id: index,
                title: "S\(index)",
                content: TesseraSwiftUIContentProvider {
                    PivotProbeContent(value: "\(value)-\(index)")
                }
            )
        }
    }

    private func host(_ controller: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        self.window = window
        spinRunLoop()
    }

    /// SwiftUI-страницы пейджера по значению их контента.
    private func pageHosts(
        of pivot: PivotViewController
    ) -> [UIHostingController<PivotProbeContent>] {
        pivot.pagerViewController.children.compactMap {
            $0 as? UIHostingController<PivotProbeContent>
        }
    }

    private func pageHost(
        _ index: Int,
        of pivot: PivotViewController
    ) -> UIHostingController<PivotProbeContent>? {
        pageHosts(of: pivot).first { $0.rootView.value.hasSuffix("-\(index)") }
    }

    // MARK: - Контроллер: обновление контента без потери состояния

    /// Тот же набор `id`/заголовков с новым контентом: страница остаётся
    /// прежней, контроллеры переиспользуются, `rootView` обновлён.
    func testRefreshSectionContentUpdatesExistingPagesInPlace() throws {
        let pivot = PivotViewController(sections: makeSections(value: "A"))
        host(pivot)
        pivot.selectSection(at: 2, animated: false)
        let scrollView = try XCTUnwrap(pivot.pagerScrollView)
        let offsetBefore = scrollView.contentOffset
        let hostBefore = try XCTUnwrap(pageHost(2, of: pivot))

        pivot.refreshSectionContent(makeSections(value: "B"))

        let hostAfter = try XCTUnwrap(pageHost(2, of: pivot))
        XCTAssertTrue(hostAfter === hostBefore, "Контроллер страницы переиспользуется")
        XCTAssertEqual(hostAfter.rootView.value, "B-2")
        XCTAssertEqual(pageHost(1, of: pivot)?.rootView.value, "B-1")
        XCTAssertEqual(pivot.currentSectionIndex, 2)
        XCTAssertEqual(scrollView.contentOffset, offsetBefore)
    }

    /// Обновление во время анимированного перехода откладывается (reload
    /// пейджера оборвал бы анимацию) и применяется по его завершении.
    func testRefreshSectionContentIsDeferredDuringAnimatedTransition() throws {
        try XCTSkipIf(TesseraAccessibility.isReduceMotionEnabled, "Нужен анимированный переход")
        let pivot = PivotViewController(sections: makeSections(value: "A"))
        host(pivot)

        pivot.selectSection(at: 1, animated: true)
        XCTAssertTrue(pivot.isTransitionInFlight)

        pivot.refreshSectionContent(makeSections(value: "B"))
        XCTAssertEqual(pageHost(0, of: pivot)?.rootView.value, "A-0", "Во время перехода контент не трогаем")

        pivot.pager(pivot.pagerViewController, didShowPageAt: 1)

        XCTAssertFalse(pivot.isTransitionInFlight)
        XCTAssertEqual(pageHost(1, of: pivot)?.rootView.value, "B-1", "Отложенный контент применён")
    }

    // MARK: - Прогресс не вызывается синхронно внутри reload

    /// `reload`, меняющий положение текущей секции, не зовёт
    /// `didChangeProgress` синхронно; итоговое значение приходит следующим
    /// проходом главной очереди.
    func testReloadDefersProgressCallback() throws {
        let pivot = PivotViewController(sections: makeSections(value: "A"))
        host(pivot)
        pivot.selectSection(at: 2, animated: false)
        let spy = PivotTransitionSpy()
        pivot.delegate = spy

        // Секция 2 переезжает в начало: прогресс меняется 2 → 0.
        let reordered = makeSections(value: "A")
        pivot.reload(sections: [reordered[2], reordered[0], reordered[1], reordered[3]])

        XCTAssertEqual(spy.progressValues, [], "Колбэк прогресса не должен вызываться внутри reload")
        XCTAssertEqual(pivot.currentSectionIndex, 0)

        spinRunLoop(0.05)
        XCTAssertEqual(spy.progressValues, [0])
    }

    /// `reload` с тем же положением не порождает колбэков прогресса вовсе —
    /// нет цикла «колбэк → состояние SwiftUI → обновление → reload».
    func testReloadWithUnchangedProgressDoesNotNotifyDelegate() throws {
        let pivot = PivotViewController(sections: makeSections(value: "A"))
        host(pivot)
        pivot.selectSection(at: 1, animated: false)
        let spy = PivotTransitionSpy()
        pivot.delegate = spy

        pivot.reload(sections: makeSections(value: "B"))
        spinRunLoop(0.05)

        XCTAssertEqual(spy.progressValues, [])
    }

    // MARK: - SwiftUI-фасад

    /// `PivotView` доносит новый контент секций с теми же `id`/заголовками
    /// (до E10.12а `sectionsDiffer` сравнивал только `id`+`title` и reload не
    /// вызывался): страница, хостинг-контроллер и `@StateObject` сохраняются.
    func testPivotViewPropagatesContentForSameIdentifiers() throws {
        let store = PivotProbeStore()
        let spy = PivotTransitionSpy()
        let hosting = UIHostingController(rootView: PivotProbeHarness(store: store, delegate: spy))
        host(hosting)

        let pivot = try XCTUnwrap(
            hosting.children.compactMap { $0 as? PivotViewController }.first,
            "PivotView должен встроить PivotViewController"
        )
        pivot.selectSection(at: 1, animated: false)
        spinRunLoop()

        let hostBefore = try XCTUnwrap(pageHost(1, of: pivot))
        XCTAssertEqual(hostBefore.rootView.value, "A-1")
        let tokensBefore = PivotProbeToken.createdCount
        XCTAssertGreaterThan(tokensBefore, 0, "Предусловие: SwiftUI-страница отрисована и создала @StateObject")
        let progressCountBefore = spy.progressValues.count

        store.value = "B"
        spinRunLoop()
        hosting.view.layoutIfNeeded()

        let hostAfter = try XCTUnwrap(pageHost(1, of: pivot))
        XCTAssertTrue(hostAfter === hostBefore, "Хостинг страницы переиспользуется")
        XCTAssertEqual(hostAfter.rootView.value, "B-1", "Новый контент дошёл до страницы")
        XCTAssertEqual(pivot.currentSectionIndex, 1, "Текущая секция сохранена")
        XCTAssertEqual(PivotProbeToken.createdCount, tokensBefore, "@StateObject контента не пересоздан")
        XCTAssertEqual(spy.progressValues.count, progressCountBefore, "Обновление контента не шлёт прогресс")
    }
}

#endif
