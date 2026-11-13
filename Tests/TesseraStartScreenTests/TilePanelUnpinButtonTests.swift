//
//  TilePanelUnpinButtonTests.swift
//  TesseraStartScreenTests
//
//  Кнопка открепления на ярлыках раскрытой панели папки в режиме правки (D46,
//  13.11.2026). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления
//  реализации (E14)», п. 57; решение D46 в docs/STATE.md; эталон —
//  docs/W10M-STARTSCREEN.md §6.5, §6.6, §6.9.
//
//  Проверяется на настоящем `TileStore` и сетке в окне (`TesseraTestDragHost`):
//  - кнопка есть у каждого ярлыка панели только в правке и только когда панель
//    устоялась; нет у плитки-папки (D38); стрелки размера у ярлыка панели нет;
//  - размер и угол те же, что у кнопки на плитке сетки (общий помощник угла);
//  - правило зоны касания: угловая четверть ярлыка, не дальше выступа за рамку,
//    не меньше 44 pt там, где помещается; центр и тело ярлыка — не кнопка;
//    RTL зеркалится; пересечения решает ближайший центр;
//  - тап: полёт ярлыка, `unpin`, `didUnpin`, фокус; в папке из двух — распад
//    (D45); Reduce Motion — без полёта; повторный тап в полёте игнорируется;
//  - кнопки идут за панелью (прокрутка, смена ширины), снимаются при закрытии
//    панели, при drag из панели и вне правки; десктопные кнопки не затронуты.
//
//  Раскладки точные (`TileStoreCellFixture`), 4 колонки; без `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePanelUnpinButtonTests: XCTestCase {

    // MARK: - Помощники

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var events: [String] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            events.append("unpin:\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            events.append("dissolve:\(folderID)>\(tileID)")
        }
    }

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func record(_ host: TesseraTestDragHost) -> PostRecorder {
        let recorder = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            recorder.posts.append((notification, argument))
        }
        return recorder
    }

    /// Стенд: папка F (medium, (0,0)) из `contents`, плитка `a` под ней и ряд
    /// плиток ниже (для прокрутки).
    private func makeHost(
        contents: [(String, TileSize)] = [("x", .small), ("y", .small), ("z", .small)],
        rowsBelow: Int = 1
    ) throws -> TesseraTestDragHost {
        let tiles = (0..<rowsBelow).map { CellFixtureTile("a\($0)", .small, 3 + $0, 0) }
        return try TesseraTestDragHost(
            cells: tiles,
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)]
        )
    }

    /// Входит в правку и раскрывает панель без анимации.
    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost, folderID: AnyHashable = "F") throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        })
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    private func control(
        _ tileID: AnyHashable,
        in host: TesseraTestDragHost
    ) throws -> TesseraTileEditControlView {
        let control = try XCTUnwrap(host.coordinator.panelEditControls[tileID], "кнопка ярлыка \(tileID)")
        control.layoutIfNeeded()
        return control
    }

    private func buttons(of control: TesseraTileEditControlView) -> [UIButton] {
        control.subviews.compactMap { $0 as? UIButton }
    }

    private func visibleButtons(of control: TesseraTileEditControlView) -> [UIButton] {
        buttons(of: control).filter { !$0.isHidden }
    }

    /// Тап по видимой кнопке оверлея (как касание пальцем: `touchUpInside`).
    private func tap(_ control: TesseraTileEditControlView, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = visibleButtons(of: control).first else {
            return XCTFail("Нет видимой кнопки", file: file, line: line)
        }
        // `sendActions(for:)` без приложения-хоста (логические тесты) цели не
        // вызывает: выполняем зарегистрированные на `touchUpInside` действия сами.
        for target in button.allTargets {
            for action in button.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                _ = (target as AnyObject).perform(Selector(action))
            }
        }
    }

    /// Ждёт конца перехода панели и применения отложенного снимка сеткой.
    private func waitForFolderTransitionDone(_ host: TesseraTestDragHost) -> Bool {
        host.host.waitForFolderTransition() && host.waitUntil { host.gridIDs == host.storeIDs }
    }

    private func panelFrames(_ host: TesseraTestDragHost) throws -> TesseraPanelShortcutGeometry {
        try XCTUnwrap(host.host.grid.panelShortcutGeometry())
    }

    private func flyingSnapshots(_ host: TesseraTestDragHost) -> [UIView] {
        host.host.grid.subviews.filter { $0.layer.zPosition == 1000 }
    }

    // MARK: - Наличие

    /// В правке у каждого ярлыка панели — кнопка открепления, без стрелки размера;
    /// кнопка стоит в контейнере кнопок и совпадает с рамкой ярлыка; снимается
    /// вместе с выходом из правки.
    func testEveryPanelTileHasOnlyUnpinButtonInEditMode() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try panelFrames(host)

        XCTAssertEqual(Set(host.coordinator.panelEditControls.keys), ["x", "y", "z"] as Set<AnyHashable>)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)
        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            XCTAssertTrue(control.isPanelMember)
            XCTAssertTrue(control.superview === container)
            XCTAssertEqual(control.frame.minX, geometry.frames[index].minX, accuracy: 0.5)
            XCTAssertEqual(control.frame.minY, geometry.frames[index].minY, accuracy: 0.5)
            XCTAssertEqual(control.frame.width, geometry.frames[index].width, accuracy: 0.5)
            XCTAssertEqual(visibleButtons(of: control).count, 1, "Только кнопка открепления")
            XCTAssertEqual(buttons(of: control).filter { $0.isHidden }.count, 1, "Стрелка размера скрыта")
            XCTAssertFalse(control.isHidden)
        }

        host.coordinator.endEditing()
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        XCTAssertNil(host.coordinator.editControlsHost)
    }

    /// Вне правки кнопок на ярлыках панели нет; вход в правку закрывает панель
    /// (E10.5-A4), после раскрытия в правке кнопки появляются.
    func testNoButtonsOutsideEditMode() throws {
        let host = try makeHost()
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        host.spin(0.05)
        XCTAssertEqual(host.host.grid.expandedFolderID, "F")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Не в правке — кнопок нет")
        XCTAssertNil(host.coordinator.editControlsHost)

        host.coordinator.beginEditing()
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertTrue(host.waitUntil { host.host.grid.expandedFolderID == nil })
        XCTAssertNil(host.host.grid.expandedFolderID, "Вход в правку закрыл панель")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)

        try openPanel(host)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)
        host.coordinator.endEditing()
    }

    /// У плитки-папки кнопки открепления нет (D38) — только стрелка размера;
    /// оверлей папки не «ярлык панели».
    func testFolderTileHasNoUnpinButton() throws {
        let host = try makeHost()
        try openPanel(host)

        let folderControl = try XCTUnwrap(host.coordinator.editControls["F"])
        folderControl.layoutIfNeeded()
        XCTAssertFalse(folderControl.isPanelMember)
        XCTAssertEqual(visibleButtons(of: folderControl).count, 1, "У папки — только стрелка размера")
        XCTAssertNil(host.coordinator.panelEditControls["F"])
        XCTAssertFalse(host.coordinator.panelEditControls.keys.contains("F"))
        host.coordinator.endEditing()
    }

    /// Кнопки не видны для VoiceOver (как десктопные), а действие «Открепить»
    /// на ярлыке панели осталось.
    func testButtonsAreHiddenFromAccessibilityAndActionRemains() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)

        XCTAssertFalse(container.isAccessibilityElement)
        for control in host.coordinator.panelEditControls.values {
            XCTAssertFalse(control.isAccessibilityElement)
            XCTAssertTrue(buttons(of: control).allSatisfy { !$0.isAccessibilityElement })
        }
        let unpinName = TesseraStartScreenStrings.string(.a11yActionUnpin)
        for cell in panel.shortcutCells {
            XCTAssertTrue((cell.accessibilityCustomActions ?? []).contains { $0.name == unpinName })
        }
        host.coordinator.endEditing()
    }

    // MARK: - Размер и угол

    /// Диаметр и угол — по правилам десктопной кнопки: диаметр от размера ярлыка
    /// и потолка конфигурации (не меньше 20 pt), центр у угла рамки, выступ
    /// 4 pt (D48); рамка кнопки — результат общего помощника угла, тот же, что у
    /// кнопки плитки сетки.
    func testButtonUsesDesktopSizeAndSharedCornerHelper() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try panelFrames(host)
        let desktop = try XCTUnwrap(host.coordinator.editControls["a0"])
        desktop.layoutIfNeeded()

        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            let tileSize = geometry.frames[index].size
            let side = TesseraTileEditControlView.diameter(
                forTileSize: tileSize,
                maxDiameter: host.coordinator.configuration.controlDiameter
            )
            let expected = TesseraTileEditControlView.unpinButtonFrame(
                inTileBounds: control.bounds,
                side: side,
                isRightToLeft: false
            )
            XCTAssertEqual(control.unpinButtonFrame, expected)
            XCTAssertGreaterThanOrEqual(control.unpinButtonFrame.width, TesseraTileEditControlView.minimumDiameter)
            // E15.2: верхний угол у конца строки — правый в LTR.
            XCTAssertEqual(
                control.unpinButtonFrame.maxX,
                control.bounds.maxX + TesseraTileEditControlView.cornerOverhang,
                accuracy: 0.001
            )
            XCTAssertEqual(control.unpinButtonFrame.minY, -TesseraTileEditControlView.cornerOverhang, accuracy: 0.001)
        }

        // Тот же угол и тот же размер плитки (small = small): рамка кнопки
        // панели в точности равна рамке кнопки на плитке сетки.
        let panelControl = try control("x", in: host)
        XCTAssertEqual(panelControl.bounds.size.width, desktop.bounds.size.width, accuracy: 1)
        XCTAssertEqual(panelControl.unpinButtonFrame, desktop.unpinButtonFrame)
        host.coordinator.endEditing()
    }

    /// Помощник угла: правый верхний в LTR (E15.2, D29), в RTL зеркалит кнопку в
    /// левый верхний угол.
    func testSharedCornerHelperMirrorsInRightToLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        let ltr = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        let rtl = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        // D48: выступ 4 pt (был 6).
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        XCTAssertEqual(ltr, CGRect(x: 64, y: -4, width: 20, height: 20))
        XCTAssertEqual(rtl, CGRect(x: -4, y: -4, width: 20, height: 20))
    }

    /// D48: допуск зоны кнопки ярлыка панели — выступ 4 pt, но не больше зазора
    /// панели; сама зона не выходит за рамку ярлыка дальше этого допуска (кнопка
    /// не заходит на соседа), и общий выступ — один на сетку и панель.
    func testPanelHitOutsetFollowsTheSharedOverhangAndSpacing() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try panelFrames(host)
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        let expected = min(TesseraTileEditControlView.cornerOverhang, max(0, geometry.spacing))
        XCTAssertGreaterThan(geometry.tileIDs.count, 0)
        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            XCTAssertEqual(control.panelHitOutset, expected, accuracy: 0.001, "\(id)")
            let tile = geometry.frames[index]
            let zone = control.convert(control.unpinHitFrame, to: host.host.grid)
            XCTAssertLessThanOrEqual(zone.maxX, tile.maxX + expected + 0.001, "\(id)")
            XCTAssertGreaterThanOrEqual(zone.minY, tile.minY - expected - 0.001, "\(id)")
        }
        host.coordinator.endEditing()
    }

    // MARK: - Правило зоны касания

    /// Чистое правило (E15.2: угол — верхний правый в LTR): зона не уходит за
    /// угловую четверть и выступ, центр и тело ярлыка — не зона, сама кнопка —
    /// зона; на ярлыке 88 pt зона не меньше 28 pt.
    func testPanelHitZoneRuleLeftToRight() {
        // D48: выступ — общая константа 4 pt, зона не выходит за него.
        let overhang = TesseraTileEditControlView.cornerOverhang
        for tileSide: CGFloat in [44, 55, 88] {
            let bounds = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
            let side: CGFloat = 20
            let button = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: false)
            let zone = TesseraTileEditControlView.panelUnpinHitZone(
                buttonFrame: button, tileBounds: bounds, isRightToLeft: false, outset: overhang
            )

            XCTAssertTrue(zone.contains(CGPoint(x: button.midX, y: button.midY)), "центр кнопки — зона, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: bounds.midX, y: bounds.midY)), "центр ярлыка — не зона, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)), "противоположный угол, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: 4, y: 4)), "левый верхний угол, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: 4, y: bounds.maxY - 4)), "левый нижний угол, \(tileSide)")
            XCTAssertLessThanOrEqual(zone.maxX, bounds.maxX + overhang + 0.001)
            XCTAssertGreaterThanOrEqual(zone.minY, -overhang - 0.001)
            XCTAssertGreaterThan(zone.minX, bounds.midX)
            XCTAssertLessThan(zone.maxY, bounds.midY)
            XCTAssertGreaterThanOrEqual(zone.width, min(44, tileSide / 2 + overhang - 1) - 0.001)
        }
    }

    /// RTL: четверть левая, зона зеркальна LTR.
    func testPanelHitZoneRuleRightToLeftIsMirrored() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        let ltrButton = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        let rtlButton = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        let overhang = TesseraTileEditControlView.cornerOverhang
        let ltr = TesseraTileEditControlView.panelUnpinHitZone(
            buttonFrame: ltrButton, tileBounds: bounds, isRightToLeft: false, outset: overhang
        )
        let rtl = TesseraTileEditControlView.panelUnpinHitZone(
            buttonFrame: rtlButton, tileBounds: bounds, isRightToLeft: true, outset: overhang
        )

        XCTAssertEqual(rtl.width, ltr.width, accuracy: 0.001)
        XCTAssertEqual(rtl.height, ltr.height, accuracy: 0.001)
        XCTAssertEqual(rtl.minX, bounds.width - ltr.maxX, accuracy: 0.001, "зеркально относительно вертикальной оси")
        XCTAssertTrue(rtl.contains(CGPoint(x: rtlButton.midX, y: rtlButton.midY)))
        XCTAssertFalse(rtl.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertFalse(rtl.contains(CGPoint(x: bounds.maxX - 4, y: 4)), "правый верхний угол в RTL — не кнопка")
        XCTAssertGreaterThanOrEqual(rtl.minX, -overhang - 0.001)
        XCTAssertLessThan(rtl.maxX, bounds.midX)
    }

    /// Зазор меньше выступа сжимает зону: на соседа она не заходит.
    func testPanelHitZoneNeverEntersNeighbourWhenSpacingIsSmall() {
        let bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let button = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        for spacing: CGFloat in [0, 2, 4, 8] {
            let outset = min(TesseraTileEditControlView.cornerOverhang, spacing)
            let zone = TesseraTileEditControlView.panelUnpinHitZone(
                buttonFrame: button, tileBounds: bounds, isRightToLeft: false, outset: outset
            )
            XCTAssertLessThanOrEqual(zone.maxX, bounds.maxX + spacing + 0.001, "spacing=\(spacing)")
            XCTAssertGreaterThanOrEqual(zone.minY, -spacing - 0.001, "spacing=\(spacing)")
        }
    }

    /// Интеграция с настоящей панелью (E15.2: кнопка — в правом верхнем углу
    /// ярлыка): центр ярлыка — мимо кнопок (тап и long-press идут ярлыку), угол
    /// кнопки — кнопка, зазор справа от «x» на высоте его кнопки — кнопка «x»
    /// (в пределах выступа), а не соседа; левый верхний угол ярлыка — его тело.
    func testHitRuleInPanelBodyCornerAndNeighbourOverlap() throws {
        let host = try makeHost()
        try openPanel(host)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)
        let geometry = try panelFrames(host)
        let x = geometry.frames[0]
        let y = geometry.frames[1]

        // Центр ярлыка: касание проходит мимо кнопок.
        XCTAssertNil(container.hitTest(CGPoint(x: x.midX, y: x.midY), with: nil))
        XCTAssertNil(container.hitTest(CGPoint(x: y.midX, y: y.midY), with: nil))
        // Тело ярлыка вдали от кнопки.
        XCTAssertNil(container.hitTest(CGPoint(x: x.maxX - 4, y: x.maxY - 4), with: nil))
        // Левый верхний угол «y» (у границы с «x»): тело «y», не кнопка «x».
        XCTAssertNil(container.hitTest(CGPoint(x: y.minX + 3, y: y.minY + 3), with: nil))

        // Угол кнопки: попадание в кнопку нужного ярлыка.
        let xButton = try control("x", in: host).unpinButtonFrame
        let xPoint = CGPoint(x: x.minX + xButton.midX, y: x.minY + xButton.midY)
        let xHit = container.hitTest(xPoint, with: nil)
        XCTAssertTrue(xHit is UIButton)
        XCTAssertTrue(xHit?.superview === host.coordinator.panelEditControls["x"])

        // Зазор справа от «x» на высоте его кнопки — кнопка «x» (в пределах
        // выступа), а не «y» и не пустота; дальше выступа — мимо.
        let gapPoint = CGPoint(x: x.maxX + 3, y: x.minY + xButton.midY)
        let gapHit = container.hitTest(gapPoint, with: nil)
        XCTAssertTrue(gapHit is UIButton)
        XCTAssertTrue(gapHit?.superview === host.coordinator.panelEditControls["x"])
        XCTAssertNil(container.hitTest(CGPoint(x: x.maxX + 8, y: x.minY + xButton.midY), with: nil), "дальше выступа — не кнопка")

        // Выше первой строки ярлыков — не кнопка дальше выступа.
        XCTAssertNil(container.hitTest(CGPoint(x: x.midX, y: x.minY - 12), with: nil))
        host.coordinator.endEditing()
    }

    /// RTL: кнопка в левом верхнем углу ярлыка (E15.2), зона — левая четверть.
    func testHitRuleMirrorsForRightToLeftControl() throws {
        let host = try makeHost()
        try openPanel(host)
        let control = try control("x", in: host)
        control.semanticContentAttribute = .forceRightToLeft
        control.setNeedsLayout()
        control.layoutIfNeeded()
        let bounds = control.bounds

        XCTAssertEqual(control.unpinButtonFrame.minX, -TesseraTileEditControlView.cornerOverhang, accuracy: 0.001)
        XCTAssertNotNil(control.hitTest(CGPoint(x: 6, y: 6), with: nil), "левый верхний угол — кнопка")
        XCTAssertNil(control.hitTest(CGPoint(x: bounds.maxX - 6, y: 6), with: nil), "правый верхний угол — тело ярлыка")
        XCTAssertNil(control.hitTest(CGPoint(x: bounds.midX, y: bounds.midY), with: nil))
        host.coordinator.endEditing()
    }

    /// Пересечение зон оверлея ярлыка панели с чужой кнопкой решает ближайший центр
    /// кнопки (а не порядок подвью); с E15.2 то же правило — для любых оверлеев
    /// (стрелка размера верхней плитки и открепление нижней стоят в одной колонке).
    func testOverlappingZonesResolveByNearestButtonCenter() {
        let container = TesseraTileEditControlsHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let desktop = TesseraTileEditControlView(diameter: 20)
        desktop.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        desktop.tileSize = desktop.frame.size
        let panel = TesseraTileEditControlView(diameter: 20)
        panel.isPanelMember = true
        panel.configure(canUnpin: true, canResize: false)
        panel.frame = CGRect(x: 10, y: 10, width: 60, height: 60)
        panel.tileSize = panel.frame.size
        container.addSubview(desktop)
        container.addSubview(panel)   // верхний в порядке подвью
        desktop.layoutIfNeeded()
        panel.layoutIfNeeded()

        // E15.2: кнопки — в правых верхних углах: центр кнопки плитки сетки (54, 6),
        // центр кнопки панели (64, 16); зоны пересекаются в области, где обе зоны
        // шире 44 pt вокруг своих центров (выступ 4 pt, D48).
        let nearDesktop = CGPoint(x: 50, y: 5)
        XCTAssertTrue(container.hitTest(nearDesktop, with: nil)?.superview === desktop)
        // Ближе к кнопке панели, хотя зона плитки сетки тоже накрывает точку.
        let nearPanel = CGPoint(x: 70, y: 20)
        XCTAssertNotNil(desktop.hitTest(container.convert(nearPanel, to: desktop), with: nil))
        XCTAssertTrue(container.hitTest(nearPanel, with: nil)?.superview === panel)
    }

    // MARK: - Тап по кнопке

    /// Папка из трёх: тап по кнопке — полёт ярлыка, затем `unpin`, `didUnpin`;
    /// панель остаётся, фокус — на следующем ярлыке; кнопка ушла вместе с ярлыком.
    func testTapUnpinsMiddleTileOfThreeTileFolderWithFlyOut() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host)
        let yControl = try control("y", in: host)

        tap(yControl)
        // Ярлык летит: модель ещё не изменена, снимок виден, кнопка снята.
        XCTAssertTrue(host.store.isPinned("y"))
        XCTAssertEqual(flyingSnapshots(host).count, 1, "Снимок ярлыка летит")
        XCTAssertNil(host.coordinator.panelEditControls["y"])
        XCTAssertEqual(host.folders.first?.tiles.count, 3)

        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        XCTAssertFalse(host.store.isPinned("y"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "z"] as [AnyHashable])
        XCTAssertEqual(host.host.grid.expandedFolderID, "F", "Панель осталась")
        XCTAssertEqual(recorder.events, ["unpin:y"])
        XCTAssertTrue(flyingSnapshots(host).isEmpty)

        let panel = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertEqual(panel.shortcutCells.count, 2)
        XCTAssertTrue((posts.posts.last?.1 as? UIView) === panel.shortcutCells[1], "фокус — следующий «z»")
        XCTAssertTrue(host.waitUntil { Set(host.coordinator.panelEditControls.keys) == ["x", "z"] })
        XCTAssertTrue(panel.shortcutCells.allSatisfy { $0.alpha == 1 }, "Ячейки видны")
        host.coordinator.endEditing()
    }

    /// Последний ярлык панели: фокус — на предыдущем.
    func testTapUnpinsLastTileFocusesPrevious() throws {
        let host = try makeHost()
        let posts = record(host)
        try openPanel(host)

        tap(try control("z", in: host))
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        let panel = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable])
        XCTAssertTrue((posts.posts.last?.1 as? UIView) === panel.shortcutCells[1], "фокус — предыдущий «y»")
        host.coordinator.endEditing()
    }

    /// Папка из двух: тап по кнопке — распад (D45): панель закрывается, оставшийся
    /// ярлык — на ячейке папки со своим размером, `didUnpin`, затем
    /// `didDissolveFolder`, фокус — на нём, кнопок панели нет.
    func testTapInTwoTileFolderDissolvesFolderAndFocusesRemainingTile() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .medium)])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host)
        let folderCell = try XCTUnwrap(host.store.placement(of: "F"))

        tap(try control("x", in: host))
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty }, "фокус опубликован")
        XCTAssertTrue(waitForFolderTransitionDone(host))

        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placement(of: "y"), folderCell)
        XCTAssertEqual(host.store.snapshot().item(withID: "y")?.size, .medium)
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
        XCTAssertTrue((posts.posts.last?.1 as? UIView) === host.host.cell("y"))
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        XCTAssertNotNil(host.coordinator.editControls["y"], "Оставшийся ярлык — на сетке с десктопными кнопками")
        host.coordinator.endEditing()
    }

    /// Reduce Motion: без полёта, мутация сразу; в папке из двух панель закрывается
    /// мгновенно.
    func testTapWithReduceMotionIsInstant() throws {
        let host = try makeHost()
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try openPanel(host)

        tap(try control("y", in: host))
        XCTAssertFalse(host.store.isPinned("y"), "Мутация сразу")
        XCTAssertTrue(flyingSnapshots(host).isEmpty, "Без полёта")
        XCTAssertEqual(recorder.events, ["unpin:y"])
        XCTAssertEqual(host.host.grid.expandedFolderID, "F")

        // Осталось два: второй тап распускает папку, панель закрыта сразу.
        host.host.layout()
        XCTAssertTrue(host.waitUntil { host.coordinator.panelEditControls["x"] != nil })
        tap(try control("x", in: host))
        XCTAssertNil(host.host.grid.expandedFolderID, "Панель закрыта сразу")
        XCTAssertEqual(recorder.events, ["unpin:y", "unpin:x", "dissolve:F>z"])
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        host.coordinator.endEditing()
    }

    /// Повторный тап по кнопке, пока ярлык летит, и тап по соседней кнопке в это
    /// время не дают ни второй мутации, ни второго колбэка.
    func testSecondTapWhileFlyingIsIgnored() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host)
        let yControl = try control("y", in: host)
        let zControl = try control("z", in: host)

        tap(yControl)
        tap(yControl)
        tap(zControl)
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        host.spin(0.1)

        XCTAssertEqual(recorder.events, ["unpin:y"])
        XCTAssertTrue(host.store.isPinned("z"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "z"] as [AnyHashable])
        host.coordinator.endEditing()
    }

    /// Панель закрыли, пока ярлык летел: мутации нет, ярлык виден, колбэка нет.
    func testClosingPanelDuringFlightCancelsUnpin() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        let yCell = panel.shortcutCells[1]

        tap(try control("y", in: host))
        XCTAssertEqual(flyingSnapshots(host).count, 1)
        host.host.grid.closeFolder(animated: false)
        XCTAssertTrue(host.waitUntil { self.flyingSnapshots(host).isEmpty })
        host.spin(0.05)

        XCTAssertTrue(host.store.isPinned("y"), "Ярлык не откреплён")
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(yCell.alpha, 1, "Ячейка возвращена")
        host.coordinator.endEditing()
    }

    /// Публичное `unpin(_:)` (в том числе действие VoiceOver) по-прежнему мгновенное,
    /// без полёта: анимация — только для тапа по кнопке.
    func testPublicUnpinOfPanelTileStaysImmediate() throws {
        let host = try makeHost()
        try openPanel(host)

        host.coordinator.unpin("y")
        XCTAssertFalse(host.store.isPinned("y"))
        XCTAssertTrue(flyingSnapshots(host).isEmpty)
        host.coordinator.endEditing()
    }

    // MARK: - Жизненный цикл

    /// Кнопки появляются, когда панель устоялась, и снимаются при закрытии.
    func testButtonsFollowPanelOpenAndCloseTransitions() throws {
        let host = try makeHost()
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: true)
        XCTAssertTrue(host.host.grid.isFolderChangeAnimating)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Пока панель открывается — кнопок нет")
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3, "Панель устоялась — кнопки есть")

        host.host.grid.closeFolder(animated: true)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Закрытие началось — кнопки сняты")
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)

        host.host.grid.openFolder(folder, animated: false)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)
        host.host.grid.closeFolder(animated: false)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        host.coordinator.endEditing()
    }

    /// Новые кнопки раскрытой панели проявляются плавно, при Reduce Motion — сразу.
    func testButtonsFadeInOnOpenAndAppearInstantlyWithReduceMotion() throws {
        let host = try makeHost()
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: false)
        let control = try XCTUnwrap(host.coordinator.panelEditControls["x"])
        XCTAssertNotNil(control.layer.animation(forKey: "opacity"), "Проявление анимируется")
        host.host.grid.closeFolder(animated: false)

        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.openFolder(folder, animated: false)
        let instant = try XCTUnwrap(host.coordinator.panelEditControls["x"])
        XCTAssertEqual(instant.alpha, 1)
        XCTAssertNil(instant.layer.animation(forKey: "opacity"))
        host.coordinator.endEditing()
    }

    /// Drag ярлыка из панели: панель закрывается, кнопок на ярлыках нет ни во
    /// время drag, ни после отмены (панели нет); долгое нажатие по телу ярлыка
    /// с кнопками стартует drag.
    func testDragOutStillWorksAndRemovesPanelButtons() throws {
        let host = try makeHost()
        try openPanel(host)
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let geometry = try panelFrames(host)
        let y = geometry.frames[1]
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)

        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: y.midX, y: y.midY))
        XCTAssertTrue(host.coordinator.isDragging, "Long-press по телу ярлыка поднимает его")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Во время drag кнопок на ярлыках панели нет")
        XCTAssertNil(host.host.grid.expandedFolderID)

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        host.coordinator.endEditing()
    }

    // MARK: - Следование за панелью

    /// Прокрутка двигает кнопки вместе с ярлыками; ярлык, ушедший за край, — скрытая кнопка.
    func testButtonsFollowPanelOnScroll() throws {
        let host = try makeHost(rowsBelow: 14)
        try openPanel(host)
        let grid = host.host.grid
        XCTAssertGreaterThan(grid.contentSize.height, grid.bounds.height + 100)

        let before = try panelFrames(host)
        grid.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        host.host.layout()
        let after = try panelFrames(host)
        XCTAssertEqual(after.frames[0].minY, before.frames[0].minY - 40, accuracy: 0.5)
        for (index, id) in after.tileIDs.enumerated() {
            let control = try XCTUnwrap(host.coordinator.panelEditControls[id])
            XCTAssertEqual(control.frame.minY, after.frames[index].minY, accuracy: 0.5, "\(id)")
            XCTAssertEqual(control.frame.minX, after.frames[index].minX, accuracy: 0.5, "\(id)")
        }

        // Прокрутили так, что панель ушла за верх: кнопки скрыты.
        grid.setContentOffset(CGPoint(x: 0, y: after.frames[0].maxY + 400), animated: false)
        host.host.layout()
        host.spin(0.05)
        for control in host.coordinator.panelEditControls.values {
            XCTAssertTrue(control.isHidden)
        }
        host.coordinator.endEditing()
    }

    /// Смена ширины сетки (поворот) и `refreshEditControls()`: кнопки встают на
    /// новые рамки ярлыков; число колонок панели не меняет состав кнопок.
    func testButtonsRelayoutAfterWidthChange() throws {
        let host = try makeHost()
        try openPanel(host)
        let grid = host.host.grid
        let oldWidth = try panelFrames(host).frames[0].width

        grid.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
        host.host.layout()
        host.coordinator.refreshEditControls()
        host.host.layout()

        let geometry = try panelFrames(host)
        XCTAssertNotEqual(geometry.frames[0].width, oldWidth, "Ярлыки перестроились")
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)
        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            XCTAssertEqual(control.frame.minX, geometry.frames[index].minX, accuracy: 0.5)
            XCTAssertEqual(control.frame.minY, geometry.frames[index].minY, accuracy: 0.5)
            XCTAssertEqual(control.frame.width, geometry.frames[index].width, accuracy: 0.5)
            XCTAssertEqual(
                control.unpinButtonFrame.maxX,
                control.bounds.maxX + TesseraTileEditControlView.cornerOverhang,
                accuracy: 0.001
            )
        }
        host.coordinator.endEditing()
    }

    // MARK: - Десктоп не затронут

    /// Десктопные кнопки: не «ярлыки панели», зона касания без урезания (не
    /// меньше 44 pt, выступает на тело соседей как раньше), обе кнопки на месте.
    func testDesktopControlsAreUnaffected() throws {
        let host = try makeHost()
        try openPanel(host)
        let desktop = try XCTUnwrap(host.coordinator.editControls["a0"])
        desktop.layoutIfNeeded()

        XCTAssertFalse(desktop.isPanelMember)
        XCTAssertEqual(visibleButtons(of: desktop).count, 2, "Булавка и стрелка")
        XCTAssertGreaterThanOrEqual(desktop.unpinHitFrame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(desktop.unpinHitFrame.height, 44 - 0.001)
        XCTAssertGreaterThan(
            desktop.unpinHitFrame.maxX, desktop.bounds.maxX + TesseraTileEditControlView.cornerOverhang,
            "Зона плитки сетки не урезана выступом (как раньше, 44 pt вокруг кнопки)"
        )
        XCTAssertNotNil(desktop.hitTest(CGPoint(x: desktop.unpinHitFrame.maxX - 1, y: desktop.unpinHitFrame.maxY - 1), with: nil))
        host.coordinator.endEditing()
    }
}

#endif
