//
//  TileStoreRecoveryTests.swift
//  TesseraStartScreenTests
//
//  Tests of `TesseraTileStore` state recovery.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit
//  mode" (persistence), §6 (a single source of truth, pin/unpin) and
//  "Implementation deviations"; plan — docs/PLAN.md.
//
//  What is checked:
//  - "dead" folders: after `setCatalog` → `load()` a folder without a single tile
//  of the catalog is dissolved, and unknown tiles are removed from folders; the result
//  does not depend on the order of the `setCatalog`/`load` calls;
//  - "orphan" folders (present in the file's `folders` but absent from `items`) go to the end
//  of the grid, and their tiles are not lost; the "a tile lives in one place" invariants and
//  consistency of `isPinned`/`pin`/`unpinned`;
//  - a corrupted file and a file of a newer schema are set aside as a backup
//  before the first write, and autosave writes a new file.
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreRecoveryTests: XCTestCase {

    // MARK: - Helpers

    private func catalog(_ ids: [String]) -> [TesseraTileDescriptor] {
        ids.map { tesseraTestTile($0, size: .small) }
    }

    private func makeStore(
        _ descriptors: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory,
        autosaves: Bool = false
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(descriptors)
        return store
    }

    private func ids(_ store: TesseraTileStore) -> [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Backup files in the store directory.
    private func backupFiles(in directory: TesseraTestDirectory) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tiles.unreadable-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Model invariants: item identifiers are unique; every catalog
    /// tile is in exactly one place (the grid, one folder or the list of
    /// unpinned tiles); `isPinned` is consistent with `unpinned`; no folder in the
    /// snapshot is empty.
    private func assertInvariants(
        _ store: TesseraTileStore,
        catalogIDs: [AnyHashable],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = store.snapshot()
        let itemIDs = snapshot.items.map { $0.id }
        XCTAssertEqual(Set(itemIDs).count, itemIDs.count, "duplicates on the grid", file: file, line: line)

        var places: [AnyHashable: Int] = [:]
        for item in snapshot.items {
            if let tile = item.tile { places[tile.id, default: 0] += 1 }
            for tile in item.folderTiles { places[tile.id, default: 0] += 1 }
        }
        for tile in snapshot.unpinned { places[tile.id, default: 0] += 1 }
        for id in catalogIDs {
            XCTAssertEqual(places[id], 1, "tile \(id) must be in exactly one place", file: file, line: line)
        }

        let unpinned = Set(snapshot.unpinned.map { $0.id })
        for id in catalogIDs {
            XCTAssertEqual(store.isPinned(id), !unpinned.contains(id), "isPinned(\(id))", file: file, line: line)
        }
        for folder in snapshot.folders {
            XCTAssertFalse(folder.tiles.isEmpty, "empty folder \(folder.id) on the grid", file: file, line: line)
        }
    }

    /// Saves a file with the folder [B, C] in B's place: order [A, folder, D].
    private func saveLayoutWithFolder(in directory: TesseraTestDirectory) throws -> AnyHashable {
        let store = makeStore(catalog(["a", "b", "c", "d"]), in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "b", title: "F", columns: 6))
        XCTAssertTrue(store.addToFolder("c", folderID: folder.id, columns: 6))
        try store.save()
        return folder.id
    }

    // MARK: - Dead folders

    /// All of a folder's tiles are gone from the catalog: after `setCatalog` → `load()`
    /// the folder is dissolved rather than remaining an empty tile.
    func testLoadDissolvesFolderWithoutCatalogTiles() throws {
        let directory = TesseraTestDirectory()
        _ = try saveLayoutWithFolder(in: directory)

        let store = makeStore(catalog(["a", "d"]), in: directory)
        try store.load()

        XCTAssertEqual(ids(store), ["a", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        assertInvariants(store, catalogIDs: ["a", "d"])
    }

    /// Some of a folder's tiles remain in the catalog. D45: one tile is left in the folder,
    /// so it is dissolved and tile "c" takes its place (previously the folder remained with
    /// a single tile).
    func testLoadPrunesUnknownTilesFromFolder() throws {
        let directory = TesseraTestDirectory()
        _ = try saveLayoutWithFolder(in: directory)

        let store = makeStore(catalog(["a", "c", "d"]), in: directory)
        try store.load()

        XCTAssertEqual(ids(store), ["a", "c", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        assertInvariants(store, catalogIDs: ["a", "c", "d"])
    }

    /// The call order does not affect folders: `load()` before `setCatalog` gives the same
    /// result.
    func testLoadBeforeCatalogGivesSameResult() throws {
        let directory = TesseraTestDirectory()
        _ = try saveLayoutWithFolder(in: directory)

        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try store.load()
        store.setCatalog(catalog(["a", "d"]))

        XCTAssertEqual(ids(store), ["a", "d"])
        XCTAssertTrue(store.snapshot().folders.isEmpty)
        assertInvariants(store, catalogIDs: ["a", "d"])
    }

    // MARK: - Orphan folders

    /// A folder is in `folders` but not in `items`: it goes to the end of the grid, and its
    /// tiles stay in it rather than "hanging" as unpinned ones that cannot be
    /// pinned.
    func testOrphanFolderIsAppendedToGrid() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let json = """
        {
          "version": 1,
          "items": [{"kind": "tile", "key": "s:a"}],
          "sizes": {},
          "folders": [
            {"key": "s:orphan", "title": "O", "size": "medium", "tileKeys": ["s:b", "s:c"]}
          ]
        }
        """
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try Data(json.utf8).write(to: store.fileURL)
        store.setCatalog(catalog(["a", "b", "c", "d"]))
        try store.load()

        XCTAssertEqual(ids(store), ["a", "orphan"])
        XCTAssertEqual(store.snapshot().folders.first?.tiles.map { $0.id }, ["b", "c"])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["d"])
        XCTAssertTrue(store.isPinned("b"))
        XCTAssertFalse(store.pinTile("b", columns: 6), "a tile from a folder cannot be pinned a second time")
        assertInvariants(store, catalogIDs: ["a", "b", "c", "d"])
    }

    /// Broken references in the file: a tile both on the grid and in a folder; a folder inside
    /// a folder; duplicates — the model is still consistent.
    func testLoadRepairsInconsistentFolderReferences() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let json = """
        {
          "version": 1,
          "items": [
            {"kind": "tile", "key": "s:a"},
            {"kind": "folder", "key": "s:f1"},
            {"kind": "tile", "key": "s:b"},
            {"kind": "tile", "key": "s:a"}
          ],
          "sizes": {},
          "folders": [
            {"key": "s:f1", "title": "F1", "size": "medium", "tileKeys": ["s:b", "s:f2", "s:c"]},
            {"key": "s:f2", "title": "F2", "size": "medium", "tileKeys": ["s:c", "s:d"]}
          ]
        }
        """
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        try Data(json.utf8).write(to: store.fileURL)
        store.setCatalog(catalog(["a", "b", "c", "d", "e"]))
        try store.load()

        // D45: after the duplicate is cleaned up, "f2" is left with a single tile "d" — the folder
        // is dissolved and "d" takes its place.
        XCTAssertEqual(ids(store), ["a", "f1", "d"])
        XCTAssertEqual(store.snapshot().folders.map { $0.tiles.map { $0.id } }, [["b", "c"]])
        XCTAssertEqual(store.snapshot().unpinned.map { $0.id }, ["e"])
        assertInvariants(store, catalogIDs: ["a", "b", "c", "d", "e"])
    }

    // MARK: - Unreadable file

    /// Corrupted JSON: `load()` throws, the file is set aside as a backup with
    /// the original bytes before any write, and autosave writes
    /// a new readable file.
    func testCorruptedFileIsBackedUpBeforeAutosave() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let original = Data("{ this is not JSON".utf8)
        let store = makeStore(catalog(["a", "b", "c"]), in: directory, autosaves: true)
        try original.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(ids(store), ["a", "b", "c"], "The app works with the current state")

        let backups = try backupFiles(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        XCTAssertTrue(store.unpin("b", columns: 6))
        XCTAssertNil(store.lastPersistenceError)
        let reloaded = makeStore(catalog(["a", "b", "c"]), in: directory)
        XCTAssertNoThrow(try reloaded.load())
        XCTAssertEqual(ids(reloaded), ["a", "c"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)
    }

    /// A file of a newer schema (current version + 1) is not overwritten with the v2 schema.
    func testNewerSchemaFileIsBackedUpBeforeAutosave() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        // The current schema is 2 (`TesseraTileStore.schemaVersion`); the file was written as version 3.
        let original = Data(#"{"version":3,"items":[],"sizes":{},"folders":[],"future":true}"#.utf8)
        let store = makeStore(catalog(["a", "b"]), in: directory, autosaves: true)
        try original.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case TesseraTileStoreError.unsupportedSchemaVersion(let version)? = error as? TesseraTileStoreError else {
                return XCTFail("Expected unsupportedSchemaVersion, got: \(error)")
            }
            XCTAssertEqual(version, 3)
        }

        let backups = try backupFiles(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), original)

        XCTAssertTrue(store.resize("a", to: .wide, columns: 6))
        let written = try Data(contentsOf: store.fileURL)
        XCTAssertNotEqual(written, original)
        let reloaded = makeStore(catalog(["a", "b"]), in: directory)
        XCTAssertNoThrow(try reloaded.load())
        XCTAssertEqual(reloaded.descriptor(withID: "a")?.size, .wide)
    }

    /// An existing backup is not overwritten: the new one gets
    /// a suffix; the name is `<name>.unreadable-<ISO date>.json`.
    func testBackupDoesNotOverwriteExistingCopy() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(catalog(["a"]), in: directory, autosaves: true)
        store.currentDate = { Date(timeIntervalSince1970: 1_793_361_600) } // 2026-10-30T12:00:00Z

        let existing = directory.url.appendingPathComponent("tiles.unreadable-2026-10-30T12-00-00Z.json")
        let older = Data("older backup".utf8)
        try older.write(to: existing)

        let original = Data("not json".utf8)
        try original.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())

        let backupURL = try XCTUnwrap(store.lastUnreadableFileBackupURL)
        XCTAssertEqual(backupURL.lastPathComponent, "tiles.unreadable-2026-10-30T12-00-00Z-2.json")
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertEqual(try Data(contentsOf: existing), older)
    }

    /// An I/O error is not "unreadable content": a missing
    /// file is a first launch, and no backup is created.
    func testMissingFileCreatesNoBackup() throws {
        let directory = TesseraTestDirectory()
        try directory.create()
        let store = makeStore(catalog(["a"]), in: directory)
        XCTAssertNoThrow(try store.load())
        XCTAssertNil(store.lastUnreadableFileBackupURL)
        XCTAssertTrue(try backupFiles(in: directory).isEmpty)
    }
}

#endif
