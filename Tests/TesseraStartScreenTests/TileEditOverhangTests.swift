//
//  TileEditOverhangTests.swift
//  TesseraStartScreenTests
//
//  A 4 pt overhang of the edit buttons (D48): the "unpin" and "resize" buttons protrude beyond
//  the tile frame by `cornerOverhang` = 4 pt, exactly half the grid gap (8 pt),
//  so the button circles of adjacent tiles (the arrow of the upper one and the unpin of the lower one in
//  the same column) touch but do not overlap (with 6 pt the overlap was 4 pt).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, "Implementation deviations";
//  decision D48 in docs/STATE.md.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditOverhangTests: XCTestCase {

    // MARK: - Helpers

    private struct Circle {
        let center: CGPoint
        let diameter: CGFloat

        init(frame: CGRect) {
            center = CGPoint(x: frame.midX, y: frame.midY)
            diameter = frame.width
        }

        /// The gap between the circle edges (negative means overlap).
        func gap(to other: Circle) -> CGFloat {
            hypot(center.x - other.center.x, center.y - other.center.y) - (diameter + other.diameter) / 2
        }
    }

    private let screenWidths: [CGFloat] = [375, 390, 402, 414]

    /// Fixture: edit mode on; tiles of one size in a row of 6 columns.
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

    /// The button circles of a tile: (unpin, arrow) in grid coordinates.
    private func circles(
        of id: AnyHashable,
        in host: TesseraTestDragHost
    ) throws -> (unpin: Circle, resize: Circle) {
        let control = try XCTUnwrap(host.coordinator.editControls[id], "overlay \(id)")
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
                            "circles \(first).\(nameA) and \(second).\(nameB) overlap by \(-gap) pt: \(label)",
                            file: file, line: line
                        )
                    }
                }
            }
        }
        print("[D48] \(label): smallest gap between neighbor circles \(worst) pt")
    }

    // MARK: - Constant and formula

    /// The overhang is 4 pt, that is half the default grid gap (8 pt).
    func testOverhangIsHalfOfDefaultGridSpacing() {
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang * 2, 8, "2 × overhang = grid gap")
    }

    /// Pure formula: tiles of one size one above another (and side by side) with a gap of
    /// 8 pt; the arrow of the upper one and the unpin of the lower one are in the same column, the circles
    /// touch (gap 0), for all diameters and both directions. With the previous
    /// 6 pt overhang the circles would overlap by 2 × 6 − 8 = 4 pt.
    func testNeighbouringCirclesTouchButDoNotOverlap() {
        let spacing: CGFloat = 8
        for tileSide in [CGFloat(50), 55, 62, 120] {
            for rtl in [false, true] {
                let bounds = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
                let side = TesseraTileEditControlView.diameter(forTileSize: bounds.size, maxDiameter: 28)
                let upperResize = Circle(frame: TesseraTileEditControlView.resizeButtonFrame(
                    inTileBounds: bounds, side: side, isRightToLeft: rtl
                ))
                // The lower tile is shifted by the side + gap (button frames are computed
                // from the overlay origin, so the result is shifted).
                let lowerOffset = CGPoint(x: 0, y: tileSide + spacing)
                let lowerUnpin = Circle(frame: TesseraTileEditControlView.unpinButtonFrame(
                    inTileBounds: bounds, side: side, isRightToLeft: rtl
                ).offsetBy(dx: lowerOffset.x, dy: lowerOffset.y))
                XCTAssertEqual(
                    upperResize.gap(to: lowerUnpin), 0, accuracy: 0.001,
                    "vertical neighbors: tile \(tileSide) rtl=\(rtl)"
                )

                // Horizontal neighbors: the buttons of each tile are at the end of its row,
                // so a neighbor's circle is no closer than the gap minus the overhang.
                let shift = tileSide + spacing
                func button(_ frame: CGRect, dx: CGFloat) -> Circle { Circle(frame: frame.offsetBy(dx: dx, dy: 0)) }
                let unpinFrame = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: rtl)
                let resizeFrame = TesseraTileEditControlView.resizeButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: rtl)
                let ownCircles = [button(unpinFrame, dx: 0), button(resizeFrame, dx: 0)]
                let neighbourCircles = [button(unpinFrame, dx: shift), button(resizeFrame, dx: shift)]
                for own in ownCircles {
                    for other in neighbourCircles {
                        XCTAssertGreaterThanOrEqual(own.gap(to: other), -0.001, "horizontal neighbors: tile \(tileSide)")
                    }
                }
            }
        }
    }

    // MARK: - A real grid

    /// Six medium tiles (two rows of three): the circles of all buttons of different tiles do not
    /// overlap, vertically, horizontally and diagonally, at all four
    /// widths, in LTR and RTL.
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

    /// Small tiles: two rows of six; 20 pt circles on 50…57 pt tiles.
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

    /// The circles of vertical neighbors in a real grid: they exactly touch (the grid
    /// gap of 8 pt = 2 × 4 pt) instead of overlapping.
    func testVerticalNeighboursTouchExactlyInRealGrid() throws {
        let ids = (0..<6).map { "m\($0)" }
        let host = makeHost(
            descriptors: ids.map { tesseraTestTile($0, size: .medium) },
            width: 390
        )
        for column in 0..<3 {
            let upper = try circles(of: AnyHashable("m\(column)"), in: host)
            let lower = try circles(of: AnyHashable("m\(column + 3)"), in: host)
            XCTAssertEqual(upper.resize.gap(to: lower.unpin), 0, accuracy: 0.01, "column \(column)")
        }
        host.coordinator.endEditing()
    }

    // MARK: - Touch areas

    /// Touch areas on 50/55/62/120 pt tiles (LTR and RTL): deterministic,
    /// they do not cross the tile's vertical axis; the unpin area is the upper
    /// half, the arrow area is the lower one. Sizes with a 4 pt overhang: 50 pt is 40 × 41,
    /// 55 pt is 42.5 × 43.5, from 62 pt it is the full 44 × 44.
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
                let label = "tile \(item.side) rtl=\(rtl)"
                let unpin = control.unpinHitFrame
                let resize = control.resizeHitFrame

                XCTAssertEqual(unpin.width, item.width, accuracy: 0.001, label)
                XCTAssertEqual(resize.width, item.width, accuracy: 0.001, label)
                XCTAssertEqual(unpin.height, item.height, accuracy: 0.001, label)
                XCTAssertEqual(resize.height, item.height, accuracy: 0.001, label)
                XCTAssertLessThanOrEqual(unpin.maxY, item.side / 2 + 0.001, label)
                XCTAssertGreaterThanOrEqual(resize.minY, item.side / 2 - 0.001, label)
                if rtl {
                    XCTAssertLessThan(unpin.maxX, item.side / 2, "does not cross the axis: \(label)")
                    XCTAssertLessThan(resize.maxX, item.side / 2, "does not cross the axis: \(label)")
                } else {
                    XCTAssertGreaterThan(unpin.minX, item.side / 2, "does not cross the axis: \(label)")
                    XCTAssertGreaterThan(resize.minX, item.side / 2, "does not cross the axis: \(label)")
                }
                XCTAssertFalse(unpin.intersects(resize), "button areas of one tile do not intersect: \(label)")
                // The visible button is inside its area.
                XCTAssertTrue(unpin.contains(CGPoint(x: control.unpinButtonFrame.midX, y: control.unpinButtonFrame.midY)), label)
                XCTAssertTrue(resize.contains(CGPoint(x: control.resizeButtonFrame.midX, y: control.resizeButtonFrame.midY)), label)
            }
        }
    }

    /// The areas of adjacent tiles in one column intersect, but the choice is deterministic:
    /// the center of each button belongs to the button itself (with a 4 pt overhang the centers are
    /// farther from the gap than with 6 pt).
    func testCentreOfEveryButtonStillBelongsToItself() throws {
        let ids = (0..<6).map { "m\($0)" }
        let host = makeHost(descriptors: ids.map { tesseraTestTile($0, size: .medium) }, width: 390)
        let container = host.host.grid
        for id in ids {
            let control = try XCTUnwrap(host.coordinator.editControls[AnyHashable(id)])
            for button in [control.unpinButtonFrame, control.resizeButtonFrame] {
                let centre = control.convert(CGPoint(x: button.midX, y: button.midY), to: container)
                let hit = control.hitTest(control.convert(centre, from: container), with: nil)
                XCTAssertNotNil(hit, "button center \(id)")
                // The window decides over the whole hierarchy: the touch goes to the button of its own overlay.
                let window = host.host.window
                let windowHit = window.hitTest(container.convert(centre, to: window), with: nil)
                XCTAssertTrue(windowHit?.superview === control, "button center \(id) belongs to its overlay")
            }
        }
        host.coordinator.endEditing()
    }
}

#endif
