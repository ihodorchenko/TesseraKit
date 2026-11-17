//
//  FolderToggleTests.swift
//  TesseraStartScreenTests
//
//  Tests for the folder expansion state machine (D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, section "Tile grid";
//  D17 in docs/STATE.md: at most one folder is expanded at a time, the panel
//  is inserted as a separate item below the folder tile (the tile stays visible),
//  and it is closed by a repeated tap or an explicit call from the host.
//
//  There is no pure open/close function in the API: the state is owned by `TesseraTileGridView`
//  (`expandedFolderID`), and the `openFolder`/`toggleFolder`/`closeFolder` methods
//  work without a window too. Outside a window `canAnimateFolderChange` is false, so
//  the grid goes through the non-animated branch synchronously: no UI loop or timers needed.
//  The collection's set is read through the internal `displayItems` (the panel is a UI layer,
//  not data), the data through the public `items`.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class FolderToggleTests: XCTestCase {

    // MARK: - Helpers

    /// Grid width in the tests (like an iPhone 13/14).
    private let gridWidth: CGFloat = 390

    /// Default outer insets of the grid (16 pt each).
    private let gridInsets: CGFloat = 16

    /// Default gap between units.
    private let gridSpacing: CGFloat = 8

    /// Width of the grid content (without outer insets).
    private var contentWidth: CGFloat {
        gridWidth - gridInsets * 2
    }

    /// Grid unit at `contentWidth` width, four columns and a gap of 8.
    private var unit: CGFloat {
        (contentWidth - gridSpacing * 3) / 4
    }

    /// A folder with one tile (or with the given tiles).
    ///
    /// - Parameters:
    ///   - id: Folder identifier.
    ///   - tiles: Tiles inside the folder.
    /// - Returns: The folder model.
    private func makeFolder(
        _ id: String,
        tiles: [TesseraTileDescriptor] = [tesseraTestTile("f-tile")]
    ) -> TesseraTileFolder {
        TesseraTileFolder(id: id, title: id, tiles: tiles)
    }

    /// A grid laid out manually: no window needed, the collection gets bounds.
    ///
    /// - Parameters:
    ///   - items: Snapshot items in display order.
    ///   - columns: Number of grid columns.
    /// - Returns: The ready grid without a window.
    private func makeGrid(_ items: [TesseraTileGridItem], columns: Int = 4) -> TesseraTileGridView {
        let grid = TesseraTileGridView(
            frame: CGRect(x: 0, y: 0, width: gridWidth, height: 844)
        )
        grid.columns = columns
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layout(grid)
        return grid
    }

    /// Runs layout of the grid and its collection: cells and frames are up to date.
    ///
    /// - Parameter grid: Grid.
    private func layout(_ grid: TesseraTileGridView) {
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
    }

    /// The collection inside the grid.
    ///
    /// - Parameter grid: Grid.
    /// - Returns: The collection, or `nil` if the hierarchy is broken.
    private func collectionView(in grid: TesseraTileGridView) -> UICollectionView? {
        grid.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// The actual frame of a collection item in content coordinates.
    ///
    /// Taken from the layout attributes: an off-screen cell may not have been
    /// created yet, while the panel frame is also needed for geometry checks.
    ///
    /// - Parameters:
    ///   - grid: Grid.
    ///   - index: Index of the item in the collection's set.
    /// - Returns: The frame, or `nil`.
    private func frame(in grid: TesseraTileGridView, at index: Int) -> CGRect? {
        guard let collectionView = collectionView(in: grid) else { return nil }
        return collectionView.collectionViewLayout
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?
            .frame
    }

    /// Indices of the expanded folder panels in the collection's set.
    ///
    /// - Parameter grid: Grid.
    /// - Returns: Indices of the `folderContent` items.
    private func panelIndices(in grid: TesseraTileGridView) -> [Int] {
        grid.displayItems.indices.filter { grid.displayItems[$0].isFolderPanel }
    }

    /// Whether the set contains the panel of the given folder.
    ///
    /// - Parameters:
    ///   - grid: Grid.
    ///   - id: Folder identifier.
    /// - Returns: `true` if the panel is inserted.
    private func hasPanel(in grid: TesseraTileGridView, folderID: AnyHashable) -> Bool {
        grid.displayItems.contains { $0.isFolderPanel && $0.id == folderID }
    }

    /// Index of the folder tile in the set (the panel is skipped).
    ///
    /// - Parameters:
    ///   - grid: Grid.
    ///   - id: Folder identifier.
    /// - Returns: Index in `displayItems`, or `nil`.
    private func folderIndex(in grid: TesseraTileGridView, folderID: AnyHashable) -> Int? {
        grid.displayItems.firstIndex { !$0.isFolderPanel && $0.folder?.id == folderID }
    }

    /// The folder cell in the grid.
    ///
    /// - Parameters:
    ///   - grid: Grid.
    ///   - id: Folder identifier.
    /// - Returns: The cell, or `nil` if the folder is not on screen.
    private func folderCell(in grid: TesseraTileGridView, id: AnyHashable) -> TesseraTileCell? {
        grid.cellView(forItemID: id) as? TesseraTileCell
    }

    // MARK: - Opening

    /// Opening inserts the panel into the collection's set, but not into the snapshot data.
    func testOpenFolderExpandsPanelOnlyInDisplayItems() {
        let folder = makeFolder("f")
        let grid = makeGrid([.tile(tesseraTestTile("a")), .folder(folder)])
        var events: [(AnyHashable, Bool)] = []
        grid.onFolderExpansionChanged = { events.append(($0.id, $1)) }

        grid.openFolder(folder, animated: false)

        XCTAssertEqual(grid.expandedFolderID, folder.id)
        XCTAssertTrue(hasPanel(in: grid, folderID: folder.id))
        XCTAssertEqual(panelIndices(in: grid).count, 1)
        // The panel is UI state: it is not in the data.
        XCTAssertFalse(grid.items.contains { $0.isFolderPanel })
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, folder.id)
        XCTAssertEqual(events.first?.1, true)
    }

    /// The panel is inserted as a separate item right after the folder tile: the tile
    /// stays in the set, and the item count grows by one.
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
        // The folder tile is in place, the panel is the next row of the set.
        XCTAssertEqual(grid.displayItems[index].folder?.id, folder.id)
        XCTAssertFalse(grid.displayItems[index].isFolderPanel)
        XCTAssertEqual(panelIndices(in: grid), [index + 1])
        XCTAssertEqual(grid.displayItems[index + 1].panelFolder?.id, folder.id)
    }

    /// Opening an already open folder again changes nothing and does not duplicate
    /// the event.
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

    /// The folder is not in the current snapshot: the call is ignored.
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

    // MARK: - Panel geometry below the folder

    /// The folder tile stays in place and visible, and the panel starts one row below
    /// and pushes down everything that started below the folder.
    func testPanelIsInsertedBelowFolderAndPushesContentBelow() throws {
        let folder = makeFolder("f", tiles: (0..<9).map { tesseraTestTile("t\($0)") })
        let wide = tesseraTestTile("wide", size: .wide)
        let items: [TesseraTileGridItem] = [.folder(folder), .tile(wide)]
        let grid = makeGrid(items)

        let folderFrame = try XCTUnwrap(grid.frame(forItemID: folder.id))
        let wideBefore = try XCTUnwrap(grid.frame(forItemID: wide.id))
        let panelIndex = 1 // the panel is inserted right after the folder

        grid.openFolder(folder, animated: false)
        layout(grid)

        // The folder tile has not disappeared or moved.
        XCTAssertEqual(try XCTUnwrap(grid.frame(forItemID: folder.id)), folderFrame)
        XCTAssertEqual(panelIndices(in: grid), [panelIndex])

        let panelFrame = try XCTUnwrap(frame(in: grid, at: panelIndex))
        let panelHeight = TesseraTileLayoutEngine.panelHeight(
            for: folder,
            width: contentWidth,
            columns: 4
        )

        // The panel is a full-width row right after the last row of the folder.
        XCTAssertEqual(panelFrame.minX, gridInsets, accuracy: 0.5)
        XCTAssertEqual(panelFrame.width, contentWidth, accuracy: 0.5)
        XCTAssertEqual(
            panelFrame.minY,
            folderFrame.maxY + gridSpacing,
            accuracy: 0.5
        )
        XCTAssertEqual(panelFrame.height, panelHeight, accuracy: 0.5)

        // Everything that started below the folder goes under the panel.
        let wideAfter = try XCTUnwrap(grid.frame(forItemID: wide.id))
        XCTAssertEqual(
            wideAfter.minY,
            panelFrame.maxY + gridSpacing,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(wideAfter.minY, wideBefore.minY)
    }

    /// A neighbor in the folder row stays in place: the panel starts after the row
    /// where the folder ends, not at its top edge.
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

    /// An item that ends above the folder row stays in place: the panel
    /// starts after the folder row and does not touch anything below.
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
        // The panel does not rise above the folder and does not move it.
        let panelFrame = try XCTUnwrap(frame(in: grid, at: 2))
        XCTAssertGreaterThan(panelFrame.minY, folderFrame.minY)
    }

    // MARK: - Toggle and close

    /// Toggle closes an open folder and removes the panel from the set.
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

    /// Toggle opens a closed folder (the same branch as a tap on the folder).
    func testToggleOpensClosedFolder() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])

        grid.toggleFolder(folder)

        XCTAssertEqual(grid.expandedFolderID, folder.id)
        XCTAssertTrue(hasPanel(in: grid, folderID: folder.id))
    }

    /// An explicit close returns the set to the snapshot data: the panel is removed,
    /// and the folder tile stays at its previous index.
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

    /// Closing when no folder is expanded is a no-op without an event.
    func testCloseFolderWithoutExpandedFolderIsNoOp() {
        let folder = makeFolder("f")
        let grid = makeGrid([.folder(folder)])
        var events = 0
        grid.onFolderExpansionChanged = { _, _ in events += 1 }

        grid.closeFolder(animated: false)

        XCTAssertNil(grid.expandedFolderID)
        XCTAssertEqual(events, 0)
    }

    /// At most one folder is expanded at a time: opening a second one closes
    /// the first and reports it to the host.
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
        // Both folders remain tiles in the set.
        XCTAssertEqual(grid.displayItems.first?.folder?.id, first.id)
        XCTAssertEqual(events.map { $0.0 }, [first.id, first.id, second.id])
        XCTAssertEqual(events.map { $0.1 }, [true, false, true])
    }

    /// The folder disappeared from the new snapshot: the expansion is cleared, and the host gets
    /// a close event (D17: a panel cannot remain without its folder).
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

    // MARK: - Preview mini-tiles (D17)

    /// A closed folder shows the preview mini-tiles; an expanded one hides them,
    /// keeping the backing and the title; closing brings the mini-tiles back.
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
        // Exactly the mini-tile block is hidden: the tiles themselves are in place and come back
        // on close without being recreated.
        XCTAssertTrue(expandedPreview.isHidden)
        XCTAssertEqual(expandedPreview.miniTileViews.count, 4)

        grid.closeFolder(animated: false)
        layout(grid)

        let collapsedCell = try XCTUnwrap(folderCell(in: grid, id: folder.id))
        XCTAssertFalse(try XCTUnwrap(collapsedCell.folderPreviewView).isHidden)
    }

    /// The hidden preview state survives cell reuse: another
    /// folder inherits neither the hidden nor the shown preview.
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
