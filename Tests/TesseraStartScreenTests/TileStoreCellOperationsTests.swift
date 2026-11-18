//
//  TileStoreCellOperationsTests.swift
//  TesseraStartScreenTests
//
//  `TesseraTileStore` cell operations: move, in-place resize, folders,
//  unpin/pin, collapsing empty rows.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 and "Implementation
//  deviations"; decisions D20, D30–D33 in docs/DECISIONS.md.
//
//  What is tested: holes remain (no repack), cascading push down,
//  a 2×2 folder in place of a small target and a column shift to the left, take-out onto a cell and into
//  a new row, a folder that became empty disappearing with a hole, in-place resize,
//  pinning into a new row, collapsing only uncovered rows (and
//  idempotency), one notification per operation, no-op on invalid input,
//  model consistency (`tesseraAssertCellInvariants`). The names are
//  `resize(_:to:columns:)` and `pinTile(_:columns:)` (formerly `resizeInPlace`,
//  `pinTileToNewRow`).
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreCellOperationsTests: XCTestCase {

    private let columns = 6

    private func makeStore(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = [],
        in directory: TesseraTestDirectory,
        columns: Int = 6
    ) throws -> TesseraTileStore {
        try TileStoreCellFixture.makeStore(
            columns: columns, tiles: tiles, folders: folders, unpinned: unpinned, in: directory
        )
    }

    private func catalogIDs(
        _ tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = []
    ) -> [String] {
        tiles.map { $0.id } + folders.flatMap { $0.contents.map { $0.id } } + unpinned.map { $0.0 }
    }

    // MARK: - Move

    /// A move to a free cell: a hole remains, the others do not move.
    func testMoveItemToFreeCellLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 0, 2)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(3, 4), columns: columns))

        XCTAssertEqual(store.placement(of: "a"), tesseraCell(3, 4))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 2))
        XCTAssertNil(store.placements.values.first { $0 == tesseraCell(0, 0) }, "cell (0, 0) is a hole")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
        XCTAssertEqual(tesseraTestIDs(store.snapshot().items), ["b", "c", "a"])
    }

    /// Cascade: an insertion pushes a chain down and leaves the rest alone.
    func testMoveItemPushesDownCascade() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("A", .medium, 0, 0),
            CellFixtureTile("B", .small, 2, 0),
            CellFixtureTile("C", .small, 3, 0),
            CellFixtureTile("D", .small, 0, 3),
            CellFixtureTile("X", .small, 0, 4),
        ]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItem("X", toCell: tesseraCell(0, 0), columns: columns))

        XCTAssertEqual(store.placement(of: "X"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "A"), tesseraCell(1, 0))
        XCTAssertEqual(store.placement(of: "B"), tesseraCell(3, 0))
        XCTAssertEqual(store.placement(of: "C"), tesseraCell(4, 0))
        XCTAssertEqual(store.placement(of: "D"), tesseraCell(0, 3), "outside the affected area: stays in place")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// A cell that is too far right shifts left; a move onto its own cell is a no-op.
    func testMoveItemClampsLeftAndSameCellIsNoOp() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("w", .wide, 0, 0), CellFixtureTile("s", .small, 2, 0)]
        let store = try makeStore(tiles, in: directory)
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertTrue(store.moveItem("w", toCell: tesseraCell(4, 5), columns: columns))
        XCTAssertEqual(store.placement(of: "w"), tesseraCell(4, 2), "wide 4×2 on 6 columns: column ≤ 2")
        XCTAssertEqual(notifications, 1)

        XCTAssertFalse(store.moveItem("w", toCell: tesseraCell(4, 2), columns: columns))
        XCTAssertFalse(store.moveItem("w", toCell: tesseraCell(4, 5), columns: columns), "after clamping the same cell")
        XCTAssertEqual(notifications, 1, "a no-op does not notify")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// A folder is moved the same way as a tile.
    func testMoveFolderToCell() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)])]
        let tiles = [CellFixtureTile("a", .small, 0, 2)]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.moveItem("f", toCell: tesseraCell(2, 2), columns: columns))
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(2, 2))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 2))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// A move to a new row: after the last occupied one, column 0, a hole remains.
    func testMoveItemToNewRow() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .medium, 0, 2), CellFixtureTile("c", .small, 1, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItemToNewRow("a", columns: columns))

        XCTAssertEqual(store.placement(of: "a"), tesseraCell(2, 0))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 2))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// The only item in the last row: the "new row" is its own.
    func testMoveItemToNewRowWhenAlreadyAloneAtBottomIsNoOp() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 1, 0)]
        let store = try makeStore(tiles, in: directory)
        XCTAssertFalse(store.moveItemToNewRow("b", columns: columns))
    }

    // MARK: - Resize

    /// Growth pushes down; the size is kept in the model; the anchor stays.
    func testResizeGrowthPushesDown() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 1, 0), CellFixtureTile("z", .small, 0, 4)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.resize("a", to: .medium, columns: columns))

        XCTAssertEqual(store.snapshot().item(withID: "a")?.size, .medium)
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(2, 1), "b intersected the 2×2: down below it")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(2, 0))
        XCTAssertEqual(store.placement(of: "z"), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Shrinking leaves a hole and moves nothing.
    func testResizeShrinkLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("big", .large, 0, 0), CellFixtureTile("n", .small, 4, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.resize("big", to: .small, columns: columns))

        XCTAssertEqual(store.placement(of: "big"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "n"), tesseraCell(4, 0), "nothing was pulled up")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Growth at the right edge shifts the column left; a folder resizes the same way.
    func testResizeClampsLeftAndWorksForFolders() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("s", .small, 0, 5)]
        let folders = [CellFixtureFolder("f", .medium, 4, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.resize("s", to: .medium, columns: columns))
        XCTAssertEqual(store.placement(of: "s"), tesseraCell(0, 4))

        XCTAssertTrue(store.resize("f", to: .wide, columns: columns))
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(4, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// The same size, an unknown item: a no-op. A tile inside a folder: only the size.
    func testResizeNoOpsAndTileInFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.resize("a", to: .small, columns: columns))
        XCTAssertFalse(store.resize("nope", to: .wide, columns: columns))
        XCTAssertFalse(store.resize("a", to: .wide, columns: 0))
        XCTAssertEqual(notifications, 0)

        XCTAssertTrue(store.resize("x", to: .wide, columns: columns))
        XCTAssertEqual(store.tileSizeInFolder("x"), .wide)
        XCTAssertEqual(store.placements, before, "cells did not change")
        XCTAssertEqual(notifications, 1)
    }

    // MARK: - Folder creation

    /// A small target becomes a 2×2 folder on its own cell and pushes a neighbor;
    /// the source cell stays a hole.
    func testCreateFolderOnSmallTargetBecomesMediumAndPushesNeighbor() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("T", .small, 1, 1),
            CellFixtureTile("N", .small, 1, 2),
            CellFixtureTile("S", .small, 0, 5),
            CellFixtureTile("K", .small, 4, 4),
        ]
        let store = try makeStore(tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "S", onto: "T", title: "Games", columns: columns) else {
            return XCTFail("the folder must be created")
        }

        XCTAssertEqual(folder.size, .medium, "D20: a folder is always 2×2")
        XCTAssertEqual(folder.title, "Games")
        XCTAssertEqual(folder.tiles.map { $0.id }, ["T", "S"])
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(1, 1))
        XCTAssertEqual(store.placement(of: "N"), tesseraCell(3, 2), "N is pushed below the folder")
        XCTAssertEqual(store.placement(of: "K"), tesseraCell(4, 4))
        XCTAssertNil(store.placement(of: "S"))
        XCTAssertNil(store.placement(of: "T"))
        XCTAssertFalse(store.placements.values.contains(tesseraCell(0, 5)), "the source cell is a hole")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// A target at the right edge: the folder shifts left.
    func testCreateFolderClampsLeft() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .small, 0, 5), CellFixtureTile("S", .small, 3, 0)]
        let store = try makeStore(tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("the folder must be created")
        }
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// A wide target is replaced by a medium folder, the other cells are holes.
    func testCreateFolderOnWideTargetKeepsHoles() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .wide, 0, 0), CellFixtureTile("S", .small, 2, 0), CellFixtureTile("K", .small, 0, 4)]
        let store = try makeStore(tiles, in: directory)

        guard case .created(let folder) = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("the folder must be created")
        }
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(0, 0))
        XCTAssertEqual(store.snapshot().item(withID: folder.id)?.size, .medium)
        XCTAssertEqual(store.placement(of: "K"), tesseraCell(0, 4))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Host approval: the order of the questions, a rejection of the first and second step leaves no trace.
    func testCreateFolderApprovalAndDenials() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .small, 0, 0), CellFixtureTile("S", .small, 0, 1)]
        let store = try makeStore(tiles, in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        var actions: [TesseraTileGroupingAction] = []
        store.approval = { _, _, action in actions.append(action); return action != .createFolder }
        guard case .createDenied = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("a creation rejection was expected")
        }
        XCTAssertEqual(actions, [.createFolder])

        actions = []
        store.approval = { _, _, action in actions.append(action); return action != .addToFolder }
        guard case .addDenied = store.createFolder(from: "S", onto: "T", columns: columns) else {
            return XCTFail("an addition rejection was expected")
        }
        XCTAssertEqual(actions, [.createFolder, .addToFolder])

        XCTAssertEqual(store.placements, before)
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(notifications, 0)
    }

    /// Invalid input: the same tile, not on the grid, a folder instead of a tile, width 0.
    func testCreateFolderInvalidInput() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("T", .small, 0, 0), CellFixtureTile("S", .small, 0, 1)]
        // D45: a folder has at least two tiles (a single-tile one is dissolved on load).
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)])]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)

        for (source, target, columns) in [("T", "T", 6), ("S", "u", 6), ("u", "T", 6), ("S", "f", 6), ("S", "x", 6), ("S", "T", 0)] as [(String, String, Int)] {
            guard case .createDenied = store.createFolder(from: source, onto: target, columns: columns) else {
                return XCTFail("(\(source), \(target), \(columns)) must be rejected")
            }
        }
        XCTAssertEqual(store.snapshot().folders.count, 1)
    }

    // MARK: - Adding to a folder

    /// A tile goes into the folder; its cell is a hole, the folder stays on its own.
    func testAddToFolderLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 0, 4)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.addToFolder("a", folderID: "f", columns: columns))

        XCTAssertNil(store.placement(of: "a"))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(0, 4))
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(2, 0))
        XCTAssertEqual(store.folderContaining("a")?.id, AnyHashable("f"))
        XCTAssertEqual(store.snapshot().folders.first?.tiles.map { $0.id }, ["x", "y", "a"])
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// A host rejection, a repeat, a tile in another folder, unknown ids: all no-ops.
    func testAddToFolderNoOps() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [
            CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 2, 3, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.addToFolder("x", folderID: "f", columns: columns), "already in this folder")
        XCTAssertFalse(store.addToFolder("y", folderID: "f", columns: columns), "in another folder")
        XCTAssertFalse(store.addToFolder("u", folderID: "f", columns: columns), "not on the grid")
        XCTAssertFalse(store.addToFolder("a", folderID: "nope", columns: columns))
        XCTAssertFalse(store.addToFolder("a", folderID: "f", columns: 0))
        store.approval = { _, _, _ in false }
        XCTAssertFalse(store.addToFolder("a", folderID: "f", columns: columns), "the host forbade it")

        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(notifications, 0)
    }

    // MARK: - Take-out from a folder

    /// A take-out onto a cell with the tile's own size: a cascade; a folder of three stays with two
    /// (D45: from two it would be left with one, so it is dissolved, see `TileStoreFolderMinTwoTests`).
    func testExtractFromFolderToCellKeepsFolderWithRemainingTile() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 3, 0), CellFixtureTile("b", .small, 5, 0)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .medium), ("y", .small), ("z", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 0), columns: columns))

        XCTAssertEqual(store.placement(of: "x"), tesseraCell(3, 0))
        XCTAssertEqual(store.snapshot().item(withID: "x")?.size, .medium, "the tile keeps its own size")
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(5, 0), "a is pushed below x")
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(6, 0), "the cascade reached b")
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(0, 0), "the folder with two tiles stays")
        XCTAssertEqual(store.folderContaining("y")?.tiles.map { $0.id }, ["y", "z"])
        XCTAssertNil(store.folderContaining("x"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Taking out the last tile of a transitional folder (D45: a single-tile folder is
    /// only `createFolder(withTile:)`): the folder disappears, its cell is a hole.
    func testExtractLastTileRemovesFolderAndLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 3), CellFixtureTile("x", .small, 0, 0)]
        let folders: [CellFixtureFolder] = []
        let store = try makeStore(tiles, folders: folders, in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "x", columns: columns))
        XCTAssertEqual(store.placement(of: folder.id), tesseraCell(0, 0))

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(4, 4), columns: columns))

        XCTAssertNil(store.placement(of: folder.id))
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(4, 4))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 3))
        XCTAssertFalse(store.placements.values.contains(tesseraCell(0, 0)), "the folder cell is a hole")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// A take-out into a new row; an emptied folder does not count toward the row.
    func testExtractToNewRow() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 3)]
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small)]),
            CellFixtureFolder("g", .medium, 4, 0, contents: [("z", .small), ("z2", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, in: directory)

        // D45: x leaves folder f (x, y), and f dissolves into y on its own cell.
        XCTAssertTrue(store.extractFromFolderToNewRow("x", columns: columns))
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(6, 0), "after folder g (rows 4–5)")
        XCTAssertEqual(store.placement(of: "y"), tesseraCell(0, 0), "y took the place of f")

        // z leaves folder g: g dissolves into z2 (small, row 4), row 5 is free;
        // the new row is computed from the lowest occupied one, which is x (row 6).
        XCTAssertTrue(store.extractFromFolderToNewRow("z", columns: columns))
        XCTAssertNil(store.placement(of: "g"))
        XCTAssertEqual(store.placement(of: "z2"), tesseraCell(4, 0))
        XCTAssertEqual(store.placement(of: "z"), tesseraCell(7, 0), "after x (row 6)")
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Taking a wide tile out to the right edge shifts the column left.
    func testExtractClampsLeft() throws {
        let directory = TesseraTestDirectory()
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .wide), ("y", .small)])]
        let store = try makeStore([], folders: folders, in: directory)

        XCTAssertTrue(store.extractFromFolder("x", toCell: tesseraCell(3, 5), columns: columns))
        XCTAssertEqual(store.placement(of: "x"), tesseraCell(3, 2))
    }

    /// Invalid input and a host rejection: a no-op; the host receives `.moveBetweenFolders`.
    func testExtractNoOpsAndApprovalAction() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("y", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)
        let before = store.placements
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertFalse(store.extractFromFolder("a", toCell: tesseraCell(1, 1), columns: columns), "the tile is not in a folder")
        XCTAssertFalse(store.extractFromFolder("nope", toCell: tesseraCell(1, 1), columns: columns))
        XCTAssertFalse(store.extractFromFolderToNewRow("a", columns: columns))
        XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(1, 1), columns: 0))

        var seen: [(TesseraTileGroupingAction, Bool)] = []
        store.approval = { folder, _, action in seen.append((action, folder == nil)); return false }
        XCTAssertFalse(store.extractFromFolder("x", toCell: tesseraCell(1, 1), columns: columns))
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, .moveBetweenFolders)
        XCTAssertEqual(seen.first?.1, true, "target folder nil: onto the desktop")

        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(notifications, 0)
    }

    // MARK: - Between folders

    /// A source folder of two tiles dissolved (D45): the remaining tile took its
    /// cell (previously an emptied folder left a hole here), the rest stays in place.
    func testMoveBetweenFoldersDissolvingSourceFillsCellWithRemainingTile() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small)]),
            CellFixtureFolder("g", .medium, 2, 2, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))

        XCTAssertNil(store.placement(of: "f"))
        XCTAssertEqual(store.placement(of: "x2"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "g"), tesseraCell(2, 2))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 4))
        XCTAssertEqual(store.folderContaining("x")?.id, AnyHashable("g"))
        XCTAssertNil(store.folderContaining("x2"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// The source folder stays (it has three tiles, D45): cells do not change; the same
    /// folder/rejection is a no-op.
    func testMoveBetweenFoldersKeepingSourceAndNoOps() throws {
        let directory = TesseraTestDirectory()
        let folders = [
            CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("x2", .small), ("x3", .small)]),
            CellFixtureFolder("g", .medium, 2, 2, contents: [("y", .small), ("y2", .small)]),
        ]
        let store = try makeStore([], folders: folders, in: directory)
        let before = store.placements

        XCTAssertFalse(store.moveBetweenFolders("x", to: "f", columns: columns), "into the same folder")
        XCTAssertFalse(store.moveBetweenFolders("x", to: "nope", columns: columns))
        XCTAssertFalse(store.moveBetweenFolders("ghost", to: "g", columns: columns))
        store.approval = { _, _, _ in false }
        XCTAssertFalse(store.moveBetweenFolders("x", to: "g", columns: columns))
        store.approval = { _, _, _ in true }

        XCTAssertTrue(store.moveBetweenFolders("x", to: "g", columns: columns))
        XCTAssertEqual(store.placements, before)
        XCTAssertEqual(store.folderContaining("x2")?.tiles.map { $0.id }, ["x2", "x3"])
    }

    // MARK: - Unpin and pin

    /// Unpinning a tile on the grid leaves a hole; it appears among the unpinned ones.
    func testUnpinLeavesHole() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 1, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.unpin("a", columns: columns))

        XCTAssertNil(store.placement(of: "a"))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 0))
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertFalse(store.isPinned("a"))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Unpinning tiles from a folder one by one (D45): from three, the folder stays with two,
    /// from two it dissolves, and the last tile takes the folder's cell.
    func testUnpinFolderContentOneByOneDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 4)]
        let folders = [CellFixtureFolder("f", .medium, 0, 0, contents: [("x", .small), ("y", .small), ("z", .small)])]
        let store = try makeStore(tiles, folders: folders, in: directory)

        XCTAssertTrue(store.unpin("x", columns: columns))
        XCTAssertEqual(store.placement(of: "f"), tesseraCell(0, 0))
        XCTAssertEqual(store.folderContaining("y")?.tiles.map { $0.id }, ["y", "z"])

        XCTAssertTrue(store.unpin("y", columns: columns))
        XCTAssertNil(store.placement(of: "f"))
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertEqual(store.placement(of: "z"), tesseraCell(0, 0), "the remaining tile is in the folder's place")
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 4))
        XCTAssertEqual(Set(store.snapshot().unpinned.map { $0.id }), ["x", "y"])
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, folders: folders))
    }

    /// Unpinning an unknown or already unpinned tile, a folder and width 0 are no-ops.
    func testUnpinNoOps() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)])]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)

        XCTAssertFalse(store.unpin("u", columns: columns))
        XCTAssertFalse(store.unpin("nope", columns: columns))
        XCTAssertFalse(store.unpin("f", columns: columns), "a folder cannot be unpinned (D38)")
        XCTAssertFalse(store.unpin("a", columns: 0))
        XCTAssertEqual(store.snapshot().items.count, 2)
    }

    /// Pinning: a new row at the end, the size from `sizes`/the catalog.
    func testPinTileGoesToNewRow() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .medium, 0, 0), CellFixtureTile("b", .small, 0, 4)]
        let store = try makeStore(tiles, unpinned: [("w", .wide), ("s", .small)], in: directory)

        XCTAssertTrue(store.pinTile("w", columns: columns))
        XCTAssertEqual(store.placement(of: "w"), tesseraCell(2, 0))
        XCTAssertEqual(store.snapshot().item(withID: "w")?.size, .wide)

        XCTAssertTrue(store.pinTile("s", columns: columns))
        XCTAssertEqual(store.placement(of: "s"), tesseraCell(4, 0))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(0, 0))
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles, unpinned: [("w", .wide), ("s", .small)]))
    }

    /// On a narrow grid a large tile shrinks in width, the column is 0.
    func testPinTileFitsNarrowGrid() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let store = try makeStore(tiles, unpinned: [("L", .large)], in: directory, columns: 2)

        XCTAssertTrue(store.pinTile("L", columns: 2))
        XCTAssertEqual(store.placement(of: "L"), tesseraCell(1, 0))
        tesseraAssertCellInvariants(store, columns: 2, catalogIDs: ["a", "L"])
    }

    /// Pinning: already on the grid, in a folder, not in the catalog, width 0 are no-ops.
    func testPinTileNoOps() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0)]
        let folders = [CellFixtureFolder("f", .medium, 2, 0, contents: [("x", .small), ("x2", .small)])]
        let store = try makeStore(tiles, folders: folders, unpinned: [("u", .small)], in: directory)

        XCTAssertFalse(store.pinTile("a", columns: columns))
        XCTAssertFalse(store.pinTile("x", columns: columns))
        XCTAssertFalse(store.pinTile("nope", columns: columns))
        XCTAssertFalse(store.pinTile("u", columns: 0))
        XCTAssertEqual(store.snapshot().items.count, 2)
    }

    // MARK: - Collapsing empty rows

    /// Only rows that no item covers are collapsed.
    func testCollapseEmptyRowsOnlyRemovesUncoveredRows() throws {
        let directory = TesseraTestDirectory()
        let tiles = [
            CellFixtureTile("tall", .large, 1, 0),   // rows 1–4
            CellFixtureTile("s1", .small, 1, 4),     // row 1
            CellFixtureTile("s2", .small, 7, 4),     // row 7; 5–6 are empty
            CellFixtureTile("s3", .small, 10, 0),    // 8–9 are empty
        ]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.collapseEmptyRows(columns: columns))

        // Row 0 is empty (above all), 5–6 are empty, 8–9 are empty: 5 rows in total will go away.
        XCTAssertEqual(store.placement(of: "tall"), tesseraCell(0, 0))
        XCTAssertEqual(store.placement(of: "s1"), tesseraCell(0, 4), "rows 2–4 are covered by the tall tile")
        XCTAssertEqual(store.placement(of: "s2"), tesseraCell(5 - 1, 4), "7 − (1 + 2)")
        XCTAssertEqual(store.placement(of: "s3"), tesseraCell(10 - 5, 0))
        tesseraAssertCellInvariants(store, columns: columns, catalogIDs: catalogIDs(tiles))
    }

    /// Idempotency: a repeated call and a layout without empty rows are a no-op.
    func testCollapseEmptyRowsIsIdempotentAndSilent() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 3, 0)]
        let store = try makeStore(tiles, in: directory)
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        XCTAssertTrue(store.collapseEmptyRows(columns: columns))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(1, 0))
        let afterFirst = store.placements
        let fileAfterFirst = try Data(contentsOf: store.fileURL)

        XCTAssertFalse(store.collapseEmptyRows(columns: columns))
        XCTAssertEqual(store.placements, afterFirst)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), fileAfterFirst)
        XCTAssertEqual(notifications, 1)
        XCTAssertFalse(store.collapseEmptyRows(columns: 0))
    }

    /// Row operations do not collapse: a hole row stays until `collapseEmptyRows` is called.
    func testOperationsDoNotCollapseRowsByThemselves() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 1, 0), CellFixtureTile("c", .small, 2, 0)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.unpin("b", columns: columns))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(2, 0), "empty row 1 stayed")
        XCTAssertTrue(store.collapseEmptyRows(columns: columns))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(1, 0))
    }

    // MARK: - Notifications and no repack

    /// One operation is one `onChange`, and the snapshot is already consistent.
    func testSingleNotificationPerOperation() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1)]
        let store = try makeStore(tiles, in: directory)
        var snapshots: [TesseraTileGridSnapshot] = []
        store.onChange = { snapshots.append($0) }

        guard case .created(let folder) = store.createFolder(from: "a", onto: "b", columns: columns) else {
            return XCTFail("the folder must be created")
        }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(tesseraTestIDs(snapshots[0].items), [folder.id])
    }

    /// Operations do not recompute cells by packing: a neighbor leaving leaves a hole, and
    /// the cell of a distant tile is not pulled up (the transitional repack was removed).
    func testUnpinDoesNotRepackOtherCells() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 0, 1), CellFixtureTile("c", .small, 3, 3)]
        let store = try makeStore(tiles, in: directory)

        XCTAssertTrue(store.moveItem("c", toCell: tesseraCell(5, 5), columns: columns))
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(5, 5), "the cell was not recomputed by packing")

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(0, 1), "the hole at \"a\" stayed")
        XCTAssertEqual(store.placement(of: "c"), tesseraCell(5, 5))
    }

    /// A host width different from the canvas does not overwrite the file on an input error (D32).
    func testInvalidInputDoesNotAdoptCanvasOrWriteFile() throws {
        let directory = TesseraTestDirectory()
        let tiles = [CellFixtureTile("a", .small, 0, 0), CellFixtureTile("b", .small, 3, 5)]
        let store = try makeStore(tiles, in: directory)
        let original = try Data(contentsOf: store.fileURL)

        XCTAssertFalse(store.moveItem("nope", toCell: tesseraCell(0, 0), columns: 4))
        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(0, 0), columns: 4), "already in place in the projection")
        XCTAssertFalse(store.collapseEmptyRows(columns: 4), "there are no empty rows in the projection")

        XCTAssertEqual(store.canvasColumns, 6)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }
}

private extension TesseraTileStore {

    /// The size of a tile from the store catalog (for checking resize inside a folder).
    func tileSizeInFolder(_ id: AnyHashable) -> TesseraTileSize? {
        folderContaining(id)?.tiles.first { $0.id == id }?.size
    }
}

#endif
