//
//  TileLayoutEnginePlacementPropertyTests.swift
//  TesseraStartScreenTests
//
//  Property test of the "placement by coordinates" layer (D30–D31): seeded
//  random sequences of `inserting` / `resizing` / `removing` /
//  `collapsingEmptyRows` at different grid widths. After every step the invariants are checked:
//  no overlaps, all footprints inside `[0, columns)`, identifiers are
//  unique; "untouched" tiles do not move horizontally, tile rows
//  above the insertion do not change, and pushing down only moves tiles down.
//
//  The generator is `TesseraTestSeededGenerator`: a run is reproducible. A failure
//  message contains the seed, the columns and the step number.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEnginePlacementPropertyTests: XCTestCase {

    // MARK: - Helpers

    /// A tile footprint (by its clamped size) for checks in the test.
    private struct Footprint {
        let row: Int
        let column: Int
        let width: Int
        let height: Int

        var bottom: Int { row + height }

        func overlaps(_ other: Footprint) -> Bool {
            row < other.bottom && other.row < bottom
                && column < other.column + other.width && other.column < column + width
        }
    }

    private func footprint(_ item: TesseraTilePlacedItem, columns: Int) -> Footprint {
        let fitted = TesseraTileLayoutEngine.fittingSize(item.size, columns: columns)
        return Footprint(
            row: item.cell.row,
            column: item.cell.column,
            width: fitted.unitColumns,
            height: fitted.unitRows
        )
    }

    /// General invariants of a valid set.
    private func assertValid(
        _ placements: [TesseraTilePlacedItem],
        columns: Int,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            TesseraTileLayoutEngine.validate(placements, columns: columns).isEmpty,
            "violators \(TesseraTileLayoutEngine.validate(placements, columns: columns)); \(context())",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(placements.map(\.id)).count,
            placements.count,
            "duplicate identifiers; \(context())",
            file: file,
            line: line
        )
    }

    /// Checks the insert/resize properties: what moves and where.
    ///
    /// - Parameters:
    ///   - before: The set before the operation (valid).
    ///   - after: The set after the operation.
    ///   - id: The identifier of the inserted item.
    ///   - columns: The column count.
    private func assertPushDownProperties(
        before: [TesseraTilePlacedItem],
        after: [TesseraTilePlacedItem],
        id: AnyHashable,
        columns: Int,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let inserted = after.first(where: { $0.id == id }) else {
            return XCTFail("the inserted item disappeared; \(context())", file: file, line: line)
        }
        let insertion = footprint(inserted, columns: columns)

        let others = before.filter { $0.id != id }
        XCTAssertEqual(
            after.filter { $0.id != id }.map(\.id),
            others.map(\.id),
            "the order of the others changed; \(context())",
            file: file,
            line: line
        )

        for old in others {
            guard let new = after.first(where: { $0.id == old.id }) else {
                XCTFail("item \(old.id) disappeared; \(context())", file: file, line: line)
                continue
            }
            XCTAssertEqual(new.size, old.size, "size of \(old.id); \(context())", file: file, line: line)
            XCTAssertEqual(new.cell.column, old.cell.column, "horizontal shift of \(old.id); \(context())", file: file, line: line)
            XCTAssertGreaterThanOrEqual(new.cell.row, old.cell.row, "\(old.id) moved up; \(context())", file: file, line: line)

            // Tiles entirely above the insertion do not change.
            if footprint(old, columns: columns).bottom <= insertion.row {
                XCTAssertEqual(new.cell, old.cell, "\(old.id) above the insertion moved; \(context())", file: file, line: line)
            }
        }
    }

    // MARK: - Property

    /// Random operation sequences preserve the invariants.
    func testRandomOperationSequencesKeepInvariants() {
        let columnChoices = [3, 4, 6, 6, 8]

        for seed in 1...40 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = columnChoices[generator.int(upperBound: columnChoices.count)]
            var placements: [TesseraTilePlacedItem] = []
            var nextID = 0

            for step in 0..<60 {
                let context = "seed \(seed), columns \(columns), step \(step)"
                let sizes = TesseraTileSize.allCases
                let size = sizes[generator.int(upperBound: sizes.count)]
                let cell = TesseraTileGridPlacement(
                    row: generator.int(upperBound: 14),
                    column: generator.int(upperBound: columns + 2)
                )

                switch generator.int(upperBound: 10) {
                case 0...3 where placements.count < 24:
                    let id = AnyHashable("n\(nextID)")
                    nextID += 1
                    let after = TesseraTileLayoutEngine.inserting(
                        id: id, size: size, at: cell, into: placements, columns: columns
                    )
                    assertPushDownProperties(
                        before: placements, after: after, id: id, columns: columns, context
                    )
                    // Determinism.
                    XCTAssertEqual(
                        after,
                        TesseraTileLayoutEngine.inserting(id: id, size: size, at: cell, into: placements, columns: columns),
                        context
                    )
                    placements = after

                case 4...5 where !placements.isEmpty:
                    let target = placements[generator.int(upperBound: placements.count)]
                    let after = TesseraTileLayoutEngine.inserting(
                        id: target.id, size: target.size, at: cell, into: placements, columns: columns
                    )
                    assertPushDownProperties(
                        before: placements, after: after, id: target.id, columns: columns, context
                    )
                    placements = after

                case 6...7 where !placements.isEmpty:
                    let target = placements[generator.int(upperBound: placements.count)]
                    let after = TesseraTileLayoutEngine.resizing(
                        id: target.id, to: size, in: placements, columns: columns
                    )
                    assertPushDownProperties(
                        before: placements, after: after, id: target.id, columns: columns, context
                    )
                    // The anchor stays: the same row, the column only moves left.
                    let resized = after.first(where: { $0.id == target.id })
                    XCTAssertEqual(resized?.cell.row, target.cell.row, context)
                    XCTAssertLessThanOrEqual(resized?.cell.column ?? .max, target.cell.column, context)
                    placements = after

                case 8 where !placements.isEmpty:
                    let target = placements[generator.int(upperBound: placements.count)]
                    let after = TesseraTileLayoutEngine.removing(id: target.id, from: placements)
                    XCTAssertEqual(after, placements.filter { $0.id != target.id }, context)
                    placements = after

                default:
                    let after = TesseraTileLayoutEngine.collapsingEmptyRows(in: placements, columns: columns)
                    assertCollapseProperties(before: placements, after: after, columns: columns, context)
                    placements = after
                }

                assertValid(placements, columns: columns, context)
            }
        }
    }

    /// Collapse properties: order/columns/sizes, rows only move up,
    /// the relative order of rows, idempotence and no empty rows.
    private func assertCollapseProperties(
        before: [TesseraTilePlacedItem],
        after: [TesseraTilePlacedItem],
        columns: Int,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(placementIDs(after), placementIDs(before), context(), file: file, line: line)
        for (old, new) in zip(before, after) {
            XCTAssertEqual(new.size, old.size, context(), file: file, line: line)
            XCTAssertEqual(new.cell.column, old.cell.column, context(), file: file, line: line)
            XCTAssertLessThanOrEqual(new.cell.row, old.cell.row, context(), file: file, line: line)
        }
        for lhs in before.indices {
            for rhs in before.indices where before[lhs].cell.row < before[rhs].cell.row {
                XCTAssertLessThan(after[lhs].cell.row, after[rhs].cell.row, context(), file: file, line: line)
            }
        }
        XCTAssertEqual(
            TesseraTileLayoutEngine.collapsingEmptyRows(in: after, columns: columns),
            after,
            "collapse is not idempotent; \(context())",
            file: file,
            line: line
        )

        // Every row from 0 to the bottom bound is covered.
        var covered = Set<Int>()
        var bottom = 0
        for item in after {
            let rect = footprint(item, columns: columns)
            for row in rect.row..<rect.bottom { covered.insert(row) }
            bottom = max(bottom, rect.bottom)
        }
        XCTAssertEqual(covered.count, bottom, "empty rows remained after the collapse; \(context())", file: file, line: line)
    }

    /// Inserting into a spot without overlaps changes nothing for the others (holes
    /// are preserved) — on random sets.
    func testInsertionIntoFreeCellLeavesEveryoneUntouched() {
        for seed in 100..<130 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = 6
            var placements: [TesseraTilePlacedItem] = []

            for index in 0..<12 {
                let size = TesseraTileSize.allCases[generator.int(upperBound: 4)]
                let cell = TesseraTileLayoutEngine.firstFreeCell(size: size, columns: columns, placements: placements)
                let after = TesseraTileLayoutEngine.inserting(
                    id: AnyHashable("i\(index)"), size: size, at: cell, into: placements, columns: columns
                )
                XCTAssertEqual(Array(after.prefix(placements.count)), placements, "seed \(seed), step \(index)")
                placements = after

                // Periodically create holes.
                if index % 3 == 2, let victim = placements.first {
                    placements = TesseraTileLayoutEngine.removing(id: victim.id, from: placements)
                }
            }
            XCTAssertFalse(TesseraTileLayoutEngine.hasOverlaps(placements, columns: columns), "seed \(seed)")
        }
    }

    /// Any valid set is unchanged when each of its items is inserted onto
    /// its own cell (idempotence on random data).
    func testSelfInsertionIsIdempotentOnRandomValidSets() {
        for seed in 200..<220 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = 6
            var placements: [TesseraTilePlacedItem] = []

            for index in 0..<10 {
                let size = TesseraTileSize.allCases[generator.int(upperBound: 4)]
                let cell = TesseraTileGridPlacement(row: generator.int(upperBound: 10), column: generator.int(upperBound: 6))
                placements = TesseraTileLayoutEngine.inserting(
                    id: AnyHashable("s\(index)"), size: size, at: cell, into: placements, columns: columns
                )
            }

            for item in placements {
                XCTAssertEqual(
                    TesseraTileLayoutEngine.inserting(
                        id: item.id, size: item.size, at: item.cell, into: placements, columns: columns
                    ),
                    placements,
                    "seed \(seed), \(item.id)"
                )
            }
        }
    }
}

#endif
