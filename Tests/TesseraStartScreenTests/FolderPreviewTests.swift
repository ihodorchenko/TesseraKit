//
//  FolderPreviewTests.swift
//  TesseraStartScreenTests
//
//  Tests for the closed folder preview (D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, section "Tile grid";
//  D17 in docs/STATE.md: a closed folder shows a 2×2 mini-grid of the first
//  four content icons.
//
//  There is no separate pure "first four" function in the API: the choice is made by
//  `TesseraFolderPreviewView.configure(tiles:schedule:)` (and the same `prefix(4)`
//  in `TesseraTileCell` before the call). So the contract is checked at the level of
//  the view value without a window: the number of mini-tiles and their badges as an observable sign
//  of the order. The flip timer is not started because the preview is not in a window.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderPreviewTests: XCTestCase {

    // MARK: - Helpers

    /// Tiles with unique identifiers and the given badges.
    ///
    /// - Parameter badges: Badges in tile order.
    /// - Returns: An array of tiles "t0", "t1", ...
    private func makeTiles(_ badges: [TesseraTileBadge]) -> [TesseraTileDescriptor] {
        badges.enumerated().map { index, badge in
            tesseraTestTile("t\(index)", badge: badge)
        }
    }

    /// A preview without a window: the schedule is not started.
    ///
    /// - Returns: An empty preview.
    private func makePreview() -> TesseraFolderPreviewView {
        TesseraFolderPreviewView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
    }

    /// Applies tiles with a fixed schedule seed.
    ///
    /// - Parameters:
    ///   - preview: Preview.
    ///   - tiles: Folder tiles in display order.
    private func configure(_ preview: TesseraFolderPreviewView, tiles: [TesseraTileDescriptor]) {
        preview.configure(tiles: tiles, schedule: TesseraFolderFlipSchedule(seed: 7))
    }

    // MARK: - Choosing the first four

    /// An empty folder creates no mini-tiles.
    func testEmptyFolderShowsNoMiniTiles() {
        let preview = makePreview()

        configure(preview, tiles: [])

        XCTAssertTrue(preview.miniTileViews.isEmpty)
    }

    /// Fewer than four tiles: all of them are shown, in folder order.
    func testFewerThanFourTilesAreShownInOrder() {
        let preview = makePreview()
        let tiles = makeTiles([.dot, .count(3), .none])

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(3), .none])
    }

    /// Exactly four tiles: all four.
    func testFourTilesAreAllShown() {
        let preview = makePreview()
        let tiles = makeTiles([.count(1), .count(2), .count(3), .count(4)])

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.count, 4)
        XCTAssertEqual(
            preview.miniTileViews.map { $0.badge },
            [.count(1), .count(2), .count(3), .count(4)]
        )
    }

    /// More than four: exactly the first four are taken, not the last ones.
    func testMoreThanFourTilesUseFirstFourOnly() {
        let preview = makePreview()
        let tiles = makeTiles((0..<6).map { .count(100 + $0) })

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.count, 4)
        XCTAssertEqual(
            preview.miniTileViews.map { $0.badge },
            [.count(100), .count(101), .count(102), .count(103)]
        )
        XCTAssertFalse(preview.miniTileViews.contains { $0.badge == .count(104) })
    }

    /// Shrinking the folder removes the extra mini-tiles (view reuse).
    func testReconfigureWithFewerTilesRemovesExtraViews() {
        let preview = makePreview()
        configure(preview, tiles: makeTiles((0..<5).map { .count($0 + 1) }))
        XCTAssertEqual(preview.miniTileViews.count, 4)

        configure(preview, tiles: makeTiles([.dot, .count(2)]))

        XCTAssertEqual(preview.miniTileViews.count, 2)
        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(2)])
    }

    /// Reconfiguring with the same content is idempotent: the phase is not
    /// reset, and the views are not recreated.
    func testReconfigureWithSameTilesKeepsViews() {
        let preview = makePreview()
        let tiles = makeTiles([.count(1), .count(2), .count(3), .count(4)])
        configure(preview, tiles: tiles)
        let firstMiniTile = preview.miniTileViews.first

        configure(preview, tiles: tiles)

        XCTAssertEqual(preview.miniTileViews.count, 4)
        XCTAssertTrue(preview.miniTileViews.first === firstMiniTile)
    }

    /// A real change of the contents updates the mini-tiles.
    ///
    /// The views themselves are reused (extra ones are removed, missing ones are added):
    /// the test pins the content, not the view identity.
    func testReconfigureWithDifferentTilesUpdatesContent() {
        let preview = makePreview()
        configure(preview, tiles: makeTiles([.count(1), .count(2)]))

        configure(preview, tiles: makeTiles([.dot, .count(7), .count(8)]))

        XCTAssertEqual(preview.miniTileViews.count, 3)
        XCTAssertEqual(preview.miniTileViews.map { $0.badge }, [.dot, .count(7), .count(8)])
    }
}

#endif
