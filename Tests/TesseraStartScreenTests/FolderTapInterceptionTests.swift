//
//  FolderTapInterceptionTests.swift
//  TesseraStartScreenTests
//
//  Тесты перехватчика тапа по папке (задача E7.4, решение D17).
//  Проектный документ: docs/STARTSCREEN-IOS-DESIGN.md §3 «Плиточная сетка»;
//  D17 в docs/STATE.md — `folderTapHandler`, вернувший `true`, отменяет
//  нативное раскрытие: панель не открывается, `onTap` не вызывается.
//
//  Тап приходит тем же путём, что и от UICollectionView: через публичный
//  delegate-метод `collectionView(_:didSelectItemAt:)`. Коллекция берётся из
//  подвью сетки (как в `TileEditTests`), окно не нужно: вне окна раскрытие
//  выполняется синхронно, без анимации.
//
//  Панель вставляется под плитку папки (D17): пока панель открыта, плитка папки
//  остаётся в наборе, но панель закрывает собственный жест по фону/заголовку
//  (см. `TesseraFolderPanelCell`), а выбор панели коллекцией отключён
//  (`shouldSelectItemAt`).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderTapInterceptionTests: XCTestCase {

    // MARK: - Вспомогательные средства

    /// Папка с одним ярлыком.
    ///
    /// - Parameter id: Идентификатор папки.
    /// - Returns: Модель папки.
    private func makeFolder(_ id: String) -> TesseraTileFolder {
        TesseraTileFolder(id: id, title: id, tiles: [tesseraTestTile("\(id)-tile")])
    }

    /// Сетка с элементами снимка, разложенная без окна.
    ///
    /// - Parameter items: Элементы в порядке отображения.
    /// - Returns: Готовая сетка.
    private func makeGrid(_ items: [TesseraTileGridItem]) -> TesseraTileGridView {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        grid.columns = 4
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
        return grid
    }

    /// Коллекция внутри сетки — источник `IndexPath` для delegate-метода.
    ///
    /// - Parameter grid: Сетка.
    /// - Returns: Коллекция.
    /// - Throws: Ошибка, если коллекции нет (сломанная иерархия вью).
    private func collectionView(in grid: TesseraTileGridView) throws -> UICollectionView {
        try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    /// Индекс плитки-папки в наборе коллекции.
    ///
    /// Панель пропускается: она делит идентификатор с папкой, но это другой
    /// элемент набора (D17).
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - id: Идентификатор папки.
    /// - Returns: Индекс плитки-папки.
    /// - Throws: Ошибка, если папки нет в наборе.
    private func folderIndex(in grid: TesseraTileGridView, id: AnyHashable) throws -> Int {
        try XCTUnwrap(
            grid.displayItems.firstIndex { !$0.isFolderPanel && $0.folder?.id == id }
        )
    }

    /// Индекс панели раскрытой папки в наборе коллекции.
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - id: Идентификатор папки.
    /// - Returns: Индекс панели.
    /// - Throws: Ошибка, если панель не открыта.
    private func panelIndex(in grid: TesseraTileGridView, id: AnyHashable) throws -> Int {
        try XCTUnwrap(
            grid.displayItems.firstIndex { $0.isFolderPanel && $0.id == id }
        )
    }

    /// Эмулирует выбор элемента коллекцией.
    ///
    /// - Parameters:
    ///   - grid: Сетка.
    ///   - index: Индекс элемента в наборе коллекции.
    /// - Throws: Ошибка, если коллекции нет.
    private func tap(grid: TesseraTileGridView, at index: Int) throws {
        let collectionView = try collectionView(in: grid)
        grid.collectionView(
            collectionView,
            didSelectItemAt: IndexPath(item: index, section: 0)
        )
    }

    // MARK: - Перехват

    /// `true` отменяет и раскрытие, и `onTap`: решение остаётся за хостом.
    func testHandlerReturningTrueSuppressesExpansionAndTap() throws {
        let folder = makeFolder("f")
        let grid = makeGrid([.tile(tesseraTestTile("a")), .folder(folder)])
        var handled: [TesseraTileFolder] = []
        var tapped: [TesseraTileGridItem] = []
        grid.folderTapHandler = { candidate in
            handled.append(candidate)
            return true
        }
        grid.onTap = { tapped.append($0) }

        try tap(grid: grid, at: folderIndex(in: grid, id: folder.id))

        XCTAssertEqual(handled.count, 1)
        XCTAssertEqual(handled.first?.id, folder.id)
        XCTAssertEqual(handled.first?.title, folder.title)
        XCTAssertTrue(tapped.isEmpty)
        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(grid.displayItems.contains { $0.isFolderPanel })
    }

    /// `false` — перехватчик лишь посмотрел, нативное раскрытие выполняется.
    func testHandlerReturningFalseAllowsExpansionAndTap() throws {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        var handled = 0
        var tapped: [TesseraTileGridItem] = []
        grid.folderTapHandler = { _ in
            handled += 1
            return false
        }
        grid.onTap = { tapped.append($0) }

        try tap(grid: grid, at: folderIndex(in: grid, id: folder.id))

        XCTAssertEqual(handled, 1)
        XCTAssertEqual(tapped.count, 1)
        XCTAssertEqual(tapped.first?.folder?.id, folder.id)
        XCTAssertEqual(grid.expandedFolderID, folder.id)
    }

    /// `nil` — перехватчика нет, поведение по умолчанию: тап + раскрытие.
    func testNoHandlerAllowsExpansionAndTap() throws {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        var tapped: [TesseraTileGridItem] = []
        grid.onTap = { tapped.append($0) }

        try tap(grid: grid, at: folderIndex(in: grid, id: folder.id))

        XCTAssertEqual(tapped.count, 1)
        XCTAssertEqual(tapped.first?.folder?.id, folder.id)
        XCTAssertEqual(grid.expandedFolderID, folder.id)
    }

    /// Выбор панели не вызывает перехватчик и не меняет состояние: панель —
    /// представление, а не элемент модели. Закрытие — жест самой панели по
    /// фону/заголовку, а не перехват тапа по папке (D17).
    func testHandlerIsNotCalledForExpandedPanel() throws {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        grid.openFolder(folder, animated: false)
        XCTAssertEqual(grid.expandedFolderID, folder.id)

        var handled = 0
        var tapped: [TesseraTileGridItem] = []
        grid.folderTapHandler = { _ in
            handled += 1
            return true
        }
        grid.onTap = { tapped.append($0) }

        try tap(grid: grid, at: panelIndex(in: grid, id: folder.id))

        XCTAssertEqual(handled, 0)
        XCTAssertTrue(tapped.isEmpty)
        XCTAssertEqual(grid.expandedFolderID, folder.id)
        XCTAssertTrue(grid.displayItems.contains { $0.isFolderPanel })
    }

    /// Выбор панели отключён, а плитка папки и ярлыки выбираются: иначе тап по
    /// панели после её закрытия пришёл бы по индексу, где панели уже нет, и
    /// сработал бы по чужому элементу.
    func testPanelIsNotSelectableWhileTilesAndFoldersAre() throws {
        let folder = makeFolder("f")
        let tile = tesseraTestTile("a")
        let grid = makeGrid([.tile(tile), .folder(folder)])
        let collectionView = try collectionView(in: grid)

        let tileIndex = try XCTUnwrap(
            grid.displayItems.firstIndex { !$0.isFolderPanel && $0.tile?.id == tile.id }
        )
        let closedFolderIndex = try folderIndex(in: grid, id: folder.id)
        XCTAssertTrue(
            grid.collectionView(collectionView, shouldSelectItemAt: IndexPath(item: tileIndex, section: 0))
        )
        XCTAssertTrue(
            grid.collectionView(
                collectionView,
                shouldSelectItemAt: IndexPath(item: closedFolderIndex, section: 0)
            )
        )

        grid.openFolder(folder, animated: false)
        let index = try panelIndex(in: grid, id: folder.id)

        XCTAssertFalse(
            grid.collectionView(collectionView, shouldSelectItemAt: IndexPath(item: index, section: 0))
        )
    }

    /// Пока панель раскрыта, плитка папки остаётся в наборе и выбирается:
    /// повторный тап по ней закрывает панель (D17). Перехватчика нет, поэтому
    /// тап идёт обычным путём.
    func testFolderTileStaysSelectableWhileExpanded() throws {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        let collectionView = try collectionView(in: grid)
        var tapped: [TesseraTileGridItem] = []
        grid.onTap = { tapped.append($0) }

        grid.openFolder(folder, animated: false)
        let index = try folderIndex(in: grid, id: folder.id)
        XCTAssertTrue(
            grid.collectionView(
                collectionView,
                shouldSelectItemAt: IndexPath(item: index, section: 0)
            )
        )

        try tap(grid: grid, at: index)

        XCTAssertEqual(tapped.count, 1)
        XCTAssertEqual(tapped.first?.folder?.id, folder.id)
        XCTAssertNil(grid.expandedFolderID)
        XCTAssertFalse(grid.displayItems.contains { $0.isFolderPanel })
    }

    /// Перехватчик папок не трогает тапы по ярлыкам: они идут в `onTap`.
    func testHandlerIsNotCalledForTileTap() throws {
        let folder = makeFolder("f")
        let tile = tesseraTestTile("a")
        let grid = makeGrid([.tile(tile), .folder(folder)])
        var handled = 0
        var tapped: [TesseraTileGridItem] = []
        grid.folderTapHandler = { _ in
            handled += 1
            return true
        }
        grid.onTap = { tapped.append($0) }

        let tileIndex = try XCTUnwrap(
            grid.displayItems.firstIndex { !$0.isFolderPanel && $0.tile?.id == tile.id }
        )
        try tap(grid: grid, at: tileIndex)

        XCTAssertEqual(handled, 0)
        XCTAssertEqual(tapped.count, 1)
        XCTAssertEqual(tapped.first?.tile?.id, tile.id)
        XCTAssertNil(grid.expandedFolderID)
    }
}

#endif
