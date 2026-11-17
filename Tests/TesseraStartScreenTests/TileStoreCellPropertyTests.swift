//
//  TileStoreCellPropertyTests.swift
//  TesseraStartScreenTests
//
//  Property test of `TesseraTileStore` cell operations: random
//  operation sequences (seeded, reproducible), with the model invariants
//  checked after each one.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 and "Implementation
//  deviations"; decisions D30–D33 in docs/STATE.md.
//
//  Invariants after every operation: no overlaps, everything inside
//  `[0, columns)`, every visible item has exactly one cell, tiles
//  are preserved (on the grid, in a folder or among the unpinned — exactly once), folders
//  hold at least two tiles (D45: take-out, unpin and moving between
//  folders dissolve a folder left with one tile; the sequences do not
//  call the transitional `createFolder(withTile:)`), folder contents ⊂ catalog,
//  model order equals the reading order of the cells.
//  The host width changes during the sequence (D32).
//

#if canImport(UIKit)

import XCTest
@testable import TesseraStartScreen

final class TileStoreCellPropertyTests: XCTestCase {

    private static let sizes: [TesseraTileSize] = [.small, .medium, .wide, .large]
    private static let widths = [3, 4, 6]

    /// Random sequences of cell operations.
    func testRandomOperationSequencesKeepInvariants() throws {
        var successes: [String: Int] = [:]
        for seed in 1...16 {
            try runSequence(seed: UInt64(seed), steps: 70, successes: &successes)
        }
        // Coverage: every operation actually succeeded at least once (not only failed).
        for name in [
            "moveItem", "moveItemToNewRow", "resize", "createFolder", "addToFolder",
            "extract", "extractNewRow", "moveBetweenFolders", "unpin", "pinTile", "collapseEmptyRows",
            "folderDissolved",
        ] {
            XCTAssertGreaterThan(successes[name] ?? 0, 0, "operation \(name) never succeeded: \(successes)")
        }
    }

    private func runSequence(seed: UInt64, steps: Int, successes: inout [String: Int]) throws {
        var rng = TesseraTestSeededGenerator(seed: seed)
        let directory = TesseraTestDirectory()
        let ids = (0..<14).map { "t\($0)" }
        let catalog = ids.map { tesseraTestTile($0, size: TileStoreCellPropertyTests.sizes[rng.int(upperBound: 4)]) }

        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(catalog)
        var columns = TileStoreCellPropertyTests.widths[rng.int(upperBound: 3)]
        store.placeItems(columns: columns)

        for step in 0..<steps {
            if rng.int(upperBound: 10) == 0 {
                columns = TileStoreCellPropertyTests.widths[rng.int(upperBound: 3)]
            }
            let snapshot = store.snapshot()
            let topTiles = snapshot.items.compactMap { $0.tile?.id.base as? String }
            let folders = snapshot.folders
            let folderTiles = folders.flatMap { $0.tiles.map { $0.id.base as? String ?? "" } }
            let unpinned = snapshot.unpinned.map { $0.id.base as? String ?? "" }
            let topIDs = snapshot.items.map { $0.id }
            let pinnedCount = topTiles.count + folderTiles.count

            func pick<T>(_ list: [T]) -> T? {
                list.isEmpty ? nil : list[rng.int(upperBound: list.count)]
            }
            let cell = tesseraCell(rng.int(upperBound: 10), rng.int(upperBound: columns + 2))
            let op = rng.int(upperBound: 12)

            let before = store.placements(forColumns: columns)
            var ok: Bool?
            var name = "op\(op)"

            switch op {
            case 0:
                if let id = pick(topIDs) { ok = store.moveItem(id, toCell: cell, columns: columns); name = "moveItem" }
            case 1:
                if let id = pick(topIDs) { ok = store.moveItemToNewRow(id, columns: columns); name = "moveItemToNewRow" }
            case 2:
                let candidates: [AnyHashable] = topIDs + folderTiles.map { AnyHashable($0) }
                if let id = pick(candidates) {
                    ok = store.resize(id, to: TileStoreCellPropertyTests.sizes[rng.int(upperBound: 4)], columns: columns)
                    name = "resize"
                }
            case 3:
                if topTiles.count >= 2, let source = pick(topTiles) {
                    let target = pick(topTiles.filter { $0 != source })!
                    if case .created = store.createFolder(from: source, onto: target, columns: columns) { ok = true } else { ok = false }
                    name = "createFolder"
                }
            case 4:
                if let tile = pick(topTiles), let folder = pick(folders) {
                    ok = store.addToFolder(tile, folderID: folder.id, columns: columns)
                    name = "addToFolder"
                }
            case 5:
                if let tile = pick(folderTiles) { ok = store.extractFromFolder(tile, toCell: cell, columns: columns); name = "extract" }
            case 6:
                if let tile = pick(folderTiles) { ok = store.extractFromFolderToNewRow(tile, columns: columns); name = "extractNewRow" }
            case 7:
                if let tile = pick(folderTiles), let folder = pick(folders) {
                    ok = store.moveBetweenFolders(tile, to: folder.id, columns: columns)
                    name = "moveBetweenFolders"
                }
            case 8:
                if pinnedCount > 4, let tile = pick(topTiles + folderTiles) { ok = store.unpin(tile, columns: columns); name = "unpin" }
            case 9:
                if let tile = pick(unpinned) { ok = store.pinTile(tile, columns: columns); name = "pinTile" }
            case 10:
                ok = store.collapseEmptyRows(columns: columns)
                name = "collapseEmptyRows"
                if ok == true {
                    XCTAssertFalse(store.collapseEmptyRows(columns: columns), "seed \(seed) step \(step): idempotence")
                }
            default:
                ok = store.moveItem("no-such-item", toCell: cell, columns: columns)
                XCTAssertEqual(ok, false)
                name = "invalid"
            }

            if ok == true { successes[name, default: 0] += 1 }
            // D45: an operation that removed a tile from a folder dissolved it (the folder is gone,
            // and all its tiles are still pinned).
            if ok == true, ["extract", "extractNewRow", "moveBetweenFolders", "unpin"].contains(name),
               Set(folders.map { $0.id }).subtracting(store.snapshot().folders.map { $0.id }).isEmpty == false {
                successes["folderDissolved", default: 0] += 1
            }
            XCTContext.runActivity(named: "seed \(seed) step \(step) \(name) columns \(columns) ok \(String(describing: ok))") { _ in
                tesseraAssertCellInvariants(store, columns: columns, catalogIDs: ids, checkOrder: ok == true)
                if ok != true {
                    XCTAssertEqual(store.placements(forColumns: columns), before, "a failed operation changes nothing")
                }
            }
        }

        // Write round trip: the canvas of the last successful width survives saving.
        try store.save()
        let fresh = TesseraTileStore(directoryURL: directory.url)
        fresh.setCatalog(catalog)
        try fresh.load()
        if let canvas = store.canvasColumns {
            XCTAssertEqual(fresh.canvasColumns, canvas, "seed \(seed)")
            XCTAssertEqual(fresh.placements, store.placements, "seed \(seed)")
            XCTAssertEqual(fresh.snapshot().items.map { $0.id }, store.snapshot().items.map { $0.id }, "seed \(seed)")
            tesseraAssertCellInvariants(fresh, columns: canvas, catalogIDs: ids)
        }
    }
}

#endif
