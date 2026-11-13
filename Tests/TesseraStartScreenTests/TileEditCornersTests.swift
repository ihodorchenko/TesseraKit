//
//  TileEditCornersTests.swift
//  TesseraStartScreenTests
//
//  Углы кнопок правки (D29, E15.2): открепление — в верхнем углу у конца строки
//  (правый в LTR, левый в RTL), стрелка размера — в нижнем углу той же стороны,
//  то есть обе кнопки одной плитки стоят друг над другом. Правило владения
//  зонами касания на малой плитке: открепление владеет верхней половиной высоты,
//  стрелка — нижней, центр плитки не принадлежит никому. Проектный документ:
//  docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации (E15)», п. 59.
//
//  Заодно — бэйдж против кнопок в настоящей правке на ширинах 375/390/402/414 pt
//  при 6 колонках (E15.1).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditCornersTests: XCTestCase {

    // MARK: - Помощники

    /// Оверлей кнопок плитки `side × side` с заданным направлением.
    private func makeControl(
        side: CGFloat,
        rightToLeft: Bool = false,
        diameter: CGFloat = 28
    ) -> TesseraTileEditControlView {
        let control = TesseraTileEditControlView(diameter: diameter)
        if rightToLeft { control.semanticContentAttribute = .forceRightToLeft }
        control.frame = CGRect(x: 0, y: 0, width: side, height: side)
        control.tileSize = control.frame.size
        control.layoutIfNeeded()
        return control
    }

    private func unpinButton(of control: TesseraTileEditControlView) -> UIButton? {
        control.subviews.compactMap { $0 as? UIButton }.first {
            $0.frame == control.unpinButtonFrame
        }
    }

    private func resizeButton(of control: TesseraTileEditControlView) -> UIButton? {
        control.subviews.compactMap { $0 as? UIButton }.first {
            $0.frame == control.resizeButtonFrame
        }
    }

    // MARK: - Углы

    /// Помощники углов: открепление сверху, стрелка снизу, оба у конца строки.
    func testCornerHelpersPutBothButtonsOnTrailingSideStackedVertically() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 60)
        let overhang = TesseraTileEditControlView.cornerOverhang
        let unpinLTR = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        let resizeLTR = TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        XCTAssertEqual(unpinLTR, CGRect(x: 80 - 20 + overhang, y: -overhang, width: 20, height: 20))
        XCTAssertEqual(resizeLTR, CGRect(x: 80 - 20 + overhang, y: 60 - 20 + overhang, width: 20, height: 20))
        XCTAssertEqual(unpinLTR.midX, resizeLTR.midX, "в одной колонке")
        XCTAssertLessThan(unpinLTR.midY, resizeLTR.midY, "открепление выше")

        let unpinRTL = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        let resizeRTL = TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        XCTAssertEqual(unpinRTL, CGRect(x: -overhang, y: -overhang, width: 20, height: 20))
        XCTAssertEqual(resizeRTL, CGRect(x: -overhang, y: 60 - 20 + overhang, width: 20, height: 20))
        XCTAssertEqual(unpinRTL.midX, resizeRTL.midX)
    }

    /// Оверлей плитки сетки строит кнопки теми же помощниками (LTR и RTL).
    func testGridOverlayUsesSharedCornerHelpers() {
        for rtl in [false, true] {
            for side: CGFloat in [55, 120] {
                let control = makeControl(side: side, rightToLeft: rtl)
                let diameter = TesseraTileEditControlView.diameter(forTileSize: control.bounds.size, maxDiameter: 28)
                XCTAssertEqual(
                    control.unpinButtonFrame,
                    TesseraTileEditControlView.unpinButtonFrame(
                        inTileBounds: control.bounds, side: diameter, isRightToLeft: rtl
                    )
                )
                XCTAssertEqual(
                    control.resizeButtonFrame,
                    TesseraTileEditControlView.resizeButtonFrame(
                        inTileBounds: control.bounds, side: diameter, isRightToLeft: rtl
                    )
                )
            }
        }
    }

    /// В настоящей правке: открепление — выше и у конца строки, стрелка — ниже, оба
    /// выступают наружу у конца строки (правый край в LTR, левый в RTL).
    func testRealEditSessionPlacesButtonsAtTrailingCorners() throws {
        for rtl in [false, true] {
            let host = TesseraTestDragHost(
                descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
            )
            if rtl {
                host.host.grid.semanticContentAttribute = .forceRightToLeft
                host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
                host.host.layout()
            }
            host.coordinator.beginEditing()
            host.spin(0.03)
            for id in ["t0", "t1", "t2", "t3"] {
                let control = try XCTUnwrap(host.coordinator.editControls[AnyHashable(id)])
                if rtl {
                    control.semanticContentAttribute = .forceRightToLeft
                    control.setNeedsLayout()
                }
                control.layoutIfNeeded()
                let tile = try XCTUnwrap(host.host.grid.frame(forItemID: AnyHashable(id)))
                let unpin = control.convert(control.unpinButtonFrame, to: host.host.grid)
                let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)

                XCTAssertLessThan(unpin.minY, tile.minY, "открепление выступает вверх: \(id) rtl=\(rtl)")
                XCTAssertGreaterThan(resize.maxY, tile.maxY, "стрелка выступает вниз: \(id) rtl=\(rtl)")
                XCTAssertEqual(unpin.midX, resize.midX, accuracy: 0.5, "одна колонка: \(id) rtl=\(rtl)")
                if rtl {
                    XCTAssertLessThan(unpin.minX, tile.minX, "RTL: слева \(id)")
                    XCTAssertLessThan(unpin.midX, tile.midX, id)
                } else {
                    XCTAssertGreaterThan(unpin.maxX, tile.maxX, "LTR: справа \(id)")
                    XCTAssertGreaterThan(unpin.midX, tile.midX, id)
                }
            }
            host.coordinator.endEditing()
        }
    }

    // MARK: - Правило владения зонами касания

    private let sampledSides: [CGFloat] = [50, 55, 62, 120]

    /// Зоны двух кнопок плитки никогда не пересекаются; верхняя половина высоты —
    /// у открепления, нижняя — у стрелки; тап по каждой точке плитки и вокруг даёт
    /// не больше одной кнопки, ровно как говорят зоны.
    func testHitOwnershipIsDeterministicAtSmallAndLargeTileSizes() {
        for side in sampledSides {
            for rtl in [false, true] {
                let control = makeControl(side: side, rightToLeft: rtl)
                let unpinZone = control.unpinHitFrame
                let resizeZone = control.resizeHitFrame
                let label = "плитка \(side) rtl=\(rtl)"

                XCTAssertFalse(unpinZone.isEmpty, label)
                XCTAssertFalse(resizeZone.isEmpty, label)
                XCTAssertLessThanOrEqual(unpinZone.maxY, side / 2 + 0.001, "открепление — верхняя половина: \(label)")
                XCTAssertGreaterThanOrEqual(resizeZone.minY, side / 2 - 0.001, "стрелка — нижняя половина: \(label)")
                XCTAssertGreaterThanOrEqual(unpinZone.width, 42 - 0.001, "ширина зоны \(label)")
                XCTAssertGreaterThanOrEqual(unpinZone.height, 42 - 0.001, "высота зоны \(label)")
                XCTAssertGreaterThanOrEqual(resizeZone.width, 42 - 0.001, label)
                XCTAssertGreaterThanOrEqual(resizeZone.height, 42 - 0.001, label)
                if side >= 55 {
                    XCTAssertEqual(unpinZone.width, 44, accuracy: 0.001, label)
                    XCTAssertEqual(unpinZone.height, 44, accuracy: 0.001, label)
                    XCTAssertEqual(resizeZone.width, 44, accuracy: 0.001, label)
                    XCTAssertEqual(resizeZone.height, 44, accuracy: 0.001, label)
                }

                let unpin = unpinButton(of: control)
                let resize = resizeButton(of: control)
                XCTAssertNotNil(unpin, label)
                XCTAssertNotNil(resize, label)

                // Сэмплирование: результат hitTest совпадает с зонами, пересечений нет.
                var y: CGFloat = -30
                while y < side + 30 {
                    var x: CGFloat = -30
                    while x < side + 30 {
                        let point = CGPoint(x: x, y: y)
                        let inUnpin = unpinZone.contains(point)
                        let inResize = resizeZone.contains(point)
                        XCTAssertFalse(inUnpin && inResize, "зоны пересеклись в \(point): \(label)")
                        let hit = control.hitTest(point, with: nil)
                        if inUnpin {
                            XCTAssertTrue(hit === unpin, "точка \(point) принадлежит откреплению: \(label)")
                        } else if inResize {
                            XCTAssertTrue(hit === resize, "точка \(point) принадлежит стрелке: \(label)")
                        } else {
                            XCTAssertNil(hit, "точка \(point) — ничья: \(label)")
                        }
                        x += 0.5
                    }
                    y += 0.5
                }
            }
        }
    }

    /// Центр плитки и вся полоса вдоль вертикальной оси не принадлежат кнопкам
    /// (тап по телу, long-press и drag работают), а сами центры кнопок — зона.
    func testTileCenterBelongsToNeitherButton() {
        for side in sampledSides {
            for rtl in [false, true] {
                let control = makeControl(side: side, rightToLeft: rtl)
                let label = "плитка \(side) rtl=\(rtl)"
                let center = CGPoint(x: side / 2, y: side / 2)
                XCTAssertNil(control.hitTest(center, with: nil), label)
                XCTAssertFalse(control.unpinHitFrame.contains(center), label)
                XCTAssertFalse(control.resizeHitFrame.contains(center), label)
                // Вертикальная ось: ни у одной из кнопок нет зоны через неё.
                for y in stride(from: CGFloat(0), through: side, by: 1) {
                    XCTAssertNil(control.hitTest(CGPoint(x: side / 2, y: y), with: nil), "ось y=\(y): \(label)")
                }
                // Противоположная (ведущая) половина плитки — тело.
                let leading = rtl ? side - 4 : 4
                XCTAssertNil(control.hitTest(CGPoint(x: leading, y: 4), with: nil), label)
                XCTAssertNil(control.hitTest(CGPoint(x: leading, y: side - 4), with: nil), label)

                XCTAssertNotNil(control.hitTest(
                    CGPoint(x: control.unpinButtonFrame.midX, y: control.unpinButtonFrame.midY), with: nil
                ), label)
                XCTAssertNotNil(control.hitTest(
                    CGPoint(x: control.resizeButtonFrame.midX, y: control.resizeButtonFrame.midY), with: nil
                ), label)
            }
        }
    }

    /// Старая нахлёстка: на плитке ≈ 50 pt зоны 44 pt пересеклись бы (≈ 1,5–2 pt),
    /// теперь зазор между зонами по высоте не отрицателен на всех размерах.
    func testZonesDoNotOverlapAtSmallestTile() {
        for side in [CGFloat(48), 50, 50.5, 52, 55] {
            let control = makeControl(side: side)
            let gap = control.resizeHitFrame.minY - control.unpinHitFrame.maxY
            XCTAssertGreaterThanOrEqual(gap, -0.001, "плитка \(side): зазор \(gap)")
        }
    }

    /// Чистое правило: симметрично по направлению, зона внутри допустимой области.
    func testGridHitZoneRuleIsMirroredInRightToLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 62, height: 62)
        let side: CGFloat = 20
        for upper in [true, false] {
            let ltrButton = upper
                ? TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: false)
                : TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: false)
            let rtlButton = upper
                ? TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: true)
                : TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: true)
            let ltr = TesseraTileEditControlView.gridHitZone(
                buttonFrame: ltrButton, tileBounds: bounds, isRightToLeft: false, ownsUpperHalf: upper
            )
            let rtl = TesseraTileEditControlView.gridHitZone(
                buttonFrame: rtlButton, tileBounds: bounds, isRightToLeft: true, ownsUpperHalf: upper
            )
            XCTAssertEqual(ltr.width, rtl.width, accuracy: 0.001)
            XCTAssertEqual(ltr.height, rtl.height, accuracy: 0.001)
            XCTAssertEqual(rtl.minX, bounds.width - ltr.maxX, accuracy: 0.001, "зеркально (upper=\(upper))")
            XCTAssertEqual(ltr.minY, rtl.minY, accuracy: 0.001)
            XCTAssertGreaterThan(ltr.minX, bounds.midX - 0.001)
            XCTAssertLessThan(rtl.maxX, bounds.midX + 0.001)
        }
    }

    // MARK: - Соседние плитки

    /// Плитки друг над другом (зазор 8 pt): зоны стрелки верхней плитки и
    /// открепления нижней пересекаются; касание в пересечении достаётся кнопке с
    /// ближайшим центром — детерминированно, для каждой точки области.
    func testStackedNeighboursResolveByNearestButtonCenter() {
        for side in sampledSides {
            let container = TesseraTileEditControlsHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            let upper = makeControl(side: side)
            let lower = makeControl(side: side)
            upper.frame = CGRect(x: 100, y: 100, width: side, height: side)
            lower.frame = CGRect(x: 100, y: 100 + side + 8, width: side, height: side)
            container.addSubview(upper)
            container.addSubview(lower)
            upper.layoutIfNeeded()
            lower.layoutIfNeeded()

            func centre(_ control: TesseraTileEditControlView, _ frame: CGRect) -> CGPoint {
                control.convert(CGPoint(x: frame.midX, y: frame.midY), to: container)
            }
            let upperResize = centre(upper, upper.resizeButtonFrame)
            let lowerUnpin = centre(lower, lower.unpinButtonFrame)

            XCTAssertTrue(container.hitTest(upperResize, with: nil)?.superview === upper, "центр стрелки: \(side)")
            XCTAssertTrue(container.hitTest(lowerUnpin, with: nil)?.superview === lower, "центр открепления: \(side)")

            var overlapSamples = 0
            var y = upperResize.y - 30
            while y < lowerUnpin.y + 30 {
                var x = upperResize.x - 30
                while x < upperResize.x + 30 {
                    let point = CGPoint(x: x, y: y)
                    let inUpper = upper.hitTest(upper.convert(point, from: container), with: nil) != nil
                    let inLower = lower.hitTest(lower.convert(point, from: container), with: nil) != nil
                    if inUpper && inLower {
                        overlapSamples += 1
                        let upperDistance = hypot(point.x - upperResize.x, point.y - upperResize.y)
                        let lowerDistance = hypot(point.x - lowerUnpin.x, point.y - lowerUnpin.y)
                        let winner = container.hitTest(point, with: nil)?.superview
                        if upperDistance < lowerDistance {
                            XCTAssertTrue(winner === upper, "\(point): ближе стрелка верхней, плитка \(side)")
                        } else if lowerDistance < upperDistance {
                            XCTAssertTrue(winner === lower, "\(point): ближе открепление нижней, плитка \(side)")
                        } else {
                            XCTAssertNotNil(winner)
                        }
                    }
                    x += 1
                }
                y += 1
            }
            XCTAssertGreaterThan(overlapSamples, 0, "зоны соседей действительно пересекаются: \(side)")
        }
    }

    // MARK: - Ярлык панели папки

    /// Панель: кнопка в верхнем углу у конца строки, зона — угловая четверть этого
    /// же угла (правая в LTR, левая в RTL), центр и противоположные углы — тело.
    func testPanelControlUsesTrailingTopCornerAndQuarterZone() {
        for rtl in [false, true] {
            for side: CGFloat in [55, 88] {
                let control = TesseraTileEditControlView(diameter: 28)
                control.isPanelMember = true
                control.configure(canUnpin: true, canResize: false)
                if rtl { control.semanticContentAttribute = .forceRightToLeft }
                control.frame = CGRect(x: 0, y: 0, width: side, height: side)
                control.tileSize = control.frame.size
                control.layoutIfNeeded()
                let label = "панель \(side) rtl=\(rtl)"

                let diameter = TesseraTileEditControlView.diameter(forTileSize: control.bounds.size, maxDiameter: 28)
                XCTAssertEqual(
                    control.unpinButtonFrame,
                    TesseraTileEditControlView.unpinButtonFrame(
                        inTileBounds: control.bounds, side: diameter, isRightToLeft: rtl
                    ),
                    label
                )
                let zone = control.unpinHitFrame
                XCTAssertTrue(zone.contains(CGPoint(x: control.unpinButtonFrame.midX, y: control.unpinButtonFrame.midY)), label)
                XCTAssertNil(control.hitTest(CGPoint(x: side / 2, y: side / 2), with: nil), label)
                let leading: CGFloat = rtl ? side - 4 : 4
                let trailing: CGFloat = rtl ? 4 : side - 4
                XCTAssertNil(control.hitTest(CGPoint(x: leading, y: 4), with: nil), "ведущий верхний угол: \(label)")
                XCTAssertNil(control.hitTest(CGPoint(x: trailing, y: side - 4), with: nil), "нижний угол: \(label)")
                XCTAssertNotNil(control.hitTest(CGPoint(x: trailing, y: 4), with: nil), "ведомый верхний угол: \(label)")
            }
        }
    }

    // MARK: - Бэйдж и кнопки в настоящей правке (E15.1)

    private func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }

    /// Ширины 375/390/402/414 pt, 6 колонок: у плиток 1×1, 2×2 и 4×2 с бэйджами
    /// (капсула, «99+», точка) бэйдж в правке не пересекает ни стрелку размера, ни
    /// открепление; бэйдж остаётся видимым (кроме «99+» на 1×1 при ширинах ≤ 402 pt:
    /// скрыт только на время правки). Измеренные зазоры выводятся в лог.
    func testBadgeDoesNotOverlapButtonsInRealEditSession() throws {
        let badges: [(String, TileBadge)] = [("count 3", .count(3)), ("99+", .count(150)), ("dot", .dot)]
        for width in [CGFloat(375), 390, 402, 414] {
            for (badgeName, badge) in badges {
                let host = TesseraTestDragHost(
                    descriptors: [
                        tesseraTestTile("s1", size: .small, badge: badge),
                        tesseraTestTile("s2", size: .small, badge: badge),
                        tesseraTestTile("m", size: .medium, badge: badge),
                        tesseraTestTile("w", size: .wide, badge: badge),
                    ],
                    columns: 6,
                    windowSize: CGSize(width: width, height: 844)
                )
                host.coordinator.isReduceMotionEnabled = { true }
                host.host.grid.isReduceMotionEnabled = { true }
                host.coordinator.beginEditing()
                host.spin(0.05)

                for id in ["s1", "s2", "m", "w"] {
                    let label = "\(Int(width)) pt \(id) \(badgeName)"
                    let cell = try XCTUnwrap(host.host.cell(AnyHashable(id)), label)
                    cell.layoutIfNeeded()
                    let badgeView = try XCTUnwrap(
                        cell.contentView.subviews.compactMap { $0 as? TesseraLiveTileBadgeView }.first, label
                    )
                    let control = try XCTUnwrap(host.coordinator.editControls[AnyHashable(id)], label)
                    control.layoutIfNeeded()
                    let tile = try XCTUnwrap(host.host.grid.frame(forItemID: AnyHashable(id)), label)

                    let expectHidden = badgeName == "99+" && id.hasPrefix("s") && width <= 402
                    XCTAssertEqual(
                        badgeView.alpha, expectHidden ? 0 : 1, accuracy: 0.001,
                        "видимость бэйджа в правке: \(label)"
                    )
                    if expectHidden {
                        print("[E15.1] \(label): tile \(tile.size) — бэйдж скрыт на время правки")
                        continue
                    }
                    let badgeFrame = cell.contentView.convert(badgeView.frame, to: host.host.grid)
                    let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)
                    let unpin = control.convert(control.unpinButtonFrame, to: host.host.grid)
                    XCTAssertTrue(tile.insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame), "внутри плитки: \(label)")
                    XCTAssertFalse(badgeFrame.intersects(resize), "бэйдж × стрелка: \(label)")
                    XCTAssertFalse(badgeFrame.intersects(unpin), "бэйдж × открепление: \(label)")
                    let resizeGap = gap(badgeFrame, resize)
                    let unpinGap = gap(badgeFrame, unpin)
                    XCTAssertGreaterThanOrEqual(resizeGap, TesseraTileBadgeLayout.editGap - 0.01, label)
                    print("[E15.1] \(label): tile \(tile.size), badge \(badgeFrame.size), gap to resize \(resizeGap), to unpin \(unpinGap)")
                }
                host.coordinator.endEditing()

                // После выхода из правки бэйдж возвращается в угол.
                host.spin(0.05)
                let cell = try XCTUnwrap(host.host.cell("s1"))
                cell.layoutIfNeeded()
                let badgeView = try XCTUnwrap(
                    cell.contentView.subviews.compactMap { $0 as? TesseraLiveTileBadgeView }.first
                )
                XCTAssertEqual(cell.badgeEditClearance, 0)
                XCTAssertEqual(
                    badgeView.frame.maxX, cell.contentView.bounds.width - max(6, min(12, cell.contentView.bounds.width * 0.08)),
                    accuracy: 0.5
                )
            }
        }
    }
}

#endif
