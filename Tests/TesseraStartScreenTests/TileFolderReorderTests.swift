//
//  TileFolderReorderTests.swift
//  TesseraStartScreenTests
//
//  Reordering tiles inside a folder: model, coordinator, VoiceOver
//  (D40; Windows 10 Mobile spec §6.5). Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  "Implementation deviations"; decision D40 in docs/STATE.md.
//
//  What is checked:
//  - `TesseraTileStore.moveWithinFolder(_:folderID:toIndex:)`: forward/backward, index
//    clamping, no-op (no `onChange` and no write), foreign identifiers, write round trip,
//    a single notification, cells and sizes do not change, host approval is not
//    requested, invisible members (before the catalog is registered);
//  - `TesseraTileEditCoordinator.moveWithinFolder(_:to:)`: the grid and the panel
//    show the new order, the `didReorderTile` delegate fires exactly once, VoiceOver
//    focus lands on the tile in its new panel cell;
//  - the "Move earlier/later" custom actions on panel tiles: presence on the
//    first/middle/last tile, the action itself, en/ru strings.
//
//  Layouts are exact (`TileStoreCellFixture`): 6 columns for the model, 4 for the grid.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileFolderReorderTests: XCTestCase {

    private let columns = 6
    private let folderID: AnyHashable = "F"

    // MARK: - Model helpers

    /// Folder F (medium, (0,0)) made from `contents`, and tile `a` to its right.
    private func makeStore(
        contents: [(String, TesseraTileSize)] = [("x", .small), ("y", .small), ("z", .small), ("w", .small)],
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) throws -> TesseraTileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [CellFixtureTile("a", .small, 0, 4)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)],
            in: directory,
            autosaves: autosaves
        )
    }

    private func order(_ store: TesseraTileStore, folder: AnyHashable = "F") -> [AnyHashable] {
        store.snapshot().folders.first { $0.id == folder }?.tiles.map { $0.id } ?? []
    }

    /// Counts `onChange` notifications and remembers the folder order in each.
    private final class ChangeRecorder {
        var orders: [[AnyHashable]] = []
    }

    private func record(_ store: TesseraTileStore) -> ChangeRecorder {
        let recorder = ChangeRecorder()
        store.onChange = { snapshot in
            recorder.orders.append(snapshot.folders.first?.tiles.map { $0.id } ?? [])
        }
        return recorder
    }

    // MARK: - Model: reordering

    /// A tile moves forward: the folder order in the snapshot, `folderContaining` and the preview.
    func testMoveForwardReordersFolder() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)

        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 2))

        XCTAssertEqual(order(store), ["y", "z", "x", "w"] as [AnyHashable])
        XCTAssertEqual(store.folderContaining("x")?.tiles.map { $0.id }, ["y", "z", "x", "w"] as [AnyHashable])
    }

    /// A tile moves backward.
    func testMoveBackwardReordersFolder() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)

        XCTAssertTrue(store.moveWithinFolder("w", folderID: "F", toIndex: 1))

        XCTAssertEqual(order(store), ["x", "w", "y", "z"] as [AnyHashable])
    }

    /// An out-of-bounds index is clamped to the bound.
    func testIndexIsClamped() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)

        XCTAssertTrue(store.moveWithinFolder("y", folderID: "F", toIndex: -7))
        XCTAssertEqual(order(store), ["y", "x", "z", "w"] as [AnyHashable])

        XCTAssertTrue(store.moveWithinFolder("y", folderID: "F", toIndex: 99))
        XCTAssertEqual(order(store), ["x", "z", "w", "y"] as [AnyHashable])

        // Clamping to the current position is a no-op.
        XCTAssertFalse(store.moveWithinFolder("y", folderID: "F", toIndex: 42))
        XCTAssertEqual(order(store), ["x", "z", "w", "y"] as [AnyHashable])
    }

    /// A folder with two tiles: reordering is a swap.
    func testTwoTileFolderSwaps() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(contents: [("x", .small), ("y", .small)], in: directory)

        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
        XCTAssertEqual(order(store), ["y", "x"] as [AnyHashable])
        XCTAssertFalse(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
    }

    // MARK: - Model: no-op and foreign identifiers

    /// The same position gives `false`, with no `onChange` and no file write.
    func testSamePositionIsNoOpWithoutNotificationOrSave() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)
        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
        try FileManager.default.removeItem(at: store.fileURL)
        let recorder = record(store)

        XCTAssertFalse(store.moveWithinFolder("x", folderID: "F", toIndex: 1))
        XCTAssertFalse(store.moveWithinFolder("y", folderID: "F", toIndex: 0))

        XCTAssertTrue(recorder.orders.isEmpty, "No onChange at all")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "Nothing was written")
        XCTAssertEqual(order(store), ["y", "x", "z", "w"] as [AnyHashable])
    }

    /// An unknown folder, an unknown tile, a tile not from this folder, a grid tile
    /// instead of a folder — `false`, and the model does not change.
    func testUnknownIdentifiersAreNoOps() throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: [CellFixtureTile("a", .small, 0, 4)],
            folders: [
                CellFixtureFolder("F", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
                CellFixtureFolder("G", .medium, 2, 0, contents: [("p", .small), ("q", .small)]),
            ],
            in: directory
        )
        let recorder = record(store)

        XCTAssertFalse(store.moveWithinFolder("x", folderID: "nope", toIndex: 1), "No such folder")
        XCTAssertFalse(store.moveWithinFolder("nope", folderID: "F", toIndex: 1), "No such tile")
        XCTAssertFalse(store.moveWithinFolder("p", folderID: "F", toIndex: 1), "A tile from another folder")
        XCTAssertFalse(store.moveWithinFolder("a", folderID: "F", toIndex: 1), "A tile from the desktop")
        XCTAssertFalse(store.moveWithinFolder("x", folderID: "a", toIndex: 1), "A tile instead of a folder")

        XCTAssertTrue(recorder.orders.isEmpty)
        XCTAssertEqual(order(store, folder: "F"), ["x", "y"] as [AnyHashable])
        XCTAssertEqual(order(store, folder: "G"), ["p", "q"] as [AnyHashable])
    }

    // MARK: - Model: persistence and side effects

    /// Write round trip: the order survives a restart; the preview and the snapshot show it.
    func testOrderSurvivesRoundTrip() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory, autosaves: true)

        XCTAssertTrue(store.moveWithinFolder("w", folderID: "F", toIndex: 0))
        XCTAssertEqual(order(store), ["w", "x", "y", "z"] as [AnyHashable])

        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog(["a", "x", "y", "z", "w"].map { tesseraTestTile($0, size: .small) })
        try fresh.load()
        XCTAssertEqual(order(fresh), ["w", "x", "y", "z"] as [AnyHashable], "The order in the file")
        XCTAssertEqual(
            fresh.snapshot().folders.first?.tiles.map { $0.id },
            store.snapshot().folders.first?.tiles.map { $0.id }
        )
        XCTAssertEqual(fresh.placements, store.placements)
    }

    /// A single `onChange` notification, and the snapshot in it already has the new order.
    func testExactlyOneChangeWithNewOrder() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        let recorder = record(store)

        XCTAssertTrue(store.moveWithinFolder("z", folderID: "F", toIndex: 0))

        XCTAssertEqual(recorder.orders.count, 1)
        XCTAssertEqual(recorder.orders.first, ["z", "x", "y", "w"] as [AnyHashable])
    }

    /// Cells and sizes of top-level items and of the tiles themselves do not change.
    func testPlacementsAndSizesAreUntouched() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(
            contents: [("x", .small), ("y", .wide), ("z", .medium)],
            in: directory
        )
        let placements = store.placements
        let sizes = Dictionary(uniqueKeysWithValues: store.snapshot().items.map { ($0.id, $0.size) })
        let tileSizes = Dictionary(
            uniqueKeysWithValues: (store.snapshot().folders.first?.tiles ?? []).map { ($0.id, $0.size) }
        )

        XCTAssertTrue(store.moveWithinFolder("z", folderID: "F", toIndex: 0))

        XCTAssertEqual(store.placements, placements)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.snapshot().items.map { ($0.id, $0.size) }), sizes)
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: (store.snapshot().folders.first?.tiles ?? []).map { ($0.id, $0.size) }
            ),
            tileSizes
        )
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ["a", "x", "y", "z"])
    }

    /// Host approval (D14) is not requested: the folder's composition does not change.
    func testApprovalIsNotAsked() throws {
        let directory = TesseraTestDirectory()
        let store = try makeStore(in: directory)
        var asked = 0
        store.approval = { _, _, _ in
            asked += 1
            return false
        }

        XCTAssertTrue(store.moveWithinFolder("x", folderID: "F", toIndex: 3))

        XCTAssertEqual(asked, 0)
        XCTAssertEqual(order(store), ["y", "z", "w", "x"] as [AnyHashable])
    }

    /// Invisible members (the file is read before the catalog is registered): without a catalog
    /// reordering is refused; after registration it works on the visible tiles.
    func testInvisibleMembersBeforeCatalogRegistration() throws {
        let directory = TesseraTestDirectory()
        let source = try makeStore(in: directory, autosaves: true)
        try source.save()

        let fresh = TesseraTileStore(directoryURL: directory.url)
        try fresh.load()
        XCTAssertFalse(
            fresh.moveWithinFolder("x", folderID: "F", toIndex: 2),
            "No catalog: there are no visible tiles in the folder"
        )

        fresh.setCatalog(["a", "x", "y", "z", "w"].map { tesseraTestTile($0, size: .small) })
        XCTAssertTrue(fresh.moveWithinFolder("x", folderID: "F", toIndex: 2))
        XCTAssertEqual(order(fresh), ["y", "z", "x", "w"] as [AnyHashable])
    }

    // MARK: - Coordinator helpers

    private final class Recorder: TesseraTileEditCoordinatorDelegate {
        var reorders: [(tile: AnyHashable, folder: AnyHashable, index: Int)] = []
        var grouping: [TesseraTileGroupingAction] = []

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didReorderTile tileID: AnyHashable,
            inFolder folderID: AnyHashable,
            toIndex index: Int
        ) {
            reorders.append((tileID, folderID, index))
        }

        func tileEditCoordinator(
            _ coordinator: TesseraTileEditCoordinator,
            didFailGrouping action: TesseraTileGroupingAction,
            tileID: AnyHashable,
            folderID: AnyHashable?
        ) {
            grouping.append(action)
        }
    }

    private final class PostRecorder {
        var posts: [(UIAccessibility.Notification, Any?)] = []
    }

    private func makeHost(
        contents: [(String, TesseraTileSize)] = [("x", .small), ("y", .small), ("z", .small)]
    ) throws -> TesseraTestDragHost {
        try TesseraTestDragHost(
            cells: [CellFixtureTile("a", .small, 3, 0)],
            folders: [CellFixtureFolder("F", .medium, 0, 0, contents: contents)]
        )
    }

    @discardableResult
    private func openPanel(_ host: TesseraTestDragHost) throws -> TesseraFolderPanelCell {
        host.coordinator.beginEditing()
        let folder = try XCTUnwrap(host.folders.first { $0.id == self.folderID })
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID)
        XCTAssertTrue(host.waitUntil {
            host.host.panelCell(folderID: folderID)?.shortcutCells.first?.accessibilityCustomActions != nil
        })
        return try XCTUnwrap(host.host.panelCell(folderID: folderID))
    }

    // MARK: - Coordinator

    /// The public method: the model, the grid with a closed panel, the delegate exactly once.
    func testCoordinatorMoveUpdatesModelGridAndDelegate() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.moveWithinFolder("x", to: 2))

        XCTAssertEqual(order(host.store), ["y", "z", "x"] as [AnyHashable])
        XCTAssertEqual(
            host.host.grid.snapshot?.folders.first?.tiles.map { $0.id },
            ["y", "z", "x"] as [AnyHashable],
            "The grid shows the new order"
        )
        XCTAssertEqual(recorder.reorders.count, 1)
        XCTAssertEqual(recorder.reorders.first?.tile, "x")
        XCTAssertEqual(recorder.reorders.first?.folder, "F")
        XCTAssertEqual(recorder.reorders.first?.index, 2)
        XCTAssertTrue(recorder.grouping.isEmpty, "Host approval was not requested")
    }

    /// Index clamping: the delegate receives the actual index.
    func testCoordinatorReportsClampedIndex() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertTrue(host.coordinator.moveWithinFolder("x", to: 50))

        XCTAssertEqual(recorder.reorders.first?.index, 2)
    }

    /// A no-op and an unknown tile: `false`, the delegate stays silent, the grid does not change.
    func testCoordinatorNoOpAndUnknownTile() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder

        XCTAssertFalse(host.coordinator.moveWithinFolder("x", to: 0), "The same position")
        XCTAssertFalse(host.coordinator.moveWithinFolder("a", to: 0), "The tile is not in the folder")
        XCTAssertFalse(host.coordinator.moveWithinFolder("nope", to: 0))

        XCTAssertTrue(recorder.reorders.isEmpty)
        XCTAssertEqual(order(host.store), ["x", "y", "z"] as [AnyHashable])
    }

    /// An open panel is reconfigured in place: tiles in the slots follow the new
    /// order, and so do the preview icons of the closed folder.
    func testOpenPanelShowsNewOrder() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ["x", "y", "z"] as [AnyHashable?])

        XCTAssertTrue(host.coordinator.moveWithinFolder("z", to: 0))

        XCTAssertEqual(panel.shortcutCells.map { $0.itemID }, ["z", "x", "y"] as [AnyHashable?], "The same panel view")
        XCTAssertEqual(host.host.grid.expandedFolderID, folderID, "The panel stayed open")
        XCTAssertEqual(host.host.grid.snapshot?.folders.first?.tiles.map { $0.id }, ["z", "x", "y"] as [AnyHashable])
    }

    /// VoiceOver focus stays on the moved tile — in its new panel cell.
    func testFocusStaysOnMovedTileInNewPanelCell() throws {
        let host = try makeHost()
        let panel = try openPanel(host)
        let posts = PostRecorder()
        host.coordinator.accessibilityNotificationPoster = { notification, argument in
            posts.posts.append((notification, argument))
        }

        XCTAssertTrue(host.coordinator.moveWithinFolder("x", to: 2))

        XCTAssertTrue(host.waitUntil { !posts.posts.isEmpty })
        let post = try XCTUnwrap(posts.posts.last)
        XCTAssertEqual(post.0, .layoutChanged)
        let focused = try XCTUnwrap(post.1 as? TesseraTileCell)
        XCTAssertTrue(focused === panel.shortcutCells[2], "The new panel cell")
        XCTAssertEqual(focused.itemID, "x")
    }

    /// During a drag the public reorder is refused (the session model does not change).
    func testCoordinatorRefusesDuringDrag() throws {
        let host = try makeHost()
        host.coordinator.beginEditing()
        XCTAssertTrue(host.startDrag("a"))

        XCTAssertFalse(host.coordinator.moveWithinFolder("x", to: 2))
        XCTAssertEqual(order(host.store), ["x", "y", "z"] as [AnyHashable])

        host.coordinator.finishDrag(commit: false)
        host.coordinator.endEditing()
    }

    // MARK: - VoiceOver: custom actions

    private func actionNames(of cell: TesseraTileCell) -> [String] {
        (cell.accessibilityCustomActions ?? []).map { $0.name }
    }

    private func action(_ name: String, of cell: TesseraTileCell) -> UIAccessibilityCustomAction? {
        cell.accessibilityCustomActions?.first { $0.name == name }
    }

    private var earlier: String { TesseraStartScreenStrings.string(.a11yActionMoveEarlier) }
    private var later: String { TesseraStartScreenStrings.string(.a11yActionMoveLater) }

    /// The first tile has no "earlier", the last has no "later", the middle one has both.
    func testMoveActionsPresenceAtFirstMiddleLast() throws {
        let host = try makeHost()
        let panel = try openPanel(host)

        let first = actionNames(of: panel.shortcutCells[0])
        XCTAssertFalse(first.contains(earlier))
        XCTAssertTrue(first.contains(later))

        let middle = actionNames(of: panel.shortcutCells[1])
        XCTAssertTrue(middle.contains(earlier))
        XCTAssertTrue(middle.contains(later))

        let last = actionNames(of: panel.shortcutCells[2])
        XCTAssertTrue(last.contains(earlier))
        XCTAssertFalse(last.contains(later))
    }

    /// "Later" moves the tile one position; "earlier" moves it back; the delegate hears it.
    func testMoveActionsMoveByOnePosition() throws {
        let host = try makeHost()
        let recorder = Recorder()
        host.coordinator.delegate = recorder
        let panel = try openPanel(host)

        let moveLater = try XCTUnwrap(action(later, of: panel.shortcutCells[0]))
        XCTAssertEqual(moveLater.actionHandler?(moveLater), true)
        XCTAssertEqual(order(host.store), ["y", "x", "z"] as [AnyHashable])
        XCTAssertEqual(recorder.reorders.last?.index, 1)

        // The deferred reconciliation updates the actions for the new position.
        XCTAssertTrue(host.waitUntil {
            self.actionNames(of: panel.shortcutCells[0]).contains(self.later)
                && !self.actionNames(of: panel.shortcutCells[0]).contains(self.earlier)
                && self.actionNames(of: panel.shortcutCells[1]).contains(self.earlier)
        })
        let moveEarlier = try XCTUnwrap(action(earlier, of: panel.shortcutCells[1]))
        XCTAssertEqual(moveEarlier.actionHandler?(moveEarlier), true)
        XCTAssertEqual(order(host.store), ["x", "y", "z"] as [AnyHashable])
        XCTAssertEqual(recorder.reorders.count, 2)
    }

    /// After a tile leaves the folder the action set is recomputed: the new
    /// last tile loses "later".
    func testMoveActionsRefreshAfterFolderShrinks() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small), ("z", .small), ("w", .small)])
        let panel = try openPanel(host)
        XCTAssertTrue(actionNames(of: panel.shortcutCells[2]).contains(later))

        host.coordinator.unpin("w")
        XCTAssertTrue(host.waitUntil { host.store.folderContaining("x")?.tiles.count == 3 })
        XCTAssertTrue(host.waitUntil {
            !self.actionNames(of: panel.shortcutCells[2]).contains(self.later)
        }, "The new last tile has no \"later\"")
    }

    /// A folder with two tiles: the first has only "later", the second only "earlier".
    func testMoveActionsInTwoTileFolder() throws {
        let host = try makeHost(contents: [("x", .small), ("y", .small)])
        let panel = try openPanel(host)

        XCTAssertEqual(
            [earlier, later].filter { actionNames(of: panel.shortcutCells[0]).contains($0) },
            [later]
        )
        XCTAssertEqual(
            [earlier, later].filter { actionNames(of: panel.shortcutCells[1]).contains($0) },
            [earlier]
        )
    }

    /// Outside edit mode there are no actions.
    func testNoMoveActionsOutsideEditing() throws {
        let host = try makeHost()
        let folder = try XCTUnwrap(host.folders.first)
        host.host.grid.openFolder(folder, animated: false)
        host.host.layout()
        let panel = try XCTUnwrap(host.host.panelCell(folderID: folderID))
        host.spin(0.05)

        for cell in panel.shortcutCells {
            XCTAssertFalse(actionNames(of: cell).contains(earlier))
            XCTAssertFalse(actionNames(of: cell).contains(later))
        }
    }

    // MARK: - en/ru strings

    func testMoveStringsExistInBothLanguages() {
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveEarlier, language: "en"), "Move earlier")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveLater, language: "en"), "Move later")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveEarlier, language: "ru"), "Переместить раньше")
        XCTAssertEqual(TesseraStartScreenStrings.string(.a11yActionMoveLater, language: "ru"), "Переместить позже")
        for language in ["en", "ru"] {
            let format = TesseraStartScreenStrings.string(.a11yFolderTilePositionFormat, language: language)
            XCTAssertTrue(String(format: format, 2, 5).contains("2"), format)
            XCTAssertTrue(String(format: format, 2, 5).contains("5"), format)
        }
    }
}

#endif
