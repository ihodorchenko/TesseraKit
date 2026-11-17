//
//  TileGridItemTests.swift
//  TesseraStartScreenTests
//
//  Tests of the desktop grid item (decision D17).
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid";
//  D17 in docs/STATE.md — the panel of an opened folder, `folderContent`, lives in the same
//  enumeration as the tile and the folder, but is not a data item.
//
//  The tests check identity, size, "view" properties and a switch over all three
//  cases: adding a new case must not break host handlers. The model is a
//  pure value, so no UIKit loop is needed.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileGridItemTests: XCTestCase {

    // MARK: - Helpers

    /// A folder with two tiles for identity and content checks.
    ///
    /// - Returns: The model of folder "f" with tiles "a" and "b".
    private func makeFolder() -> TesseraTileFolder {
        TesseraTileFolder(
            id: "f",
            title: "Folder",
            tiles: [tesseraTestTile("a"), tesseraTestTile("b")]
        )
    }

    /// A human-readable case name — exactly what a host does in a switch.
    ///
    /// If `TesseraTileGridItem` gains a fourth case, this switch stops
    /// compiling: the test catches the incompatibility at build time.
    ///
    /// - Parameter item: A grid item.
    /// - Returns: The case name.
    private func describe(_ item: TesseraTileGridItem) -> String {
        switch item {
        case .tile:
            return "tile"
        case .folder:
            return "folder"
        case .folderContent:
            return "folderContent"
        }
    }

    // MARK: - New case folderContent (D17)

    /// The panel inherits the folder identifier: the layout uses it to find the folder
    /// row after which the panel is placed (D17: the panel is inserted below the tile).
    func testFolderContentSharesIdentityWithFolder() {
        let folder = makeFolder()
        let panel = TesseraTileGridItem.folderContent(folder)

        XCTAssertEqual(panel.id, folder.id)
        XCTAssertEqual(panel.panelFolder?.id, folder.id)
        XCTAssertEqual(
            panel.panelFolder?.tiles.map { $0.id },
            [AnyHashable("a"), AnyHashable("b")]
        )
    }

    /// The panel is neither a tile nor a folder tile: only `panelFolder`.
    func testFolderContentIsNeitherTileNorFolder() {
        let folder = makeFolder()
        let panel = TesseraTileGridItem.folderContent(folder)

        XCTAssertNil(panel.tile)
        XCTAssertNil(panel.folder)
        XCTAssertNotNil(panel.panelFolder)
    }

    /// The panel has no size of its own: `.wide` is a "full width" marker.
    /// The layout does not pack the panel by this marker: the panel is a separate
    /// full-width row below the folder, not a tile.
    func testFolderContentUsesWideSizeAsFullWidthMarker() {
        let panel = TesseraTileGridItem.folderContent(makeFolder())

        XCTAssertEqual(panel.size, .wide)
        XCTAssertEqual(panel.size.unitColumns, 4)
        XCTAssertEqual(panel.size.unitRows, 2)
    }

    /// The panel's `folderTiles` is empty: the contents are available through `panelFolder`,
    /// so one folder is not counted twice when walking the snapshot.
    func testFolderContentExposesNoTilesOfItsOwn() {
        let panel = TesseraTileGridItem.folderContent(makeFolder())

        XCTAssertTrue(panel.folderTiles.isEmpty)
        XCTAssertEqual(panel.panelFolder?.tiles.count, 2)
    }

    /// The panel flag distinguishes it from a folder tile with the same identifier.
    func testIsFolderPanelDistinguishesPanelFromFolder() {
        let folder = makeFolder()

        XCTAssertTrue(TesseraTileGridItem.folderContent(folder).isFolderPanel)
        XCTAssertFalse(TesseraTileGridItem.folder(folder).isFolderPanel)
        XCTAssertFalse(TesseraTileGridItem.tile(tesseraTestTile("a")).isFolderPanel)
    }

    /// A folder and a panel share an identifier but remain distinct cases: in
    /// a set they sit next to each other (the panel after the tile), and comparing by `id` does not
    /// confuse data with UI state.
    func testFolderAndPanelShareIDButRemainDistinctCases() {
        let folder = makeFolder()
        let panel = TesseraTileGridItem.folderContent(folder)
        let item = TesseraTileGridItem.folder(folder)

        XCTAssertEqual(panel.id, item.id)

        // Comparing by identifier must not mean "the same item":
        // for a panel `folder` is nil, for a folder tile `panelFolder` is nil.
        XCTAssertNotEqual(panel.id, AnyHashable("other"))
        XCTAssertNil(panel.folder)
        XCTAssertNil(item.panelFolder)
    }

    /// Existing cases keep their former semantics (API compatibility).
    func testFolderAndTileCasesKeepTheirPayload() {
        let folder = makeFolder()
        let item = TesseraTileGridItem.folder(folder)
        let tile = tesseraTestTile("x", size: .large, badge: .dot)
        let tileItem = TesseraTileGridItem.tile(tile)

        XCTAssertEqual(item.id, folder.id)
        XCTAssertEqual(item.size, folder.size)
        XCTAssertEqual(item.folder?.id, folder.id)
        XCTAssertEqual(item.folderTiles.map { $0.id }, [AnyHashable("a"), AnyHashable("b")])

        XCTAssertEqual(tileItem.id, tile.id)
        XCTAssertEqual(tileItem.size, .large)
        XCTAssertEqual(tileItem.tile?.id, tile.id)
        XCTAssertEqual(tileItem.tile?.badge, .dot)
        XCTAssertNil(tileItem.folder)
    }

    /// The switch over the three cases is exhaustive and distinguishes all three kinds.
    func testSwitchCoversAllCases() {
        let folder = makeFolder()
        let items: [TesseraTileGridItem] = [
            .tile(tesseraTestTile("a")),
            .folder(folder),
            .folderContent(folder),
        ]

        XCTAssertEqual(items.map(describe), ["tile", "folder", "folderContent"])
    }

    // MARK: - Panel in a snapshot

    /// The snapshot does not treat the panel as data: `layoutItems` and `folders` skip
    /// it, and `item(withID:)` returns the first entry with that
    /// identifier. In practice a `TesseraTileStore` snapshot does not contain the panel —
    /// the test guards hosts that put it into the set anyway.
    func testSnapshotExcludesPanelFromLayoutAndFolders() {
        let folder = makeFolder()
        let snapshot = TesseraTileGridSnapshot(
            items: [
                .folder(folder),
                .folderContent(folder),
            ],
            unpinned: []
        )

        XCTAssertEqual(snapshot.layoutItems.map { $0.id }, [folder.id])
        XCTAssertEqual(snapshot.folders.map { $0.id }, [folder.id])
        XCTAssertEqual(snapshot.item(withID: folder.id)?.folder?.id, folder.id)
        XCTAssertFalse(snapshot.item(withID: folder.id)?.isFolderPanel ?? true)
        XCTAssertEqual(snapshot.items.count, 2)
    }
}

#endif
