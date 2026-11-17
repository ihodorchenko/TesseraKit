//
//  TileEditControlsTests.swift
//  TesseraStartScreenTests
//
//  Tests of the edit-mode buttons: clipped together with the tile,
//  sized by tile size, a touch target of at least 44 pt, contrast in both
//  themes. Design document: docs/STARTSCREEN-IOS-DESIGN.md §5
//  ("Implementation deviations").
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

    // MARK: - Buttons do not fly in when entering edit mode

    /// The buttons sit in the tile's place immediately: neither on entry nor after the deferred
    /// reconciliation do they have a position animation from a zero frame (flying in
    /// from the top-left corner), including with Reduce Motion enabled.
    func testControlsAppearInPlaceWithoutFlyInFromOrigin() throws {
        // The jiggle is off by default; when enabled it rotates the overlay layer,
        // and the button centers must still coincide with the tile.
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
                // The jiggle rotates the layer, so compare centers (the frame
                // of a rotated view is the frame of its bounding rectangle).
                let center = CGPoint(x: tile.midX, y: tile.midY)
                XCTAssertEqual(control.center.x, center.x, accuracy: 0.5, "reduceMotion=\(reduceMotion) \(id)")
                XCTAssertEqual(control.center.y, center.y, accuracy: 0.5, "reduceMotion=\(reduceMotion) \(id)")
                XCTAssertNil(
                    control.layer.animation(forKey: "position"),
                    "No fly-in: reduceMotion=\(reduceMotion) \(id)"
                )
                let shown = control.layer.presentation()?.position ?? control.layer.position
                XCTAssertEqual(shown.x, center.x, accuracy: 1, "\(id)")
                XCTAssertEqual(shown.y, center.y, accuracy: 1, "\(id)")
            }
        }
    }

    /// The buttons of a tile lifted by a long press return to its place
    /// without flying in after release: the overlay is recreated with an animated pass, and
    /// previously its frame animated from zero (the grid's top-left corner).
    func testControlsOfLiftedTileReappearInPlaceAfterRelease() throws {
        for reduceMotion in [false, true] {
            let host = TesseraTestDragHost(
                descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
            )
            host.coordinator.isReduceMotionEnabled = { reduceMotion }
            XCTAssertTrue(host.startDrag("t0"))
            XCTAssertNil(host.coordinator.editControls["t0"], "No overlay under the finger")
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
            XCTAssertTrue(seen, "The overlay is back: reduceMotion=\(reduceMotion)")
        }
    }

    // MARK: - Clipping

    /// The buttons live in a container that clips to the grid's `bounds`, just as
    /// the collection view clips tiles.
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
        XCTAssertNil(host.coordinator.editControlsHost, "The container is removed together with the buttons")
    }

    /// A tile partly under the top edge and partly under the bottom one: the tile's button
    /// extends beyond the container's `bounds` (and will be clipped), while a tile that has
    /// fully scrolled away is hidden.
    func testControlsAreClippedLikeTileAtTopAndBottomEdges() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<48).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        host.coordinator.beginEditing()
        let grid = host.host.grid
        let container = try XCTUnwrap(host.coordinator.editControlsHost)

        // Tile t0 (the top row) goes partly off the top.
        let top = try XCTUnwrap(grid.frame(forItemID: "t0"))
        grid.setContentOffset(CGPoint(x: 0, y: top.minY + top.height / 2), animated: false)
        host.host.layout()
        let partlyTop = try XCTUnwrap(grid.frame(forItemID: "t0"))
        XCTAssertLessThan(partlyTop.minY, 0)
        XCTAssertGreaterThan(partlyTop.maxY, 0)
        let topControl = try control("t0", in: host)
        XCTAssertFalse(topControl.isHidden)
        let unpinInGrid = topControl.convert(topControl.unpinButtonFrame, to: grid)
        XCTAssertLessThan(unpinInGrid.minY, 0, "The button extends past the edge — the container will clip it")
        XCTAssertEqual(container.frame, grid.bounds)
        XCTAssertTrue(container.clipsToBounds)

        // A tile cut in half by the grid's bottom edge.
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

        // Far beyond the edge — hidden.
        grid.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        host.host.layout()
        if let gone = host.coordinator.editControls[AnyHashable("t0")] {
            XCTAssertTrue(gone.isHidden, "A tile outside the visible area — its buttons are hidden")
        }
        host.coordinator.endEditing()
    }

    // MARK: - Size, touch target, contrast

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
        XCTAssertLessThanOrEqual(small, 24, "A small tile — compact buttons")

        for id in ["m", "w", "l"] {
            XCTAssertEqual(
                try control(id, in: host).unpinButtonFrame.width,
                28,
                accuracy: 0.001,
                "Tile \(id): diameter = the controlDiameter ceiling"
            )
        }
        XCTAssertEqual(
            TesseraTileEditControlView.diameter(forTileSize: CGSize(width: 10, height: 10), maxDiameter: 28),
            20
        )
        XCTAssertEqual(
            TesseraTileEditControlView.diameter(forTileSize: CGSize(width: 500, height: 500), maxDiameter: 12),
            20,
            "A ceiling below the minimum is raised to 20"
        )
        host.coordinator.endEditing()
    }

    /// The buttons sit in the corners and cover little: the center of a small tile (the icon)
    /// is free, and the overhang past the frame is at most 4 pt (D48: half the 8 pt grid gap).
    func testControlsSitAtCornersWithBoundedOverhang() throws {
        let host = TesseraTestDragHost(descriptors: [tesseraTestTile("s", size: .small)])
        host.coordinator.beginEditing()
        host.host.layout()
        let control = try control("s", in: host)
        let bounds = control.bounds
        let unpin = control.unpinButtonFrame
        let resize = control.resizeButtonFrame

        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4, "D48: overhang of 4 pt")
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

        // A point inside the touch target but outside the visible button hits the button.
        let unpin = control.unpinButtonFrame
        let nearUnpin = CGPoint(x: unpin.midX + 20, y: unpin.midY + 20)
        XCTAssertFalse(unpin.contains(nearUnpin))
        XCTAssertNotNil(control.hitTest(nearUnpin, with: nil))
        XCTAssertTrue(control.hitTest(nearUnpin, with: nil) is UIButton)

        // The tile center misses the buttons.
        let center = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
        XCTAssertNil(control.hitTest(center, with: nil))
        let container = try XCTUnwrap(host.coordinator.editControlsHost)
        XCTAssertNil(container.hitTest(container.convert(center, from: control), with: nil))
        host.coordinator.endEditing()
    }

    /// A light fill with a dark glyph — contrast on dark and light tiles
    /// in both themes; the ring is dynamic.
    func testControlColorsContrastInLightAndDarkMode() throws {
        let host = TesseraTestDragHost(descriptors: [tesseraTestTile("s", size: .small)])
        host.coordinator.beginEditing()
        let control = try control("s", in: host)
        let button = try XCTUnwrap(buttons(of: control).first)

        for style in [UIUserInterfaceStyle.light, .dark] {
            let fill = try XCTUnwrap(button.backgroundColor)
            let glyph = button.tintColor ?? .clear
            XCTAssertGreaterThan(luminance(fill, style: style), 0.85, "The fill is light (\(style.rawValue))")
            XCTAssertLessThan(luminance(glyph, style: style), 0.2, "The glyph is dark (\(style.rawValue))")
        }

        let ring = TesseraTileEditControlView.ringColor
        let lightAlpha = ring.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor.alpha
        let darkAlpha = ring.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor.alpha
        XCTAssertNotEqual(lightAlpha, darkAlpha, "The ring is a dynamic color")
        XCTAssertNotNil(button.layer.borderColor)
        host.coordinator.endEditing()
    }
}

#endif
