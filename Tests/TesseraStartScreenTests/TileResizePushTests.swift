//
//  TileResizePushTests.swift
//  TesseraStartScreenTests
//
//  Tests for resize push-down.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid" and
//  §5 "Edit mode" (resize triggers an animated repack),
//  §14 "MVP refinements" (D15: four sizes: 1×1, 2×2, 4×2, 4×4).
//
//  Windows Phone behavior: when a tile grows, the free space on its right is checked; if
//  there is none or other tiles are there, they are pushed down, freeing room
//  for the new size. The size cycle stays four-way
//  (small → medium → wide → large → small).
//
//  Checked:
//  - integration into `TesseraTileStore.resize(_:to:columns:)` and into the resize cycle
//    of the coordinator (`TesseraTileEditCoordinator.cycleSize(of:)`);
//  - invariants: the set of items is neither lost nor duplicated, and the four-size
//    cycle is not broken.
//
//  The pure function `TesseraTileLayoutEngine.resizePlacement` (order-based) was removed
//  together with its tests: pushing down on growth and a hole on shrink are
//  checked on placements in `TileLayoutEnginePlacementTests`,
//  `TileLayoutEnginePlacementPropertyTests` (the engine) and `TileStoreCellOperationsTests`
//  (the store).
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileResizePushTests: XCTestCase {

    // MARK: - Helpers

    /// Item identifiers in array order.
    private func ids(_ items: [TesseraTileGridItem]) -> [AnyHashable] {
        items.map { $0.id }
    }

    /// Compact packing slots by identifier: the same geometry the grid layout
    /// sees.
    private func slots(
        _ items: [TesseraTileGridItem],
        columns: Int = 4
    ) -> [AnyHashable: TesseraTileLayoutSlot] {
        let pairs: [(id: AnyHashable, size: TesseraTileSize)] = items.map {
            (id: $0.id, size: $0.size)
        }
        var result: [AnyHashable: TesseraTileLayoutSlot] = [:]
        for slot in TesseraTileLayoutEngine.pack(items: pairs, columns: columns, unit: 1) {
            result[slot.id] = slot
        }
        return result
    }

    private func makeStore(
        _ descriptors: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        store.placeItems(columns: 4)
        return store
    }

    /// A grid laid out without a window: the collection gets its bounds.
    private func makeGrid(store: TesseraTileStore, columns: Int = 4) -> TesseraTileGridView {
        let grid = TesseraTileGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        grid.columns = columns
        grid.reload(snapshot: store.snapshot())
        grid.layoutIfNeeded()
        grid.subviews
            .compactMap { $0 as? UICollectionView }
            .forEach { $0.layoutIfNeeded() }
        return grid
    }

    /// The size of the item with the identifier in the order.
    private func size(
        of id: AnyHashable,
        in items: [TesseraTileGridItem]
    ) -> TesseraTileSize? {
        items.first { $0.id == id }?.size
    }

    // MARK: - Integration into TesseraTileStore

    /// `TesseraTileStore.resize(_:to:columns:)` changes the size and the order in one
    /// operation: the conflicting tile goes down, the snapshot immediately gives the new
    /// order, and a repeat is a no-op.
    func testStoreResizeAppliesPushOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)

        XCTAssertEqual(ids(store.snapshot().items), ["a", "b", "c"])
        XCTAssertTrue(store.resize("a", to: .wide, columns: 4))

        let snapshot = store.snapshot()
        XCTAssertEqual(ids(snapshot.items), ["a", "c", "b"])
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)

        let after = slots(snapshot.items)
        XCTAssertEqual(after[AnyHashable("a")]?.row, 0)
        XCTAssertEqual(after[AnyHashable("a")]?.unitColumns, 4)
        XCTAssertEqual(after[AnyHashable("b")]?.row, 2)

        XCTAssertFalse(
            store.resize("a", to: .wide, columns: 4),
            "A repeated resize to the same size is a no-op"
        )
        XCTAssertEqual(ids(store.snapshot().items), ["a", "c", "b"])
    }

    /// Resizing a folder follows the same push semantics; a tile inside a folder changes
    /// only its size and does not touch the grid order.
    func testStoreResizeFolderPushesConflictsAndKeepsLayoutOrder() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)
        let folder = try XCTUnwrap(store.createFolder(withTile: "a", title: "A", columns: 4))
        XCTAssertEqual(ids(store.snapshot().items), [folder.id, "b", "c"])

        XCTAssertTrue(store.resize(folder.id, to: .wide, columns: 4))
        XCTAssertEqual(ids(store.snapshot().items), [folder.id, "c", "b"])
        XCTAssertEqual(store.snapshot().folders.first?.size, .wide)

        // A tile inside a folder is not on the grid: there is nothing to reorder.
        XCTAssertTrue(store.resize("a", to: .large, columns: 4))
        XCTAssertEqual(ids(store.snapshot().items), [folder.id, "c", "b"])
        XCTAssertEqual(
            store.folderContaining("a")?.tiles.first?.size,
            .large
        )
    }

    // MARK: - Coordinator size cycle

    /// The cycle small → medium → wide → large → small is not broken: the coordinator
    /// passes the grid column count, the order is rearranged with push semantics,
    /// and the set of items is preserved at every step.
    func testCycleSizeKeepsFourSizeCycleWithPush() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)
        let allIDs = Set<AnyHashable>(["a", "b", "c"])

        // D28: the full D15 cycle in Windows 10 Mobile order: medium → large → small →
        // wide → medium; the set of items is preserved at every step.
        for expected in [TesseraTileSize.large, .small, .wide, .medium] {
            XCTAssertEqual(editor.cycleSize(of: "a"), expected)
            XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs, "after \(expected)")
            XCTAssertEqual(Set(ids(grid.items)), allIDs, "grid after \(expected)")
        }
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
        XCTAssertEqual(Set(ids(store.snapshot().items)), allIDs)
        XCTAssertEqual(size(of: AnyHashable("b"), in: grid.items), .medium)
        XCTAssertEqual(size(of: AnyHashable("c"), in: grid.items), .small)
    }

    /// Growth 2×2 → 4×2 pushes the neighbor down (the former medium → wide step check:
    /// in the D28 cycle the next size after medium is large, so the set is narrowed to medium/wide).
    func testCycleSizeMediumToWidePushesRightNeighborDown() {
        let directory = TesseraTestDirectory()
        let store = makeStore([
            tesseraTestTile("a", size: .medium),
            tesseraTestTile("b", size: .medium),
            tesseraTestTile("c", size: .small),
        ], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)
        editor.supportedSizesProvider = { _ in [.medium, .wide] }

        // medium → wide: b on the right conflicts and goes down.
        XCTAssertEqual(editor.cycleSize(of: "a"), .wide)
        XCTAssertEqual(ids(store.snapshot().items), ["a", "c", "b"])
        XCTAssertEqual(ids(grid.items), ["a", "c", "b"])
    }
}

#endif
