//
//  TestSupport.swift
//  TesseraStartScreenTests
//
//  Shared deterministic helpers for the start screen tests.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 "Tile grid"
//  (tests on random tile configurations), §5 "Edit mode"
//  (TesseraTileStore persistence), §14 "MVP refinements" (D12–D15).
//
//  All helpers are test-only: they do not touch the target's public API.
//  "Randomness" is always seeded, so a run is reproducible and not flaky.
//

#if canImport(UIKit)

import Foundation
import XCTest
@testable import TesseraStartScreen

// MARK: - Deterministic generator

/// A simple seeded generator for "random" layout configurations (§3).
///
/// It does not use `SystemRandomNumberGenerator`: a test must produce the same
/// configuration on every run. The implementation intentionally differs from the
/// production stagger generator `TesseraSeededGenerator`, so the layout
/// test does not depend on the Live engine's internals.
struct TesseraTestSeededGenerator {

    /// LCG state.
    private var state: UInt64

    /// Creates a generator.
    ///
    /// - Parameter seed: The seed; the same seed gives the same sequence.
    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    /// The next pseudo-random value.
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// A value in `0..<upperBound`.
    ///
    /// - Parameter upperBound: A positive bound.
    mutating func int(upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound must be positive")
        return Int((next() >> 33) % UInt64(upperBound))
    }
}

// MARK: - Temporary directory

/// A temporary directory for `TesseraTileStore` persistence tests.
///
/// The directory is removed in `deinit`: tests leave no garbage in the simulator
/// sandbox and do not depend on run order.
final class TesseraTestDirectory {

    /// The directory path.
    let url: URL

    /// Creates the directory description (the directory itself is created on demand).
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseraStartScreenTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates the directory on disk.
    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Tile model

/// A tile for tests: a stub action and configurable size/badge (D12/D15).
///
/// - Parameters:
///   - id: The tile identifier.
///   - size: The tile size, `.medium` by default (D12).
///   - badge: The attention badge, `.none` by default.
/// - Returns: A ready `TesseraTileDescriptor`.
func tesseraTestTile(
    _ id: String,
    size: TesseraTileSize = .medium,
    badge: TesseraTileBadge = .none
) -> TesseraTileDescriptor {
    TesseraTileDescriptor(
        id: id,
        title: id,
        action: {},
        badge: badge,
        size: size
    )
}

/// Identifiers of the snapshot items in display order.
///
/// - Parameter items: The grid items.
/// - Returns: The identifiers in the same order.
func tesseraTestIDs(_ items: [TesseraTileGridItem]) -> [AnyHashable] {
    items.map { $0.id }
}

/// A folder for tests: a title, the number of small tiles and a size (D17/D15).
///
/// - Parameters:
///   - id: The folder identifier.
///   - tileCount: The number of tiles in the folder.
///   - title: The label; the identifier by default.
///   - size: The folder size on the grid, `.medium` by default.
/// - Returns: The folder model.
func tesseraTestFolder(
    _ id: String,
    tileCount: Int = 4,
    title: String? = nil,
    size: TesseraTileSize = .medium
) -> TesseraTileFolder {
    TesseraTileFolder(
        id: id,
        title: title ?? id,
        tiles: (0..<tileCount).map { tesseraTestTile("\(id)-tile\($0)", size: .small) },
        size: size
    )
}

// MARK: - Live content

/// A live content provider for tests: the faces are set directly, with no subscription.
///
/// The protocol conformance uses its default implementations: the back is the one set
/// at creation, and no update subscription is needed (v1, §10).
final class TesseraTestLiveProvider: TesseraLiveTileContentProvider {

    /// The front content.
    var frontFace: TesseraLiveTileFace

    /// The back content; `nil` means no flips.
    var backFace: TesseraLiveTileFace?

    /// Creates a provider.
    ///
    /// - Parameters:
    ///   - frontFace: The front content.
    ///   - backFace: The back content; `nil` means a static tile.
    init(frontFace: TesseraLiveTileFace, backFace: TesseraLiveTileFace? = nil) {
        self.frontFace = frontFace
        self.backFace = backFace
    }
}

/// A live tile for tests: a provider with the given faces and a stub action.
///
/// - Parameters:
///   - id: The tile identifier.
///   - front: The front content.
///   - back: The back content; `nil` means no flips.
///   - badge: The attention badge.
///   - size: The tile size.
///   - action: The tile action (empty by default).
/// - Returns: A ready `TesseraTileDescriptor` with live content.
func tesseraTestLiveTile(
    _ id: String,
    front: TesseraLiveTileFace,
    back: TesseraLiveTileFace? = nil,
    badge: TesseraTileBadge = .none,
    size: TesseraTileSize = .medium,
    action: @escaping () -> Void = {}
) -> TesseraTileDescriptor {
    TesseraTileDescriptor(
        id: id,
        title: id,
        action: action,
        badge: badge,
        size: size,
        liveContent: TesseraTestLiveProvider(frontFace: front, backFace: back)
    )
}

// MARK: - Window with a grid

/// A grid in a real window for tests that need the folder panel animations and
/// real cells.
///
/// In a window, the panel-expansion `UIViewPropertyAnimator` and the UICollectionView
/// batch updates run for real, so tests wait for
/// the transition to finish by spinning the run loop (`waitForFolderTransition`) rather than with a
/// fixed delay. The window belongs to the host and is removed in `deinit`.
final class TesseraTestWindowedGrid {

    /// The default window size (the width class of iPhone 13/14/15/17).
    static let defaultSize = CGSize(width: 390, height: 844)

    /// The window the grid is embedded in.
    let window: UIWindow

    /// The grid under test.
    let grid: TesseraTileGridView

    /// Creates a window with a grid and applies the first snapshot.
    ///
    /// - Parameters:
    ///   - items: The snapshot items in display order.
    ///   - snapshot: A ready snapshot (for example, `TesseraTileStore.snapshot(columns:)` with
    ///     a cell table); used instead of `items` when set.
    ///   - columns: The grid column count.
    ///   - size: The window and grid size.
    init(
        items: [TesseraTileGridItem] = [],
        snapshot: TesseraTileGridSnapshot? = nil,
        columns: Int = 4,
        size: CGSize = TesseraTestWindowedGrid.defaultSize
    ) {
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.isHidden = false
        grid = TesseraTileGridView(frame: CGRect(origin: .zero, size: size))
        grid.columns = columns
        window.addSubview(grid)
        grid.reload(snapshot: snapshot ?? TesseraTileGridSnapshot(items: items, unpinned: []))
        layout()
    }

    deinit {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
    }

    /// The collection inside the grid.
    var collectionView: UICollectionView? {
        grid.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// Brings the grid and collection layout up to date: cells and frames are current.
    func layout() {
        grid.layoutIfNeeded()
        collectionView?.layoutIfNeeded()
    }

    /// Applies a snapshot without animation and brings the layout up to date.
    ///
    /// - Parameter items: The new snapshot items.
    func reload(_ items: [TesseraTileGridItem]) {
        grid.reload(snapshot: TesseraTileGridSnapshot(items: items, unpinned: []))
        layout()
    }

    /// Spins the run loop for the given time (waiting for timers, not animations).
    ///
    /// - Parameter seconds: The wait duration in seconds.
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits for a condition by spinning the run loop (without a fixed pause).
    ///
    /// - Parameters:
    ///   - timeout: The maximum wait in seconds.
    ///   - condition: The readiness condition.
    /// - Returns: `true` if the condition held before the timeout.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Waits for the folder panel animation to finish.
    ///
    /// - Parameter timeout: The maximum wait in seconds.
    /// - Returns: `true` if the transition finished before the timeout.
    @discardableResult
    func waitForFolderTransition(timeout: TimeInterval = 2) -> Bool {
        waitUntil(timeout: timeout) { !self.grid.isFolderChangeAnimating }
    }

    /// The visible cell of an item.
    ///
    /// - Parameter id: The tile or folder identifier.
    /// - Returns: The cell, or `nil` if the item is not on screen.
    func cell(_ id: AnyHashable) -> TesseraTileCell? {
        grid.cellView(forItemID: id) as? TesseraTileCell
    }

    /// The visible panel cell of the expanded folder.
    ///
    /// - Parameter folderID: The identifier of the expanded folder.
    /// - Returns: The panel, or `nil` if it is off screen.
    func panelCell(folderID: AnyHashable) -> TesseraFolderPanelCell? {
        guard let collectionView,
              let index = grid.displayItems.firstIndex(where: {
                  $0.isFolderPanel && $0.id == folderID
              }) else {
            return nil
        }
        return collectionView.cellForItem(
            at: IndexPath(item: index, section: 0)
        ) as? TesseraFolderPanelCell
    }

    /// The first subview of the given type in the hierarchy.
    ///
    /// - Parameters:
    ///   - type: The subview type.
    ///   - root: The search root; the grid by default.
    /// - Returns: The found view, or `nil`.
    func firstSubview<T: UIView>(of type: T.Type, in root: UIView? = nil) -> T? {
        func find(in view: UIView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews {
                if let match = find(in: subview) { return match }
            }
            return nil
        }
        return find(in: root ?? grid)
    }
}

// MARK: - Drag session rig

/// A rig layout item packed as before explicit cells (`TesseraTestDragHost(packed:)`).
enum TesseraTestPackedEntry {

    /// A top-level tile.
    case tile(String, TesseraTileSize)

    /// A top-level folder with content (sizes of the tiles inside).
    case folder(String, TesseraTileSize, [(String, TesseraTileSize)])

    /// The item identifier.
    var id: String {
        switch self {
        case let .tile(id, _), let .folder(id, _, _): return id
        }
    }

    /// The requested item size.
    var size: TesseraTileSize {
        switch self {
        case let .tile(_, size), let .folder(_, size, _): return size
        }
    }
}

/// A rig for windowed drag sessions: a window with a grid, a `TesseraTileStore` and a live
/// edit coordinator.
///
/// The grid is built from a store snapshot with a cell table
/// (`TesseraTileStore.snapshot(columns:)`), so the coordinator's "model
/// and snapshot are consistent" checks pass normally. The animations are real: completion
/// is awaited by spinning the run loop (`waitUntil`), with no fixed pauses.
final class TesseraTestDragHost {

    /// The store's temporary directory (removed in `deinit`).
    let directory: TesseraTestDirectory

    /// The model's only writer.
    let store: TesseraTileStore

    /// The window with the grid.
    let host: TesseraTestWindowedGrid

    /// The drag coordinator.
    let coordinator: TesseraTileEditCoordinator

    /// Creates the rig.
    ///
    /// - Parameters:
    ///   - descriptors: The tile catalog; order = pin order.
    ///   - columns: The grid column count.
    ///   - configuration: Edit parameters (jiggle, drag, folders).
    ///   - autosaves: Store autosave; off by default so that
    ///     tests do not write to disk.
    ///   - windowSize: The window and grid size (the screen width for geometry checks).
    ///   - prepare: Model preparation before the grid is built (for example, creating a
    ///     folder through `TesseraTileStore`); receives the store and the grid width for
    ///     cell-based operations. The layout before `prepare` is the packed
    ///     catalog (`placeItems`); operations work by cells: holes stay.
    convenience init(
        descriptors: [TesseraTileDescriptor],
        columns: Int = 4,
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(),
        autosaves: Bool = false,
        windowSize: CGSize = TesseraTestWindowedGrid.defaultSize,
        prepare: ((TesseraTileStore, Int) -> Void)? = nil
    ) {
        let directory = TesseraTestDirectory()
        try? directory.create()
        let store = TesseraTileStore(directoryURL: directory.url)
        store.autosaves = autosaves
        store.setCatalog(descriptors)
        store.placeItems(columns: columns)
        prepare?(store, columns)
        self.init(
            directory: directory,
            store: store,
            columns: columns,
            configuration: configuration,
            windowSize: windowSize
        )
    }

    /// Creates a rig with an exact cell layout: a version 2 schema file
    /// with holes (`TileStoreCellFixture`) is loaded into `TesseraTileStore`, and the grid
    /// is built from `snapshot(columns:)`.
    ///
    /// - Parameters:
    ///   - tiles: Top-level tiles with cells.
    ///   - folders: Top-level folders with content.
    ///   - unpinned: Catalog tiles outside the grid.
    ///   - columns: The grid column count (and the file's canvas width).
    ///   - configuration: Edit parameters.
    convenience init(
        cells tiles: [CellFixtureTile],
        folders: [CellFixtureFolder] = [],
        unpinned: [(String, TesseraTileSize)] = [],
        columns: Int = 4,
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0,
            reorderPreviewDwell: 0
        )
    ) throws {
        let directory = TesseraTestDirectory()
        let store = try TileStoreCellFixture.makeStore(
            columns: columns,
            tiles: tiles,
            folders: folders,
            unpinned: unpinned,
            in: directory,
            autosaves: false
        )
        self.init(directory: directory, store: store, columns: columns, configuration: configuration)
    }

    /// Creates a rig with a layout **packed as before explicit cells**: items in
    /// array order are packed by `TesseraTileLayoutEngine.packCompact` for `columns`,
    /// and the result is written as a version 2 file (`TileStoreCellFixture`), so
    /// the cells are exact and the model order is the reading order. For tests whose geometry
    /// was calculated for the compact layout that order-based operations used to
    /// produce.
    ///
    /// - Parameters:
    ///   - entries: Top-level tiles and folders in packing order.
    ///   - columns: The grid column count (and the file's canvas width).
    ///   - unpinned: Catalog tiles outside the grid.
    ///   - configuration: Edit parameters.
    convenience init(
        packed entries: [TesseraTestPackedEntry],
        columns: Int = 4,
        unpinned: [(String, TesseraTileSize)] = [],
        configuration: TesseraTileEditConfiguration = TesseraTileEditConfiguration(
            mergeHoverDuration: 0.05,
            magnetSnapRadius: 0,
            reorderPreviewDwell: 0
        )
    ) throws {
        let slots = TesseraTileLayoutEngine.packCompact(
            items: entries.map { (id: AnyHashable($0.id), size: $0.size) },
            columns: columns,
            unit: 1
        )
        var cellByID: [String: (row: Int, column: Int)] = [:]
        for slot in slots {
            if let id = slot.id.base as? String { cellByID[id] = (slot.row, slot.column) }
        }
        var tiles: [CellFixtureTile] = []
        var folders: [CellFixtureFolder] = []
        for entry in entries {
            let cell = cellByID[entry.id] ?? (0, 0)
            switch entry {
            case let .tile(id, size):
                tiles.append(CellFixtureTile(id, size, cell.row, cell.column))
            case let .folder(id, size, contents):
                folders.append(CellFixtureFolder(id, size, cell.row, cell.column, contents: contents))
            }
        }
        try self.init(
            cells: tiles,
            folders: folders,
            unpinned: unpinned,
            columns: columns,
            configuration: configuration
        )
    }

    /// Shared part: a window with a grid from a store snapshot and a live coordinator.
    private init(
        directory: TesseraTestDirectory,
        store: TesseraTileStore,
        columns: Int,
        configuration: TesseraTileEditConfiguration,
        windowSize: CGSize = TesseraTestWindowedGrid.defaultSize
    ) {
        self.directory = directory
        self.store = store
        // The host builds the grid from `snapshot(columns:)`, with a cell table.
        host = TesseraTestWindowedGrid(
            snapshot: store.snapshot(columns: columns),
            columns: columns,
            size: windowSize
        )
        host.layout()
        coordinator = TesseraTileEditCoordinator(
            grid: host.grid,
            store: store,
            configuration: configuration
        )
        // Determinism: the tests exercise the animated branches without depending on
        // the run host's system Reduce Motion setting.
        host.grid.isReduceMotionEnabled = { false }
        coordinator.isReduceMotionEnabled = { false }
    }

    /// A point inside an item's frame in grid coordinates.
    ///
    /// - Parameters:
    ///   - id: The tile or folder identifier.
    ///   - fx: The fraction of the width: 0 is the left edge, 0.5 the center, 1 the right edge.
    ///   - fy: The fraction of the height.
    /// - Returns: The point, or `nil` if the item is not in the snapshot/layout.
    func point(_ id: AnyHashable, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> CGPoint? {
        guard let frame = host.grid.frame(forItemID: id) else { return nil }
        return CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
    }

    /// Starts an item drag: a long press at a point of its frame.
    ///
    /// The coordinator's built-in gesture does the same; the method calls the same
    /// entry point directly, so the test does not simulate touches.
    ///
    /// - Parameters:
    ///   - id: The item identifier.
    ///   - fx: The fraction of the width of the grab point.
    ///   - fy: The fraction of the height of the grab point.
    /// - Returns: `true` if the drag actually started.
    @discardableResult
    func startDrag(_ id: AnyHashable, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> Bool {
        guard let item = host.grid.items.first(where: { $0.id == id }),
              let point = point(id, fx: fx, fy: fy) else {
            return false
        }
        coordinator.handleLongPress(on: item, at: point)
        return coordinator.isDragging
    }

    /// Identifiers of the items in the order the user sees.
    var gridIDs: [AnyHashable] {
        host.grid.items.map { $0.id }
    }

    /// Identifiers of the items in model order.
    var storeIDs: [AnyHashable] {
        store.snapshot().items.map { $0.id }
    }

    /// Folders in grid order.
    var folders: [TesseraTileFolder] {
        store.snapshot().folders
    }

    /// The identifier of the first folder in the model.
    var firstFolderID: AnyHashable? {
        folders.first?.id
    }

    /// Spins the run loop until the condition holds.
    ///
    /// - Parameters:
    ///   - timeout: The maximum wait in seconds.
    ///   - condition: The readiness condition.
    /// - Returns: `true` if the condition held before the timeout.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        host.waitUntil(timeout: timeout, condition)
    }

    /// Spins the run loop for the given time (waiting for timers, not animations).
    ///
    /// - Parameter seconds: The duration in seconds.
    func spin(_ seconds: TimeInterval) {
        host.spin(seconds)
    }

    /// Waits for the cleanup of a cancelled drag (the cell is visible again).
    ///
    /// - Parameter id: The identifier of the dragged item.
    /// - Returns: `true` if the cleanup finished before the timeout.
    @discardableResult
    func waitForDragCleanup(_ id: AnyHashable, timeout: TimeInterval = 2) -> Bool {
        waitUntil(timeout: timeout) {
            (host.cell(id)?.contentView.alpha ?? 0) > 0
        }
    }

    /// Base layout cell geometry: a point inside the cell of a small
    /// tile `(row, column)` in grid coordinates, with a logical column.
    ///
    /// - Parameters:
    ///   - row: The row.
    ///   - column: The logical column (0 is the reading start).
    ///   - fx: The fraction of the cell width.
    ///   - fy: The fraction of the cell height.
    /// - Returns: The point, or `nil` if the geometry cannot be computed.
    func cellPoint(row: Int, column: Int, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> CGPoint? {
        guard let frame = host.grid.baseFrame(
            forCell: TesseraTileGridPlacement(row: row, column: column),
            size: .small
        ) else {
            return nil
        }
        return CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
    }

    /// The frame of a small tile cell `(row, column)` in grid coordinates.
    func cellFrame(row: Int, column: Int, size: TesseraTileSize = .small) -> CGRect? {
        host.grid.baseFrame(forCell: TesseraTileGridPlacement(row: row, column: column), size: size)
    }

    /// The cells the grid is currently showing (the grid snapshot's table).
    var gridCells: [AnyHashable: TesseraTileGridPlacement]? {
        host.grid.snapshot?.placementTable?.cells
    }
}

#endif
