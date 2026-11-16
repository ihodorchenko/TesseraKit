//
//  TileFolderBadgeTests.swift
//  TesseraStartScreenTests
//
//  Бэйдж плитки папки — сумма числовых бэйджей вложенных ярлыков (D44, E15.7).
//  Нет числовых, но есть точка — точка; сумма больше 99 — «99+» (рисует сам
//  бэйдж, как у плитки). Бэйдж папки подчиняется тем же правилам размещения, что и
//  бэйдж плитки (E15.1): нижний угол у конца строки, обход стрелки размера в
//  правке, скрытие «99+» на 1×1 в правке. Малая папка (1×1) с бэйджем не рисует
//  подпись (как малая плитка с иконкой, D47): мини-сетка стоит над рядом бэйджа.
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md «Отступления реализации
//  (E15)», п. 64; решения D44 и D47 в docs/STATE.md.
//
//  Ширины экрана 375/414 pt при 6 колонках (поля 16, зазор 8): малая плитка
//  50,3 / 57 pt.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderBadgeTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Стенд

    private let screenWidths: [CGFloat] = [375, 414]

    private let badges: [(String, TesseraTileBadge)] = [
        ("count 3", .count(3)),
        ("count 99+", .count(150)),
        ("dot", .dot),
    ]

    private func unit(_ screenWidth: CGFloat) -> CGFloat {
        (screenWidth - 32 - 5 * 8) / 6
    }

    /// Размеры папки для ширины экрана при 6 колонках, полях 16 и зазоре 8.
    private func folderSizes(screenWidth: CGFloat) -> [(TesseraTileSize, CGSize)] {
        let unit = unit(screenWidth)
        return [
            (.small, CGSize(width: unit, height: unit)),
            (.medium, CGSize(width: 2 * unit + 8, height: 2 * unit + 8)),
            (.wide, CGSize(width: 4 * unit + 24, height: 2 * unit + 8)),
        ]
    }

    private func inset(for size: CGSize) -> CGFloat {
        max(6, min(12, min(size.width, size.height) * 0.08))
    }

    /// Папка с двумя ярлыками: бэйдж первого задан, второго нет; другой состав —
    /// через `members`.
    private func folder(
        id: String = "F",
        title: String = "Работа",
        size: TesseraTileSize = .medium,
        members: [TesseraTileDescriptor]? = nil,
        badge: TesseraTileBadge = .count(3)
    ) -> TesseraTileFolder {
        TesseraTileFolder(
            id: id,
            title: title,
            tiles: members ?? [
                tesseraTestTile("mail", size: .small, badge: badge),
                tesseraTestTile("notes", size: .small),
            ],
            size: size
        )
    }

    /// Ячейка с папкой в окне с заданными Dynamic Type и направлением.
    private func makeCell(
        size: CGSize,
        folder: TesseraTileFolder,
        rightToLeft: Bool = false,
        category: UIContentSizeCategory = .large,
        editClearance: CGFloat = 0,
        isExpanded: Bool = false
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
        cell.configure(
            with: .folder(folder),
            liveTileEngine: nil,
            isVisible: false,
            isFolderExpanded: isExpanded
        )
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

    private func countText(of badgeView: TesseraLiveTileBadgeView) -> String? {
        badgeView.subviews.compactMap { $0 as? UILabel }.first?.text
    }

    // MARK: - Помощник агрегата (D44)

    private func aggregate(_ badges: [TesseraTileBadge]) -> TesseraTileBadge {
        TesseraTileFolder.aggregateBadge(of: badges.enumerated().map {
            tesseraTestTile("t\($0.offset)", size: .small, badge: $0.element)
        })
    }

    /// Пустая папка и папка без бэйджей — `.none`.
    func testAggregateIsNoneForEmptyAndBadgeless() {
        XCTAssertEqual(TesseraTileFolder.aggregateBadge(of: []), .none)
        XCTAssertEqual(aggregate([.none, .none, .none]), .none)
        XCTAssertEqual(folder(members: []).aggregateBadge, .none)
    }

    /// Счётчики складываются; один ярлык — его счётчик.
    func testAggregateSumsPositiveCounts() {
        XCTAssertEqual(aggregate([.count(3)]), .count(3))
        XCTAssertEqual(aggregate([.count(3), .count(4), .none, .count(1)]), .count(8))
        XCTAssertEqual(aggregate([.count(1), .count(1)]), .count(2))
    }

    /// Нулевые и отрицательные счётчики не учитываются; из них одних — `.none`.
    func testAggregateIgnoresZeroAndNegativeCounts() {
        XCTAssertEqual(aggregate([.count(0), .count(-5)]), .none)
        XCTAssertEqual(aggregate([.count(-5), .count(2), .count(0)]), .count(2))
        XCTAssertEqual(aggregate([.count(-100), .count(3)]), .count(3), "отрицательный не вычитается")
    }

    /// Точка без положительных счётчиков — точка; точка с `.count(0)` — тоже.
    func testAggregateDotOnlyWhenNoPositiveCount() {
        XCTAssertEqual(aggregate([.dot]), .dot)
        XCTAssertEqual(aggregate([.none, .dot, .dot]), .dot)
        XCTAssertEqual(aggregate([.dot, .count(0)]), .dot)
        XCTAssertEqual(aggregate([.count(-1), .dot]), .dot)
    }

    /// Точка и счётчик вместе: побеждает счётчик (точка не прибавляет единицу).
    func testAggregateCountWinsOverDot() {
        XCTAssertEqual(aggregate([.dot, .count(3)]), .count(3))
        XCTAssertEqual(aggregate([.count(2), .dot, .count(5)]), .count(7))
    }

    /// Сумма больше 99 остаётся числом (подпись «99+» рисует бэйдж); большая
    /// сумма насыщается и не переполняется.
    func testAggregateOverNinetyNineAndSaturation() {
        XCTAssertEqual(aggregate([.count(60), .count(60)]), .count(120))
        XCTAssertEqual(aggregate([.count(99), .count(1)]), .count(100))
        XCTAssertEqual(aggregate([.count(Int.max), .count(5)]), .count(Int.max), "без переполнения")
        XCTAssertEqual(aggregate([.count(Int.max - 1), .count(1), .count(1)]), .count(Int.max))
    }

    /// Порядок и позиция ярлыка не влияют; считаются все ярлыки, а не только
    /// четыре, видимые в превью.
    func testAggregateCountsAllMembersNotJustPreviewFour() {
        let members = (0..<6).map { tesseraTestTile("m\($0)", size: .small, badge: .count(10)) }
        XCTAssertEqual(TesseraTileFolder.aggregateBadge(of: members), .count(60))
        XCTAssertEqual(TesseraTileFolder.aggregateBadge(of: members.reversed()), .count(60))
    }

    // MARK: - Бэйдж на ячейке сетки

    /// Капсула со счётчиком, «99+» и точка — виджет виден, текст правильный.
    func testFolderCellShowsAggregateCapsuleDotAnd99Plus() {
        let size = CGSize(width: 110, height: 110)
        let sum = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .count(3)),
            tesseraTestTile("b", size: .small, badge: .count(4)),
            tesseraTestTile("c", size: .small),
        ]))
        XCTAssertFalse(badgeView(of: sum).isHidden)
        XCTAssertEqual(badgeView(of: sum).badge, .count(7))
        XCTAssertEqual(countText(of: badgeView(of: sum)), "7")
        XCTAssertGreaterThan(badgeView(of: sum).frame.width, 0)

        let many = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .count(70)),
            tesseraTestTile("b", size: .small, badge: .count(40)),
        ]))
        XCTAssertEqual(countText(of: badgeView(of: many)), "99+")

        let dot = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .dot),
            tesseraTestTile("b", size: .small),
        ]))
        XCTAssertFalse(badgeView(of: dot).isHidden)
        XCTAssertEqual(badgeView(of: dot).badge, .dot)
        XCTAssertEqual(badgeView(of: dot).frame.size, CGSize(width: 10, height: 10))
    }

    /// Ни у кого нет бэйджа — виджет скрыт, рамки нет (прежнее поведение).
    func testFolderCellHidesBadgeWhenNoMemberHasOne() {
        let cell = makeCell(
            size: CGSize(width: 110, height: 110),
            folder: folder(members: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small, badge: .count(0)),
            ])
        )
        XCTAssertTrue(badgeView(of: cell).isHidden)
        XCTAssertEqual(badgeView(of: cell).frame, .zero)
        XCTAssertFalse(titleLabel(of: cell).isHidden)
    }

    /// Переиспользованная ячейка не наследует чужой бэйдж: ни после папки с
    /// бэйджем, ни при смене на плитку или на папку без бэйджа.
    func testReusedCellDoesNotInheritFolderBadge() {
        let cell = makeCell(size: CGSize(width: 110, height: 110), folder: folder())
        XCTAssertEqual(badgeView(of: cell).badge, .count(3))

        cell.prepareForReuse()
        XCTAssertEqual(badgeView(of: cell).badge, .none)
        XCTAssertNil(cell.accessibilityValue)

        cell.configure(with: .folder(folder(badge: .none)), liveTileEngine: nil, isVisible: false)
        cell.layoutIfNeeded()
        XCTAssertTrue(badgeView(of: cell).isHidden)

        cell.configure(
            with: .tile(tesseraTestTile("t", size: .medium, badge: .count(2))),
            liveTileEngine: nil,
            isVisible: false
        )
        cell.layoutIfNeeded()
        XCTAssertEqual(badgeView(of: cell).badge, .count(2), "бэйдж ярлыка — его собственный")
    }

    // MARK: - Угол и раскладка по размерам

    /// Бэйдж папки — внизу у конца строки (справа в LTR, слева в RTL) на папках
    /// 1×1, 2×2 и 4×2; подпись и превью его не перекрывают, превью не пропадает;
    /// малая папка с бэйджем не рисует подпись.
    func testBadgeSitsBottomTrailingAndDoesNotOverlapTitleOrPreview() throws {
        for width in screenWidths {
            for (tileSize, size) in folderSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl)"
                        let cell = makeCell(
                            size: size, folder: folder(size: tileSize, badge: badge), rightToLeft: rtl
                        )
                        let bounds = cell.contentView.bounds
                        let inset = inset(for: size)
                        let badgeView = badgeView(of: cell)
                        let frame = badgeView.frame
                        XCTAssertFalse(badgeView.isHidden, label)
                        XCTAssertEqual(badgeView.alpha, 1, accuracy: 0.001, label)
                        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "внутри плитки: \(label)")
                        XCTAssertEqual(frame.maxY, bounds.height - inset, accuracy: 0.5, "у низа: \(label)")
                        if rtl {
                            XCTAssertEqual(frame.minX, inset, accuracy: 0.5, "слева в RTL: \(label)")
                        } else {
                            XCTAssertEqual(frame.maxX, bounds.width - inset, accuracy: 0.5, "справа в LTR: \(label)")
                        }

                        let preview = try XCTUnwrap(cell.folderPreviewView, label)
                        XCTAssertFalse(preview.isHidden, label)
                        XCTAssertGreaterThanOrEqual(preview.frame.width, 12, "превью не пропало: \(label)")
                        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(preview.frame), label)
                        XCTAssertFalse(preview.frame.intersects(frame), "превью × бэйдж: \(label)")

                        let title = titleLabel(of: cell)
                        if tileSize == .small {
                            XCTAssertTrue(title.isHidden, "1×1 с бэйджем без подписи: \(label)")
                            // Превью — по центру над рядом бэйджа.
                            XCTAssertEqual(preview.frame.midX, bounds.midX, accuracy: 1, label)
                            XCTAssertLessThanOrEqual(preview.frame.maxY, frame.minY, label)
                        } else {
                            XCTAssertFalse(title.isHidden, label)
                            XCTAssertFalse(title.frame.intersects(frame), "подпись × бэйдж: \(label)")
                            XCTAssertLessThanOrEqual(
                                preview.frame.maxY, min(title.frame.minY, frame.minY), "превью над рядом: \(label)"
                            )
                            // Превью по-прежнему прижато к верхнему углу по направлению чтения.
                            XCTAssertEqual(preview.frame.minY, inset, accuracy: 0.5, label)
                            XCTAssertEqual(
                                rtl ? bounds.width - preview.frame.maxX : preview.frame.minX, inset,
                                accuracy: 0.5, label
                            )
                        }
                    }
                }
            }
        }
    }

    /// Папка без бэйджа раскладывается как до E15.7: подпись видна на любом размере
    /// (в том числе 1×1) во всю ширину, превью прижато к верхнему углу, подпись — к низу.
    func testFolderWithoutBadgeKeepsItsLookAtAllSizes() throws {
        for width in screenWidths {
            for (tileSize, size) in folderSizes(screenWidth: width) {
                for rtl in [false, true] {
                    let label = "\(Int(width)) pt \(tileSize) rtl=\(rtl)"
                    let cell = makeCell(size: size, folder: folder(size: tileSize, badge: .none), rightToLeft: rtl)
                    let bounds = cell.contentView.bounds
                    let inset = inset(for: size)
                    let title = titleLabel(of: cell)
                    let preview = try XCTUnwrap(cell.folderPreviewView, label)
                    XCTAssertFalse(title.isHidden, "подпись видна: \(label)")
                    XCTAssertEqual(title.frame.minX, inset, accuracy: 0.5, label)
                    XCTAssertEqual(
                        title.frame.width, bounds.width - inset * 2, accuracy: 0.5, "подпись во всю ширину: \(label)"
                    )
                    XCTAssertEqual(title.frame.maxY, bounds.height - inset, accuracy: 0.5, label)
                    XCTAssertEqual(preview.frame.minY, inset, accuracy: 0.5, label)
                    XCTAssertLessThanOrEqual(preview.frame.maxY, title.frame.minY, label)
                    XCTAssertTrue(badgeView(of: cell).isHidden, label)
                }
            }
        }
    }

    /// Подпись папки 2×2 уступает бэйджу рядом: становится уже, а не выше.
    func testTitleOfMediumFolderYieldsToBadgeBeside() {
        let size = CGSize(width: 110, height: 110)
        let plain = makeCell(size: size, folder: folder(badge: .none))
        let withBadge = makeCell(size: size, folder: folder(badge: .count(3)))
        XCTAssertLessThan(titleLabel(of: withBadge).frame.width, titleLabel(of: plain).frame.width)
        XCTAssertLessThanOrEqual(titleLabel(of: withBadge).frame.height, titleLabel(of: plain).frame.height + 0.5)
    }

    /// Dynamic Type: на XXL и AX5 бэйдж не наезжает на подпись и превью.
    func testBadgeDoesNotOverlapAtLargeDynamicType() {
        let categories: [UIContentSizeCategory] = [.extraExtraLarge, .accessibilityExtraExtraExtraLarge]
        for category in categories {
            for (tileSize, size) in folderSizes(screenWidth: 375) {
                for (badgeName, badge) in badges {
                    let label = "\(category.rawValue) \(tileSize) \(badgeName)"
                    let cell = makeCell(size: size, folder: folder(size: tileSize, badge: badge), category: category)
                    let frame = badgeView(of: cell).frame
                    let title = titleLabel(of: cell)
                    XCTAssertTrue(cell.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), label)
                    if !title.isHidden {
                        XCTAssertFalse(title.frame.intersects(frame), "подпись × бэйдж: \(label)")
                    }
                    if let preview = cell.folderPreviewView, preview.frame.width > 0 {
                        XCTAssertFalse(preview.frame.intersects(frame), "превью × бэйдж: \(label)")
                    }
                }
            }
        }
    }

    // MARK: - Правка: обход стрелки размера

    /// В правке бэйдж папки обходит стрелку размера, а подпись и превью его не
    /// перекрывают; «99+» на 1×1 в правке скрыт.
    func testEditModeSlidesFolderBadgeAwayFromResizeArrow() {
        for width in screenWidths {
            for (tileSize, size) in folderSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl)"
                        let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
                        let normal = makeCell(size: size, folder: folder(size: tileSize, badge: badge), rightToLeft: rtl)
                        let editing = makeCell(
                            size: size, folder: folder(size: tileSize, badge: badge),
                            rightToLeft: rtl, editClearance: clearance
                        )
                        let editBadge = badgeView(of: editing)
                        let normalBadge = badgeView(of: normal)
                        let isHidden = tileSize == .small && badgeName == "count 99+"
                        XCTAssertEqual(editBadge.alpha, isHidden ? 0 : 1, accuracy: 0.001, "«99+» на 1×1: \(label)")
                        if isHidden { continue }

                        let arrow = TesseraTileEditControlView.resizeButtonFrame(
                            inTileBounds: CGRect(origin: .zero, size: size),
                            side: TesseraTileEditControlView.diameter(forTileSize: size, maxDiameter: 28),
                            isRightToLeft: rtl
                        )
                        let frame = editBadge.frame
                        XCTAssertFalse(frame.intersects(arrow), "бэйдж × стрелка: \(label)")
                        XCTAssertEqual(frame.maxY, normalBadge.frame.maxY, accuracy: 0.5, "тот же ряд: \(label)")
                        let moved = rtl
                            ? frame.minX - normalBadge.frame.minX
                            : normalBadge.frame.maxX - frame.maxX
                        XCTAssertGreaterThan(moved, 0, "сдвинулся от угла: \(label)")
                        let title = titleLabel(of: editing)
                        if !title.isHidden { XCTAssertFalse(title.frame.intersects(frame), "подпись: \(label)") }
                        if let preview = editing.folderPreviewView {
                            XCTAssertFalse(preview.frame.intersects(frame), "превью: \(label)")
                        }
                    }
                }
            }
        }
    }

    /// Живой координатор: в правке бэйдж папки не пересекает стрелку размера, а
    /// после выхода возвращается в угол (сдвиг считает координатор для папки так же,
    /// как для плитки).
    func testCoordinatorEditModeKeepsFolderBadgeClearOfArrow() throws {
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small, badge: .count(3)),
                tesseraTestTile("b", size: .small, badge: .dot),
                tesseraTestTile("c", size: .small),
            ],
            columns: 6,
            windowSize: CGSize(width: 375, height: 844),
            prepare: { store, columns in
                guard let created = store.createFolder(withTile: "a", title: "Работа", columns: columns) else { return }
                _ = store.addToFolder("b", folderID: created.id, columns: columns)
            }
        )
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.isReduceMotionEnabled = { true }
        let folder = try XCTUnwrap(host.folders.first)
        host.coordinator.beginEditing()
        host.spin(0.05)

        let cell = try XCTUnwrap(host.host.cell(folder.id))
        cell.layoutIfNeeded()
        let badgeView = badgeView(of: cell)
        XCTAssertEqual(badgeView.badge, .count(3), "точка и счётчик: побеждает счётчик")
        let control = try XCTUnwrap(host.coordinator.editControls[folder.id])
        control.layoutIfNeeded()
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: folder.id))
        XCTAssertGreaterThan(cell.badgeEditClearance, 0)
        let badgeFrame = cell.contentView.convert(badgeView.frame, to: host.host.grid)
        let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)
        XCTAssertTrue(tile.insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame))
        XCTAssertFalse(badgeFrame.intersects(resize), "бэйдж × стрелка")

        host.coordinator.endEditing()
        host.spin(0.05)
        cell.layoutIfNeeded()
        XCTAssertEqual(cell.badgeEditClearance, 0)
        XCTAssertEqual(
            self.badgeView(of: cell).frame.maxX,
            cell.contentView.bounds.width - max(6, min(12, cell.contentView.bounds.width * 0.08)),
            accuracy: 0.5
        )
    }

    // MARK: - Живое обновление

    /// Смена бэйджа члена папки доходит до плитки папки через снимок сетки: сумма,
    /// точка и скрытие обновляются на той же ячейке, без перезагрузки.
    func testMemberBadgeChangeUpdatesFolderBadgeThroughSnapshot() throws {
        func snapshot(mail: TesseraTileBadge, other: TesseraTileBadge = .none) -> TesseraTileGridSnapshot {
            TesseraTileGridSnapshot(items: [
                .folder(folder(members: [
                    tesseraTestTile("mail", size: .small, badge: mail),
                    tesseraTestTile("notes", size: .small, badge: other),
                ])),
                .tile(tesseraTestTile("solo", size: .small)),
            ], unpinned: [])
        }
        let host = TesseraTestWindowedGrid(snapshot: snapshot(mail: .none), columns: 6)
        let cell = try XCTUnwrap(host.cell("F"))
        XCTAssertTrue(badgeView(of: cell).isHidden)

        host.grid.update(snapshot: snapshot(mail: .count(3)), animated: false)
        host.layout()
        XCTAssertTrue(host.cell("F") === cell, "та же ячейка")
        XCTAssertEqual(badgeView(of: cell).badge, .count(3))
        XCTAssertFalse(badgeView(of: cell).isHidden)
        XCTAssertGreaterThan(badgeView(of: cell).frame.width, 0)
        XCTAssertEqual(cell.accessibilityValue, "3, 2")

        host.grid.update(snapshot: snapshot(mail: .count(3), other: .count(200)), animated: false)
        host.layout()
        XCTAssertEqual(countText(of: badgeView(of: cell)), "99+")

        host.grid.update(snapshot: snapshot(mail: .none, other: .dot), animated: false)
        host.layout()
        XCTAssertEqual(badgeView(of: cell).badge, .dot)
        XCTAssertEqual(cell.accessibilityValue, "\(TesseraStartScreenStrings.string(.a11yBadgeDot)), 2")

        host.grid.update(snapshot: snapshot(mail: .none), animated: false)
        host.layout()
        XCTAssertTrue(badgeView(of: cell).isHidden)
        XCTAssertEqual(cell.accessibilityValue, "2")
    }

    /// Бэйдж меняется и при анимированном применении снимка.
    func testMemberBadgeChangeUpdatesFolderBadgeWithAnimatedSnapshot() throws {
        func snapshot(_ mail: TesseraTileBadge) -> TesseraTileGridSnapshot {
            TesseraTileGridSnapshot(items: [
                .folder(folder(members: [
                    tesseraTestTile("mail", size: .small, badge: mail),
                    tesseraTestTile("notes", size: .small),
                ])),
                .tile(tesseraTestTile("solo", size: .small)),
            ], unpinned: [])
        }
        let host = TesseraTestWindowedGrid(snapshot: snapshot(.none), columns: 6)
        let cell = try XCTUnwrap(host.cell("F"))
        host.grid.update(snapshot: snapshot(.count(5)), animated: true)
        XCTAssertTrue(host.waitUntil { self.badgeView(of: cell).badge == .count(5) })
    }

    /// Хранилище: уход члена из каталога (невидимый не считается), открепление и
    /// распад папки (D45) пересчитывают бэйдж; после распада оставшийся ярлык
    /// показывает свой бэйдж плиткой.
    func testStoreDissolveAndCatalogPruneRecomputeAggregate() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        let columns = 6
        func catalog(_ entries: [(String, TesseraTileBadge)]) -> [TesseraTileDescriptor] {
            entries.map { tesseraTestTile($0.0, size: .small, badge: $0.1) }
        }
        let all: [(String, TesseraTileBadge)] = [("a", .count(3)), ("b", .count(4)), ("c", .dot), ("solo", .none)]
        store.setCatalog(catalog(all))
        store.placeItems(columns: columns)
        let created = try XCTUnwrap(store.createFolder(withTile: "a", title: "Работа", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: created.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: created.id, columns: columns))
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.aggregateBadge, .count(7))

        let host = TesseraTestWindowedGrid(snapshot: store.snapshot(columns: columns), columns: columns)
        let cell = try XCTUnwrap(host.cell(created.id))
        XCTAssertEqual(badgeView(of: cell).badge, .count(7))

        // Член ушёл из каталога: он невидим и не считается (D45).
        store.setCatalog(catalog(all.filter { $0.0 != "b" }))
        host.grid.update(snapshot: store.snapshot(columns: columns), animated: false)
        host.layout()
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.tiles.count, 2)
        XCTAssertEqual(badgeView(of: cell).badge, .count(3), "невидимый член не считается")

        // Открепление члена: в папке остаётся один ярлык — папка распускается.
        XCTAssertTrue(store.unpin("a", columns: columns))
        let dissolved = store.snapshot(columns: columns)
        XCTAssertTrue(dissolved.folders.isEmpty, "D45: папка из одного ярлыка распущена")
        host.grid.update(snapshot: dissolved, animated: false)
        host.layout()
        let tileCell = try XCTUnwrap(host.cell("c"))
        XCTAssertEqual(badgeView(of: tileCell).badge, .dot, "оставшийся ярлык — со своим бэйджем")
        XCTAssertEqual(tileCell.accessibilityValue, TesseraStartScreenStrings.string(.a11yBadgeDot))
    }

    /// Папка из трёх: открепление одного пересчитывает агрегат по оставшимся.
    func testUnpinOneOfThreeRecomputesAggregate() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        let columns = 6
        store.setCatalog([
            tesseraTestTile("a", size: .small, badge: .count(10)),
            tesseraTestTile("b", size: .small, badge: .count(5)),
            tesseraTestTile("c", size: .small, badge: .count(1)),
        ])
        store.placeItems(columns: columns)
        let created = try XCTUnwrap(store.createFolder(withTile: "a", title: "F", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: created.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: created.id, columns: columns))
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.aggregateBadge, .count(16))

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertEqual(store.snapshot(columns: columns).folders.first?.aggregateBadge, .count(6))
    }

    // MARK: - Доступность

    /// Value папки отражает агрегат тем же помощником, что и плитка: число для
    /// суммы, «есть уведомление» для точки; label — название; число ярлыков и
    /// «раскрыта» сохраняются; без бэйджа value прежнее.
    func testFolderAccessibilityValueReflectsAggregate() {
        let size = CGSize(width: 110, height: 110)
        let dotText = TesseraStartScreenStrings.string(.a11yBadgeDot)
        let expanded = TesseraStartScreenStrings.string(.panelExpanded)

        let sum = makeCell(size: size, folder: folder(badge: .count(3)))
        XCTAssertEqual(sum.accessibilityLabel, "Работа", "label — название папки")
        XCTAssertEqual(sum.accessibilityValue, "3, 2")
        sum.setFolderExpanded(true)
        XCTAssertEqual(sum.accessibilityValue, "3, 2, \(expanded)")
        sum.setFolderExpanded(false)
        XCTAssertEqual(sum.accessibilityValue, "3, 2")

        let dot = makeCell(size: size, folder: folder(badge: .dot))
        XCTAssertEqual(dot.accessibilityValue, "\(dotText), 2")

        let many = makeCell(size: size, folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .count(70)),
            tesseraTestTile("b", size: .small, badge: .count(40)),
        ]))
        XCTAssertEqual(many.accessibilityValue, "110, 2", "озвучивается число, а не «99+»")

        let plain = makeCell(size: size, folder: folder(badge: .none))
        XCTAssertEqual(plain.accessibilityValue, "2", "без бэйджа — как раньше")
        XCTAssertTrue(plain.isAccessibilityElement)
    }

    // MARK: - Панель и раскрытая папка

    /// На плитке раскрытой папки бэйдж остаётся, а у шапки панели своего бэйджа нет
    /// (бэйджи есть только у ярлыков панели — как раньше).
    func testPanelHeaderHasNoBadgeAndFolderTileKeepsOneWhenExpanded() throws {
        let folder = folder(members: [
            tesseraTestTile("mail", size: .small, badge: .count(3)),
            tesseraTestTile("notes", size: .small, badge: .dot),
        ])
        let host = TesseraTestWindowedGrid(
            items: [.folder(folder), .tile(tesseraTestTile("solo", size: .small))],
            columns: 6
        )
        host.grid.openFolder(folder, animated: false)
        XCTAssertTrue(host.waitForFolderTransition())
        host.layout()

        let tileCell = try XCTUnwrap(host.cell(folder.id))
        XCTAssertEqual(badgeView(of: tileCell).badge, .count(3), "плитка раскрытой папки сохраняет бэйдж")
        XCTAssertEqual(tileCell.accessibilityValue, "3, 2, \(TesseraStartScreenStrings.string(.panelExpanded))")

        let panel = try XCTUnwrap(host.panelCell(folderID: folder.id))
        func ownBadges(in view: UIView) -> [TesseraLiveTileBadgeView] {
            var result: [TesseraLiveTileBadgeView] = []
            for subview in view.subviews {
                if subview is TesseraTileCell { continue }
                if let badge = subview as? TesseraLiveTileBadgeView { result.append(badge) }
                result += ownBadges(in: subview)
            }
            return result
        }
        XCTAssertTrue(ownBadges(in: panel).isEmpty, "у шапки панели бэйджа нет")
        XCTAssertEqual(
            panel.shortcutCells.map { badgeView(of: $0).badge }, [.count(3), .dot], "бэйджи ярлыков панели прежние"
        )
    }

    // MARK: - Превью

    /// Мини-иконки превью сохраняют свои бэйджи рядом с бэйджем папки.
    func testPreviewMiniTilesKeepTheirOwnBadges() throws {
        let cell = makeCell(size: CGSize(width: 110, height: 110), folder: folder(members: [
            tesseraTestTile("a", size: .small, badge: .dot),
            tesseraTestTile("b", size: .small, badge: .count(3)),
            tesseraTestTile("c", size: .small),
        ]))
        let preview = try XCTUnwrap(cell.folderPreviewView)
        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(3), .none])
        XCTAssertEqual(badgeView(of: cell).badge, .count(3), "сумма: точка не прибавляет")
    }
}

#endif
