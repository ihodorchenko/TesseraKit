//
//  TileLayoutEnginePlacementTests.swift
//  TesseraStartScreenTests
//
//  Тесты чистого слоя «размещение по координатам» (E14.2, D30–D31).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка» и
//  «Отступления реализации (E14)»; D30 (настоящие пустоты), D31 (коллизии —
//  выталкивание вниз каскадом; строка схлопывается, только если её не занимает
//  никто) в docs/STATE.md.
//
//  Функции чистые: ни UIKit-цикла, ни хранилища, ни окна. Здесь — слоты, проверка
//  корректности, ограничение ячейки, вставка/каскад, resize, удаление,
//  схлопывание пустых строк, поиск свободных ячеек. Property-тест со случайными
//  последовательностями операций — в `TileLayoutEnginePlacementPropertyTests`,
//  геометрия панели папки — в `TileLayoutEngineFolderPlacementTests`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

// MARK: - Общие средства тестов размещений

/// Элемент набора размещений: `item("a", .small, 0, 2)` — строка 0, колонка 2.
func placementItem(_ id: String, _ size: TileSize, _ row: Int, _ column: Int) -> TilePlacedItem {
    TilePlacedItem(id: id, size: size, cell: TileGridPlacement(row: row, column: column))
}

/// Ячейка элемента в наборе.
func placementCell(_ id: String, in placements: [TilePlacedItem]) -> TileGridPlacement? {
    placements.first(where: { $0.id == AnyHashable(id) })?.cell
}

/// Идентификаторы набора в порядке массива.
func placementIDs(_ placements: [TilePlacedItem]) -> [AnyHashable] {
    placements.map(\.id)
}

final class TileLayoutEnginePlacementTests: XCTestCase {

    private let columns = 6

    // MARK: - slots

    /// Слоты берут ячейки как есть, без упаковки: дыры остаются.
    func testSlotsUseExplicitCellsWithoutPacking() {
        let placements = [
            placementItem("a", .small, 3, 5),
            placementItem("b", .medium, 10, 2),
        ]

        let slots = TileLayoutEngine.slots(placements: placements, columns: columns, unit: 10)

        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots[0], TileLayoutSlot(id: "a", size: .small, column: 5, row: 3, unit: 10))
        XCTAssertEqual(slots[1], TileLayoutSlot(id: "b", size: .medium, column: 2, row: 10, unit: 10))
    }

    /// Слоты идут в порядке входного массива, а не в порядке чтения.
    func testSlotsKeepInputOrder() {
        let placements = [
            placementItem("late", .small, 9, 0),
            placementItem("early", .small, 0, 0),
        ]

        let slots = TileLayoutEngine.slots(placements: placements, columns: columns, unit: 1)

        XCTAssertEqual(slots.map(\.id), ["late", "early"])
    }

    /// Плитка шире сетки пропускается, как в `pack`.
    func testSlotsSkipTilesWiderThanGridLikePack() {
        let placements = [
            placementItem("w", .wide, 0, 0),
            placementItem("s", .small, 0, 2),
        ]

        let slots = TileLayoutEngine.slots(placements: placements, columns: 3, unit: 1)

        XCTAssertEqual(slots.map(\.id), ["s"])
    }

    /// С `fitting: true` широкая плитка ужимается вместо пропуска.
    func testSlotsFittingDegradesInsteadOfSkipping() {
        let placements = [placementItem("w", .wide, 0, 0), placementItem("l", .large, 4, 0)]

        let slots = TileLayoutEngine.slots(placements: placements, columns: 3, unit: 1, fitting: true)

        XCTAssertEqual(slots.map(\.size), [.medium, .medium])
    }

    /// Вырожденная геометрия — пустой результат.
    func testSlotsDegenerateGeometryIsEmpty() {
        let placements = [placementItem("a", .small, 0, 0)]

        XCTAssertTrue(TileLayoutEngine.slots(placements: placements, columns: 0, unit: 1).isEmpty)
        XCTAssertTrue(TileLayoutEngine.slots(placements: placements, columns: 6, unit: 0).isEmpty)
        XCTAssertTrue(TileLayoutEngine.slots(placements: [], columns: 6, unit: 1).isEmpty)
    }

    /// Раскладка совпадает со слотами `pack` на компактном наборе: переход со
    /// старого API на новый не меняет геометрию.
    func testSlotsMatchPackForCompactLayout() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            ("a", .medium), ("b", .small), ("c", .wide), ("d", .large), ("e", .small),
        ]
        let packed = TileLayoutEngine.pack(items: items, columns: columns, unit: 7)
        let placements = packed.map {
            TilePlacedItem(id: $0.id, size: $0.size, cell: TileGridPlacement(row: $0.row, column: $0.column))
        }

        XCTAssertEqual(TileLayoutEngine.slots(placements: placements, columns: columns, unit: 7), packed)
    }

    // MARK: - validate / hasOverlaps

    /// Корректный набор — без нарушителей.
    func testValidateReturnsNothingForValidSet() {
        let placements = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .wide, 0, 2),
            placementItem("c", .small, 5, 5),
        ]

        XCTAssertTrue(TileLayoutEngine.validate(placements, columns: columns).isEmpty)
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// Пересечение: нарушителями названы оба участника, порядок — по входу.
    func testValidateReportsBothSidesOfOverlap() {
        let placements = [
            placementItem("a", .medium, 0, 0),
            placementItem("free", .small, 4, 4),
            placementItem("b", .small, 1, 1),
        ]

        XCTAssertEqual(TileLayoutEngine.validate(placements, columns: columns), ["a", "b"])
        XCTAssertTrue(TileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// Выход за холст и отрицательные координаты — нарушения, но не «пересечения».
    func testValidateReportsOutOfBounds() {
        let placements = [
            placementItem("right", .medium, 0, 5),
            placementItem("negRow", .small, -1, 0),
            placementItem("negCol", .small, 3, -1),
            placementItem("ok", .small, 2, 2),
        ]

        XCTAssertEqual(TileLayoutEngine.validate(placements, columns: columns), ["right", "negRow", "negCol"])
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// Соприкосновение по границе не пересечение.
    func testTouchingEdgesAreNotOverlap() {
        let placements = [
            placementItem("a", .medium, 0, 0),
            placementItem("right", .medium, 0, 2),
            placementItem("below", .medium, 2, 0),
        ]

        XCTAssertFalse(TileLayoutEngine.hasOverlaps(placements, columns: columns))
    }

    /// Без колонок все элементы — нарушители, пересечений «нет».
    func testValidateWithZeroColumnsFlagsEverything() {
        let placements = [placementItem("a", .small, 0, 0)]

        XCTAssertEqual(TileLayoutEngine.validate(placements, columns: 0), ["a"])
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(placements, columns: 0))
    }

    // MARK: - clamped

    /// Отрицательная строка поднимается до нуля.
    func testClampedNegativeRowBecomesZero() {
        let cell = TileLayoutEngine.clamped(cell: TileGridPlacement(row: -3, column: 1), size: .small, columns: columns)

        XCTAssertEqual(cell, TileGridPlacement(row: 0, column: 1))
    }

    /// Слишком правая ячейка сдвигается влево под ширину плитки.
    func testClampedShiftsLeftNeverRight() {
        XCTAssertEqual(
            TileLayoutEngine.clamped(cell: TileGridPlacement(row: 2, column: 5), size: .medium, columns: columns),
            TileGridPlacement(row: 2, column: 4)
        )
        XCTAssertEqual(
            TileLayoutEngine.clamped(cell: TileGridPlacement(row: 0, column: 4), size: .wide, columns: columns),
            TileGridPlacement(row: 0, column: 2)
        )
        XCTAssertEqual(
            TileLayoutEngine.clamped(cell: TileGridPlacement(row: 0, column: -2), size: .small, columns: columns),
            TileGridPlacement(row: 0, column: 0)
        )
    }

    /// Допустимая ячейка не меняется.
    func testClampedKeepsValidCell() {
        let cell = TileGridPlacement(row: 7, column: 2)

        XCTAssertEqual(TileLayoutEngine.clamped(cell: cell, size: .wide, columns: columns), cell)
    }

    /// На узкой сетке берётся ужатая ширина: большая плитка при 3 колонках — 2.
    func testClampedUsesFittedWidthOnNarrowGrid() {
        let cell = TileLayoutEngine.clamped(cell: TileGridPlacement(row: 0, column: 3), size: .large, columns: 3)

        XCTAssertEqual(cell, TileGridPlacement(row: 0, column: 1))
    }

    /// Без колонок колонка — 0.
    func testClampedWithZeroColumnsPinsToColumnZero() {
        let cell = TileLayoutEngine.clamped(cell: TileGridPlacement(row: 1, column: 4), size: .small, columns: 0)

        XCTAssertEqual(cell, TileGridPlacement(row: 1, column: 0))
    }

    // MARK: - inserting: базовые случаи

    /// Вставка в пустой набор — один элемент на ячейке.
    func testInsertingIntoEmptySet() {
        let result = TileLayoutEngine.inserting(
            id: "a", size: .medium, at: TileGridPlacement(row: 4, column: 2), into: [], columns: columns
        )

        XCTAssertEqual(result, [placementItem("a", .medium, 4, 2)])
    }

    /// Вставка на свободное место ничего не двигает, новый элемент — в конец.
    func testInsertingAtFreeCellKeepsOthersAndAppends() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .small, 0, 4)]

        let result = TileLayoutEngine.inserting(
            id: "n", size: .small, at: TileGridPlacement(row: 2, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(Array(result.prefix(2)), base)
        XCTAssertEqual(result.last, placementItem("n", .small, 2, 0))
        XCTAssertEqual(result.count, 3)
    }

    /// Вставка за все строки — на своей строке, дыра между остаётся.
    func testInsertingBelowAllRowsLeavesHole() {
        let base = [placementItem("a", .medium, 0, 0)]

        let result = TileLayoutEngine.inserting(
            id: "far", size: .small, at: TileGridPlacement(row: 40, column: 3), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("far", in: result), TileGridPlacement(row: 40, column: 3))
        XCTAssertEqual(placementCell("a", in: result), TileGridPlacement(row: 0, column: 0))
    }

    /// Слишком правая ячейка сдвигается влево перед вставкой.
    func testInsertingClampsTooRightCell() {
        let result = TileLayoutEngine.inserting(
            id: "w", size: .wide, at: TileGridPlacement(row: -2, column: 5), into: [], columns: columns
        )

        XCTAssertEqual(placementCell("w", in: result), TileGridPlacement(row: 0, column: 2))
    }

    // MARK: - inserting: выталкивание вниз

    /// Малая плитка под вставляемой 2×2 уходит вниз на нижнюю границу вставки.
    func testInsertingPushesOverlappedTileDownToInsertionBottom() {
        let base = [placementItem("s", .small, 0, 0)]

        let result = TileLayoutEngine.inserting(
            id: "m", size: .medium, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("s", in: result), TileGridPlacement(row: 2, column: 0))
        XCTAssertEqual(placementCell("m", in: result), TileGridPlacement(row: 0, column: 0))
    }

    /// Каскад: толкаемая плитка выталкивает следующую и т. д.
    func testInsertingCascadesThroughStackedTiles() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("b", .small, 1, 0),
            placementItem("c", .small, 2, 0),
        ]

        let result = TileLayoutEngine.inserting(
            id: "m", size: .medium, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("a", in: result)?.row, 2)
        XCTAssertEqual(placementCell("b", in: result)?.row, 3)
        XCTAssertEqual(placementCell("c", in: result)?.row, 4)
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Плитка, которая не пересеклась, остаётся на месте даже ниже толкаемых
    /// (дыра между ними допустима).
    func testInsertingDoesNotMoveTilesFarBelow() {
        let base = [placementItem("a", .small, 0, 0), placementItem("far", .small, 9, 0)]

        let result = TileLayoutEngine.inserting(
            id: "m", size: .medium, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("a", in: result)?.row, 2)
        XCTAssertEqual(placementCell("far", in: result)?.row, 9)
    }

    /// Дыры выше вставки и соседи без пересечения не трогаются; по горизонтали
    /// никто не двигается.
    func testInsertingKeepsUnaffectedTilesAndNeverMovesHorizontally() {
        let base = [
            placementItem("top", .small, 0, 0),
            placementItem("left", .medium, 3, 0),
            placementItem("hit", .small, 3, 3),
            placementItem("right", .small, 3, 5),
        ]

        let result = TileLayoutEngine.inserting(
            id: "m", size: .medium, at: TileGridPlacement(row: 3, column: 2), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("top", in: result), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(placementCell("left", in: result), TileGridPlacement(row: 3, column: 0))
        XCTAssertEqual(placementCell("right", in: result), TileGridPlacement(row: 3, column: 5))
        XCTAssertEqual(placementCell("hit", in: result), TileGridPlacement(row: 5, column: 3))
        for item in base {
            XCTAssertEqual(placementCell("\(item.id)", in: result)?.column, item.cell.column)
        }
    }

    /// Высокая плитка толкается целиком, и плитки под ней — тоже.
    func testInsertingPushesTallTileAndItsNeighborsBelow() {
        let base = [
            placementItem("tall", .large, 0, 0),
            placementItem("under", .small, 4, 0),
        ]

        let result = TileLayoutEngine.inserting(
            id: "m", size: .medium, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("tall", in: result), TileGridPlacement(row: 2, column: 0))
        XCTAssertEqual(placementCell("under", in: result), TileGridPlacement(row: 6, column: 0))
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Порядок обхода — чтение исходных позиций: левая из двух плиток одной
    /// строки обрабатывается раньше (детерминированный итог).
    func testInsertingProcessesReadingOrderOfOriginalPositions() {
        // `wide` стоит правее и выше по индексу, но читается позже `left`.
        let base = [
            placementItem("wide", .wide, 1, 2),
            placementItem("left", .small, 1, 0),
        ]

        let result = TileLayoutEngine.inserting(
            id: "m", size: .large, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        // Прямоугольник вставки — колонки 0–3, строки 0–3. Обе плитки уходят на 4.
        XCTAssertEqual(placementCell("left", in: result), TileGridPlacement(row: 4, column: 0))
        XCTAssertEqual(placementCell("wide", in: result), TileGridPlacement(row: 4, column: 2))
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    // MARK: - inserting: перенос существующего

    /// Существующий элемент переносится: на своём индексе, без коллизии со своим
    /// прежним местом.
    func testInsertingExistingIDMovesAndKeepsArrayIndex() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .small, 0, 3),
            placementItem("c", .small, 5, 0),
        ]

        let result = TileLayoutEngine.inserting(
            id: "a", size: .medium, at: TileGridPlacement(row: 0, column: 2), into: base, columns: columns
        )

        XCTAssertEqual(placementIDs(result), ["a", "b", "c"])
        XCTAssertEqual(placementCell("a", in: result), TileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("b", in: result), TileGridPlacement(row: 2, column: 3))
        XCTAssertEqual(result.count, 3)
    }

    /// Перенос с новым размером: итоговый размер — переданный.
    func testInsertingExistingIDAppliesNewSize() {
        let base = [placementItem("a", .small, 0, 0)]

        let result = TileLayoutEngine.inserting(
            id: "a", size: .wide, at: TileGridPlacement(row: 1, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(result, [placementItem("a", .wide, 1, 0)])
    }

    // MARK: - inserting: особые случаи

    /// Создание папки: 2×2 на месте малой плитки-цели выталкивает соседей вниз.
    func testFolderCreationAtSmallTargetBecomesMediumAndPushesNeighborsDown() {
        // Цель — small (0,2); справа и снизу соседи, которые 2×2 перекроет.
        let base = [
            placementItem("target", .small, 0, 2),
            placementItem("right", .small, 0, 3),
            placementItem("below", .small, 1, 2),
            placementItem("diag", .small, 1, 3),
            placementItem("untouched", .small, 0, 5),
        ]
        let withoutTarget = TileLayoutEngine.removing(id: "target", from: base)

        let result = TileLayoutEngine.inserting(
            id: "folder", size: .medium, at: TileGridPlacement(row: 0, column: 2),
            into: withoutTarget, columns: columns
        )

        XCTAssertEqual(placementCell("folder", in: result), TileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("right", in: result), TileGridPlacement(row: 2, column: 3))
        XCTAssertEqual(placementCell("below", in: result), TileGridPlacement(row: 2, column: 2))
        // Диагональная плитка сначала упирается в 2×2, затем в уже сдвинутую `right`.
        XCTAssertEqual(placementCell("diag", in: result), TileGridPlacement(row: 3, column: 3))
        XCTAssertEqual(placementCell("untouched", in: result), TileGridPlacement(row: 0, column: 5))
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Вынос широкой плитки в слишком узкую ячейку: сдвиг влево + выталкивание.
    func testExtractingWideTileIntoNarrowCellClampsLeftAndPushes() {
        let base = [
            placementItem("a", .small, 0, 2),
            placementItem("b", .small, 0, 5),
        ]

        let result = TileLayoutEngine.inserting(
            id: "wide", size: .wide, at: TileGridPlacement(row: 0, column: 4), into: base, columns: columns
        )

        XCTAssertEqual(placementCell("wide", in: result), TileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("a", in: result), TileGridPlacement(row: 2, column: 2))
        XCTAssertEqual(placementCell("b", in: result), TileGridPlacement(row: 2, column: 5))
    }

    /// Большая плитка у правого края сдвигается влево на 2 колонки.
    func testInsertingLargeAtRightEdgeShiftsLeft() {
        let result = TileLayoutEngine.inserting(
            id: "l", size: .large, at: TileGridPlacement(row: 1, column: 5), into: [], columns: columns
        )

        XCTAssertEqual(placementCell("l", in: result), TileGridPlacement(row: 1, column: 2))
    }

    /// Колонок меньше ширины плитки: след ужимается, плитка не пропадает.
    func testInsertingWideIntoGridNarrowerThanTileUsesFittedFootprint() {
        let result = TileLayoutEngine.inserting(
            id: "w", size: .wide, at: TileGridPlacement(row: 0, column: 2), into: [placementItem("s", .small, 0, 0)],
            columns: 3
        )

        // Ужатая ширина 2: колонка 2 → 1, малая плитка на колонке 0 не мешает.
        XCTAssertEqual(placementCell("w", in: result), TileGridPlacement(row: 0, column: 1))
        XCTAssertEqual(placementCell("s", in: result), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(result.first(where: { $0.id == AnyHashable("w") })?.size, .wide)
        XCTAssertTrue(TileLayoutEngine.validate(result, columns: 3).isEmpty)
    }

    /// Без колонок вход возвращается как есть.
    func testInsertingWithZeroColumnsReturnsInput() {
        let base = [placementItem("a", .small, 0, 0)]

        XCTAssertEqual(
            TileLayoutEngine.inserting(
                id: "n", size: .small, at: TileGridPlacement(row: 0, column: 0), into: base, columns: 0
            ),
            base
        )
    }

    /// Идемпотентность: вставка уже корректного размещения на его ячейку.
    func testInsertingValidPlacementAtOwnCellChangesNothing() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .wide, 0, 2),
            placementItem("c", .small, 6, 3),
            placementItem("d", .large, 2, 0),
        ]

        for item in base {
            let result = TileLayoutEngine.inserting(
                id: item.id, size: item.size, at: item.cell, into: base, columns: columns
            )
            XCTAssertEqual(result, base, "перенос \(item.id) на свою ячейку изменил набор")
        }
    }

    /// Детерминизм: один вход — один выход.
    func testInsertingIsDeterministic() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("b", .small, 0, 1),
            placementItem("c", .medium, 1, 0),
            placementItem("d", .small, 3, 0),
        ]

        let first = TileLayoutEngine.inserting(
            id: "m", size: .large, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )
        let second = TileLayoutEngine.inserting(
            id: "m", size: .large, at: TileGridPlacement(row: 0, column: 0), into: base, columns: columns
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(first, columns: columns))
    }

    /// Пересечения во входе тоже разрешаются: результат без пересечений.
    func testInsertingResolvesPreExistingOverlapsInInput() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .medium, 1, 1)]

        let result = TileLayoutEngine.inserting(
            id: "n", size: .small, at: TileGridPlacement(row: 9, column: 0), into: base, columns: columns
        )

        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    // MARK: - resizing

    /// Рост на месте: якорь остаётся, соседей нет — ничего не двигается.
    func testResizingGrowsInPlaceKeepingAnchor() {
        let base = [placementItem("a", .small, 2, 1), placementItem("b", .small, 8, 0)]

        let result = TileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns)

        XCTAssertEqual(placementCell("a", in: result), TileGridPlacement(row: 2, column: 1))
        XCTAssertEqual(result.first?.size, .medium)
        XCTAssertEqual(placementCell("b", in: result), TileGridPlacement(row: 8, column: 0))
    }

    /// Рост у правого края сдвигает колонку влево.
    func testResizingNearRightEdgeShiftsColumnLeft() {
        let base = [placementItem("a", .small, 0, 5)]

        XCTAssertEqual(
            placementCell("a", in: TileLayoutEngine.resizing(id: "a", to: .wide, in: base, columns: columns)),
            TileGridPlacement(row: 0, column: 2)
        )
        XCTAssertEqual(
            placementCell("a", in: TileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns)),
            TileGridPlacement(row: 0, column: 4)
        )
    }

    /// Рост выталкивает соседей вниз каскадом.
    func testResizingGrowthPushesNeighborsDownWithCascade() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("right", .small, 0, 1),
            placementItem("below", .small, 1, 0),
            placementItem("chain", .small, 2, 0),
        ]

        let result = TileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns)

        XCTAssertEqual(placementCell("right", in: result), TileGridPlacement(row: 2, column: 1))
        XCTAssertEqual(placementCell("below", in: result), TileGridPlacement(row: 2, column: 0))
        XCTAssertEqual(placementCell("chain", in: result), TileGridPlacement(row: 3, column: 0))
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Уменьшение оставляет дыру: ничего не двигается.
    func testResizingShrinkLeavesHoleAndMovesNothing() {
        let base = [
            placementItem("big", .large, 0, 0),
            placementItem("under", .small, 4, 0),
            placementItem("side", .small, 0, 4),
        ]

        let result = TileLayoutEngine.resizing(id: "big", to: .small, in: base, columns: columns)

        XCTAssertEqual(placementCell("big", in: result), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(result.first?.size, .small)
        XCTAssertEqual(placementCell("under", in: result), TileGridPlacement(row: 4, column: 0))
        XCTAssertEqual(placementCell("side", in: result), TileGridPlacement(row: 0, column: 4))
    }

    /// Тот же размер — набор не меняется; неизвестный id — тоже.
    func testResizingSameSizeAndUnknownIDChangeNothing() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .small, 0, 2)]

        XCTAssertEqual(TileLayoutEngine.resizing(id: "a", to: .medium, in: base, columns: columns), base)
        XCTAssertEqual(TileLayoutEngine.resizing(id: "zzz", to: .large, in: base, columns: columns), base)
        XCTAssertEqual(TileLayoutEngine.resizing(id: "a", to: .large, in: base, columns: 0), base)
    }

    // MARK: - removing

    /// Удаление оставляет дыру, остальные не двигаются.
    func testRemovingLeavesHole() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .small, 0, 2),
            placementItem("c", .small, 2, 0),
        ]

        let result = TileLayoutEngine.removing(id: "a", from: base)

        XCTAssertEqual(result, [placementItem("b", .small, 0, 2), placementItem("c", .small, 2, 0)])
    }

    /// Неизвестный id — набор прежний.
    func testRemovingUnknownIDChangesNothing() {
        let base = [placementItem("a", .small, 0, 0)]

        XCTAssertEqual(TileLayoutEngine.removing(id: "x", from: base), base)
    }

    // MARK: - collapsingEmptyRows

    /// Полностью пустая строка схлопывается; плитки ниже поднимаются.
    func testCollapsingRemovesFullyEmptyRow() {
        let base = [placementItem("a", .small, 0, 0), placementItem("b", .small, 2, 3)]

        let result = TileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        XCTAssertEqual(placementCell("a", in: result), TileGridPlacement(row: 0, column: 0))
        XCTAssertEqual(placementCell("b", in: result), TileGridPlacement(row: 1, column: 3))
    }

    /// Строки, покрытые высокой плиткой, не схлопываются, даже если в них больше
    /// никого нет.
    func testCollapsingKeepsRowsCoveredByTallTiles() {
        let base = [
            placementItem("tall", .large, 0, 0),
            placementItem("s", .small, 0, 5),
            placementItem("t", .small, 3, 5),
        ]

        XCTAssertEqual(TileLayoutEngine.collapsingEmptyRows(in: base, columns: columns), base)
    }

    /// Многострочный пустой промежуток схлопывается целиком.
    func testCollapsingRemovesMultiRowGapEntirely() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .small, 7, 4),
            placementItem("c", .medium, 9, 0),
        ]

        let result = TileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        // Покрыты строки 0–1, 7, 9–10; пустые — 2–6 и 8.
        XCTAssertEqual(placementCell("a", in: result)?.row, 0)
        XCTAssertEqual(placementCell("b", in: result)?.row, 2)
        XCTAssertEqual(placementCell("c", in: result)?.row, 3)
        XCTAssertFalse(TileLayoutEngine.hasOverlaps(result, columns: columns))
    }

    /// Пустые строки в самом верху тоже схлопываются.
    func testCollapsingRemovesLeadingEmptyRows() {
        let base = [placementItem("a", .small, 4, 2), placementItem("b", .medium, 5, 0)]

        let result = TileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        XCTAssertEqual(placementCell("a", in: result), TileGridPlacement(row: 0, column: 2))
        XCTAssertEqual(placementCell("b", in: result), TileGridPlacement(row: 1, column: 0))
    }

    /// Колонки не меняются, порядок массива сохраняется, пустой набор — пустой.
    func testCollapsingKeepsColumnsAndOrderAndHandlesEmptySet() {
        let base = [placementItem("z", .small, 5, 4), placementItem("a", .small, 0, 1)]

        let result = TileLayoutEngine.collapsingEmptyRows(in: base, columns: columns)

        XCTAssertEqual(placementIDs(result), ["z", "a"])
        XCTAssertEqual(result.map(\.cell.column), [4, 1])
        XCTAssertTrue(TileLayoutEngine.collapsingEmptyRows(in: [], columns: columns).isEmpty)
    }

    /// Плитка 2×2, закрывающая «пустую» для остальных строку, удерживает её.
    func testCollapsingWithRowCoveredOnlyByMediumKeepsAllRows() {
        let base = [
            placementItem("top", .small, 0, 0),
            placementItem("m", .medium, 1, 2),
            placementItem("low", .small, 3, 0),
        ]

        XCTAssertEqual(TileLayoutEngine.collapsingEmptyRows(in: base, columns: columns), base)
    }

    /// Высота большой плитки на узкой сетке — ужатая: строки 2–3 пусты.
    func testCollapsingUsesFittedHeightOnNarrowGrid() {
        let base = [placementItem("l", .large, 0, 0), placementItem("s", .small, 4, 0)]

        let narrow = TileLayoutEngine.collapsingEmptyRows(in: base, columns: 3)
        let wide = TileLayoutEngine.collapsingEmptyRows(in: base, columns: 6)

        XCTAssertEqual(placementCell("s", in: narrow)?.row, 2)
        XCTAssertEqual(placementCell("s", in: wide)?.row, 4)
    }

    // MARK: - newRowCell / firstFreeCell

    /// Пустой набор — строка 0.
    func testNewRowCellOfEmptySetIsOrigin() {
        XCTAssertEqual(
            TileLayoutEngine.newRowCell(size: .medium, columns: columns, placements: []),
            TileGridPlacement(row: 0, column: 0)
        )
    }

    /// Новая строка — под самой нижней границей, включая высокие плитки.
    func testNewRowCellIsBelowLastOccupiedRow() {
        let base = [placementItem("a", .small, 0, 0), placementItem("tall", .large, 2, 2)]

        XCTAssertEqual(
            TileLayoutEngine.newRowCell(size: .small, columns: columns, placements: base),
            TileGridPlacement(row: 6, column: 0)
        )
    }

    /// Переносимый элемент освобождает своё место: новая строка считается без него.
    func testNewRowCellExcludingMovedTile() {
        let base = [placementItem("a", .small, 0, 0), placementItem("last", .medium, 5, 0)]

        XCTAssertEqual(
            TileLayoutEngine.newRowCell(size: .medium, columns: columns, placements: base, excluding: "last"),
            TileGridPlacement(row: 1, column: 0)
        )
    }

    /// Пустой набор — начало сетки.
    func testFirstFreeCellOfEmptySetIsOrigin() {
        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .large, columns: columns, placements: []),
            TileGridPlacement(row: 0, column: 0)
        )
    }

    /// Находит первую дыру сверху-слева.
    func testFirstFreeCellFindsHoleTopLeft() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("c", .small, 0, 2),
        ]

        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .small, columns: columns, placements: base),
            TileGridPlacement(row: 0, column: 1)
        )
    }

    /// Дыра, в которую плитка не помещается, пропускается.
    func testFirstFreeCellSkipsHolesThatAreTooSmall() {
        let base = [
            placementItem("a", .small, 0, 0),
            placementItem("c", .small, 0, 2),
            placementItem("d", .small, 1, 1),
        ]

        // Дыра (0,1) — одна клетка: 2×2 ей не влезает; первая подходящая ниже.
        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .medium, columns: columns, placements: base),
            TileGridPlacement(row: 0, column: 3)
        )
        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .wide, columns: columns, placements: base),
            TileGridPlacement(row: 1, column: 2)
        )
    }

    /// Свободного места среди плиток нет — ячейка под последней строкой.
    func testFirstFreeCellFallsBackBelowEverything() {
        let base = [placementItem("a", .large, 0, 0), placementItem("b", .medium, 0, 4)]

        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .large, columns: 4, placements: [placementItem("x", .large, 0, 0)]),
            TileGridPlacement(row: 4, column: 0)
        )
        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .large, columns: columns, placements: base),
            TileGridPlacement(row: 4, column: 0)
        )
    }

    /// Переносимый элемент освобождает своё место.
    func testFirstFreeCellExcludingMovedTile() {
        let base = [placementItem("a", .medium, 0, 0), placementItem("b", .small, 0, 2)]

        XCTAssertEqual(
            TileLayoutEngine.firstFreeCell(size: .medium, columns: columns, placements: base, excluding: "a"),
            TileGridPlacement(row: 0, column: 0)
        )
    }

    /// Найденная ячейка всегда свободна: вставка в неё ничего не двигает.
    func testFirstFreeCellInsertionNeverPushesAnything() {
        let base = [
            placementItem("a", .medium, 0, 0),
            placementItem("b", .wide, 0, 2),
            placementItem("c", .small, 2, 0),
            placementItem("d", .large, 3, 2),
        ]

        for size in TileSize.allCases {
            let cell = TileLayoutEngine.firstFreeCell(size: size, columns: columns, placements: base)
            let result = TileLayoutEngine.inserting(id: "n", size: size, at: cell, into: base, columns: columns)

            XCTAssertEqual(Array(result.prefix(base.count)), base, "размер \(size)")
            XCTAssertEqual(placementCell("n", in: result), cell)
        }
    }

    // MARK: - fittingSize

    /// При 6 колонках (D26) ни один размер D15 не ужимается.
    func testFittingSizeKeepsAllSizesAtSixColumns() {
        for size in TileSize.allCases {
            XCTAssertEqual(TileLayoutEngine.fittingSize(size, columns: 6), size)
            XCTAssertEqual(TileLayoutEngine.fittingSize(size, columns: 4), size)
        }
    }

    /// На узкой сетке ужатая ширина всегда ≤ колонок — основа `clamped`.
    func testFittingSizeAlwaysFitsWidthForClamping() {
        for columns in 1...6 {
            for size in TileSize.allCases {
                let fitted = TileLayoutEngine.fittingSize(size, columns: columns)
                XCTAssertLessThanOrEqual(fitted.unitColumns, columns)

                let cell = TileLayoutEngine.clamped(
                    cell: TileGridPlacement(row: 0, column: 99), size: size, columns: columns
                )
                XCTAssertEqual(cell.column + fitted.unitColumns, columns)
            }
        }
    }
}

#endif
