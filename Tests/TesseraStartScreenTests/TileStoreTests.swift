//
//  TileStoreTests.swift
//  TesseraStartScreenTests
//
//  Tests for the start screen store.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit mode"
//  (TesseraTileStore keeps order/sizes/pins and survives between
//  launches), §6 "Right page" (the single source of truth,
//  two-way pin/unpin) and §14 "MVP refinements" (D14: folder creation,
//  adding a tile and moving between folders go only through the host
//  approval function; the default is allowed).
//
//  Checked: pin/unpin consistency, move/resize, folders and the approval
//  function, the persistence round trip to a temporary directory, a corrupted
//  file and an unsupported schema version. The tests do not bring up UI and run
//  on the main thread, like TesseraTileStore itself.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreTests: XCTestCase {

    // MARK: - Helpers

    /// The host grid width in all cell operations.
    private let columns = 6

    private func makeDescriptors() -> [TesseraTileDescriptor] {
        [
            tesseraTestTile("a", size: .small),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .medium),
            tesseraTestTile("d", size: .small),
        ]
    }

    /// Creates a store on top of a temporary directory.
    ///
    /// Autosave is off by default: most tests check
    /// the model, not file operations.
    ///
    /// - Parameters:
    ///   - descriptors: The tile catalog (D12).
    ///   - directory: The test's temporary directory.
    ///   - autosaves: Whether to enable autosave.
    /// - Returns: The configured store.
    private func makeStore(
        _ descriptors: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(descriptors)
        // First-launch layout: a(0,0) b(0,1) c(0,3) d(0,5) on 6 columns.
        store.placeItems(columns: columns)
        return store
    }

    private func ids(_ snapshot: TesseraTileGridSnapshot) -> [AnyHashable] {
        snapshot.items.map { $0.id }
    }

    // MARK: - First launch and pinning

    /// On first launch the whole catalog is pinned in registration order.
    func testFirstLaunchPinsCatalogInOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let snapshot = store.snapshot()

        XCTAssertEqual(ids(snapshot), ["a", "b", "c", "d"])
        XCTAssertTrue(snapshot.unpinned.isEmpty)
        XCTAssertEqual(snapshot.layoutItems.map { $0.id }, ids(snapshot))
        XCTAssertTrue(store.isPinned("a"))
    }

    /// pin/unpin are consistent: a tile cannot be on the grid and in the list of
    /// unpinned at once, and repeated calls return `false`.
    func testPinAndUnpinKeepSnapshotConsistent() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        XCTAssertFalse(store.pinTile("a", columns: columns))
        XCTAssertFalse(store.isPinned("missing"))
        XCTAssertFalse(store.pinTile("missing", columns: columns))
        XCTAssertFalse(store.unpin("missing", columns: columns))

        XCTAssertTrue(store.unpin("b", columns: columns))
        XCTAssertFalse(store.isPinned("b"))
        XCTAssertEqual(ids(store.snapshot()), ["a", "c", "d"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["b"])

        // Pinning is a new row at the end of the canvas (D33): reading order a, c, d, b.
        XCTAssertTrue(store.pinTile("b", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), ["a", "c", "d", "b"])
        XCTAssertTrue(store.snapshot().unpinned.isEmpty)
        XCTAssertTrue(store.isPinned("b"))
    }

    /// Unpinning the last tile of a folder dissolves the folder: a tile without
    /// content does not stay on the grid (§5).
    func testUnpinLastFolderTileDissolvesFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        // A 2×2 folder takes the cell of "a" and pushes "b" down (D31).
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "c", "d", "b"])

        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertNil(store.folderContaining("a"))
        XCTAssertEqual(ids(store.snapshot()), ["c", "d", "b"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["a"])
        XCTAssertFalse(store.isPinned("a"))
    }

    /// A tile from a folder cannot be pinned again: the "one tile, one
    /// place" invariant (§6).
    func testPinRejectsTileThatLivesInFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        _ = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        XCTAssertFalse(store.pinTile("a", columns: columns))
        XCTAssertEqual(store.folderContaining("a")?.tiles.count, 1)
    }

    // MARK: - Size of a new folder (always medium)

    /// A folder is always created medium (Windows 10 Mobile), regardless of the size of the target tile
    /// (small/medium/wide/large, saved or from the descriptor); the size
    /// survives a round trip.
    func testCreateFolderIsAlwaysMedium() throws {
        let directory = TesseraTestDirectory()
        // D45: a one-tile folder is dissolved on load, so a second tile was
        // added to each of the three transient folders (apart from checking the size of
        // the new folder the test changes nothing).
        let descriptors = makeDescriptors() + ["e", "f", "g"].map { tesseraTestTile($0, size: .small) }
        let store = makeStore(descriptors, in: directory)

        let small = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertEqual(small.size, .medium)
        let medium = try XCTUnwrap(store.createFolder(withTile: "b", columns: columns))
        XCTAssertEqual(medium.size, .medium)

        XCTAssertTrue(store.resize("c", to: .wide, columns: columns))
        let wide = try XCTUnwrap(store.createFolder(withTile: "c", columns: columns))
        XCTAssertEqual(wide.size, .medium, "The tile's saved wide size is not inherited")
        XCTAssertTrue(store.addToFolder("d", folderID: small.id, columns: columns))
        XCTAssertTrue(store.addToFolder("e", folderID: medium.id, columns: columns))
        XCTAssertTrue(store.addToFolder("f", folderID: wide.id, columns: columns))

        XCTAssertEqual(store.snapshot().folders.map { $0.size }, [.medium, .medium, .medium])

        try store.save()
        let restored = makeStore(descriptors, in: directory)
        try restored.load()
        XCTAssertEqual(restored.snapshot().folders.map { $0.size }, [.medium, .medium, .medium])
    }

    /// Atomic creation from a wide/large target also gives medium; the folder's own size
    /// can be changed by the user (`resize`), and it is preserved, including
    /// for folders written to disk under the earlier size inheritance.
    func testAtomicCreateFromWideTargetIsMediumAndFolderStaysResizable() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        XCTAssertTrue(store.resize("a", to: .large, columns: columns))
        guard case .created(let folder) = store.createFolder(from: "b", onto: "a", columns: columns) else {
            return XCTFail("Creation must succeed")
        }
        XCTAssertEqual(folder.size, .medium)

        XCTAssertTrue(store.resize(folder.id, to: .wide, columns: columns))
        try store.save()
        let restored = makeStore(makeDescriptors(), in: directory)
        try restored.load()
        XCTAssertEqual(restored.snapshot().folders.first?.size, .wide, "The folder's saved size is left alone")
    }

    // MARK: - Take-out from a folder onto the desktop

    /// Taking a tile out of a folder onto a cell: it takes the cell, and the folder keeps the
    /// remaining content. D45: two tiles remain in the folder (after a take-out from a
    /// three-tile folder), so it is not dissolved.
    func testExtractFromFolderLandsOnCell() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: columns))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "d"])

        XCTAssertTrue(store.extractFromFolder("b", toCell: tesseraCell(2, 0), columns: columns))
        XCTAssertEqual(store.placement(of: "b"), tesseraCell(2, 0))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "d", "b"])
        XCTAssertEqual(store.folderContaining("a")?.tiles.count, 2)
    }

    /// Taking out the last tile: the folder disappears, and the tile takes the specified cell.
    func testExtractLastTileRemovesFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), ["a", folder.id, "c", "d"])

        XCTAssertTrue(store.extractFromFolder("b", toCell: tesseraCell(0, 1), columns: columns))
        XCTAssertEqual(ids(store.snapshot()), ["a", "b", "c", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
    }

    /// A take-out to a new row puts the tile after the last occupied row.
    func testExtractFromFolderToNewRow() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", columns: columns))
        XCTAssertTrue(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: columns))

        // D45: two remain in a three-tile folder, so it is not dissolved.
        XCTAssertTrue(store.extractFromFolderToNewRow("b", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "d", "b"])
        XCTAssertEqual(store.placement(of: "b")?.column, 0)
    }

    // MARK: - move / resize

    /// A move to a cell is clamped by the canvas; unknown tiles and a move to
    /// its own cell give `false` (a layout operation, without D14 approval).
    func testMoveItemRejectsUnknownAndSameCell() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(0, 0), columns: columns), "own cell")
        XCTAssertFalse(store.moveItem("missing", toCell: tesseraCell(1, 0), columns: columns))

        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(5, 99), columns: columns))
        XCTAssertEqual(store.placement(of: "a"), tesseraCell(5, 5), "the column is clamped by the canvas")

        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(store.unpin(id, columns: columns))
        }
        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(0, 0), columns: columns))
    }

    /// resize changes a tile's authoritative size (D15), a repeat is a no-op,
    /// and an unknown identifier gives `false`.
    func testResizeUpdatesAuthoritativeSizeAndIgnoresNoOps() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        for size in [TesseraTileSize.medium, .wide, .large, .small] {
            XCTAssertTrue(store.resize("a", to: size, columns: columns))
            XCTAssertEqual(store.descriptor(withID: "a")?.size, size)
            XCTAssertEqual(
                store.snapshot().items.first(where: { $0.id == AnyHashable("a") })?.size,
                size
            )
            XCTAssertFalse(store.resize("a", to: size, columns: columns))
        }

        XCTAssertFalse(store.resize("missing", to: .wide, columns: columns))
    }

    /// A folder scales too; the size of a tile inside a folder is visible in its snapshot.
    func testResizeFolderAndFolderTiles() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        XCTAssertTrue(store.resize(folder.id, to: .wide, columns: columns))
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)
        XCTAssertFalse(store.resize(folder.id, to: .wide, columns: columns))

        XCTAssertTrue(store.resize("a", to: .large, columns: columns))
        XCTAssertEqual(store.folderContaining("a")?.tiles.first?.size, .large)
    }

    // MARK: - Persistence

    /// Round trip: order, sizes, folders and pins survive writing and
    /// reading JSON (§5).
    func testPersistenceRoundTripKeepsOrderSizesFoldersAndPins() throws {
        let directory = TesseraTestDirectory()
        let descriptors = makeDescriptors()

        let store = makeStore(descriptors, in: directory)
        XCTAssertTrue(store.unpin("d", columns: columns))
        XCTAssertTrue(store.resize("a", to: .wide, columns: columns))
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", title: "Work", columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: columns))
        try store.save()
        XCTAssertNil(store.lastPersistenceError)

        let restored = makeStore(descriptors, in: directory)
        try restored.load()

        let snapshot = restored.snapshot()
        XCTAssertEqual(ids(snapshot), [AnyHashable("a"), folder.id])
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertEqual(snapshot.folders.first?.title, "Work")
        XCTAssertEqual(
            snapshot.folders.first?.tiles.map { $0.id },
            [AnyHashable("b"), AnyHashable("c")]
        )
        XCTAssertEqual(restored.descriptor(withID: "a")?.size, .wide)
        XCTAssertEqual(snapshot.unpinned.map { $0.id }, [AnyHashable("d")])
        XCTAssertFalse(restored.isPinned("d"))

        // The second round trip: a new pin (a new row) also survives a restart.
        XCTAssertTrue(restored.pinTile("d", columns: columns))
        try restored.save()

        let restoredAgain = makeStore(descriptors, in: directory)
        try restoredAgain.load()
        XCTAssertEqual(
            ids(restoredAgain.snapshot()),
            [AnyHashable("a"), folder.id, AnyHashable("d")]
        )
    }

    /// With autosave enabled, an edit operation immediately writes the state
    /// file (§5).
    func testAutosaveWritesStateFile() {
        let directory = TesseraTestDirectory()
        // Without `placeItems`: the store does not know the grid width yet, and there is no file.
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = true
        store.setCatalog(makeDescriptors())

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(store.unpin("a", columns: columns))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(store.lastPersistenceError)
    }

    /// A write error does not break the model: the operation completes, and the error goes
    /// into `lastPersistenceError`.
    func testPersistenceErrorIsRecordedWithoutBreakingState() throws {
        let directory = TesseraTestDirectory()
        // A file lies where the catalog should be, so a directory cannot be created.
        try Data("not a directory".utf8).write(to: directory.url)

        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = true
        store.setCatalog(makeDescriptors())

        XCTAssertTrue(store.resize("a", to: .wide, columns: columns))
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)
        XCTAssertThrowsError(try store.save())
    }

    /// A corrupted file: `load()` throws an error and does not change the current state.
    func testLoadThrowsOnCorruptedFileAndKeepsState() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(makeDescriptors(), in: directory)

        try Data("{ not JSON".utf8).write(to: store.fileURL)
        let before = ids(store.snapshot())

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(ids(store.snapshot()), before)
        XCTAssertTrue(store.isPinned("a"))
    }

    /// A file newer than the current schema is not read (§5, a versioned document).
    func testLoadThrowsOnUnsupportedSchemaVersion() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(makeDescriptors(), in: directory)

        let json = #"{"version":99,"items":[],"sizes":{},"folders":[]}"#
        try Data(json.utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard let storeError = error as? TesseraTileStoreError else {
                return XCTFail("Expected TesseraTileStoreError, got: \(error)")
            }
            switch storeError {
            case .unsupportedSchemaVersion(let version):
                XCTAssertEqual(version, 99)
            }
        }
    }

    // MARK: - Approval function (D14)

    /// The host gets the right folder, tile and operation type for all three
    /// D14 actions.
    func testApprovalReceivesCorrectFolderTileAndAction() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        var calls: [(folder: AnyHashable?, tile: AnyHashable, action: TesseraTileGroupingAction)] = []
        store.approval = { folder, tile, action in
            calls.append((folder?.id, tile.id, action))
            return true
        }

        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].folder)
        XCTAssertEqual(calls[0].tile, AnyHashable("a"))
        XCTAssertEqual(calls[0].action, .createFolder)

        XCTAssertTrue(store.addToFolder("b", folderID: folderA.id, columns: columns))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].folder, folderA.id)
        XCTAssertEqual(calls[1].tile, AnyHashable("b"))
        XCTAssertEqual(calls[1].action, .addToFolder)

        let folderB = try XCTUnwrap(store.createFolder(withTile: "c", title: "B", columns: columns))
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[2].action, .createFolder)

        XCTAssertTrue(store.moveBetweenFolders("b", to: folderB.id, columns: columns))
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[3].folder, folderB.id)
        XCTAssertEqual(calls[3].tile, AnyHashable("b"))
        XCTAssertEqual(calls[3].action, .moveBetweenFolders)

        XCTAssertTrue(store.extractFromFolderToNewRow("b", columns: columns))
        XCTAssertEqual(calls.count, 5)
        XCTAssertNil(calls[4].folder)
        XCTAssertEqual(calls[4].tile, AnyHashable("b"))
        XCTAssertEqual(calls[4].action, .moveBetweenFolders)
    }

    /// A refusal to create a folder does not change state.
    func testDeniedCreateFolderLeavesStateUntouched() {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let before = ids(store.snapshot())

        store.approval = { _, _, action in action != .createFolder }

        XCTAssertNil(store.createFolder(withTile: "a", title: "A", columns: columns))
        XCTAssertEqual(ids(store.snapshot()), before)
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertTrue(store.isPinned("a"))
    }

    /// A refusal to add a tile to a folder leaves the tile on the grid.
    func testDeniedAddToFolderKeepsTileOnGrid() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))

        store.approval = { _, _, action in action != .addToFolder }

        XCTAssertFalse(store.addToFolder("b", folderID: folder.id, columns: columns))
        XCTAssertEqual(ids(store.snapshot()), [folder.id, "c", "d", "b"], "'b' was pushed down by the folder and stayed on the grid")
        XCTAssertEqual(
            store.snapshot().folders.first?.tiles.map { $0.id },
            [AnyHashable("a")]
        )
    }

    /// A refusal to move between folders leaves the tile in the source folder.
    func testDeniedMoveBetweenFoldersKeepsTileInSourceFolder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B", columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folderA.id, columns: columns))

        store.approval = { _, _, action in action != .moveBetweenFolders }

        XCTAssertFalse(store.moveBetweenFolders("c", to: folderB.id, columns: columns))
        XCTAssertEqual(store.folderContaining("c")?.id, folderA.id)
        XCTAssertEqual(
            store.snapshot().folders.first(where: { $0.id == folderB.id })?.tiles.map { $0.id },
            [AnyHashable("b")]
        )
    }

    /// A move to the desktop (`nil`) goes through the same D14 approval.
    /// D45: both source folders lose a tile and are left with one, so they are dissolved, and
    /// the tiles take the folders' cells; the moved-out tile goes into a new row at the end.
    func testMoveBetweenFoldersReturnsTileToDesktopAndDissolvesFolders() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)
        let folderA = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        let folderB = try XCTUnwrap(store.createFolder(withTile: "b", title: "B", columns: columns))
        XCTAssertTrue(store.addToFolder("c", folderID: folderA.id, columns: columns))

        // "c" leaves folder A: "a" remains in it, so the folder is dissolved.
        XCTAssertTrue(store.moveBetweenFolders("c", to: folderB.id, columns: columns))
        XCTAssertNil(store.folderContaining("a"))
        XCTAssertEqual(store.folderContaining("c")?.id, folderB.id)
        // "c" leaves folder B: "b" remains, so it is dissolved too.
        XCTAssertTrue(store.extractFromFolderToNewRow("c", columns: columns))

        XCTAssertTrue(store.snapshot().folders.isEmpty)
        XCTAssertNil(store.folderContaining("c"))
        XCTAssertEqual(Set(ids(store.snapshot())), ["a", "b", "c", "d"])
        // A take-out without a cell is a new row at the end of the canvas; order follows the cells.
        XCTAssertEqual(ids(store.snapshot()).last, "c")
        XCTAssertTrue(store.isPinned("c"))
    }

    /// A move into the same folder is rejected before the approval is called: the host does not
    /// receive a meaningless operation.
    func testMoveBetweenFoldersRejectsSameFolderWithoutApproval() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(makeDescriptors(), in: directory)

        var approvalCalls = 0
        store.approval = { _, _, _ in
            approvalCalls += 1
            return true
        }

        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: columns))
        XCTAssertEqual(approvalCalls, 1)

        XCTAssertFalse(store.moveBetweenFolders("a", to: folder.id, columns: columns))
        XCTAssertEqual(approvalCalls, 1)
        XCTAssertEqual(store.folderContaining("a")?.id, folder.id)
    }
}

#endif
