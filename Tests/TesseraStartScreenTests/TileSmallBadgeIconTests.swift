//
//  TileSmallBadgeIconTests.swift
//  TesseraStartScreenTests
//
//  A small 1×1 tile with a visible badge (a capsule or a dot): an icon and a badge, no
//  title (D47, as in Windows 10 Mobile). Previously the title sat above the badge and squeezed the icon out
//  ("Mail" with badge "3" had no icon). The title is hidden only visually:
//  the VoiceOver label and value do not change. A small tile without a badge and 2×2, 4×2 tiles
//  are laid out as before. Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  ("Implementation notes and deviations"); decision D47 in docs/DECISIONS.md.
//
//  Screen widths 375/390/402/414 pt with 6 columns (margins 16, gap 8): a small
//  tile is 50.3 / 53 / 55 / 57 pt.
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

    // MARK: - Rig

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

    /// A cell in a window with overridden Dynamic Type category and direction.
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
        title: String = "Mail",
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

    // MARK: - Small tile with a badge: icon and badge

    /// A capsule, "99+" and a dot on 1×1 (all four widths, LTR and RTL): there is no title,
    /// the icon is visible inside the tile, does not intersect the badge, sits at the center of the upper
    /// zone, and the badge is in the bottom corner at the end of the line. Measured sizes go to the log.
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

                    XCTAssertTrue(title.isHidden, "no title: \(label)")
                    XCTAssertFalse(icon.isHidden, "the icon is present: \(label)")
                    XCTAssertGreaterThanOrEqual(icon.frame.width, TesseraTileBadgeLayout.minimumSmallIconSide, label)
                    XCTAssertEqual(icon.frame.width, icon.frame.height, accuracy: 0.001, label)
                    XCTAssertTrue(
                        CGRect(origin: .zero, size: size).contains(icon.frame),
                        "the icon is inside the tile: \(label) \(icon.frame)"
                    )
                    XCTAssertFalse(icon.frame.intersects(badgeFrame), "icon × badge: \(label)")
                    XCTAssertEqual(icon.frame.midX, size.width / 2, accuracy: 0.5, "the icon is centered: \(label)")
                    XCTAssertLessThanOrEqual(icon.frame.maxY, badgeFrame.minY + 0.001, "the icon is above the badge row: \(label)")
                    XCTAssertEqual(badgeFrame.maxY, size.height - margin, accuracy: 0.5, "the badge is at the bottom: \(label)")
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

    /// In RTL the icon stands where it does in LTR (centered), and the badge is mirrored.
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

    /// A "0" badge is not visible: the title stays, as without a badge.
    func testZeroCountBadgeDoesNotHideTitle() {
        let size = CGSize(width: 53, height: 53)
        let cell = makeCell(size: size, descriptor: descriptor(badge: .count(0)))
        XCTAssertFalse(titleLabel(of: cell).isHidden)
        XCTAssertGreaterThan(titleLabel(of: cell).frame.width, 0)
    }

    // MARK: - Unchanged

    /// A small tile without a badge: the title and icon as before: the title is at
    /// the bottom at full width, and the icon is in the top corner in reading direction.
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

    /// A small tile with a badge but no icon: the title stays (otherwise the tile
    /// would be left empty), still above the badge row.
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

    /// 2×2 and 4×2 (and 4×4) tiles with a badge: the title is present and the icon is in the corner; the
    /// layout did not change.
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
                    // The icon is in the top corner (the left one in LTR), not centered.
                    XCTAssertFalse(icon.isHidden, label)
                    XCTAssertEqual(icon.frame.minX, inset(for: size), accuracy: 0.5, label)
                    XCTAssertEqual(icon.frame.minY, inset(for: size), accuracy: 0.5, label)
                }
            }
        }
    }

    /// The tile's size in the model decides, not geometry: a tile of the same width
    /// that is not `.small` keeps its title.
    func testDecisionFollowsModelSizeNotGeometry() {
        let size = CGSize(width: 53, height: 53)
        let medium = makeCell(size: size, descriptor: descriptor(badge: .count(3), size: .medium))
        XCTAssertFalse(titleLabel(of: medium).isHidden)
        let small = makeCell(size: size, descriptor: descriptor(badge: .count(3), size: .small))
        XCTAssertTrue(titleLabel(of: small).isHidden)
    }

    // MARK: - Accessibility

    /// The VoiceOver label and value are the same as before D47: the title is still
    /// spoken, the number is in the value; a dot is the D34 string ("has a notification").
    func testAccessibilityLabelAndValueAreUnchanged() {
        let size = CGSize(width: 53, height: 53)
        let counted = makeCell(size: size, descriptor: descriptor(title: "Mail", badge: .count(3)))
        XCTAssertEqual(counted.accessibilityLabel, "Mail")
        XCTAssertEqual(counted.accessibilityValue, "3")
        XCTAssertTrue(counted.isAccessibilityElement)

        let dotted = makeCell(size: size, descriptor: descriptor(title: "Mail", badge: .dot))
        XCTAssertEqual(dotted.accessibilityLabel, "Mail")
        XCTAssertEqual(dotted.accessibilityValue, TesseraStartScreenStrings.string(.a11yBadgeDot))

        // The same values as for an equivalent tile without an icon (its title is visible).
        let plain = makeCell(size: size, descriptor: descriptor(title: "Mail", badge: .count(3), withIcon: false))
        XCTAssertEqual(plain.accessibilityLabel, counted.accessibilityLabel)
        XCTAssertEqual(plain.accessibilityValue, counted.accessibilityValue)
    }

    // MARK: - Reuse and size change

    /// Changing the size from small to medium brings the title back (resize), and back
    /// hides it; a reused cell does not inherit another's flag.
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

        // A folder in such a cell shows the title again.
        let folder = TesseraTileFolder(id: "F", title: "Folder", tiles: [descriptor(badge: .none, size: .small)], size: .small)
        cell.configure(with: .folder(folder), liveTileEngine: nil, isVisible: false)
        cell.layoutIfNeeded()
        XCTAssertFalse(titleLabel(of: cell).isHidden)
    }

    // MARK: - Edit mode

    /// In edit mode the badge on 1×1 still moves away from the resize arrow (a 2 pt gap),
    /// the icon stays in place, and the title does not come back (it does not jump on entering).
    func testEditModeSlidesBadgeAndKeepsIconAndHiddenTitle() {
        for width in screenWidths {
            let side = unit(width)
            let size = CGSize(width: side, height: side)
            let clearance = TesseraTileEditControlView.badgeClearance(forTileSize: size, maxDiameter: 28)
            XCTAssertEqual(clearance, 16, accuracy: 0.001, "arrow 20 pt, protrusion 4 pt")
            for rtl in [false, true] {
                for badge in [TesseraTileBadge.count(3), .dot] {
                    let label = "\(Int(width)) pt rtl=\(rtl) \(badge)"
                    let normal = makeCell(size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl)
                    let editing = makeCell(
                        size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl, editClearance: clearance
                    )
                    XCTAssertEqual(iconView(of: editing).frame, iconView(of: normal).frame, "the icon is in place: \(label)")
                    XCTAssertTrue(titleLabel(of: editing).isHidden, "the title does not come back: \(label)")
                    XCTAssertEqual(badgeView(of: editing).alpha, 1, accuracy: 0.001, label)

                    let arrow = TesseraTileEditControlView.resizeButtonFrame(
                        inTileBounds: CGRect(origin: .zero, size: size),
                        side: TesseraTileEditControlView.diameter(forTileSize: size, maxDiameter: 28),
                        isRightToLeft: rtl
                    )
                    let badgeFrame = badgeView(of: editing).frame
                    let gap = rtl ? badgeFrame.minX - arrow.maxX : arrow.minX - badgeFrame.maxX
                    XCTAssertEqual(gap, TesseraTileBadgeLayout.editGap, accuracy: 0.01, "gap to the arrow: \(label)")
                    XCTAssertFalse(iconView(of: editing).frame.intersects(badgeFrame), "icon × badge: \(label)")
                }
            }
        }
    }

    /// The rule of hiding "99+" on 1×1 in edit mode remains (the tile is only 58 pt: 34 pt
    /// of capsule + 16 pt of arrow + 2 pt of gap + 6 pt margin); the icon stays
    /// in place and the title is hidden, so the tile does not go empty and does not jump.
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
            XCTAssertTrue(shouldHide, "at all four widths 99+ is hidden: \(Int(width)) pt")
            XCTAssertFalse(iconView(of: cell).isHidden)
            XCTAssertTrue(titleLabel(of: cell).isHidden)
        }
    }

    // MARK: - Dynamic Type

    /// The icon is squeezed out by neither the badge nor the title at all Dynamic Type
    /// categories: it is present and lies inside the tile; up to xxxLarge it does not
    /// intersect the badge (at accessibility sizes the counter grows larger than
    /// the tile itself and lies over the icon; such a badge cannot be
    /// separated from the icon).
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
                        XCTAssertFalse(icon.isHidden, "the icon is present: \(label)")
                        XCTAssertTrue(titleLabel(of: cell).isHidden, "no title: \(label)")
                        XCTAssertGreaterThanOrEqual(icon.frame.width, TesseraTileBadgeLayout.minimumSmallIconSide, label)
                        XCTAssertTrue(
                            CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(icon.frame),
                            "the icon is inside the tile: \(label) \(icon.frame)"
                        )
                        if intersectionFree.contains(category) {
                            XCTAssertFalse(icon.frame.intersects(badgeFrame), "icon × badge: \(label)")
                        }
                        if category == .large || category == .extraSmall {
                            print("[D47] \(label): icon \(icon.frame.size.width) pt, badge \(badgeFrame.size)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pure layout

    /// An icon frame helper: inside the tile, centered, with a side within
    /// [12, 34] and no more than 45 % of the smaller side; it grows with the tile.
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
            XCTAssertGreaterThanOrEqual(frame.width, previous, "grows with the tile: \(tile)")
            previous = frame.width
        }
    }

    /// Badge layout: `hidesTitle` without a badge changes nothing; with a badge it is
    /// the `.iconAndBadge` mode, with no reserve for the title and a reserve for the icon.
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
        XCTAssertEqual(withTitle.frame, capsule.frame, "the badge corner is the same")
    }

    // MARK: - Live tile

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

    /// A 1×1 live tile in a grid cell with a badge and a face icon: the labels
    /// (title and detail) are hidden, the icon is visible (although the tile is only 80 pt, where the
    /// icon is usually hidden), the badge is in the corner; without a badge and without an icon, as before.
    func testLiveSmallTileShowsIconAndBadgeWithoutText() {
        let size = CGSize(width: 53, height: 53)
        let face = TesseraLiveTileFace(title: "Weather", detail: "Sunny", icon: envelope)
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
                XCTAssertTrue(labels(of: front).allSatisfy { $0.isHidden }, "no text: \(label)")
                let liveIcon = icon(of: front)
                XCTAssertEqual(liveIcon?.isHidden, false, "the icon is present: \(label)")
                let iconFrame = front.convert(liveIcon?.frame ?? .zero, to: live)
                XCTAssertGreaterThanOrEqual(iconFrame.width, TesseraTileBadgeLayout.minimumSmallIconSide, label)
                XCTAssertFalse(iconFrame.intersects(live.badgeView.frame), "icon × badge: \(label)")
                XCTAssertTrue(live.bounds.contains(iconFrame), label)
                XCTAssertEqual(iconFrame.midX, size.width / 2, accuracy: 0.5, label)
                // The same corner and the same icon size as in the static cell.
                let staticCell = makeCell(size: size, descriptor: descriptor(badge: badge), rightToLeft: rtl)
                XCTAssertEqual(iconFrame, iconView(of: staticCell).frame, "same as the static one: \(label)")
                XCTAssertEqual(live.badgeView.frame, badgeView(of: staticCell).frame, "the badge is the same as on the static one: \(label)")
            }
        }
    }

    /// A 1×1 live tile: without a badge, without a face icon, and a non-small tile
    /// keep their text; a face without an icon keeps its text even if the
    /// front has an icon.
    func testLiveTileKeepsTextWhenRuleDoesNotApply() {
        let size = CGSize(width: 53, height: 53)
        let withIcon = TesseraLiveTileFace(title: "Weather", icon: envelope)
        let withoutIcon = TesseraLiveTileFace(title: "Tomorrow")

        // Without a badge.
        let noBadge = makeCell(size: size, descriptor: liveDescriptor(badge: .none, front: withIcon))
        XCTAssertTrue(labels(of: faceViews(of: liveView(of: noBadge))[0]).contains { !$0.isHidden })

        // There is a badge, the face has no icon.
        let noIcon = makeCell(size: size, descriptor: liveDescriptor(badge: .count(3), front: withoutIcon))
        XCTAssertTrue(labels(of: faceViews(of: liveView(of: noIcon))[0]).contains { !$0.isHidden })

        // Front with an icon, back without: the front has no text, the back has text.
        let mixed = makeCell(
            size: size,
            descriptor: liveDescriptor(badge: .count(3), front: withIcon, back: withoutIcon)
        )
        let faces = faceViews(of: liveView(of: mixed))
        XCTAssertTrue(labels(of: faces[0]).allSatisfy { $0.isHidden })
        XCTAssertTrue(labels(of: faces[1]).contains { !$0.isHidden })

        // A non-small tile (2×2) with a badge and an icon: the previous text layout.
        let medium = makeCell(
            size: CGSize(width: 114, height: 114),
            descriptor: liveDescriptor(badge: .count(3), front: withIcon, size: .medium)
        )
        XCTAssertFalse(liveView(of: medium).isSmallTile)
        XCTAssertTrue(labels(of: faceViews(of: liveView(of: medium))[0]).contains { !$0.isHidden })
    }

    /// A standalone container outside the grid (`isSmallTile` not set) does not
    /// change the layout: the public behavior of `TesseraLiveTileView` is the same.
    func testStandaloneLiveTileViewIsUnchanged() {
        let live = TesseraLiveTileView(frame: CGRect(x: 0, y: 0, width: 53, height: 53))
        live.setFaces(front: TesseraLiveTileFace(title: "Weather", icon: envelope), back: nil)
        live.badge = .count(3)
        live.layoutIfNeeded()
        XCTAssertFalse(live.isSmallTile)
        XCTAssertTrue(labels(of: faceViews(of: live)[0]).contains { !$0.isHidden })
    }

    // MARK: - Real edit mode

    /// A grid in a window with edit mode on: a Mail 1×1 with a badge in a row of small tiles:
    /// the icon and the badge without a title; the buttons do not cover the icon and do not intersect
    /// the badge; the badge-arrow gap is 2 pt at widths 375/390/402/414.
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
                XCTAssertTrue(titleLabel(of: cell).isHidden, "normal mode, no title: \(label)")
                let normalIcon = iconView(of: cell).frame

                host.coordinator.beginEditing()
                host.spin(0.05)
                cell.layoutIfNeeded()
                let control = try XCTUnwrap(host.coordinator.editControls["mail"], label)
                control.layoutIfNeeded()
                let tile = try XCTUnwrap(host.host.grid.frame(forItemID: "mail"), label)

                XCTAssertEqual(iconView(of: cell).frame, normalIcon, "the icon does not move in edit mode: \(label)")
                XCTAssertTrue(titleLabel(of: cell).isHidden, label)

                let iconFrame = cell.contentView.convert(iconView(of: cell).frame, to: host.host.grid)
                let badgeFrame = cell.contentView.convert(badgeView(of: cell).frame, to: host.host.grid)
                let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)
                let unpin = control.convert(control.unpinButtonFrame, to: host.host.grid)

                XCTAssertTrue(tile.insetBy(dx: -0.5, dy: -0.5).contains(iconFrame), label)
                XCTAssertFalse(iconFrame.intersects(unpin), "icon × unpin: \(label)")
                XCTAssertFalse(iconFrame.intersects(resize), "icon × arrow: \(label)")
                XCTAssertFalse(badgeFrame.intersects(resize), "badge × arrow: \(label)")
                XCTAssertFalse(badgeFrame.intersects(unpin), "badge × unpin: \(label)")
                XCTAssertEqual(resize.minX - badgeFrame.maxX, TesseraTileBadgeLayout.editGap, accuracy: 0.01, label)
                print("[D47] edit \(label): tile \(tile.size.width), icon \(iconFrame.size.width) pt, " +
                      "badge \(badgeFrame.size), gap to arrow \(resize.minX - badgeFrame.maxX)")
                host.coordinator.endEditing()
            }
        }
    }
}

#endif
