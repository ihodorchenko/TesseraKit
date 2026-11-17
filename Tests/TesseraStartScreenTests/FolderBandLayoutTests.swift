//
//  FolderBandLayoutTests.swift
//  TesseraStartScreenTests
//
//  Tests for the layout of the expanded folder panel based on the "folder band" (D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, section "Tile grid" and
//  "Implementation deviations"; D17/D18 in docs/STATE.md: the panel is a
//  full-width row placed BELOW the folder tile.
//
//  Previously the decision "stays above the panel / moves below the panel" was made by
//  the top row of the tile (`slot.row < folderEndRow`): a tile that started in
//  the folder rows and ended below stayed in place and was overlapped by
//  the panel. These tests check the real layout
//  (`TesseraTileCollectionViewLayout`) on a collection without a window: no item
//  intersects the panel or another item, and the item order matches
//  the visual one (everything before the panel is above it, everything after is below it).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderBandLayoutTests: XCTestCase {

    // MARK: - Helpers

    /// Layout on a collection of the given width (no window needed).
    private struct Harness {

        /// Layout under test.
        let layout: TesseraTileCollectionViewLayout

        /// Owning collection: the layout takes its `bounds` from it.
        let collectionView: UICollectionView
    }

    /// Creates a layout on a collection without a window.
    ///
    /// - Parameters:
    ///   - width: Collection width.
    ///   - columns: Number of columns.
    ///   - spacing: Grid spacing.
    ///   - scale: Alignment scale (`nil` means taken from `traitCollection`).
    /// - Returns: The ready layout and collection.
    private func makeHarness(
        width: CGFloat = 390,
        columns: Int = 4,
        spacing: CGFloat = 8,
        scale: CGFloat? = nil
    ) -> Harness {
        let layout = TesseraTileCollectionViewLayout()
        layout.columns = columns
        layout.itemSpacing = spacing
        layout.displayScaleOverride = scale
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: width, height: 844),
            collectionViewLayout: layout
        )
        return Harness(layout: layout, collectionView: collectionView)
    }

    /// Frames of all items of the set, by index.
    ///
    /// - Parameters:
    ///   - harness: Layout.
    ///   - items: Set (with or without the panel).
    /// - Returns: Frames in the order of the set; an empty array if the layout did not
    ///   return a frame for at least one item.
    private func frames(in harness: Harness, items: [TesseraTileGridItem]) -> [CGRect] {
        harness.layout.setItems(items, reason: .items)
        var result: [CGRect] = []
        for index in items.indices {
            guard let frame = harness.layout.frame(forItemAt: index) else { return [] }
            result.append(frame)
        }
        return result
    }

    /// A set with the panel inserted at the engine index (as the grid does it).
    ///
    /// - Parameters:
    ///   - items: Base set without the panel.
    ///   - folder: The folder being expanded.
    ///   - columns: Number of columns.
    /// - Returns: The set with the panel and its index.
    private func expanded(
        _ items: [TesseraTileGridItem],
        folder: TesseraTileFolder,
        columns: Int = 4
    ) -> (items: [TesseraTileGridItem], panelIndex: Int)? {
        guard let index = TesseraTileLayoutEngine.folderPanelInsertionIndex(
            items: items,
            columns: columns,
            expandedFolderID: folder.id
        ) else {
            return nil
        }
        var result = items
        result.insert(.folderContent(folder), at: index)
        return (result, index)
    }

    /// Whether the frames overlap by area (touching edges does not count).
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 0.001 && intersection.height > 0.001
    }

    /// A folder with the given number of tiles.
    private func makeFolder(_ id: String, size: TesseraTileSize = .medium, tileCount: Int = 3) -> TesseraTileFolder {
        TesseraTileFolder(
            id: id,
            title: id,
            tiles: (0..<tileCount).map { tesseraTestTile("\(id)-t\($0)", size: .small) },
            size: size
        )
    }

    // MARK: - Review examples

    /// A "step" `[folder 2×2, small, small, tile 2×2]`, 4 columns: the tile
    /// sits in rows 1-2, the folder band is rows 0-2, the panel starts at row
    /// 3 and the tile does not overlap it.
    func testStepTileStartingInFolderRowsStaysAbovePanel() throws {
        let folder = makeFolder("f")
        let shortcut = tesseraTestTile("m", size: .medium)
        let base: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(shortcut),
        ]
        let harness = makeHarness()
        let collapsed = frames(in: harness, items: base)
        XCTAssertEqual(collapsed.count, base.count)

        let open = try XCTUnwrap(expanded(base, folder: folder))
        // The tile is inside the folder band: the panel comes after it in the array too.
        XCTAssertEqual(open.panelIndex, 4)

        let openFrames = frames(in: harness, items: open.items)
        XCTAssertEqual(openFrames.count, open.items.count)
        let panel = openFrames[open.panelIndex]

        let shortcutBefore = collapsed[3]
        let shortcutAfter = openFrames[3]
        // The tile stays in place, the panel is below it, no overlap.
        XCTAssertEqual(shortcutAfter, shortcutBefore)
        XCTAssertFalse(overlaps(shortcutAfter, panel))
        XCTAssertGreaterThanOrEqual(panel.minY, shortcutAfter.maxY + 8 - 0.001)
        // The folder stays in place as well.
        XCTAssertEqual(openFrames[0], collapsed[0])
    }

    /// `[folder small, tile 2×2]`: the tile is in rows 0-1, the folder is in row 0;
    /// the panel starts at row 2, not 1.
    func testMediumNextToSmallFolderStaysAbovePanel() throws {
        let folder = makeFolder("f", size: .small)
        let shortcut = tesseraTestTile("m", size: .medium)
        let base: [TesseraTileGridItem] = [.folder(folder), .tile(shortcut)]
        let harness = makeHarness()
        let collapsed = frames(in: harness, items: base)

        let open = try XCTUnwrap(expanded(base, folder: folder))
        XCTAssertEqual(open.panelIndex, 2)

        let openFrames = frames(in: harness, items: open.items)
        XCTAssertEqual(openFrames.count, open.items.count)
        let panel = openFrames[open.panelIndex]

        XCTAssertEqual(openFrames[1], collapsed[1])
        XCTAssertFalse(overlaps(openFrames[1], panel))
        XCTAssertFalse(overlaps(openFrames[0], panel))
    }

    /// A tile below the band moves below the panel: the first row under the panel is at
    /// `panelHeight + spacing` from its top edge, as reported by
    /// `rowsBelowOffset`.
    func testItemBelowBandMovesUnderPanelByReportedOffset() throws {
        let folder = makeFolder("f")
        let wide = tesseraTestTile("w", size: .wide)
        let base: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(tesseraTestTile("m", size: .medium)),
            .tile(wide),
        ]
        let harness = makeHarness()
        let open = try XCTUnwrap(expanded(base, folder: folder))
        XCTAssertEqual(open.panelIndex, 4)

        let openFrames = frames(in: harness, items: open.items)
        XCTAssertEqual(openFrames.count, open.items.count)
        let panel = openFrames[open.panelIndex]
        let wideFrame = openFrames[5]

        let offset = TesseraTileLayoutEngine.rowsBelowOffset(
            items: base,
            columns: 4,
            expandedFolderID: folder.id,
            panelHeight: panel.height
        )
        XCTAssertEqual(wideFrame.minY - panel.minY, offset, accuracy: 0.001)
        XCTAssertEqual(offset, panel.height + 8, accuracy: 0.001)
    }

    // MARK: - Randomized check

    /// Hundreds of seeded configurations (tile sizes, folder size and position, number
    /// of columns): no item intersects the panel or other
    /// items; every item is entirely above the panel or entirely below it;
    /// everything above the panel comes before it in the array (the insertion index is after
    /// the whole folder band) and does not shift relative to the collapsed grid.
    func testRandomConfigurationsNeverOverlapPanel() {
        var generator = TesseraTestSeededGenerator(seed: 0xE10_1)
        let sizes: [TesseraTileSize] = [.small, .small, .small, .medium, .medium, .wide, .large]
        let folderSizes: [TesseraTileSize] = [.small, .medium, .medium, .wide, .large]
        let columnChoices = [4, 4, 4, 3, 6]
        let harnesses = Dictionary(
            uniqueKeysWithValues: Set(columnChoices).map { ($0, makeHarness(columns: $0)) }
        )

        for configuration in 0..<400 {
            let columns = columnChoices[generator.int(upperBound: columnChoices.count)]
            guard let harness = harnesses[columns] else { return XCTFail("No layout") }

            let count = 1 + generator.int(upperBound: 14)
            var base: [TesseraTileGridItem] = (0..<count).map { index in
                .tile(tesseraTestTile("c\(configuration)-\(index)", size: sizes[generator.int(upperBound: sizes.count)]))
            }
            let folder = makeFolder(
                "folder-\(configuration)",
                size: folderSizes[generator.int(upperBound: folderSizes.count)],
                tileCount: 1 + generator.int(upperBound: 9)
            )
            base.insert(.folder(folder), at: generator.int(upperBound: base.count + 1))

            let collapsed = frames(in: harness, items: base)
            guard let open = expanded(base, folder: folder, columns: columns) else {
                return XCTFail("No insertion index, configuration \(configuration)")
            }
            let openFrames = frames(in: harness, items: open.items)
            guard openFrames.count == open.items.count, collapsed.count == base.count else {
                return XCTFail("Layout returned no frames, configuration \(configuration)")
            }

            let panel = openFrames[open.panelIndex]
            XCTAssertGreaterThan(panel.height, 0, "Configuration \(configuration)")

            for index in openFrames.indices where index != open.panelIndex {
                let frame = openFrames[index]
                XCTAssertFalse(
                    overlaps(frame, panel),
                    "Item \(index) is overlapped by the panel, configuration \(configuration)"
                )
                let isAbove = frame.maxY <= panel.minY + 0.001
                let isBelow = frame.minY >= panel.maxY - 0.001
                XCTAssertTrue(isAbove || isBelow, "Item \(index) touches the panel row (\(configuration))")
                if isAbove {
                    // Everything above the panel comes before it in the array and does not move.
                    XCTAssertLessThan(index, open.panelIndex, "Item \(index) is above the panel but comes after it (\(configuration))")
                    if index < open.panelIndex {
                        XCTAssertEqual(frame, collapsed[index], "Shift above the panel (\(configuration))")
                    }
                }
                for other in openFrames.indices where other > index && other != open.panelIndex {
                    XCTAssertFalse(
                        overlaps(frame, openFrames[other]),
                        "Items \(index) and \(other) overlap, configuration \(configuration)"
                    )
                }
            }
        }
    }

    // MARK: - Panel spacing

    /// With `itemSpacing = 12` the panel tiles line up with the grid columns: their x and
    /// width match the 1×1 tiles under the same columns, the row step is
    /// unit + 12.
    func testPanelShortcutsAlignWithGridColumnsForCustomSpacing() throws {
        let folder = makeFolder("f", size: .medium, tileCount: 6)
        let smalls = (0..<4).map { tesseraTestTile("s\($0)", size: .small) }
        let items: [TesseraTileGridItem] = smalls.map { .tile($0) } + [.folder(folder)]

        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 393, height: 1200))
        grid.columns = 4
        grid.itemSpacing = 12
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layoutGrid(grid)
        grid.openFolder(folder, animated: false)
        layoutGrid(grid)

        let collectionView = try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
        let panelIndex = try XCTUnwrap(grid.displayItems.firstIndex { $0.isFolderPanel })
        let panelCell = try XCTUnwrap(
            collectionView.cellForItem(at: IndexPath(item: panelIndex, section: 0)) as? TesseraFolderPanelCell
        )
        panelCell.layoutIfNeeded()

        let shortcutFrames = panelCell.contentView.subviews
            .compactMap { $0 as? TesseraTileCell }
            .map { panelCell.contentView.convert($0.frame, to: collectionView) }
        XCTAssertEqual(shortcutFrames.count, 6)

        let columnFrames = try smalls.map { try XCTUnwrap(grid.frame(forItemID: $0.id)) }
            .map { grid.convert($0, to: collectionView) }

        for (index, shortcut) in shortcutFrames.enumerated() {
            let column = columnFrames[index % 4]
            XCTAssertEqual(shortcut.minX, column.minX, accuracy: 0.001, "Tile \(index): column")
            XCTAssertEqual(shortcut.width, column.width, accuracy: 0.001, "Tile \(index): width")
        }
        // The second row of tiles is one unit plus the grid spacing of 12 apart.
        XCTAssertEqual(
            shortcutFrames[4].minY - shortcutFrames[0].minY,
            columnFrames[0].height + 12,
            accuracy: 0.001
        )
        // The gap between columns is 12 in the panel too.
        XCTAssertEqual(shortcutFrames[1].minX - shortcutFrames[0].maxX, 12, accuracy: 0.001)
    }

    /// Runs layout of the grid and its collection.
    private func layoutGrid(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }
}

#endif
