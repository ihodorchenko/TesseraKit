//
//  TileEditButtonGapTapTests.swift
//  TesseraStartScreenTests
//
//  A tap on the protruding part of an edit button: the "unpin" and
//  "resize" buttons on a grid tile protrude beyond the tile frame (`cornerOverhang`, 4 pt after D48; it was 6 pt),
//  that is, into the gap between tiles. A tap on that part used to trigger both the
//  button (unpin/resize) and the "tap on background" gesture (the gap is not a tile):
//  edit mode ended unexpectedly. Now the background gesture does not accept touches
//  that land in the touch area of any edit overlay, using the same
//  `hitTest` as the buttons themselves. Design document:
//  docs/STARTSCREEN-IOS-DESIGN.md, "Implementation deviations".
//
//  Touch simulation: the window's real `hitTest` determines the view under the finger,
//  the background gesture gets a `UITouch` with that view and point (`shouldReceive`), then
//  the `touchUpInside` button actions run and (if the gesture accepted the touch)
//  the background gesture action. No `sleep`: waiting is done by spinning the run loop.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditButtonGapTapTests: XCTestCase {

    // MARK: - Helpers

    /// A touch with the given view and point (`UITouch` has no public initializer
    /// with parameters, so a subclass overrides the needed getters).
    private final class TouchStub: UITouch {
        private let stubWindow: UIWindow
        private let windowPoint: CGPoint
        private let stubView: UIView?

        init(window: UIWindow, point: CGPoint, view: UIView?) {
            stubWindow = window
            windowPoint = point
            stubView = view
            super.init()
        }

        override var view: UIView? { stubView }
        override var window: UIWindow? { stubWindow }

        override func location(in view: UIView?) -> CGPoint {
            guard let view else { return windowPoint }
            return view.convert(windowPoint, from: stubWindow)
        }
    }

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var events: [String] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            events.append("unpin:\(tileID)")
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didResize tileID: AnyHashable,
            to size: TesseraTileSize
        ) {
            events.append("resize:\(tileID)")
        }
    }

    /// Touch result.
    private struct Outcome {
        /// The view under the finger according to the window's real `hitTest`.
        let hit: UIView?
        /// Whether the "tap on background" gesture accepted the touch.
        let backgroundReceived: Bool
    }

    /// Fixture: four medium tiles (2 × 2 with 4 columns), edit mode on.
    private func makeHost(rightToLeft: Bool = false) throws -> (TesseraTestDragHost, Recorder) {
        let host = TesseraTestDragHost(
            descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        if rightToLeft {
            host.host.grid.semanticContentAttribute = .forceRightToLeft
            host.host.collectionView?.semanticContentAttribute = .forceRightToLeft
            host.host.layout()
        }
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        host.spin(0.03)
        if rightToLeft {
            for control in host.coordinator.editControls.values {
                control.semanticContentAttribute = .forceRightToLeft
                control.setNeedsLayout()
                control.layoutIfNeeded()
            }
        }
        XCTAssertTrue(host.coordinator.isEditing)
        return (host, recorder)
    }

    private func control(
        _ id: AnyHashable,
        in host: TesseraTestDragHost
    ) throws -> TesseraTileEditControlView {
        let control = try XCTUnwrap(host.coordinator.editControls[id], "overlay \(id)")
        control.layoutIfNeeded()
        return control
    }

    /// A frame in grid coordinates (the button container matches the grid `bounds`).
    private func gridFrame(_ rect: CGRect, of control: TesseraTileEditControlView, in host: TesseraTestDragHost) -> CGRect {
        control.convert(rect, to: host.host.grid)
    }

    /// Runs a touch at a grid point: the background gesture decision, the action of the button
    /// under the finger, then the background gesture action if it accepted the touch.
    @discardableResult
    private func tap(_ point: CGPoint, in host: TesseraTestDragHost) -> Outcome {
        let outcome = touchDown(at: point, in: host)
        // Release: the button (`touchUpInside`) and the background gesture.
        if let button = outcome.hit as? UIButton {
            for target in button.allTargets {
                for action in button.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                    _ = (target as AnyObject).perform(Selector(action))
                }
            }
        }
        if outcome.backgroundReceived {
            host.coordinator.performBackgroundTap(at: point)
        }
        return outcome
    }

    /// Only the decision whether to accept the touch (no actions).
    private func touchDown(at point: CGPoint, in host: TesseraTestDragHost) -> Outcome {
        let window = host.host.window
        let windowPoint = host.host.grid.convert(point, to: window)
        let hit = window.hitTest(windowPoint, with: nil)
        let touch = TouchStub(window: window, point: windowPoint, view: hit)
        let recognizer = host.coordinator.backgroundTapGestureRecognizer
        let received = recognizer.isEnabled
            && host.coordinator.gestureRecognizer(recognizer, shouldReceive: touch)
        return Outcome(hit: hit, backgroundReceived: received)
    }

    /// A point inside the visible button, **outside the tile frame** and in the gap (there is
    /// no tile under it), closest to the button center: the "protruding part".
    private func overhangPointIfAny(
        button: CGRect,
        tile: CGRect,
        in host: TesseraTestDragHost
    ) -> CGPoint? {
        var best: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var x = button.minX + 0.5
        while x < button.maxX {
            var y = button.minY + 0.5
            while y < button.maxY {
                let point = CGPoint(x: x, y: y)
                if !tile.contains(point), host.host.grid.item(at: point) == nil {
                    let distance = hypot(x - button.midX, y - button.midY)
                    if distance < bestDistance {
                        best = point
                        bestDistance = distance
                    }
                }
                y += 1
            }
            x += 1
        }
        return best
    }

    private func overhangPoint(
        button: CGRect,
        tile: CGRect,
        in host: TesseraTestDragHost
    ) throws -> CGPoint {
        try XCTUnwrap(
            overhangPointIfAny(button: button, tile: tile, in: host),
            "the button has no part in the gap"
        )
    }

    /// How many delegate events have the prefix.
    private func waitForEvent(_ event: String, _ recorder: Recorder, _ host: TesseraTestDragHost) -> Bool {
        host.waitUntil { recorder.events.contains(event) }
    }

    // MARK: - Reproducing the bug: the unpin button

    /// A tap on the part of the unpin button protruding into the gap: the tile is unpinned and
    /// edit mode **stays on** (it used to end immediately).
    func testTapOnUnpinOverhangInGapUnpinsAndKeepsEditing() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t3"
        let control = try control(id, in: host)
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: id))
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let point = try overhangPoint(button: button, tile: tile, in: host)

        XCTAssertNil(host.host.grid.item(at: point), "the point is in the gap, not on a tile")
        XCTAssertFalse(tile.contains(point))
        let outcome = touchDown(at: point, in: host)
        XCTAssertTrue(outcome.hit is UIButton, "a button is under the finger")
        XCTAssertFalse(outcome.backgroundReceived, "the background gesture does not accept a touch on a button")

        tap(point, in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host), "the button fired")
        XCTAssertTrue(host.coordinator.isEditing, "edit mode did not end")
    }

    /// The same for the resize button: the size changes, edit mode stays on.
    func testTapOnResizeOverhangInGapResizesAndKeepsEditing() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t0"
        let control = try control(id, in: host)
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: id))
        let button = gridFrame(control.resizeButtonFrame, of: control, in: host)
        let point = try overhangPoint(button: button, tile: tile, in: host)

        XCTAssertNil(host.host.grid.item(at: point))
        let outcome = touchDown(at: point, in: host)
        XCTAssertTrue(outcome.hit is UIButton)
        XCTAssertFalse(outcome.backgroundReceived)

        tap(point, in: host)
        XCTAssertTrue(recorder.events.contains("resize:t0"), "the button fired")
        XCTAssertTrue(host.coordinator.isEditing, "edit mode did not end")
    }

    /// D48: a 4 pt overhang. The extreme point of the protruding part of the button (3.5 pt
    /// to the right of the tile frame, at the button's vertical center) is still protected:
    /// a tap on it unpins the tile and does not leave edit mode; both the unpin button and
    /// the resize arrow overhang by exactly 4 pt.
    func testExtremeOverhangPointIsProtectedWithFourPointOverhang() throws {
        XCTAssertEqual(TesseraTileEditControlView.cornerOverhang, 4)
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t3"
        let control = try control(id, in: host)
        let tile = try XCTUnwrap(host.host.grid.frame(forItemID: id))
        let unpin = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let resize = gridFrame(control.resizeButtonFrame, of: control, in: host)
        XCTAssertEqual(unpin.maxX - tile.maxX, 4, accuracy: 0.01)
        XCTAssertEqual(tile.minY - unpin.minY, 4, accuracy: 0.01)
        XCTAssertEqual(resize.maxX - tile.maxX, 4, accuracy: 0.01)
        XCTAssertEqual(resize.maxY - tile.maxY, 4, accuracy: 0.01)

        for button in [unpin, resize] {
            let point = CGPoint(x: tile.maxX + 3.5, y: button.midY)
            XCTAssertNil(host.host.grid.item(at: point), "the point is in the gap")
            let outcome = touchDown(at: point, in: host)
            XCTAssertTrue(outcome.hit is UIButton, "the extreme point of the overhang is a button")
            XCTAssertFalse(outcome.backgroundReceived)
        }
        tap(CGPoint(x: tile.maxX + 3.5, y: unpin.midY), in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing, "edit mode did not end")
    }

    // MARK: - Extended touch area (44 pt)

    /// Points of the touch area outside the visible button (extended to 44 pt) behave
    /// like the button itself: the touch goes to the button, the background gesture does not accept it,
    /// both in the gap to the right and above the top row tile.
    func testExtendedHitZoneBehavesLikeTheButton() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t3"
        let control = try control(id, in: host)
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let hit = gridFrame(control.unpinHitFrame, of: control, in: host)
        XCTAssertGreaterThan(hit.width, button.width, "the area is wider than the button")

        // To the right of the button (unpin is in the top corner at the end of the row):
        // in the gap between tiles or in the grid inset (deeper than the gap is another tile).
        let left = CGPoint(x: button.maxX + 1, y: button.midY)
        XCTAssertTrue(hit.contains(left))
        XCTAssertFalse(button.contains(left))
        XCTAssertNil(host.host.grid.item(at: left), "the point is in the gap")
        let outcome = touchDown(at: left, in: host)
        XCTAssertTrue(outcome.hit is UIButton)
        XCTAssertFalse(outcome.backgroundReceived)

        tap(left, in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing)
    }

    /// The extended area above the top edge of a first-row tile (the grid inset):
    /// the touch belongs to the button too, not to the background.
    func testExtendedHitZoneAboveTopRowDoesNotExitEditing() throws {
        let (host, recorder) = try makeHost()
        let id: AnyHashable = "t0"
        let control = try control(id, in: host)
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let hit = gridFrame(control.unpinHitFrame, of: control, in: host)
        let above = CGPoint(x: button.midX, y: button.minY - 1)
        try XCTSkipUnless(above.y > 0 && hit.contains(above), "the button is pressed against the grid edge")
        XCTAssertFalse(button.contains(above))
        XCTAssertNil(host.host.grid.item(at: above))

        let outcome = touchDown(at: above, in: host)
        XCTAssertTrue(outcome.hit is UIButton)
        XCTAssertFalse(outcome.backgroundReceived)
        tap(above, in: host)
        XCTAssertTrue(waitForEvent("unpin:t0", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing)
    }

    // MARK: - Empty space and the tile body: unchanged

    /// A tap in a gap outside all button areas still leaves edit mode.
    func testTapInPureGapStillExitsEditing() throws {
        let (host, recorder) = try makeHost()
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let t1 = try XCTUnwrap(host.host.grid.frame(forItemID: "t1"))
        // The middle of the vertical gap between t0 and t1: far from the tile corners.
        let point = CGPoint(x: (t0.maxX + t1.minX) / 2, y: t0.midY)
        XCTAssertNil(host.host.grid.item(at: point))

        let outcome = touchDown(at: point, in: host)
        XCTAssertNil(outcome.hit as? UIButton)
        XCTAssertTrue(outcome.backgroundReceived, "empty space accepts the background gesture")

        tap(point, in: host)
        XCTAssertFalse(host.coordinator.isEditing, "a tap on empty space leaves edit mode")
        XCTAssertTrue(recorder.events.isEmpty, "no buttons fired")
    }

    /// A tap on the body of any tile (including a "dimmed" one) does not end edit
    /// mode, as before; the background gesture accepts the touch (the grid decides).
    func testTapOnTileBodyKeepsEditingAsBefore() throws {
        let (host, recorder) = try makeHost()
        for id in ["t0", "t1", "t2", "t3"] {
            let center = try XCTUnwrap(host.point(AnyHashable(id)))
            let outcome = touchDown(at: center, in: host)
            XCTAssertNil(outcome.hit as? UIButton, id)
            XCTAssertTrue(outcome.backgroundReceived, "body of tile \(id): the grid decides, as before")
            tap(center, in: host)
            XCTAssertTrue(host.coordinator.isEditing, "\(id)")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - Adjacent tiles: overlapping areas

    /// At the gap intersection the areas of three buttons of different tiles meet (the resize arrow
    /// of t0 and the unpin of t1 and t2, t3): the touch goes to one of them
    /// (as before, by subview order), and edit mode stays on.
    func testOverlappingZonesOfNeighbouringTilesKeepEditing() throws {
        let (host, recorder) = try makeHost()
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        // The gap intersection between four tiles.
        let point = CGPoint(x: (t0.maxX + t3.minX) / 2, y: (t0.maxY + t3.minY) / 2)
        XCTAssertNil(host.host.grid.item(at: point))

        let outcome = touchDown(at: point, in: host)
        XCTAssertTrue(outcome.hit is UIButton, "at the intersection there is a button of one of the tiles")
        XCTAssertFalse(outcome.backgroundReceived)

        tap(point, in: host)
        XCTAssertTrue(host.coordinator.isEditing)
        // Exactly one button fired (resize t0 synchronously or unpin t3 after the flight).
        host.spin(0.4)
        XCTAssertEqual(recorder.events.count, 1, "\(recorder.events)")
        XCTAssertTrue(host.coordinator.isEditing)
    }

    // MARK: - Single source of truth: button areas and the background gesture

    /// Across the whole grid: the background gesture accepts a touch if and only if
    /// there is no edit overlay button under it (`hitTest` of the window <-> `shouldReceive`).
    func testBackgroundRecognizerAgreesWithButtonHitTestAcrossGrid() throws {
        let (host, _) = try makeHost()
        let grid = host.host.grid
        var sawButton = false
        var sawBackground = false
        var y: CGFloat = 1
        while y < grid.bounds.height {
            var x: CGFloat = 1
            while x < grid.bounds.width {
                let outcome = touchDown(at: CGPoint(x: x, y: y), in: host)
                let isButton = outcome.hit is UIButton
                XCTAssertEqual(outcome.backgroundReceived, !isButton, "(\(x), \(y))")
                sawButton = sawButton || isButton
                sawBackground = sawBackground || outcome.backgroundReceived
                x += 3
            }
            y += 3
        }
        XCTAssertTrue(sawButton && sawBackground)
    }

    // MARK: - RTL

    /// RTL: the buttons are mirrored (both at the start of the physical left edge:
    /// unpin at the top left, resize at the bottom left); a touch on the protruding
    /// part of each does not leave edit mode.
    func testRightToLeftOverhangsKeepEditing() throws {
        let (host, recorder) = try makeHost(rightToLeft: true)

        // Unpin of t3: the mirrored corner is the top left.
        let t3Control = try control("t3", in: host)
        let t3 = try XCTUnwrap(host.host.grid.frame(forItemID: "t3"))
        let unpinButton = gridFrame(t3Control.unpinButtonFrame, of: t3Control, in: host)
        XCTAssertLessThan(unpinButton.midX, t3.midX, "RTL: the unpin button is on the left")
        let unpinPoint = try overhangPoint(button: unpinButton, tile: t3, in: host)
        let unpinOutcome = touchDown(at: unpinPoint, in: host)
        XCTAssertTrue(unpinOutcome.hit is UIButton)
        XCTAssertFalse(unpinOutcome.backgroundReceived)
        tap(unpinPoint, in: host)
        XCTAssertTrue(waitForEvent("unpin:t3", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing)

        // Resize of t0: the mirrored corner is the bottom left.
        let t0Control = try control("t0", in: host)
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let resizeButton = gridFrame(t0Control.resizeButtonFrame, of: t0Control, in: host)
        XCTAssertLessThan(resizeButton.midX, t0.midX, "RTL: the resize arrow is on the left")
        let resizePoint = try overhangPoint(button: resizeButton, tile: t0, in: host)
        let resizeOutcome = touchDown(at: resizePoint, in: host)
        XCTAssertTrue(resizeOutcome.hit is UIButton)
        XCTAssertFalse(resizeOutcome.backgroundReceived)
        tap(resizePoint, in: host)
        XCTAssertTrue(recorder.events.contains("resize:t0"))
        XCTAssertTrue(host.coordinator.isEditing)
    }

    /// RTL: empty space still leaves edit mode.
    func testRightToLeftPureGapStillExitsEditing() throws {
        let (host, _) = try makeHost(rightToLeft: true)
        let t0 = try XCTUnwrap(host.host.grid.frame(forItemID: "t0"))
        let t1 = try XCTUnwrap(host.host.grid.frame(forItemID: "t1"))
        let left = min(t0.maxX, t1.maxX)
        let right = max(t0.minX, t1.minX)
        let point = CGPoint(x: (left + right) / 2, y: t0.midY)
        XCTAssertNil(host.host.grid.item(at: point))
        XCTAssertTrue(touchDown(at: point, in: host).backgroundReceived)
        tap(point, in: host)
        XCTAssertFalse(host.coordinator.isEditing)
    }

    // MARK: - Folder panel buttons

    private func makePanelHost() throws -> (TesseraTestDragHost, Recorder) {
        let host = try TesseraTestDragHost(
            cells: [CellFixtureTile("a0", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])]
        )
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertTrue(host.waitUntil { host.coordinator.panelEditControls.count == 3 })
        for control in host.coordinator.panelEditControls.values { control.layoutIfNeeded() }
        return (host, recorder)
    }

    /// The panel buttons are unaffected: a tap on the button (center and protruding part)
    /// unpins the tile and edit mode stays on; the background gesture does not accept such a touch.
    func testPanelButtonTapKeepsEditing() throws {
        let (host, recorder) = try makePanelHost()
        let geometry = try XCTUnwrap(host.host.grid.panelShortcutGeometry())
        let tileID = geometry.tileIDs[0]
        let control = try XCTUnwrap(host.coordinator.panelEditControls[tileID])
        let tile = geometry.frames[0]
        let button = gridFrame(control.unpinButtonFrame, of: control, in: host)
        let center = CGPoint(x: button.midX, y: button.midY)
        // A panel tile button may have no part in the gap (right corner).
        let overhang = overhangPointIfAny(button: button, tile: tile, in: host)

        for point in [center, overhang].compactMap({ $0 }) {
            let outcome = touchDown(at: point, in: host)
            XCTAssertTrue(outcome.hit is UIButton, "(\(point.x), \(point.y))")
            XCTAssertFalse(outcome.backgroundReceived, "(\(point.x), \(point.y))")
        }
        tap(center, in: host)
        XCTAssertTrue(waitForEvent("unpin:\(tileID)", recorder, host))
        XCTAssertTrue(host.coordinator.isEditing, "edit mode did not end")
    }

    /// Panel: the button touch area and the background gesture are consistent across the whole grid; the body
    /// of a panel tile outside the corner quarter does not count as a button and the gesture accepts it.
    func testPanelBackgroundRecognizerAgreesWithButtonHitTest() throws {
        let (host, _) = try makePanelHost()
        let grid = host.host.grid
        var sawButton = false
        var y: CGFloat = 1
        while y < grid.bounds.height {
            var x: CGFloat = 1
            while x < grid.bounds.width {
                let outcome = touchDown(at: CGPoint(x: x, y: y), in: host)
                let isButton = outcome.hit is UIButton
                XCTAssertEqual(outcome.backgroundReceived, !isButton, "(\(x), \(y))")
                sawButton = sawButton || isButton
                x += 3
            }
            y += 3
        }
        XCTAssertTrue(sawButton)

        let geometry = try XCTUnwrap(grid.panelShortcutGeometry())
        let body = CGPoint(x: geometry.frames[0].midX, y: geometry.frames[0].midY)
        let outcome = touchDown(at: body, in: host)
        XCTAssertNil(outcome.hit as? UIButton)
        XCTAssertTrue(outcome.backgroundReceived)
    }

    // MARK: - Enabling the gesture

    /// The background gesture is enabled only in edit mode; outside edit mode it does not accept touches.
    func testBackgroundRecognizerFollowsEditMode() throws {
        let host = TesseraTestDragHost(
            descriptors: (0..<4).map { tesseraTestTile("t\($0)", size: .medium) }
        )
        let recognizer = host.coordinator.backgroundTapGestureRecognizer
        XCTAssertFalse(recognizer.isEnabled)
        XCTAssertTrue(recognizer.cancelsTouchesInView == false)

        host.coordinator.beginEditing()
        XCTAssertTrue(recognizer.isEnabled)
        XCTAssertFalse(recognizer.cancelsTouchesInView, "cancelsTouchesInView semantics unchanged")

        host.coordinator.endEditing()
        XCTAssertFalse(recognizer.isEnabled)
        let point = try XCTUnwrap(host.point("t0"))
        XCTAssertFalse(touchDown(at: point, in: host).backgroundReceived)
    }
}

#endif
