//
//  TileBadgeCornerTests.swift
//  TesseraStartScreenTests
//
//  A tile badge in the bottom corner at the end of the row (D29): bottom right in LTR,
//  bottom left in RTL, as in Windows 10 Mobile. The title does not go under the badge (it sits beside it if
//  there is room, otherwise above it); in edit mode the badge avoids the resize arrow
//  that sits in the same corner. Design document: docs/STARTSCREEN-IOS-DESIGN.md,
//  §4 and "Implementation notes and deviations"; docs/W10M-STARTSCREEN.md §1.
//
//  Screen widths 375/390/402/414 pt with 6 columns (insets 16, gap 8): a small
//  tile is 50.3 / 53 / 55 / 57 pt, medium and wide follow the layout formula.
//
//  D47: a small tile (TesseraTileSize.small) with a badge and an icon shows the icon and
//  the badge without a title; that mode is covered by `TileSmallBadgeIconTests`. Here
//  the cell gets the same `TesseraTileSize` in its model as its geometry (the test used to
//  set .small everywhere), so the title checks apply to 2×2 and 4×2, and for
//  the small tile to the "icon and badge" mode.
//  D48: the edit buttons overhang by 4 pt, so the arrow enters the tile by 16 pt (was 14),
//  the badge shifts by 12 pt (was 10), and "99+" on 1×1 is hidden in edit mode at all
//  four widths (was ≤ 402 pt).
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

    // MARK: - Fixture

    /// Screen widths under test.
    private let screenWidths: [CGFloat] = [375, 390, 402, 414]

    private struct Shape {
        let name: String
        let size: TesseraTileSize
        let multiplier: (CGFloat) -> CGSize
    }

    /// Tile sizes for a screen width with 6 columns, insets of 16 and a gap of 8.
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

    /// A cell in a window with an overridden Dynamic Type category and direction.
    private func makeCell(
        size: CGSize,
        badge: TesseraTileBadge,
        title: String = "Mail",
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

    // MARK: - Corner

    /// The capsule and the dot are at the bottom at the end of the row: right in LTR, left in RTL; on
    /// 1×1, 2×2, 4×2 tiles at all screen widths; inside the tile; not at the top.
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
                        XCTAssertEqual(frame.maxY, size.height - margin, accuracy: 0.5, "bottom: \(label)")
                        XCTAssertGreaterThan(frame.midY, size.height / 2, "bottom half: \(label)")
                        if rtl {
                            XCTAssertEqual(frame.minX, margin, accuracy: 0.5, "left edge: \(label)")
                            XCTAssertLessThan(frame.midX, size.width / 2, label)
                        } else {
                            XCTAssertEqual(frame.maxX, size.width - margin, accuracy: 0.5, "right edge: \(label)")
                            XCTAssertGreaterThan(frame.midX, size.width / 2, label)
                        }
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).contains(frame),
                            "inside the tile: \(label)"
                        )
                        XCTAssertEqual(view.alpha, 1, accuracy: 0.001, label)
                    }
                }
            }
        }
    }

    /// No badge: the frame is zero and nothing is reserved for the title (the title is at
    /// the bottom, as before the badge corner change).
    func testNoBadgeReservesNothing() {
        let size = CGSize(width: 53, height: 53)
        let cell = makeCell(size: size, badge: .none, withIcon: false)
        XCTAssertEqual(badgeView(of: cell).frame, .zero)
        let title = titleLabel(of: cell)
        XCTAssertEqual(title.frame.maxY, size.height - inset(for: size), accuracy: 0.5)
        XCTAssertEqual(title.frame.width, size.width - 2 * inset(for: size), accuracy: 0.5)
    }

    // MARK: - Title and icon

    /// The title and the icon do not intersect the badge on any tile, width or
    /// direction; the title stays readable (non-zero width and height).
    func testTitleAndIconNeverOverlapBadge() {
        for width in screenWidths {
            for (tileSize, size) in tileSizes(screenWidth: width) {
                for (badgeName, badge) in badges {
                    for rtl in [false, true] {
                        for title in ["Mail", "Calendar events", "Confidentiality"] {
                            let label = "\(Int(width)) pt \(tileSize) \(badgeName) rtl=\(rtl) «\(title)»"
                            let cell = makeCell(
                                size: size, badge: badge, title: title, descriptorSize: tileSize, rightToLeft: rtl
                            )
                            let badgeFrame = badgeView(of: cell).frame
                            let titleFrame = titleLabel(of: cell).frame
                            let icon = iconView(of: cell)

                            if tileSize == .small {
                                // D47: a small tile with an icon and a badge has no title.
                                XCTAssertTrue(titleLabel(of: cell).isHidden, "no title: \(label)")
                                XCTAssertFalse(icon.isHidden, "icon present: \(label)")
                                XCTAssertFalse(icon.frame.intersects(badgeFrame), "icon × badge: \(label)")
                                continue
                            }
                            XCTAssertGreaterThan(titleFrame.width, 0, "title present: \(label)")
                            XCTAssertGreaterThan(titleFrame.height, 0, "title present: \(label)")
                            XCTAssertFalse(titleFrame.intersects(badgeFrame), "title × badge: \(label)")
                            if !icon.isHidden {
                                XCTAssertFalse(icon.frame.intersects(badgeFrame), "icon × badge: \(label)")
                                XCTAssertFalse(icon.frame.intersects(titleFrame), "icon × title: \(label)")
                            }
                            XCTAssertTrue(
                                CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(titleFrame),
                                "title inside the tile: \(label)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// A narrow 1×1 tile with a capsule: a full-width title rises above the badge
    /// row; on a wide tile the title stays in the bottom row but is narrower by
    /// the badge width.
    func testTitleIsAboveBadgeOnNarrowTileAndBesideOnWideTile() {
        let narrow = CGSize(width: 53, height: 53)
        let narrowCell = makeCell(size: narrow, badge: .count(3), withIcon: false)
        let narrowBadge = badgeView(of: narrowCell).frame
        let narrowTitle = titleLabel(of: narrowCell).frame
        XCTAssertLessThanOrEqual(narrowTitle.maxY, narrowBadge.minY + 0.5, "title above the badge")
        XCTAssertEqual(
            narrowTitle.width,
            narrow.width - 2 * inset(for: narrow),
            accuracy: 0.5,
            "full width"
        )

        let wide = CGSize(width: 4 * 53 + 24, height: 2 * 53 + 8)
        let wideCell = makeCell(size: wide, badge: .count(3), withIcon: false)
        let wideBadge = badgeView(of: wideCell).frame
        let wideTitle = titleLabel(of: wideCell).frame
        XCTAssertEqual(wideTitle.maxY, wide.height - inset(for: wide), accuracy: 0.5, "title at the bottom")
        XCTAssertLessThanOrEqual(wideTitle.maxX, wideBadge.minX + 0.5, "title to the left of the badge")
    }

    /// RTL: the "beside" title yields space on the left, the "above" title is full width.
    func testTitleBesideBadgeMirrorsInRightToLeft() {
        let wide = CGSize(width: 4 * 53 + 24, height: 2 * 53 + 8)
        let cell = makeCell(size: wide, badge: .count(3), withIcon: false, rightToLeft: true)
        let badge = badgeView(of: cell).frame
        let title = titleLabel(of: cell).frame
        XCTAssertGreaterThanOrEqual(title.minX, badge.maxX - 0.5, "title to the right of the badge")
        XCTAssertEqual(title.maxX, wide.width - inset(for: wide), accuracy: 0.5)
    }

    // MARK: - Dynamic Type

    /// Large Dynamic Type: the capsule grows but stays inside the tile and does not
    /// run into the title.
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
                            title: "Calendar",
                            descriptorSize: tileSize,
                            rightToLeft: rtl,
                            category: category
                        )
                        let badgeFrame = badgeView(of: cell).frame
                        let titleFrame = titleLabel(of: cell).frame
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame),
                            "badge inside the tile: \(label)"
                        )
                        XCTAssertFalse(titleFrame.intersects(badgeFrame), "title × badge: \(label)")
                    }
                }
            }
        }
    }

    /// The capsule grows with Dynamic Type (the counter scales, the ceiling is 13 pt).
    func testCapsuleGrowsWithDynamicType() {
        let size = CGSize(width: 115, height: 115)
        let normal = badgeView(of: makeCell(size: size, badge: .count(3), category: .large)).frame
        let huge = badgeView(of: makeCell(size: size, badge: .count(3), category: .accessibilityExtraExtraExtraLarge)).frame
        XCTAssertGreaterThanOrEqual(huge.height, normal.height)
        XCTAssertGreaterThanOrEqual(huge.width, normal.width)
    }

    // MARK: - Edit mode: avoiding the resize arrow

    /// Diameter and frame of the resize arrow on a tile, via the same helpers as the
    /// button overlay.
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

    /// In edit mode the badge intersects neither the resize arrow (same corner) nor the
    /// unpin button (top corner) on 1×1, 2×2, 4×2 at all widths, for
    /// the capsule, "99+" and the dot; the badge stays visible (except "99+" on 1×1 with
    /// a tile narrower than 58 pt, that is at all four widths: there it is hidden only for
    /// the duration of edit mode).
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
                        // The only hiding case: the "99+" capsule (34 pt) on 1×1 does not
                        // fit to the right of the arrow (16 pt in the tile + 2 pt gap) with
                        // a 6 pt inset while the tile is narrower than 58 pt. D48 (4 pt overhang) moved
                        // the boundary: it used to be hidden at screen widths ≤ 402 pt, now
                        // tiles of 50.3…57 pt, that is all four widths, are hidden.
                        let expectHidden = badgeName == "count 99+" && tileSize == .small
                            && size.width < 18 + 34 + 6
                        XCTAssertEqual(
                            view.alpha, expectHidden ? 0 : 1, accuracy: 0.001,
                            "badge visibility in edit mode: \(label)"
                        )
                        if expectHidden {
                            XCTAssertFalse(
                                titleLabel(of: cell).frame.intersects(view.frame),
                                "the title does not run into the place of the hidden badge: \(label)"
                            )
                            continue
                        }

                        let resize = resizeButtonFrame(tile: size, rtl: rtl)
                        let unpin = unpinButtonFrame(tile: size, rtl: rtl)
                        XCTAssertFalse(view.frame.intersects(resize), "badge × arrow: \(label) \(view.frame) \(resize)")
                        XCTAssertFalse(view.frame.intersects(unpin), "badge × unpin: \(label)")
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).contains(view.frame),
                            "inside the tile: \(label)"
                        )
                        XCTAssertFalse(
                            titleLabel(of: cell).frame.intersects(view.frame),
                            "title × badge in edit mode: \(label)"
                        )
                        XCTAssertFalse(
                            titleLabel(of: cell).frame.intersects(resize),
                            "title × arrow: \(label)"
                        )
                    }
                }
            }
        }
    }

    /// In edit mode the badge stays in the bottom row at the same edge: shifted along the row
    /// away from the corner, the height does not change.
    func testEditShiftMovesBadgeAlongBottomRowOnly() {
        let size = CGSize(width: 53, height: 53)
        let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
        XCTAssertEqual(clearance, 16, accuracy: 0.001, "arrow 20 pt, overhang 4 pt (D48)")
        for rtl in [false, true] {
            let normal = badgeView(of: makeCell(size: size, badge: .count(3), rightToLeft: rtl)).frame
            let editing = badgeView(
                of: makeCell(size: size, badge: .count(3), rightToLeft: rtl, editClearance: clearance)
            ).frame
            XCTAssertEqual(editing.minY, normal.minY, accuracy: 0.001)
            XCTAssertEqual(editing.size, normal.size)
            let shift = rtl ? editing.minX - normal.minX : normal.minX - editing.minX
            XCTAssertEqual(shift, 12, accuracy: 0.5, "shift = arrow inset + gap − inset")
        }
    }

    /// If the badge does not fit to the right of the arrow (a capsule inflated by Dynamic Type, on
    /// the narrowest tile), it is hidden only during edit mode; outside edit mode it is visible.
    func testBadgeHiddenOnlyWhileEditingWhenItCannotClearTheButton() {
        let size = CGSize(width: 50, height: 50)
        let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
        // A capsule of this width is guaranteed not to fit (50 − 6 − 18 = 26 < 30).
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
        XCTAssertEqual(layoutEditing.arrangement, layoutNormal.arrangement, "the title does not jump when entering edit mode")
    }

    /// Leaving edit mode returns the badge to the corner.
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

    // MARK: - Pure layout

    /// Pure calculation: the reservation method does not depend on edit mode.
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

    /// A zero badge reserves nothing.
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

    // MARK: - Live tile

    /// A live tile badge is also at the bottom at the end of the row, and the title of both sides does not
    /// go under it (LTR and RTL).
    func testLiveTileBadgeIsBottomTrailingAndAwayFromText() {
        for rtl in [false, true] {
            let live = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 115, height: 115))
            if rtl {
                // The sides are subviews with an unspecified direction: in the app it
                // comes from the trait collection, in the test we set it explicitly for all.
                live.semanticContentAttribute = .forceRightToLeft
                live.subviews.forEach { $0.semanticContentAttribute = .forceRightToLeft }
            }
            live.setFaces(
                front: TesseraLiveTileFace(title: "Weather", detail: "Sunny"),
                back: TesseraLiveTileFace(title: "Tomorrow", detail: "Rain")
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
                XCTAssertFalse(text.intersects(badge), "text × badge rtl=\(rtl) \(text) \(badge)")
            }
        }
    }
}

#endif
