//
//  TileEditOverhangTests.swift
//  TesseraStartScreenTests
//
//  Выступ кнопок правки 4 pt (D48): кнопки «открепить» и «размер» выступают за
//  рамку плитки на `cornerOverhang` = 4 pt — ровно половину зазора сетки (8 pt),
//  поэтому круги кнопок соседних плиток (стрелка верхней и открепление нижней в
//  одной колонке) касаются, но не перекрываются (при 6 pt перекрытие было 4 pt).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации
//  (E15)», п. 60; решение D48 в docs/STATE.md.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditOverhangTests: XCTestCase {

    // MARK: - Помощники

    private struct Circle {
        let center: CGPoint
        let diameter: CGFloat

        init(frame: CGRect) {
            center = CGPoint(x: frame.midX, y: frame.midY)
            diameter = frame.width
        }

        /// Зазор между краями кругов (отрицательный — перекрытие).
        func gap(to other: Circle) -> CGFloat {
            hypot(center.x - other.center.x, center.y - other.center.y) - (diameter + other.diameter) / 2
        }
    }

    private let screenWidths: [CGFloat] = [375, 390, 402, 414]

    /// Стенд: правка включена; плитки одного размера в ряд по 6 колонок.
    private func makeHost(
        descriptors: [TesseraTileDescriptor],
        width: CGFloat,
        rightToLeft: Bool = false
    ) -> TesseraTestDragHost {
        let host = TesseraTestDragHost(
            descriptors: descriptors,
            columns: 6,
            windowSize: CGSize(width: width, height: 844)
        )
        if rightToLeft {
            host.host.grid.semanticContentAttribute = .forceRightToLeft
            host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
            host.host.layout()
        }
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.beginEditing()
        host.spin(0.05)
        if rightToLeft {
            for control in host.coordinator.editControls.values {
                control.semanticContentAttribute = .forceRightToLeft
                control.setNeedsLayout()
                control.layoutIfNeeded()
            }
        }
        return host
    }

    /// Круги кнопок плитки: (открепление, стрелка) в координатах сетки.
    private func circles(
        of id: AnyHashable,
        in host: TesseraTestDragHost
    ) throws -> (unpin: Circle, resize: Circle) {
        let control = try XCTUnwrap(host.coordinator.editControls[id], "оверлей \(id)")
        control.layoutIfNeeded()
        return (
            Circle(frame: control.convert(control.unpinButtonFrame, to: host.host.grid)),
            Circle(frame: control.convert(control.resizeButtonFrame, to: host.host.grid))
        )
    }

    private func assertNoOverlap(
        ids: [String],
        in host: TesseraTestDragHost,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var worst = CGFloat.greatestFiniteMagnitude
        for (i, first) in ids.enumerated() {
            for second in ids[(i + 1)...] {
                let a = try circles(of: AnyHashable(first), in: host)
                let b = try circles(of: AnyHashable(second), in: host)
                for (nameA, circleA) in [("unpin", a.unpin), ("resize", a.resize)] {
                    for (nameB, circleB) in [("unpin", b.unpin), ("resize", b.resize)] {
                        let gap = circleA.gap(to: circleB)
                        worst = min(worst, gap)
                        XCTAssertGreaterThanOrEqual(
                            gap, -0.01,
                            "круги \(first).\(nameA) и \(second).\(nameB) перекрываются на \(-gap) pt: \(label)",
                            file: file, line: line
                        )
                    }
                }
            }
        }
        print("[D48] \(label): наименьший зазор между кругами соседей \(worst) pt")
    }

    // MARK: - Константа и формула

    /// Выступ — 4 pt, то есть половина зазора сетки по умолчанию (8 pt).
    func testOverhangIsHalfOfDefaultGridSpacing() {
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang * 2, 8, "2 × выступ = зазор сетки")
    }

    /// Чистая формула: плитки одного размера друг над другом (и рядом) с зазором
    /// 8 pt; стрелка верхней и открепление нижней — в одной колонке, круги
    /// касаются (зазор 0), для всех диаметров и обоих направлений. С прежним
    /// выступом 6 pt круги перекрывались бы на 2 × 6 − 8 = 4 pt.
    func testNeighbouringCirclesTouchButDoNotOverlap() {
        let spacing: CGFloat = 8
        for tileSide in [CGFloat(50), 55, 62, 120] {
            for rtl in [false, true] {
                let bounds = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
                let side = TesseraTileEditControlView.diameter(forTileSize: bounds.size, maxDiameter: 28)
                let upperResize = Circle(frame: TesseraTileEditControlView.resizeButtonFrame(
                    inTileBounds: bounds, side: side, isRightToLeft: rtl
                ))
                // Нижняя плитка сдвинута на сторону + зазор (рамки кнопок считаются
                // от начала координат оверлея, поэтому сдвигаем результат).
                let lowerOffset = CGPoint(x: 0, y: tileSide + spacing)
                let lowerUnpin = Circle(frame: TesseraTileEditControlView.unpinButtonFrame(
                    inTileBounds: bounds, side: side, isRightToLeft: rtl
                ).offsetBy(dx: lowerOffset.x, dy: lowerOffset.y))
                XCTAssertEqual(
                    upperResize.gap(to: lowerUnpin), 0, accuracy: 0.001,
                    "вертикальные соседи: плитка \(tileSide) rtl=\(rtl)"
                )

                // Соседи по горизонтали: кнопки каждой плитки — у её конца строки,
                // поэтому круг соседа не ближе, чем на зазор минус выступ.
                let shift = tileSide + spacing
                func button(_ frame: CGRect, dx: CGFloat) -> Circle { Circle(frame: frame.offsetBy(dx: dx, dy: 0)) }
                let unpinFrame = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: rtl)
                let resizeFrame = TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: rtl)
                let ownCircles = [button(unpinFrame, dx: 0), button(resizeFrame, dx: 0)]
                let neighbourCircles = [button(unpinFrame, dx: shift), button(resizeFrame, dx: shift)]
                for own in ownCircles {
                    for other in neighbourCircles {
                        XCTAssertGreaterThanOrEqual(own.gap(to: other), -0.001, "горизонтальные соседи: плитка \(tileSide)")
                    }
                }
            }
        }
    }

    // MARK: - Настоящая сетка

    /// Шесть средних плиток (два ряда по три): круги всех кнопок разных плиток не
    /// перекрываются — по вертикали, горизонтали и диагонали, при всех четырёх
    /// ширинах, LTR и RTL.
    func testCirclesOfNeighbouringMediumTilesDoNotOverlapInRealGrid() throws {
        let ids = (0..<6).map { "m\($0)" }
        for width in screenWidths {
            for rtl in [false, true] {
                let host = makeHost(
                    descriptors: ids.map { tesseraTestTile($0, size: .medium) },
                    width: width,
                    rightToLeft: rtl
                )
                try assertNoOverlap(ids: ids, in: host, label: "medium \(Int(width)) pt rtl=\(rtl)")
                host.coordinator.endEditing()
            }
        }
    }

    /// Малые плитки: два ряда по шесть; круги 20 pt на плитках 50…57 pt.
    func testCirclesOfNeighbouringSmallTilesDoNotOverlapInRealGrid() throws {
        let ids = (0..<12).map { "s\($0)" }
        for width in screenWidths {
            for rtl in [false, true] {
                let host = makeHost(
                    descriptors: ids.map { tesseraTestTile($0, size: .small) },
                    width: width,
                    rightToLeft: rtl
                )
                try assertNoOverlap(ids: ids, in: host, label: "small \(Int(width)) pt rtl=\(rtl)")
                host.coordinator.endEditing()
            }
        }
    }

    /// Круги вертикальных соседей в настоящей сетке: ровно касаются (зазор
    /// сетки 8 pt = 2 × 4 pt), а не перекрываются.
    func testVerticalNeighboursTouchExactlyInRealGrid() throws {
        let ids = (0..<6).map { "m\($0)" }
        let host = makeHost(
            descriptors: ids.map { tesseraTestTile($0, size: .medium) },
            width: 390
        )
        for column in 0..<3 {
            let upper = try circles(of: AnyHashable("m\(column)"), in: host)
            let lower = try circles(of: AnyHashable("m\(column + 3)"), in: host)
            XCTAssertEqual(upper.resize.gap(to: lower.unpin), 0, accuracy: 0.01, "колонка \(column)")
        }
        host.coordinator.endEditing()
    }

    // MARK: - Зоны касания

    /// Зоны касания на плитках 50/55/62/120 pt (LTR и RTL): детерминированны,
    /// не заходят за вертикальную ось плитки, зона открепления — верхняя
    /// половина, стрелки — нижняя. Размеры при выступе 4 pt: 50 pt — 40 × 41,
    /// 55 pt — 42,5 × 43,5, от 62 pt — полные 44 × 44.
    func testHitZonesAtSampledTileSizes() {
        let expected: [(side: CGFloat, width: CGFloat, height: CGFloat)] = [
            (50, 40, 41), (55, 42.5, 43.5), (62, 44, 44), (120, 44, 44),
        ]
        for item in expected {
            for rtl in [false, true] {
                let control = TesseraTileEditControlView(diameter: 28)
                if rtl { control.semanticContentAttribute = .forceRightToLeft }
                control.frame = CGRect(x: 0, y: 0, width: item.side, height: item.side)
                control.tileSize = control.frame.size
                control.layoutIfNeeded()
                let label = "плитка \(item.side) rtl=\(rtl)"
                let unpin = control.unpinHitFrame
                let resize = control.resizeHitFrame

                XCTAssertEqual(unpin.width, item.width, accuracy: 0.001, label)
                XCTAssertEqual(resize.width, item.width, accuracy: 0.001, label)
                XCTAssertEqual(unpin.height, item.height, accuracy: 0.001, label)
                XCTAssertEqual(resize.height, item.height, accuracy: 0.001, label)
                XCTAssertLessThanOrEqual(unpin.maxY, item.side / 2 + 0.001, label)
                XCTAssertGreaterThanOrEqual(resize.minY, item.side / 2 - 0.001, label)
                if rtl {
                    XCTAssertLessThan(unpin.maxX, item.side / 2, "не через ось: \(label)")
                    XCTAssertLessThan(resize.maxX, item.side / 2, "не через ось: \(label)")
                } else {
                    XCTAssertGreaterThan(unpin.minX, item.side / 2, "не через ось: \(label)")
                    XCTAssertGreaterThan(resize.minX, item.side / 2, "не через ось: \(label)")
                }
                XCTAssertFalse(unpin.intersects(resize), "зоны кнопок одной плитки не пересекаются: \(label)")
                // Видимая кнопка внутри своей зоны.
                XCTAssertTrue(unpin.contains(CGPoint(x: control.unpinButtonFrame.midX, y: control.unpinButtonFrame.midY)), label)
                XCTAssertTrue(resize.contains(CGPoint(x: control.resizeButtonFrame.midX, y: control.resizeButtonFrame.midY)), label)
            }
        }
    }

    /// Зоны соседних плиток одной колонки пересекаются, но выбор детерминирован:
    /// центр каждой кнопки принадлежит ей самой (с выступом 4 pt центры стали
    /// дальше от зазора, чем при 6 pt).
    func testCentreOfEveryButtonStillBelongsToItself() throws {
        let ids = (0..<6).map { "m\($0)" }
        let host = makeHost(descriptors: ids.map { tesseraTestTile($0, size: .medium) }, width: 390)
        let container = host.host.grid
        for id in ids {
            let control = try XCTUnwrap(host.coordinator.editControls[AnyHashable(id)])
            for button in [control.unpinButtonFrame, control.resizeButtonFrame] {
                let centre = control.convert(CGPoint(x: button.midX, y: button.midY), to: container)
                let hit = control.hitTest(control.convert(centre, from: container), with: nil)
                XCTAssertNotNil(hit, "центр кнопки \(id)")
                // Окно решает по всей иерархии: касание достаётся кнопке своего оверлея.
                let window = host.host.window
                let windowHit = window.hitTest(container.convert(centre, to: window), with: nil)
                XCTAssertTrue(windowHit?.superview === control, "центр кнопки \(id) принадлежит её оверлею")
            }
        }
        host.coordinator.endEditing()
    }
}

#endif
