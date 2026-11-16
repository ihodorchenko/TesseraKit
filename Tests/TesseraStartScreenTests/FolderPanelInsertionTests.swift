//
//  FolderPanelInsertionTests.swift
//  TesseraStartScreenTests
//
//  Тесты чистой геометрии панели раскрытой папки (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»;
//  D17 в docs/STATE.md — панель вставляется отдельным элементом сразу после
//  плитки папки (плитка остаётся видимой), а геометрически занимает
//  полноширинную строку сразу после строки, в которой заканчивается папка;
//  всё, что начинается ниже этой строки, встаёт под панелью.
//
//  Проверяются только чистые функции `TesseraTileLayoutEngine`:
//  `folderPanelInsertionIndex`, `rowsBelowOffset`, `panelHeight`. Ни
//  UICollectionView, ни окно, ни layout-проход здесь не нужны: функции
//  детерминированы и зависят только от модели и числа колонок.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderPanelInsertionTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Высота строки заголовка панели: поля 12 pt сверху и снизу + 44 pt.
    private let headerHeight: CGFloat = 68

    /// Допуск сравнения геометрии в точках.
    private let accuracy: CGFloat = 0.0001

    /// Папка для теста раскладки.
    ///
    /// - Parameters:
    ///   - id: Идентификатор папки.
    ///   - title: Заголовок панели.
    ///   - tiles: Ярлыки внутри папки.
    ///   - size: Размер плитки-папки на сетке (по умолчанию 2×2).
    /// - Returns: Готовая модель `TesseraTileFolder`.
    private func makeFolder(
        _ id: String,
        title: String = "Папка",
        tiles: [TesseraTileDescriptor] = [],
        size: TesseraTileSize = .medium
    ) -> TesseraTileFolder {
        TesseraTileFolder(id: id, title: title, tiles: tiles, size: size)
    }

    /// Элементы набора для наглядных проверок порядка.
    ///
    /// - Parameter items: Элементы сетки.
    /// - Returns: Идентификаторы в порядке массива.
    private func ids(_ items: [TesseraTileGridItem]) -> [AnyHashable] {
        items.map { $0.id }
    }

    // MARK: - Индекс вставки панели (folderPanelInsertionIndex)

    /// Без раскрытой папки вставлять нечего.
    func testInsertionIndexIsNilWithoutExpandedFolder() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [.tile(tesseraTestTile("a")), .folder(folder)]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: nil
            )
        )
    }

    /// Папки нет в наборе — вставлять нечего (идентификатор не совпал).
    func testInsertionIndexIsNilWhenFolderIsMissing() {
        let items: [TesseraTileGridItem] = [.tile(tesseraTestTile("a"))]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: AnyHashable("missing")
            )
        )
    }

    /// Панель уже в наборе — второй раз её не вставляют.
    func testInsertionIndexIsNilWhenPanelIsAlreadyInserted() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .folderContent(folder),
        ]

        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            )
        )
    }

    /// Индекс вставки — сразу после плитки-папки, а не вместо неё.
    func testInsertionIndexPointsRightAfterFolderTile() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a", size: .small)),
            .folder(folder),
            .tile(tesseraTestTile("b", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            ),
            2
        )
    }

    /// Вставка не убирает плитку папки: число элементов растёт на один, плитка
    /// остаётся на своём индексе, панель идёт следующей.
    func testInsertionKeepsFolderTileAndGrowsItemCount() {
        let folder = makeFolder("f")
        var items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folder(folder),
            .tile(tesseraTestTile("b")),
            .tile(tesseraTestTile("c")),
        ]
        let before = ids(items)

        let index = TesseraTileLayoutEngine.folderPanelInsertionIndex(
            items: items,
            expandedFolderID: folder.id
        )
        XCTAssertEqual(index, 2)
        guard let index else { return }
        items.insert(.folderContent(folder), at: index)

        XCTAssertEqual(items.count, before.count + 1)
        // Плитка папки осталась на прежнем индексе: [a, folder, panel, b, c].
        XCTAssertEqual(ids(items), [before[0], before[1], folder.id, before[2], before[3]])
        XCTAssertEqual(items[1].folder?.id, folder.id)
        XCTAssertTrue(items[2].isFolderPanel)
        XCTAssertEqual(items[2].panelFolder?.id, folder.id)
    }

    /// Индекс работает для первой и последней папки: первая даёт 1, последняя —
    /// конец массива (вставка в конец).
    func testInsertionIndexWorksForFirstAndLastFolder() {
        let folder = makeFolder("f")
        let first: [TesseraTileGridItem] = [.folder(folder), .tile(tesseraTestTile("a"))]
        let last: [TesseraTileGridItem] = [.tile(tesseraTestTile("a")), .folder(folder)]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: first, expandedFolderID: folder.id),
            1
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: last, expandedFolderID: folder.id),
            2
        )
    }

    /// Индекс не зависит от размеров соседей: это позиция в массиве, а не в
    /// раскладке (строку панели считает уже геометрия вью-слоя).
    func testInsertionIndexIgnoresNeighbourSizes() {
        let folder = makeFolder("f", size: .medium)
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("wide", size: .wide)),
            .tile(tesseraTestTile("large", size: .large)),
            .folder(folder),
            .tile(tesseraTestTile("small", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            ),
            3
        )
    }

    /// Папка находится по идентификатору, а не по случаю элемента: панель
    /// вставляется после неё, даже если рядом стоят другие папки.
    func testInsertionIndexFindsFolderAmongTiles() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .tile(tesseraTestTile("b")),
            .folder(folder),
            .tile(tesseraTestTile("c")),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                expandedFolderID: folder.id
            ),
            3
        )
    }

    // MARK: - Отступ строк под панелью (rowsBelowOffset)

    /// Сосед в той же строке, что и 2×2-папка, остаётся на месте: панель
    /// начинается после строки, в которой заканчивается папка, а не с её
    /// верхнего края.
    func testRowsBelowOffsetIsZeroWhenNeighbourSharesFolderRow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("top", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Сосед в последней строке папки тоже остаётся на месте: первая строка
    /// панели идёт ниже неё.
    func testRowsBelowOffsetIsZeroWhenNeighbourSharesFolderLastRow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("a", size: .small)),
            .tile(tesseraTestTile("b", size: .small)),
            .tile(tesseraTestTile("c", size: .small)),
        ]

        // a и b — строка 0 (справа от папки), c — строка 1: все выше строки 2.
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Элемент, начинающийся ниже строки папки, уходит под панель: отступ
    /// равен её высоте плюс зазор сетки (по умолчанию 8 pt) — ровно на столько
    /// раскладка сдвигает первый ряд под панелью (E10.1).
    func testRowsBelowOffsetShiftsItemsBelowFolder() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            128,
            accuracy: accuracy
        )
    }

    /// Папка последняя: под панелью ничего нет, сдвигать нечего.
    func testRowsBelowOffsetIsZeroWhenNothingIsBelowFolder() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("wide", size: .wide)),
            .folder(folder),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Элементы, заканчивающиеся выше строки папки, остаются на месте.
    func testRowsBelowOffsetIsZeroWhenAllItemsAreAboveFolderRow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("wide", size: .wide)),
            .tile(tesseraTestTile("below", size: .wide)),
            .folder(folder),
        ]

        // «wide» — строки 0–1, «below» — строки 2–3, папка — строка 4.
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Несколько элементов под панелью не суммируются: отступ считается один
    /// раз, на одну высоту панели (плюс зазор сетки).
    func testRowsBelowOffsetCountsPanelOnceForSeveralItemsBelow() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("a", size: .small)),
            .tile(tesseraTestTile("b", size: .small)),
            .tile(tesseraTestTile("wide", size: .wide)),
            .tile(tesseraTestTile("c", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            128,
            accuracy: accuracy
        )
    }

    /// Панель уже в наборе — раскладка её влияние уже учла, повторный отступ 0.
    func testRowsBelowOffsetIsZeroWhenPanelIsAlreadyPresent() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .folderContent(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )
    }

    /// Нет раскрытой папки, папки нет в наборе или сетка вырождена — отступ 0.
    func testRowsBelowOffsetIsZeroForDegenerateInput() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: nil,
                panelHeight: 120
            ),
            0
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: AnyHashable("missing"),
                panelHeight: 120
            ),
            0
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 0,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0
        )
    }

    /// Нулевая, отрицательная или нечисловая высота панели не сдвигает строки.
    func testRowsBelowOffsetIgnoresInvalidPanelHeight() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        for height in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    items: items,
                    columns: 4,
                    expandedFolderID: folder.id,
                    panelHeight: height
                ),
                0,
                "Некорректная высота \(height) не должна сдвигать строки"
            )
        }
    }

    /// Отступ учитывает фактический зазор сетки (E10.1): `itemSpacing = 12`
    /// даёт `panelHeight + 12`; отрицательный и нечисловой зазор — 0.
    func testRowsBelowOffsetUsesGivenSpacing() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("below", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120,
                spacing: 12
            ),
            132,
            accuracy: accuracy
        )
        for spacing in [CGFloat(-4), .nan] {
            XCTAssertEqual(
                TesseraTileLayoutEngine.rowsBelowOffset(
                    items: items,
                    columns: 4,
                    expandedFolderID: folder.id,
                    panelHeight: 120,
                    spacing: spacing
                ),
                120,
                accuracy: accuracy
            )
        }
    }

    // MARK: - Полоса папки (E10.1)

    /// «Ступенька» `[папка 2×2, small, small, ярлык 2×2]`: ярлык — в строках
    /// 1–2, полоса папки — строки 0–2. Под панелью ничего нет, ярлык остаётся
    /// над ней, панель вставляется после ярлыка.
    func testStepTileIsPartOfFolderBand() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("s1", size: .small)),
            .tile(tesseraTestTile("s2", size: .small)),
            .tile(tesseraTestTile("m", size: .medium)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                columns: 4,
                expandedFolderID: folder.id
            ),
            4
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            0,
            accuracy: accuracy
        )

        // Плитка после «ступеньки» начинается ниже полосы — под панелью.
        let withBelow = items + [.tile(tesseraTestTile("w", size: .wide))]
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: withBelow,
                columns: 4,
                expandedFolderID: folder.id
            ),
            4
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: withBelow,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120
            ),
            128,
            accuracy: accuracy
        )
    }

    /// `[папка small, ярлык 2×2]`: 2×2 занимает строки 0–1, полоса — тоже;
    /// панель вставляется после ярлыка.
    func testTallNeighbourOfSmallFolderIsPartOfBand() {
        let folder = makeFolder("f", size: .small)
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("m", size: .medium)),
            .tile(tesseraTestTile("w", size: .wide)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                columns: 4,
                expandedFolderID: folder.id
            ),
            2
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.rowsBelowOffset(
                items: items,
                columns: 4,
                expandedFolderID: folder.id,
                panelHeight: 120,
                spacing: 8
            ),
            128,
            accuracy: accuracy
        )
    }

    /// Индекс вставки с колонками не раньше «сразу после папки» и идёт после
    /// элементов, поднятых компактностью в строки полосы.
    func testInsertionIndexWithColumnsFollowsLastBandItem() {
        let folder = makeFolder("f")
        // Папка (0,0)–(1,1); wide не помещается справа — строка 2; small
        // поднимается в (2,0): он в полосе, хотя в массиве после wide.
        let items: [TesseraTileGridItem] = [
            .folder(folder),
            .tile(tesseraTestTile("w", size: .wide)),
            .tile(tesseraTestTile("s", size: .small)),
        ]

        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items,
                columns: 4,
                expandedFolderID: folder.id
            ),
            3
        )
        // Без соседей в полосе — сразу после папки, как устаревший вход.
        let alone: [TesseraTileGridItem] = [.folder(folder), .tile(tesseraTestTile("w", size: .wide))]
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: alone, columns: 4, expandedFolderID: folder.id),
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: alone, expandedFolderID: folder.id)
        )
        // Вырожденные колонки — устаревший индекс; нет папки или панель уже
        // есть — nil.
        XCTAssertEqual(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: items, columns: 0, expandedFolderID: folder.id),
            1
        )
        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(items: items, columns: 4, expandedFolderID: nil)
        )
        XCTAssertNil(
            TesseraTileLayoutEngine.folderPanelInsertionIndex(
                items: items + [.folderContent(folder)],
                columns: 4,
                expandedFolderID: folder.id
            )
        )
    }

    /// Высота панели с зазором сетки (E10.1): ярлыки — юнит и зазор сетки.
    func testPanelHeightUsesGridSpacingAndScale() {
        let five = makeFolder("f", tiles: (0..<5).map { tesseraTestTile("t\($0)") })

        // 390 pt, зазор 12: юнит (390 − 36) / 4 = 88.5; 2 строки:
        // 68 + 8 + (2×88.5 + 12) = 265.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4, spacing: 12, scale: 0),
            265,
            accuracy: accuracy
        )
        // 3×: юнит 88.5 → 88⅓; 68 + 8 + (2×88⅓ + 12) = 264⅔.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4, spacing: 12, scale: 3),
            264 + 2.0 / 3.0,
            accuracy: accuracy
        )
        // Устаревший вход — зазор 8 без выравнивания.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4),
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4, spacing: 8, scale: 0),
            accuracy: accuracy
        )
    }

    // MARK: - Высота панели (panelHeight)

    /// Пустая папка: одна строка заголовка, без сетки содержимого.
    func testPanelHeightForEmptyFolderIsHeaderOnly() {
        let folder = makeFolder("f", tiles: [])

        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: folder, width: 390, columns: 4),
            headerHeight,
            accuracy: accuracy
        )
    }

    /// Заголовок занимает одну строку: его текст не меняет высоту панели.
    func testPanelHeightDoesNotDependOnFolderTitle() {
        let untitled = makeFolder("f", title: "")
        let titled = makeFolder("f", title: "Очень длинное название папки")

        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: untitled, width: 390, columns: 4),
            TesseraTileLayoutEngine.panelHeight(for: titled, width: 390, columns: 4),
            accuracy: accuracy
        )
    }

    /// Одна–четыре иконки — одна строка сетки содержимого.
    func testPanelHeightForSingleContentRow() {
        for count in 1...4 {
            let folder = makeFolder("f", tiles: (0..<count).map { tesseraTestTile("t\($0)") })

            // 390 pt: юнит сетки (390 − 3×8) / 4 = 91.5 — та же сторона, что
            // у плитки 1×1; высота = 68 (заголовок) + 8 (зазор) + 91.5 = 167.5.
            XCTAssertEqual(
                TesseraTileLayoutEngine.panelHeight(for: folder, width: 390, columns: 4),
                167.5,
                accuracy: accuracy,
                "Одна строка содержимого при \(count) ярлыках"
            )
        }
    }

    /// Пятая иконка открывает вторую строку, девятая — третью.
    func testPanelHeightGrowsWithContentRows() {
        let five = makeFolder("f", tiles: (0..<5).map { tesseraTestTile("t\($0)") })
        let nine = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })

        // 2 строки: 68 + 8 + (2×91.5 + 8) = 267.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 390, columns: 4),
            267,
            accuracy: accuracy
        )
        // 3 строки: 68 + 8 + (3×91.5 + 2×8) = 366.5.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: nine, width: 390, columns: 4),
            366.5,
            accuracy: accuracy
        )
    }

    /// Ширина меняет сторону ячейки, а значит и высоту панели.
    func testPanelHeightDependsOnWidth() {
        let four = makeFolder("f", tiles: (0..<4).map { tesseraTestTile("t\($0)") })
        let five = makeFolder("f", tiles: (0..<5).map { tesseraTestTile("t\($0)") })

        // 320 pt: юнит (320 − 3×8) / 4 = 74.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: four, width: 320, columns: 4),
            150,
            accuracy: accuracy
        )
        // 2 строки: 68 + 8 + (2×74 + 8) = 232.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: five, width: 320, columns: 4),
            232,
            accuracy: accuracy
        )

        XCTAssertGreaterThan(
            TesseraTileLayoutEngine.panelHeight(for: four, width: 390, columns: 4),
            TesseraTileLayoutEngine.panelHeight(for: four, width: 320, columns: 4)
        )
    }

    /// Число колонок сетки содержимого тоже меняет сторону ячейки.
    func testPanelHeightDependsOnColumns() {
        let folder = makeFolder("f", tiles: [tesseraTestTile("a")])

        // 390 pt, 2 колонки: юнит (390 − 8) / 2 = 191;
        // высота = 68 + 8 + 191 = 267.
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(for: folder, width: 390, columns: 2),
            267,
            accuracy: accuracy
        )
    }

    /// Отрицательное число ярлыков трактуется как пустая панель.
    func testPanelHeightClampsNegativeTileCount() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: -3, width: 390, columns: 4),
            headerHeight,
            accuracy: accuracy
        )
    }

    /// Вырожденная геометрия даёт нулевую высоту.
    func testPanelHeightIsZeroForDegenerateGeometry() {
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 24, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 23, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 0, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: -10, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: .nan, columns: 4),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 390, columns: 0),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            TesseraTileLayoutEngine.panelHeight(tileCount: 4, width: 390, columns: -4),
            0,
            accuracy: accuracy
        )
    }
}

#endif
