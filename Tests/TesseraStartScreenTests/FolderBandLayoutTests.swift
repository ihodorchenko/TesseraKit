//
//  FolderBandLayoutTests.swift
//  TesseraStartScreenTests
//
//  Тесты раскладки панели раскрытой папки по «полосе папки» (E10.1, D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»,
//  «Отступления реализации» п. 5; D17/D18 в docs/STATE.md — панель встаёт
//  полноширинной строкой ПОД плиткой папки.
//
//  До E10.1 решение «остаётся над панелью / уходит под панель» принималось по
//  верхней строке плитки (`slot.row < folderEndRow`): плитка, начинающаяся в
//  строках папки и заканчивающаяся ниже, оставалась на месте и перекрывалась
//  панелью. Здесь проверяется настоящая раскладка
//  (`TesseraTileCollectionViewLayout`) на коллекции без окна: ни один элемент
//  не пересекается с панелью и друг с другом, порядок элементов совпадает с
//  визуальным (всё до панели — над ней, всё после — под ней).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderBandLayoutTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Раскладка на коллекции заданной ширины (окно не нужно).
    private struct Harness {

        /// Раскладка под тестом.
        let layout: TesseraTileCollectionViewLayout

        /// Коллекция-владелец: раскладка берёт из неё `bounds`.
        let collectionView: UICollectionView
    }

    /// Создаёт раскладку на коллекции без окна.
    ///
    /// - Parameters:
    ///   - width: Ширина коллекции.
    ///   - columns: Число колонок.
    ///   - spacing: Зазор сетки.
    ///   - scale: Масштаб выравнивания (`nil` — из `traitCollection`).
    /// - Returns: Готовая раскладка и коллекция.
    private func makeHarness(
        width: CGFloat = 390,
        columns: Int = 4,
        spacing: CGFloat = 8,
        scale: CGFloat? = nil
    ) -> Harness {
        let layout = TesseraTileCollectionViewLayout()
        layout.columns = columns
        layout.itemSpacing = spacing
        layout.displayScaleOverride = scale
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: width, height: 844),
            collectionViewLayout: layout
        )
        return Harness(layout: layout, collectionView: collectionView)
    }

    /// Рамки всех элементов набора по индексу.
    ///
    /// - Parameters:
    ///   - harness: Раскладка.
    ///   - items: Набор (с панелью или без).
    /// - Returns: Рамки в порядке набора; пустой массив, если раскладка не
    ///   отдала рамку хотя бы одному элементу.
    private func frames(in harness: Harness, items: [TileGridItem]) -> [CGRect] {
        harness.layout.setItems(items, reason: .items)
        var result: [CGRect] = []
        for index in items.indices {
            guard let frame = harness.layout.frame(forItemAt: index) else { return [] }
            result.append(frame)
        }
        return result
    }

    /// Набор с панелью, вставленной по индексу движка (как это делает сетка).
    ///
    /// - Parameters:
    ///   - items: Базовый набор без панели.
    ///   - folder: Раскрываемая папка.
    ///   - columns: Число колонок.
    /// - Returns: Набор с панелью и её индекс.
    private func expanded(
        _ items: [TileGridItem],
        folder: TileFolder,
        columns: Int = 4
    ) -> (items: [TileGridItem], panelIndex: Int)? {
        guard let index = TileLayoutEngine.folderPanelInsertionIndex(
            items: items,
            columns: columns,
            expandedFolderID: folder.id
        ) else {
            return nil
        }
        var result = items
        result.insert(.folderContent(folder), at: index)
        return (result, index)
    }

    /// Пересекаются ли рамки по площади (касание краями не считается).
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 0.001 && intersection.height > 0.001
    }

    /// Папка с заданным числом ярлыков.
    private func makeFolder(_ id: String, size: TileSize = .medium, tileCount: Int = 3) -> TileFolder {
        TileFolder(
            id: id,
            title: id,
            tiles: (0..<tileCount).map { tesseraTestTile("\(id)-t\($0)", size: .small) },
            size: size
        )
    }

    // MARK: - Примеры из ревью

    /// «Ступенька» `[папка 2×2, small, small, ярлык 2×2]`, 4 колонки: ярлык
    /// стоит в строках 1–2, полоса папки — строки 0–2, панель встаёт со строки
    /// 3 и ярлык не перекрывает.
    func testStepTileStartingInFolderRowsStaysAbovePanel() throws {
        let folder = makeFolder("f")
        let shortcut = tesseraTestTile("m", size: .medium)
        let base: [TileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(shortcut),
        ]
        let harness = makeHarness()
        let collapsed = frames(in: harness, items: base)
        XCTAssertEqual(collapsed.count, base.count)

        let open = try XCTUnwrap(expanded(base, folder: folder))
        // Ярлык — в полосе папки: панель идёт после него и в массиве.
        XCTAssertEqual(open.panelIndex, 4)

        let openFrames = frames(in: harness, items: open.items)
        XCTAssertEqual(openFrames.count, open.items.count)
        let panel = openFrames[open.panelIndex]

        let shortcutBefore = collapsed[3]
        let shortcutAfter = openFrames[3]
        // Ярлык на месте, панель — под ним, без пересечения.
        XCTAssertEqual(shortcutAfter, shortcutBefore)
        XCTAssertFalse(overlaps(shortcutAfter, panel))
        XCTAssertGreaterThanOrEqual(panel.minY, shortcutAfter.maxY + 8 - 0.001)
        // Папка тоже на месте.
        XCTAssertEqual(openFrames[0], collapsed[0])
    }

    /// `[папка small, ярлык 2×2]`: ярлык в строках 0–1, папка — строка 0;
    /// панель встаёт со строки 2, а не 1.
    func testMediumNextToSmallFolderStaysAbovePanel() throws {
        let folder = makeFolder("f", size: .small)
        let shortcut = tesseraTestTile("m", size: .medium)
        let base: [TileGridItem] = [.folder(folder), .tile(shortcut)]
        let harness = makeHarness()
        let collapsed = frames(in: harness, items: base)

        let open = try XCTUnwrap(expanded(base, folder: folder))
        XCTAssertEqual(open.panelIndex, 2)

        let openFrames = frames(in: harness, items: open.items)
        XCTAssertEqual(openFrames.count, open.items.count)
        let panel = openFrames[open.panelIndex]

        XCTAssertEqual(openFrames[1], collapsed[1])
        XCTAssertFalse(overlaps(openFrames[1], panel))
        XCTAssertFalse(overlaps(openFrames[0], panel))
    }

    /// Плитка ниже полосы уходит под панель: первый ряд под панелью — на
    /// `panelHeight + spacing` от её верхнего края, как и сообщает
    /// `rowsBelowOffset`.
    func testItemBelowBandMovesUnderPanelByReportedOffset() throws {
        let folder = makeFolder("f")
        let wide = tesseraTestTile("w", size: .wide)
        let base: [TileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(tesseraTestTile("m", size: .medium)),
            .tile(wide),
        ]
        let harness = makeHarness()
        let open = try XCTUnwrap(expanded(base, folder: folder))
        XCTAssertEqual(open.panelIndex, 4)

        let openFrames = frames(in: harness, items: open.items)
        XCTAssertEqual(openFrames.count, open.items.count)
        let panel = openFrames[open.panelIndex]
        let wideFrame = openFrames[5]

        let offset = TileLayoutEngine.rowsBelowOffset(
            items: base,
            columns: 4,
            expandedFolderID: folder.id,
            panelHeight: panel.height
        )
        XCTAssertEqual(wideFrame.minY - panel.minY, offset, accuracy: 0.001)
        XCTAssertEqual(offset, panel.height + 8, accuracy: 0.001)
    }

    // MARK: - Рандомизированная проверка

    /// Сотни seeded-конфигураций (размеры плиток, размер и позиция папки, число
    /// колонок): ни один элемент не пересекается с панелью и с другими
    /// элементами; каждый элемент целиком над панелью или целиком под ней;
    /// всё, что над панелью, идёт в массиве до неё (индекс вставки — после
    /// всей полосы папки) и не сдвигается относительно свёрнутой сетки.
    func testRandomConfigurationsNeverOverlapPanel() {
        var generator = TesseraTestSeededGenerator(seed: 0xE10_1)
        let sizes: [TileSize] = [.small, .small, .small, .medium, .medium, .wide, .large]
        let folderSizes: [TileSize] = [.small, .medium, .medium, .wide, .large]
        let columnChoices = [4, 4, 4, 3, 6]
        let harnesses = Dictionary(
            uniqueKeysWithValues: Set(columnChoices).map { ($0, makeHarness(columns: $0)) }
        )

        for configuration in 0..<400 {
            let columns = columnChoices[generator.int(upperBound: columnChoices.count)]
            guard let harness = harnesses[columns] else { return XCTFail("Нет раскладки") }

            let count = 1 + generator.int(upperBound: 14)
            var base: [TileGridItem] = (0..<count).map { index in
                .tile(tesseraTestTile("c\(configuration)-\(index)", size: sizes[generator.int(upperBound: sizes.count)]))
            }
            let folder = makeFolder(
                "folder-\(configuration)",
                size: folderSizes[generator.int(upperBound: folderSizes.count)],
                tileCount: 1 + generator.int(upperBound: 9)
            )
            base.insert(.folder(folder), at: generator.int(upperBound: base.count + 1))

            let collapsed = frames(in: harness, items: base)
            guard let open = expanded(base, folder: folder, columns: columns) else {
                return XCTFail("Нет индекса вставки, конфигурация \(configuration)")
            }
            let openFrames = frames(in: harness, items: open.items)
            guard openFrames.count == open.items.count, collapsed.count == base.count else {
                return XCTFail("Раскладка не отдала рамки, конфигурация \(configuration)")
            }

            let panel = openFrames[open.panelIndex]
            XCTAssertGreaterThan(panel.height, 0, "Конфигурация \(configuration)")

            for index in openFrames.indices where index != open.panelIndex {
                let frame = openFrames[index]
                XCTAssertFalse(
                    overlaps(frame, panel),
                    "Элемент \(index) перекрыт панелью, конфигурация \(configuration)"
                )
                let isAbove = frame.maxY <= panel.minY + 0.001
                let isBelow = frame.minY >= panel.maxY - 0.001
                XCTAssertTrue(isAbove || isBelow, "Элемент \(index) задевает строку панели (\(configuration))")
                if isAbove {
                    // Всё, что над панелью, идёт в массиве до неё и не двигается.
                    XCTAssertLessThan(index, open.panelIndex, "Элемент \(index) над панелью, но после неё (\(configuration))")
                    if index < open.panelIndex {
                        XCTAssertEqual(frame, collapsed[index], "Сдвиг над панелью (\(configuration))")
                    }
                }
                for other in openFrames.indices where other > index && other != open.panelIndex {
                    XCTAssertFalse(
                        overlaps(frame, openFrames[other]),
                        "Элементы \(index) и \(other) пересекаются, конфигурация \(configuration)"
                    )
                }
            }
        }
    }

    // MARK: - Зазор панели (E10.1)

    /// При `itemSpacing = 12` ярлыки панели встают в колонки сетки: их x и
    /// ширина совпадают с плитками 1×1 под теми же колонками, шаг строк —
    /// юнит + 12.
    func testPanelShortcutsAlignWithGridColumnsForCustomSpacing() throws {
        let folder = makeFolder("f", size: .medium, tileCount: 6)
        let smalls = (0..<4).map { tesseraTestTile("s\($0)", size: .small) }
        let items: [TileGridItem] = smalls.map { .tile($0) } + [.folder(folder)]

        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 393, height: 1200))
        grid.itemSpacing = 12
        grid.reload(snapshot: TileGridSnapshot(items: items, unpinned: []))
        layoutGrid(grid)
        grid.openFolder(folder, animated: false)
        layoutGrid(grid)

        let collectionView = try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
        let panelIndex = try XCTUnwrap(grid.displayItems.firstIndex { $0.isFolderPanel })
        let panelCell = try XCTUnwrap(
            collectionView.cellForItem(at: IndexPath(item: panelIndex, section: 0)) as? TesseraFolderPanelCell
        )
        panelCell.layoutIfNeeded()

        let shortcutFrames = panelCell.contentView.subviews
            .compactMap { $0 as? TesseraTileCell }
            .map { panelCell.contentView.convert($0.frame, to: collectionView) }
        XCTAssertEqual(shortcutFrames.count, 6)

        let columnFrames = try smalls.map { try XCTUnwrap(grid.frame(forItemID: $0.id)) }
            .map { grid.convert($0, to: collectionView) }

        for (index, shortcut) in shortcutFrames.enumerated() {
            let column = columnFrames[index % 4]
            XCTAssertEqual(shortcut.minX, column.minX, accuracy: 0.001, "Ярлык \(index): колонка")
            XCTAssertEqual(shortcut.width, column.width, accuracy: 0.001, "Ярлык \(index): ширина")
        }
        // Вторая строка ярлыков — через юнит и зазор сетки 12.
        XCTAssertEqual(
            shortcutFrames[4].minY - shortcutFrames[0].minY,
            columnFrames[0].height + 12,
            accuracy: 0.001
        )
        // Зазор между колонками — 12 и в панели.
        XCTAssertEqual(shortcutFrames[1].minX - shortcutFrames[0].maxX, 12, accuracy: 0.001)
    }

    /// Прогоняет layout сетки и её коллекции.
    private func layoutGrid(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }
}

#endif
