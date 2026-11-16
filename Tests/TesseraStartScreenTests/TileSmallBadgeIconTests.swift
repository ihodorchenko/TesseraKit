//
//  TileSmallBadgeIconTests.swift
//  TesseraStartScreenTests
//
//  Малая плитка 1×1 с видимым бэйджем (капсула или точка): иконка и бэйдж, без
//  подписи (D47, как в W10M). Раньше подпись шла над бэйджем и выдавливала иконку
//  («Почта» с бэйджем «3» была без иконки). Подпись скрыта только визуально:
//  label и value VoiceOver не меняются. Малая плитка без бэйджа и плитки 2×2, 4×2
//  раскладываются как раньше. Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md
//  «Отступления реализации (E15)», п. 60; решение D47 в docs/STATE.md.
//
//  Ширины экрана 375/390/402/414 pt при 6 колонках (поля 16, зазор 8): малая
//  плитка 50,3 / 53 / 55 / 57 pt.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileSmallBadgeIconTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Стенд

    private let screenWidths: [CGFloat] = [375, 390, 402, 414]

    private let badges: [(String, TesseraTileBadge)] = [
        ("count 3", .count(3)),
        ("count 99+", .count(150)),
        ("dot", .dot),
    ]

    private func unit(_ screenWidth: CGFloat) -> CGFloat {
        (screenWidth - 32 - 5 * 8) / 6
    }

    private func inset(for size: CGSize) -> CGFloat {
        max(6, min(12, min(size.width, size.height) * 0.08))
    }

    private let envelope = UIImage(systemName: "envelope.fill")

    /// Ячейка в окне с переопределёнными категорией Dynamic Type и направлением.
    private func makeCell(
        size: CGSize,
        descriptor: TesseraTileDescriptor,
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
        cell.configure(with: .tile(descriptor), liveTileEngine: nil, isVisible: false)
        cell.setBadgeEditClearance(editClearance, animated: false)
        cell.layoutIfNeeded()
        return cell
    }

    private func descriptor(
        title: String = "Почта",
        badge: TesseraTileBadge,
        size: TesseraTileSize = .small,
        withIcon: Bool = true
    ) -> TesseraTileDescriptor {
        var descriptor = tesseraTestTile(title, size: size, badge: badge)
        if withIcon { descriptor.icon = envelope }
        return descriptor
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

    // MARK: - Малая плитка с бэйджем: иконка и бэйдж

    /// Капсула, «99+» и точка на 1×1 (все четыре ширины, LTR и RTL): подписи нет,
    /// иконка видна внутри плитки, не пересекает бэйдж, стоит по центру верхней
    /// зоны, бэйдж — в нижнем углу у конца строки. Измеренные размеры — в лог.
    func testSmallTileWithBadgeShowsIconAndBadgeWithoutTitle() {
        for width in screenWidths {
            let side = unit(width)
            let size = CGSize(width: side, height: side)
            let margin = inset(for: size)
            for (badgeName, badge) in badges {
                for rtl in [false, true] {
                    let label = "\(Int(width)) pt \(badgeName) rtl=\(rtl)"
                    let cell = makeCell(size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl)
                    let title = titleLabel(of: cell)
                    let icon = iconView(of: cell)
                    let badgeFrame = badgeView(of: cell).frame

                    XCTAssertTrue(title.isHidden, "подписи нет: \(label)")
                    XCTAssertFalse(icon.isHidden, "иконка есть: \(label)")
                    XCTAssertGreaterThanOrEqual(icon.frame.width, TesseraTileBadgeLayout.minimumSmallIconSide, label)
                    XCTAssertEqual(icon.frame.width, icon.frame.height, accuracy: 0.001, label)
                    XCTAssertTrue(
                        CGRect(origin: .zero, size: size).contains(icon.frame),
                        "иконка внутри плитки: \(label) \(icon.frame)"
                    )
                    XCTAssertFalse(icon.frame.intersects(badgeFrame), "иконка × бэйдж: \(label)")
                    XCTAssertEqual(icon.frame.midX, size.width / 2, accuracy: 0.5, "иконка по центру: \(label)")
                    XCTAssertLessThanOrEqual(icon.frame.maxY, badgeFrame.minY + 0.001, "иконка над рядом бэйджа: \(label)")
                    XCTAssertEqual(badgeFrame.maxY, size.height - margin, accuracy: 0.5, "бэйдж внизу: \(label)")
                    if rtl {
                        XCTAssertEqual(badgeFrame.minX, margin, accuracy: 0.5, label)
                    } else {
                        XCTAssertEqual(badgeFrame.maxX, size.width - margin, accuracy: 0.5, label)
                    }
                    print("[D47] \(label): tile \(size.width), icon \(icon.frame), badge \(badgeFrame)")
                }
            }
        }
    }

    /// В RTL иконка стоит там же, где в LTR (по центру), бэйдж — зеркально.
    func testIconPositionDoesNotDependOnDirection() {
        let size = CGSize(width: 53, height: 53)
        for (_, badge) in badges {
            let ltr = makeCell(size: size, descriptor: descriptor(badge: badge))
            let rtl = makeCell(size: size, descriptor: descriptor(badge: badge), rightToLeft: true)
            XCTAssertEqual(iconView(of: ltr).frame, iconView(of: rtl).frame)
            XCTAssertEqual(
                badgeView(of: ltr).frame.minX,
                size.width - badgeView(of: rtl).frame.maxX,
                accuracy: 0.5
            )
        }
    }

    /// Бэйдж «0» не виден: подпись остаётся, как без бэйджа.
    func testZeroCountBadgeDoesNotHideTitle() {
        let size = CGSize(width: 53, height: 53)
        let cell = makeCell(size: size, descriptor: descriptor(badge: .count(0)))
        XCTAssertFalse(titleLabel(of: cell).isHidden)
        XCTAssertGreaterThan(titleLabel(of: cell).frame.width, 0)
    }

    // MARK: - Без изменений

    /// Малая плитка без бэйджа: подпись и иконка как раньше (E15.1): подпись у
    /// низа полной ширины, иконка в верхнем углу по направлению чтения.
    func testSmallTileWithoutBadgeKeepsTitle() {
        for width in screenWidths {
            let side = unit(width)
            let size = CGSize(width: side, height: side)
            let margin = inset(for: size)
            for rtl in [false, true] {
                let label = "\(Int(width)) pt rtl=\(rtl)"
                let cell = makeCell(size: size, descriptor: descriptor(badge: .none), rightToLeft: rtl)
                let title = titleLabel(of: cell)
                XCTAssertFalse(title.isHidden, label)
                XCTAssertEqual(title.frame.maxY, size.height - margin, accuracy: 0.5, label)
                XCTAssertEqual(title.frame.width, size.width - 2 * margin, accuracy: 0.5, label)
                XCTAssertEqual(badgeView(of: cell).frame, .zero, label)
            }
        }
    }

    /// Малая плитка с бэйджем, но без иконки: подпись остаётся (иначе плитка
    /// осталась бы пустой), по-прежнему над рядом бэйджа.
    func testSmallTileWithBadgeButNoIconKeepsTitleAboveBadge() {
        let size = CGSize(width: 53, height: 53)
        for (badgeName, badge) in badges {
            let cell = makeCell(size: size, descriptor: descriptor(badge: badge, withIcon: false))
            let title = titleLabel(of: cell)
            XCTAssertFalse(title.isHidden, badgeName)
            XCTAssertGreaterThan(title.frame.width, 0, badgeName)
            XCTAssertLessThanOrEqual(title.frame.maxY, badgeView(of: cell).frame.minY + 0.5, badgeName)
        }
    }

    /// Плитки 2×2 и 4×2 (и 4×4) с бэйджем: подпись есть, иконка в углу — раскладка
    /// E15.1 не менялась.
    func testMediumWideAndLargeTilesKeepTheirTitleLayout() {
        for width in screenWidths {
            let side = unit(width)
            let shapes: [(TesseraTileSize, CGSize)] = [
                (.medium, CGSize(width: 2 * side + 8, height: 2 * side + 8)),
                (.wide, CGSize(width: 4 * side + 24, height: 2 * side + 8)),
                (.large, CGSize(width: 4 * side + 24, height: 4 * side + 24)),
            ]
            for (tileSize, size) in shapes {
                for (badgeName, badge) in badges {
                    let label = "\(Int(width)) pt \(tileSize) \(badgeName)"
                    let cell = makeCell(size: size, descriptor: descriptor(badge: badge, size: tileSize))
                    let title = titleLabel(of: cell)
                    let icon = iconView(of: cell)
                    XCTAssertFalse(title.isHidden, label)
                    XCTAssertGreaterThan(title.frame.width, 0, label)
                    XCTAssertFalse(title.frame.intersects(badgeView(of: cell).frame), label)
                    // Иконка — в верхнем углу (левый в LTR), а не по центру.
                    XCTAssertFalse(icon.isHidden, label)
                    XCTAssertEqual(icon.frame.minX, inset(for: size), accuracy: 0.5, label)
                    XCTAssertEqual(icon.frame.minY, inset(for: size), accuracy: 0.5, label)
                }
            }
        }
    }

    /// Размер ярлыка в модели решает, а не геометрия: плитка той же ширины,
    /// но не `.small`, остаётся с подписью.
    func testDecisionFollowsModelSizeNotGeometry() {
        let size = CGSize(width: 53, height: 53)
        let medium = makeCell(size: size, descriptor: descriptor(badge: .count(3), size: .medium))
        XCTAssertFalse(titleLabel(of: medium).isHidden)
        let small = makeCell(size: size, descriptor: descriptor(badge: .count(3), size: .small))
        XCTAssertTrue(titleLabel(of: small).isHidden)
    }

    // MARK: - Accessibility

    /// label и value VoiceOver те же, что и до D47: подпись по-прежнему
    /// озвучивается, число — в value; точка — строка D34 («есть уведомление»).
    func testAccessibilityLabelAndValueAreUnchanged() {
        let size = CGSize(width: 53, height: 53)
        let counted = makeCell(size: size, descriptor: descriptor(title: "Почта", badge: .count(3)))
        XCTAssertEqual(counted.accessibilityLabel, "Почта")
        XCTAssertEqual(counted.accessibilityValue, "3")
        XCTAssertTrue(counted.isAccessibilityElement)

        let dotted = makeCell(size: size, descriptor: descriptor(title: "Почта", badge: .dot))
        XCTAssertEqual(dotted.accessibilityLabel, "Почта")
        XCTAssertEqual(dotted.accessibilityValue, TesseraStartScreenStrings.string(.a11yBadgeDot))

        // Те же значения, что у такой же плитки без иконки (подпись на ней видна).
        let plain = makeCell(size: size, descriptor: descriptor(title: "Почта", badge: .count(3), withIcon: false))
        XCTAssertEqual(plain.accessibilityLabel, counted.accessibilityLabel)
        XCTAssertEqual(plain.accessibilityValue, counted.accessibilityValue)
    }

    // MARK: - Повторное использование и смена размера

    /// Смена размера малая → средняя возвращает подпись (resize), обратно —
    /// скрывает; переиспользованная ячейка не наследует чужой признак.
    func testResizeAndReuseRestoreTheTitle() {
        let size = CGSize(width: 53, height: 53)
        let cell = makeCell(size: size, descriptor: descriptor(badge: .count(3), size: .small))
        XCTAssertTrue(titleLabel(of: cell).isHidden)
        XCTAssertTrue(cell.isSmallTile)

        cell.configure(
            with: .tile(descriptor(badge: .count(3), size: .medium)),
            liveTileEngine: nil,
            isVisible: false
        )
        cell.layoutIfNeeded()
        XCTAssertFalse(titleLabel(of: cell).isHidden)
        XCTAssertFalse(cell.isSmallTile)

        cell.configure(
            with: .tile(descriptor(badge: .count(3), size: .small)),
            liveTileEngine: nil,
            isVisible: false
        )
        cell.layoutIfNeeded()
        XCTAssertTrue(titleLabel(of: cell).isHidden)

        cell.prepareForReuse()
        XCTAssertFalse(cell.isSmallTile)

        // Папка в такой ячейке снова показывает подпись.
        let folder = TesseraTileFolder(id: "F", title: "Папка", tiles: [descriptor(badge: .none, size: .small)], size: .small)
        cell.configure(with: .folder(folder), liveTileEngine: nil, isVisible: false)
        cell.layoutIfNeeded()
        XCTAssertFalse(titleLabel(of: cell).isHidden)
    }

    // MARK: - Правка

    /// В правке бэйдж на 1×1 по-прежнему уходит от стрелки размера (зазор 2 pt),
    /// иконка остаётся на месте, подпись не возвращается (не прыгает при входе).
    func testEditModeSlidesBadgeAndKeepsIconAndHiddenTitle() {
        for width in screenWidths {
            let side = unit(width)
            let size = CGSize(width: side, height: side)
            let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
            XCTAssertEqual(clearance, 16, accuracy: 0.001, "стрелка 20 pt, выступ 4 pt")
            for rtl in [false, true] {
                for badge in [TesseraTileBadge.count(3), .dot] {
                    let label = "\(Int(width)) pt rtl=\(rtl) \(badge)"
                    let normal = makeCell(size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl)
                    let editing = makeCell(
                        size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl, editClearance: clearance
                    )
                    XCTAssertEqual(iconView(of: editing).frame, iconView(of: normal).frame, "иконка на месте: \(label)")
                    XCTAssertTrue(titleLabel(of: editing).isHidden, "подпись не возвращается: \(label)")
                    XCTAssertEqual(badgeView(of: editing).alpha, 1, accuracy: 0.001, label)

                    let arrow = TesseraTileEditControlView.resizeButtonFrame(
                        inTileBounds: CGRect(origin: .zero, size: size),
                        side: TesseraTileEditControlView.diameter(forTileSize: size, maxDiameter: 28),
                        isRightToLeft: rtl
                    )
                    let badgeFrame = badgeView(of: editing).frame
                    let gap = rtl ? badgeFrame.minX - arrow.maxX : arrow.minX - badgeFrame.maxX
                    XCTAssertEqual(gap, TesseraTileBadgeLayout.editGap, accuracy: 0.01, "зазор до стрелки: \(label)")
                    XCTAssertFalse(iconView(of: editing).frame.intersects(badgeFrame), "иконка × бэйдж: \(label)")
                }
            }
        }
    }

    /// Правило скрытия «99+» на 1×1 в правке остаётся (плитка уже 58 pt: 34 pt
    /// капсулы + 16 pt стрелки + 2 pt зазора + поле 6 pt); иконка при этом на
    /// месте, подпись скрыта — плитка не пустеет и не прыгает.
    func testHiddenCapsuleInEditKeepsIconAndNoTitle() {
        for width in screenWidths {
            let side = unit(width)
            let size = CGSize(width: side, height: side)
            let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
            let cell = makeCell(
                size: size, descriptor: descriptor(badge: .count(150)), editClearance: clearance
            )
            let shouldHide = side < 34 + clearance + TesseraTileBadgeLayout.editGap + inset(for: size)
            XCTAssertEqual(badgeView(of: cell).alpha, shouldHide ? 0 : 1, accuracy: 0.001, "\(Int(width)) pt")
            XCTAssertTrue(shouldHide, "на всех четырёх ширинах 99+ скрыт: \(Int(width)) pt")
            XCTAssertFalse(iconView(of: cell).isHidden)
            XCTAssertTrue(titleLabel(of: cell).isHidden)
        }
    }

    // MARK: - Dynamic Type

    /// Иконка не выдавливается ни бэйджем, ни подписью на всех категориях
    /// Dynamic Type: она есть и лежит внутри плитки; до xxxLarge она не
    /// пересекает бэйдж (на accessibility-размерах счётчик вырастает больше
    /// самой плитки и ложится поверх иконки — такого бэйджа с иконкой не
    /// разнести).
    func testDynamicTypeNeverPushesIconOut() {
        let categories: [UIContentSizeCategory] = [
            .extraSmall, .large, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityExtraExtraExtraLarge,
        ]
        let intersectionFree: Set<UIContentSizeCategory> = [
            .extraSmall, .large, .extraExtraLarge, .extraExtraExtraLarge,
        ]
        for category in categories {
            for width in screenWidths {
                let side = unit(width)
                let size = CGSize(width: side, height: side)
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(category.rawValue) \(Int(width)) \(badgeName) rtl=\(rtl)"
                        let cell = makeCell(
                            size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl, category: category
                        )
                        let icon = iconView(of: cell)
                        let badgeFrame = badgeView(of: cell).frame
                        XCTAssertFalse(icon.isHidden, "иконка есть: \(label)")
                        XCTAssertTrue(titleLabel(of: cell).isHidden, "подписи нет: \(label)")
                        XCTAssertGreaterThanOrEqual(icon.frame.width, TesseraTileBadgeLayout.minimumSmallIconSide, label)
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(icon.frame),
                            "иконка внутри плитки: \(label) \(icon.frame)"
                        )
                        if intersectionFree.contains(category) {
                            XCTAssertFalse(icon.frame.intersects(badgeFrame), "иконка × бэйдж: \(label)")
                        }
                        if category == .large || category == .extraSmall {
                            print("[D47] \(label): icon \(icon.frame.size.width) pt, badge \(badgeFrame.size)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Чистая раскладка

    /// Помощник рамки иконки: внутри плитки, по центру, сторона в пределах
    /// [12, 34] и не больше 45 % меньшей стороны; растёт вместе с плиткой.
    func testSmallTileIconFrameHelper() {
        var previous: CGFloat = 0
        for tile in [CGFloat(40), 50, 53, 55, 57, 60, 75, 100, 180] {
            let size = CGSize(width: tile, height: tile)
            let inset = max(6, min(12, tile * 0.08))
            let frame = TesseraTileBadgeLayout.smallTileIconFrame(
                tileSize: size, inset: inset, bottomReserve: 18 + TesseraTileBadgeLayout.titleGap
            )
            XCTAssertGreaterThanOrEqual(frame.width, TesseraTileBadgeLayout.minimumSmallIconSide, "\(tile)")
            XCTAssertLessThanOrEqual(frame.width, TesseraTileBadgeLayout.maximumSmallIconSide, "\(tile)")
            XCTAssertLessThanOrEqual(
                frame.width,
                max(TesseraTileBadgeLayout.minimumSmallIconSide, tile * TesseraTileBadgeLayout.smallIconSideFraction),
                "\(tile)"
            )
            XCTAssertEqual(frame.midX, tile / 2, accuracy: 0.5, "\(tile)")
            XCTAssertGreaterThanOrEqual(frame.minY, inset - 0.001, "\(tile)")
            XCTAssertGreaterThanOrEqual(frame.width, previous, "растёт вместе с плиткой: \(tile)")
            previous = frame.width
        }
    }

    /// Раскладка бэйджа: `hidesTitle` без бэйджа ничего не меняет; с бэйджем —
    /// способ `.iconAndBadge` без резерва для подписи и с резервом для иконки.
    func testLayoutHidesTitleOnlyWithBadge() {
        let tile = CGSize(width: 55, height: 55)
        let none = TesseraTileBadgeLayout.make(
            tileSize: tile, badgeSize: .zero, inset: 6, isRightToLeft: false, editClearance: 0, hidesTitle: true
        )
        XCTAssertEqual(none, TesseraTileBadgeLayout())

        let capsule = TesseraTileBadgeLayout.make(
            tileSize: tile, badgeSize: CGSize(width: 20, height: 18), inset: 6, isRightToLeft: false,
            editClearance: 0, hidesTitle: true
        )
        XCTAssertEqual(capsule.arrangement, .iconAndBadge)
        XCTAssertEqual(capsule.titleTrailingReserve, 0)
        XCTAssertEqual(capsule.titleBottomReserve, 0)
        XCTAssertEqual(capsule.iconBottomReserve, 18 + TesseraTileBadgeLayout.titleGap)

        let withTitle = TesseraTileBadgeLayout.make(
            tileSize: tile, badgeSize: CGSize(width: 20, height: 18), inset: 6, isRightToLeft: false,
            editClearance: 0, hidesTitle: false
        )
        XCTAssertNotEqual(withTitle.arrangement, .iconAndBadge)
        XCTAssertEqual(withTitle.frame, capsule.frame, "угол бэйджа тот же")
    }

    // MARK: - Живая плитка

    private func liveDescriptor(
        badge: TesseraTileBadge,
        front: TesseraLiveTileFace,
        back: TesseraLiveTileFace? = nil,
        size: TesseraTileSize = .small
    ) -> TesseraTileDescriptor {
        tesseraTestLiveTile("L", front: front, back: back, badge: badge, size: size)
    }

    private func liveView(of cell: TesseraTileCell) -> TesseraLiveTileView {
        cell.contentView.subviews.compactMap { $0 as? TesseraLiveTileView }.first ?? TesseraLiveTileView()
    }

    private func faceViews(of live: TesseraLiveTileView) -> [TesseraLiveTileFaceView] {
        live.subviews.compactMap { $0 as? TesseraLiveTileFaceView }
    }

    private func labels(of face: UIView) -> [UILabel] {
        face.subviews.compactMap { $0 as? UILabel }
    }

    private func icon(of face: UIView) -> UIImageView? {
        face.subviews.compactMap { $0 as? UIImageView }.first
    }

    /// Живая плитка 1×1 в ячейке сетки с бэйджем и иконкой стороны: подписи
    /// (заголовок и подпись) скрыты, иконка видна (хотя плитка уже 80 pt, где
    /// иконку обычно прячут), бэйдж в углу; без бэйджа и без иконки — как раньше.
    func testLiveSmallTileShowsIconAndBadgeWithoutText() {
        let size = CGSize(width: 53, height: 53)
        let face = TesseraLiveTileFace(title: "Погода", detail: "Солнечно", icon: envelope)
        for (badgeName, badge) in badges {
            for rtl in [false, true] {
                let label = "\(badgeName) rtl=\(rtl)"
                let cell = makeCell(size: size, descriptor: liveDescriptor(badge: badge, front: face), rightToLeft: rtl)
                let live = liveView(of: cell)
                if rtl {
                    live.semanticContentAttribute = .forceRightToLeft
                    live.subviews.forEach { $0.semanticContentAttribute = .forceRightToLeft }
                    live.setNeedsLayout()
                    live.layoutIfNeeded()
                }
                let front = faceViews(of: live)[0]
                XCTAssertTrue(live.isSmallTile, label)
                XCTAssertTrue(labels(of: front).allSatisfy { $0.isHidden }, "текста нет: \(label)")
                let liveIcon = icon(of: front)
                XCTAssertEqual(liveIcon?.isHidden, false, "иконка есть: \(label)")
                let iconFrame = front.convert(liveIcon?.frame ?? .zero, to: live)
                XCTAssertGreaterThanOrEqual(iconFrame.width, TesseraTileBadgeLayout.minimumSmallIconSide, label)
                XCTAssertFalse(iconFrame.intersects(live.badgeView.frame), "иконка × бэйдж: \(label)")
                XCTAssertTrue(live.bounds.contains(iconFrame), label)
                XCTAssertEqual(iconFrame.midX, size.width / 2, accuracy: 0.5, label)
                // Тот же угол и тот же размер иконки, что у статичной ячейки.
                let staticCell = makeCell(size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl)
                XCTAssertEqual(iconFrame, iconView(of: staticCell).frame, "как у статичной: \(label)")
                XCTAssertEqual(live.badgeView.frame, badgeView(of: staticCell).frame, "бэйдж как у статичной: \(label)")
            }
        }
    }

    /// Живая плитка 1×1: без бэйджа, без иконки стороны и не-малая плитка
    /// остаются с текстом; сторона без иконки сохраняет текст, даже если на
    /// фронте иконка есть.
    func testLiveTileKeepsTextWhenRuleDoesNotApply() {
        let size = CGSize(width: 53, height: 53)
        let withIcon = TesseraLiveTileFace(title: "Погода", icon: envelope)
        let withoutIcon = TesseraLiveTileFace(title: "Завтра")

        // Без бэйджа.
        let noBadge = makeCell(size: size, descriptor: liveDescriptor(badge: .none, front: withIcon))
        XCTAssertTrue(labels(of: faceViews(of: liveView(of: noBadge))[0]).contains { !$0.isHidden })

        // Бэйдж есть, иконки у стороны нет.
        let noIcon = makeCell(size: size, descriptor: liveDescriptor(badge: .count(3), front: withoutIcon))
        XCTAssertTrue(labels(of: faceViews(of: liveView(of: noIcon))[0]).contains { !$0.isHidden })

        // Фронт с иконкой, бэк без: фронт без текста, бэк с текстом.
        let mixed = makeCell(
            size: size,
            descriptor: liveDescriptor(badge: .count(3), front: withIcon, back: withoutIcon)
        )
        let faces = faceViews(of: liveView(of: mixed))
        XCTAssertTrue(labels(of: faces[0]).allSatisfy { $0.isHidden })
        XCTAssertTrue(labels(of: faces[1]).contains { !$0.isHidden })

        // Не малая плитка (2×2) с бэйджем и иконкой: прежний текстовый layout.
        let medium = makeCell(
            size: CGSize(width: 114, height: 114),
            descriptor: liveDescriptor(badge: .count(3), front: withIcon, size: .medium)
        )
        XCTAssertFalse(liveView(of: medium).isSmallTile)
        XCTAssertTrue(labels(of: faceViews(of: liveView(of: medium))[0]).contains { !$0.isHidden })
    }

    /// Самостоятельный контейнер вне сетки (`isSmallTile` не выставлен) не
    /// меняет раскладку: публичное поведение `TesseraLiveTileView` прежнее.
    func testStandaloneLiveTileViewIsUnchanged() {
        let live = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 53, height: 53))
        live.setFaces(front: TesseraLiveTileFace(title: "Погода", icon: envelope), back: nil)
        live.badge = .count(3)
        live.layoutIfNeeded()
        XCTAssertFalse(live.isSmallTile)
        XCTAssertTrue(labels(of: faceViews(of: live)[0]).contains { !$0.isHidden })
    }

    // MARK: - Настоящая правка

    /// Сетка в окне, правка включена: Почта 1×1 с бэйджем в ряду малых плиток —
    /// иконка и бэйдж без подписи; кнопки не закрывают иконку и не пересекаются
    /// с бэйджем; зазор бэйдж — стрелка 2 pt на ширинах 375/390/402/414.
    func testRealEditSessionKeepsIconBadgeAndButtonsApart() throws {
        for width in screenWidths {
            for badge in [TesseraTileBadge.count(3), .dot] {
                var mail = tesseraTestTile("mail", size: .small, badge: badge)
                mail.icon = envelope
                let host = TesseraTestDragHost(
                    descriptors: [mail, tesseraTestTile("s2", size: .small)],
                    columns: 6,
                    windowSize: CGSize(width: width, height: 844)
                )
                host.coordinator.isReduceMotionEnabled = { true }
                host.host.grid.isReduceMotionEnabled = { true }

                let label = "\(Int(width)) pt \(badge)"
                let cell = try XCTUnwrap(host.host.cell("mail"), label)
                cell.layoutIfNeeded()
                XCTAssertTrue(titleLabel(of: cell).isHidden, "обычный режим, подписи нет: \(label)")
                let normalIcon = iconView(of: cell).frame

                host.coordinator.beginEditing()
                host.spin(0.05)
                cell.layoutIfNeeded()
                let control = try XCTUnwrap(host.coordinator.editControls["mail"], label)
                control.layoutIfNeeded()
                let tile = try XCTUnwrap(host.host.grid.frame(forItemID: "mail"), label)

                XCTAssertEqual(iconView(of: cell).frame, normalIcon, "иконка не двигается в правке: \(label)")
                XCTAssertTrue(titleLabel(of: cell).isHidden, label)

                let iconFrame = cell.contentView.convert(iconView(of: cell).frame, to: host.host.grid)
                let badgeFrame = cell.contentView.convert(badgeView(of: cell).frame, to: host.host.grid)
                let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)
                let unpin = control.convert(control.unpinButtonFrame, to: host.host.grid)

                XCTAssertTrue(tile.insetBy(dx: -0.5, dy: -0.5).contains(iconFrame), label)
                XCTAssertFalse(iconFrame.intersects(unpin), "иконка × открепление: \(label)")
                XCTAssertFalse(iconFrame.intersects(resize), "иконка × стрелка: \(label)")
                XCTAssertFalse(badgeFrame.intersects(resize), "бэйдж × стрелка: \(label)")
                XCTAssertFalse(badgeFrame.intersects(unpin), "бэйдж × открепление: \(label)")
                XCTAssertEqual(resize.minX - badgeFrame.maxX, TesseraTileBadgeLayout.editGap, accuracy: 0.01, label)
                print("[D47] edit \(label): tile \(tile.size.width), icon \(iconFrame.size.width) pt, " +
                      "badge \(badgeFrame.size), gap to arrow \(resize.minX - badgeFrame.maxX)")
                host.coordinator.endEditing()
            }
        }
    }
}

#endif
