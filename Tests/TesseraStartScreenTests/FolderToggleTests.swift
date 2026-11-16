//
//  FolderToggleTests.swift
//  TesseraStartScreenTests
//
//  Тесты state-машины раскрытия папки (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»;
//  D17 в docs/STATE.md — одновременно раскрыта максимум одна папка, панель
//  вставляется отдельным элементом под плитку папки (плитка остаётся видимой),
//  закрытие повторным тапом/явным вызовом хоста.
//
//  Чистой функции open/close в API нет: состоянием владеет `TesseraTileGridView`
//  (`expandedFolderID`), а методы `openFolder`/`toggleFolder`/`closeFolder`
//  работают и без окна. Вне окна `canAnimateFolderChange` = false, поэтому
//  сетка проходит неанимированную ветку синхронно — UI-цикл и таймеры не нужны.
//  Набор коллекции читается по внутреннему `displayItems` (панель — UI-слой,
//  не данные), данные — по публичному `items`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderToggleTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Ширина сетки в тестах (как у iPhone 13/14).
    private let gridWidth: CGFloat = 390

    /// Внешние поля сетки по умолчанию (по 16 pt).
    private let gridInsets: CGFloat = 16

    /// Зазор между юнитами по умолчанию.
    private let gridSpacing: CGFloat = 8

    /// Ширина контента сетки (без внешних полей).
    private var contentWidth: CGFloat {
        gridWidth - gridInsets * 2
    }

    /// Юнит сетки при ширине `contentWidth`, четырёх колонках и зазоре 8.
    private var unit: CGFloat {
        (contentWidth - gridSpacing * 3) / 4
    }

    /// Папка с одним ярлыком (или с заданными ярлыками).
    ///
    /// - Parameters:
    ///   - id: Идентификатор папки.
    ///   - tiles: Ярлыки внутри папки.
    /// - Returns: Модель папки.
    private func makeFolder(
        _ id: String,
        tiles: [TesseraTileDescriptor] = [tesseraTestTile("f-tile")]
    ) -> TesseraTileFolder {
        TesseraTileFolder(id: id, title: id, tiles: tiles)
    }

    /// Сетка, разложенная вручную: окно не нужно, коллекция получает bounds.
    ///
    /// - Parameters:
    ///   - items: Элементы снимка в порядке отображения.
    ///   - columns: Число колонок сетки.
    /// - Returns: Готовая сетка без окна.
    private func makeGrid(_ items: [TesseraTileGridItem], columns: Int = 4) -> TesseraTileGridView {
        let grid = TesseraTileGridView(
            frame: CGRect(x: 0, y: 0, width: gridWidth, height: 844)
        )
        grid.columns = columns
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layout(grid)
        return grid
    }

    /// Прогоняет layout сетки и её коллекции: ячейки и рамки актуальны.
    ///
    /// - Parameter grid: Сетка.
    private func layout(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    /// Коллекция внутри сетки.
    ///
    /// - Parameter grid: Сетка.
    /// - Returns: Коллекция или `nil`, если иерархия сломана.
    private func collectionView(in grid: TesseraTileGridView) -> UICollectionView? {
        grid.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// Фактическая рамка элемента коллекции в координатах контента.
    ///
    /// Берётся из атрибутов раскладки: ячейка за пределами экрана могла ещё не
    /// создаться, а рамка панели нужна и для проверок геометрии.
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - index: Индекс элемента в наборе коллекции.
    /// - Returns: Рамка или `nil`.
    private func frame(in grid: TesseraTileGridView, at index: Int) -> CGRect? {
        guard let collectionView = collectionView(in: grid) else { return nil }
        return collectionView.collectionViewLayout
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?
            .frame
    }

    /// Индексы панелей раскрытой папки в наборе коллекции.
    ///
    /// - Parameter grid: Сетка.
    /// - Returns: Индексы элементов `folderContent`.
    private func panelIndices(in grid: TesseraTileGridView) -> [Int] {
        grid.displayItems.indices.filter { grid.displayItems[$0].isFolderPanel }
    }

    /// Есть ли в наборе панель указанной папки.
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - id: Идентификатор папки.
    /// - Returns: `true`, если панель вставлена.
    private func hasPanel(in grid: TesseraTileGridView, folderID: AnyHashable) -> Bool {
        grid.displayItems.contains { $0.isFolderPanel && $0.id == folderID }
    }

    /// Индекс плитки-папки в наборе (панель пропускается).
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - id: Идентификатор папки.
    /// - Returns: Индекс в `displayItems` или `nil`.
    private func folderIndex(in grid: TesseraTileGridView, folderID: AnyHashable) -> Int? {
        grid.displayItems.firstIndex { !$0.isFolderPanel && $0.folder?.id == folderID }
    }

    /// Ячейка папки в сетке.
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - id: Идентификатор папки.
    /// - Returns: Ячейка или `nil`, если папка не на экране.
    private func folderCell(in grid: TesseraTileGridView, id: AnyHashable) -> TesseraTileCell? {
        grid.cellView(forItemID: id) as? TesseraTileCell
    }

    // MARK: - Открытие

    /// Открытие вставляет панель в набор коллекции, но не в данные снимка.
    func testOpenFolderExpandsPanelOnlyInDisplayItems() {
        let folder = makeFolder("f")
        let grid = makeGrid([.tile(tesseraTestTile("a")), .folder(folder)])
        var events: [(AnyHashable, Bool)] = []
        grid.onFolderExpansionChanged = { events.append(($0.id, $1)) }

        grid.openFolder(folder, animated: false)

        XCTAssertEqual(grid.expandedFolderID, folder.id)
        XCTAssertTrue(hasPanel(in: grid, folderID: folder.id))
        XCTAssertEqual(panelIndices(in: grid).count, 1)
        // Панель — UI-состояние: в данных её нет.
        XCTAssertFalse(grid.items.contains { $0.isFolderPanel })
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, folder.id)
        XCTAssertEqual(events.first?.1, true)
    }

    /// Панель вставляется отдельным элементом сразу после плитки папки: плитка
    /// остаётся в наборе, число элементов растёт на один.
    func testOpenFolderInsertsPanelAfterFolderTile() {
        let folder = makeFolder("f")
        let tileA = tesseraTestTile("a")
        let tileB = tesseraTestTile("b")
        let items: [TesseraTileGridItem] = [.tile(tileA), .folder(folder), .tile(tileB)]
        let grid = makeGrid(items)
        let index = folderIndex(in: grid, folderID: folder.id)

        grid.openFolder(folder, animated: false)

        XCTAssertEqual(index, 1)
        XCTAssertEqual(grid.displayItems.count, items.count + 1)
        guard let index else { return }
        // Плитка папки на месте, панель — следующей строкой набора.
        XCTAssertEqual(grid.displayItems[index].folder?.id, folder.id)
        XCTAssertFalse(grid.displayItems[index].isFolderPanel)
        XCTAssertEqual(panelIndices(in: grid), [index + 1])
        XCTAssertEqual(grid.displayItems[index + 1].panelFolder?.id, folder.id)
    }

    /// Повторное открытие уже открытой папки ничего не меняет и не дублирует
    /// событие.
    func testOpenFolderIsIdempotent() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        var events: [(AnyHashable, Bool)] = []
        grid.onFolderExpansionChanged = { events.append(($0.id, $1)) }

        grid.openFolder(folder, animated: false)
        grid.openFolder(folder, animated: false)

        XCTAssertEqual(grid.expandedFolderID, folder.id)
        XCTAssertEqual(panelIndices(in: grid).count, 1)
        XCTAssertEqual(events.count, 1)
    }

    /// Папки нет в текущем снимке — вызов игнорируется.
    func testOpenFolderIgnoresFolderMissingFromSnapshot() {
        let other = makeFolder("other")
        let missing = makeFolder("missing")
        let grid = makeGrid([.folder(other)])
        var events = 0
        grid.onFolderExpansionChanged = { _, _ in events += 1 }

        grid.openFolder(missing, animated: false)

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(hasPanel(in: grid, folderID: missing.id))
        XCTAssertEqual(events, 0)
    }

    // MARK: - Геометрия панели под папкой

    /// Плитка папки остаётся на месте и видна, а панель начинается строкой ниже
    /// и сдвигает вниз всё, что начиналось ниже папки.
    func testPanelIsInsertedBelowFolderAndPushesContentBelow() throws {
        let folder = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })
        let wide = tesseraTestTile("wide", size: .wide)
        let items: [TesseraTileGridItem] = [.folder(folder), .tile(wide)]
        let grid = makeGrid(items)

        let folderFrame = try XCTUnwrap(grid.frame(forItemID: folder.id))
        let wideBefore = try XCTUnwrap(grid.frame(forItemID: wide.id))
        let panelIndex = 1 // панель вставляется сразу после папки

        grid.openFolder(folder, animated: false)
        layout(grid)

        // Плитка папки никуда не исчезла и не переехала.
        XCTAssertEqual(try XCTUnwrap(grid.frame(forItemID: folder.id)), folderFrame)
        XCTAssertEqual(panelIndices(in: grid), [panelIndex])

        let panelFrame = try XCTUnwrap(frame(in: grid, at: panelIndex))
        let panelHeight = TesseraTileLayoutEngine.panelHeight(
            for: folder,
            width: contentWidth,
            columns: 4
        )

        // Панель — полноширинная строка сразу после последней строки папки.
        XCTAssertEqual(panelFrame.minX, gridInsets, accuracy: 0.5)
        XCTAssertEqual(panelFrame.width, contentWidth, accuracy: 0.5)
        XCTAssertEqual(
            panelFrame.minY,
            folderFrame.maxY + gridSpacing,
            accuracy: 0.5
        )
        XCTAssertEqual(panelFrame.height, panelHeight, accuracy: 0.5)

        // Всё, что начиналось ниже папки, встаёт под панелью.
        let wideAfter = try XCTUnwrap(grid.frame(forItemID: wide.id))
        XCTAssertEqual(
            wideAfter.minY,
            panelFrame.maxY + gridSpacing,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(wideAfter.minY, wideBefore.minY)
    }

    /// Сосед в строке папки остаётся на месте: панель начинается после строки,
    /// в которой заканчивается папка, а не с её верхнего края.
    func testNeighbourInFolderRowStaysInPlace() throws {
        let folder = makeFolder("f")
        let small = tesseraTestTile("small", size: .small)
        let items: [TesseraTileGridItem] = [.folder(folder), .tile(small)]
        let grid = makeGrid(items)

        let smallBefore = try XCTUnwrap(grid.frame(forItemID: small.id))

        grid.openFolder(folder, animated: false)
        layout(grid)

        let smallAfter = try XCTUnwrap(grid.frame(forItemID: small.id))
        XCTAssertEqual(smallAfter.minX, smallBefore.minX, accuracy: 0.5)
        XCTAssertEqual(smallAfter.minY, smallBefore.minY, accuracy: 0.5)
    }

    /// Элемент, заканчивающийся выше строки папки, остаётся на месте: панель
    /// встаёт после строки папки и ниже ничего не задевает.
    func testPanelKeepsItemsAboveFolderInPlace() throws {
        let folder = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })
        let wide = tesseraTestTile("wide", size: .wide)
        let items: [TesseraTileGridItem] = [.tile(wide), .folder(folder)]
        let grid = makeGrid(items)

        let wideFrame = try XCTUnwrap(grid.frame(forItemID: wide.id))
        let folderFrame = try XCTUnwrap(grid.frame(forItemID: folder.id))

        grid.openFolder(folder, animated: false)
        layout(grid)

        let wideAfter = try XCTUnwrap(grid.frame(forItemID: wide.id))
        XCTAssertEqual(wideAfter.minY, wideFrame.minY, accuracy: 0.5)
        XCTAssertEqual(wideAfter.minX, wideFrame.minX, accuracy: 0.5)
        // Панель не поднимается выше папки и не двигает её.
        let panelFrame = try XCTUnwrap(frame(in: grid, at: 2))
        XCTAssertGreaterThan(panelFrame.minY, folderFrame.minY)
    }

    // MARK: - Переключение и закрытие

    /// Toggle закрывает открытую папку и убирает панель из набора.
    func testToggleClosesOpenFolder() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        var events: [(AnyHashable, Bool)] = []
        grid.onFolderExpansionChanged = { events.append(($0.id, $1)) }

        grid.openFolder(folder, animated: false)
        grid.toggleFolder(folder)

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(hasPanel(in: grid, folderID: folder.id))
        XCTAssertEqual(events.map { $0.1 }, [true, false])
    }

    /// Toggle открывает закрытую папку (та же ветка, что у тапа по папке).
    func testToggleOpensClosedFolder() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])

        grid.toggleFolder(folder)

        XCTAssertEqual(grid.expandedFolderID, folder.id)
        XCTAssertTrue(hasPanel(in: grid, folderID: folder.id))
    }

    /// Явное закрытие возвращает набор к данным снимка: панель удаляется,
    /// плитка папки остаётся на прежнем индексе.
    func testCloseFolderRestoresDataItems() {
        let folder = makeFolder("f")
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folder(folder),
            .tile(tesseraTestTile("b")),
        ]
        let grid = makeGrid(items)
        let index = folderIndex(in: grid, folderID: folder.id)
        var closed = 0
        grid.onFolderExpansionChanged = { _, expanded in
            if !expanded { closed += 1 }
        }

        grid.openFolder(folder, animated: false)
        XCTAssertTrue(hasPanel(in: grid, folderID: folder.id))

        grid.closeFolder(animated: false)

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(hasPanel(in: grid, folderID: folder.id))
        XCTAssertEqual(grid.displayItems.map { $0.id }, items.map { $0.id })
        XCTAssertEqual(closed, 1)
        if let index {
            XCTAssertEqual(grid.displayItems[index].folder?.id, folder.id)
            XCTAssertFalse(grid.displayItems[index].isFolderPanel)
        }
    }

    /// Закрытие при отсутствии раскрытой папки — no-op без события.
    func testCloseFolderWithoutExpandedFolderIsNoOp() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        var events = 0
        grid.onFolderExpansionChanged = { _, _ in events += 1 }

        grid.closeFolder(animated: false)

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertEqual(events, 0)
    }

    /// Одновременно раскрыта максимум одна папка: открытие второй закрывает
    /// первую и сообщает об этом хосту.
    func testOpeningAnotherFolderClosesPrevious() {
        let first = makeFolder("first")
        let second = makeFolder("second")
        let grid = makeGrid([.folder(first), .folder(second)])
        var events: [(AnyHashable, Bool)] = []
        grid.onFolderExpansionChanged = { events.append(($0.id, $1)) }

        grid.openFolder(first, animated: false)
        grid.openFolder(second, animated: false)

        XCTAssertEqual(grid.expandedFolderID, second.id)
        XCTAssertFalse(hasPanel(in: grid, folderID: first.id))
        XCTAssertTrue(hasPanel(in: grid, folderID: second.id))
        XCTAssertEqual(panelIndices(in: grid).count, 1)
        // Обе папки остаются плитками в наборе.
        XCTAssertEqual(grid.displayItems.first?.folder?.id, first.id)
        XCTAssertEqual(events.map { $0.0 }, [first.id, first.id, second.id])
        XCTAssertEqual(events.map { $0.1 }, [true, false, true])
    }

    /// Папка исчезла из нового снимка — раскрытие снимается, хост получает
    /// событие закрытия (D17: панель без папки остаться не может).
    func testReloadWithoutExpandedFolderClosesPanel() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder), .tile(tesseraTestTile("a"))])
        var events: [(AnyHashable, Bool)] = []
        grid.onFolderExpansionChanged = { events.append(($0.id, $1)) }
        grid.openFolder(folder, animated: false)

        grid.reload(snapshot: TesseraTileGridSnapshot(items: [.tile(tesseraTestTile("a"))], unpinned: []))

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(hasPanel(in: grid, folderID: folder.id))
        XCTAssertEqual(events.map { $0.1 }, [true, false])
    }

    // MARK: - Мини-ярлыки превью (D17)

    /// Закрытая папка показывает мини-ярлыки превью; раскрытая — прячет их,
    /// оставляя подложку и заголовок; закрытие возвращает мини-ярлыки.
    func testExpandedFolderHidesAndRestoresPreviewShortcuts() throws {
        let folder = makeFolder("f", tiles: (0..<4).map { tesseraTestTile("t\($0)") })
        let grid = makeGrid([.folder(folder)])

        let cell = try XCTUnwrap(folderCell(in: grid, id: folder.id))
        let preview = try XCTUnwrap(cell.folderPreviewView)
        XCTAssertFalse(preview.isHidden)
        XCTAssertEqual(preview.miniTileViews.count, 4)

        grid.openFolder(folder, animated: false)
        layout(grid)

        let expandedCell = try XCTUnwrap(folderCell(in: grid, id: folder.id))
        let expandedPreview = try XCTUnwrap(expandedCell.folderPreviewView)
        // Скрыт именно блок мини-ярлыков: сами они на месте и вернутся при
        // закрытии без пересоздания.
        XCTAssertTrue(expandedPreview.isHidden)
        XCTAssertEqual(expandedPreview.miniTileViews.count, 4)

        grid.closeFolder(animated: false)
        layout(grid)

        let collapsedCell = try XCTUnwrap(folderCell(in: grid, id: folder.id))
        XCTAssertFalse(try XCTUnwrap(collapsedCell.folderPreviewView).isHidden)
    }

    /// Состояние скрытого превью переживает переиспользование ячейки: чужая
    /// папка не наследует ни скрытое, ни показанное превью.
    func testPreviewVisibilitySurvivesCellReuse() {
        let folder = makeFolder("f")
        let cell = TesseraTileCell(frame: CGRect(x: 0, y: 0, width: 160, height: 160))

        cell.configure(
            with: .folder(folder),
            liveTileEngine: nil,
            isVisible: false,
            isFolderExpanded: true
        )
        XCTAssertTrue(cell.folderPreviewView?.isHidden ?? false)

        cell.prepareForReuse()
        cell.configure(
            with: .tile(tesseraTestTile("a")),
            liveTileEngine: nil,
            isVisible: false
        )
        XCTAssertTrue(cell.folderPreviewView?.isHidden ?? true)

        cell.configure(
            with: .folder(folder),
            liveTileEngine: nil,
            isVisible: false,
            isFolderExpanded: false
        )
        XCTAssertFalse(cell.folderPreviewView?.isHidden ?? true)
    }
}

#endif
