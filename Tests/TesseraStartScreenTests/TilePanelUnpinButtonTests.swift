//
//  TilePanelUnpinButtonTests.swift
//  TesseraStartScreenTests
//
//  The unpin button on tiles of an expanded folder panel in edit mode (D46).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, "Implementation deviations";
//  decision D46 in docs/STATE.md; reference:
//  docs/W10M-STARTSCREEN.md §6.5, §6.6, §6.9.
//
//  Tested on a real `TesseraTileStore` and a grid in a window (`TesseraTestDragHost`):
//  - every panel tile has a button only in edit mode and only when the panel
//    has settled; a folder tile has none (D38); a panel tile has no resize arrow;
//  - the size and corner are the same as for the button on a grid tile (a shared corner helper);
//  - the touch area rule: the corner quarter of the tile, no farther than the overhang beyond the frame,
//    at least 44 pt where it fits; the center and body of the tile are not a button;
//    RTL is mirrored; overlaps are resolved by the nearest center;
//  - a tap: the tile flight, `unpin`, `didUnpin`, focus; in a folder of two, a dissolution
//    (D45); Reduce Motion means no flight; a repeated tap during the flight is ignored;
//  - the buttons follow the panel (scrolling, width change), are removed when the
//    panel closes, during a drag from the panel and outside edit mode; desktop buttons are unaffected.
//
//  Exact layouts (`TileStoreCellFixture`), 4 columns; no `sleep`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePanelUnpinButtonTests: XCTestCase {

    // MARK: - Helpers

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var events: [String] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            events.append("unpin:\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didDissolveFolder folderID: AnyHashable,
            remainingTile tileID: AnyHashable
        ) {
            events.append("dissolve:\(folderID)>\(tileID)")
        }
    }

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func record(_ host: TesseraTestDragHost) -> PostRecorder {
        let recorder = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            recorder.posts.append((notification, argument))
        }
        return recorder
    }

    /// Fixture: folder F (medium, (0,0)) from `contents`, tile `a` under it and a row
    /// of tiles below (for scrolling).
    private func makeHost(
        contents: [(String, TesseraTileSize)] = [("x", .small), ("y", .small), ("z", .small)],
        rowsBelow: Int = 1
    ) throws -> TesseraTestDragHost {
        let tiles = (0..<rowsBelow).map { CellFixtureTile("a\($0)", .small, 3 + $0, 0) }
        return try TesseraTestDragHost(
            cells: tiles,
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)]
        )
    }

    /// Enters edit mode and expands the panel without animation.
    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost, folderID: AnyHashable = "F") throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        })
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    private func control(
        _ tileID: AnyHashable,
        in host: TesseraTestDragHost
    ) throws -> TesseraTileEditControlView {
        let control = try XCTUnwrap(host.coordinator.panelEditControls[tileID], "button of tile \(tileID)")
        control.layoutIfNeeded()
        return control
    }

    private func buttons(of control: TesseraTileEditControlView) -> [UIButton] {
        control.subviews.compactMap { $0 as? UIButton }
    }

    private func visibleButtons(of control: TesseraTileEditControlView) -> [UIButton] {
        buttons(of: control).filter { !$0.isHidden }
    }

    /// A tap on a visible overlay button (like a finger touch: `touchUpInside`).
    private func tap(_ control: TesseraTileEditControlView, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = visibleButtons(of: control).first else {
            return XCTFail("No visible button", file: file, line: line)
        }
        // `sendActions(for:)` without a host app (logic tests) does not call
        // targets: run the actions registered for `touchUpInside` ourselves.
        for target in button.allTargets {
            for action in button.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                _ = (target as AnyObject).perform(Selector(action))
            }
        }
    }

    /// Waits for the end of the panel transition and for the grid to apply the deferred snapshot.
    private func waitForFolderTransitionDone(_ host: TesseraTestDragHost) -> Bool {
        host.host.waitForFolderTransition() && host.waitUntil { host.gridIDs == host.storeIDs }
    }

    private func panelFrames(_ host: TesseraTestDragHost) throws -> TesseraPanelShortcutGeometry {
        try XCTUnwrap(host.host.grid.panelShortcutGeometry())
    }

    private func flyingSnapshots(_ host: TesseraTestDragHost) -> [UIView] {
        host.host.grid.subviews.filter { $0.layer.zPosition == 1000 }
    }

    // MARK: - Presence

    /// In edit mode every panel tile has an unpin button, no resize arrow;
    /// the button sits in the button container and matches the tile frame; it is removed
    /// together with leaving edit mode.
    func testEveryPanelTileHasOnlyUnpinButtonInEditMode() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try panelFrames(host)

        XCTAssertEqual(Set(host.coordinator.panelEditControls.keys), ["x", "y", "z"] as Set<AnyHashable>)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)
        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            XCTAssertTrue(control.isPanelMember)
            XCTAssertTrue(control.superview === container)
            XCTAssertEqual(control.frame.minX, geometry.frames[index].minX, accuracy: 0.5)
            XCTAssertEqual(control.frame.minY, geometry.frames[index].minY, accuracy: 0.5)
            XCTAssertEqual(control.frame.width, geometry.frames[index].width, accuracy: 0.5)
            XCTAssertEqual(visibleButtons(of: control).count, 1, "Only the unpin button")
            XCTAssertEqual(buttons(of: control).filter { $0.isHidden }.count, 1, "The resize arrow is hidden")
            XCTAssertFalse(control.isHidden)
        }

        host.coordinator.endEditing()
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        XCTAssertNil(host.coordinator.editControlsHost)
    }

    /// Outside edit mode there are no buttons on panel tiles; entering edit mode closes the panel,
    /// and after expanding in edit mode the buttons appear.
    func testNoButtonsOutsideEditMode() throws {
        let host = try makeHost()
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        host.spin(0.05)
        XCTAssertEqual(host.host.grid.expandedFolderID, "F")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Not in edit mode: no buttons")
        XCTAssertNil(host.coordinator.editControlsHost)

        host.coordinator.beginEditing()
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertTrue(host.waitUntil { host.host.grid.expandedFolderID == nil })
        XCTAssertNil(host.host.grid.expandedFolderID, "Entering edit mode closed the panel")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)

        try openPanel(host)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)
        host.coordinator.endEditing()
    }

    /// A folder tile has no unpin button (D38), only the resize arrow;
    /// a folder overlay is not a "panel tile".
    func testFolderTileHasNoUnpinButton() throws {
        let host = try makeHost()
        try openPanel(host)

        let folderControl = try XCTUnwrap(host.coordinator.editControls["F"])
        folderControl.layoutIfNeeded()
        XCTAssertFalse(folderControl.isPanelMember)
        XCTAssertEqual(visibleButtons(of: folderControl).count, 1, "A folder has only the resize arrow")
        XCTAssertNil(host.coordinator.panelEditControls["F"])
        XCTAssertFalse(host.coordinator.panelEditControls.keys.contains("F"))
        host.coordinator.endEditing()
    }

    /// The buttons are not visible to VoiceOver (like the desktop ones), while the "Unpin" action
    /// on the panel tile remains.
    func testButtonsAreHiddenFromAccessibilityAndActionRemains() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)

        XCTAssertFalse(container.isAccessibilityElement)
        for control in host.coordinator.panelEditControls.values {
            XCTAssertFalse(control.isAccessibilityElement)
            XCTAssertTrue(buttons(of: control).allSatisfy { !$0.isAccessibilityElement })
        }
        let unpinName = TesseraStartScreenStrings.string(.a11yActionUnpin)
        for cell in panel.shortcutCells {
            XCTAssertTrue((cell.accessibilityCustomActions ?? []).contains { $0.name == unpinName })
        }
        host.coordinator.endEditing()
    }

    // MARK: - Size and corner

    /// Diameter and corner follow the desktop button rules: the diameter depends on the tile size
    /// and the configuration ceiling (at least 20 pt), the center is at the frame corner, the overhang is
    /// 4 pt (D48); the button frame is the result of the shared corner helper, the same as for
    /// the button on a grid tile.
    func testButtonUsesDesktopSizeAndSharedCornerHelper() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try panelFrames(host)
        let desktop = try XCTUnwrap(host.coordinator.editControls["a0"])
        desktop.layoutIfNeeded()

        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            let tileSize = geometry.frames[index].size
            let side = TesseraTileEditControlView.diameter(
                forTileSize: tileSize,
                maxDiameter: host.coordinator.configuration.controlDiameter
            )
            let expected = TesseraTileEditControlView.unpinButtonFrame(
                inTileBounds: control.bounds,
                side: side,
                isRightToLeft: false
            )
            XCTAssertEqual(control.unpinButtonFrame, expected)
            XCTAssertGreaterThanOrEqual(control.unpinButtonFrame.width, TesseraTileEditControlView.minimumDiameter)
            // The top corner at the end of the row: right in LTR.
            XCTAssertEqual(
                control.unpinButtonFrame.maxX,
                control.bounds.maxX + TesseraTileEditControlView.cornerOverhang,
                accuracy: 0.001
            )
            XCTAssertEqual(control.unpinButtonFrame.minY, -TesseraTileEditControlView.cornerOverhang, accuracy: 0.001)
        }

        // The same corner and the same tile size (small = small): the panel button
        // frame exactly equals the button frame on a grid tile.
        let panelControl = try control("x", in: host)
        XCTAssertEqual(panelControl.bounds.size.width, desktop.bounds.size.width, accuracy: 1)
        XCTAssertEqual(panelControl.unpinButtonFrame, desktop.unpinButtonFrame)
        host.coordinator.endEditing()
    }

    /// The corner helper: top right in LTR (D29), in RTL it mirrors the button to the
    /// top left corner.
    func testSharedCornerHelperMirrorsInRightToLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        let ltr = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        let rtl = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        // D48: a 4 pt overhang (it was 6).
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        XCTAssertEqual(ltr, CGRect(x: 64, y: -4, width: 20, height: 20))
        XCTAssertEqual(rtl, CGRect(x: -4, y: -4, width: 20, height: 20))
    }

    /// D48: the tolerance of the panel tile button zone is a 4 pt overhang, but no more than the panel
    /// gap; the zone itself does not go beyond the tile frame by more than this tolerance (the button
    /// does not enter a neighbor), and the overhang is shared by the grid and the panel.
    func testPanelHitOutsetFollowsTheSharedOverhangAndSpacing() throws {
        let host = try makeHost()
        try openPanel(host)
        let geometry = try panelFrames(host)
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        let expected = min(TesseraTileEditControlView.cornerOverhang, max(0, geometry.spacing))
        XCTAssertGreaterThan(geometry.tileIDs.count, 0)
        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            XCTAssertEqual(control.panelHitOutset, expected, accuracy: 0.001, "\(id)")
            let tile = geometry.frames[index]
            let zone = control.convert(control.unpinHitFrame, to: host.host.grid)
            XCTAssertLessThanOrEqual(zone.maxX, tile.maxX + expected + 0.001, "\(id)")
            XCTAssertGreaterThanOrEqual(zone.minY, tile.minY - expected - 0.001, "\(id)")
        }
        host.coordinator.endEditing()
    }

    // MARK: - Touch area rule

    /// The pure rule (the corner is top right in LTR): the zone does not go beyond the
    /// corner quarter and the overhang, the center and body of the tile are not the zone, the button itself is
    /// the zone; on an 88 pt tile the zone is at least 28 pt.
    func testPanelHitZoneRuleLeftToRight() {
        // D48: the overhang is a shared 4 pt constant, the zone does not go beyond it.
        let overhang = TesseraTileEditControlView.cornerOverhang
        for tileSide: CGFloat in [44, 55, 88] {
            let bounds = CGRect(x: 0, y: 0, width: tileSide, height: tileSide)
            let side: CGFloat = 20
            let button = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: side, isRightToLeft: false)
            let zone = TesseraTileEditControlView.panelUnpinHitZone(
                buttonFrame: button, tileBounds: bounds, isRightToLeft: false, outset: overhang
            )

            XCTAssertTrue(zone.contains(CGPoint(x: button.midX, y: button.midY)), "the button center is in the zone, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: bounds.midX, y: bounds.midY)), "the tile center is not in the zone, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: bounds.maxX - 4, y: bounds.maxY - 4)), "the opposite corner, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: 4, y: 4)), "the top left corner, \(tileSide)")
            XCTAssertFalse(zone.contains(CGPoint(x: 4, y: bounds.maxY - 4)), "the bottom left corner, \(tileSide)")
            XCTAssertLessThanOrEqual(zone.maxX, bounds.maxX + overhang + 0.001)
            XCTAssertGreaterThanOrEqual(zone.minY, -overhang - 0.001)
            XCTAssertGreaterThan(zone.minX, bounds.midX)
            XCTAssertLessThan(zone.maxY, bounds.midY)
            XCTAssertGreaterThanOrEqual(zone.width, min(44, tileSide / 2 + overhang - 1) - 0.001)
        }
    }

    /// RTL: the quarter is on the left, the zone is a mirror of LTR.
    func testPanelHitZoneRuleRightToLeftIsMirrored() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        let ltrButton = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        let rtlButton = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: true)
        let overhang = TesseraTileEditControlView.cornerOverhang
        let ltr = TesseraTileEditControlView.panelUnpinHitZone(
            buttonFrame: ltrButton, tileBounds: bounds, isRightToLeft: false, outset: overhang
        )
        let rtl = TesseraTileEditControlView.panelUnpinHitZone(
            buttonFrame: rtlButton, tileBounds: bounds, isRightToLeft: true, outset: overhang
        )

        XCTAssertEqual(rtl.width, ltr.width, accuracy: 0.001)
        XCTAssertEqual(rtl.height, ltr.height, accuracy: 0.001)
        XCTAssertEqual(rtl.minX, bounds.width - ltr.maxX, accuracy: 0.001, "mirrored about the vertical axis")
        XCTAssertTrue(rtl.contains(CGPoint(x: rtlButton.midX, y: rtlButton.midY)))
        XCTAssertFalse(rtl.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertFalse(rtl.contains(CGPoint(x: bounds.maxX - 4, y: 4)), "the top right corner in RTL is not a button")
        XCTAssertGreaterThanOrEqual(rtl.minX, -overhang - 0.001)
        XCTAssertLessThan(rtl.maxX, bounds.midX)
    }

    /// A gap smaller than the overhang shrinks the zone: it does not enter the neighbor.
    func testPanelHitZoneNeverEntersNeighbourWhenSpacingIsSmall() {
        let bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        let button = TesseraTileEditControlView.unpinButtonFrame(inTileBounds: bounds, side: 20, isRightToLeft: false)
        for spacing: CGFloat in [0, 2, 4, 8] {
            let outset = min(TesseraTileEditControlView.cornerOverhang, spacing)
            let zone = TesseraTileEditControlView.panelUnpinHitZone(
                buttonFrame: button, tileBounds: bounds, isRightToLeft: false, outset: outset
            )
            XCTAssertLessThanOrEqual(zone.maxX, bounds.maxX + spacing + 0.001, "spacing=\(spacing)")
            XCTAssertGreaterThanOrEqual(zone.minY, -spacing - 0.001, "spacing=\(spacing)")
        }
    }

    /// Integration with a real panel (the button is in the top right corner
    /// of the tile): the tile center misses the buttons (a tap and long press go to the tile), the button
    /// corner is the button, the gap to the right of "x" at the height of its button is the "x" button
    /// (within the overhang), not the neighbor's; the top left corner of the tile is its body.
    func testHitRuleInPanelBodyCornerAndNeighbourOverlap() throws {
        let host = try makeHost()
        try openPanel(host)
        let container = try XCTUnwrap(host.coordinator.editControlsHost)
        let geometry = try panelFrames(host)
        let x = geometry.frames[0]
        let y = geometry.frames[1]

        // The tile center: the touch misses the buttons.
        XCTAssertNil(container.hitTest(CGPoint(x: x.midX, y: x.midY), with: nil))
        XCTAssertNil(container.hitTest(CGPoint(x: y.midX, y: y.midY), with: nil))
        // The tile body far from the button.
        XCTAssertNil(container.hitTest(CGPoint(x: x.maxX - 4, y: x.maxY - 4), with: nil))
        // The top left corner of "y" (at the border with "x"): the body of "y", not the "x" button.
        XCTAssertNil(container.hitTest(CGPoint(x: y.minX + 3, y: y.minY + 3), with: nil))

        // The button corner: a hit on the button of the right tile.
        let xButton = try control("x", in: host).unpinButtonFrame
        let xPoint = CGPoint(x: x.minX + xButton.midX, y: x.minY + xButton.midY)
        let xHit = container.hitTest(xPoint, with: nil)
        XCTAssertTrue(xHit is UIButton)
        XCTAssertTrue(xHit?.superview === host.coordinator.panelEditControls["x"])

        // The gap to the right of "x" at the height of its button is the "x" button (within
        // the overhang), not "y" and not empty space; beyond the overhang it misses.
        let gapPoint = CGPoint(x: x.maxX + 3, y: x.minY + xButton.midY)
        let gapHit = container.hitTest(gapPoint, with: nil)
        XCTAssertTrue(gapHit is UIButton)
        XCTAssertTrue(gapHit?.superview === host.coordinator.panelEditControls["x"])
        XCTAssertNil(container.hitTest(CGPoint(x: x.maxX + 8, y: x.minY + xButton.midY), with: nil), "beyond the overhang: not a button")

        // Above the first row of tiles it is not a button beyond the overhang.
        XCTAssertNil(container.hitTest(CGPoint(x: x.midX, y: x.minY - 12), with: nil))
        host.coordinator.endEditing()
    }

    /// RTL: the button is in the top left corner of the tile, the zone is the left quarter.
    func testHitRuleMirrorsForRightToLeftControl() throws {
        let host = try makeHost()
        try openPanel(host)
        let control = try control("x", in: host)
        control.semanticContentAttribute = .forceRightToLeft
        control.setNeedsLayout()
        control.layoutIfNeeded()
        let bounds = control.bounds

        XCTAssertEqual(control.unpinButtonFrame.minX, -TesseraTileEditControlView.cornerOverhang, accuracy: 0.001)
        XCTAssertNotNil(control.hitTest(CGPoint(x: 6, y: 6), with: nil), "the top left corner is a button")
        XCTAssertNil(control.hitTest(CGPoint(x: bounds.maxX - 6, y: 6), with: nil), "the top right corner is the tile body")
        XCTAssertNil(control.hitTest(CGPoint(x: bounds.midX, y: bounds.midY), with: nil))
        host.coordinator.endEditing()
    }

    /// An overlap of a panel tile overlay's zone with another button is resolved by the nearest button
    /// center (not by subview order); the same rule applies to all overlays
    /// (the resize arrow of the upper tile and the unpin of the lower one are in the same column).
    func testOverlappingZonesResolveByNearestButtonCenter() {
        let container = TesseraTileEditControlsHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let desktop = TesseraTileEditControlView(diameter: 20)
        desktop.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        desktop.tileSize = desktop.frame.size
        let panel = TesseraTileEditControlView(diameter: 20)
        panel.isPanelMember = true
        panel.configure(canUnpin: true, canResize: false)
        panel.frame = CGRect(x: 10, y: 10, width: 60, height: 60)
        panel.tileSize = panel.frame.size
        container.addSubview(desktop)
        container.addSubview(panel)   // topmost in subview order
        desktop.layoutIfNeeded()
        panel.layoutIfNeeded()

        // The buttons are in the top right corners: the grid tile button center is (54, 6),
        // the panel button center is (64, 16); the zones intersect in the area where both zones are
        // wider than 44 pt around their centers (a 4 pt overhang, D48).
        let nearDesktop = CGPoint(x: 50, y: 5)
        XCTAssertTrue(container.hitTest(nearDesktop, with: nil)?.superview === desktop)
        // Closer to the panel button, although the grid tile zone also covers the point.
        let nearPanel = CGPoint(x: 70, y: 20)
        XCTAssertNotNil(desktop.hitTest(container.convert(nearPanel, to: desktop), with: nil))
        XCTAssertTrue(container.hitTest(nearPanel, with: nil)?.superview === panel)
    }

    // MARK: - Tap on the button

    /// A folder of three: a tap on the button is a tile flight, then `unpin`, `didUnpin`;
    /// the panel stays, focus goes to the next tile; the button left together with the tile.
    func testTapUnpinsMiddleTileOfThreeTileFolderWithFlyOut() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host)
        let yControl = try control("y", in: host)

        tap(yControl)
        // The tile is flying: the model is not changed yet, the drag image is visible, the button is removed.
        XCTAssertTrue(host.store.isPinned("y"))
        XCTAssertEqual(flyingSnapshots(host).count, 1, "The tile snapshot is flying")
        XCTAssertNil(host.coordinator.panelEditControls["y"])
        XCTAssertEqual(host.folders.first?.tiles.count, 3)

        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        XCTAssertFalse(host.store.isPinned("y"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "z"] as [AnyHashable])
        XCTAssertEqual(host.host.grid.expandedFolderID, "F", "The panel stayed")
        XCTAssertEqual(recorder.events, ["unpin:y"])
        XCTAssertTrue(flyingSnapshots(host).isEmpty)

        let panel = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertEqual(panel.shortcutCells.count, 2)
        XCTAssertTrue((posts.posts.last?.1 as? UIView) === panel.shortcutCells[1], "focus goes to the next \"z\"")
        XCTAssertTrue(host.waitUntil { Set(host.coordinator.panelEditControls.keys) == ["x", "z"] })
        XCTAssertTrue(panel.shortcutCells.allSatisfy { $0.alpha == 1 }, "The cells are visible")
        host.coordinator.endEditing()
    }

    /// The last panel tile: focus goes to the previous one.
    func testTapUnpinsLastTileFocusesPrevious() throws {
        let host = try makeHost()
        let posts = record(host)
        try openPanel(host)

        tap(try control("z", in: host))
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })

        let panel = try XCTUnwrap(host.host.panelCell(folderID: "F"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "y"] as [AnyHashable])
        XCTAssertTrue((posts.posts.last?.1 as? UIView) === panel.shortcutCells[1], "focus goes to the previous \"y\"")
        host.coordinator.endEditing()
    }

    /// A folder of two: a tap on the button is a dissolution (D45): the panel closes, the remaining
    /// tile is on the folder's cell with its own size, `didUnpin`, then
    /// `didDissolveFolder`, focus goes to it, there are no panel buttons.
    func testTapInTwoTileFolderDissolvesFolderAndFocusesRemainingTile() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .medium)])
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host)
        let folderCell = try XCTUnwrap(host.store.placement(of: "F"))

        tap(try control("x", in: host))
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty }, "focus was posted")
        XCTAssertTrue(waitForFolderTransitionDone(host))

        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed")
        XCTAssertTrue(host.folders.isEmpty)
        XCTAssertEqual(host.store.placement(of: "y"), folderCell)
        XCTAssertEqual(host.store.snapshot().item(withID: "y")?.size, .medium)
        XCTAssertEqual(recorder.events, ["unpin:x", "dissolve:F>y"])
        XCTAssertTrue((posts.posts.last?.1 as? UIView) === host.host.cell("y"))
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        XCTAssertNotNil(host.coordinator.editControls["y"], "The remaining tile is on the grid with desktop buttons")
        host.coordinator.endEditing()
    }

    /// Reduce Motion: no flight, the mutation is immediate; in a folder of two the panel closes
    /// instantly.
    func testTapWithReduceMotionIsInstant() throws {
        let host = try makeHost()
        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        try openPanel(host)

        tap(try control("y", in: host))
        XCTAssertFalse(host.store.isPinned("y"), "Immediate mutation")
        XCTAssertTrue(flyingSnapshots(host).isEmpty, "No flight")
        XCTAssertEqual(recorder.events, ["unpin:y"])
        XCTAssertEqual(host.host.grid.expandedFolderID, "F")

        // Two remain: the second tap dissolves the folder, the panel is closed immediately.
        host.host.layout()
        XCTAssertTrue(host.waitUntil { host.coordinator.panelEditControls["x"] != nil })
        tap(try control("x", in: host))
        XCTAssertNil(host.host.grid.expandedFolderID, "The panel is closed immediately")
        XCTAssertEqual(recorder.events, ["unpin:y", "unpin:x", "dissolve:F>z"])
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        host.coordinator.endEditing()
    }

    /// A repeated tap on the button while the tile is flying, and a tap on a neighboring button in the meantime,
    /// produce neither a second mutation nor a second callback.
    func testSecondTapWhileFlyingIsIgnored() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let posts = record(host)
        try openPanel(host)
        let yControl = try control("y", in: host)
        let zControl = try control("z", in: host)

        tap(yControl)
        tap(yControl)
        tap(zControl)
        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        host.spin(0.1)

        XCTAssertEqual(recorder.events, ["unpin:y"])
        XCTAssertTrue(host.store.isPinned("z"))
        XCTAssertEqual(host.folders.first?.tiles.map { $0.id }, ["x", "z"] as [AnyHashable])
        host.coordinator.endEditing()
    }

    /// The panel was closed while the tile was flying: no mutation, the tile is visible, no callback.
    func testClosingPanelDuringFlightCancelsUnpin() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)
        let yCell = panel.shortcutCells[1]

        tap(try control("y", in: host))
        XCTAssertEqual(flyingSnapshots(host).count, 1)
        host.host.grid.closeFolder(animated: false)
        XCTAssertTrue(host.waitUntil { self.flyingSnapshots(host).isEmpty })
        host.spin(0.05)

        XCTAssertTrue(host.store.isPinned("y"), "The tile is not unpinned")
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(yCell.alpha, 1, "The cell is restored")
        host.coordinator.endEditing()
    }

    /// The public `unpin(_:)` (including the VoiceOver action) is still immediate,
    /// without a flight: the animation is only for a tap on the button.
    func testPublicUnpinOfPanelTileStaysImmediate() throws {
        let host = try makeHost()
        try openPanel(host)

        host.coordinator.unpin("y")
        XCTAssertFalse(host.store.isPinned("y"))
        XCTAssertTrue(flyingSnapshots(host).isEmpty)
        host.coordinator.endEditing()
    }

    // MARK: - Lifecycle

    /// The buttons appear when the panel has settled and are removed when it closes.
    func testButtonsFollowPanelOpenAndCloseTransitions() throws {
        let host = try makeHost()
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: true)
        XCTAssertTrue(host.host.grid.isFolderChangeAnimating)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "While the panel is opening there are no buttons")
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3, "The panel has settled: the buttons are there")

        host.host.grid.closeFolder(animated: true)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "Closing started: the buttons are removed")
        XCTAssertTrue(host.host.waitForFolderTransition())
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)

        host.host.grid.openFolder(folder, animated: false)
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)
        host.host.grid.closeFolder(animated: false)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        host.coordinator.endEditing()
    }

    /// New buttons of an expanded panel fade in smoothly, immediately under Reduce Motion.
    func testButtonsFadeInOnOpenAndAppearInstantlyWithReduceMotion() throws {
        let host = try makeHost()
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first)

        host.host.grid.openFolder(folder, animated: false)
        let control = try XCTUnwrap(host.coordinator.panelEditControls["x"])
        XCTAssertNotNil(control.layer.animation(forKey: "opacity"), "The appearance is animated")
        host.host.grid.closeFolder(animated: false)

        host.host.grid.isReduceMotionEnabled = { true }
        host.coordinator.isReduceMotionEnabled = { true }
        host.host.grid.openFolder(folder, animated: false)
        let instant = try XCTUnwrap(host.coordinator.panelEditControls["x"])
        XCTAssertEqual(instant.alpha, 1)
        XCTAssertNil(instant.layer.animation(forKey: "opacity"))
        host.coordinator.endEditing()
    }

    /// Dragging a tile from the panel: there are no buttons on the tiles during the drag; a long
    /// press on the body of a tile with buttons starts a drag. First this is
    /// a reorder inside the panel (the panel is open, the buttons return after
    /// cancellation); the finger leaving the panel takes the tile out (the panel is closed, no buttons).
    func testDragOutStillWorksAndRemovesPanelButtons() throws {
        let host = try makeHost()
        try openPanel(host)
        let panelItem = try XCTUnwrap(host.host.grid.displayItems.first { $0.isFolderPanel })
        let geometry = try panelFrames(host)
        let y = geometry.frames[1]
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)

        host.coordinator.handleLongPress(on: panelItem, at: CGPoint(x: y.midX, y: y.midY))
        XCTAssertTrue(host.coordinator.isDragging, "A long press on the tile body lifts it")
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty, "During the drag there are no buttons on panel tiles")
        XCTAssertNotNil(host.host.grid.expandedFolderID, "Reorder: the panel stays open")

        // Leaving the panel is a take-out: the panel closes immediately.
        host.coordinator.updateDrag(to: CGPoint(x: y.midX, y: geometry.panelFrame.maxY + 60))
        XCTAssertNil(host.host.grid.expandedFolderID)
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)

        host.coordinator.finishDrag(commit: false)
        XCTAssertTrue(host.waitUntil { host.coordinator.dragSession == nil })
        XCTAssertTrue(host.coordinator.panelEditControls.isEmpty)
        host.coordinator.endEditing()
    }

    // MARK: - Following the panel

    /// Scrolling moves the buttons together with the tiles; a tile that went off the edge has a hidden button.
    func testButtonsFollowPanelOnScroll() throws {
        let host = try makeHost(rowsBelow: 14)
        try openPanel(host)
        let grid = host.host.grid
        XCTAssertGreaterThan(grid.contentSize.height, grid.bounds.height + 100)

        let before = try panelFrames(host)
        grid.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        host.host.layout()
        let after = try panelFrames(host)
        XCTAssertEqual(after.frames[0].minY, before.frames[0].minY - 40, accuracy: 0.5)
        for (index, id) in after.tileIDs.enumerated() {
            let control = try XCTUnwrap(host.coordinator.panelEditControls[id])
            XCTAssertEqual(control.frame.minY, after.frames[index].minY, accuracy: 0.5, "\(id)")
            XCTAssertEqual(control.frame.minX, after.frames[index].minX, accuracy: 0.5, "\(id)")
        }

        // Scrolled so that the panel went off the top: the buttons are hidden.
        grid.setContentOffset(CGPoint(x: 0, y: after.frames[0].maxY + 400), animated: false)
        host.host.layout()
        host.spin(0.05)
        for control in host.coordinator.panelEditControls.values {
            XCTAssertTrue(control.isHidden)
        }
        host.coordinator.endEditing()
    }

    /// A grid width change (rotation) and `refreshEditControls()`: the buttons take
    /// the new tile frames; the panel's column count does not change the set of buttons.
    func testButtonsRelayoutAfterWidthChange() throws {
        let host = try makeHost()
        try openPanel(host)
        let grid = host.host.grid
        let oldWidth = try panelFrames(host).frames[0].width

        grid.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
        host.host.layout()
        host.coordinator.refreshEditControls()
        host.host.layout()

        let geometry = try panelFrames(host)
        XCTAssertNotEqual(geometry.frames[0].width, oldWidth, "The tiles were rebuilt")
        XCTAssertEqual(host.coordinator.panelEditControls.count, 3)
        for (index, id) in geometry.tileIDs.enumerated() {
            let control = try control(id, in: host)
            XCTAssertEqual(control.frame.minX, geometry.frames[index].minX, accuracy: 0.5)
            XCTAssertEqual(control.frame.minY, geometry.frames[index].minY, accuracy: 0.5)
            XCTAssertEqual(control.frame.width, geometry.frames[index].width, accuracy: 0.5)
            XCTAssertEqual(
                control.unpinButtonFrame.maxX,
                control.bounds.maxX + TesseraTileEditControlView.cornerOverhang,
                accuracy: 0.001
            )
        }
        host.coordinator.endEditing()
    }

    // MARK: - Desktop unaffected

    /// Desktop buttons: not "panel tiles", the touch area is not trimmed (at
    /// least 44 pt, overhanging neighbor bodies as before), both buttons in place.
    func testDesktopControlsAreUnaffected() throws {
        let host = try makeHost()
        try openPanel(host)
        let desktop = try XCTUnwrap(host.coordinator.editControls["a0"])
        desktop.layoutIfNeeded()

        XCTAssertFalse(desktop.isPanelMember)
        XCTAssertEqual(visibleButtons(of: desktop).count, 2, "Pin and arrow")
        XCTAssertGreaterThanOrEqual(desktop.unpinHitFrame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(desktop.unpinHitFrame.height, 44 - 0.001)
        XCTAssertGreaterThan(
            desktop.unpinHitFrame.maxX, desktop.bounds.maxX + TesseraTileEditControlView.cornerOverhang,
            "The grid tile zone is not trimmed by the overhang (as before, 44 pt around the button)"
        )
        XCTAssertNotNil(desktop.hitTest(CGPoint(x: desktop.unpinHitFrame.maxX - 1, y: desktop.unpinHitFrame.maxY - 1), with: nil))
        host.coordinator.endEditing()
    }
}

#endif
