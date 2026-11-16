//
//  TileLayoutEngineFolderPlacementTests.swift
//  TesseraStartScreenTests
//
//  Геометрия панели раскрытой папки на размещениях по координатам (E14.2, D17,
//  D30). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 и «Отступления
//  реализации» п. 5, 49.
//
//  Варианты `folderBandEndRow(forFolder:...)`, `folderPanelInsertionIndex(
//  placements:...)` и `rowsBelowOffset(placements:...)` работают по готовым
//  ячейкам и не делают репак: строки ниже полосы папки сохраняют дыры, а панель
//  сдвигает их вниз на высоту панели (в точках — слой раскладки). На компактной
//  раскладке результат обязан совпасть со старыми вариантами по `TesseraTileGridItem`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileLayoutEngineFolderPlacementTests: XCTestCase {

    private let columns = 6

    // MARK: - folderBandEndRow

    /// Одинокая папка 2×2 — полоса из её двух строк.
    func testBandEndOfLoneFolderIsItsBottom() {
        let placements = [placementItem("f", .medium, 3, 0)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            5
        )
    }

    /// Плитка, начинающаяся в строках папки и заканчивающаяся ниже, расширяет
    /// полосу (итеративно, до неподвижной точки).
    func testBandEndExtendsOverTilesStartingInsideBand() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("tall", .medium, 1, 2),
            placementItem("chain", .medium, 2, 4),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            4
        )
    }

    /// Плитка за дырой ниже полосы полосу не расширяет.
    func testBandEndIgnoresTilesBelowAHole() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("far", .large, 6, 0),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            2
        )
    }

    /// Папки нет в наборе — `nil`.
    func testBandEndOfUnknownFolderIsNil() {
        XCTAssertNil(
            TesseraTileLayoutEngine.folderBandEndRow(
                forFolder: "none", in: [placementItem("a", .small, 0, 0)], columns: columns
            )
        )
    }

    /// Функция по слотам и по размещениям даёт одно и то же.
    func testBandEndMatchesSlotBasedVariant() {
        let placements = [
            placementItem("f", .medium, 1, 2),
            placementItem("a", .small, 2, 4),
            placementItem("b", .wide, 3, 0),
        ]
        let slots = TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 1, fitting: true)

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            TesseraTileLayoutEngine.folderBandEndRow(for: slots[0], in: slots)
        )
    }

    // MARK: - folderPanelInsertionIndex

    /// Панель встаёт после последнего элемента, оставшегося над ней; дыры не
    /// заполняются и порядок массива не пересчитывается.
    func testInsertionIndexAfterLastElementAbovePanelWithHoles() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("below", .small, 6, 0),
            placementItem("side", .small, 0, 3),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: "f"
            ),
            3
        )
    }

    /// Без элементов рядом панель — сразу после папки.
    func testInsertionIndexRightAfterFolderWhenNothingElseAbove() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("below", .small, 4, 0),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: "f"
            ),
            1
        )
    }

    /// Нет раскрытия или нет такой папки — `nil`.
    func testInsertionIndexNilWithoutExpansionOrFolder() {
        let placements = [placementItem("f", .medium, 0, 0)]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: nil
            )
        )
        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                placements: placements, columns: columns, expandedFolderID: "zzz"
            )
        )
    }

    // MARK: - rowsBelowOffset

    /// Есть что сдвигать (даже за дырой) — отступ `panelHeight + spacing`;
    /// ячейки при этом остаются прежними (панель не делает репак).
    func testRowsBelowOffsetShiftsTilesBelowBandWithoutRepacking() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("far", .small, 9, 3),
        ]

        let offset = TesseraTileLayoutEngine.rowsBelowOffset(
            placements: placements, columns: columns, expandedFolderID: "f", panelHeight: 100, spacing: 8
        )

        XCTAssertEqual(offset, 108)
        XCTAssertEqual(
            TesseraTileLayoutEngine.slots(placements: placements, columns: columns, unit: 1, fitting: true).map(\.row),
            [0, 9]
        )
    }

    /// Всё в полосе папки или ниже ничего нет — сдвиг 0.
    func testRowsBelowOffsetIsZeroWhenNothingBelowBand() {
        let placements = [
            placementItem("f", .medium, 0, 0),
            placementItem("tall", .medium, 1, 2),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                placements: placements, columns: columns, expandedFolderID: "f", panelHeight: 100
            ),
            0
        )
    }

    /// Вырожденные входы: высота 0, нет раскрытия, нет папки.
    func testRowsBelowOffsetDegenerateInputs() {
        let placements = [placementItem("f", .medium, 0, 0), placementItem("a", .small, 5, 0)]

        let cases: [(AnyHashable?, CGFloat)] = [(nil, 100), ("f", 0), ("zzz", 100), ("f", .nan)]
        for (expanded, height) in cases {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    placements: placements, columns: columns, expandedFolderID: expanded, panelHeight: height
                ),
                0
            )
        }
    }

    /// Отрицательный/нечисловой зазор трактуется как 0.
    func testRowsBelowOffsetSanitizesSpacing() {
        let placements = [placementItem("f", .medium, 0, 0), placementItem("a", .small, 5, 0)]

        for spacing in [CGFloat(-4), .nan] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    placements: placements, columns: columns, expandedFolderID: "f",
                    panelHeight: 100, spacing: spacing
                ),
                100
            )
        }
    }

    // MARK: - Совместимость со старым API на компактной раскладке

    /// Для компактной упаковки новые варианты совпадают со старыми по
    /// `TesseraTileGridItem` (индекс вставки и отступ строк под панелью).
    func testPlacementVariantsMatchLegacyItemsAPIOnCompactLayout() {
        let sizes = TesseraTileSize.allCases

        for seed in 1...25 {
            var generator = TesseraTestSeededGenerator(seed: UInt64(seed))
            let columns = [4, 6][generator.int(upperBound: 2)]
            let folderSize = sizes[generator.int(upperBound: sizes.count)]
            let folderPosition = generator.int(upperBound: 6)

            var items: [TesseraTileGridItem] = []
            for index in 0..<6 {
                items.append(.tile(tesseraTestTile("t\(index)", size: sizes[generator.int(upperBound: sizes.count)])))
            }
            items.insert(.folder(tesseraTestFolder("f", tileCount: 3, size: folderSize)), at: folderPosition)

            let packed = TesseraTileLayoutEngine.pack(
                items: items.map { (id: $0.id, size: $0.size) },
                columns: columns,
                unit: 1
            )
            let placements = packed.map {
                TesseraTilePlacedItem(id: $0.id, size: $0.size, cell: TesseraTileGridPlacement(row: $0.row, column: $0.column))
            }
            let context = "seed \(seed), columns \(columns)"

            XCTAssertEqual(
                TesseraTileLayoutEngine.folderPanelInsertionIndex(
                    placements: placements, columns: columns, expandedFolderID: "f"
                ),
                TesseraTileLayoutEngine.folderPanelInsertionIndex(
                    items: items, columns: columns, expandedFolderID: "f"
                ),
                context
            )
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    placements: placements, columns: columns, expandedFolderID: "f", panelHeight: 120
                ),
                TesseraTileLayoutEngine.rowsBelowOffset(
                    items: items, columns: columns, expandedFolderID: "f", panelHeight: 120
                ),
                context
            )
        }
    }

    /// Раскладка по слотам для одной и той же модели не зависит от дыр выше
    /// полосы: удаление плитки выше папки не меняет индекс вставки относительно
    /// оставшихся элементов (дыра не «схлопывается» панелью).
    func testRemovingTileAboveFolderLeavesBandAndShiftUnchanged() {
        let placements = [
            placementItem("top", .small, 0, 0),
            placementItem("f", .medium, 2, 0),
            placementItem("below", .small, 4, 0),
        ]
        let withoutTop = TesseraTileLayoutEngine.removing(id: "top", from: placements)

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: placements, columns: columns),
            TesseraTileLayoutEngine.folderBandEndRow(forFolder: "f", in: withoutTop, columns: columns)
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                placements: withoutTop, columns: columns, expandedFolderID: "f", panelHeight: 90
            ),
            98
        )
    }
}

#endif
