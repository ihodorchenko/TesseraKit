//
//  TileEditButtonGapTapTests.swift
//  TesseraStartScreenTests
//
//  Тап по выступающей части кнопки правки (E15.10): кнопки «открепить» и
//  «размер» на плитке сетки выступают за рамку плитки (`cornerOverhang`, 6 pt),
//  то есть в зазор между плитками. Тап по этой части раньше срабатывал и по
//  кнопке (открепление/размер), и по жесту «тап по фону» (зазор — не плитка):
//  правка неожиданно заканчивалась. Теперь жест фона не принимает касания,
//  которые попадают в зону касания любого оверлея правки — по тому же
//  `hitTest`, что и сами кнопки. Проектный документ:
//  docs/STARTSCREEN-IOS-DESIGN.md, «Отступления реализации (E14)», п. 58.
//
//  Симуляция касания: настоящий `hitTest` окна определяет вид под пальцем,
//  жест фона получает `UITouch` с этим видом и точкой (`shouldReceive`), затем
//  выполняются действия кнопки `touchUpInside` и (если жест принял касание)
//  действие жеста фона. Без `sleep`: ожидание — прокруткой run loop.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditButtonGapTapTests: XCTestCase {

    // MARK: - Помощники

    /// Касание с заданными видом и точкой (у `UITouch` нет публичного init'а
    /// с параметрами, поэтому подкласс переопределяет нужные геттеры).
    private final class TouchStub: UITouch {
        private let stubWindow: UIWindow
        private let windowPoint: CGPoint
        private let stubView: UIView?

        init(window: UIWindow, point: CGPoint, view: UIView?) {
            stubWindow = window
            windowPoint = point
            stubView = view
            super.init()
        }

        override var view: UIView? { stubView }
        override var window: UIWindow? { stubWindow }

        override func location(in view: UIView?) -> CGPoint {
            guard let view else { return windowPoint }
            return view.convert(windowPoint, from: stubWindow)
        }
    }

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var events: [String] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            events.append("unpin:\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didResize tileID: AnyHashable,
            to size: TileSize
        ) {
            events.append("resize:\(tileID)")
        }
    }

    /// Результат касания.
    private struct Outcome {
        /// Вид под пальцем по настоящему `hitTest` окна.
        let hit: UIView?
        /// Принял ли касание жест «тап по фону».
        let backgroundReceived: Bool
    }

    /// Стенд: четыре средние плитки (2 × 2 при 4 колонках), правка включена.
    private func makeHost(rightToLeft: Bool = false) throws -> (TesseraTestDragHost, Recorder) {
        let host = TesseraTestDragHost(
            descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        if rightToLeft {
            host.host.grid.semanticContentAttribute = .forceRightToLeft
            host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
            host.host.layout()
        }
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        host.spin(0.03)
        if rightToLeft {
            for control in host.coordinator.editControls.values {
                control.semanticContentAttribute = .forceRightToLeft
                control.setNeedsLayout()
                control.layoutIfNeeded()
            }
        }
        XCTAssertTrue(host.coordinator.isEditing)
        return (host, recorder)
    }

    private func control(
        _ id: AnyHashable,
        in host: TesseraTestDragHost
    ) throws -> TesseraTileEditControlView {
        let control = try XCTUnwrap(host.coordinator.editControls[id], "оверлей \(id)")
        control.layoutIfNeeded()
        return control
    }

    /// Рамка в координатах сетки (контейнер кнопок совпадает с `bounds` сетки).
    private func gridFrame(_ rect: CGRect, of control: TesseraTileEditControlView, in host: TesseraTestDragHost) -> CGRect {
        control.convert(rect, to: host.host.grid)
    }

    /// Прогоняет касание в точке сетки: решение жеста фона, действие кнопки
    /// под пальцем, затем действие жеста фона, если он принял касание.
    @discardableResult
    private func tap(_ point: CGPoint, in host: TesseraTestDragHost) -> Outcome {
        let outcome = touchDown(at: point, in: host)
        // Отпускание: кнопка (`touchUpInside`) и жест фона.
        if let button = outcome.hit as? UIButton {
            for target in button.allTargets {
                for action in button.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                    _ = (target as AnyObject).perform(Selector(action))
                }
            }
        }
        if outcome.backgroundReceived {
            host.coordinator.performBackgroundTap(at: point)
        }
        return outcome
    }

    /// Только решение о приёме касания (без действий).
    private func touchDown(at point: CGPoint, in host: TesseraTestDragHost) -> Outcome {
        let window = host.host.window
        let windowPoint = host.host.grid.convert(point, to: window)
        let hit = window.hitTest(windowPoint, with: nil)
        let touch = TouchStub(window: window, point: windowPoint, view: hit)
        let recognizer = host.coordinator.backgroundTapGestureRecognizer
        let received = recognizer.isEnabled
            && host.coordinator.gestureRecognizer(recognizer, shouldReceive: touch)
        return Outcome(hit: hit, backgroundReceived: received)
    }

    /// Точка внутри видимой кнопки, **вне рамки плитки** и в зазоре (под ней
    /// нет плитки), ближайшая к центру кнопки: «выступающая часть».
    private func overhangPoint(
        button: CGRect,
        tile: CGRect,
        in host: TesseraTestDragHost
    ) throws -> CGPoint {
        var best: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var x = button.minX + 0.5
        while x < button.maxX {
            var y = button.minY + 0.5
            while y < button.maxY {
                let point = CGPoint(x: x, y: y)
                if !tile.contains(point), host.host.grid.item(at: point) == nil {
                    let distance = hypot(x - button.midX, y - button.midY)
                    if distance < bestDistance {
                        best = point
                        bestDistance = distance
                    }
                }
                y += 1
            }
            x += 1
        }
        return try XCTUnwrap(best, "у кнопки нет части в зазоре")
    }

    /// Сколько единиц событий делегата с префиксом.
    private func waitForEvent(_ event: String, _ recorder: Recorder, _ host: TesseraTestDragHost) -> Bool {
        host.waitUntil { recorder.events.contains(event) }
    }

    // MARK: - Воспроизведение ошибки: кнопка открепления

    /// Тап по выступающей в зазор части кнопки открепления: ярлык откреплён, а
    /// правка **остаётся** (раньше сразу заканчивалась).
    func testTapOnUnpinOverhangInGapUnpinsAndKeepsEditing() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t3"
        let control = try control(id, in: host)
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: id))
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let point = try overhangPoint(button: button, tile: tile, in: host)

        XCTAssertNil(host.host.grid.item(at: point), "точка — в зазоре, не на плитке")
        XCTAssertFalse(tile.contains(point))
        let outcome = touchDown(at: point, in: host)
        XCTAssertTrue(outcome.hit is UIButton, "под пальцем — кнопка")
        XCTAssertFalse(outcome.backgroundReceived, "жест фона не принимает касание в кнопке")

        tap(point, in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host), "кнопка сработала")
        XCTAssertTrue(host.coordinator.isEditing, "правка не закончилась")
    }

    /// То же для кнопки размера: размер сменён, правка остаётся.
    func testTapOnResizeOverhangInGapResizesAndKeepsEditing() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t0"
        let control = try control(id, in: host)
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: id))
        let button = gridFrame(control.resizeButtonFrame, of: control, in: host)
        let point = try overhangPoint(button: button, tile: tile, in: host)

        XCTAssertNil(host.host.grid.item(at: point))
        let outcome = touchDown(at: point, in: host)
        XCTAssertTrue(outcome.hit is UIButton)
        XCTAssertFalse(outcome.backgroundReceived)

        tap(point, in: host)
        XCTAssertTrue(recorder.events.contains("resize:t0"), "кнопка сработала")
        XCTAssertTrue(host.coordinator.isEditing, "правка не закончилась")
    }

    // MARK: - Расширенная зона касания (44 pt)

    /// Точки зоны касания вне видимой кнопки (расширение до 44 pt) ведут себя
    /// как сама кнопка: касание уходит кнопке, жест фона его не принимает —
    /// и в зазоре слева, и над плиткой верхнего ряда.
    func testExtendedHitZoneBehavesLikeTheButton() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t3"
        let control = try control(id, in: host)
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let hit = gridFrame(control.unpinHitFrame, of: control, in: host)
        XCTAssertGreaterThan(hit.width, button.width, "зона шире кнопки")

        // Слева от кнопки: в зазоре между плитками (глубже зазора — другая плитка).
        let left = CGPoint(x: button.minX - 1, y: button.midY)
        XCTAssertTrue(hit.contains(left))
        XCTAssertFalse(button.contains(left))
        XCTAssertNil(host.host.grid.item(at: left), "точка — в зазоре")
        let outcome = touchDown(at: left, in: host)
        XCTAssertTrue(outcome.hit is UIButton)
        XCTAssertFalse(outcome.backgroundReceived)

        tap(left, in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing)
    }

    /// Расширенная зона над верхним краем плитки первого ряда (поле сетки):
    /// касание тоже принадлежит кнопке, а не фону.
    func testExtendedHitZoneAboveTopRowDoesNotExitEditing() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t0"
        let control = try control(id, in: host)
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let hit = gridFrame(control.unpinHitFrame, of: control, in: host)
        let above = CGPoint(x: button.midX, y: button.minY - 1)
        try XCTSkipUnless(above.y > 0 && hit.contains(above), "кнопка прижата к краю сетки")
        XCTAssertFalse(button.contains(above))
        XCTAssertNil(host.host.grid.item(at: above))

        let outcome = touchDown(at: above, in: host)
        XCTAssertTrue(outcome.hit is UIButton)
        XCTAssertFalse(outcome.backgroundReceived)
        tap(above, in: host)
        XCTAssertTrue(waitForEvent("unpin:t0", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing)
    }

    // MARK: - Пустое место и тело плитки: без изменений

    /// Тап в зазоре вне зон всех кнопок по-прежнему выходит из правки.
    func testTapInPureGapStillExitsEditing() throws {
        let (host, recorder) = try makeHost()
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let t1 = try XCTUnwrap(host.host.grid.frame(forItemID: "t1"))
        // Середина вертикального зазора между t0 и t1: далеко от углов плиток.
        let point = CGPoint(x: (t0.maxX + t1.minX) / 2, y: t0.midY)
        XCTAssertNil(host.host.grid.item(at: point))

        let outcome = touchDown(at: point, in: host)
        XCTAssertNil(outcome.hit as? UIButton)
        XCTAssertTrue(outcome.backgroundReceived, "пустое место принимает жест фона")

        tap(point, in: host)
        XCTAssertFalse(host.coordinator.isEditing, "тап по пустому месту — выход")
        XCTAssertTrue(recorder.events.isEmpty, "кнопки не срабатывали")
    }

    /// Тап по телу любой плитки (в том числе «приглушённой») правку не
    /// заканчивает, как и раньше; жест фона касание принимает (решает сетка).
    func testTapOnTileBodyKeepsEditingAsBefore() throws {
        let (host, recorder) = try makeHost()
        for id in ["t0", "t1", "t2", "t3"] {
            let center = try XCTUnwrap(host.point(AnyHashable(id)))
            let outcome = touchDown(at: center, in: host)
            XCTAssertNil(outcome.hit as? UIButton, id)
            XCTAssertTrue(outcome.backgroundReceived, "тело плитки \(id): решение за сеткой, как раньше")
            tap(center, in: host)
            XCTAssertTrue(host.coordinator.isEditing, "\(id)")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - Соседние плитки: пересекающиеся зоны

    /// В перекрёстке зазоров сходятся зоны трёх кнопок разных плиток (стрелка
    /// размера t0 и открепления t1 и t2, t3): касание достаётся одной из них
    /// (как раньше — по порядку подвью), правка остаётся.
    func testOverlappingZonesOfNeighbouringTilesKeepEditing() throws {
        let (host, recorder) = try makeHost()
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        // Перекрёсток зазоров между четырьмя плитками.
        let point = CGPoint(x: (t0.maxX + t3.minX) / 2, y: (t0.maxY + t3.minY) / 2)
        XCTAssertNil(host.host.grid.item(at: point))

        let outcome = touchDown(at: point, in: host)
        XCTAssertTrue(outcome.hit is UIButton, "в перекрёстке — кнопка какой-то из плиток")
        XCTAssertFalse(outcome.backgroundReceived)

        tap(point, in: host)
        XCTAssertTrue(host.coordinator.isEditing)
        // Сработала ровно одна кнопка (resize t0 синхронно либо unpin t3 после полёта).
        host.spin(0.4)
        XCTAssertEqual(recorder.events.count, 1, "\(recorder.events)")
        XCTAssertTrue(host.coordinator.isEditing)
    }

    // MARK: - Единый источник правды: зоны кнопок и жест фона

    /// По всей сетке: жест фона принимает касание тогда и только тогда, когда
    /// под ним не кнопка оверлея правки (`hitTest` окна ↔ `shouldReceive`).
    func testBackgroundRecognizerAgreesWithButtonHitTestAcrossGrid() throws {
        let (host, _) = try makeHost()
        let grid = host.host.grid
        var sawButton = false
        var sawBackground = false
        var y: CGFloat = 1
        while y < grid.bounds.height {
            var x: CGFloat = 1
            while x < grid.bounds.width {
                let outcome = touchDown(at: CGPoint(x: x, y: y), in: host)
                let isButton = outcome.hit is UIButton
                XCTAssertEqual(outcome.backgroundReceived, !isButton, "(\(x), \(y))")
                sawButton = sawButton || isButton
                sawBackground = sawBackground || outcome.backgroundReceived
                x += 3
            }
            y += 3
        }
        XCTAssertTrue(sawButton && sawBackground)
    }

    // MARK: - RTL

    /// RTL: кнопки зеркалятся (открепление — вверху справа, размер — внизу
    /// слева); касание по выступающей части каждой не выводит из правки.
    func testRightToLeftOverhangsKeepEditing() throws {
        let (host, recorder) = try makeHost(rightToLeft: true)

        // Открепление t3: зеркальный угол — правый верхний.
        let t3Control = try control("t3", in: host)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let unpinButton = gridFrame(t3Control.unpinButtonFrame, of: t3Control, in: host)
        XCTAssertGreaterThan(unpinButton.midX, t3.midX, "RTL: кнопка открепления справа")
        let unpinPoint = try overhangPoint(button: unpinButton, tile: t3, in: host)
        let unpinOutcome = touchDown(at: unpinPoint, in: host)
        XCTAssertTrue(unpinOutcome.hit is UIButton)
        XCTAssertFalse(unpinOutcome.backgroundReceived)
        tap(unpinPoint, in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing)

        // Размер t0: зеркальный угол — левый нижний.
        let t0Control = try control("t0", in: host)
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let resizeButton = gridFrame(t0Control.resizeButtonFrame, of: t0Control, in: host)
        XCTAssertLessThan(resizeButton.midX, t0.midX, "RTL: стрелка размера слева")
        let resizePoint = try overhangPoint(button: resizeButton, tile: t0, in: host)
        let resizeOutcome = touchDown(at: resizePoint, in: host)
        XCTAssertTrue(resizeOutcome.hit is UIButton)
        XCTAssertFalse(resizeOutcome.backgroundReceived)
        tap(resizePoint, in: host)
        XCTAssertTrue(recorder.events.contains("resize:t0"))
        XCTAssertTrue(host.coordinator.isEditing)
    }

    /// RTL: пустое место по-прежнему выходит из правки.
    func testRightToLeftPureGapStillExitsEditing() throws {
        let (host, _) = try makeHost(rightToLeft: true)
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let t1 = try XCTUnwrap(host.host.grid.frame(forItemID: "t1"))
        let left = min(t0.maxX, t1.maxX)
        let right = max(t0.minX, t1.minX)
        let point = CGPoint(x: (left + right) / 2, y: t0.midY)
        XCTAssertNil(host.host.grid.item(at: point))
        XCTAssertTrue(touchDown(at: point, in: host).backgroundReceived)
        tap(point, in: host)
        XCTAssertFalse(host.coordinator.isEditing)
    }

    // MARK: - Кнопки панели папки

    private func makePanelHost() throws -> (TesseraTestDragHost, Recorder) {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a0", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil { host.coordinator.panelEditControls.count == 3 })
        for control in host.coordinator.panelEditControls.values { control.layoutIfNeeded() }
        return (host, recorder)
    }

    /// Кнопки панели не затронуты: тап по кнопке (центр и выступающая часть)
    /// открепляет ярлык, правка остаётся; жест фона такое касание не принимает.
    func testPanelButtonTapKeepsEditing() throws {
        let (host, recorder) = try makePanelHost()
        let geometry = try XCTUnwrap(host.host.grid.panelShortcutGeometry())
        let tileID = geometry.tileIDs[0]
        let control = try XCTUnwrap(host.coordinator.panelEditControls[tileID])
        let tile = geometry.frames[0]
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let center = CGPoint(x: button.midX, y: button.midY)
        let overhang = try? overhangPoint(button: button, tile: tile, in: host)

        for point in [center, overhang].compactMap({ $0 }) {
            let outcome = touchDown(at: point, in: host)
            XCTAssertTrue(outcome.hit is UIButton, "(\(point.x), \(point.y))")
            XCTAssertFalse(outcome.backgroundReceived, "(\(point.x), \(point.y))")
        }
        tap(center, in: host)
        XCTAssertTrue(waitForEvent("unpin:\(tileID)", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing, "правка не закончилась")
    }

    /// Панель: зона касания кнопок и жест фона согласованы по всей сетке; тело
    /// ярлыка панели вне угловой четверти кнопку не считает и жест принимает.
    func testPanelBackgroundRecognizerAgreesWithButtonHitTest() throws {
        let (host, _) = try makePanelHost()
        let grid = host.host.grid
        var sawButton = false
        var y: CGFloat = 1
        while y < grid.bounds.height {
            var x: CGFloat = 1
            while x < grid.bounds.width {
                let outcome = touchDown(at: CGPoint(x: x, y: y), in: host)
                let isButton = outcome.hit is UIButton
                XCTAssertEqual(outcome.backgroundReceived, !isButton, "(\(x), \(y))")
                sawButton = sawButton || isButton
                x += 3
            }
            y += 3
        }
        XCTAssertTrue(sawButton)

        let geometry = try XCTUnwrap(grid.panelShortcutGeometry())
        let body = CGPoint(x: geometry.frames[0].midX, y: geometry.frames[0].midY)
        let outcome = touchDown(at: body, in: host)
        XCTAssertNil(outcome.hit as? UIButton)
        XCTAssertTrue(outcome.backgroundReceived)
    }

    // MARK: - Включение жеста

    /// Жест фона включён только в правке; вне правки касания не принимает.
    func testBackgroundRecognizerFollowsEditMode() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        let recognizer = host.coordinator.backgroundTapGestureRecognizer
        XCTAssertFalse(recognizer.isEnabled)
        XCTAssertTrue(recognizer.cancelsTouchesInView == false)

        host.coordinator.beginEditing()
        XCTAssertTrue(recognizer.isEnabled)
        XCTAssertFalse(recognizer.cancelsTouchesInView, "семантика cancelsTouchesInView прежняя")

        host.coordinator.endEditing()
        XCTAssertFalse(recognizer.isEnabled)
        let point = try XCTUnwrap(host.point("t0"))
        XCTAssertFalse(touchDown(at: point, in: host).backgroundReceived)
    }
}

#endif
