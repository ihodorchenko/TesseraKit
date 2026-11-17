//
//  TileLayoutEnginePlacementTests.swift
//  TesseraStartScreenTests
//
//  Tests of the pure "placement by coordinates" layer (D30–D31).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid" and
//  "Implementation deviations"; D30 (real holes), D31 (collisions —
//  a cascading push down; a row collapses only if nobody
//  occupies it) in docs/STATE.md.
//
//  The functions are pure: no UIKit loop, no store, no window. Covered here: slots, validity
//  checks, cell clamping, insertion/cascade, resize, removal,
//  collapsing empty rows, searching for free cells. The property test with random
//  operation sequences is in `TileLayoutEnginePlacementPropertyTests`,
//  the folder panel geometry is in `TileLayoutEngineFolderPlacementTests`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

// MARK: - Shared helpers for placement tests

/// A placement set item: `item("a", .small, 0, 2)` — row 0, column 2.
func placementItem(_ id: String, _ size: TesseraTileSize, _ row: Int, _ column: Int) -> TesseraTilePlacedItem {
    TesseraTilePlacedItem(id: id, size: size, cell: TesseraTileGridPlacement(row: row, column: column))
}

/// An item's cell in the set.
func placementCell(_ id: String, in placements: [TesseraTilePlacedItem]) -> TesseraTileGridPlacement? {
    placements.first(where: { $0.id == AnyHashable(id) })?.cell
}

/// The set's identifiers in array order.
func placementIDs(_ placements: [TesseraTilePlacedItem]) -> [AnyHashable] {
    placements.map(\.id)
}

final class TileLayoutEnginePlacementTests: XCTestCase {

    private let columns = 6

    // MARK: - slots

    /// Slots take cells as they are, without packing: holes remain.
    func testSlotsUseExplicitCellsWithoutPacking() {
        let placements = [
            placementItem("a", .small, 3, 5),
            placementItem("b", .medium, 10, 2),
        ]

        let slots = TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 10)

        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots[0], TesseraTileLayoutSlot(id: "a", size: .small, column: 5, row: 3, unit: 10))
        XCTAssertEqual(slots[1], TesseraTileLayoutSlot(id: "b", size: .medium, column: 2, row: 10, unit: 10))
    }

    /// Slots follow the order of the input array, not the reading order.
    func testSlotsKeepInputOrder() {
        let placements = [
            placementItem("late", .small, 9, 0),
            placementItem("early", .small, 0, 0),
        ]

        let slots = TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 1)

        XCTAssertEqual(slots.map(\.id), ["late", "early"])
    }

    /// A tile wider than the grid is skipped, as in `pack`.
    func testSlotsSkipTilesWiderThanGridLikePack() {
        let placements = [
            placementItem("w", .wide, 0, 0),
            placementItem("s", .small, 0, 2),
        ]

        let slots = TesseraTileLayoutEngine.slots(placements: placements, columns: 3, unit: 1)

        XCTAssertEqual(slots.map(\.id), ["s"])
    }

    /// With `fitting: true` a wide tile is clamped instead of skipped.
    func testSlotsFittingDegradesInsteadOfSkipping() {
        let placements = [placementItem("w", .wide, 0, 0), placementItem("l", .large, 4, 0)]

        let slots = TesseraTileLayoutEngine.slots(placements: placements, columns: 3, unit: 1, fitting: true)

        XCTAssertEqual(slots.map(\.size), [.medium, .medium])
    }

    /// Degenerate geometry gives an empty result.
    func testSlotsDegenerateGeometryIsEmpty() {
        let placements = [placementItem("a", .small, 0, 0)]

        XCTAssertTrue(TesseraTileLayoutEngine.slots(placements: placements, columns: 0, unit: 1).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.slots(placements: placements, columns: 6, unit: 0).isEmpty)
        XCTAssertTrue(TesseraTileLayoutEngine.slots(placements: [], columns: 6, unit: 1).isEmpty)
    }

    /// The layout matches the `pack` slots on a compact set: moving from the
    /// old API to the new one does not change the geometry.
    func testSlotsMatchPackForCompactLayout() {
        let items: [(id: AnyHashable, size: TesseraTileSize)] = [
            ("a", .medium), ("b", .small), ("c", .wide), ("d", .large), ("e", .small),
        ]
        let packed = TesseraTileLayoutEngine.pack(items: items, columns: columns, unit: 7)
        let placements = packed.map {
            TesseraTilePlacedItem(id: $0.id, size: $0.size, cell: TesseraTileGridPlacement(row: $0.row, column: $0.column))
        }

        XCTAssertEqual(TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 7), packed)
    }

    // MARK: - validate / hasOverlaps

    /// A valid set has no violators.
    func testValidateReturnsNothingForValidSet() {
        let placements = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .wide, 0, 2),
            placementItem("c", .small, 5, 5),
        ]

        XCTAssertTrue(TesseraTileLayoutEngine.validate(placements, columns: columns).isEmpty)
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// An overlap: both participants are named violators, in input order.
    func testValidateReportsBothSidesOfOverlap() {
        let placements = [
            placementItem("a", .medium, 0, 0),
            placementItem("free", .small, 4, 4),
            placementItem("b", .small, 1, 1),
        ]

        XCTAssertEqual(TesseraTileLayoutEngine.validate(placements, columns: columns), ["a", "b"])
        XCTAssertTrue(TesseraTileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// Going beyond the canvas and negative coordinates are violations, but not "overlaps".
    func testValidateReportsOutOfBounds() {
        let placements = [
            placementItem("right", .medium, 0, 5),
            placementItem("negRow", .small, -1, 0),
            placementItem("negCol", .small, 3, -1),
            placementItem("ok", .small, 2, 2),
        ]

        XCTAssertEqual(TesseraTileLayoutEngine.validate(placements, columns: columns), ["right", "negRow", "negCol"])
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// Touching along a border is not an overlap.
    func testTouchingEdgesAreNotOverlap() {
        let placements = [
            placementItem("a", .medium, 0, 0),
            placementItem("right", .medium, 0, 2),
            placementItem("below", .medium, 2, 0),
        ]

        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// With no columns all items are violators, and there are "no" overlaps.
    func testValidateWithZeroColumnsFlagsEverything() {
        let placements = [placementItem("a", .small, 0, 0)]

        XCTAssertEqual(TesseraTileLayoutEngine.validate(placements, columns: 0), ["a"])
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(placements, columns: 0))
    }

    // MARK: - clamped

    /// A negative row is raised to zero.
    func testClampedNegativeRowBecomesZero() {
        let cell = TesseraTileLayoutEngine.clamped(cell: TesseraTileGridPlacement(row: -3, column: 1), size: .small, columns: columns)

        XCTAssertEqual(cell, TesseraTileGridPlacement(row: 0, column: 1))
    }

    /// A cell that is too far right is shifted left to fit the tile's width.
    func testClampedShiftsLeftNeverRight() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.clamped(cell: TesseraTileGridPlacement(row: 2, column: 5), size: .medium, columns: columns),
            TesseraTileGridPlacement(row: 2, column: 4)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.clamped(cell: TesseraTileGridPlacement(row: 0, column: 4), size: .wide, columns: columns),
            TesseraTileGridPlacement(row: 0, column: 2)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.clamped(cell: TesseraTileGridPlacement(row: 0, column: -2), size: .small, columns: columns),
            TesseraTileGridPlacement(row: 0, column: 0)
        )
    }

    /// A valid cell does not change.
    func testClampedKeepsValidCell() {
        let cell = TesseraTileGridPlacement(row: 7, column: 2)

        XCTAssertEqual(TesseraTileLayoutEngine.clamped(cell: cell, size: .wide, columns: columns), cell)
    }

    /// On a narrow grid the clamped width is used: a large tile at 3 columns is 2.
    func testClampedUsesFittedWidthOnNarrowGrid() {
        let cell = TesseraTileLayoutEngine.clamped(cell: TesseraTileGridPlacement(row: 0, column: 3), size: .large, columns: 3)

        XCTAssertEqual(cell, TesseraTileGridPlacement(row: 0, column: 1))
    }

    /// With no columns the column is 0.
    func testClampedWithZeroColumnsPinsToColumnZero() {
        let cell = TesseraTileLayoutEngine.clamped(cell: TesseraTileGridPlacement(row: 1, column: 4), size: .small, columns: 0)

        XCTAssertEqual(cell, TesseraTileGridPlacement(row: 1, column: 0))
    }

    // MARK: - inserting: basic cases

    /// Inserting into an empty set — one item on the cell.
    func testInsertingIntoEmptySet() {
        let result = TesseraTileLayoutEngine.inserting(
            id: "a", size: .medium, at: TesseraTileGridPlacement(row: 4, column: 2), into: [], columns: columns
        )

        XCTAssertEqual(result, [placementItem("a", .medium, 4, 2)])
    }

    /// Inserting into free space moves nothing; the new item goes to the end.
    func testInsertingAtFreeCellKeepsOthersAndAppends() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .small, 0, 4)]

        let result = TesseraTileLayoutEngine.inserting(
            id: "n", size: .small, at: TesseraTileGridPlacement(row: 2, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(Array(result.prefix(2)), base)
        XCTAssertEqual(result.last, placementItem("n", .small, 2, 0))
        XCTAssertEqual(result.count, 3)
    }

    /// Inserting beyond all rows — on its own row, the hole in between remains.
    func testInsertingBelowAllRowsLeavesHole() {
        let base = [placementItem("a", .medium, 0, 0)]

        let result = TesseraTileLayoutEngine.inserting(
            id: "far", size: .small, at: TesseraTileGridPlacement(row: 40, column: 3), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("far", in: result), TesseraTileGridPlacement(row: 40, column: 3))
        XCTAssertEqual(placementCell("a", in: result), TesseraTileGridPlacement(row: 0, column: 0))
    }

    /// A cell that is too far right is shifted left before insertion.
    func testInsertingClampsTooRightCell() {
        let result = TesseraTileLayoutEngine.inserting(
            id: "w", size: .wide, at: TesseraTileGridPlacement(row: -2, column: 5), into: [], columns: columns
        )

        XCTAssertEqual(placementCell("w", in: result), TesseraTileGridPlacement(row: 0, column: 2))
    }

    // MARK: - inserting: pushing down

    /// A small tile under an inserted 2×2 goes down to the insertion's lower bound.
    func testInsertingPushesOverlappedTileDownToInsertionBottom() {
        let base = [placementItem("s", .small, 0, 0)]

        let result = TesseraTileLayoutEngine.inserting(
            id: "m", size: .medium, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("s", in: result), TesseraTileGridPlacement(row: 2, column: 0))
        XCTAssertEqual(placementCell("m", in: result), TesseraTileGridPlacement(row: 0, column: 0))
    }

    /// Cascade: a pushed tile pushes the next one, and so on.
    func testInsertingCascadesThroughStackedTiles() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("b", .small, 1, 0),
            placementItem("c", .small, 2, 0),
        ]

        let result = TesseraTileLayoutEngine.inserting(
            id: "m", size: .medium, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("a", in: result)?.row, 2)
        XCTAssertEqual(placementCell("b", in: result)?.row, 3)
        XCTAssertEqual(placementCell("c", in: result)?.row, 4)
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// A tile that did not overlap stays in place even below the pushed ones
    /// (a hole between them is allowed).
    func testInsertingDoesNotMoveTilesFarBelow() {
        let base = [placementItem("a", .small, 0, 0), placementItem("far", .small, 9, 0)]

        let result = TesseraTileLayoutEngine.inserting(
            id: "m", size: .medium, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("a", in: result)?.row, 2)
        XCTAssertEqual(placementCell("far", in: result)?.row, 9)
    }

    /// Holes above the insertion and neighbors without an overlap are not touched; nobody
    /// moves horizontally.
    func testInsertingKeepsUnaffectedTilesAndNeverMovesHorizontally() {
        let base = [
            placementItem("top", .small, 0, 0),
            placementItem("left", .medium, 3, 0),
            placementItem("hit", .small, 3, 3),
            placementItem("right", .small, 3, 5),
        ]

        let result = TesseraTileLayoutEngine.inserting(
            id: "m", size: .medium, at: TesseraTileGridPlacement(row: 3, column: 2), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("top", in: result), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(placementCell("left", in: result), TesseraTileGridPlacement(row: 3, column: 0))
        XCTAssertEqual(placementCell("right", in: result), TesseraTileGridPlacement(row: 3, column: 5))
        XCTAssertEqual(placementCell("hit", in: result), TesseraTileGridPlacement(row: 5, column: 3))
        for item in base {
            XCTAssertEqual(placementCell("\(item.id)", in: result)?.column, item.cell.column)
        }
    }

    /// A tall tile is pushed as a whole, and the tiles below it too.
    func testInsertingPushesTallTileAndItsNeighborsBelow() {
        let base = [
            placementItem("tall", .large, 0, 0),
            placementItem("under", .small, 4, 0),
        ]

        let result = TesseraTileLayoutEngine.inserting(
            id: "m", size: .medium, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("tall", in: result), TesseraTileGridPlacement(row: 2, column: 0))
        XCTAssertEqual(placementCell("under", in: result), TesseraTileGridPlacement(row: 6, column: 0))
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// The traversal order is the reading of the original positions: the left of two tiles
    /// in one row is processed earlier (a deterministic outcome).
    func testInsertingProcessesReadingOrderOfOriginalPositions() {
        // `wide` is to the right and earlier by index, but is read after `left`.
        let base = [
            placementItem("wide", .wide, 1, 2),
            placementItem("left", .small, 1, 0),
        ]

        let result = TesseraTileLayoutEngine.inserting(
            id: "m", size: .large, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        // The insertion rectangle is columns 0–3, rows 0–3. Both tiles go to 4.
        XCTAssertEqual(placementCell("left", in: result), TesseraTileGridPlacement(row: 4, column: 0))
        XCTAssertEqual(placementCell("wide", in: result), TesseraTileGridPlacement(row: 4, column: 2))
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    // MARK: - inserting: moving an existing item

    /// An existing item is moved: at its own index, with no collision with its
    /// former place.
    func testInsertingExistingIDMovesAndKeepsArrayIndex() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .small, 0, 3),
            placementItem("c", .small, 5, 0),
        ]

        let result = TesseraTileLayoutEngine.inserting(
            id: "a", size: .medium, at: TesseraTileGridPlacement(row: 0, column: 2), into: base, columns: columns
        )

        XCTAssertEqual(placementIDs(result), ["a", "b", "c"])
        XCTAssertEqual(placementCell("a", in: result), TesseraTileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("b", in: result), TesseraTileGridPlacement(row: 2, column: 3))
        XCTAssertEqual(result.count, 3)
    }

    /// A move with a new size: the resulting size is the one passed.
    func testInsertingExistingIDAppliesNewSize() {
        let base = [placementItem("a", .small, 0, 0)]

        let result = TesseraTileLayoutEngine.inserting(
            id: "a", size: .wide, at: TesseraTileGridPlacement(row: 1, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(result, [placementItem("a", .wide, 1, 0)])
    }

    // MARK: - inserting: special cases

    /// Folder creation: a 2×2 on the place of a small target tile pushes the neighbors down.
    func testFolderCreationAtSmallTargetBecomesMediumAndPushesNeighborsDown() {
        // The target is small (0,2); to the right and below are neighbors that the 2×2 will cover.
        let base = [
            placementItem("target", .small, 0, 2),
            placementItem("right", .small, 0, 3),
            placementItem("below", .small, 1, 2),
            placementItem("diag", .small, 1, 3),
            placementItem("untouched", .small, 0, 5),
        ]
        let withoutTarget = TesseraTileLayoutEngine.removing(id: "target", from: base)

        let result = TesseraTileLayoutEngine.inserting(
            id: "folder", size: .medium, at: TesseraTileGridPlacement(row: 0, column: 2),
            into: withoutTarget, columns: columns
        )

        XCTAssertEqual(placementCell("folder", in: result), TesseraTileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("right", in: result), TesseraTileGridPlacement(row: 2, column: 3))
        XCTAssertEqual(placementCell("below", in: result), TesseraTileGridPlacement(row: 2, column: 2))
        // The diagonal tile first hits the 2×2, then the already shifted `right`.
        XCTAssertEqual(placementCell("diag", in: result), TesseraTileGridPlacement(row: 3, column: 3))
        XCTAssertEqual(placementCell("untouched", in: result), TesseraTileGridPlacement(row: 0, column: 5))
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Taking a wide tile out into a cell that is too narrow: a shift left + pushing down.
    func testExtractingWideTileIntoNarrowCellClampsLeftAndPushes() {
        let base = [
            placementItem("a", .small, 0, 2),
            placementItem("b", .small, 0, 5),
        ]

        let result = TesseraTileLayoutEngine.inserting(
            id: "wide", size: .wide, at: TesseraTileGridPlacement(row: 0, column: 4), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("wide", in: result), TesseraTileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("a", in: result), TesseraTileGridPlacement(row: 2, column: 2))
        XCTAssertEqual(placementCell("b", in: result), TesseraTileGridPlacement(row: 2, column: 5))
    }

    /// A large tile at the right edge shifts left by 2 columns.
    func testInsertingLargeAtRightEdgeShiftsLeft() {
        let result = TesseraTileLayoutEngine.inserting(
            id: "l", size: .large, at: TesseraTileGridPlacement(row: 1, column: 5), into: [], columns: columns
        )

        XCTAssertEqual(placementCell("l", in: result), TesseraTileGridPlacement(row: 1, column: 2))
    }

    /// Fewer columns than the tile's width: the footprint is clamped, the tile does not vanish.
    func testInsertingWideIntoGridNarrowerThanTileUsesFittedFootprint() {
        let result = TesseraTileLayoutEngine.inserting(
            id: "w", size: .wide, at: TesseraTileGridPlacement(row: 0, column: 2), into: [placementItem("s", .small, 0, 0)],
            columns: 3
        )

        // Clamped width 2: column 2 → 1, a small tile at column 0 does not interfere.
        XCTAssertEqual(placementCell("w", in: result), TesseraTileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(placementCell("s", in: result), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(result.first(where: { $0.id == AnyHashable("w") })?.size, .wide)
        XCTAssertTrue(TesseraTileLayoutEngine.validate(result, columns: 3).isEmpty)
    }

    /// With no columns the input is returned as is.
    func testInsertingWithZeroColumnsReturnsInput() {
        let base = [placementItem("a", .small, 0, 0)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.inserting(
                id: "n", size: .small, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: 0
            ),
            base
        )
    }

    /// Idempotence: inserting an already valid placement onto its own cell.
    func testInsertingValidPlacementAtOwnCellChangesNothing() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .wide, 0, 2),
            placementItem("c", .small, 6, 3),
            placementItem("d", .large, 2, 0),
        ]

        for item in base {
            let result = TesseraTileLayoutEngine.inserting(
                id: item.id, size: item.size, at: item.cell, into: base, columns: columns
            )
            XCTAssertEqual(result, base, "moving \(item.id) onto its own cell changed the set")
        }
    }

    /// Determinism: one input — one output.
    func testInsertingIsDeterministic() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("b", .small, 0, 1),
            placementItem("c", .medium, 1, 0),
            placementItem("d", .small, 3, 0),
        ]

        let first = TesseraTileLayoutEngine.inserting(
            id: "m", size: .large, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )
        let second = TesseraTileLayoutEngine.inserting(
            id: "m", size: .large, at: TesseraTileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(first, columns: columns))
    }

    /// Overlaps in the input are also resolved: the result has no overlaps.
    func testInsertingResolvesPreExistingOverlapsInInput() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .medium, 1, 1)]

        let result = TesseraTileLayoutEngine.inserting(
            id: "n", size: .small, at: TesseraTileGridPlacement(row: 9, column: 0), into: base, columns: columns
        )

        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    // MARK: - resizing

    /// Growing in place: the anchor stays, there are no neighbors — nothing moves.
    func testResizingGrowsInPlaceKeepingAnchor() {
        let base = [placementItem("a", .small, 2, 1), placementItem("b", .small, 8, 0)]

        let result = TesseraTileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns)

        XCTAssertEqual(placementCell("a", in: result), TesseraTileGridPlacement(row: 2, column: 1))
        XCTAssertEqual(result.first?.size, .medium)
        XCTAssertEqual(placementCell("b", in: result), TesseraTileGridPlacement(row: 8, column: 0))
    }

    /// Growing at the right edge shifts the column left.
    func testResizingNearRightEdgeShiftsColumnLeft() {
        let base = [placementItem("a", .small, 0, 5)]

        XCTAssertEqual(
            placementCell("a", in: TesseraTileLayoutEngine.resizing(id: "a", to: .wide, in: base, columns: columns)),
            TesseraTileGridPlacement(row: 0, column: 2)
        )
        XCTAssertEqual(
            placementCell("a", in: TesseraTileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns)),
            TesseraTileGridPlacement(row: 0, column: 4)
        )
    }

    /// Growing pushes neighbors down in a cascade.
    func testResizingGrowthPushesNeighborsDownWithCascade() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("right", .small, 0, 1),
            placementItem("below", .small, 1, 0),
            placementItem("chain", .small, 2, 0),
        ]

        let result = TesseraTileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns)

        XCTAssertEqual(placementCell("right", in: result), TesseraTileGridPlacement(row: 2, column: 1))
        XCTAssertEqual(placementCell("below", in: result), TesseraTileGridPlacement(row: 2, column: 0))
        XCTAssertEqual(placementCell("chain", in: result), TesseraTileGridPlacement(row: 3, column: 0))
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Shrinking leaves a hole: nothing moves.
    func testResizingShrinkLeavesHoleAndMovesNothing() {
        let base = [
            placementItem("big", .large, 0, 0),
            placementItem("under", .small, 4, 0),
            placementItem("side", .small, 0, 4),
        ]

        let result = TesseraTileLayoutEngine.resizing(id: "big", to: .small, in: base, columns: columns)

        XCTAssertEqual(placementCell("big", in: result), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(result.first?.size, .small)
        XCTAssertEqual(placementCell("under", in: result), TesseraTileGridPlacement(row: 4, column: 0))
        XCTAssertEqual(placementCell("side", in: result), TesseraTileGridPlacement(row: 0, column: 4))
    }

    /// The same size — the set does not change; an unknown id — likewise.
    func testResizingSameSizeAndUnknownIDChangeNothing() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .small, 0, 2)]

        XCTAssertEqual(TesseraTileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns), base)
        XCTAssertEqual(TesseraTileLayoutEngine.resizing(id: "zzz", to: .large, in: base, columns: columns), base)
        XCTAssertEqual(TesseraTileLayoutEngine.resizing(id: "a", to: .large, in: base, columns: 0), base)
    }

    // MARK: - removing

    /// Removal leaves a hole, the others do not move.
    func testRemovingLeavesHole() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .small, 0, 2),
            placementItem("c", .small, 2, 0),
        ]

        let result = TesseraTileLayoutEngine.removing(id: "a", from: base)

        XCTAssertEqual(result, [placementItem("b", .small, 0, 2), placementItem("c", .small, 2, 0)])
    }

    /// An unknown id — the set is unchanged.
    func testRemovingUnknownIDChangesNothing() {
        let base = [placementItem("a", .small, 0, 0)]

        XCTAssertEqual(TesseraTileLayoutEngine.removing(id: "x", from: base), base)
    }

    // MARK: - collapsingEmptyRows

    /// A fully empty row collapses; the tiles below move up.
    func testCollapsingRemovesFullyEmptyRow() {
        let base = [placementItem("a", .small, 0, 0), placementItem("b", .small, 2, 3)]

        let result = TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        XCTAssertEqual(placementCell("a", in: result), TesseraTileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(placementCell("b", in: result), TesseraTileGridPlacement(row: 1, column: 3))
    }

    /// Rows covered by a tall tile do not collapse, even if nobody else
    /// is in them.
    func testCollapsingKeepsRowsCoveredByTallTiles() {
        let base = [
            placementItem("tall", .large, 0, 0),
            placementItem("s", .small, 0, 5),
            placementItem("t", .small, 3, 5),
        ]

        XCTAssertEqual(TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: columns), base)
    }

    /// A multi-row empty gap collapses entirely.
    func testCollapsingRemovesMultiRowGapEntirely() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .small, 7, 4),
            placementItem("c", .medium, 9, 0),
        ]

        let result = TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        // Rows 0–1, 7, 9–10 are covered; 2–6 and 8 are empty.
        XCTAssertEqual(placementCell("a", in: result)?.row, 0)
        XCTAssertEqual(placementCell("b", in: result)?.row, 2)
        XCTAssertEqual(placementCell("c", in: result)?.row, 3)
        XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Empty rows at the very top collapse too.
    func testCollapsingRemovesLeadingEmptyRows() {
        let base = [placementItem("a", .small, 4, 2), placementItem("b", .medium, 5, 0)]

        let result = TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        XCTAssertEqual(placementCell("a", in: result), TesseraTileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("b", in: result), TesseraTileGridPlacement(row: 1, column: 0))
    }

    /// Columns do not change, the array order is preserved, an empty set stays empty.
    func testCollapsingKeepsColumnsAndOrderAndHandlesEmptySet() {
        let base = [placementItem("z", .small, 5, 4), placementItem("a", .small, 0, 1)]

        let result = TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        XCTAssertEqual(placementIDs(result), ["z", "a"])
        XCTAssertEqual(result.map(\.cell.column), [4, 1])
        XCTAssertTrue(TesseraTileLayoutEngine.collapsingEmptyRows(in: [], columns: columns).isEmpty)
    }

    /// A 2×2 tile covering a row that is "empty" for the others keeps it.
    func testCollapsingWithRowCoveredOnlyByMediumKeepsAllRows() {
        let base = [
            placementItem("top", .small, 0, 0),
            placementItem("m", .medium, 1, 2),
            placementItem("low", .small, 3, 0),
        ]

        XCTAssertEqual(TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: columns), base)
    }

    /// The height of a large tile on a narrow grid is clamped: rows 2–3 are empty.
    func testCollapsingUsesFittedHeightOnNarrowGrid() {
        let base = [placementItem("l", .large, 0, 0), placementItem("s", .small, 4, 0)]

        let narrow = TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: 3)
        let wide = TesseraTileLayoutEngine.collapsingEmptyRows(in: base, columns: 6)

        XCTAssertEqual(placementCell("s", in: narrow)?.row, 2)
        XCTAssertEqual(placementCell("s", in: wide)?.row, 4)
    }

    // MARK: - newRowCell / firstFreeCell

    /// An empty set — row 0.
    func testNewRowCellOfEmptySetIsOrigin() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.newRowCell(size: .medium, columns: columns, placements: []),
            TesseraTileGridPlacement(row: 0, column: 0)
        )
    }

    /// A new row goes below the lowest bound, including tall tiles.
    func testNewRowCellIsBelowLastOccupiedRow() {
        let base = [placementItem("a", .small, 0, 0), placementItem("tall", .large, 2, 2)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.newRowCell(size: .small, columns: columns, placements: base),
            TesseraTileGridPlacement(row: 6, column: 0)
        )
    }

    /// The item being moved frees its place: the new row is computed without it.
    func testNewRowCellExcludingMovedTile() {
        let base = [placementItem("a", .small, 0, 0), placementItem("last", .medium, 5, 0)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.newRowCell(size: .medium, columns: columns, placements: base, excluding: "last"),
            TesseraTileGridPlacement(row: 1, column: 0)
        )
    }

    /// An empty set — the start of the grid.
    func testFirstFreeCellOfEmptySetIsOrigin() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .large, columns: columns, placements: []),
            TesseraTileGridPlacement(row: 0, column: 0)
        )
    }

    /// Finds the first hole from the top left.
    func testFirstFreeCellFindsHoleTopLeft() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("c", .small, 0, 2),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .small, columns: columns, placements: base),
            TesseraTileGridPlacement(row: 0, column: 1)
        )
    }

    /// A hole the tile does not fit into is skipped.
    func testFirstFreeCellSkipsHolesThatAreTooSmall() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("c", .small, 0, 2),
            placementItem("d", .small, 1, 1),
        ]

        // The hole (0,1) is a single cell: a 2×2 does not fit; the first suitable one is below.
        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .medium, columns: columns, placements: base),
            TesseraTileGridPlacement(row: 0, column: 3)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .wide, columns: columns, placements: base),
            TesseraTileGridPlacement(row: 1, column: 2)
        )
    }

    /// There is no free space among the tiles — a cell below the last row.
    func testFirstFreeCellFallsBackBelowEverything() {
        let base = [placementItem("a", .large, 0, 0), placementItem("b", .medium, 0, 4)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .large, columns: 4, placements: [placementItem("x", .large, 0, 0)]),
            TesseraTileGridPlacement(row: 4, column: 0)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .large, columns: columns, placements: base),
            TesseraTileGridPlacement(row: 4, column: 0)
        )
    }

    /// The item being moved frees its place.
    func testFirstFreeCellExcludingMovedTile() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .small, 0, 2)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.firstFreeCell(size: .medium, columns: columns, placements: base, excluding: "a"),
            TesseraTileGridPlacement(row: 0, column: 0)
        )
    }

    /// The found cell is always free: inserting into it moves nothing.
    func testFirstFreeCellInsertionNeverPushesAnything() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .wide, 0, 2),
            placementItem("c", .small, 2, 0),
            placementItem("d", .large, 3, 2),
        ]

        for size in TesseraTileSize.allCases {
            let cell = TesseraTileLayoutEngine.firstFreeCell(size: size, columns: columns, placements: base)
            let result = TesseraTileLayoutEngine.inserting(id: "n", size: size, at: cell, into: base, columns: columns)

            XCTAssertEqual(Array(result.prefix(base.count)), base, "size \(size)")
            XCTAssertEqual(placementCell("n", in: result), cell)
        }
    }

    // MARK: - fittingSize

    /// At 6 columns (D26) no D15 size is clamped.
    func testFittingSizeKeepsAllSizesAtSixColumns() {
        for size in TesseraTileSize.allCases {
            XCTAssertEqual(TesseraTileLayoutEngine.fittingSize(size, columns: 6), size)
            XCTAssertEqual(TesseraTileLayoutEngine.fittingSize(size, columns: 4), size)
        }
    }

    /// On a narrow grid the clamped width is always ≤ columns — the basis of `clamped`.
    func testFittingSizeAlwaysFitsWidthForClamping() {
        for columns in 1...6 {
            for size in TesseraTileSize.allCases {
                let fitted = TesseraTileLayoutEngine.fittingSize(size, columns: columns)
                XCTAssertLessThanOrEqual(fitted.unitColumns, columns)

                let cell = TesseraTileLayoutEngine.clamped(
                    cell: TesseraTileGridPlacement(row: 0, column: 99), size: size, columns: columns
                )
                XCTAssertEqual(cell.column + fitted.unitColumns, columns)
            }
        }
    }
}

#endif
