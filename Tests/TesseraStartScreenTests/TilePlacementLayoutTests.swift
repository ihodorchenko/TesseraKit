//
//  TilePlacementLayoutTests.swift
//  TesseraStartScreenTests
//
//  Раскладка по явным ячейкам: плитки встают на свои ячейки, дыры остаются
//  (E14.3, D30). Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3
//  «Плиточная сетка» и «Отступления реализации (E14)», п. 51; решения D30–D33
//  в docs/STATE.md.
//
//  Проверяется `TesseraTileCollectionViewLayout` на коллекции без окна и
//  руками собранных таблицах ячеек (`TileGridPlacementTable`):
//  - снимок с дырами: плитки не «проваливаются» в дыру, высота контента — по
//    нижней занятой строке, пустые хвостовые строки не считаются;
//  - откат на упаковку по порядку: таблицы нет, неполная, некорректная
//    (пересечение, выход за холст, отрицательная ячейка) или другой ширины —
//    кадры в точности прежние;
//  - ключ геометрии: смена одних ячеек (и одной заявленной ширины)
//    пересчитывает раскладку;
//  - раскрытая папка с дырами ниже: строки ниже полосы сдвигаются вниз на
//    высоту панели и зазор без репака, дыры сохраняются; откат на упаковку
//    сохраняет прежний репак под панелью (D17/D18);
//  - RTL: ячейки логические, зеркалит раскладка;
//  - узкая сетка: большая плитка ужимается, а не пропускается.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TilePlacementLayoutTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Масштаб пиксельного выравнивания тестов.
    private let scale: CGFloat = 2

    /// Раскладка на коллекции без окна.
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

    /// Ожидаемая геометрия сетки: те же формулы, что у раскладки (E10.1).
    private struct Geometry {
        let metrics: TileLayoutEngine.GridMetrics
        let left: CGFloat
        let top: CGFloat
        let rightToLeft: Bool

        init(width: CGFloat = 390, columns: Int = 4, spacing: CGFloat = 8, scale: CGFloat, rightToLeft: Bool = false) {
            let contentLeft = TileLayoutEngine.pixelRound(16, scale: scale)
            let contentRight = TileLayoutEngine.pixelRound(width - 16, scale: scale)
            metrics = TileLayoutEngine.gridMetrics(
                contentWidth: contentRight - contentLeft,
                columns: columns,
                spacing: spacing,
                scale: scale
            )!
            left = contentLeft + metrics.leading
            top = TileLayoutEngine.pixelRound(16, scale: scale)
            self.rightToLeft = rightToLeft
        }

        /// Шаг строки/колонки: юнит + зазор.
        var pitch: CGFloat { metrics.unit + metrics.spacing }

        /// Рамка плитки на ячейке (логические координаты).
        func frame(_ cell: TileGridPlacement, size: TileSize) -> CGRect {
            let slot = TileLayoutSlot(id: "x", size: size, column: cell.column, row: cell.row, unit: metrics.unit)
            var rect = TileLayoutEngine.rect(
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

    private func small(_ id: String) -> TileGridItem { .tile(tesseraTestTile(id, size: .small)) }
    private func medium(_ id: String) -> TileGridItem { .tile(tesseraTestTile(id, size: .medium)) }

    private func cell(_ row: Int, _ column: Int) -> TileGridPlacement {
        TileGridPlacement(row: row, column: column)
    }

    /// Рамки набора по индексу (раскладка получает набор и таблицу, как от сетки).
    private func frames(
        _ harness: Harness,
        _ items: [TileGridItem],
        table: TileGridPlacementTable?
    ) throws -> [CGRect] {
        harness.layout.setItems(items, placements: table, reason: .items)
        return try items.indices.map { try XCTUnwrap(harness.layout.frame(forItemAt: $0), "кадр \($0)") }
    }

    /// Размещения набора в порядке `items` — для индекса вставки панели.
    private func placed(_ items: [TileGridItem], table: TileGridPlacementTable) -> [TilePlacedItem] {
        items.compactMap { item in
            guard !item.isFolderPanel, let cell = table.cells[item.id] else { return nil }
            return TilePlacedItem(id: item.id, size: item.size, cell: cell)
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

    // MARK: - Дыры

    /// Плитки встают на свои ячейки; дыра остаётся, ничто не поднимается в неё.
    func testHolesStayAndTilesDoNotBackfill() throws {
        let items = [small("a"), small("b"), small("c")]
        let table = TileGridPlacementTable(
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
            "кадры по ячейкам"
        )
        XCTAssertEqual(result[2].minY - result[0].minY, 2 * g.pitch, accuracy: 0.001, "две пустые строки над c")
        XCTAssertEqual(result[1].minX - result[0].minX, 3 * g.pitch, accuracy: 0.001, "две пустые колонки между a и b")

        // Без таблицы те же плитки были бы упакованы вплотную в первую строку.
        let packed = try frames(makeHarness(), items, table: nil)
        XCTAssertEqual(packed[2].minY, packed[0].minY, accuracy: 0.001)
        XCTAssertGreaterThan(result[2].minY, packed[2].minY)
    }

    /// Высота контента — нижняя граница самой нижней занятой строки; пустые
    /// хвостовые строки (таблица лишних ячеек) не прибавляют высоты.
    func testContentHeightIsBottomOfLowestOccupiedRow() throws {
        let harness = makeHarness()
        let items = [small("a"), medium("b")]
        let table = TileGridPlacementTable(
            cells: ["a": cell(0, 0), "b": cell(3, 2), "ghost": cell(50, 0)],
            columns: 4
        )
        let result = try frames(harness, items, table: table)
        let lowest = result.map(\.maxY).max() ?? 0
        XCTAssertEqual(
            harness.layout.collectionViewContentSize.height,
            lowest + 16,
            accuracy: 0.001,
            "нижняя занятая строка + нижнее поле"
        )
        XCTAssertLessThan(harness.layout.collectionViewContentSize.height, Geometry(scale: scale).top + 50 * Geometry(scale: scale).pitch)
    }

    /// Единственная плитка глубоко вниз: пустые строки над ней сохраняются.
    func testLeadingEmptyRowsAreKept() throws {
        let harness = makeHarness()
        let result = try frames(
            harness,
            [small("a")],
            table: TileGridPlacementTable(cells: ["a": cell(5, 0)], columns: 4)
        )
        let g = Geometry(scale: scale)
        XCTAssertEqual(result[0].minY, g.top + 5 * g.pitch, accuracy: 0.001)
        XCTAssertEqual(harness.layout.collectionViewContentSize.height, result[0].maxY + 16, accuracy: 0.001)
    }

    /// Большая плитка на узкой сетке ужимается и не пропускается; след считает
    /// `fittingSize`, дыра под ней остаётся.
    func testWideTileOnNarrowGridIsFittedNotSkipped() throws {
        let harness = makeHarness(columns: 2)
        let items: [TileGridItem] = [.tile(tesseraTestTile("w", size: .wide)), small("s")]
        let table = TileGridPlacementTable(cells: ["w": cell(0, 0), "s": cell(3, 1)], columns: 2)
        let result = try frames(harness, items, table: table)
        let g = Geometry(columns: 2, scale: scale)

        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        assertFrames(
            result,
            [g.frame(cell(0, 0), size: TileLayoutEngine.fittingSize(.wide, columns: 2)), g.frame(cell(3, 1), size: .small)],
            "ужатая плитка и малая плитка после дыры"
        )
    }

    // MARK: - Откат на упаковку

    /// Все виды негодной таблицы дают в точности прежние кадры упаковки.
    func testFallbackToPackOverOrderKeepsLegacyFrames() throws {
        let items = [small("a"), small("b"), medium("c"), small("d")]
        let reference = try frames(makeHarness(), items, table: nil)

        let good: [AnyHashable: TileGridPlacement] = [
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

        let cases: [(String, TileGridPlacementTable?)] = [
            ("таблицы нет", nil),
            ("пустая таблица", TileGridPlacementTable(cells: [:], columns: 4)),
            ("неполная", TileGridPlacementTable(cells: incomplete, columns: 4)),
            ("пересечение", TileGridPlacementTable(cells: overlapping, columns: 4)),
            ("плитка вне холста", TileGridPlacementTable(cells: outside, columns: 4)),
            ("широкая плитка выходит за холст", TileGridPlacementTable(cells: tooWide, columns: 4)),
            ("отрицательная строка", TileGridPlacementTable(cells: negative, columns: 4)),
            ("другая ширина холста", TileGridPlacementTable(cells: good, columns: 6)),
        ]
        for (name, table) in cases {
            let harness = makeHarness()
            let result = try frames(harness, items, table: table)
            XCTAssertFalse(harness.layout.usesExplicitPlacements, name)
            assertFrames(result, reference, name)
        }

        // Контроль: корректная полная таблица — другая картинка.
        let harness = makeHarness()
        let explicit = try frames(harness, items, table: TileGridPlacementTable(cells: good, columns: 4))
        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        XCTAssertNotEqual(explicit[3].minY, reference[3].minY)
    }

    /// Ширина холста не заявлена (`nil`): таблицу проверяет только `validate`.
    func testTableWithoutDeclaredWidthIsValidatedOnGridWidth() throws {
        let items = [small("a"), small("b")]
        let harness = makeHarness()
        _ = try frames(
            harness,
            items,
            table: TileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(4, 1)], columns: nil)
        )
        XCTAssertTrue(harness.layout.usesExplicitPlacements)

        _ = try frames(
            harness,
            items,
            table: TileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(0, 4)], columns: nil)
        )
        XCTAssertFalse(harness.layout.usesExplicitPlacements, "колонка 4 вне холста из 4 колонок")
    }

    // MARK: - Ключ геометрии

    /// Одна лишь смена ячейки (состав, размеры и порядок те же) пересчитывает
    /// раскладку; та же таблица повторно — кадры не меняются.
    func testCellOnlyChangeInvalidatesGeometry() throws {
        let harness = makeHarness()
        let items = [small("a"), small("b")]
        let first = TileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(1, 1)], columns: 4)
        let second = TileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(4, 1)], columns: 4)

        let before = try frames(harness, items, table: first)
        let again = try frames(harness, items, table: first)
        assertFrames(again, before, "та же таблица — те же кадры")

        let after = try frames(harness, items, table: second)
        let g = Geometry(scale: scale)
        XCTAssertEqual(after[1].minY - before[1].minY, 3 * g.pitch, accuracy: 0.001, "b ушла на три строки вниз")
        assertFrames([after[0]], [before[0]], "a не двигалась")
    }

    /// Смена одной заявленной ширины таблицы (те же ячейки) переключает раскладку
    /// между явными ячейками и упаковкой.
    func testDeclaredWidthChangeInvalidatesGeometry() throws {
        let harness = makeHarness()
        let items = [small("a"), small("b")]
        let cells: [AnyHashable: TileGridPlacement] = ["a": cell(0, 0), "b": cell(3, 2)]

        let explicit = try frames(harness, items, table: TileGridPlacementTable(cells: cells, columns: 4))
        XCTAssertTrue(harness.layout.usesExplicitPlacements)
        let fallback = try frames(harness, items, table: TileGridPlacementTable(cells: cells, columns: 6))
        XCTAssertFalse(harness.layout.usesExplicitPlacements)
        XCTAssertNotEqual(explicit[1].minY, fallback[1].minY)
    }

    /// Смена числа колонок сетки делает таблицу чужой: откат на упаковку без
    /// повторной подачи набора.
    func testGridColumnsChangeMakesTableForeign() throws {
        let harness = makeHarness(columns: 4)
        let items = [small("a"), small("b")]
        let table = TileGridPlacementTable(cells: ["a": cell(0, 0), "b": cell(3, 2)], columns: 4)
        _ = try frames(harness, items, table: table)
        XCTAssertTrue(harness.layout.usesExplicitPlacements)

        harness.layout.columns = 6
        _ = harness.layout.frame(forItemAt: 0)
        XCTAssertFalse(harness.layout.usesExplicitPlacements)
    }

    // MARK: - Панель раскрытой папки

    /// Набор: папка 2×2 с соседями в полосе и три плитки ниже с дырами.
    private func panelScenario() -> (folder: TileFolder, items: [TileGridItem], table: TileGridPlacementTable) {
        let folder = tesseraTestFolder("f", tileCount: 6)
        let items: [TileGridItem] = [
            .folder(folder), small("s1"), small("s2"), small("x"), small("y"), medium("m"),
        ]
        let table = TileGridPlacementTable(
            cells: [
                "f": cell(0, 0), "s1": cell(0, 2), "s2": cell(1, 3),
                "x": cell(4, 0), "y": cell(7, 3), "m": cell(4, 2),
            ],
            columns: 4
        )
        return (folder, items, table)
    }

    /// Панель с явными ячейками: полоса и всё выше — на месте, строки ниже
    /// сдвигаются вниз на высоту панели и зазор, дыры между ними и под панелью
    /// сохраняются (репака нет).
    func testExpandedPanelShiftsRowsBelowWithoutRepack() throws {
        let scenario = panelScenario()
        let harness = makeHarness()
        let g = Geometry(scale: scale)

        let collapsed = try frames(harness, scenario.items, table: scenario.table)

        let panelIndex = try XCTUnwrap(
            TileLayoutEngine.folderPanelInsertionIndex(
                placements: placed(scenario.items, table: scenario.table),
                columns: 4,
                expandedFolderID: scenario.folder.id
            )
        )
        var expandedItems = scenario.items
        expandedItems.insert(.folderContent(scenario.folder), at: panelIndex)
        let open = try frames(harness, expandedItems, table: scenario.table)
        XCTAssertTrue(harness.layout.usesExplicitPlacements)

        // Индексы базовых элементов в раскрытом наборе.
        func openFrame(_ baseIndex: Int) -> CGRect { open[baseIndex < panelIndex ? baseIndex : baseIndex + 1] }
        let panel = open[panelIndex]

        // Полоса (папка 2×2 + s1 + s2) — строки 0–1, панель — со строки 2.
        XCTAssertEqual(panel.minY, g.top + 2 * g.pitch, accuracy: 0.001)
        XCTAssertGreaterThan(panel.height, 0)
        for baseIndex in 0...2 {
            assertFrames([openFrame(baseIndex)], [collapsed[baseIndex]], "полоса не двигается: \(baseIndex)")
        }

        // x, y, m — на высоту панели и зазор ниже; взаимное положение сохранено.
        let shift = panel.height + g.metrics.spacing
        for baseIndex in 3...5 {
            XCTAssertEqual(
                openFrame(baseIndex).minY - collapsed[baseIndex].minY,
                shift,
                accuracy: 0.001,
                "сдвиг на панель: \(baseIndex)"
            )
            XCTAssertEqual(openFrame(baseIndex).minX, collapsed[baseIndex].minX, accuracy: 0.001)
        }
        XCTAssertEqual(openFrame(4).minY - openFrame(3).minY, 3 * g.pitch, accuracy: 0.001, "дыра между x и y")
        XCTAssertEqual(openFrame(3).minY - panel.maxY, 2 * g.pitch + g.metrics.spacing, accuracy: 0.001, "две пустые строки под панелью")

        // Ничто не пересекается; высота контента — по нижней занятой строке.
        for lhs in open.indices {
            for rhs in open.indices where rhs > lhs {
                XCTAssertFalse(overlaps(open[lhs], open[rhs]), "\(lhs) и \(rhs) пересекаются")
            }
        }
        XCTAssertEqual(
            harness.layout.collectionViewContentSize.height,
            open.map(\.maxY).max()! + 16,
            accuracy: 0.001
        )
    }

    /// Откат на упаковку сохраняет прежний репак под панелью: первая плитка под
    /// панелью встаёт сразу под ней, на зазор ниже (D17/D18, E10.1).
    func testExpandedPanelFallbackKeepsLegacyRepack() throws {
        let scenario = panelScenario()
        let harness = makeHarness()

        let panelIndex = try XCTUnwrap(
            TileLayoutEngine.folderPanelInsertionIndex(
                items: scenario.items,
                columns: 4,
                expandedFolderID: scenario.folder.id
            )
        )
        var expandedItems = scenario.items
        expandedItems.insert(.folderContent(scenario.folder), at: panelIndex)
        let open = try frames(harness, expandedItems, table: nil)
        XCTAssertFalse(harness.layout.usesExplicitPlacements)

        // По упаковке `m` (2×2) — единственная плитка ниже полосы, и она
        // встаёт сразу под панелью.
        let panel = open[panelIndex]
        let mIndex = expandedItems.firstIndex { !$0.isFolderPanel && $0.id == AnyHashable("m") }!
        XCTAssertEqual(open[mIndex].minY, panel.maxY + 8, accuracy: 0.001)

        // Негодная таблица ведёт себя так же.
        let broken = TileGridPlacementTable(cells: ["f": cell(0, 0)], columns: 4)
        let fallback = try frames(harness, expandedItems, table: broken)
        XCTAssertFalse(harness.layout.usesExplicitPlacements)
        assertFrames(fallback, open, "неполная таблица — прежние кадры")
    }

    // MARK: - RTL

    /// Ячейки логические: колонка 0 в RTL — правый край сетки; зеркалит
    /// раскладка, а не таблица.
    func testExplicitCellsAreMirroredInRightToLeft() throws {
        let items = [small("a"), small("b"), medium("c")]
        let table = TileGridPlacementTable(
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
            "зеркальные кадры"
        )
        XCTAssertEqual(rtl[0].maxX, g.left + g.metrics.width, accuracy: 0.001, "колонка 0 — правый край")
        XCTAssertEqual(rtl[1].minX, g.left, accuracy: 0.001, "колонка 3 — левый край")
        for index in items.indices {
            XCTAssertEqual(rtl[index].minY, ltr[index].minY, accuracy: 0.001, "строки не зеркалятся")
            XCTAssertEqual(
                rtl[index].minX - g.left,
                g.metrics.width - (ltr[index].maxX - g.left),
                accuracy: 0.001,
                "зеркало внутри ширины сетки"
            )
        }
    }
}

#endif
