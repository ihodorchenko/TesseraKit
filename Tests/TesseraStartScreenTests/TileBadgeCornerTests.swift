//
//  TileBadgeCornerTests.swift
//  TesseraStartScreenTests
//
//  Бэйдж плитки в нижнем углу у конца строки (D29, E15.1): правый нижний в LTR,
//  левый нижний в RTL, как в W10M. Подпись не заходит под бэйдж (рядом, если
//  остаётся место, иначе над ним); в правке бэйдж обходит стрелку размера,
//  которая сидит в том же углу. Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  §4, «Отступления реализации (E15)», п. 59; docs/W10M-STARTSCREEN.md §1.
//
//  Ширины экрана 375/390/402/414 pt при 6 колонках (поля 16, зазор 8): малая
//  плитка 50,3 / 53 / 55 / 57 pt, средняя и широкая — по формуле раскладки.
//
//  D47: малая плитка (TesseraTileSize.small) с бэйджем и иконкой показывает иконку и
//  бэйдж без подписи — этот режим покрывает `TileSmallBadgeIconTests`; здесь
//  ячейка получает в модель тот же `TesseraTileSize`, что и её геометрия (раньше тест
//  везде ставил .small), поэтому проверки подписи относятся к 2×2 и 4×2, а для
//  малой плитки — к режиму «иконка и бэйдж».
//  D48: выступ кнопок правки 4 pt — стрелка заходит в плитку на 16 pt (было 14),
//  бэйдж сдвигается на 12 pt (было 10), «99+» на 1×1 скрыт в правке на всех
//  четырёх ширинах (было ≤ 402 pt).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileBadgeCornerTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Стенд

    /// Ширины экранов проверки.
    private let screenWidths: [CGFloat] = [375, 390, 402, 414]

    private struct Shape {
        let name: String
        let size: TesseraTileSize
        let multiplier: (CGFloat) -> CGSize
    }

    /// Размеры плиток для ширины экрана при 6 колонках, полях 16 и зазоре 8.
    private func tileSizes(screenWidth: CGFloat) -> [(TesseraTileSize, CGSize)] {
        let unit = (screenWidth - 32 - 5 * 8) / 6
        return [
            (.small, CGSize(width: unit, height: unit)),
            (.medium, CGSize(width: 2 * unit + 8, height: 2 * unit + 8)),
            (.wide, CGSize(width: 4 * unit + 24, height: 2 * unit + 8)),
        ]
    }

    private let badges: [(String, TesseraTileBadge)] = [
        ("count 3", .count(3)),
        ("count 99+", .count(150)),
        ("dot", .dot),
    ]

    private func inset(for size: CGSize) -> CGFloat {
        max(6, min(12, min(size.width, size.height) * 0.08))
    }

    /// Ячейка в окне с переопределённой категорией Dynamic Type и направлением.
    private func makeCell(
        size: CGSize,
        badge: TesseraTileBadge,
        title: String = "Почта",
        withIcon: Bool = true,
        descriptorSize: TesseraTileSize = .medium,
        rightToLeft: Bool = false,
        category: UIContentSizeCategory = .large,
        editClearance: CGFloat = 0
    ) -> TesseraTileCell {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        child.didMove(toParent: parent)
        parent.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: category),
            forChild: child
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        window.rootViewController = parent
        window.makeKeyAndVisible()
        self.window = window

        let cell = TesseraTileCell(frame: CGRect(origin: CGPoint(x: 10, y: 10), size: size))
        if rightToLeft {
            cell.semanticContentAttribute = .forceRightToLeft
            cell.contentView.semanticContentAttribute = .forceRightToLeft
        }
        child.view.addSubview(cell)
        var descriptor = tesseraTestTile(title, size: descriptorSize, badge: badge)
        if withIcon {
            descriptor.icon = UIImage(systemName: "envelope.fill")
        }
        cell.configure(with: .tile(descriptor), liveTileEngine: nil, isVisible: false)
        cell.setBadgeEditClearance(editClearance, animated: false)
        cell.layoutIfNeeded()
        return cell
    }

    private func badgeView(of cell: TesseraTileCell) -> TesseraLiveTileBadgeView {
        cell.contentView.subviews.compactMap { $0 as? TesseraLiveTileBadgeView }.first
            ?? TesseraLiveTileBadgeView()
    }

    private func titleLabel(of cell: TesseraTileCell) -> UILabel {
        cell.contentView.subviews.compactMap { $0 as? UILabel }.first ?? UILabel()
    }

    private func iconView(of cell: TesseraTileCell) -> UIImageView {
        cell.contentView.subviews.compactMap { $0 as? UIImageView }.first ?? UIImageView()
    }

    // MARK: - Угол

    /// Капсула и точка — внизу у конца строки: справа в LTR, слева в RTL; на
    /// плитках 1×1, 2×2, 4×2 при всех ширинах экрана; внутри плитки; не вверху.
    func testBadgeSitsAtBottomTrailingCornerInBothDirections() {
        for width in screenWidths {
            for (tileSize, size) in tileSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl)"
                        let cell = makeCell(size: size, badge: badge, descriptorSize: tileSize, rightToLeft: rtl)
                        let view = badgeView(of: cell)
                        let frame = view.frame
                        let margin = inset(for: size)

                        XCTAssertGreaterThan(frame.width, 0, label)
                        XCTAssertEqual(frame.maxY, size.height - margin, accuracy: 0.5, "низ: \(label)")
                        XCTAssertGreaterThan(frame.midY, size.height / 2, "нижняя половина: \(label)")
                        if rtl {
                            XCTAssertEqual(frame.minX, margin, accuracy: 0.5, "левый край: \(label)")
                            XCTAssertLessThan(frame.midX, size.width / 2, label)
                        } else {
                            XCTAssertEqual(frame.maxX, size.width - margin, accuracy: 0.5, "правый край: \(label)")
                            XCTAssertGreaterThan(frame.midX, size.width / 2, label)
                        }
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).contains(frame),
                            "внутри плитки: \(label)"
                        )
                        XCTAssertEqual(view.alpha, 1, accuracy: 0.001, label)
                    }
                }
            }
        }
    }

    /// Бэйджа нет — рамка нулевая и подписи ничего не резервируется (подпись у
    /// низа, как до E15.1).
    func testNoBadgeReservesNothing() {
        let size = CGSize(width: 53, height: 53)
        let cell = makeCell(size: size, badge: .none, withIcon: false)
        XCTAssertEqual(badgeView(of: cell).frame, .zero)
        let title = titleLabel(of: cell)
        XCTAssertEqual(title.frame.maxY, size.height - inset(for: size), accuracy: 0.5)
        XCTAssertEqual(title.frame.width, size.width - 2 * inset(for: size), accuracy: 0.5)
    }

    // MARK: - Подпись и иконка

    /// Подпись и иконка не пересекают бэйдж ни на одной плитке, ширине и
    /// направлении; подпись остаётся читаемой (ненулевая ширина и высота).
    func testTitleAndIconNeverOverlapBadge() {
        for width in screenWidths {
            for (tileSize, size) in tileSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        for title in ["Почта", "Календарь событий", "Конфиденциальность"] {
                            let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl) «\(title)»"
                            let cell = makeCell(
                                size: size, badge: badge, title: title, descriptorSize: tileSize, rightToLeft: rtl
                            )
                            let badgeFrame = badgeView(of: cell).frame
                            let titleFrame = titleLabel(of: cell).frame
                            let icon = iconView(of: cell)

                            if tileSize == .small {
                                // D47: малая плитка с иконкой и бэйджем — подписи нет.
                                XCTAssertTrue(titleLabel(of: cell).isHidden, "подписи нет: \(label)")
                                XCTAssertFalse(icon.isHidden, "иконка есть: \(label)")
                                XCTAssertFalse(icon.frame.intersects(badgeFrame), "иконка × бэйдж: \(label)")
                                continue
                            }
                            XCTAssertGreaterThan(titleFrame.width, 0, "подпись есть: \(label)")
                            XCTAssertGreaterThan(titleFrame.height, 0, "подпись есть: \(label)")
                            XCTAssertFalse(titleFrame.intersects(badgeFrame), "подпись × бэйдж: \(label)")
                            if !icon.isHidden {
                                XCTAssertFalse(icon.frame.intersects(badgeFrame), "иконка × бэйдж: \(label)")
                                XCTAssertFalse(icon.frame.intersects(titleFrame), "иконка × подпись: \(label)")
                            }
                            XCTAssertTrue(
                                CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(titleFrame),
                                "подпись внутри плитки: \(label)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// Узкая плитка 1×1 с капсулой: подпись полной ширины поднимается над рядом
    /// бэйджа; на широкой плитке подпись остаётся в нижнем ряду, но уже на
    /// ширину бэйджа.
    func testTitleIsAboveBadgeOnNarrowTileAndBesideOnWideTile() {
        let narrow = CGSize(width: 53, height: 53)
        let narrowCell = makeCell(size: narrow, badge: .count(3), withIcon: false)
        let narrowBadge = badgeView(of: narrowCell).frame
        let narrowTitle = titleLabel(of: narrowCell).frame
        XCTAssertLessThanOrEqual(narrowTitle.maxY, narrowBadge.minY + 0.5, "подпись над бэйджем")
        XCTAssertEqual(
            narrowTitle.width,
            narrow.width - 2 * inset(for: narrow),
            accuracy: 0.5,
            "ширина полная"
        )

        let wide = CGSize(width: 4 * 53 + 24, height: 2 * 53 + 8)
        let wideCell = makeCell(size: wide, badge: .count(3), withIcon: false)
        let wideBadge = badgeView(of: wideCell).frame
        let wideTitle = titleLabel(of: wideCell).frame
        XCTAssertEqual(wideTitle.maxY, wide.height - inset(for: wide), accuracy: 0.5, "подпись у низа")
        XCTAssertLessThanOrEqual(wideTitle.maxX, wideBadge.minX + 0.5, "подпись левее бэйджа")
    }

    /// RTL: подпись «рядом» уступает место слева, подпись «над» — полной ширины.
    func testTitleBesideBadgeMirrorsInRightToLeft() {
        let wide = CGSize(width: 4 * 53 + 24, height: 2 * 53 + 8)
        let cell = makeCell(size: wide, badge: .count(3), withIcon: false, rightToLeft: true)
        let badge = badgeView(of: cell).frame
        let title = titleLabel(of: cell).frame
        XCTAssertGreaterThanOrEqual(title.minX, badge.maxX - 0.5, "подпись правее бэйджа")
        XCTAssertEqual(title.maxX, wide.width - inset(for: wide), accuracy: 0.5)
    }

    // MARK: - Dynamic Type

    /// Крупный Dynamic Type: капсула растёт, но остаётся внутри плитки и не
    /// наезжает на подпись.
    func testBadgeAndTitleStayApartAtAccessibilityDynamicType() {
        let categories: [UIContentSizeCategory] = [
            .extraSmall, .extraExtraExtraLarge, .accessibilityLarge, .accessibilityExtraExtraExtraLarge,
        ]
        for category in categories {
            for width in [CGFloat(375), 414] {
                for (tileSize, size) in tileSizes(screenWidth: width) {
                    for rtl in [false, true] {
                        let label = "\(category.rawValue) \(Int(width)) \(tileSize) rtl=\(rtl)"
                        let cell = makeCell(
                            size: size,
                            badge: .count(150),
                            title: "Календарь",
                            descriptorSize: tileSize,
                            rightToLeft: rtl,
                            category: category
                        )
                        let badgeFrame = badgeView(of: cell).frame
                        let titleFrame = titleLabel(of: cell).frame
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame),
                            "бэйдж внутри плитки: \(label)"
                        )
                        XCTAssertFalse(titleFrame.intersects(badgeFrame), "подпись × бэйдж: \(label)")
                    }
                }
            }
        }
    }

    /// Капсула растёт с Dynamic Type (счётчик масштабируется, потолок 13 pt).
    func testCapsuleGrowsWithDynamicType() {
        let size = CGSize(width: 115, height: 115)
        let normal = badgeView(of: makeCell(size: size, badge: .count(3), category: .large)).frame
        let huge = badgeView(of: makeCell(size: size, badge: .count(3), category: .accessibilityExtraExtraExtraLarge)).frame
        XCTAssertGreaterThanOrEqual(huge.height, normal.height)
        XCTAssertGreaterThanOrEqual(huge.width, normal.width)
    }

    // MARK: - Правка: обход стрелки размера

    /// Диаметр и рамка стрелки размера на плитке — теми же помощниками, что у
    /// оверлея кнопок.
    private func resizeButtonFrame(tile: CGSize, rtl: Bool) -> CGRect {
        let side = TesseraTileEditControlView.diameter(forTileSize: tile, maxDiameter: 28)
        return TesseraTileEditControlView.resizeButtonFrame(
            inTileBounds: CGRect(origin: .zero, size: tile),
            side: side,
            isRightToLeft: rtl
        )
    }

    private func unpinButtonFrame(tile: CGSize, rtl: Bool) -> CGRect {
        let side = TesseraTileEditControlView.diameter(forTileSize: tile, maxDiameter: 28)
        return TesseraTileEditControlView.unpinButtonFrame(
            inTileBounds: CGRect(origin: .zero, size: tile),
            side: side,
            isRightToLeft: rtl
        )
    }

    /// В правке бэйдж не пересекает ни стрелку размера (тот же угол), ни кнопку
    /// открепления (верхний угол) на 1×1, 2×2, 4×2 при всех ширинах, для
    /// капсулы, «99+» и точки; бэйдж остаётся видимым (кроме «99+» на 1×1 при
    /// плитке уже 58 pt, то есть на всех четырёх ширинах: там он скрыт только на
    /// время правки).
    func testBadgeClearsResizeAndUnpinButtonsInEditMode() {
        for width in screenWidths {
            for (tileSize, size) in tileSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl)"
                        let clearance = TesseraTileEditControlView.badgeClearance(
                            forTileSize: size,
                            maxDiameter: 28
                        )
                        let cell = makeCell(
                            size: size,
                            badge: badge,
                            descriptorSize: tileSize,
                            rightToLeft: rtl,
                            editClearance: clearance
                        )
                        let view = badgeView(of: cell)
                        // Единственный случай скрытия: капсула «99+» (34 pt) на 1×1 не
                        // помещается правее стрелки (16 pt в плитке + зазор 2 pt) с
                        // полем 6 pt, пока плитка уже 58 pt. D48 (выступ 4 pt) сдвинул
                        // границу: раньше скрытие было при ширинах экрана ≤ 402 pt, теперь
                        // плитки 50,3…57 pt, то есть все четыре ширины, скрыты.
                        let expectHidden = badgeName == "count 99+" && tileSize == .small
                            && size.width < 18 + 34 + 6
                        XCTAssertEqual(
                            view.alpha, expectHidden ? 0 : 1, accuracy: 0.001,
                            "видимость бэйджа в правке: \(label)"
                        )
                        if expectHidden {
                            XCTAssertFalse(
                                titleLabel(of: cell).frame.intersects(view.frame),
                                "подпись не наезжает на место скрытого бэйджа: \(label)"
                            )
                            continue
                        }

                        let resize = resizeButtonFrame(tile: size, rtl: rtl)
                        let unpin = unpinButtonFrame(tile: size, rtl: rtl)
                        XCTAssertFalse(view.frame.intersects(resize), "бэйдж × стрелка: \(label) \(view.frame) \(resize)")
                        XCTAssertFalse(view.frame.intersects(unpin), "бэйдж × открепление: \(label)")
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).contains(view.frame),
                            "внутри плитки: \(label)"
                        )
                        XCTAssertFalse(
                            titleLabel(of: cell).frame.intersects(view.frame),
                            "подпись × бэйдж в правке: \(label)"
                        )
                        XCTAssertFalse(
                            titleLabel(of: cell).frame.intersects(resize),
                            "подпись × стрелка: \(label)"
                        )
                    }
                }
            }
        }
    }

    /// Бэйдж в правке остаётся в нижнем ряду у того же края: сдвинут вдоль ряда
    /// от угла, высота не меняется.
    func testEditShiftMovesBadgeAlongBottomRowOnly() {
        let size = CGSize(width: 53, height: 53)
        let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
        XCTAssertEqual(clearance, 16, accuracy: 0.001, "стрелка 20 pt, выступ 4 pt (D48)")
        for rtl in [false, true] {
            let normal = badgeView(of: makeCell(size: size, badge: .count(3), rightToLeft: rtl)).frame
            let editing = badgeView(
                of: makeCell(size: size, badge: .count(3), rightToLeft: rtl, editClearance: clearance)
            ).frame
            XCTAssertEqual(editing.minY, normal.minY, accuracy: 0.001)
            XCTAssertEqual(editing.size, normal.size)
            let shift = rtl ? editing.minX - normal.minX : normal.minX - editing.minX
            XCTAssertEqual(shift, 12, accuracy: 0.5, "сдвиг = отступ стрелки + зазор − поле")
        }
    }

    /// Если бэйдж не помещается правее стрелки (капсула, раздутая Dynamic Type, на
    /// самой узкой плитке), он скрыт только на время правки; вне правки виден.
    func testBadgeHiddenOnlyWhileEditingWhenItCannotClearTheButton() {
        let size = CGSize(width: 50, height: 50)
        let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
        // Капсула такой ширины гарантированно не помещается (50 − 6 − 18 = 26 < 30).
        let layoutEditing = TesseraTileBadgeLayout.make(
            tileSize: size,
            badgeSize: CGSize(width: 30, height: 20),
            inset: 6,
            isRightToLeft: false,
            editClearance: clearance
        )
        XCTAssertTrue(layoutEditing.isHiddenByEditControls)
        let layoutNormal = TesseraTileBadgeLayout.make(
            tileSize: size,
            badgeSize: CGSize(width: 30, height: 20),
            inset: 6,
            isRightToLeft: false,
            editClearance: 0
        )
        XCTAssertFalse(layoutNormal.isHiddenByEditControls)
        XCTAssertEqual(layoutEditing.arrangement, layoutNormal.arrangement, "подпись не прыгает при входе в правку")
    }

    /// Выход из правки возвращает бэйдж в угол.
    func testBadgeReturnsToCornerWhenEditingEnds() {
        let size = CGSize(width: 53, height: 53)
        let cell = makeCell(size: size, badge: .count(3), editClearance: 16)
        let shifted = badgeView(of: cell).frame
        cell.setBadgeEditClearance(0, animated: false)
        cell.layoutIfNeeded()
        let home = badgeView(of: cell).frame
        XCTAssertGreaterThan(home.maxX, shifted.maxX)
        XCTAssertEqual(home.maxX, size.width - inset(for: size), accuracy: 0.5)
    }

    // MARK: - Чистая раскладка

    /// Чистый расчёт: способ резервирования не зависит от правки.
    func testArrangementDoesNotDependOnEditing() {
        for tile in [CGSize(width: 50, height: 50), CGSize(width: 115, height: 115), CGSize(width: 240, height: 115)] {
            for badge in [CGSize(width: 10, height: 10), CGSize(width: 18, height: 18), CGSize(width: 30, height: 18)] {
                let normal = TesseraTileBadgeLayout.make(
                    tileSize: tile, badgeSize: badge, inset: 6, isRightToLeft: false, editClearance: 0
                )
                let editing = TesseraTileBadgeLayout.make(
                    tileSize: tile, badgeSize: badge, inset: 6, isRightToLeft: false, editClearance: 16
                )
                XCTAssertEqual(normal.arrangement, editing.arrangement, "\(tile) \(badge)")
            }
        }
    }

    /// Нулевой бэйдж ничего не резервирует.
    func testZeroBadgeLayoutIsEmpty() {
        let layout = TesseraTileBadgeLayout.make(
            tileSize: CGSize(width: 100, height: 100),
            badgeSize: .zero,
            inset: 6,
            isRightToLeft: false,
            editClearance: 16
        )
        XCTAssertEqual(layout, TesseraTileBadgeLayout())
    }

    // MARK: - Живая плитка

    /// Бэйдж живой плитки тоже внизу у конца строки, и подпись обеих сторон не
    /// заходит под него (LTR и RTL).
    func testLiveTileBadgeIsBottomTrailingAndAwayFromText() {
        for rtl in [false, true] {
            let live = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 115, height: 115))
            if rtl {
                // Стороны — подвиды с неуказанным направлением: в приложении оно
                // идёт из trait-коллекции, в тесте задаём явно всем.
                live.semanticContentAttribute = .forceRightToLeft
                live.subviews.forEach { $0.semanticContentAttribute = .forceRightToLeft }
            }
            live.setFaces(
                front: TesseraLiveTileFace(title: "Погода", detail: "Солнечно"),
                back: TesseraLiveTileFace(title: "Завтра", detail: "Дождь")
            )
            live.badge = .count(5)
            live.layoutIfNeeded()
            let badge = live.badgeView.frame
            XCTAssertEqual(badge.maxY, 115 - 9.2, accuracy: 0.5, "rtl=\(rtl)")
            if rtl {
                XCTAssertLessThan(badge.midX, 115 / 2)
            } else {
                XCTAssertGreaterThan(badge.midX, 115 / 2)
            }
            let labels = live.subviews.filter { $0 !== live.badgeView }.flatMap { face in
                face.subviews.compactMap { $0 as? UILabel }.map { face.convert($0.frame, to: live) }
            }
            for text in labels where text.height > 0 {
                XCTAssertFalse(text.intersects(badge), "текст × бэйдж rtl=\(rtl) \(text) \(badge)")
            }
        }
    }
}

#endif
