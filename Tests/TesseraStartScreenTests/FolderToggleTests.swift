//
//  FolderToggleTests.swift
//  TesseraStartScreenTests
//
//  Тесты state-машины раскрытия папки (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»;
//  D17 в docs/STATE.md — одновременно раскрыта максимум одна папка, папка
//  «разворачивается на месте» (панель заменяет плитку по её индексу), закрытие
//  повторным тапом/явным вызовом хоста.
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

    /// Папка с одним ярлыком.
    ///
    /// - Parameters:
    ///   - id: Идентификатор папки.
    ///   - tiles: Ярлыки внутри папки.
    /// - Returns: Модель папки.
    private func makeFolder(
        _ id: String,
        tiles: [TileDescriptor] = [tesseraTestTile("f-tile")]
    ) -> TileFolder {
        TileFolder(id: id, title: id, tiles: tiles)
    }

    /// Сетка, разложенная вручную: окно не нужно, коллекция получает bounds.
    ///
    /// - Parameters:
    ///   - items: Элементы снимка в порядке отображения.
    ///   - columns: Число колонок сетки.
    /// - Returns: Готовая сетка без окна.
    private func makeGrid(_ items: [TileGridItem], columns: Int = 4) -> TesseraTileGridView {
        let grid = TesseraTileGridView(
            frame: CGRect(x: 0, y: 0, width: gridWidth, height: 844)
        )
        grid.columns = columns
        grid.reload(snapshot: TileGridSnapshot(items: items, unpinned: []))
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
        return grid
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

    /// Индекс плитки-папки в наборе (пока папка закрыта).
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - id: Идентификатор папки.
    /// - Returns: Индекс в `displayItems` или `nil`.
    private func folderIndex(in grid: TesseraTileGridView, folderID: AnyHashable) -> Int? {
        grid.displayItems.firstIndex { !$0.isFolderPanel && $0.folder?.id == folderID }
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

    /// Раскрытие «на месте»: панель встаёт на индекс папки, а не отдельной
    /// строкой; число элементов и их порядок не меняются.
    func testOpenFolderReplacesFolderTileAtSameIndex() {
        let folder = makeFolder("f")
        let tileA = tesseraTestTile("a")
        let tileB = tesseraTestTile("b")
        let items: [TileGridItem] = [.tile(tileA), .folder(folder), .tile(tileB)]
        let grid = makeGrid(items)
        let index = folderIndex(in: grid, folderID: folder.id)

        grid.openFolder(folder, animated: false)

        XCTAssertNotNil(index)
        XCTAssertEqual(grid.displayItems.count, items.count)
        XCTAssertEqual(grid.displayItems.map { $0.id }, items.map { $0.id })
        if let index {
            XCTAssertTrue(grid.displayItems[index].isFolderPanel)
            XCTAssertEqual(grid.displayItems[index].panelFolder?.id, folder.id)
        }
        // Плитки папки на сетке больше нет — её место заняла панель.
        XCTAssertFalse(grid.displayItems.contains { $0.folder != nil })
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

    // MARK: - Геометрия «разворота на месте»

    /// Панель занимает верхний край бывшей плитки папки: соседи выше не
    /// переезжают, а элементы из строки папки и ниже уходят под панель.
    func testPanelTakesFolderPlaceAndPushesContentBelow() throws {
        let folder = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })
        let wide = tesseraTestTile("wide", size: .wide)
        let items: [TileGridItem] = [.folder(folder), .tile(wide)]
        let grid = makeGrid(items)

        let folderFrame = try XCTUnwrap(grid.frame(forItemID: folder.id))
        let wideBefore = try XCTUnwrap(grid.frame(forItemID: wide.id))

        grid.openFolder(folder, animated: false)

        // Плитки папки на сетке больше нет, её место заняла панель.
        XCTAssertNil(grid.frame(forItemID: folder.id))

        let wideAfter = try XCTUnwrap(grid.frame(forItemID: wide.id))
        let panelHeight = TileLayoutEngine.panelHeight(
            for: folder,
            width: gridWidth - gridInsets * 2,
            columns: 4
        )

        // Панель начинается там, где начиналась папка, и тянется вниз; всё, что
        // делило с ней строку или шло ниже, встаёт под панелью.
        XCTAssertEqual(
            wideAfter.minY,
            folderFrame.minY + panelHeight + gridSpacing,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(wideAfter.minY, wideBefore.minY)
    }

    /// Элемент, заканчивающийся выше строки папки, остаётся на месте: панель
    /// занимает только место папки и то, что ниже.
    func testPanelKeepsItemsAboveFolderInPlace() throws {
        let folder = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })
        let wide = tesseraTestTile("wide", size: .wide)
        let items: [TileGridItem] = [.tile(wide), .folder(folder)]
        let grid = makeGrid(items)

        let wideFrame = try XCTUnwrap(grid.frame(forItemID: wide.id))
        let folderFrame = try XCTUnwrap(grid.frame(forItemID: folder.id))

        grid.openFolder(folder, animated: false)

        let wideAfter = try XCTUnwrap(grid.frame(forItemID: wide.id))
        XCTAssertEqual(wideAfter.minY, wideFrame.minY, accuracy: 0.5)
        XCTAssertEqual(wideAfter.minX, wideFrame.minX, accuracy: 0.5)
        // Панель не поднимается выше места папки.
        XCTAssertGreaterThan(folderFrame.minY, wideFrame.minY)
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

    /// Явное закрытие возвращает набор к данным снимка в исходном порядке:
    /// панель уходит, плитка папки встаёт на её индекс.
    func testCloseFolderRestoresDataItems() {
        let folder = makeFolder("f")
        let items: [TileGridItem] = [
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
        // Плитка папки вернулась на прежний индекс.
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
        // Первая папка вернулась на свой индекс обычной плиткой.
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

        grid.reload(snapshot: TileGridSnapshot(items: [.tile(tesseraTestTile("a"))], unpinned: []))

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(hasPanel(in: grid, folderID: folder.id))
        XCTAssertEqual(events.map { $0.1 }, [true, false])
    }
}

#endif
