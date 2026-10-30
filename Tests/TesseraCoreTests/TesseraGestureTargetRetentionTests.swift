//
//  TesseraGestureTargetRetentionTests.swift
//  TesseraCoreTests
//
//  Доказательный тест к E9.1 (К1 ревью): удерживает ли `UIGestureRecognizer`
//  свой таргет. Pivot, Panorama и StartScreen подписываются на пан скролл-вью
//  пейджера через `pan.addTarget(self, …)` и снимают таргет в `deinit`. Если бы
//  UIKit удерживал таргет сильно, получился бы цикл «контроллер → пейджер →
//  скролл-вью → пан → контроллер», и `deinit` был бы недостижим.
//
//  Вывод (зафиксирован тестами ниже): UIKit таргет НЕ удерживает — ссылка
//  слабая и обнуляемая; цикла нет, `deinit` контроллера вызывается. Поэтому
//  слабый proxy-таргет в Core не нужен.
//

#if canImport(UIKit)

import XCTest
import UIKit
@testable import TesseraCore

/// Таргет-пустышка: только принимает action.
private final class TargetProbe: NSObject {
    @objc func handle(_ sender: UIGestureRecognizer) {}
}

/// Хост реального сценария: встраивает пейджер Core и подписывается на пан его
/// скролл-вью ровно так, как это делают контроллеры компонентов
/// (`addTarget(self, …)` + `removeTarget` в `deinit`).
private final class PagerHostProbe: UIViewController {
    let pager = TesseraPagerViewController(
        mode: .paged,
        pages: (0..<3).map { index in
            TesseraPageDescriptor(id: index, title: "Страница \(index)") { UIViewController() }
        }
    )
    private weak var observedPan: UIPanGestureRecognizer?
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager)
        pager.view.frame = view.bounds
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
    }

    /// Находит скролл-вью пейджера (тот же обход, что в Pivot/StartScreen)
    /// и подписывается на его пан.
    func attachToPagerPan() -> Bool {
        guard let scrollView = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first else {
            return false
        }
        let pan = scrollView.panGestureRecognizer
        pan.addTarget(self, action: #selector(pagerPanDidChange(_:)))
        observedPan = pan
        return true
    }

    @objc private func pagerPanDidChange(_ pan: UIPanGestureRecognizer) {}

    deinit {
        observedPan?.removeTarget(self, action: #selector(pagerPanDidChange(_:)))
        onDeinit()
    }
}

final class TesseraGestureTargetRetentionTests: XCTestCase {

    // MARK: - Поведение UIKit

    /// `addTarget(_:action:)` не удерживает таргет: после выхода из пула
    /// таргет освобождается, хотя распознаватель жив и таргет не снят.
    func testGestureRecognizerDoesNotRetainAddedTarget() {
        let pan = UIPanGestureRecognizer()
        weak var weakTarget: TargetProbe?

        autoreleasepool {
            let target = TargetProbe()
            weakTarget = target
            pan.addTarget(target, action: #selector(TargetProbe.handle(_:)))
        }

        XCTAssertNil(weakTarget, "UIGestureRecognizer не должен удерживать таргет")
        withExtendedLifetime(pan) {}
    }

    /// То же для таргета, переданного в `init(target:action:)`.
    func testGestureRecognizerDoesNotRetainInitTarget() {
        var pan: UIPanGestureRecognizer?
        weak var weakTarget: TargetProbe?

        autoreleasepool {
            let target = TargetProbe()
            weakTarget = target
            pan = UIPanGestureRecognizer(target: target, action: #selector(TargetProbe.handle(_:)))
        }

        XCTAssertNotNil(pan)
        XCTAssertNil(weakTarget, "init(target:action:) не должен удерживать таргет")
    }

    /// Встроенный пан `UIScrollView` ведёт себя так же: внешний таргет,
    /// добавленный аддитивно, не удерживается.
    func testScrollViewPanDoesNotRetainAddedTarget() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        weak var weakTarget: TargetProbe?

        autoreleasepool {
            let target = TargetProbe()
            weakTarget = target
            scrollView.panGestureRecognizer.addTarget(target, action: #selector(TargetProbe.handle(_:)))
        }

        XCTAssertNil(weakTarget, "Пан UIScrollView не должен удерживать внешний таргет")
        withExtendedLifetime(scrollView) {}
    }

    /// Освобождённый таргет не мешает дальнейшей работе распознавателя:
    /// снятие таргетов и повторное добавление не падают.
    func testRecognizerStaysUsableAfterTargetDeallocates() {
        let pan = UIPanGestureRecognizer()

        autoreleasepool {
            let target = TargetProbe()
            pan.addTarget(target, action: #selector(TargetProbe.handle(_:)))
        }

        pan.removeTarget(nil, action: nil)
        let survivor = TargetProbe()
        pan.addTarget(survivor, action: #selector(TargetProbe.handle(_:)))
        pan.removeTarget(survivor, action: #selector(TargetProbe.handle(_:)))
    }

    // MARK: - Реальный сценарий E9.1

    /// Контроллер, встроивший пейджер Core и подписавшийся таргетом на пан его
    /// скролл-вью, освобождается: цикла удержания нет, `deinit` достижим
    /// (и снимает таргет). Проверяется и вне окна, и в окне.
    func testHostSubscribedToPagerPanIsDeallocated() throws {
        for inWindow in [false, true] {
            var deinitCalled = false
            weak var weakHost: PagerHostProbe?
            var attached = false

            autoreleasepool {
                let host = PagerHostProbe { deinitCalled = true }
                weakHost = host
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                if inWindow {
                    window.rootViewController = host
                    window.isHidden = false
                } else {
                    host.loadViewIfNeeded()
                    host.view.frame = window.bounds
                }
                host.view.layoutIfNeeded()
                attached = host.attachToPagerPan()
                if inWindow {
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }

            XCTAssertTrue(attached, "Скролл-вью пейджера должен находиться обходом иерархии (inWindow=\(inWindow))")
            XCTAssertNil(weakHost, "Хост с таргетом на пане пейджера должен освобождаться (inWindow=\(inWindow))")
            XCTAssertTrue(deinitCalled, "deinit хоста должен быть достижим (inWindow=\(inWindow))")
        }
    }
}

#endif
