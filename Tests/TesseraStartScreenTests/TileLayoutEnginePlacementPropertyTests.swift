//
//  TileLayoutEnginePlacementPropertyTests.swift
//  TesseraStartScreenTests
//
//  Property-тест слоя «размещение по координатам» (E14.2, D30–D31): seeded
//  случайные последовательности `inserting` / `resizing` / `removing` /
//  `collapsingEmptyRows` на разной ширине сетки. После каждого шага проверяются
//  инварианты: нет пересечений, все следы внутри `[0, columns)`, идентификаторы
//  уникальны; «незатронутые» плитки не двигаются по горизонтали, строки плиток
//  выше вставки не меняются, а выталкивание только опускает.
//
//  Генератор — `TesseraTestSeededGenerator`: прогон воспроизводим. Сообщение
//  о падении содержит зерно, колонки и номер шага.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEnginePlacementPropertyTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// След плитки (по ужатому размеру) для проверок в тесте.
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

    private func footprint(_ item: TilePlacedItem, columns: Int) -> Footprint {
        let fitted = TileLayoutEngine.fittingSize(item.size, columns: columns)
        return Footprint(
            row: item.cell.row,
            column: item.cell.column,
            width: fitted.unitColumns,
            height: fitted.unitRows
        )
    }

    /// Общие инварианты корректного набора.
    private func assertValid(
        _ placements: [TilePlacedItem],
        columns: Int,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            TileLayoutEngine.validate(placements, columns: columns).isEmpty,
            "нарушители \(TileLayoutEngine.validate(placements, columns: columns)); \(context())",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(placements.map(\.id)).count,
            placements.count,
            "дубли идентификаторов; \(context())",
            file: file,
            line: line
        )
    }

    /// Проверка свойств вставки/resize: что двигается и куда.
    ///
    /// - Parameters:
    ///   - before: Набор до операции (корректный).
    ///   - after: Набор после операции.
    ///   - id: Идентификатор вставленного элемента.
    ///   - columns: Число колонок.
    private func assertPushDownProperties(
        before: [TilePlacedItem],
        after: [TilePlacedItem],
        id: AnyHashable,
        columns: Int,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let inserted = after.first(where: { $0.id == id }) else {
            return XCTFail("вставленный элемент пропал; \(context())", file: file, line: line)
        }
        let insertion = footprint(inserted, columns: columns)

        let others = before.filter { $0.id != id }
        XCTAssertEqual(
            after.filter { $0.id != id }.map(\.id),
            others.map(\.id),
            "порядок остальных изменился; \(context())",
            file: file,
            line: line
        )

        for old in others {
            guard let new = after.first(where: { $0.id == old.id }) else {
                XCTFail("элемент \(old.id) пропал; \(context())", file: file, line: line)
                continue
            }
            XCTAssertEqual(new.size, old.size, "размер \(old.id); \(context())", file: file, line: line)
            XCTAssertEqual(new.cell.column, old.cell.column, "сдвиг \(old.id) по горизонтали; \(context())", file: file, line: line)
            XCTAssertGreaterThanOrEqual(new.cell.row, old.cell.row, "\(old.id) поднялся; \(context())", file: file, line: line)

            // Плитки целиком выше вставки не меняются.
            if footprint(old, columns: columns).bottom <= insertion.row {
                XCTAssertEqual(new.cell, old.cell, "\(old.id) выше вставки сдвинулся; \(context())", file: file, line: line)
            }
        }
    }

    // MARK: - Property

    /// Случайные последовательности операций сохраняют инварианты.
    func testRandomOperationSequencesKeepInvariants() {
        let columnChoices = [3, 4, 6, 6, 8]

        for seed in 1...40 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = columnChoices[generator.int(upperBound: columnChoices.count)]
            var placements: [TilePlacedItem] = []
            var nextID = 0

            for step in 0..<60 {
                let context = "seed \(seed), columns \(columns), шаг \(step)"
                let sizes = TileSize.allCases
                let size = sizes[generator.int(upperBound: sizes.count)]
                let cell = TileGridPlacement(
                    row: generator.int(upperBound: 14),
                    column: generator.int(upperBound: columns + 2)
                )

                switch generator.int(upperBound: 10) {
                case 0...3 where placements.count < 24:
                    let id = AnyHashable("n\(nextID)")
                    nextID += 1
                    let after = TileLayoutEngine.inserting(
                        id: id, size: size, at: cell, into: placements, columns: columns
                    )
                    assertPushDownProperties(
                        before: placements, after: after, id: id, columns: columns, context
                    )
                    // Детерминизм.
                    XCTAssertEqual(
                        after,
                        TileLayoutEngine.inserting(id: id, size: size, at: cell, into: placements, columns: columns),
                        context
                    )
                    placements = after

                case 4...5 where !placements.isEmpty:
                    let target = placements[generator.int(upperBound: placements.count)]
                    let after = TileLayoutEngine.inserting(
                        id: target.id, size: target.size, at: cell, into: placements, columns: columns
                    )
                    assertPushDownProperties(
                        before: placements, after: after, id: target.id, columns: columns, context
                    )
                    placements = after

                case 6...7 where !placements.isEmpty:
                    let target = placements[generator.int(upperBound: placements.count)]
                    let after = TileLayoutEngine.resizing(
                        id: target.id, to: size, in: placements, columns: columns
                    )
                    assertPushDownProperties(
                        before: placements, after: after, id: target.id, columns: columns, context
                    )
                    // Якорь остаётся: строка та же, колонка только влево.
                    let resized = after.first(where: { $0.id == target.id })
                    XCTAssertEqual(resized?.cell.row, target.cell.row, context)
                    XCTAssertLessThanOrEqual(resized?.cell.column ?? .max, target.cell.column, context)
                    placements = after

                case 8 where !placements.isEmpty:
                    let target = placements[generator.int(upperBound: placements.count)]
                    let after = TileLayoutEngine.removing(id: target.id, from: placements)
                    XCTAssertEqual(after, placements.filter { $0.id != target.id }, context)
                    placements = after

                default:
                    let after = TileLayoutEngine.collapsingEmptyRows(in: placements, columns: columns)
                    assertCollapseProperties(before: placements, after: after, columns: columns, context)
                    placements = after
                }

                assertValid(placements, columns: columns, context)
            }
        }
    }

    /// Свойства схлопывания: порядок/колонки/размеры, строки только вверх,
    /// относительный порядок строк, идемпотентность и отсутствие пустых строк.
    private func assertCollapseProperties(
        before: [TilePlacedItem],
        after: [TilePlacedItem],
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
            TileLayoutEngine.collapsingEmptyRows(in: after, columns: columns),
            after,
            "схлопывание неидемпотентно; \(context())",
            file: file,
            line: line
        )

        // Каждая строка от 0 до нижней границы покрыта.
        var covered = Set<Int>()
        var bottom = 0
        for item in after {
            let rect = footprint(item, columns: columns)
            for row in rect.row..<rect.bottom { covered.insert(row) }
            bottom = max(bottom, rect.bottom)
        }
        XCTAssertEqual(covered.count, bottom, "после схлопывания остались пустые строки; \(context())", file: file, line: line)
    }

    /// Вставка в место без пересечений ничего не меняет у остальных (дыры
    /// сохраняются) — на случайных наборах.
    func testInsertionIntoFreeCellLeavesEveryoneUntouched() {
        for seed in 100..<130 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = 6
            var placements: [TilePlacedItem] = []

            for index in 0..<12 {
                let size = TileSize.allCases[generator.int(upperBound: 4)]
                let cell = TileLayoutEngine.firstFreeCell(size: size, columns: columns, placements: placements)
                let after = TileLayoutEngine.inserting(
                    id: AnyHashable("i\(index)"), size: size, at: cell, into: placements, columns: columns
                )
                XCTAssertEqual(Array(after.prefix(placements.count)), placements, "seed \(seed), шаг \(index)")
                placements = after

                // Периодически создаём дыры.
                if index % 3 == 2, let victim = placements.first {
                    placements = TileLayoutEngine.removing(id: victim.id, from: placements)
                }
            }
            XCTAssertFalse(TileLayoutEngine.hasOverlaps(placements, columns: columns), "seed \(seed)")
        }
    }

    /// Любой корректный набор не меняется при вставке каждого своего элемента на
    /// его же ячейку (идемпотентность на случайных данных).
    func testSelfInsertionIsIdempotentOnRandomValidSets() {
        for seed in 200..<220 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = 6
            var placements: [TilePlacedItem] = []

            for index in 0..<10 {
                let size = TileSize.allCases[generator.int(upperBound: 4)]
                let cell = TileGridPlacement(row: generator.int(upperBound: 10), column: generator.int(upperBound: 6))
                placements = TileLayoutEngine.inserting(
                    id: AnyHashable("s\(index)"), size: size, at: cell, into: placements, columns: columns
                )
            }

            for item in placements {
                XCTAssertEqual(
                    TileLayoutEngine.inserting(
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
