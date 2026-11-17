//
//  FolderTapInterceptionTests.swift
//  TesseraStartScreenTests
//
//  Tests for the folder tap interceptor (D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid";
//  D17 in docs/STATE.md: a `folderTapHandler` that returns `true` cancels
//  the native expansion: the panel does not open and `onTap` is not called.
//
//  A tap arrives the same way as from UICollectionView: through the public
//  delegate method `collectionView(_:didSelectItemAt:)`. The collection is taken from the
//  grid's subviews (as in `TileEditTests`); no window is needed: outside a window the expansion
//  runs synchronously, without animation.
//
//  The panel is inserted under the folder tile (D17): while the panel is open, the folder tile
//  stays in the set, but the panel absorbs its own background/title gesture
//  (see `TesseraFolderPanelCell`), and selection of the panel by the collection is disabled
//  (`shouldSelectItemAt`).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderTapInterceptionTests: XCTestCase {

    // MARK: - Helpers

    /// A folder with one tile.
    ///
    /// - Parameter id: The folder identifier.
    /// - Returns: The folder model.
    private func makeFolder(_ id: String) -> TesseraTileFolder {
        TesseraTileFolder(id: id, title: id, tiles: [tesseraTestTile("\(id)-tile")])
    }

    /// A grid with the snapshot items, laid out without a window.
    ///
    /// - Parameter items: The items in display order.
    /// - Returns: A ready grid.
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

    /// The collection inside the grid is the source of the `IndexPath` for the delegate method.
    ///
    /// - Parameter grid: The grid.
    /// - Returns: The collection.
    /// - Throws: An error if there is no collection (a broken view hierarchy).
    private func collectionView(in grid: TesseraTileGridView) throws -> UICollectionView {
        try XCTUnwrap(grid.subviews.compactMap { $0 as? UICollectionView }.first)
    }

    /// The index of the folder tile in the collection's set.
    ///
    /// The panel is skipped: it shares the identifier with the folder, but it is a different
    /// item of the set (D17).
    ///
    /// - Parameters:
    ///   - grid: The grid.
    ///   - id: The folder identifier.
    /// - Returns: The index of the folder tile.
    /// - Throws: An error if the folder is not in the set.
    private func folderIndex(in grid: TesseraTileGridView, id: AnyHashable) throws -> Int {
        try XCTUnwrap(
            grid.displayItems.firstIndex { !$0.isFolderPanel && $0.folder?.id == id }
        )
    }

    /// The index of the expanded folder's panel in the collection's set.
    ///
    /// - Parameters:
    ///   - grid: The grid.
    ///   - id: The folder identifier.
    /// - Returns: The panel index.
    /// - Throws: An error if the panel is not open.
    private func panelIndex(in grid: TesseraTileGridView, id: AnyHashable) throws -> Int {
        try XCTUnwrap(
            grid.displayItems.firstIndex { $0.isFolderPanel && $0.id == id }
        )
    }

    /// Emulates the collection selecting an item.
    ///
    /// - Parameters:
    ///   - grid: The grid.
    ///   - index: The item index in the collection's set.
    /// - Throws: An error if there is no collection.
    private func tap(grid: TesseraTileGridView, at index: Int) throws {
        let collectionView = try collectionView(in: grid)
        grid.collectionView(
            collectionView,
            didSelectItemAt: IndexPath(item: index, section: 0)
        )
    }

    // MARK: - Interception

    /// `true` cancels both the expansion and `onTap`: the decision stays with the host.
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

    /// `false` means the interceptor only looked, and the native expansion runs.
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

    /// `nil` means there is no interceptor and the default behavior applies: tap + expansion.
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

    /// Selecting the panel does not call the interceptor and does not change state: the panel is
    /// a presentation, not a model item. Closing is the panel's own gesture on its
    /// background/title, not an interception of the folder tap (D17).
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

    /// Selection of the panel is disabled, while the folder tile and tiles can be selected: otherwise a tap on
    /// the panel after it closed would arrive at an index where the panel no longer exists and
    /// would act on a different item.
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

    /// While the panel is expanded, the folder tile stays in the set and can be selected:
    /// a second tap on it closes the panel (D17). There is no interceptor, so
    /// the tap takes the normal path.
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

    /// The folder interceptor does not touch taps on tiles: they go to `onTap`.
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
