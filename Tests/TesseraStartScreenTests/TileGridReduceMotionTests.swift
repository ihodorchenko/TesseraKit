//
//  TileGridReduceMotionTests.swift
//  TesseraStartScreenTests
//
//  Reduce Motion when a grid snapshot is applied.
//
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §9 "Accessibility"
//  (Reduce Motion: no flips, jiggle or parallax; animations are not played);
//  the crossfade of a grid composition change honors
//  the setting.
//
//  The crossfade branch with `animated: true` is reachable only after
//  `guard shouldAnimate`, because `shouldAnimate` includes
//  `!isReduceMotionEnabled()`. The tests confirm that with Reduce Motion
//  the snapshot is applied without a crossfade (and immediately: the composition is already new), while without
//  Reduce Motion the crossfade runs. The Reduce Motion provider is an internal
//  seam of the grid (`isReduceMotionEnabled`); the system setting is not changed.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridReduceMotionTests: XCTestCase {

    // MARK: - Helpers

    /// A grid with the composition `[a, b]` in a window: a crossfade is possible only on screen.
    private func makeHost() -> TesseraTestWindowedGrid {
        let host = TesseraTestWindowedGrid(
            items: [.tile(tesseraTestTile("a", size: .small)),
                    .tile(tesseraTestTile("b", size: .small))]
        )
        host.layout()
        return host
    }

    /// A snapshot with the tile `c` added (a composition change).
    private func snapshotWithExtraTile() -> TesseraTileGridSnapshot {
        TesseraTileGridSnapshot(
            items: [
                .tile(tesseraTestTile("a", size: .small)),
                .tile(tesseraTestTile("b", size: .small)),
                .tile(tesseraTestTile("c", size: .small)),
            ],
            unpinned: []
        )
    }

    // MARK: - Composition change crossfade

    /// Without Reduce Motion a composition change is applied with a crossfade: the snapshot
    /// is really animated and not swapped silently.
    func testCompositionChangeCrossfadesWithoutReduceMotion() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { false }

        host.grid.update(snapshot: snapshotWithExtraTile(), animated: true)
        host.layout()

        XCTAssertTrue(
            host.grid.didApplyLastSnapshotWithCrossfade,
            "Without Reduce Motion the crossfade runs"
        )
        XCTAssertEqual(host.grid.items.count, 3)
        XCTAssertEqual(
            host.grid.items.map { $0.id },
            [AnyHashable("a"), AnyHashable("b"), AnyHashable("c")]
        )
    }

    /// With Reduce Motion the same call runs without a crossfade: the snapshot is applied
    /// immediately, and the composition is already new by the time `update` returns.
    func testCompositionChangeSkipsCrossfadeUnderReduceMotion() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { true }

        host.grid.update(snapshot: snapshotWithExtraTile(), animated: true)
        host.layout()

        XCTAssertFalse(
            host.grid.didApplyLastSnapshotWithCrossfade,
            "Reduce Motion disables the crossfade"
        )
        XCTAssertEqual(host.grid.items.count, 3)
        XCTAssertEqual(
            host.grid.items.map { $0.id },
            [AnyHashable("a"), AnyHashable("b"), AnyHashable("c")]
        )
    }

    /// "Without animation" (animated: false) does not enable a crossfade regardless of
    /// the setting: the branch is chosen by the calling code.
    func testNonAnimatedUpdateNeverCrossfades() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { false }

        host.grid.update(snapshot: snapshotWithExtraTile(), animated: false)
        host.layout()

        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertEqual(host.grid.items.count, 3)
    }

    /// A snapshot reload (`reload(snapshot:)`) never crossfades: it is the
    /// first display or a full data replacement, not an animated change.
    func testReloadNeverCrossfades() {
        let host = makeHost()
        host.grid.isReduceMotionEnabled = { false }

        host.grid.reload(snapshot: snapshotWithExtraTile())
        host.layout()

        XCTAssertFalse(host.grid.didApplyLastSnapshotWithCrossfade)
        XCTAssertEqual(host.grid.items.count, 3)
    }

    // MARK: - Reduce Motion and the folder panel

    /// With Reduce Motion the panel expands through the grid's non-animated branch:
    /// the state is applied immediately, without `isFolderChangeAnimating`.
    func testFolderExpansionAppliesImmediatelyUnderReduceMotion() {
        let folder = tesseraTestFolder("folder", tileCount: 3)
        let host = TesseraTestWindowedGrid(items: [.folder(folder)])
        host.grid.isReduceMotionEnabled = { true }

        host.grid.openFolder(folder, animated: true)
        host.layout()

        XCTAssertEqual(host.grid.expandedFolderID, folder.id)
        XCTAssertFalse(
            host.grid.isFolderChangeAnimating,
            "Reduce Motion does not start the panel animation"
        )
        XCTAssertTrue(host.grid.isScrollEnabled, "Scrolling is not blocked")
    }
}

#endif
