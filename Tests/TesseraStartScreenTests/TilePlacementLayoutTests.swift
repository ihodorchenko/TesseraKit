//
//  TilePlacementLayoutTests.swift
//  TesseraStartScreenTests
//
//  Layout by explicit cells: tiles land on their cells, holes remain
//  (D30). Design document: docs/STARTSCREEN-IOS-DESIGN.md §3
//  "Tile grid" and "Implementation deviations"; decisions D30–D33
//  in docs/STATE.md.
//
//  `TesseraTileCollectionViewLayout` is checked on a collection without a window and on
//  hand-built cell tables (`TesseraTileGridPlacementTable`):
//  - a snapshot with holes: tiles do not "fall" into a hole, the content height follows the
//    lowest occupied row, empty trailing rows do not count;
//  - fallback to order packing: no table, an incomplete one, an invalid one
//    (an overlap, going beyond the canvas, a negative cell) or one for another width —
//    the frames are exactly as before;
//  - the geometry key: a change of cells alone (or of the declared width alone)
//    recomputes the layout;
//  - an opened folder with holes below: rows below the band shift down by
//    the panel height and the gap with no repack, holes are preserved; the fallback to packing
//    keeps the former repack under the panel (D17/D18);
//  - RTL: cells are logical, the layout mirrors;
//  - a narrow grid: a large tile is clamped rather than skipped.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePlacementLayoutTests: XCTestCase {

    // MARK: - Helpers

    /// The pixel-alignment scale of the tests.
    private let scale: CGFloat = 2

    /// A layout on a collection without a window.
    private struct Harness {
        let layout: TesseraTileCollectionViewLayout
        let collectionView: UICollectionView
    }

    private func makeHarness(
        width: CGFloat = 390,
        columns: Int = 4,
        spacing: CGFloat = 8,
        rightToLeft: Bool = false
    ) -> Harness {
        let layout = TesseraTileCollectionViewLayout()
        layout.columns = columns
        layout.itemSpacing = spacing
        layout.displayScaleOverride = scale
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: width, height: 844),
            collectionViewLayout: layout
        )
        if rightToLeft {
            collectionView.semanticContentAttribute = .forceRightToLeft
        }
        return Harness(layout: layout, collectionView: collectionView)
    }

    /// The expected grid geometry: the same formulas as the layout's.
    private struct Geometry {
        let metrics: TesseraTileLayoutEngine.GridMetrics
        let left: CGFloat
        let top: CGFloat
        let rightToLeft: Bool

        init(width: CGFloat = 390, columns: Int = 4, spacing: CGFloat = 8, scale: CGFloat, rightToLeft: Bool = false) {
            let contentLeft = TesseraTileLayoutEngine.pixelRound(16, scale: scale)
            let contentRight = TesseraTileLayoutEngine.pixelRound(width - 16, scale: scale)
            metrics = TesseraTileLayoutEngine.gridMetrics(
                contentWidth: contentRight - contentLeft,
                columns: columns,
                spacing: spacing,
                scale: scale
            )!
            left = contentLeft + metrics.leading
            top = TesseraTileLayoutEngine.pixelRound(16, scale: scale)
            self.rightToLeft = rightToLeft
        }

        /// The row/column pitch: unit + gap.
        var pitch: CGFloat { metrics.unit + metrics.spacing }

        /// A tile frame on a cell (logical coordinates).
        func frame(_ cell: TesseraTileGridPlacement, size: TesseraTileSize) -> CGRect {
            let slot = TesseraTileLayoutSlot(id: "x", size: size, column: cell.column, row: cell.row, unit: metrics.unit)
            var rect = TesseraTileLayoutEngine.rect(
                for: slot,
                unit: metrics.unit,
                gap: metrics.spacing,
                origin: CGPoint(x: left, y: top)
            )
            if rightToLeft {
                let localX = rect.minX - left
                rect.origin.x = left + metrics.width - localX - rect.width
            }
            return rect
        }
    }

    private func small(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .small)) }
    private func medium(_ id: String) -> TesseraTileGridItem { .tile(tesseraTestTile(id, size: .medium)) }

    private func cell(_ row: Int, _ column: Int) -> TesseraTileGridPlacement {
        TesseraTileGridPlacement(row: row, column: column)
    }

    /// Frames of the set by index (the layout receives the set and the table, as from the grid).
    private func frames(
        _ harness: Harness,
        _ items: [TesseraTileGridItem],
        table: TesseraTileGridPlacementTable?
    ) throws -> [CGRect] {
        harness.layout.setItems(items, placements: table, reason: .items)
        return try items.indices.map { try XCTUnwrap(harness.layout.frame(forItemAt: $0), "frame \($0)") }
    }

    /// Placements of the set in `items` order — for the panel insertion index.
    private func placed(_ items: [TesseraTileGridItem], table: TesseraTileGridPlacementTable) -> [TesseraTilePlacedItem] {
        items.compactMap { item in
            guard !item.isFolderPanel, let cell = table.cells[item.id] else { return nil }
            return TesseraTilePlacedItem(id: item.id, size: item.size, cell: cell)
        }
    }

    private func assertFrames(
        _ lhs: [CGRect],
        _ rhs: [CGRect],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.count, rhs.count, message, file: file, line: line)
        for (index, pair) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(pair.0.minX, pair.1.minX, accuracy: 0.001, "\(message): x[\(index)]", file: file, line: line)
            XCTAssertEqual(pair.0.minY, pair.1.minY, accuracy: 0.001, "\(message): y[\(index)]", file: file, line: line)
            XCTAssertEqual(pair.0.width, pair.1.width, accuracy: 0.001, "\(message): w[\(index)]", file: file, line: line)
            XCTAssertEqual(pair.0.height, pair.1.height, accuracy: 0.001, "\(message): h[\(index)]", file: file, line: line)
        }
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 0.001 && intersection.height > 0.001
    }

    // MARK: - Holes

    /// Tiles land on their cells; a hole remains, nothing moves up into it.
    func testHolesStayAndTilesDoNotBackfill() throws {
        let items = [small("a"), small("b"), small("c")]
        let table = TesseraTileGridPlacementTable(
            cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(2, 1)],
            columns: 4
        )
        let harness = makeHarness()
        let result = try frames(harness, items, table: table)
        let g = Geometry(scale: scale)

        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        assertFrames(
            result,
            [
                g.frame(cell(0, 0), size: .small),
                g.frame(cell(0, 3), size: .small),
                g.frame(cell(2, 1), size: .small),
            ],
            "frames by cells"
        )
        XCTAssertEqual(result[2].minY - result[0].minY, 2 * g.pitch, accuracy: 0.001, "two empty rows above c")
        XCTAssertEqual(result[1].minX - result[0].minX, 3 * g.pitch, accuracy: 0.001, "two empty columns between a and b")

        // Without a table the same tiles would be packed tightly into the first row.
        let packed = try frames(makeHarness(), items, table: nil)
        XCTAssertEqual(packed[2].minY, packed[0].minY, accuracy: 0.001)
        XCTAssertGreaterThan(result[2].minY, packed[2].minY)
    }

    /// The content height is the lower bound of the lowest occupied row; empty
    /// trailing rows (a table of extra cells) add no height.
    func testContentHeightIsBottomOfLowestOccupiedRow() throws {
        let harness = makeHarness()
        let items = [small("a"), medium("b")]
        let table = TesseraTileGridPlacementTable(
            cells: ["a": cell(0, 0), "b": cell(3, 2), "ghost": cell(50, 0)],
            columns: 4
        )
        let result = try frames(harness, items, table: table)
        let lowest = result.map(\.maxY).max() ?? 0
        XCTAssertEqual(
            harness.layout.collectionViewContentSize.height,
            lowest + 16,
            accuracy: 0.001,
            "lowest occupied row + bottom inset"
        )
        XCTAssertLessThan(harness.layout.collectionViewContentSize.height, Geometry(scale: scale).top + 50 * Geometry(scale: scale).pitch)
    }

    /// A single tile deep down: the empty rows above it are preserved.
    func testLeadingEmptyRowsAreKept() throws {
        let harness = makeHarness()
        let result = try frames(
            harness,
            [small("a")],
            table: TesseraTileGridPlacementTable(cells: ["a": cell(5, 0)], columns: 4)
        )
        let g = Geometry(scale: scale)
        XCTAssertEqual(result[0].minY, g.top + 5 * g.pitch, accuracy: 0.001)
        XCTAssertEqual(harness.layout.collectionViewContentSize.height, result[0].maxY + 16, accuracy: 0.001)
    }

    /// A large tile on a narrow grid is clamped and not skipped; the footprint is computed by
    /// `fittingSize`, the hole under it remains.
    func testWideTileOnNarrowGridIsFittedNotSkipped() throws {
        let harness = makeHarness(columns: 2)
        let items: [TesseraTileGridItem] = [.tile(tesseraTestTile("w", size: .wide)), small("s")]
        let table = TesseraTileGridPlacementTable(cells: ["w": cell(0, 0), "s": cell(3, 1)], columns: 2)
        let result = try frames(harness, items, table: table)
        let g = Geometry(columns: 2, scale: scale)

        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        assertFrames(
            result,
            [g.frame(cell(0, 0), size: TesseraTileLayoutEngine.fittingSize(.wide, columns: 2)), g.frame(cell(3, 1), size: .small)],
            "a clamped tile and a small tile after the hole"
        )
    }

    // MARK: - Fallback to packing

    /// All kinds of an unusable table give exactly the former packing frames.
    func testFallbackToPackOverOrderKeepsLegacyFrames() throws {
        let items = [small("a"), small("b"), medium("c"), small("d")]
        let reference = try frames(makeHarness(), items, table: nil)

        let good: [AnyHashable: TesseraTileGridPlacement] = [
            "a": cell(0, 0), "b": cell(0, 3), "c": cell(3, 0), "d": cell(5, 3),
        ]
        var incomplete = good
        incomplete["d"] = nil
        var overlapping = good
        overlapping["b"] = cell(0, 0)
        var outside = good
        outside["b"] = cell(0, 4)
        var tooWide = good
        tooWide["c"] = cell(3, 3)
        var negative = good
        negative["a"] = cell(-1, 0)

        let cases: [(String, TesseraTileGridPlacementTable?)] = [
            ("no table", nil),
            ("empty table", TesseraTileGridPlacementTable(cells: [:], columns: 4)),
            ("incomplete", TesseraTileGridPlacementTable(cells: incomplete, columns: 4)),
            ("overlap", TesseraTileGridPlacementTable(cells: overlapping, columns: 4)),
            ("tile outside the canvas", TesseraTileGridPlacementTable(cells: outside, columns: 4)),
            ("a wide tile goes beyond the canvas", TesseraTileGridPlacementTable(cells: tooWide, columns: 4)),
            ("negative row", TesseraTileGridPlacementTable(cells: negative, columns: 4)),
            ("another canvas width", TesseraTileGridPlacementTable(cells: good, columns: 6)),
        ]
        for (name, table) in cases {
            let harness = makeHarness()
            let result = try frames(harness, items, table: table)
            XCTAssertFalse(harness.layout.usesExplicitPlacements, name)
            assertFrames(result, reference, name)
        }

        // Control: a valid full table gives a different picture.
        let harness = makeHarness()
        let explicit = try frames(harness, items, table: TesseraTileGridPlacementTable(cells: good, columns: 4))
        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        XCTAssertNotEqual(explicit[3].minY, reference[3].minY)
    }

    /// The canvas width is not declared (`nil`): the table is checked by `validate` only.
    func testTableWithoutDeclaredWidthIsValidatedOnGridWidth() throws {
        let items = [small("a"), small("b")]
        let harness = makeHarness()
        _ = try frames(
            harness,
            items,
            table: TesseraTileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(4, 1)], columns: nil)
        )
        XCTAssertTrue(harness.layout.usesExplicitPlacements)

        _ = try frames(
            harness,
            items,
            table: TesseraTileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(0, 4)], columns: nil)
        )
        XCTAssertFalse(harness.layout.usesExplicitPlacements, "column 4 is outside a 4-column canvas")
    }

    // MARK: - Geometry key

    /// A change of a single cell alone (composition, sizes and order the same) recomputes
    /// the layout; the same table again — the frames do not change.
    func testCellOnlyChangeInvalidatesGeometry() throws {
        let harness = makeHarness()
        let items = [small("a"), small("b")]
        let first = TesseraTileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(1, 1)], columns: 4)
        let second = TesseraTileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(4, 1)], columns: 4)

        let before = try frames(harness, items, table: first)
        let again = try frames(harness, items, table: first)
        assertFrames(again, before, "the same table — the same frames")

        let after = try frames(harness, items, table: second)
        let g = Geometry(scale: scale)
        XCTAssertEqual(after[1].minY - before[1].minY, 3 * g.pitch, accuracy: 0.001, "b moved down three rows")
        assertFrames([after[0]], [before[0]], "a did not move")
    }

    /// A change of the declared table width alone (the same cells) switches the layout
    /// between explicit cells and packing.
    func testDeclaredWidthChangeInvalidatesGeometry() throws {
        let harness = makeHarness()
        let items = [small("a"), small("b")]
        let cells: [AnyHashable: TesseraTileGridPlacement] = ["a": cell(0, 0), "b": cell(3, 2)]

        let explicit = try frames(harness, items, table: TesseraTileGridPlacementTable(cells: cells, columns: 4))
        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        let fallback = try frames(harness, items, table: TesseraTileGridPlacementTable(cells: cells, columns: 6))
        XCTAssertFalse(harness.layout.usesExplicitPlacements)
        XCTAssertNotEqual(explicit[1].minY, fallback[1].minY)
    }

    /// A change in the grid's column count makes the table foreign: fallback to packing without
    /// resubmitting the set.
    func testGridColumnsChangeMakesTableForeign() throws {
        let harness = makeHarness(columns: 4)
        let items = [small("a"), small("b")]
        let table = TesseraTileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(3, 2)], columns: 4)
        _ = try frames(harness, items, table: table)
        XCTAssertTrue(harness.layout.usesExplicitPlacements)

        harness.layout.columns = 6
        _ = harness.layout.frame(forItemAt: 0)
        XCTAssertFalse(harness.layout.usesExplicitPlacements)
    }

    // MARK: - Opened folder panel

    /// The set: a 2×2 folder with neighbors in the band and three tiles below with holes.
    private func panelScenario() -> (folder: TesseraTileFolder, items: [TesseraTileGridItem], table: TesseraTileGridPlacementTable) {
        let folder = tesseraTestFolder("f", tileCount: 6)
        let items: [TesseraTileGridItem] = [
            .folder(folder), small("s1"), small("s2"), small("x"), small("y"), medium("m"),
        ]
        let table = TesseraTileGridPlacementTable(
            cells: [
                "f": cell(0, 0), "s1": cell(0, 2), "s2": cell(1, 3),
                "x": cell(4, 0), "y": cell(7, 3), "m": cell(4, 2),
            ],
            columns: 4
        )
        return (folder, items, table)
    }

    /// A panel with explicit cells: the band and everything above stay in place, the rows below
    /// shift down by the panel height and the gap, the holes between them and under the panel
    /// are preserved (no repack).
    func testExpandedPanelShiftsRowsBelowWithoutRepack() throws {
        let scenario = panelScenario()
        let harness = makeHarness()
        let g = Geometry(scale: scale)

        let collapsed = try frames(harness, scenario.items, table: scenario.table)

        let panelIndex = try XCTUnwrap(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placed(scenario.items, table: scenario.table),
                columns: 4,
                expandedFolderID: scenario.folder.id
            )
        )
        var expandedItems = scenario.items
        expandedItems.insert(.folderContent(scenario.folder), at: panelIndex)
        let open = try frames(harness, expandedItems, table: scenario.table)
        XCTAssertTrue(harness.layout.usesExplicitPlacements)

        // Indexes of the base items in the opened set.
        func openFrame(_ baseIndex: Int) -> CGRect { open[baseIndex < panelIndex ? baseIndex : baseIndex + 1] }
        let panel = open[panelIndex]

        // The band (the 2×2 folder + s1 + s2) is rows 0–1, the panel starts at row 2.
        XCTAssertEqual(panel.minY, g.top + 2 * g.pitch, accuracy: 0.001)
        XCTAssertGreaterThan(panel.height, 0)
        for baseIndex in 0...2 {
            assertFrames([openFrame(baseIndex)], [collapsed[baseIndex]], "the band does not move: \(baseIndex)")
        }

        // x, y, m go below by the panel height and the gap; their relative position is preserved.
        let shift = panel.height + g.metrics.spacing
        for baseIndex in 3...5 {
            XCTAssertEqual(
                openFrame(baseIndex).minY - collapsed[baseIndex].minY,
                shift,
                accuracy: 0.001,
                "shift by the panel: \(baseIndex)"
            )
            XCTAssertEqual(openFrame(baseIndex).minX, collapsed[baseIndex].minX, accuracy: 0.001)
        }
        XCTAssertEqual(openFrame(4).minY - openFrame(3).minY, 3 * g.pitch, accuracy: 0.001, "the hole between x and y")
        XCTAssertEqual(openFrame(3).minY - panel.maxY, 2 * g.pitch + g.metrics.spacing, accuracy: 0.001, "two empty rows under the panel")

        // Nothing overlaps; the content height follows the lowest occupied row.
        for lhs in open.indices {
            for rhs in open.indices where rhs > lhs {
                XCTAssertFalse(overlaps(open[lhs], open[rhs]), "\(lhs) and \(rhs) overlap")
            }
        }
        XCTAssertEqual(
            harness.layout.collectionViewContentSize.height,
            open.map(\.maxY).max()! + 16,
            accuracy: 0.001
        )
    }

    /// The fallback to packing keeps the former repack under the panel: the first tile under
    /// the panel goes right below it, a gap lower (D17/D18).
    func testExpandedPanelFallbackKeepsLegacyRepack() throws {
        let scenario = panelScenario()
        let harness = makeHarness()

        let panelIndex = try XCTUnwrap(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: scenario.items,
                columns: 4,
                expandedFolderID: scenario.folder.id
            )
        )
        var expandedItems = scenario.items
        expandedItems.insert(.folderContent(scenario.folder), at: panelIndex)
        let open = try frames(harness, expandedItems, table: nil)
        XCTAssertFalse(harness.layout.usesExplicitPlacements)

        // By packing `m` (2×2) is the only tile below the band, and it
        // goes right below the panel.
        let panel = open[panelIndex]
        let mIndex = expandedItems.firstIndex { !$0.isFolderPanel && $0.id == AnyHashable("m") }!
        XCTAssertEqual(open[mIndex].minY, panel.maxY + 8, accuracy: 0.001)

        // An unusable table behaves the same way.
        let broken = TesseraTileGridPlacementTable(cells: ["f": cell(0, 0)], columns: 4)
        let fallback = try frames(harness, expandedItems, table: broken)
        XCTAssertFalse(harness.layout.usesExplicitPlacements)
        assertFrames(fallback, open, "an incomplete table — the former frames")
    }

    // MARK: - RTL

    /// Cells are logical: column 0 in RTL is the right edge of the grid; the layout
    /// mirrors, not the table.
    func testExplicitCellsAreMirroredInRightToLeft() throws {
        let items = [small("a"), small("b"), medium("c")]
        let table = TesseraTileGridPlacementTable(
            cells: ["a": cell(0, 0), "b": cell(0, 3), "c": cell(2, 1)],
            columns: 4
        )
        let ltr = try frames(makeHarness(), items, table: table)
        let harness = makeHarness(rightToLeft: true)
        let rtl = try frames(harness, items, table: table)
        let g = Geometry(scale: scale, rightToLeft: true)

        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        assertFrames(
            rtl,
            [
                g.frame(cell(0, 0), size: .small),
                g.frame(cell(0, 3), size: .small),
                g.frame(cell(2, 1), size: .medium),
            ],
            "mirrored frames"
        )
        XCTAssertEqual(rtl[0].maxX, g.left + g.metrics.width, accuracy: 0.001, "column 0 is the right edge")
        XCTAssertEqual(rtl[1].minX, g.left, accuracy: 0.001, "column 3 is the left edge")
        for index in items.indices {
            XCTAssertEqual(rtl[index].minY, ltr[index].minY, accuracy: 0.001, "rows are not mirrored")
            XCTAssertEqual(
                rtl[index].minX - g.left,
                g.metrics.width - (ltr[index].maxX - g.left),
                accuracy: 0.001,
                "mirror within the grid width"
            )
        }
    }
}

#endif
