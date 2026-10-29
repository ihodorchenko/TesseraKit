//
//  TileLayoutEngineTests.swift
//  TesseraStartScreenTests
//
//  Тесты чистой раскладки плиточной сетки (задача E4.7).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»
//  (формула юнита, жадная упаковка слева направо сверху вниз, «честные дыры»,
//  юнитные координаты, переупаковка при resize) и §14 «Уточнения MVP» п. 4
//  (D15: четыре размера — 1×1, 2×2, 4×2, 4×4).
//
//  Тесты работают только с чистыми функциями `TileLayoutEngine`: без UIKit-цикла,
//  без окна и без коллекции. Случайные конфигурации seeded — прогон
//  воспроизводим. Для каждой упаковки отдельно проверяется свойство «первая
//  свободная позиция по обходу сверху вниз, слева направо»: это и есть контракт
//  жадного алгоритма, а не просто отсутствие пересечений.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEngineTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Проверяет корректность жадной упаковки по контракту §3.
    ///
    /// Для каждой плитки в порядке `items`:
    /// 1. слот относится к тому же ярлыку и имеет тот же размер;
    /// 2. ни одна более ранняя позиция (по строкам сверху вниз, внутри строки
    ///    слева направо) не была свободна для её прямоугольника;
    /// 3. сама позиция свободна (пересечений нет);
    /// 4. плитка не выходит за число колонок.
    ///
    /// - Parameters:
    ///   - items: Запрошенные пары «идентификатор — размер».
    ///   - slots: Результат упаковки.
    ///   - columns: Число колонок сетки.
    private func assertGreedyPacking(
        items: [(id: AnyHashable, size: TileSize)],
        slots: [TileLayoutSlot],
        columns: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            slots.count,
            items.count,
            "Все плитки должны быть упакованы",
            file: file,
            line: line
        )

        // Матрица занятости строится заново по уже проверенным слотам, чтобы
        // проверка не зависела от внутренней матрицы движка.
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

        func mark(column: Int, row: Int, width: Int, height: Int) {
            ensureRows(row + height)
            for currentRow in row..<(row + height) {
                for currentColumn in column..<(column + width) {
                    occupied[currentRow][currentColumn] = true
                }
            }
        }

        for (index, slot) in slots.enumerated() {
            guard items.indices.contains(index) else {
                XCTFail("Слотов больше, чем плиток", file: file, line: line)
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
                "Плитка \(slot.id) выходит за сетку",
                file: file,
                line: line
            )

            ensureRows(slot.row + height)

            // Все позиции, которые обход посещает раньше назначенной, обязаны
            // быть заняты — иначе движок выбрал бы их («честные дыры» не
            // заполняются, пока плитка в них не помещается целиком»).
            for row in 0...slot.row {
                let lastColumn = row == slot.row ? slot.column - 1 : columns - width
                guard lastColumn >= 0 else { continue }

                for column in 0...lastColumn {
                    XCTAssertFalse(
                        isFree(column: column, row: row, width: width, height: height),
                        "Плитка \(slot.id) заняла не первую свободную позицию",
                        file: file,
                        line: line
                    )
                }
            }

            XCTAssertTrue(
                isFree(column: slot.column, row: slot.row, width: width, height: height),
                "Плитка \(slot.id) пересекается с уже упакованными",
                file: file,
                line: line
            )
            mark(column: slot.column, row: slot.row, width: width, height: height)
        }
    }

    // MARK: - Границы

    /// Пустой вход — пустая раскладка.
    func testEmptyItemsProduceEmptyLayout() {
        let slots = TileLayoutEngine.pack(items: [], columns: 4, unit: 64)
        XCTAssertTrue(slots.isEmpty)
    }

    /// Одна small-плитка встаёт в левый верхний угол и занимает один юнит.
    func testSingleSmallTileOccupiesOrigin() throws {
        let slots = TileLayoutEngine.pack(
            items: [(id: AnyHashable("a"), size: TileSize.small)],
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

    /// Одна large-плитка занимает всю ширину и четыре строки (D15: 4×4).
    func testSingleLargeTileOccupiesWholeWidth() throws {
        let slots = TileLayoutEngine.pack(
            items: [(id: AnyHashable("a"), size: TileSize.large)],
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

    /// Плитка шире сетки пропускается: сетка не искажает размер (D15).
    func testTileWiderThanGridIsSkipped() throws {
        let slots = TileLayoutEngine.pack(
            items: [
                (id: AnyHashable("wide"), size: TileSize.wide),
                (id: AnyHashable("small"), size: TileSize.small),
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

    /// Вырожденная геометрия не запускает упаковку.
    func testDegenerateGeometryProducesEmptyLayout() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: TileSize.small),
        ]

        XCTAssertTrue(TileLayoutEngine.pack(items: items, columns: 0, unit: 64).isEmpty)
        XCTAssertTrue(TileLayoutEngine.pack(items: items, columns: -2, unit: 64).isEmpty)
        XCTAssertTrue(TileLayoutEngine.pack(items: items, columns: 4, unit: 0).isEmpty)
        XCTAssertTrue(TileLayoutEngine.pack(items: items, columns: 4, unit: -10).isEmpty)
        XCTAssertTrue(TileLayoutEngine.pack(items: items, columns: 4, unit: .nan).isEmpty)
        XCTAssertTrue(TileLayoutEngine.pack(items: items, columns: 4, unit: .infinity).isEmpty)
    }

    // MARK: - Жадная упаковка

    /// Детерминированный пример: medium → wide → small.
    ///
    /// medium стоит в (0,0), wide не помещается в первые две строки и уходит в
    /// (0,2), а small позже занимает «честную дыру» (2,0) выше wide — поиск
    /// каждый раз начинается с нулевой строки (§3).
    func testLaterTileFillsHoleAboveWideTile() throws {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("small"), size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 10)

        XCTAssertEqual(slots.map { $0.column }, [0, 0, 2])
        XCTAssertEqual(slots.map { $0.row }, [0, 2, 0])
        assertGreedyPacking(items: items, slots: slots, columns: 4)
    }

    /// Дыры не «заливаются» соседями: они остаются пустыми до тех пор, пока
    /// плитка не поместится в них целиком.
    ///
    /// После medium(0,0), wide(0,2) и двух small заняты 15 юнитов из 16; дыра
    /// (3,1) остаётся, а новая small в неё не влезает (занята строка 0) —
    /// проверяется арифметикой занятой площади, а не внутренним состоянием.
    func testHonestHolesStayEmpty() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("small-1"), size: .small),
            (id: AnyHashable("small-2"), size: .small),
            (id: AnyHashable("small-3"), size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 10)

        assertGreedyPacking(items: items, slots: slots, columns: 4)

        let occupiedUnits = slots.reduce(0) { partial, slot in
            partial + slot.unitColumns * slot.unitRows
        }
        // medium 4 + wide 8 + три small 3 = 15 юнитов; сетка занята до строки 3
        // включительно (16 юнитов), значит остаётся ровно одна честная дыра —
        // (3,1). Последняя small встала в (2,1), потому что (3,0) уже занята.
        XCTAssertEqual(occupiedUnits, 15)
        XCTAssertEqual(slots.last?.column, 2)
        XCTAssertEqual(slots.last?.row, 1)
    }

    /// Случайные конфигурации (seeded): порядок, размеры и первая свободная
    /// позиция совпадают с контрактом жадного алгоритма.
    func testGreedyPackingOnSeededRandomConfigurations() {
        for seed in 0..<32 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = [4, 6][generator.int(upperBound: 2)]
            let unit = CGFloat(20 + generator.int(upperBound: 61))
            let count = generator.int(upperBound: 14)

            let fittingSizes = TileSize.allCases.filter { $0.unitColumns <= columns }
            var items: [(id: AnyHashable, size: TileSize)] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                let size = fittingSizes[generator.int(upperBound: fittingSizes.count)]
                items.append((id: AnyHashable("tile-\(index)"), size: size))
            }

            let slots = TileLayoutEngine.pack(items: items, columns: columns, unit: unit)

            XCTAssertEqual(
                slots.map { $0.id },
                items.map { $0.id },
                "Порядок слотов должен совпадать с порядком ярлыков (seed \(seed))"
            )
            XCTAssertTrue(
                slots.allSatisfy { $0.unit == unit },
                "Юнит должен попасть в каждый слот (seed \(seed))"
            )
            assertGreedyPacking(items: items, slots: slots, columns: columns)
        }
    }

    /// Переполнение строк: 101 small-плитка в 4 колонки — 26 строк без
    /// пересечений; последняя плитка в (0,25).
    func testRowOverflowGrowsGridWithoutOverlaps() {
        let items: [(id: AnyHashable, size: TileSize)] = (0..<101).map {
            (id: AnyHashable("tile-\($0)"), size: TileSize.small)
        }
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 8)

        XCTAssertEqual(slots.count, 101)
        assertGreedyPacking(items: items, slots: slots, columns: 4)

        XCTAssertEqual(slots.last?.column, 0)
        XCTAssertEqual(slots.last?.row, 25)
        XCTAssertEqual(slots.map { $0.row }.max(), 25)
    }

    /// Широкие строки (6 колонок): wide/large укладываются без пересечений.
    func testSixColumnPackingHasNoOverlaps() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("wide-1"), size: .wide),
            (id: AnyHashable("wide-2"), size: .wide),
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("large"), size: .large),
            (id: AnyHashable("small"), size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 6, unit: 30)

        XCTAssertEqual(slots.count, items.count)
        assertGreedyPacking(items: items, slots: slots, columns: 6)
    }

    // MARK: - Переупаковка (resize и смена геометрии)

    /// Resize меняет размер одной плитки и переупаковывает остальные, сохраняя
    /// порядок ярлыков (§3, §5, D15).
    func testResizeRepacksWithoutOverlapsAndKeepsOrder() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: .small),
            (id: AnyHashable("b"), size: .small),
            (id: AnyHashable("c"), size: .wide),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 64)

        let resized = TileLayoutEngine.resizing(
            slots,
            id: AnyHashable("a"),
            to: .large,
            columns: 4,
            unit: 64
        )

        XCTAssertEqual(resized.map { $0.id }, items.map { $0.id })
        XCTAssertEqual(resized.map { $0.size }, [.large, .small, .wide])

        let expected: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: .large),
            (id: AnyHashable("b"), size: .small),
            (id: AnyHashable("c"), size: .wide),
        ]
        assertGreedyPacking(items: expected, slots: resized, columns: 4)
    }

    /// Resize неизвестного идентификатора эквивалентен обычной переупаковке:
    /// метод можно использовать как общий `repack`.
    func testResizingUnknownIdentifierEqualsRepack() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: .medium),
            (id: AnyHashable("b"), size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 40)

        let resized = TileLayoutEngine.resizing(
            slots,
            id: AnyHashable("missing"),
            to: .large,
            columns: 4,
            unit: 40
        )
        let repacked = TileLayoutEngine.repack(slots, columns: 4, unit: 40)

        XCTAssertEqual(resized, repacked)
    }

    /// Смена юнита не трогает юнитные координаты: раскладка не зависит от
    /// пикселей (§3, «Модель раскладки»).
    func testRepackKeepsUnitCoordinatesAndUpdatesUnit() throws {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: .small),
            (id: AnyHashable("b"), size: .medium),
            (id: AnyHashable("c"), size: .wide),
        ]
        let original = TileLayoutEngine.pack(items: items, columns: 4, unit: 64)
        let repacked = TileLayoutEngine.repack(original, columns: 4, unit: 32)

        XCTAssertEqual(repacked.map { $0.id }, original.map { $0.id })
        XCTAssertEqual(repacked.map { $0.column }, original.map { $0.column })
        XCTAssertEqual(repacked.map { $0.row }, original.map { $0.row })
        XCTAssertEqual(repacked.map { $0.size }, original.map { $0.size })
        XCTAssertTrue(repacked.allSatisfy { $0.unit == 32 })

        let originalWidth = try XCTUnwrap(original.first?.frame.width)
        let repackedWidth = try XCTUnwrap(repacked.first?.frame.width)
        XCTAssertEqual(repackedWidth, originalWidth / 2, accuracy: 1e-9)
    }

    /// Смена числа колонок переупаковывает сетку с новой геометрией.
    func testRepackWithColumnsChangeProducesValidLayout() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("small"), size: .small),
        ]
        let original = TileLayoutEngine.pack(items: items, columns: 4, unit: 50)
        let repacked = TileLayoutEngine.repack(original, columns: 6, unit: 40)

        XCTAssertEqual(repacked.count, items.count)
        XCTAssertEqual(repacked.map { $0.id }, items.map { $0.id })
        assertGreedyPacking(items: items, slots: repacked, columns: 6)
    }

    // MARK: - Формула юнита

    /// `unit = (screenWidth − gaps × (N − 1)) / N` (§3).
    func testUnitFormula() {
        XCTAssertEqual(
            TileLayoutEngine.unit(screenWidth: 320, columns: 4, gaps: 8),
            74,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            TileLayoutEngine.unit(screenWidth: 320, columns: 6, gaps: 8),
            (320 - 40) / 6,
            accuracy: 1e-9
        )
    }

    /// Защитные случаи формулы юнита: отрицательный зазор — 0, вырожденная
    /// ширина — 0, нечисловые значения — 0.
    func testUnitClampsDegenerateInput() {
        XCTAssertEqual(
            TileLayoutEngine.unit(screenWidth: 320, columns: 4, gaps: -8),
            80,
            accuracy: 1e-9
        )
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 320, columns: 0, gaps: 8), 0)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: -320, columns: 4, gaps: 8), 0)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 20, columns: 4, gaps: 10), 0)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: .nan, columns: 4, gaps: 0), 0)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 320, columns: 4, gaps: .nan), 0)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: .infinity, columns: 4, gaps: 0), 0)
    }

    // MARK: - Геометрия в точках

    /// Внутренние зазоры входят в рамку плитки, внешние — нет (§3).
    func testRectAppliesGapAndOrigin() {
        let slot = TileLayoutSlot(
            id: AnyHashable("a"),
            size: .medium,
            column: 2,
            row: 1,
            unit: 50
        )

        let rect = TileLayoutEngine.rect(
            for: slot,
            unit: nil,
            gap: 10,
            origin: CGPoint(x: 5, y: 7)
        )

        XCTAssertEqual(rect, CGRect(x: 125, y: 67, width: 110, height: 110))
    }

    /// `unit: nil` берёт юнит из слота, отрицательный зазор обнуляется.
    func testRectUsesSlotUnitAndClampsNegativeGap() {
        let slot = TileLayoutSlot(
            id: AnyHashable("a"),
            size: .small,
            column: 1,
            row: 2,
            unit: 40
        )

        XCTAssertEqual(
            TileLayoutEngine.rect(for: slot, gap: 0),
            CGRect(x: 40, y: 80, width: 40, height: 40)
        )
        XCTAssertEqual(
            TileLayoutEngine.rect(for: slot, gap: -12),
            CGRect(x: 40, y: 80, width: 40, height: 40)
        )
    }

    /// Нечисловой/неположительный юнит и пустой след дают `.zero`.
    func testRectFallsBackToZeroForDegenerateUnit() {
        let slot = TileLayoutSlot(
            id: AnyHashable("a"),
            size: .wide,
            column: 0,
            row: 0,
            unit: 25
        )

        XCTAssertEqual(TileLayoutEngine.rect(for: slot, unit: 0), .zero)
        XCTAssertEqual(TileLayoutEngine.rect(for: slot, unit: -10), .zero)
        XCTAssertEqual(TileLayoutEngine.rect(for: slot, unit: .nan), .zero)
    }

    /// «Сырая» рамка слота тоже защищена от вырожденного юнита.
    func testSlotFrameFallsBackToZeroForDegenerateUnit() {
        let zeroUnit = TileLayoutSlot(
            id: AnyHashable("a"),
            size: .medium,
            column: 2,
            row: 1,
            unit: 0
        )
        XCTAssertEqual(zeroUnit.frame, .zero)

        let nanUnit = TileLayoutSlot(
            id: AnyHashable("a"),
            size: .medium,
            column: 2,
            row: 1,
            unit: .nan
        )
        XCTAssertEqual(nanUnit.frame, .zero)
    }
}

#endif
