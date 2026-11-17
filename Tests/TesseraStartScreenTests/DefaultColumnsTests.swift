//
//  DefaultColumnsTests.swift
//  TesseraStartScreenTests
//
//  Tests of the default column count (D26): 6 small columns, as in
//  Windows 10 Mobile (docs/W10M-STARTSCREEN.md §2) — three medium tiles per row,
//  a wide tile spans 4 of 6 columns. The value is shared by the grid, layout and store;
//  the host may set its own `columns`.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class DefaultColumnsTests: XCTestCase {

    /// There is a single default: the engine, layout, grid and store all take it from
    /// ``TesseraTileLayoutEngine/defaultColumns``.
    func testDefaultColumnsIsSixEverywhere() {
        XCTAssertEqual(TesseraTileLayoutEngine.defaultColumns, 6)
        XCTAssertEqual(TesseraTileStore.defaultGridColumns, 6)
        XCTAssertEqual(TesseraTileCollectionViewLayout().columns, 6)
        XCTAssertEqual(TesseraTileGridView(frame: .zero).columns, 6)
    }

    /// The host can still set its own column count.
    func testHostCanOverrideColumns() {
        let grid = TesseraTileGridView(frame: .zero)
        grid.columns = 4
        XCTAssertEqual(grid.columns, 4)
    }

    /// On the default grid three medium tiles fit in one row and a wide tile
    /// spans 4 of 6 columns, and the unit equals `(width − insets − 5 × gap) / 6`.
    func testGridWithDefaultColumnsPacksThreeMediumsPerRow() throws {
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("m0", size: .medium)),
            .tile(tesseraTestTile("m1", size: .medium)),
            .tile(tesseraTestTile("m2", size: .medium)),
            .tile(tesseraTestTile("w0", size: .wide)),
        ]
        let host = TesseraTestWindowedGrid(items: items, columns: TesseraTileLayoutEngine.defaultColumns)
        let grid = host.grid
        XCTAssertEqual(grid.columns, 6)

        let frames = try ["m0", "m1", "m2", "w0"].map { id in
            try XCTUnwrap(grid.frame(forItemID: id), "No frame for \(id)")
        }

        let unit = TesseraTileLayoutEngine.unit(
            screenWidth: grid.bounds.width - 32,
            columns: 6,
            gaps: grid.itemSpacing
        )
        let spacing = grid.itemSpacing
        XCTAssertEqual(frames[0].width, unit * 2 + spacing, accuracy: 1.0)
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 0.001)
        XCTAssertEqual(frames[1].minY, frames[2].minY, accuracy: 0.001)
        XCTAssertLessThan(frames[0].maxX, frames[1].minX)
        XCTAssertLessThan(frames[1].maxX, frames[2].minX)
        // The wide tile goes on the next row, 4 columns wide.
        XCTAssertGreaterThan(frames[3].minY, frames[0].maxY)
        XCTAssertEqual(frames[3].width, unit * 4 + spacing * 3, accuracy: 1.0)
        XCTAssertLessThan(frames[3].width, grid.bounds.width - 32)
    }

    /// Until the host names the grid width, the store assumes 6 columns by default
    /// (`effectiveColumns`); a named width replaces it. The former
    /// `resize(_:to:)` without `columns` has been removed — the width is passed explicitly.
    func testStoreEffectiveColumnsDefaultsToSix() {
        let directory = TesseraTestDirectory()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog([tesseraTestTile("a", size: .medium)])

        XCTAssertEqual(store.effectiveColumns, 6)
        store.placeItems(columns: 4)
        XCTAssertEqual(store.effectiveColumns, 4)
    }
}

#endif
