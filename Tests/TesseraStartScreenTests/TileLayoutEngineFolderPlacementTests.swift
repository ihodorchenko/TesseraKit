//
//  TileLayoutEngineFolderPlacementTests.swift
//  TesseraStartScreenTests
//
//  Geometry of the expanded folder panel on coordinate-based placements (D17,
//  D30). Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 and "Implementation
//  deviations".
//
//  The variants `folderBandEndRow(forFolder:...)`, `folderPanelInsertionIndex(
//  placements:...)` and `rowsBelowOffset(placements:...)` work on ready-made
//  cells and do not repack: rows below the folder band keep their holes, and the panel
//  pushes them down by the panel height (in points, the layout layer). On a compact
//  layout the result must match the old variants based on `TesseraTileGridItem`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEngineFolderPlacementTests: XCTestCase {

    private let columns = 6

    // MARK: - folderBandEndRow

    /// A lone 2×2 folder: the band consists of its two rows.
    func testBandEndOfLoneFolderIsItsBottom() {
        let placements = [placementItem("f", .medium, 3, 0)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            5
        )
    }

    /// A tile that starts in the folder rows and ends below extends
    /// the band (iteratively, until a fixed point).
    func testBandEndExtendsOverTilesStartingInsideBand() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("tall", .medium, 1, 2),
            placementItem("chain", .medium, 2, 4),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            4
        )
    }

    /// A tile behind a hole below the band does not extend the band.
    func testBandEndIgnoresTilesBelowAHole() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("far", .large, 6, 0),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            2
        )
    }

    /// The folder is not in the set: `nil`.
    func testBandEndOfUnknownFolderIsNil() {
        XCTAssertNil(
            TesseraTileLayoutEngine.folderBandEndRow(
                forFolder: "none", in: [placementItem("a", .small, 0, 0)], columns: columns
            )
        )
    }

    /// The function gives the same result by slots and by placements.
    func testBandEndMatchesSlotBasedVariant() {
        let placements = [
            placementItem("f", .medium, 1, 2),
            placementItem("a", .small, 2, 4),
            placementItem("b", .wide, 3, 0),
        ]
        let slots = TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 1, fitting: true)

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            TesseraTileLayoutEngine.folderBandEndRow(for: slots[0], in: slots)
        )
    }

    // MARK: - folderPanelInsertionIndex

    /// The panel goes after the last item that stays above it; holes are not
    /// filled and the array order is not recomputed.
    func testInsertionIndexAfterLastElementAbovePanelWithHoles() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("below", .small, 6, 0),
            placementItem("side", .small, 0, 3),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: "f"
            ),
            3
        )
    }

    /// With no items nearby the panel goes right after the folder.
    func testInsertionIndexRightAfterFolderWhenNothingElseAbove() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("below", .small, 4, 0),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: "f"
            ),
            1
        )
    }

    /// No expansion or no such folder: `nil`.
    func testInsertionIndexNilWithoutExpansionOrFolder() {
        let placements = [placementItem("f", .medium, 0, 0)]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: nil
            )
        )
        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: "zzz"
            )
        )
    }

    // MARK: - rowsBelowOffset

    /// There is something to shift (even behind a hole): an offset of `panelHeight + spacing`;
    /// the cells stay as they were (the panel does not repack).
    func testRowsBelowOffsetShiftsTilesBelowBandWithoutRepacking() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("far", .small, 9, 3),
        ]

        let offset = TesseraTileLayoutEngine.rowsBelowOffset(
            placements: placements, columns: columns, expandedFolderID: "f", panelHeight: 100, spacing: 8
        )

        XCTAssertEqual(offset, 108)
        XCTAssertEqual(
            TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 1, fitting: true).map(\.row),
            [0, 9]
        )
    }

    /// Everything is in the folder band or there is nothing below: a shift of 0.
    func testRowsBelowOffsetIsZeroWhenNothingBelowBand() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("tall", .medium, 1, 2),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                placements: placements, columns: columns, expandedFolderID: "f", panelHeight: 100
            ),
            0
        )
    }

    /// Degenerate inputs: height 0, no expansion, no folder.
    func testRowsBelowOffsetDegenerateInputs() {
        let placements = [placementItem("f", .medium, 0, 0), placementItem("a", .small, 5, 0)]

        let cases: [(AnyHashable?, CGFloat)] = [(nil, 100), ("f", 0), ("zzz", 100), ("f", .nan)]
        for (expanded, height) in cases {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    placements: placements, columns: columns, expandedFolderID: expanded, panelHeight: height
                ),
                0
            )
        }
    }

    /// A negative/non-numeric gap is treated as 0.
    func testRowsBelowOffsetSanitizesSpacing() {
        let placements = [placementItem("f", .medium, 0, 0), placementItem("a", .small, 5, 0)]

        for spacing in [CGFloat(-4), .nan] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    placements: placements, columns: columns, expandedFolderID: "f",
                    panelHeight: 100, spacing: spacing
                ),
                100
            )
        }
    }

    // MARK: - Compatibility with the old API on a compact layout

    /// For compact packing the new variants match the old ones by
    /// `TesseraTileGridItem` (the insertion index and the offset of rows under the panel).
    func testPlacementVariantsMatchLegacyItemsAPIOnCompactLayout() {
        let sizes = TesseraTileSize.allCases

        for seed in 1...25 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = [4, 6][generator.int(upperBound: 2)]
            let folderSize = sizes[generator.int(upperBound: sizes.count)]
            let folderPosition = generator.int(upperBound: 6)

            var items: [TesseraTileGridItem] = []
            for index in 0..<6 {
                items.append(.tile(tesseraTestTile("t\(index)", size: sizes[generator.int(upperBound: sizes.count)])))
            }
            items.insert(.folder(tesseraTestFolder("f", tileCount: 3, size: folderSize)), at: folderPosition)

            let packed = TesseraTileLayoutEngine.pack(
                items: items.map { (id: $0.id, size: $0.size) },
                columns: columns,
                unit: 1
            )
            let placements = packed.map {
                TesseraTilePlacedItem(id: $0.id, size: $0.size, cell: TesseraTileGridPlacement(row: $0.row, column: $0.column))
            }
            let context = "seed \(seed), columns \(columns)"

            XCTAssertEqual(
                TesseraTileLayoutEngine.folderPanelInsertionIndex(
                    placements: placements, columns: columns, expandedFolderID: "f"
                ),
                TesseraTileLayoutEngine.folderPanelInsertionIndex(
                    items: items, columns: columns, expandedFolderID: "f"
                ),
                context
            )
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    placements: placements, columns: columns, expandedFolderID: "f", panelHeight: 120
                ),
                TesseraTileLayoutEngine.rowsBelowOffset(
                    items: items, columns: columns, expandedFolderID: "f", panelHeight: 120
                ),
                context
            )
        }
    }

    /// The slot-based layout for the same model does not depend on holes above
    /// the band: removing a tile above the folder does not change the insertion index relative to
    /// the remaining items (a hole is not "collapsed" by the panel).
    func testRemovingTileAboveFolderLeavesBandAndShiftUnchanged() {
        let placements = [
            placementItem("top", .small, 0, 0),
            placementItem("f", .medium, 2, 0),
            placementItem("below", .small, 4, 0),
        ]
        let withoutTop = TesseraTileLayoutEngine.removing(id: "top", from: placements)

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: withoutTop, columns: columns)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                placements: withoutTop, columns: columns, expandedFolderID: "f", panelHeight: 90
            ),
            98
        )
    }
}

#endif
