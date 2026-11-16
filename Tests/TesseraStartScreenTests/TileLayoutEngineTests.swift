//
//  TileLayoutEngineTests.swift
//  TesseraStartScreenTests
//
//  Тесты чистой раскладки плиточной сетки (задача E4.7, строгая компактность —
//  E8.5).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»
//  (формула юнита, упаковка слева направо сверху вниз, юнитные координаты) и
//  §14 «Уточнения MVP» п. 4 (D15: четыре размера — 1×1, 2×2, 4×2, 4×4).
//  Здесь — упаковка **по порядку** (`pack`/`packCompact`, E8.5): с E14 это
//  запасной путь, миграция v1 → v2 и первый запуск; раскладка по явным ячейкам
//  с дырами проверяется в `TileLayoutEnginePlacement*Tests`.
//
//  Тесты работают только с чистыми функциями `TileLayoutEngine`: без UIKit-цикла,
//  без окна и без коллекции. Случайные конфигурации seeded — прогон
//  воспроизводим. Для каждой упаковки проверяется свойство «первая свободная
//  позиция по обходу сверху вниз, слева направо» и строгая компактность готовой
//  раскладки: ни одну плитку нельзя сдвинуть вверх/влево, пустых строк нет.
//  Отдельно проверяется схлопывание (`stabilize`) и reflow после «утаскивания»
//  плитки — это контракт E8.5, а не просто отсутствие пересечений.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEngineTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Проверяет контракт строгой компактности упаковки (E8.5).
    ///
    /// Для каждой плитки в порядке `items`:
    /// 1. слот относится к тому же ярлыку и имеет тот же размер;
    /// 2. ни одна более ранняя позиция (по строкам сверху вниз, внутри строки
    ///    слева направо) не была свободна для её прямоугольника;
    /// 3. сама позиция свободна (пересечений нет);
    /// 4. плитка не выходит за число колонок.
    ///
    /// Затем — по **готовой** раскладке, а не по порядку укладки:
    /// 5. ни одну плитку нельзя сдвинуть вверх или влево: если снять её с
    ///    сетки, все более ранние позиции заняты;
    /// 6. нет пустых строк: в каждой строке до последней занятой есть юнит.
    ///
    /// - Parameters:
    ///   - items: Запрошенные пары «идентификатор — размер».
    ///   - slots: Результат упаковки.
    ///   - columns: Число колонок сетки.
    private func assertCompactPacking(
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
            // быть заняты — иначе движок выбрал бы их.
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

        // E8.5: по готовой раскладке ни одну плитку нельзя сдвинуть вверх/влево.
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
                        "Плитку \(slot.id) можно сдвинуть вверх/влево в (\(column), \(row))",
                        file: file,
                        line: line
                    )
                }
            }

            mark(column: slot.column, row: slot.row, width: width, height: height)
        }

        // E8.5: пустых строк в середине раскладки не остаётся.
        let lastRow = slots.map { $0.row + $0.unitRows }.max() ?? 0
        for row in 0..<lastRow {
            XCTAssertTrue(
                occupied[row].contains(true),
                "Строка \(row) пуста: раскладка не компактна сверху вниз",
                file: file,
                line: line
            )
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

    // MARK: - Строгая компактность (E8.5)

    /// Детерминированный пример: medium → wide → small.
    ///
    /// medium стоит в (0,0), wide не помещается в первые две строки и уходит в
    /// (0,2), а small позже занимает свободный юнит (2,0) выше wide — поиск
    /// каждый раз начинается с нулевой строки. После упаковки ни одну плитку
    /// нельзя сдвинуть вверх/влево (E8.5).
    func testLaterTileFillsFreeSlotAboveWideTile() throws {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("small"), size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 10)

        XCTAssertEqual(slots.map { $0.column }, [0, 0, 2])
        XCTAssertEqual(slots.map { $0.row }, [0, 2, 0])
        assertCompactPacking(items: items, slots: slots, columns: 4)
    }

    /// Дыра остаётся только там, куда не помещается ни одна текущая плитка, и
    /// исчезает, как только появляется плитка подходящего размера.
    ///
    /// После medium(0,0), wide(0,2) и трёх small заняты 15 юнитов из 16:
    /// свободен только юнит (3,1). Ни одна из текущих плиток в него не влезает —
    /// сдвигать нечего, это не «честная дыра» §3, а след размеров. Следующая
    /// small в новой упаковке занимает именно (3,1), а не остаётся ниже.
    func testOnlyUnfillableHoleRemainsAndNextSmallFillsIt() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("small-1"), size: .small),
            (id: AnyHashable("small-2"), size: .small),
            (id: AnyHashable("small-3"), size: .small),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 10)

        assertCompactPacking(items: items, slots: slots, columns: 4)

        let occupiedUnits = slots.reduce(0) { partial, slot in
            partial + slot.unitColumns * slot.unitRows
        }
        // medium 4 + wide 8 + три small 3 = 15 юнитов; сетка занята до строки 3
        // включительно (16 юнитов), значит свободен ровно один юнит — (3,1).
        // Последняя small встала в (2,1): строка 0 заполнена, а в строке 1
        // свободны колонки 2 и 3 — поиск берёт левую.
        XCTAssertEqual(occupiedUnits, 15)
        XCTAssertEqual(slots.last?.column, 2)
        XCTAssertEqual(slots.last?.row, 1)

        // Строгая компактность: появившаяся small занимает свободный юнит выше,
        // а не встаёт в новую строку.
        let extra = (id: AnyHashable("small-4"), size: TileSize.small)
        let extendedItems = items + [extra]
        let extendedSlots = TileLayoutEngine.pack(
            items: extendedItems,
            columns: 4,
            unit: 10
        )
        XCTAssertEqual(extendedSlots.last?.column, 3)
        XCTAssertEqual(extendedSlots.last?.row, 1)
        assertCompactPacking(items: extendedItems, slots: extendedSlots, columns: 4)
    }

    /// Случайные конфигурации (seeded): порядок, размеры, первая свободная
    /// позиция и строгая компактность готовой раскладки.
    func testCompactPackingOnSeededRandomConfigurations() {
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
            assertCompactPacking(items: items, slots: slots, columns: columns)
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
        assertCompactPacking(items: items, slots: slots, columns: 4)

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
        assertCompactPacking(items: items, slots: slots, columns: 6)
    }

    // MARK: - Схлопывание и reflow (E8.5)

    /// Схлопывание поднимает «подвешенную» плитку в свободный юнит выше.
    ///
    /// Раскладка [medium в (0,0), small в (0,2)] не компактна: small висит
    /// строкой ниже, хотя справа от medium есть свободный юнит. После
    /// схлопывания small встаёт в (2,0) — в самую верхнюю-левую позицию.
    func testStabilizeLiftsFloatingTileIntoFreeSlot() throws {
        let slots = [
            TileLayoutSlot(
                id: AnyHashable("medium"),
                size: .medium,
                column: 0,
                row: 0,
                unit: 10
            ),
            TileLayoutSlot(
                id: AnyHashable("small"),
                size: .small,
                column: 0,
                row: 2,
                unit: 10
            ),
        ]

        let compacted = TileLayoutEngine.stabilize(slots, columns: 4)

        XCTAssertEqual(compacted.count, 2)
        XCTAssertEqual(compacted.map { $0.id }, slots.map { $0.id })

        let small = try XCTUnwrap(compacted.last)
        XCTAssertEqual(small.column, 2)
        XCTAssertEqual(small.row, 0)

        // medium уже в самой ранней позиции — его не трогаем.
        XCTAssertEqual(compacted.first?.column, 0)
        XCTAssertEqual(compacted.first?.row, 0)

        // Одна «подвешенная» плитка тоже схлопывается в (0,0).
        let single = [
            TileLayoutSlot(
                id: AnyHashable("single"),
                size: .small,
                column: 2,
                row: 2,
                unit: 10
            ),
        ]
        let compactedSingle = TileLayoutEngine.stabilize(single, columns: 4)
        XCTAssertEqual(compactedSingle.first?.column, 0)
        XCTAssertEqual(compactedSingle.first?.row, 0)
    }

    /// Схлопывание сдвигает плитку влево в той же строке, если слева есть место.
    func testStabilizeMovesTileLeftInsideRow() throws {
        let slots = [
            TileLayoutSlot(
                id: AnyHashable("medium"),
                size: .medium,
                column: 0,
                row: 0,
                unit: 10
            ),
            TileLayoutSlot(
                id: AnyHashable("small"),
                size: .small,
                column: 3,
                row: 0,
                unit: 10
            ),
        ]

        let compacted = TileLayoutEngine.stabilize(slots, columns: 4)
        let small = try XCTUnwrap(compacted.last)

        XCTAssertEqual(small.column, 2)
        XCTAssertEqual(small.row, 0)
    }

    /// Схлопывание не двигает уже компактную раскладку: упаковка — его
    /// неподвижная точка.
    func testStabilizeKeepsCompactPackingUnchanged() {
        let configurations: [[TileSize]] = [
            [.medium, .wide, .small],
            [.small, .medium, .small, .medium, .wide],
            [.large, .medium, .small, .small, .wide],
            [.small, .small, .wide, .medium, .medium, .large],
        ]

        for (index, sizes) in configurations.enumerated() {
            let items = sizes.enumerated().map { offset, size in
                (id: AnyHashable("tile-\(offset)"), size: size)
            }
            let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 8)

            XCTAssertEqual(
                TileLayoutEngine.stabilize(slots, columns: 4),
                slots,
                "Упаковка №\(index) должна быть неподвижной точкой схлопывания"
            )
        }
    }

    /// Публичный `pack` — это строго компактная упаковка: раскладка и
    /// edit/drag ходят через него, поэтому визуал режимов не различается.
    func testPublicPackMatchesCompactImplementation() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: .medium),
            (id: AnyHashable("b"), size: .small),
            (id: AnyHashable("c"), size: .wide),
            (id: AnyHashable("d"), size: .small),
        ]

        XCTAssertEqual(
            TileLayoutEngine.pack(items: items, columns: 4, unit: 12),
            TileLayoutEngine.packCompact(items: items, columns: 4, unit: 12)
        )
    }

    /// Reflow после «утаскивания» плитки: нижняя плитка поднимается в
    /// освободившееся место, пустых строк не остаётся (E8.5).
    func testRemovingTileLiftsLowerTileIntoVacatedSpace() {
        let medium = (id: AnyHashable("medium"), size: TileSize.medium)
        let wide = (id: AnyHashable("wide"), size: TileSize.wide)

        let before = TileLayoutEngine.pack(items: [medium, wide], columns: 4, unit: 10)
        XCTAssertEqual(before.map { $0.row }, [0, 2])

        // Утащили medium: wide поднимается в строку 0.
        let after = TileLayoutEngine.pack(items: [wide], columns: 4, unit: 10)
        XCTAssertEqual(after.first?.row, 0)
        XCTAssertEqual(after.first?.column, 0)
        assertCompactPacking(items: [wide], slots: after, columns: 4)
    }

    // MARK: - Смена геометрии

    /// Смена юнита не трогает юнитные координаты: раскладка не зависит от
    /// пикселей (§3, «Модель раскладки»). После E14.6 пересборка — это просто
    /// `pack` тех же элементов с другим юнитом (`repack` удалён).
    func testPackWithOtherUnitKeepsUnitCoordinatesAndUpdatesUnit() throws {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("a"), size: .small),
            (id: AnyHashable("b"), size: .medium),
            (id: AnyHashable("c"), size: .wide),
        ]
        let original = TileLayoutEngine.pack(items: items, columns: 4, unit: 64)
        let repacked = TileLayoutEngine.pack(items: items, columns: 4, unit: 32)

        XCTAssertEqual(repacked.map { $0.id }, original.map { $0.id })
        XCTAssertEqual(repacked.map { $0.column }, original.map { $0.column })
        XCTAssertEqual(repacked.map { $0.row }, original.map { $0.row })
        XCTAssertEqual(repacked.map { $0.size }, original.map { $0.size })
        XCTAssertTrue(repacked.allSatisfy { $0.unit == 32 })

        let originalWidth = try XCTUnwrap(original.first?.frame.width)
        let repackedWidth = try XCTUnwrap(repacked.first?.frame.width)
        XCTAssertEqual(repackedWidth, originalWidth / 2, accuracy: 1e-9)
    }

    /// Смена числа колонок упаковывает те же элементы с новой геометрией.
    func testPackWithColumnsChangeProducesValidLayout() {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("wide"), size: .wide),
            (id: AnyHashable("medium"), size: .medium),
            (id: AnyHashable("small"), size: .small),
        ]
        let repacked = TileLayoutEngine.pack(items: items, columns: 6, unit: 40)

        XCTAssertEqual(repacked.count, items.count)
        XCTAssertEqual(repacked.map { $0.id }, items.map { $0.id })
        assertCompactPacking(items: items, slots: repacked, columns: 6)
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

    // MARK: - Пиксельное выравнивание (E10.1)

    /// 393 pt без полей 16 pt: «сырой» юнит 84.25, выровненный вниз — 84 на
    /// 2× и 3×; 390 pt: 83.5 остаётся на 2× и становится 83⅓ на 3×.
    func testUnitWithScaleFloorsToPixelGrid() {
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8), 84.25, accuracy: 1e-9)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8, scale: 3), 84, accuracy: 1e-9)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8, scale: 2), 84, accuracy: 1e-9)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 358, columns: 4, gaps: 8, scale: 2), 83.5, accuracy: 1e-9)
        XCTAssertEqual(
            TileLayoutEngine.unit(screenWidth: 358, columns: 4, gaps: 8, scale: 3),
            250.0 / 3.0,
            accuracy: 1e-9
        )
    }

    /// Нулевой, отрицательный и нечисловой масштаб — без выравнивания;
    /// вырожденная геометрия по-прежнему даёт 0.
    func testUnitWithScaleIgnoresInvalidScale() {
        for scale in [CGFloat(0), -2, .nan, .infinity] {
            XCTAssertEqual(
                TileLayoutEngine.unit(screenWidth: 361, columns: 4, gaps: 8, scale: scale),
                84.25,
                accuracy: 1e-9,
                "Масштаб \(scale)"
            )
        }
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 20, columns: 4, gaps: 10, scale: 3), 0)
        XCTAssertEqual(TileLayoutEngine.unit(screenWidth: 361, columns: 0, gaps: 8, scale: 3), 0)
    }

    /// Геометрия сетки: юнит вниз до пикселя, зазор — к ближайшему пикселю,
    /// остаток — поровну на поля (левое — вниз до пикселя).
    func testGridMetricsCentersRemainder() throws {
        let metrics = try XCTUnwrap(
            TileLayoutEngine.gridMetrics(contentWidth: 361, columns: 4, spacing: 8, scale: 3)
        )
        XCTAssertEqual(metrics.unit, 84, accuracy: 1e-9)
        XCTAssertEqual(metrics.spacing, 8, accuracy: 1e-9)
        XCTAssertEqual(metrics.width, 360, accuracy: 1e-9)
        XCTAssertEqual(metrics.leading, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.columnOffset(3), 1.0 / 3.0 + 3 * 92, accuracy: 1e-9)

        // Дробный зазор встаёт на пиксель: 8.2 на 2× — 8.0.
        let fractional = try XCTUnwrap(
            TileLayoutEngine.gridMetrics(contentWidth: 361, columns: 4, spacing: 8.2, scale: 2)
        )
        XCTAssertEqual(fractional.spacing, 8, accuracy: 1e-9)

        // Без масштаба — точная формула §3, без остатка.
        let exact = try XCTUnwrap(
            TileLayoutEngine.gridMetrics(contentWidth: 361, columns: 4, spacing: 8, scale: 0)
        )
        XCTAssertEqual(exact.unit, 84.25, accuracy: 1e-9)
        XCTAssertEqual(exact.leading, 0)

        XCTAssertNil(TileLayoutEngine.gridMetrics(contentWidth: 0, columns: 4, spacing: 8, scale: 3))
        XCTAssertNil(TileLayoutEngine.gridMetrics(contentWidth: 361, columns: 0, spacing: 8, scale: 3))
    }

    // MARK: - Полоса папки (E10.1)

    /// Нижняя граница полосы папки по юнитной упаковке.
    ///
    /// - Parameters:
    ///   - items: Пары «идентификатор — размер».
    ///   - folderID: Идентификатор папки.
    ///   - columns: Число колонок.
    /// - Returns: Первая строка после полосы.
    private func bandEnd(
        _ items: [(id: AnyHashable, size: TileSize)],
        folderID: AnyHashable,
        columns: Int = 4
    ) throws -> Int {
        let slots = TileLayoutEngine.pack(items: items, columns: columns, unit: 1)
        let folderSlot = try XCTUnwrap(slots.first { $0.id == folderID })
        return TileLayoutEngine.folderBandEndRow(for: folderSlot, in: slots)
    }

    /// `[папка 2×2, small, small, 2×2]`: 2×2 в строках 1–2 расширяет полосу
    /// до строки 3.
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

    /// `[папка small, 2×2]`: 2×2 в строках 0–1 расширяет полосу до строки 2.
    func testFolderBandExtendsOverTallerNeighbour() throws {
        let end = try bandEnd(
            [(id: AnyHashable("f"), size: .small), (id: AnyHashable("m"), size: .medium)],
            folderID: "f"
        )
        XCTAssertEqual(end, 2)
    }

    /// Расширение итеративное: «лесенка» из 2×2 цепляет следующую плитку.
    ///
    /// 4 колонки: папка small (0,0), s (1,0), m1 2×2 (2,0)–(3,1), m2 2×2
    /// (0,1)–(1,2), m3 2×2 (2,2)–(3,3): полоса 0 → 2 (m1, m2) → 3 (m2) → 4 (m3).
    func testFolderBandExpandsToFixedPoint() throws {
        let items: [(id: AnyHashable, size: TileSize)] = [
            (id: AnyHashable("f"), size: .small),
            (id: AnyHashable("s"), size: .small),
            (id: AnyHashable("m1"), size: .medium),
            (id: AnyHashable("m2"), size: .medium),
            (id: AnyHashable("m3"), size: .medium),
        ]
        let slots = TileLayoutEngine.pack(items: items, columns: 4, unit: 1)
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        XCTAssertEqual(byID["m1"].map { [$0.column, $0.row] }, [2, 0])
        XCTAssertEqual(byID["m2"].map { [$0.column, $0.row] }, [0, 1])
        XCTAssertEqual(byID["m3"].map { [$0.column, $0.row] }, [2, 2])

        XCTAssertEqual(try bandEnd(items, folderID: "f"), 4)
    }

    /// Соседи в строках папки, не выходящие ниже, полосу не расширяют; плитка
    /// целиком ниже — тоже.
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
