//
//  TileEditTests.swift
//  TesseraStartScreenTests
//
//  Tests for edit mode.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §5 "Edit mode"
//  (resize: a cyclic size change small → wide → medium → large → small, D28,
//  dragging and drop target calculation) and §14 "MVP refinements" (D15: four
//  sizes).
//
//  The coordinator has no public "drop position" helper: the resize cycle is
//  `TesseraTileSize.cycleOrder`, the grid column count and `supportedSizesProvider`
//  (see `TileSizeCycleTests`), and the drop target is computed from the frames of
//  `TesseraTileGridView` (the private `isPointInDropCenter`). So the resize cycle
//  is checked through the real `TesseraTileEditCoordinator.cycleSize(of:)`
//  (without a window or a UI cycle), and the drop calculation through the public grid geometry
//  that the drag coordinator uses.
//

#if canImport(UIKit)

import UIKit
import XCTest
@testable import TesseraStartScreen

final class TileEditTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(
        _ descriptors: [TesseraTileDescriptor],
        in directory: TesseraTestDirectory
    ) -> TesseraTileStore {
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = false
        store.setCatalog(descriptors)
        return store
    }

    /// A grid laid out by hand: no window is needed, and the collection gets its bounds.
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

    // MARK: - Size model (D15)

    /// The size set is D15 (`allCases` is the "ascending" order); the order of the
    /// resize cycle is set separately and explicitly: small → wide → medium → large (D28).
    func testTileSizeCycleOrderMatchesD15() {
        XCTAssertEqual(TesseraTileSize.allCases, [.small, .medium, .wide, .large])
        XCTAssertEqual(TesseraTileSize.cycleOrder, [.small, .wide, .medium, .large])
        XCTAssertEqual(TesseraTileSize.small.unitSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(TesseraTileSize.medium.unitSize, CGSize(width: 2, height: 2))
        XCTAssertEqual(TesseraTileSize.wide.unitSize, CGSize(width: 4, height: 2))
        XCTAssertEqual(TesseraTileSize.large.unitSize, CGSize(width: 4, height: 4))
    }

    // MARK: - Resize cycle

    /// The coordinator goes through the full D28 cycle and returns to the original size,
    /// changing the authoritative size in `TesseraTileStore` (D15, §5).
    func testCycleSizeFollowsResizeOrder() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small)], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        XCTAssertEqual(editor.cycleSize(of: "a"), .wide)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)
        XCTAssertEqual(grid.items.first { $0.id == AnyHashable("a") }?.size, .wide)

        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)

        XCTAssertEqual(editor.cycleSize(of: "a"), .large)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .large)

        XCTAssertEqual(editor.cycleSize(of: "a"), .small)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .small)
        XCTAssertEqual(grid.items.first { $0.id == AnyHashable("a") }?.size, .small)
    }

    /// An unknown identifier does not change state.
    func testCycleSizeRejectsUnknownItem() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a")], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        XCTAssertNil(editor.cycleSize(of: "missing"))
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    /// In a narrow grid (3 columns) wide/large are unavailable: the cycle goes only between
    /// small and medium, since a tile must not stick out of the grid (§3).
    func testCycleSizeRespectsGridColumns() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small)], in: directory)
        let grid = makeGrid(store: store, columns: 3)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(editor.cycleSize(of: "a"), .small)
        XCTAssertEqual(editor.cycleSize(of: "a"), .medium)
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    /// The host can narrow the size set through `supportedSizesProvider`:
    /// the cycle follows it, and an empty array means "the default set".
    func testCycleSizeUsesSupportedSizesProvider() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .small)], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        editor.supportedSizesProvider = { _ in [.small, .large] }
        XCTAssertEqual(editor.cycleSize(of: "a"), .large)
        XCTAssertEqual(editor.cycleSize(of: "a"), .small)

        editor.supportedSizesProvider = { _ in [] }
        XCTAssertEqual(editor.cycleSize(of: "a"), .wide, "the default set, D28 order")
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .wide)
    }

    /// If exactly one size is available, there is nothing to change.
    func testCycleSizeReturnsNilForSingleSupportedSize() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a", size: .medium)], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(grid: grid, store: store)

        editor.supportedSizesProvider = { _ in [.medium] }
        XCTAssertNil(editor.cycleSize(of: "a"))
        XCTAssertEqual(store.descriptor(withID: "a")?.size, .medium)
    }

    // MARK: - Reduce Motion

    /// With Reduce Motion the jiggle is off, but edit mode works
    /// (§5, §9). The setting provider is injected; the jiggle is enabled explicitly
    /// by a parameter, otherwise `isJiggling` is false regardless of Reduce Motion.
    func testReduceMotionDisablesJiggle() {
        let directory = TesseraTestDirectory()
        let store = makeStore([tesseraTestTile("a")], in: directory)
        let grid = makeGrid(store: store)
        let editor = TesseraTileEditCoordinator(
            grid: grid,
            store: store,
            configuration: TesseraTileEditConfiguration(isJiggleEnabled: true)
        )

        editor.isReduceMotionEnabled = { true }
        editor.beginEditing()
        XCTAssertTrue(editor.isEditing)
        XCTAssertFalse(editor.isJiggling)

        editor.isReduceMotionEnabled = { false }
        XCTAssertTrue(editor.isJiggling)

        editor.endEditing()
        XCTAssertFalse(editor.isEditing)
        XCTAssertFalse(editor.isJiggling)
    }

    // MARK: - Drop geometry

    /// The drop target is found by the grid frames: a tile's center belongs to it, and a point in
    /// the gap between tiles does not. These are the same queries the
    /// drag coordinator uses (`item(under:excluding:)`, `frame(forItemID:)`).
    func testDropHitTestingUsesTileFrames() throws {
        let directory = TesseraTestDirectory()
        let store = makeStore(
            [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .medium),
                tesseraTestTile("c", size: .small),
            ],
            in: directory
        )
        let grid = makeGrid(store: store)

        let frame = try XCTUnwrap(grid.frame(forItemID: "b"))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(grid.item(at: center)?.id, AnyHashable("b"))

        // The gap right of "b": the outer gap between units belongs
        // to no tile.
        let gapPoint = CGPoint(
            x: frame.maxX + grid.itemSpacing / 2,
            y: frame.midY
        )
        XCTAssertNil(grid.item(at: gapPoint))

        XCTAssertNil(grid.frame(forItemID: "missing"))
        XCTAssertNil(grid.item(at: CGPoint(x: -1000, y: -1000)))
    }

    /// A move to a cell is the drop model: the column is clamped to the canvas, and the set of
    /// tiles is neither lost nor duplicated (§5, §6).
    func testDropReorderThroughStoreKeepsItemSet() {
        let directory = TesseraTestDirectory()
        let store = makeStore(
            [
                tesseraTestTile("a", size: .small),
                tesseraTestTile("b", size: .small),
                tesseraTestTile("c", size: .small),
            ],
            in: directory
        )

        let initial = Set(store.snapshot().items.map { $0.id })
        XCTAssertTrue(store.moveItem("a", toCell: tesseraCell(1, 3), columns: 4))
        XCTAssertEqual(Set(store.snapshot().items.map { $0.id }), initial)
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["b", "c", "a"])

        XCTAssertFalse(store.moveItem("a", toCell: tesseraCell(1, 99), columns: 4), "99 is clamped to column 3: already there")
        XCTAssertEqual(store.snapshot().items.map { $0.id }, ["b", "c", "a"])
        XCTAssertEqual(Set(store.snapshot().items.map { $0.id }), initial)
    }
}

#endif
