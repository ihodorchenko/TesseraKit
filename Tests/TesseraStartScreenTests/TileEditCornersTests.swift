//
//  TileEditCornersTests.swift
//  TesseraStartScreenTests
//
//  Edit button corners (D29): unpin sits in the top corner at the end of the line
//  (right in LTR, left in RTL), and the resize arrow sits in the bottom corner of the same side,
//  so both buttons of one tile stand one above the other. The rule for owning
//  touch zones on a small tile: unpin owns the upper half of the height,
//  the arrow owns the lower half, and the tile center belongs to nobody. Design document:
//  docs/STARTSCREEN-IOS-DESIGN.md (the "Implementation deviations" section).
//
//  Also covers the badge versus the buttons in real edit mode at widths 375/390/402/414 pt
//  with 6 columns.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditCornersTests: XCTestCase {

    // MARK: - Helpers

    /// A button overlay for a `side × side` tile with the given direction.
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

    // MARK: - Corners

    /// Corner helpers: unpin on top, the arrow below, both at the end of the line.
    func testCornerHelpersPutBothButtonsOnTrailingSideStackedVertically() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 60)
        let overhang = TesseraTileEditControlView.cornerOverhang
        let unpinLTR = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        let resizeLTR = TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        XCTAssertEqual(unpinLTR, CGRect(x: 80 - 20 + overhang, y: -overhang, width: 20, height: 20))
        XCTAssertEqual(resizeLTR, CGRect(x: 80 - 20 + overhang, y: 60 - 20 + overhang, width: 20, height: 20))
        XCTAssertEqual(unpinLTR.midX, resizeLTR.midX, "in one column")
        XCTAssertLessThan(unpinLTR.midY, resizeLTR.midY, "unpin is higher")

        let unpinRTL = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        let resizeRTL = TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        XCTAssertEqual(unpinRTL, CGRect(x: -overhang, y: -overhang, width: 20, height: 20))
        XCTAssertEqual(resizeRTL, CGRect(x: -overhang, y: 60 - 20 + overhang, width: 20, height: 20))
        XCTAssertEqual(unpinRTL.midX, resizeRTL.midX)
    }

    /// A grid tile's overlay builds the buttons with the same helpers (LTR and RTL).
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

    /// In real edit mode: unpin is higher and at the end of the line, the arrow is lower, and both
    /// protrude outward at the end of the line (the right edge in LTR, the left in RTL).
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

                XCTAssertLessThan(unpin.minY, tile.minY, "unpin protrudes upward: \(id) rtl=\(rtl)")
                XCTAssertGreaterThan(resize.maxY, tile.maxY, "the arrow protrudes downward: \(id) rtl=\(rtl)")
                XCTAssertEqual(unpin.midX, resize.midX, accuracy: 0.5, "one column: \(id) rtl=\(rtl)")
                if rtl {
                    XCTAssertLessThan(unpin.minX, tile.minX, "RTL: on the left \(id)")
                    XCTAssertLessThan(unpin.midX, tile.midX, id)
                } else {
                    XCTAssertGreaterThan(unpin.maxX, tile.maxX, "LTR: on the right \(id)")
                    XCTAssertGreaterThan(unpin.midX, tile.midX, id)
                }
            }
            host.coordinator.endEditing()
        }
    }

    // MARK: - Touch zone ownership rule

    private let sampledSides: [CGFloat] = [50, 55, 62, 120]

    /// The zones of a tile's two buttons never intersect; the upper half of the height
    /// belongs to unpin and the lower half to the arrow; a tap at every point of the tile and around it
    /// reaches at most one button, exactly as the zones say.
    func testHitOwnershipIsDeterministicAtSmallAndLargeTileSizes() {
        for side in sampledSides {
            for rtl in [false, true] {
                let control = makeControl(side: side, rightToLeft: rtl)
                let unpinZone = control.unpinHitFrame
                let resizeZone = control.resizeHitFrame
                let label = "tile \(side) rtl=\(rtl)"

                XCTAssertFalse(unpinZone.isEmpty, label)
                XCTAssertFalse(resizeZone.isEmpty, label)
                XCTAssertLessThanOrEqual(unpinZone.maxY, side / 2 + 0.001, "unpin is the upper half: \(label)")
                XCTAssertGreaterThanOrEqual(resizeZone.minY, side / 2 - 0.001, "the arrow is the lower half: \(label)")
                // D48: the 4 pt protrusion moved the button center 2 pt closer to the tile axis, and
                // the clipping at the axis got deeper: 50 pt gives about 40 × 41, 55 pt about 42.5 × 43.5,
                // and from 62 pt the full 44 × 44.
                XCTAssertGreaterThanOrEqual(unpinZone.width, 40 - 0.001, "zone width \(label)")
                XCTAssertGreaterThanOrEqual(unpinZone.height, 41 - 0.001, "zone height \(label)")
                XCTAssertGreaterThanOrEqual(resizeZone.width, 40 - 0.001, label)
                XCTAssertGreaterThanOrEqual(resizeZone.height, 41 - 0.001, label)
                if side >= 62 {
                    XCTAssertEqual(unpinZone.width, 44, accuracy: 0.001, label)
                    XCTAssertEqual(unpinZone.height, 44, accuracy: 0.001, label)
                    XCTAssertEqual(resizeZone.width, 44, accuracy: 0.001, label)
                    XCTAssertEqual(resizeZone.height, 44, accuracy: 0.001, label)
                }

                let unpin = unpinButton(of: control)
                let resize = resizeButton(of: control)
                XCTAssertNotNil(unpin, label)
                XCTAssertNotNil(resize, label)

                // Sampling: the hitTest result matches the zones, with no intersections.
                var y: CGFloat = -30
                while y < side + 30 {
                    var x: CGFloat = -30
                    while x < side + 30 {
                        let point = CGPoint(x: x, y: y)
                        let inUnpin = unpinZone.contains(point)
                        let inResize = resizeZone.contains(point)
                        XCTAssertFalse(inUnpin && inResize, "zones intersected at \(point): \(label)")
                        let hit = control.hitTest(point, with: nil)
                        if inUnpin {
                            XCTAssertTrue(hit === unpin, "point \(point) belongs to unpin: \(label)")
                        } else if inResize {
                            XCTAssertTrue(hit === resize, "point \(point) belongs to the arrow: \(label)")
                        } else {
                            XCTAssertNil(hit, "point \(point) belongs to nobody: \(label)")
                        }
                        x += 0.5
                    }
                    y += 0.5
                }
            }
        }
    }

    /// The tile center and the whole strip along the vertical axis do not belong to the buttons
    /// (a tap on the body, long press and drag work), while the button centers themselves are a zone.
    func testTileCenterBelongsToNeitherButton() {
        for side in sampledSides {
            for rtl in [false, true] {
                let control = makeControl(side: side, rightToLeft: rtl)
                let label = "tile \(side) rtl=\(rtl)"
                let center = CGPoint(x: side / 2, y: side / 2)
                XCTAssertNil(control.hitTest(center, with: nil), label)
                XCTAssertFalse(control.unpinHitFrame.contains(center), label)
                XCTAssertFalse(control.resizeHitFrame.contains(center), label)
                // Vertical axis: neither button has a zone across it.
                for y in stride(from: CGFloat(0), through: side, by: 1) {
                    XCTAssertNil(control.hitTest(CGPoint(x: side / 2, y: y), with: nil), "axis y=\(y): \(label)")
                }
                // The opposite (leading) half of the tile is the body.
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

    /// The old overlap: on a tile of about 50 pt the 44 pt zones would intersect (by about 1.5–2 pt),
    /// now the gap between zones in height is non-negative at all sizes.
    func testZonesDoNotOverlapAtSmallestTile() {
        for side in [CGFloat(48), 50, 50.5, 52, 55] {
            let control = makeControl(side: side)
            let gap = control.resizeHitFrame.minY - control.unpinHitFrame.maxY
            XCTAssertGreaterThanOrEqual(gap, -0.001, "tile \(side): gap \(gap)")
        }
    }

    /// A pure rule: symmetric by direction, with the zone inside the allowed area.
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
            XCTAssertEqual(rtl.minX, bounds.width - ltr.maxX, accuracy: 0.001, "mirrored (upper=\(upper))")
            XCTAssertEqual(ltr.minY, rtl.minY, accuracy: 0.001)
            XCTAssertGreaterThan(ltr.minX, bounds.midX - 0.001)
            XCTAssertLessThan(rtl.maxX, bounds.midX + 0.001)
        }
    }

    // MARK: - Adjacent tiles

    /// Tiles one above the other (8 pt gap): the arrow zone of the upper tile and the
    /// unpin zone of the lower one intersect; a touch in the intersection goes to the button with the
    /// nearest center, deterministically, for every point of the area.
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

            XCTAssertTrue(container.hitTest(upperResize, with: nil)?.superview === upper, "arrow center: \(side)")
            XCTAssertTrue(container.hitTest(lowerUnpin, with: nil)?.superview === lower, "unpin center: \(side)")

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
                            XCTAssertTrue(winner === upper, "\(point): the upper tile's arrow is closer, tile \(side)")
                        } else if lowerDistance < upperDistance {
                            XCTAssertTrue(winner === lower, "\(point): the lower tile's unpin is closer, tile \(side)")
                        } else {
                            XCTAssertNotNil(winner)
                        }
                    }
                    x += 1
                }
                y += 1
            }
            XCTAssertGreaterThan(overlapSamples, 0, "neighbor zones really intersect: \(side)")
        }
    }

    // MARK: - Folder panel tile

    /// The panel: the button is in the top corner at the end of the line, its zone is the corner quarter of that
    /// same corner (right in LTR, left in RTL), and the center and opposite corners are the body.
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
                let label = "panel \(side) rtl=\(rtl)"

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
                XCTAssertNil(control.hitTest(CGPoint(x: leading, y: 4), with: nil), "leading top corner: \(label)")
                XCTAssertNil(control.hitTest(CGPoint(x: trailing, y: side - 4), with: nil), "bottom corner: \(label)")
                XCTAssertNotNil(control.hitTest(CGPoint(x: trailing, y: 4), with: nil), "trailing top corner: \(label)")
            }
        }
    }

    // MARK: - Badge and buttons in real edit mode

    private func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }

    /// Widths 375/390/402/414 pt, 6 columns: for 1×1, 2×2 and 4×2 tiles with badges
    /// (capsule, "99+", dot) the badge in edit mode intersects neither the resize arrow nor
    /// unpin; the badge stays visible (except "99+" on 1×1: the tile is only 58 pt wide, D48:
    /// it is hidden only while editing). The measured gaps are printed to the log.
    func testBadgeDoesNotOverlapButtonsInRealEditSession() throws {
        let badges: [(String, TesseraTileBadge)] = [("count 3", .count(3)), ("99+", .count(150)), ("dot", .dot)]
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

                    // D48: with a 4 pt protrusion "99+" (34 pt) does not fit to the right of the arrow
                    // on tiles 58 pt wide, which is all four widths (it used to be ≤ 402 pt).
                    let expectHidden = badgeName == "99+" && id.hasPrefix("s") && tile.width < 18 + 34 + 6
                    XCTAssertEqual(
                        badgeView.alpha, expectHidden ? 0 : 1, accuracy: 0.001,
                        "badge visibility in edit mode: \(label)"
                    )
                    if expectHidden {
                        print("\(label): tile \(tile.size) — badge hidden while editing")
                        continue
                    }
                    let badgeFrame = cell.contentView.convert(badgeView.frame, to: host.host.grid)
                    let resize = control.convert(control.resizeButtonFrame, to: host.host.grid)
                    let unpin = control.convert(control.unpinButtonFrame, to: host.host.grid)
                    XCTAssertTrue(tile.insetBy(dx: -0.5, dy: -0.5).contains(badgeFrame), "inside the tile: \(label)")
                    XCTAssertFalse(badgeFrame.intersects(resize), "badge × arrow: \(label)")
                    XCTAssertFalse(badgeFrame.intersects(unpin), "badge × unpin: \(label)")
                    let resizeGap = gap(badgeFrame, resize)
                    let unpinGap = gap(badgeFrame, unpin)
                    XCTAssertGreaterThanOrEqual(resizeGap, TesseraTileBadgeLayout.editGap - 0.01, label)
                    print("\(label): tile \(tile.size), badge \(badgeFrame.size), gap to resize \(resizeGap), to unpin \(unpinGap)")
                }
                host.coordinator.endEditing()

                // After leaving edit mode the badge returns to the corner.
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
