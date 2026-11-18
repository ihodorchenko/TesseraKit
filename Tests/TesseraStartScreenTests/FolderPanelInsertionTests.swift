//
//  FolderPanelInsertionTests.swift
//  TesseraStartScreenTests
//
//  Tests for the pure geometry of the expanded folder panel (D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid";
//  D17 in docs/DECISIONS.md: the panel is inserted as a separate item right after
//  the folder tile (the tile stays visible), and geometrically occupies
//  a full-width row right after the row in which the folder ends;
//  everything that starts below that row sits under the panel.
//
//  Only the pure functions of `TesseraTileLayoutEngine` are checked:
//  `folderPanelInsertionIndex`, `rowsBelowOffset`, `panelHeight`. No
//  UICollectionView, window or layout pass is needed here: the functions
//  are deterministic and depend only on the model and the column count.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderPanelInsertionTests: XCTestCase {

    // MARK: - Helpers

    /// Height of the panel header row: 12 pt margins above and below + 44 pt.
    private let headerHeight: CGFloat = 68

    /// Geometry comparison tolerance in points.
    private let accuracy: CGFloat = 0.0001

    /// A folder for layout tests.
    ///
    /// - Parameters:
    ///   - id: The folder identifier.
    ///   - title: The panel title.
    ///   - tiles: The tiles inside the folder.
    ///   - size: The size of the folder tile on the grid (2×2 by default).
    /// - Returns: A ready `TesseraTileFolder` model.
    private func makeFolder(
        _ id: String,
        title: String = "Folder",
        tiles: [TesseraTileDescriptor] = [],
        size: TesseraTileSize = .medium
    ) -> TesseraTileFolder {
        TesseraTileFolder(id: id, title: title, tiles: tiles, size: size)
    }

    /// Set items for readable order checks.
    ///
    /// - Parameter items: The grid items.
    /// - Returns: The identifiers in array order.
    private func ids(_ items: [TesseraTileGridItem]) -> [AnyHashable] {
        items.map { $0.id }
    }

    // MARK: - Panel insertion index (folderPanelInsertionIndex)

    /// With no expanded folder there is nothing to insert.
    func testInsertionIndexIsNilWithoutExpandedFolder() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [.tile(tesseraTestTile("a")), .folder(folder)]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: nil
            )
        )
    }

    /// The folder is not in the set, so there is nothing to insert (the identifier did not match).
    func testInsertionIndexIsNilWhenFolderIsMissing() {
        let items: [TesseraTileGridItem] = [.tile(tesseraTestTile("a"))]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: AnyHashable("missing")
            )
        )
    }

    /// The panel is already in the set, so it is not inserted a second time.
    func testInsertionIndexIsNilWhenPanelIsAlreadyInserted() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .folderContent(folder),
        ]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            )
        )
    }

    /// The insertion index is right after the folder tile, not in place of it.
    func testInsertionIndexPointsRightAfterFolderTile() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a", size: .small)),
            .folder(folder),
            .tile(tesseraTestTile("b", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            ),
            2
        )
    }

    /// Insertion does not remove the folder tile: the item count grows by one, the tile
    /// stays at its own index, and the panel comes next.
    func testInsertionKeepsFolderTileAndGrowsItemCount() {
        let folder = makeFolder("f")
        var items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folder(folder),
            .tile(tesseraTestTile("b")),
            .tile(tesseraTestTile("c")),
        ]
        let before = ids(items)

        let index = TesseraTileLayoutEngine.folderPanelInsertionIndex(
            items: items,
            expandedFolderID: folder.id
        )
        XCTAssertEqual(index, 2)
        guard let index else { return }
        items.insert(.folderContent(folder), at: index)

        XCTAssertEqual(items.count, before.count + 1)
        // The folder tile stayed at its previous index: [a, folder, panel, b, c].
        XCTAssertEqual(ids(items), [before[0], before[1], folder.id, before[2], before[3]])
        XCTAssertEqual(items[1].folder?.id, folder.id)
        XCTAssertTrue(items[2].isFolderPanel)
        XCTAssertEqual(items[2].panelFolder?.id, folder.id)
    }

    /// The index works for the first and the last folder: the first gives 1, the last gives
    /// the end of the array (insertion at the end).
    func testInsertionIndexWorksForFirstAndLastFolder() {
        let folder = makeFolder("f")
        let first: [TesseraTileGridItem] = [.folder(folder), .tile(tesseraTestTile("a"))]
        let last: [TesseraTileGridItem] = [.tile(tesseraTestTile("a")), .folder(folder)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: first, expandedFolderID: folder.id),
            1
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: last, expandedFolderID: folder.id),
            2
        )
    }

    /// The index does not depend on the sizes of neighbors: it is a position in the array, not in
    /// the layout (the panel row is computed by the view layer's geometry).
    func testInsertionIndexIgnoresNeighbourSizes() {
        let folder = makeFolder("f", size: .medium)
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("wide", size: .wide)),
            .tile(tesseraTestTile("large", size: .large)),
            .folder(folder),
            .tile(tesseraTestTile("small", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            ),
            3
        )
    }

    /// The folder is found by identifier, not by the case of the item: the panel
    /// is inserted after it even when other folders stand nearby.
    func testInsertionIndexFindsFolderAmongTiles() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .tile(tesseraTestTile("b")),
            .folder(folder),
            .tile(tesseraTestTile("c")),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            ),
            3
        )
    }

    // MARK: - Offset of rows below the panel (rowsBelowOffset)

    /// A neighbor in the same row as a 2×2 folder stays in place: the panel
    /// starts after the row in which the folder ends, not at its
    /// top edge.
    func testRowsBelowOffsetIsZeroWhenNeighbourSharesFolderRow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("top", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// A neighbor in the folder's last row also stays in place: the first row
    /// of the panel goes below it.
    func testRowsBelowOffsetIsZeroWhenNeighbourSharesFolderLastRow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("a", size: .small)),
            .tile(tesseraTestTile("b", size: .small)),
            .tile(tesseraTestTile("c", size: .small)),
        ]

        // a and b are row 0 (to the right of the folder), c is row 1: all above row 2.
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// An item that starts below the folder's row goes under the panel: the offset
    /// equals its height plus the grid gap (8 pt by default), exactly how far
    /// the layout shifts the first row under the panel.
    func testRowsBelowOffsetShiftsItemsBelowFolder() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            128,
            accuracy: accuracy
        )
    }

    /// The folder is last: there is nothing under the panel, so there is nothing to shift.
    func testRowsBelowOffsetIsZeroWhenNothingIsBelowFolder() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("wide", size: .wide)),
            .folder(folder),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Items that end above the folder's row stay in place.
    func testRowsBelowOffsetIsZeroWhenAllItemsAreAboveFolderRow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("wide", size: .wide)),
            .tile(tesseraTestTile("below", size: .wide)),
            .folder(folder),
        ]

        // "wide" is rows 0–1, "below" is rows 2–3, the folder is row 4.
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Several items under the panel do not add up: the offset is counted once,
    /// for one panel height (plus the grid gap).
    func testRowsBelowOffsetCountsPanelOnceForSeveralItemsBelow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("a", size: .small)),
            .tile(tesseraTestTile("b", size: .small)),
            .tile(tesseraTestTile("wide", size: .wide)),
            .tile(tesseraTestTile("c", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            128,
            accuracy: accuracy
        )
    }

    /// The panel is already in the set: the layout has already accounted for its effect, so a repeated offset is 0.
    func testRowsBelowOffsetIsZeroWhenPanelIsAlreadyPresent() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .folderContent(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// No expanded folder, the folder is not in the set, or the grid is degenerate: the offset is 0.
    func testRowsBelowOffsetIsZeroForDegenerateInput() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: nil,
                panelHeight: 120
            ),
            0
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: AnyHashable("missing"),
                panelHeight: 120
            ),
            0
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 0,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0
        )
    }

    /// A zero, negative or non-finite panel height does not shift rows.
    func testRowsBelowOffsetIgnoresInvalidPanelHeight() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        for height in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    items: items,
                    columns: 4,
                    expandedFolderID: folder.id,
                    panelHeight: height
                ),
                0,
                "Invalid height \(height) must not shift rows"
            )
        }
    }

    /// The offset accounts for the actual grid gap: `itemSpacing = 12`
    /// gives `panelHeight + 12`; a negative or non-finite gap gives 0.
    func testRowsBelowOffsetUsesGivenSpacing() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120,
                spacing: 12
            ),
            132,
            accuracy: accuracy
        )
        for spacing in [CGFloat(-4), .nan] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    items: items,
                    columns: 4,
                    expandedFolderID: folder.id,
                    panelHeight: 120,
                    spacing: spacing
                ),
                120,
                accuracy: accuracy
            )
        }
    }

    // MARK: - Folder band

    /// A "staircase" `[folder 2×2, small, small, tile 2×2]`: the tile is in rows
    /// 1–2, and the folder band is rows 0–2. There is nothing under the panel, the tile stays
    /// above it, and the panel is inserted after the tile.
    func testStepTileIsPartOfFolderBand() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(tesseraTestTile("m", size: .medium)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                columns: 4,
                expandedFolderID: folder.id
            ),
            4
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )

        // The tile after the "staircase" starts below the band, so it goes under the panel.
        let withBelow = items + [.tile(tesseraTestTile("w", size: .wide))]
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: withBelow,
                columns: 4,
                expandedFolderID: folder.id
            ),
            4
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: withBelow,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            128,
            accuracy: accuracy
        )
    }

    /// `[folder small, tile 2×2]`: the 2×2 occupies rows 0–1, and so does the band;
    /// the panel is inserted after the tile.
    func testTallNeighbourOfSmallFolderIsPartOfBand() {
        let folder = makeFolder("f", size: .small)
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("m", size: .medium)),
            .tile(tesseraTestTile("w", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                columns: 4,
                expandedFolderID: folder.id
            ),
            2
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120,
                spacing: 8
            ),
            128,
            accuracy: accuracy
        )
    }

    /// With columns, the insertion index is no earlier than "right after the folder" and comes after
    /// the items that compactness lifted into the band rows.
    func testInsertionIndexWithColumnsFollowsLastBandItem() {
        let folder = makeFolder("f")
        // The folder is (0,0)–(1,1); wide does not fit on the right, so it takes row 2; small
        // is lifted to (2,0): it is in the band although it follows wide in the array.
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("w", size: .wide)),
            .tile(tesseraTestTile("s", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                columns: 4,
                expandedFolderID: folder.id
            ),
            3
        )
        // With no neighbors in the band, right after the folder, as with the legacy input.
        let alone: [TesseraTileGridItem] = [.folder(folder), .tile(tesseraTestTile("w", size: .wide))]
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: alone, columns: 4, expandedFolderID: folder.id),
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: alone, expandedFolderID: folder.id)
        )
        // Degenerate columns give the legacy index; no folder or the panel already
        // present gives nil.
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: items, columns: 0, expandedFolderID: folder.id),
            1
        )
        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: items, columns: 4, expandedFolderID: nil)
        )
        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items + [.folderContent(folder)],
                columns: 4,
                expandedFolderID: folder.id
            )
        )
    }

    /// Panel height with the grid gap: tiles use the grid unit and gap.
    func testPanelHeightUsesGridSpacingAndScale() {
        let five = makeFolder("f", tiles: (0..<5).map { tesseraTestTile("t\($0)") })

        // 390 pt, gap 12: unit (390 − 36) / 4 = 88.5; 2 rows:
        // 68 + 8 + (2×88.5 + 12) = 265.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4, spacing: 12, scale: 0),
            265,
            accuracy: accuracy
        )
        // 3×: unit 88.5 → 88⅓; 68 + 8 + (2×88⅓ + 12) = 264⅔.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4, spacing: 12, scale: 3),
            264 + 2.0 / 3.0,
            accuracy: accuracy
        )
        // Legacy input: gap 8 without alignment.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4),
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4, spacing: 8, scale: 0),
            accuracy: accuracy
        )
    }

    // MARK: - Panel height (panelHeight)

    /// An empty folder: one header row, no content grid.
    func testPanelHeightForEmptyFolderIsHeaderOnly() {
        let folder = makeFolder("f", tiles: [])

        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: folder, width: 390, columns: 4),
            headerHeight,
            accuracy: accuracy
        )
    }

    /// The title takes one row: its text does not change the panel height.
    func testPanelHeightDoesNotDependOnFolderTitle() {
        let untitled = makeFolder("f", title: "")
        let titled = makeFolder("f", title: "A very long folder name")

        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: untitled, width: 390, columns: 4),
            TesseraTileLayoutEngine.panelHeight(for: titled, width: 390, columns: 4),
            accuracy: accuracy
        )
    }

    /// One to four icons make one row of the content grid.
    func testPanelHeightForSingleContentRow() {
        for count in 1...4 {
            let folder = makeFolder("f", tiles: (0..<count).map { tesseraTestTile("t\($0)") })

            // 390 pt: grid unit (390 − 3×8) / 4 = 91.5, the same side as
            // a 1×1 tile; height = 68 (header) + 8 (gap) + 91.5 = 167.5.
            XCTAssertEqual(
                TesseraTileLayoutEngine.panelHeight(for: folder, width: 390, columns: 4),
                167.5,
                accuracy: accuracy,
                "One content row with \(count) tiles"
            )
        }
    }

    /// The fifth icon opens a second row, the ninth a third.
    func testPanelHeightGrowsWithContentRows() {
        let five = makeFolder("f", tiles: (0..<5).map { tesseraTestTile("t\($0)") })
        let nine = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })

        // 2 rows: 68 + 8 + (2×91.5 + 8) = 267.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4),
            267,
            accuracy: accuracy
        )
        // 3 rows: 68 + 8 + (3×91.5 + 2×8) = 366.5.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: nine, width: 390, columns: 4),
            366.5,
            accuracy: accuracy
        )
    }

    /// Width changes the cell side and therefore the panel height.
    func testPanelHeightDependsOnWidth() {
        let four = makeFolder("f", tiles: (0..<4).map { tesseraTestTile("t\($0)") })
        let five = makeFolder("f", tiles: (0..<5).map { tesseraTestTile("t\($0)") })

        // 320 pt: unit (320 − 3×8) / 4 = 74.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: four, width: 320, columns: 4),
            150,
            accuracy: accuracy
        )
        // 2 rows: 68 + 8 + (2×74 + 8) = 232.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 320, columns: 4),
            232,
            accuracy: accuracy
        )

        XCTAssertGreaterThan(
            TesseraTileLayoutEngine.panelHeight(for: four, width: 390, columns: 4),
            TesseraTileLayoutEngine.panelHeight(for: four, width: 320, columns: 4)
        )
    }

    /// The column count of the content grid also changes the cell side.
    func testPanelHeightDependsOnColumns() {
        let folder = makeFolder("f", tiles: [tesseraTestTile("a")])

        // 390 pt, 2 columns: unit (390 − 8) / 2 = 191;
        // height = 68 + 8 + 191 = 267.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: folder, width: 390, columns: 2),
            267,
            accuracy: accuracy
        )
    }

    /// A negative tile count is treated as an empty panel.
    func testPanelHeightClampsNegativeTileCount() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: -3, width: 390, columns: 4),
            headerHeight,
            accuracy: accuracy
        )
    }

    /// Degenerate geometry gives zero height.
    func testPanelHeightIsZeroForDegenerateGeometry() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 24, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 23, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 0, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: -10, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: .nan, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 390, columns: 0),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 390, columns: -4),
            0,
            accuracy: accuracy
        )
    }
}

#endif
