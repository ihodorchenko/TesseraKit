//
//  TileEditJiggleOptInTests.swift
//  TesseraStartScreenTests
//
//  Edit mode jiggle is a host parameter, off by default
//  (D39).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit mode"
//  (jiggle is off by default and enabled by
//  `TesseraTileEditConfiguration.isJiggleEnabled`), §9 (Reduce Motion
//  turns jiggle off for any value of the parameter); docs/W10M-STARTSCREEN.md
//  §5 (in Windows 10 Mobile the grid is static in edit mode).
//
//  The parameter is read on every reconciliation of the controls, so it can be changed
//  on the fly: `configuration.didSet` rebuilds the controls and attaches or removes
//  the animations.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditJiggleOptInTests: XCTestCase {

    // MARK: - Helpers

    /// Counts unpins.
    private final class UnpinRecorder: TesseraTileEditCoordinatorDelegate {
        var unpins: [AnyHashable] = []

        func tileEditCoordinator(_ coordinator: TesseraTileEditCoordinator, didUnpin tileID: AnyHashable) {
            unpins.append(tileID)
        }
    }

    private let ids: [AnyHashable] = ["a", "b", "c"]

    private func makeHost(
        jiggle: Bool? = nil,
        reduceMotion: Bool = false
    ) -> TesseraTestDragHost {
        var configuration = TesseraTileEditConfiguration()
        if let jiggle {
            configuration.isJiggleEnabled = jiggle
        }
        let host = TesseraTestDragHost(
            descriptors: [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .medium),
            ],
            configuration: configuration
        )
        host.coordinator.isReduceMotionEnabled = { reduceMotion }
        return host
    }

    /// Jiggle on the cell content layer.
    private func cellJiggle(_ id: AnyHashable, in host: TesseraTestDragHost) -> CAAnimation? {
        host.host.cell(id)?.contentView.layer.animation(
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    /// Jiggle on the button overlay.
    private func controlJiggle(_ id: AnyHashable, in host: TesseraTestDragHost) -> CAAnimation? {
        host.coordinator.editControls[id]?.layer.animation(
            forKey: TesseraTileEditCoordinator.jiggleKey
        )
    }

    /// There is no wobble on any visible cell or overlay.
    private func assertNoJiggle(
        in host: TesseraTestDragHost,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for id in host.gridIDs {
            XCTAssertNil(cellJiggle(id, in: host), "\(message): cell \(id)", file: file, line: line)
            XCTAssertNil(controlJiggle(id, in: host), "\(message): control \(id)", file: file, line: line)
            for layer in [host.host.cell(id)?.contentView.layer, host.coordinator.editControls[id]?.layer] {
                guard let layer else { continue }
                XCTAssertNil(
                    layer.animation(forKey: "transform.rotation.z"),
                    "\(message): rotation \(id)", file: file, line: line
                )
                XCTAssertTrue(
                    CATransform3DIsIdentity(layer.transform),
                    "\(message): residual transform \(id)", file: file, line: line
                )
            }
        }
    }

    // MARK: - Default value

    /// D39: jiggle is off by default; the previous amplitude, cycle and
    /// seed values are kept for hosts that enable it.
    func testJiggleIsOffByDefaultAndKeepsParameters() {
        let configuration = TesseraTileEditConfiguration()
        XCTAssertFalse(configuration.isJiggleEnabled)
        XCTAssertEqual(configuration.jiggleAngle, 1.2, accuracy: 0.0001)
        XCTAssertEqual(configuration.jiggleDuration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(configuration.seed, 0xE4_0004_0000_0001)
    }

    // MARK: - Off (default)

    /// After entering edit mode the tiles and overlays have no animation; `isJiggling` is false,
    /// while the dim and the buttons are in place.
    func testNoJiggleAfterEnteringEditWhenOffByDefault() {
        let host = makeHost()
        host.coordinator.beginEditing()
        host.spin(0.05)

        XCTAssertTrue(host.coordinator.isEditing)
        XCTAssertFalse(host.coordinator.isJiggling)
        XCTAssertEqual(host.coordinator.editControls.count, 3, "Buttons are in place")
        assertNoJiggle(in: host, "Entering edit")
        host.coordinator.endEditing()
    }

    /// Drag, resize, unpin and folder creation (with reapplication after render)
    /// leave no wobble on the layers.
    func testNoJiggleAfterDragResizeUnpinAndRenderWhenOff() throws {
        let host = makeHost()
        let recorder = UnpinRecorder()
        host.coordinator.delegate = recorder
        host.coordinator.beginEditing()
        host.spin(0.05)

        // Drag: lift, release.
        XCTAssertTrue(host.startDrag("a"))
        assertNoJiggle(in: host, "During drag")
        host.coordinator.finishDrag(commit: true)
        XCTAssertTrue(host.waitUntil { host.coordinator.editControls["a"] != nil })
        host.spin(0.05)
        assertNoJiggle(in: host, "After drag")

        // Resize.
        XCTAssertNotNil(host.coordinator.cycleSize(of: "b"))
        host.host.layout()
        host.spin(0.05)
        assertNoJiggle(in: host, "After resize")

        // Unpin.
        host.coordinator.unpin("c")
        XCTAssertTrue(host.waitUntil { recorder.unpins.count == 1 })
        host.host.layout()
        host.spin(0.05)
        assertNoJiggle(in: host, "After unpin")

        // Folder creation: cells are recreated, the grid reapplies the dim.
        let folder = try XCTUnwrap(host.coordinator.createFolder(withTile: "a"))
        host.host.layout()
        XCTAssertTrue(host.waitUntil { host.host.cell(folder.id) != nil })
        host.spin(0.05)
        assertNoJiggle(in: host, "After folder creation")
        XCTAssertFalse(host.coordinator.isJiggling)
        host.coordinator.endEditing()
    }

    /// Leaving edit mode with jiggle off: the layers are clean.
    func testNoResidualTransformAfterLeavingEditWhenOff() {
        let host = makeHost()
        host.coordinator.beginEditing()
        host.spin(0.05)
        host.coordinator.endEditing()
        host.spin(0.05)

        XCTAssertFalse(host.coordinator.isEditing)
        assertNoJiggle(in: host, "After leaving")
    }

    // MARK: - On

    /// Explicit enabling: an animation on the cell and on the overlay of every tile, as before
    /// (a sine wave of ±1.2°, a cycle of about 0.4 s), `isJiggling` is true.
    func testJiggleInstalledWhenEnabled() throws {
        let host = makeHost(jiggle: true)
        host.coordinator.beginEditing()

        XCTAssertTrue(host.waitUntil {
            self.ids.allSatisfy { self.cellJiggle($0, in: host) != nil }
        }, "The cells got the jiggle")
        XCTAssertTrue(host.coordinator.isJiggling)
        for id in ids {
            let animation = try XCTUnwrap(controlJiggle(id, in: host) as? CAKeyframeAnimation, "\(id)")
            XCTAssertEqual(animation.keyPath, "transform.rotation.z")
            XCTAssertEqual(animation.repeatCount, .infinity)
            XCTAssertGreaterThanOrEqual(animation.duration, 0.4 * 0.85 - 0.001)
            XCTAssertLessThanOrEqual(animation.duration, 0.4 * 1.15 + 0.001)
        }
        host.coordinator.endEditing()
    }

    /// With the parameter enabled, leaving edit mode removes the wobble and does not
    /// leave a rotated layer.
    func testNoResidualTransformAfterLeavingEditWhenOn() {
        let host = makeHost(jiggle: true)
        host.coordinator.beginEditing()
        XCTAssertTrue(host.waitUntil {
            self.ids.allSatisfy { self.cellJiggle($0, in: host) != nil }
        })
        host.coordinator.endEditing()
        host.spin(0.05)

        XCTAssertFalse(host.coordinator.isEditing)
        assertNoJiggle(in: host, "After leaving")
    }

    // MARK: - Reduce Motion

    /// Reduce Motion overrides the parameter: jiggle is not applied, `isJiggling` is false,
    /// the buttons remain.
    func testReduceMotionBeatsEnabledParameter() {
        let host = makeHost(jiggle: true, reduceMotion: true)
        host.coordinator.beginEditing()
        host.spin(0.05)

        XCTAssertFalse(host.coordinator.isJiggling)
        XCTAssertEqual(host.coordinator.editControls.count, 3)
        assertNoJiggle(in: host, "Reduce Motion with the parameter enabled")
        host.coordinator.endEditing()
    }

    // MARK: - Changing the parameter on the fly

    /// The parameter can be changed during edit mode: enabling attaches the jiggle,
    /// disabling removes it without a residual transform.
    func testTogglingParameterWhileEditingInstallsAndRemovesJiggle() {
        let host = makeHost(jiggle: false)
        host.coordinator.beginEditing()
        host.spin(0.05)
        assertNoJiggle(in: host, "Before enabling")

        var configuration = host.coordinator.configuration
        configuration.isJiggleEnabled = true
        host.coordinator.configuration = configuration
        XCTAssertTrue(host.waitUntil {
            self.ids.allSatisfy { self.cellJiggle($0, in: host) != nil }
        }, "Enabled on the fly")
        XCTAssertTrue(host.coordinator.isJiggling)

        configuration.isJiggleEnabled = false
        host.coordinator.configuration = configuration
        host.spin(0.05)
        XCTAssertFalse(host.coordinator.isJiggling)
        assertNoJiggle(in: host, "After disabling on the fly")
        host.coordinator.endEditing()
    }

    /// Enabling the parameter on the fly under Reduce Motion attaches nothing.
    func testTogglingParameterOnUnderReduceMotionStaysStatic() {
        let host = makeHost(jiggle: false, reduceMotion: true)
        host.coordinator.beginEditing()
        host.spin(0.05)

        var configuration = host.coordinator.configuration
        configuration.isJiggleEnabled = true
        host.coordinator.configuration = configuration
        host.spin(0.05)

        assertNoJiggle(in: host, "Parameter enabled on the fly, Reduce Motion")
        XCTAssertFalse(host.coordinator.isJiggling)
        host.coordinator.endEditing()
    }
}

#endif
