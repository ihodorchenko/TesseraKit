//
//  TileLayoutEngineTests.swift
//  TesseraStartScreenTests
//
//  Tests for the pure tile grid layout (strict compactness).
//
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid"
//  (the unit formula, left-to-right top-to-bottom packing, unit coordinates) and
//  §14 "MVP refinements" (D15: four sizes: 1×1, 2×2, 4×2, 4×4).
//  This file covers packing **by order** (`pack`/`packCompact`): with explicit cells it is
//  a fallback path, the v1 → v2 migration and first launch; layout by explicit cells
//  with holes is checked in `TileLayoutEnginePlacement*Tests`.
//
//  The tests work only with the pure functions of `TesseraTileLayoutEngine`: no UIKit cycle,
//  no window and no collection. Random configurations are seeded, so a run is
//  reproducible. For every packing the "first free
//  position in top-to-bottom, left-to-right traversal" property and the strict compactness of the finished
//  layout are checked: no tile can be moved up/left, and there are no empty rows.
//  Collapse (`stabilize`) and the reflow after a tile is "dragged away" are checked
//  separately; this is a contract, not just an absence of overlaps.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEngineTests: XCTestCase {

    // MARK: - Helpers

    /// Checks the strict compactness contract of a packing.
    ///
    /// For each tile in `items` order:
    /// 1. the slot refers to the same tile and has the same size;
    /// 2. no earlier position (rows top to bottom, within a row
    ///    left to right) was free for its rectangle;
    /// 3. the position itself is free (no overlaps);
    /// 4. the tile does not exceed the column count.
    ///
    /// Then, on the **finished** layout rather than on placement order:
    /// 5. no tile can be moved up or left: if it is removed from
    ///    the grid, all earlier positions are occupied;
    /// 6. there are no empty rows: every row up to the last occupied one has a unit.
    ///
    /// - Parameters:
    ///   - items: The requested "identifier — size" pairs.
    ///   - slots: The packing result.
    ///   - columns: The grid column count.
    private func assertCompactPacking(
        items: [(id: AnyHashable, size: TesseraTileSize)],
        slots: [TesseraTileLayoutSlot],
        columns: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            slots.count,
            items.count,
            "All tiles must be packed",
            file: file,
            line: line
        )

        // The occupancy matrix is rebuilt from the already verified slots, so that
        // the check does not depend on the engine's internal matrix.
        var occupied: [[Bool]] = []

        func ensureRows(_ count: Int) {
            while occupied.count < count {
                occupied.append(Array(repeating: false, count: columns))
            }
        }

        func isFree(column: Int, row: Int, width: Int, height: Int) -> Bool {
            guard column >= 0, row >= 0, column + width <= columns else { return false }
            ensureRows(row + height)
            for currentRow in row..<(row + height) {
                for currentColumn in column..<(column + width)
                where occupied[currentRow][currentColumn] {
                    return false
                }
            }
            return true
        }

        func mark(column: Int, row: Int, width: Int, height: Int, value: Bool = true) {
            ensureRows(row + height)
            for currentRow in row..<(row + height) {
                for currentColumn in column..<(column + width) {
                    occupied[currentRow][currentColumn] = value
                }
            }
        }

        for (index, slot) in slots.enumerated() {
            guard items.indices.contains(index) else {
                XCTFail("More slots than tiles", file: file, line: line)
                return
            }

            XCTAssertEqual(slot.id, items[index].id, file: file, line: line)
            XCTAssertEqual(slot.size, items[index].size, file: file, line: line)

            let width = slot.unitColumns
            let height = slot.unitRows
            XCTAssertGreaterThan(width, 0, file: file, line: line)
            XCTAssertGreaterThan(height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(slot.column, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(slot.row, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                slot.column + width,
                columns,
                "Tile \(slot.id) extends beyond the grid",
                file: file,
                line: line
            )

            ensureRows(slot.row + height)

            // All positions the traversal visits before the assigned one must
            // be occupied, otherwise the engine would have chosen them.
            for row in 0...slot.row {
                let lastColumn = row == slot.row ? slot.column - 1 : columns - width
                guard lastColumn >= 0 else { continue }

                for column in 0...lastColumn {
                    XCTAssertFalse(
                        isFree(column: column, row: row, width: width, height: height),
                        "Tile \(slot.id) did not take the first free position",
                        file: file,
                        line: line
                    )
                }
            }

            XCTAssertTrue(
                isFree(column: slot.column, row: slot.row, width: width, height: height),
                "Tile \(slot.id) overlaps already packed tiles",
                file: file,
                line: line
            )
            mark(column: slot.column, row: slot.row, width: width, height: height)
        }

        // On the finished layout no tile can be moved up/left.
        for slot in slots {
            let width = slot.unitColumns
            let height = slot.unitRows
            ensureRows(slot.row + height)

            mark(
                column: slot.column,
                row: slot.row,
                width: width,
                height: height,
                value: false
            )

            for row in 0...slot.row {
                let lastColumn = row == slot.row ? slot.column - 1 : columns - width
                guard lastColumn >= 0 else { continue }

                for column in 0...lastColumn {
                    XCTAssertFalse(
                        isFree(column: column, row: row, width: width, height: height),
                        "Tile \(slot.id) can be moved up/left to (\(column), \(row))",
                        file: file,
                        line: line
                    )
                }
            }

            mark(column: slot.column, row: slot.row, width: width, height: height)
        }

        // No empty rows remain in the middle of the layout.
        let lastRow = slots.map { $0.row + $0.unitRows }.max() ?? 0
        for row in 0..<lastRow {
            XCTAssertTrue(
                occupied[row].contains(true),
                "Row \(row) is empty: the layout is not compact from top to bottom",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Boundaries

    /// An empty input gives an empty layout.
    func testEmptyItemsProduceEmptyLayout() {
        let slots = TesseraTileLayoutEngine.pack(items: [], columns: 4, unit: 64)
        XCTAssertTrue(slots.isEmpty)
    }

    /// A single small tile goes to the top left corner and takes one unit.
    func testSingleSmallTileOccupiesOrigin() throws {
        let slots = TesseraTileLayoutEngine.pack(
            items: [(id: AnyHashable("a"), size: TesseraTileSize.small)],
            columns: 4,
            unit: 64
        )

        XCTAssertEqual(slots.count, 1)
        let slot = try XCTUnwrap(slots.first)
        XCTAssertEqual(slot.id, AnyHashable("a"))
        XCTAssertEqual(slot.size, .small)
        XCTAssertEqual(slot.column, 0)
        XCTAssertEqual(slot.row, 0)
        XCTAssertEqual(slot.unitColumns, 1)
        XCTAssertEqual(slot.unitRows, 1)
        XCTAssertEqual(slot.unit, 64)
        XCTAssertEqual(slot.frame, CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(slot.unitFrame, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A single large tile takes the full width and four rows (D15: 4×4).
    func testSingleLargeTileOccupiesWholeWidth() throws {
        let slots = TesseraTileLayoutEngine.pack(
            items: [(id: AnyHashable("a"), size: TesseraTileSize.large)],
            columns: 4,
            unit: 50
        )

        let slot = try XCTUnwrap(slots.first)
        XCTAssertEqual(slot.column, 0)
        XCTAssertEqual(slot.row, 0)
        XCTAssertEqual(slot.unitColumns, 4)
        XCTAssertEqual(slot.unitRows, 4)
        XCTAssertEqual(slot.frame, CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    /// A tile wider than the grid is skipped: the grid does not distort sizes (D15).
    func testTileWiderThanGridIsSkipped() throws {
        let slots = TesseraTileLayoutEngine.pack(
            items: [
                (id: AnyHashable("wide"), size: TesseraTileSize.wide),
                (id: AnyHashable("small"), size: TesseraTileSize.small),
            ],
            columns: 3,
            unit: 40
        )

        XCTAssertEqual(slots.count, 1)
        let slot = try XCTUnwrap(slots.first)
        XCTAssertEqual(slot.id, AnyHashable("small"))
        XCTAssertEqual(slot.column, 0)
        XCTAssertEqual(slot.row, 0)
    }

    /// Degenerate geometry does not start packing.
    func testDegenerateGeometryProducesEmptyLayout() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("a"), size: TesseraTileSize.small),
        ]

        XCTAssertTrue(TesseraTileLayoutEngine.pack(items: items, columns: 0, unit: 64).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.pack(items: items, columns: -2, unit: 64).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 0).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: -10).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: .nan).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: .infinity).isEmpty)
    }

    // MARK: - Strict compactness

    /// A deterministic example: medium → wide → small.
    ///
    /// medium sits at (0,0), wide does not fit in the first two rows and goes to
    /// (0,2), and small later takes the free unit (2,0) above wide: the search
    /// starts from row zero every time. After packing no tile
    /// can be moved up/left.
    func testLaterTileFillsFreeSlotAboveWideTile() throws {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("small"), size: .small),
        ]
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 10)

        XCTAssertEqual(slots.map { $0.column }, [0, 0, 2])
        XCTAssertEqual(slots.map { $0.row }, [0, 2, 0])
        assertCompactPacking(items: items, slots: slots, columns: 4)
    }

    /// A hole remains only where no current tile fits, and
    /// disappears as soon as a tile of a suitable size appears.
    ///
    /// After medium(0,0), wide(0,2) and three small tiles, 15 units of 16 are occupied:
    /// only unit (3,1) is free. None of the current tiles fits into it, so
    /// there is nothing to shift; this is not a "genuine hole" of §3 but a trace of the sizes. The next
    /// small in a new packing takes exactly (3,1) and does not stay lower.
    func testOnlyUnfillableHoleRemainsAndNextSmallFillsIt() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("small-1"), size: .small),
            (id: AnyHashable("small-2"), size: .small),
            (id: AnyHashable("small-3"), size: .small),
        ]
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 10)

        assertCompactPacking(items: items, slots: slots, columns: 4)

        let occupiedUnits = slots.reduce(0) { partial, slot in
            partial + slot.unitColumns * slot.unitRows
        }
        // medium 4 + wide 8 + three small 3 = 15 units; the grid is occupied up to row 3
        // inclusive (16 units), so exactly one unit is free: (3,1).
        // The last small landed at (2,1): row 0 is full, and in row 1
        // columns 2 and 3 are free; the search takes the left one.
        XCTAssertEqual(occupiedUnits, 15)
        XCTAssertEqual(slots.last?.column, 2)
        XCTAssertEqual(slots.last?.row, 1)

        // Strict compactness: the new small takes the free unit above
        // rather than going into a new row.
        let extra = (id: AnyHashable("small-4"), size: TesseraTileSize.small)
        let extendedItems = items + [extra]
        let extendedSlots = TesseraTileLayoutEngine.pack(
            items: extendedItems,
            columns: 4,
            unit: 10
        )
        XCTAssertEqual(extendedSlots.last?.column, 3)
        XCTAssertEqual(extendedSlots.last?.row, 1)
        assertCompactPacking(items: extendedItems, slots: extendedSlots, columns: 4)
    }

    /// Random configurations (seeded): order, sizes, the first free
    /// position and the strict compactness of the finished layout.
    func testCompactPackingOnSeededRandomConfigurations() {
        for seed in 0..<32 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = [4, 6][generator.int(upperBound: 2)]
            let unit = CGFloat(20 + generator.int(upperBound: 61))
            let count = generator.int(upperBound: 14)

            let fittingSizes = TesseraTileSize.allCases.filter { $0.unitColumns <= columns }
            var items: [(id: AnyHashable, size: TesseraTileSize)] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                let size = fittingSizes[generator.int(upperBound: fittingSizes.count)]
                items.append((id: AnyHashable("tile-\(index)"), size: size))
            }

            let slots = TesseraTileLayoutEngine.pack(items: items, columns: columns, unit: unit)

            XCTAssertEqual(
                slots.map { $0.id },
                items.map { $0.id },
                "Slot order must match tile order (seed \(seed))"
            )
            XCTAssertTrue(
                slots.allSatisfy { $0.unit == unit },
                "The unit must reach every slot (seed \(seed))"
            )
            assertCompactPacking(items: items, slots: slots, columns: columns)
        }
    }

    /// Row overflow: 101 small tiles in 4 columns make 26 rows without
    /// overlaps; the last tile is at (0,25).
    func testRowOverflowGrowsGridWithoutOverlaps() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = (0..<101).map {
            (id: AnyHashable("tile-\($0)"), size: TesseraTileSize.small)
        }
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 8)

        XCTAssertEqual(slots.count, 101)
        assertCompactPacking(items: items, slots: slots, columns: 4)

        XCTAssertEqual(slots.last?.column, 0)
        XCTAssertEqual(slots.last?.row, 25)
        XCTAssertEqual(slots.map { $0.row }.max(), 25)
    }

    /// Wide rows (6 columns): wide/large are laid out without overlaps.
    func testSixColumnPackingHasNoOverlaps() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("wide-1"), size: .wide),
            (id: AnyHashable("wide-2"), size: .wide),
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("large"), size: .large),
            (id: AnyHashable("small"), size: .small),
        ]
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: 6, unit: 30)

        XCTAssertEqual(slots.count, items.count)
        assertCompactPacking(items: items, slots: slots, columns: 6)
    }

    // MARK: - Collapse and reflow

    /// Collapse lifts a "hanging" tile into a free unit above.
    ///
    /// The layout [medium at (0,0), small at (0,2)] is not compact: small hangs
    /// a row lower although there is a free unit to the right of medium. After
    /// the collapse small goes to (2,0), the topmost-leftmost position.
    func testStabilizeLiftsFloatingTileIntoFreeSlot() throws {
        let slots = [
            TesseraTileLayoutSlot(
                id: AnyHashable("medium"),
                size: .medium,
                column: 0,
                row: 0,
                unit: 10
            ),
            TesseraTileLayoutSlot(
                id: AnyHashable("small"),
                size: .small,
                column: 0,
                row: 2,
                unit: 10
            ),
        ]

        let compacted = TesseraTileLayoutEngine.stabilize(slots, columns: 4)

        XCTAssertEqual(compacted.count, 2)
        XCTAssertEqual(compacted.map { $0.id }, slots.map { $0.id })

        let small = try XCTUnwrap(compacted.last)
        XCTAssertEqual(small.column, 2)
        XCTAssertEqual(small.row, 0)

        // medium is already at the earliest position, so we leave it alone.
        XCTAssertEqual(compacted.first?.column, 0)
        XCTAssertEqual(compacted.first?.row, 0)

        // A single "hanging" tile also collapses to (0,0).
        let single = [
            TesseraTileLayoutSlot(
                id: AnyHashable("single"),
                size: .small,
                column: 2,
                row: 2,
                unit: 10
            ),
        ]
        let compactedSingle = TesseraTileLayoutEngine.stabilize(single, columns: 4)
        XCTAssertEqual(compactedSingle.first?.column, 0)
        XCTAssertEqual(compactedSingle.first?.row, 0)
    }

    /// Collapse shifts a tile left in the same row if there is room on the left.
    func testStabilizeMovesTileLeftInsideRow() throws {
        let slots = [
            TesseraTileLayoutSlot(
                id: AnyHashable("medium"),
                size: .medium,
                column: 0,
                row: 0,
                unit: 10
            ),
            TesseraTileLayoutSlot(
                id: AnyHashable("small"),
                size: .small,
                column: 3,
                row: 0,
                unit: 10
            ),
        ]

        let compacted = TesseraTileLayoutEngine.stabilize(slots, columns: 4)
        let small = try XCTUnwrap(compacted.last)

        XCTAssertEqual(small.column, 2)
        XCTAssertEqual(small.row, 0)
    }

    /// Collapse does not move an already compact layout: packing is its
    /// fixed point.
    func testStabilizeKeepsCompactPackingUnchanged() {
        let configurations: [[TesseraTileSize]] = [
            [.medium, .wide, .small],
            [.small, .medium, .small, .medium, .wide],
            [.large, .medium, .small, .small, .wide],
            [.small, .small, .wide, .medium, .medium, .large],
        ]

        for (index, sizes) in configurations.enumerated() {
            let items = sizes.enumerated().map { offset, size in
                (id: AnyHashable("tile-\(offset)"), size: size)
            }
            let slots = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 8)

            XCTAssertEqual(
                TesseraTileLayoutEngine.stabilize(slots, columns: 4),
                slots,
                "Packing #\(index) must be a fixed point of the collapse"
            )
        }
    }

    /// The public `pack` is a strictly compact packing: the layout and
    /// edit/drag go through it, so the visuals of the modes do not differ.
    func testPublicPackMatchesCompactImplementation() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("a"), size: .medium),
            (id: AnyHashable("b"), size: .small),
            (id: AnyHashable("c"), size: .wide),
            (id: AnyHashable("d"), size: .small),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 12),
            TesseraTileLayoutEngine.packCompact(items: items, columns: 4, unit: 12)
        )
    }

    /// Reflow after a tile is "dragged away": the lower tile moves up into
    /// the freed space, and no empty rows remain.
    func testRemovingTileLiftsLowerTileIntoVacatedSpace() {
        let medium = (id: AnyHashable("medium"), size: TesseraTileSize.medium)
        let wide = (id: AnyHashable("wide"), size: TesseraTileSize.wide)

        let before = TesseraTileLayoutEngine.pack(items: [medium, wide], columns: 4, unit: 10)
        XCTAssertEqual(before.map { $0.row }, [0, 2])

        // medium was dragged away: wide moves up to row 0.
        let after = TesseraTileLayoutEngine.pack(items: [wide], columns: 4, unit: 10)
        XCTAssertEqual(after.first?.row, 0)
        XCTAssertEqual(after.first?.column, 0)
        assertCompactPacking(items: [wide], slots: after, columns: 4)
    }

    // MARK: - Geometry changes

    /// Changing the unit does not touch unit coordinates: the layout does not depend on
    /// pixels (§3, "Layout model"). Rebuilding is now just
    /// `pack` of the same items with a different unit (`repack` was removed).
    func testPackWithOtherUnitKeepsUnitCoordinatesAndUpdatesUnit() throws {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("a"), size: .small),
            (id: AnyHashable("b"), size: .medium),
            (id: AnyHashable("c"), size: .wide),
        ]
        let original = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 64)
        let repacked = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 32)

        XCTAssertEqual(repacked.map { $0.id }, original.map { $0.id })
        XCTAssertEqual(repacked.map { $0.column }, original.map { $0.column })
        XCTAssertEqual(repacked.map { $0.row }, original.map { $0.row })
        XCTAssertEqual(repacked.map { $0.size }, original.map { $0.size })
        XCTAssertTrue(repacked.allSatisfy { $0.unit == 32 })

        let originalWidth = try XCTUnwrap(original.first?.frame.width)
        let repackedWidth = try XCTUnwrap(repacked.first?.frame.width)
        XCTAssertEqual(repackedWidth, originalWidth / 2, accuracy: 1e-9)
    }

    /// Changing the column count packs the same items with the new geometry.
    func testPackWithColumnsChangeProducesValidLayout() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("small"), size: .small),
        ]
        let repacked = TesseraTileLayoutEngine.pack(items: items, columns: 6, unit: 40)

        XCTAssertEqual(repacked.count, items.count)
        XCTAssertEqual(repacked.map { $0.id }, items.map { $0.id })
        assertCompactPacking(items: items, slots: repacked, columns: 6)
    }

    // MARK: - Unit formula

    /// `unit = (screenWidth − gaps × (N − 1)) / N` (§3).
    func testUnitFormula() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.unit(screenWidth: 320, columns: 4, gaps: 8),
            74,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.unit(screenWidth: 320, columns: 6, gaps: 8),
            (320 - 40) / 6,
            accuracy: 1e-9
        )
    }

    /// Defensive cases of the unit formula: a negative gap gives 0, a degenerate
    /// width gives 0, non-finite values give 0.
    func testUnitClampsDegenerateInput() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.unit(screenWidth: 320, columns: 4, gaps: -8),
            80,
            accuracy: 1e-9
        )
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 320, columns: 0, gaps: 8), 0)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: -320, columns: 4, gaps: 8), 0)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 20, columns: 4, gaps: 10), 0)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: .nan, columns: 4, gaps: 0), 0)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 320, columns: 4, gaps: .nan), 0)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: .infinity, columns: 4, gaps: 0), 0)
    }

    // MARK: - Geometry in points

    /// Inner gaps are part of a tile's frame, outer ones are not (§3).
    func testRectAppliesGapAndOrigin() {
        let slot = TesseraTileLayoutSlot(
            id: AnyHashable("a"),
            size: .medium,
            column: 2,
            row: 1,
            unit: 50
        )

        let rect = TesseraTileLayoutEngine.rect(
            for: slot,
            unit: nil,
            gap: 10,
            origin: CGPoint(x: 5, y: 7)
        )

        XCTAssertEqual(rect, CGRect(x: 125, y: 67, width: 110, height: 110))
    }

    /// `unit: nil` takes the unit from the slot, and a negative gap is zeroed.
    func testRectUsesSlotUnitAndClampsNegativeGap() {
        let slot = TesseraTileLayoutSlot(
            id: AnyHashable("a"),
            size: .small,
            column: 1,
            row: 2,
            unit: 40
        )

        XCTAssertEqual(
            TesseraTileLayoutEngine.rect(for: slot, gap: 0),
            CGRect(x: 40, y: 80, width: 40, height: 40)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rect(for: slot, gap: -12),
            CGRect(x: 40, y: 80, width: 40, height: 40)
        )
    }

    /// A non-finite/non-positive unit and an empty footprint give `.zero`.
    func testRectFallsBackToZeroForDegenerateUnit() {
        let slot = TesseraTileLayoutSlot(
            id: AnyHashable("a"),
            size: .wide,
            column: 0,
            row: 0,
            unit: 25
        )

        XCTAssertEqual(TesseraTileLayoutEngine.rect(for: slot, unit: 0), .zero)
        XCTAssertEqual(TesseraTileLayoutEngine.rect(for: slot, unit: -10), .zero)
        XCTAssertEqual(TesseraTileLayoutEngine.rect(for: slot, unit: .nan), .zero)
    }

    /// A slot's "raw" frame is also protected from a degenerate unit.
    func testSlotFrameFallsBackToZeroForDegenerateUnit() {
        let zeroUnit = TesseraTileLayoutSlot(
            id: AnyHashable("a"),
            size: .medium,
            column: 2,
            row: 1,
            unit: 0
        )
        XCTAssertEqual(zeroUnit.frame, .zero)

        let nanUnit = TesseraTileLayoutSlot(
            id: AnyHashable("a"),
            size: .medium,
            column: 2,
            row: 1,
            unit: .nan
        )
        XCTAssertEqual(nanUnit.frame, .zero)
    }

    // MARK: - Pixel alignment

    /// 393 pt without 16 pt margins: the "raw" unit 84.25, aligned down, is 84 at
    /// 2× and 3×; at 390 pt, 83.5 stays at 2× and becomes 83⅓ at 3×.
    func testUnitWithScaleFloorsToPixelGrid() {
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8), 84.25, accuracy: 1e-9)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8, scale: 3), 84, accuracy: 1e-9)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8, scale: 2), 84, accuracy: 1e-9)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 358, columns: 4, gaps: 8, scale: 2), 83.5, accuracy: 1e-9)
        XCTAssertEqual(
            TesseraTileLayoutEngine.unit(screenWidth: 358, columns: 4, gaps: 8, scale: 3),
            250.0 / 3.0,
            accuracy: 1e-9
        )
    }

    /// A zero, negative and non-finite scale means no alignment;
    /// degenerate geometry still gives 0.
    func testUnitWithScaleIgnoresInvalidScale() {
        for scale in [CGFloat(0), -2, .nan, .infinity] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8, scale: scale),
                84.25,
                accuracy: 1e-9,
                "Scale \(scale)"
            )
        }
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 20, columns: 4, gaps: 10, scale: 3), 0)
        XCTAssertEqual(TesseraTileLayoutEngine.unit(screenWidth: 361, columns: 0, gaps: 8, scale: 3), 0)
    }

    /// Grid geometry: the unit is rounded down to a pixel, the gap to the nearest pixel,
    /// and the remainder is split equally between the margins (the left one rounded down to a pixel).
    func testGridMetricsCentersRemainder() throws {
        let metrics = try XCTUnwrap(
            TesseraTileLayoutEngine.gridMetrics(contentWidth: 361, columns: 4, spacing: 8, scale: 3)
        )
        XCTAssertEqual(metrics.unit, 84, accuracy: 1e-9)
        XCTAssertEqual(metrics.spacing, 8, accuracy: 1e-9)
        XCTAssertEqual(metrics.width, 360, accuracy: 1e-9)
        XCTAssertEqual(metrics.leading, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.columnOffset(3), 1.0 / 3.0 + 3 * 92, accuracy: 1e-9)

        // A fractional gap lands on a pixel: 8.2 at 2× becomes 8.0.
        let fractional = try XCTUnwrap(
            TesseraTileLayoutEngine.gridMetrics(contentWidth: 361, columns: 4, spacing: 8.2, scale: 2)
        )
        XCTAssertEqual(fractional.spacing, 8, accuracy: 1e-9)

        // Without a scale, the exact §3 formula, with no remainder.
        let exact = try XCTUnwrap(
            TesseraTileLayoutEngine.gridMetrics(contentWidth: 361, columns: 4, spacing: 8, scale: 0)
        )
        XCTAssertEqual(exact.unit, 84.25, accuracy: 1e-9)
        XCTAssertEqual(exact.leading, 0)

        XCTAssertNil(TesseraTileLayoutEngine.gridMetrics(contentWidth: 0, columns: 4, spacing: 8, scale: 3))
        XCTAssertNil(TesseraTileLayoutEngine.gridMetrics(contentWidth: 361, columns: 0, spacing: 8, scale: 3))
    }

    // MARK: - Folder band

    /// The lower bound of the folder band by unit packing.
    ///
    /// - Parameters:
    ///   - items: "Identifier — size" pairs.
    ///   - folderID: The folder identifier.
    ///   - columns: The column count.
    /// - Returns: The first row after the band.
    private func bandEnd(
        _ items: [(id: AnyHashable, size: TesseraTileSize)],
        folderID: AnyHashable,
        columns: Int = 4
    ) throws -> Int {
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: columns, unit: 1)
        let folderSlot = try XCTUnwrap(slots.first { $0.id == folderID })
        return TesseraTileLayoutEngine.folderBandEndRow(for: folderSlot, in: slots)
    }

    /// `[folder 2×2, small, small, 2×2]`: the 2×2 in rows 1–2 extends the band
    /// to row 3.
    func testFolderBandExtendsOverStepTile() throws {
        let end = try bandEnd(
            [
                (id: AnyHashable("f"), size: .medium),
                (id: AnyHashable("s1"), size: .small),
                (id: AnyHashable("s2"), size: .small),
                (id: AnyHashable("m"), size: .medium),
            ],
            folderID: "f"
        )
        XCTAssertEqual(end, 3)
    }

    /// `[folder small, 2×2]`: the 2×2 in rows 0–1 extends the band to row 2.
    func testFolderBandExtendsOverTallerNeighbour() throws {
        let end = try bandEnd(
            [(id: AnyHashable("f"), size: .small), (id: AnyHashable("m"), size: .medium)],
            folderID: "f"
        )
        XCTAssertEqual(end, 2)
    }

    /// The extension is iterative: a "staircase" of 2×2 tiles catches the next tile.
    ///
    /// 4 columns: folder small (0,0), s (1,0), m1 2×2 (2,0)–(3,1), m2 2×2
    /// (0,1)–(1,2), m3 2×2 (2,2)–(3,3): the band goes 0 → 2 (m1, m2) → 3 (m2) → 4 (m3).
    func testFolderBandExpandsToFixedPoint() throws {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            (id: AnyHashable("f"), size: .small),
            (id: AnyHashable("s"), size: .small),
            (id: AnyHashable("m1"), size: .medium),
            (id: AnyHashable("m2"), size: .medium),
            (id: AnyHashable("m3"), size: .medium),
        ]
        let slots = TesseraTileLayoutEngine.pack(items: items, columns: 4, unit: 1)
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        XCTAssertEqual(byID["m1"].map { [$0.column, $0.row] }, [2, 0])
        XCTAssertEqual(byID["m2"].map { [$0.column, $0.row] }, [0, 1])
        XCTAssertEqual(byID["m3"].map { [$0.column, $0.row] }, [2, 2])

        XCTAssertEqual(try bandEnd(items, folderID: "f"), 4)
    }

    /// Neighbors in the folder's rows that do not extend lower do not extend the band; a tile
    /// entirely below does not either.
    func testFolderBandKeepsFolderRowsWhenNothingSticksOut() throws {
        let end = try bandEnd(
            [
                (id: AnyHashable("f"), size: .medium),
                (id: AnyHashable("s1"), size: .small),
                (id: AnyHashable("s2"), size: .small),
                (id: AnyHashable("s3"), size: .small),
                (id: AnyHashable("w"), size: .wide),
            ],
            folderID: "f"
        )
        XCTAssertEqual(end, 2)
    }
}

#endif
