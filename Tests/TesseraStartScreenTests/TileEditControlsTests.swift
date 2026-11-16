//
//  TileEditControlsTests.swift
//  TesseraStartScreenTests
//
//  Тесты кнопок редактирования (E12.4/E12.5): обрезка вместе с плиткой,
//  размер по размеру плитки, зона касания не меньше 44 pt, контраст в обеих
//  темах. Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §5
//  (п. 42 «Отступлений реализации»).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditControlsTests: XCTestCase {

    private func control(
        _ id: String,
        in host: TesseraTestDragHost
    ) throws -> TesseraTileEditControlView {
        let control = try XCTUnwrap(host.coordinator.editControls[AnyHashable(id)])
        control.layoutIfNeeded()
        return control
    }

    private func buttons(of control: TesseraTileEditControlView) -> [UIButton] {
        control.subviews.compactMap { $0 as? UIButton }
    }

    private func luminance(_ color: UIColor, style: UIUserInterfaceStyle) -> CGFloat {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getWhite(&white, alpha: &alpha)
        return white
    }

    // MARK: - E12.9: кнопки не «влетают» при входе в edit

    /// Кнопки встают на место плитки сразу: ни на входе, ни после отложенной
    /// сверки у них нет анимации положения из нулевой рамки (перелёт из
    /// левого верхнего угла), в том числе при включённом Reduce Motion.
    func testControlsAppearInPlaceWithoutFlyInFromOrigin() throws {
        // E15.6: «желе» по умолчанию выключено; включённое — поворачивает слой
        // оверлея, и центр кнопок по-прежнему должен совпадать с плиткой.
        for (reduceMotion, jiggle) in [(false, false), (false, true), (true, false), (true, true)] {
            let host = TesseraTestDragHost(
                descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) },
                configuration: TesseraTileEditConfiguration(isJiggleEnabled: jiggle)
            )
            host.coordinator.isReduceMotionEnabled = { reduceMotion }
            host.coordinator.beginEditing()
            host.spin(0.03)

            for id in ["t0", "t1", "t2", "t3"] {
                let control = try control(id, in: host)
                let tile = try XCTUnwrap(host.host.grid.frame(forItemID: AnyHashable(id)))
                // «Желе» поворачивает слой, поэтому сравниваем центры (frame
                // повёрнутого вида — рамка описанного прямоугольника).
                let center = CGPoint(x: tile.midX, y: tile.midY)
                XCTAssertEqual(control.center.x, center.x, accuracy: 0.5, "reduceMotion=\(reduceMotion) \(id)")
                XCTAssertEqual(control.center.y, center.y, accuracy: 0.5, "reduceMotion=\(reduceMotion) \(id)")
                XCTAssertNil(
                    control.layer.animation(forKey: "position"),
                    "Нет перелёта: reduceMotion=\(reduceMotion) \(id)"
                )
                let shown = control.layer.presentation()?.position ?? control.layer.position
                XCTAssertEqual(shown.x, center.x, accuracy: 1, "\(id)")
                XCTAssertEqual(shown.y, center.y, accuracy: 1, "\(id)")
            }
        }
    }

    /// Кнопки плитки, поднятой long-press'ом, после отпускания возвращаются на
    /// место без перелёта: оверлей пересоздаётся анимированным проходом, и
    /// раньше его рамка анимировалась из нулевой (левый верхний угол сетки).
    func testControlsOfLiftedTileReappearInPlaceAfterRelease() throws {
        for reduceMotion in [false, true] {
            let host = TesseraTestDragHost(
                descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
            )
            host.coordinator.isReduceMotionEnabled = { reduceMotion }
            XCTAssertTrue(host.startDrag("t0"))
            XCTAssertNil(host.coordinator.editControls["t0"], "Под пальцем оверлея нет")
            host.coordinator.finishDrag(commit: true)

            var seen = false
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !seen {
                if let control = host.coordinator.editControls["t0"] {
                    seen = true
                    let tile = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
                    XCTAssertEqual(control.center.x, tile.midX, accuracy: 0.5, "reduceMotion=\(reduceMotion)")
                    XCTAssertEqual(control.center.y, tile.midY, accuracy: 0.5, "reduceMotion=\(reduceMotion)")
                    XCTAssertNil(control.layer.animation(forKey: "position"), "reduceMotion=\(reduceMotion)")
                    XCTAssertNil(control.layer.animation(forKey: "bounds.size"), "reduceMotion=\(reduceMotion)")
                }
                host.spin(0.005)
            }
            XCTAssertTrue(seen, "Оверлей вернулся: reduceMotion=\(reduceMotion)")
        }
    }

    // MARK: - E12.4: обрезка

    /// Кнопки живут в контейнере, который обрезает по `bounds` сетки — как
    /// коллекция обрезает плитки.
    func testControlsAreHostedInClippingContainerMatchingGridBounds() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<8).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        host.coordinator.beginEditing()
        let control = try control("t0", in: host)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)

        XCTAssertTrue(control.superview === container)
        XCTAssertTrue(container.superview === host.host.grid)
        XCTAssertTrue(container.clipsToBounds)
        XCTAssertEqual(container.frame, host.host.grid.bounds)

        host.coordinator.endEditing()
        XCTAssertNil(host.coordinator.editControlsHost, "Контейнер снят вместе с кнопками")
    }

    /// Плитка частично под верхним краем и частично под нижним: кнопка плитки
    /// выступает за `bounds` контейнера (будет обрезана), а полностью ушедшая
    /// плитка скрыта.
    func testControlsAreClippedLikeTileAtTopAndBottomEdges() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<48).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        host.coordinator.beginEditing()
        let grid = host.host.grid
        let container = try XCTUnwrap(host.coordinator.editControlsHost)

        // Плитка t0 (верхний ряд) частично уходит вверх.
        let top = try XCTUnwrap(grid.frame(forItemID: "t0"))
        grid.setContentOffset(CGPoint(x: 0, y: top.minY + top.height / 2), animated: false)
        host.host.layout()
        let partlyTop = try XCTUnwrap(grid.frame(forItemID: "t0"))
        XCTAssertLessThan(partlyTop.minY, 0)
        XCTAssertGreaterThan(partlyTop.maxY, 0)
        let topControl = try control("t0", in: host)
        XCTAssertFalse(topControl.isHidden)
        let unpinInGrid = topControl.convert(topControl.unpinButtonFrame, to: grid)
        XCTAssertLessThan(unpinInGrid.minY, 0, "Кнопка выступает над краем — обрежет контейнер")
        XCTAssertEqual(container.frame, grid.bounds)
        XCTAssertTrue(container.clipsToBounds)

        // Плитка, нижний край сетки которой режет пополам.
        let bottomID = try XCTUnwrap(
            grid.items.map { $0.id }.first {
                guard let f = grid.frame(forItemID: $0) else { return false }
                return f.minY < grid.bounds.maxY - 10 && f.maxY > grid.bounds.maxY + 10
            }
        )
        let bottomControl = try XCTUnwrap(host.coordinator.editControls[bottomID])
        bottomControl.layoutIfNeeded()
        XCTAssertFalse(bottomControl.isHidden)
        let resizeInGrid = bottomControl.convert(bottomControl.resizeButtonFrame, to: grid)
        XCTAssertGreaterThan(resizeInGrid.maxY, grid.bounds.maxY - 1)

        // Далеко за краем — скрыта.
        grid.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        host.host.layout()
        if let gone = host.coordinator.editControls[AnyHashable("t0")] {
            XCTAssertTrue(gone.isHidden, "Плитка вне видимой области — кнопки скрыты")
        }
        host.coordinator.endEditing()
    }

    // MARK: - E12.5: размер, зона касания, контраст

    func testControlDiameterScalesWithTileSize() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("s", size: .small),
                tesseraTestTile("m", size: .medium),
                tesseraTestTile("w", size: .wide),
                tesseraTestTile("l", size: .large),
            ]
        )
        host.coordinator.beginEditing()
        host.host.layout()

        let small = try control("s", in: host).unpinButtonFrame.width
        XCTAssertGreaterThanOrEqual(small, 20)
        XCTAssertLessThanOrEqual(small, 24, "Малая плитка — компактные кнопки")

        for id in ["m", "w", "l"] {
            XCTAssertEqual(
                try control(id, in: host).unpinButtonFrame.width,
                28,
                accuracy: 0.001,
                "Плитка \(id): диаметр = потолок controlDiameter"
            )
        }
        XCTAssertEqual(
            TesseraTileEditControlView.diameter(forTileSize: CGSize(width: 10, height: 10), maxDiameter: 28),
            20
        )
        XCTAssertEqual(
            TesseraTileEditControlView.diameter(forTileSize: CGSize(width: 500, height: 500), maxDiameter: 12),
            20,
            "Потолок ниже минимума поднимается до 20"
        )
        host.coordinator.endEditing()
    }

    /// Кнопки сидят в углах и закрывают мало: центр малой плитки (иконка)
    /// свободен, а выступ за рамку не больше 4 pt (D48: половина зазора сетки 8 pt).
    func testControlsSitAtCornersWithBoundedOverhang() throws {
        let host = TesseraTestDragHost(descriptors: [tesseraTestTile("s", size: .small)])
        host.coordinator.beginEditing()
        host.host.layout()
        let control = try control("s", in: host)
        let bounds = control.bounds
        let unpin = control.unpinButtonFrame
        let resize = control.resizeButtonFrame

        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4, "D48: выступ 4 pt")
        XCTAssertGreaterThanOrEqual(unpin.minX, -TesseraTileEditControlView.cornerOverhang - 0.001)
        XCTAssertGreaterThanOrEqual(unpin.minY, -TesseraTileEditControlView.cornerOverhang - 0.001)
        XCTAssertLessThanOrEqual(resize.maxX, bounds.maxX + TesseraTileEditControlView.cornerOverhang + 0.001)
        XCTAssertLessThanOrEqual(resize.maxY, bounds.maxY + TesseraTileEditControlView.cornerOverhang + 0.001)

        let centerZone = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)
        XCTAssertFalse(unpin.intersects(centerZone))
        XCTAssertFalse(resize.intersects(centerZone))
        host.coordinator.endEditing()
    }

    func testHitAreaIsAtLeast44AndPassesTouchesElsewhere() throws {
        let host = TesseraTestDragHost(
            descriptors: [tesseraTestTile("s", size: .small), tesseraTestTile("m", size: .medium)]
        )
        host.coordinator.beginEditing()
        host.host.layout()
        let control = try control("s", in: host)

        for hit in [control.unpinHitFrame, control.resizeHitFrame] {
            XCTAssertGreaterThanOrEqual(hit.width, 44 - 0.001)
            XCTAssertGreaterThanOrEqual(hit.height, 44 - 0.001)
        }
        XCTAssertGreaterThan(control.unpinHitFrame.width, control.unpinButtonFrame.width)

        // Точка в зоне касания, но вне видимой кнопки, попадает в кнопку.
        let unpin = control.unpinButtonFrame
        let nearUnpin = CGPoint(x: unpin.midX + 20, y: unpin.midY + 20)
        XCTAssertFalse(unpin.contains(nearUnpin))
        XCTAssertNotNil(control.hitTest(nearUnpin, with: nil))
        XCTAssertTrue(control.hitTest(nearUnpin, with: nil) is UIButton)

        // Центр плитки — мимо кнопок.
        let center = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
        XCTAssertNil(control.hitTest(center, with: nil))
        let container = try XCTUnwrap(host.coordinator.editControlsHost)
        XCTAssertNil(container.hitTest(container.convert(center, from: control), with: nil))
        host.coordinator.endEditing()
    }

    /// Светлая заливка с тёмным символом — контраст на тёмных и светлых плитках
    /// в обеих темах; кольцо динамическое.
    func testControlColorsContrastInLightAndDarkMode() throws {
        let host = TesseraTestDragHost(descriptors: [tesseraTestTile("s", size: .small)])
        host.coordinator.beginEditing()
        let control = try control("s", in: host)
        let button = try XCTUnwrap(buttons(of: control).first)

        for style in [UIUserInterfaceStyle.light, .dark] {
            let fill = try XCTUnwrap(button.backgroundColor)
            let glyph = button.tintColor ?? .clear
            XCTAssertGreaterThan(luminance(fill, style: style), 0.85, "Заливка светлая (\(style.rawValue))")
            XCTAssertLessThan(luminance(glyph, style: style), 0.2, "Символ тёмный (\(style.rawValue))")
        }

        let ring = TesseraTileEditControlView.ringColor
        let lightAlpha = ring.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor.alpha
        let darkAlpha = ring.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor.alpha
        XCTAssertNotEqual(lightAlpha, darkAlpha, "Кольцо — динамический цвет")
        XCTAssertNotNil(button.layer.borderColor)
        host.coordinator.endEditing()
    }
}

#endif
