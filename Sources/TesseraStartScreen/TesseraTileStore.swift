// The start screen state store: order, sizes, folders and pins.
//
// Design document: docs/STARTSCREEN-IOS-DESIGN.md
//  - §3 (the tile grid): the unit layout is computed by TesseraTileLayoutEngine (pure functions, the
//    file TesseraTileLayoutEngine.swift); item order, sizes, pins and folders are the job of
//    TesseraTileStore;
//  - §5 (edit mode): "TesseraTileStore keeps order/sizes/pins (JSON/file) and survives between
//    launches";
//  - §6 (the right page): TesseraTileStore is the single source of truth for both the grid and the
//    app list (two-way pin/unpin, the "single writer" rule);
//  - §14 (MVP clarifications) and D12–D15 in docs/DECISIONS.md: a shortcut is just an action (no type
//    field), folders are created/changed only through the host approval function, shortcuts have
//    four sizes.
//
// The shortcut and folder models are `TesseraTileDescriptor.swift` / `TesseraTileFolder.swift`: the
// store does not duplicate them but builds state on top of the shortcut catalog.
//
// Threading: all methods are meant for the main thread, so that the start screen state is not
// smeared across modules (docs/CORE-IOS-DESIGN.md §3). Disk writes are synchronous and the JSON is
// small: that is cheaper than a queue and file races.

#if canImport(UIKit)
import Combine
import Foundation
import UIKit

// MARK: - Grid snapshot

/// A start screen grid item: a shortcut, a folder or an expanded folder panel.
///
/// A snapshot returns items in display order. A shortcut comes with its current size and caption,
/// and a folder with its shortcuts, so that the grid and the folder screen are drawn from one
/// snapshot and do not hit the store for every item.
///
/// ``folderContent(_:)`` is not a data item but the expansion UI state (D17): `TesseraTileStore` and
/// the state file do not contain it, and the view layer **inserts** it as a separate item right
/// after the folder tile. The folder tile stays in the set and on screen: the panel is a full-width
/// row under it. It lives in this same enumeration so that the layout
/// (`TesseraTileLayoutEngine`/`TesseraTileCollectionViewLayout`) sees the expanded panel in the
/// common item order.
public enum TesseraTileGridItem {

    /// A shortcut with its current size from the store.
    case tile(TesseraTileDescriptor)

    /// A folder together with its shortcuts (in folder order).
    case folder(TesseraTileFolder)

    /// The full-width panel of an expanded folder (D17).
    ///
    /// The panel shows the folder title and a grid of its content. In the item set the view layer
    /// **inserts** it right after the folder tile: the tile stays visible, the item count grows by
    /// one, and the panel takes a full-width row right after the row in which the folder ends
    /// (``folderContent(_:)`` stretches over the full width). The panel is not data: it is the
    /// representation of the "folder is expanded" state, so it does not appear in a
    /// `TesseraTileStore` snapshot and is not persisted between launches. The panel identifier equals
    /// the folder identifier; the layout uses it to find the folder row after which the panel stands.
    case folderContent(TesseraTileFolder)

    /// The item identifier (of a shortcut, a folder or a folder panel).
    public var id: AnyHashable {
        switch self {
        case .tile(let descriptor): return descriptor.id
        case .folder(let folder): return folder.id
        case .folderContent(let folder): return folder.id
        }
    }

    /// The current item size in units (D15).
    ///
    /// An expanded folder panel has no size of its own in units: it always takes the full grid width,
    /// and its height is computed by ``TesseraTileLayoutEngine/panelHeight(for:width:columns:)``. For
    /// uniformity it returns ``TesseraTileSize/wide``, the nearest "full-width" D15 size. The layout
    /// does not pack the panel by this mark: the panel is a separate row under the folder
    /// (``panelFolder``), not a tile.
    public var size: TesseraTileSize {
        switch self {
        case .tile(let descriptor): return descriptor.size
        case .folder(let folder): return folder.size
        case .folderContent: return .wide
        }
    }

    /// The shortcut, if the item is a shortcut.
    public var tile: TesseraTileDescriptor? {
        guard case .tile(let descriptor) = self else { return nil }
        return descriptor
    }

    /// The folder, if the item is a folder tile.
    ///
    /// The expanded folder panel (``folderContent(_:)``) is not included here: it is not a data
    /// item, and its folder is available through ``panelFolder``. This way
    /// ``TesseraTileGridSnapshot/folders`` and snapshot traversals do not count one folder twice when
    /// the view layer adds a panel to the item set.
    public var folder: TesseraTileFolder? {
        guard case .folder(let folder) = self else { return nil }
        return folder
    }

    /// The folder, if the item is an expanded folder panel.
    public var panelFolder: TesseraTileFolder? {
        guard case .folderContent(let folder) = self else { return nil }
        return folder
    }

    /// Whether the item is the full-width panel of an expanded folder (D17).
    public var isFolderPanel: Bool {
        if case .folderContent = self { return true }
        return false
    }

    /// The folder's shortcuts, if the item is a folder tile.
    ///
    /// For an expanded folder panel the content comes from ``panelFolder``: the panel is a
    /// representation, not a second instance of the folder.
    public var folderTiles: [TesseraTileDescriptor] {
        guard case .folder(let folder) = self else { return [] }
        return folder.tiles
    }
}

/// A start screen grid snapshot: what the UI and the layout read.
///
/// A snapshot is a value: it is not tied to the store and does not change retroactively. It has no
/// pixel geometry: the layout is computed by `TesseraTileLayoutEngine` (§3), and the snapshot gives
/// order, sizes and folders. ``layoutItems`` is a ready input for
/// `TesseraTileLayoutEngine.pack(items:columns:unit:)`.
public struct TesseraTileGridSnapshot {

    /// The grid items in display order: left to right, top to bottom.
    public let items: [TesseraTileGridItem]

    /// Shortcuts off the grid: they can be pinned; the app list is built from them too (§6, two-way
    /// pin/unpin).
    public let unpinned: [TesseraTileDescriptor]

    /// An optional table of explicit cells (D30).
    ///
    /// The "side" input of the layout: while there is no table, the grid lays items out by packing
    /// in ``items`` order (strictly compactly, as before). If it is present, complete and valid for
    /// the grid's current column count, tiles stand on their cells and holes remain. An incomplete,
    /// invalid table, or one computed for another width, is ignored entirely; see
    /// ``TesseraTileGridPlacementTable``. `TesseraTileStore.snapshot()` does not attach a table (it
    /// does not know the grid width); a snapshot with a table for a specific width is built by
    /// ``TesseraTileStore/snapshot(columns:)``.
    public let placementTable: TesseraTileGridPlacementTable?

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - items: The grid items in display order.
    ///   - unpinned: Shortcuts off the grid.
    ///   - placementTable: The explicit cell table; `nil` means order-based layout.
    init(
        items: [TesseraTileGridItem],
        unpinned: [TesseraTileDescriptor],
        placementTable: TesseraTileGridPlacementTable? = nil
    ) {
        self.items = items
        self.unpinned = unpinned
        self.placementTable = placementTable
    }

    /// "Identifier - size" pairs in grid order for `TesseraTileLayoutEngine`.
    ///
    /// The store does not compute the layout itself (§3): it hands out data, and the engine packs it
    /// into unit coordinates.
    ///
    /// The expanded folder panel (``TesseraTileGridItem/folderContent(_:)``) is not included in the
    /// pairs: it has no unit size, and its row and height are computed by the layout by the folder
    /// identifier. A `TesseraTileStore` snapshot has no panel, but the view layer may add it to the
    /// item set; the filter makes `layoutItems` safe for such a set too.
    public var layoutItems: [(id: AnyHashable, size: TesseraTileSize)] {
        items.compactMap { item in
            guard !item.isFolderPanel else { return nil }
            return (id: item.id, size: item.size)
        }
    }

    /// All folders in grid order.
    ///
    /// The expanded folder panel is not counted: the folder is already in the snapshot as a folder
    /// tile, and the panel is its representation (D17).
    public var folders: [TesseraTileFolder] {
        items.compactMap { $0.folder }
    }

    /// Whether the grid is empty.
    public var isEmpty: Bool {
        items.isEmpty
    }

    /// An item by identifier.
    ///
    /// - Parameter id: The shortcut or folder identifier.
    /// - Returns: The grid item, or `nil` if it is not on the grid.
    public func item(withID id: AnyHashable) -> TesseraTileGridItem? {
        items.first { $0.id == id }
    }
}

// MARK: - Folder operation approval (D14)

/// A grouping operation that TesseraTileStore asks the host about (D14).
///
/// The order matters for UI hints: `createFolder` is "make a folder", `addToFolder` is "put a
/// shortcut into an existing folder", `moveBetweenFolders` is "move a shortcut to another folder or
/// back to the start screen".
public enum TesseraTileGroupingAction: Equatable {

    /// Creating a folder from a shortcut.
    case createFolder

    /// Adding a shortcut from the grid to a folder.
    case addToFolder

    /// Moving a shortcut between folders (or from a folder to the start screen).
    case moveBetweenFolders
}

/// The folder operation approval function (D14).
///
/// The host decides whether an operation is allowed; everything is allowed by default
/// (`TesseraTileStore.approval` is allow-all). It is called synchronously on the main thread before
/// the state changes, so the function must be fast and must not touch `TesseraTileStore` itself
/// (otherwise notifications would recurse).
///
/// - Parameters:
///   - folder: The target folder; `nil` for `createFolder` and for moving to the start screen.
///   - tile: The shortcut the operation is performed with.
///   - action: The operation type.
/// - Returns: `true` to perform the operation, `false` to deny it without changing state.
public typealias TesseraTileGroupingApproval = (_ folder: TesseraTileFolder?, _ tile: TesseraTileDescriptor, _ action: TesseraTileGroupingAction) -> Bool

// MARK: - Persistence errors

/// Errors of working with the saved state.
public enum TesseraTileStoreError: Error, CustomStringConvertible {

    /// The file was written by a newer schema version: it cannot be read.
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "TesseraTileStore: unsupported schema version \(version)"
        }
    }
}

// MARK: - Store

/// The single source of truth for order, sizes, folders and pins (§5, §6; D12–D15).
///
/// The store keeps a catalog of known shortcuts (actions are closures and are not serialized) and,
/// separately, the layout: grid item order, sizes and folders. The grid and the app list only read
/// the snapshot and call edit operations, so the "single writer" rule (§6) holds: only
/// TesseraTileStore writes.
///
/// Usage:
///
/// ```swift
/// let store = TesseraTileStore()                        // Application Support/TesseraStartScreen
/// store.approval = { folder, tile, action in true }   // the default is allow (D14)
/// store.setCatalog(descriptors)                  // the app's shortcuts with actions
/// try? store.load()                              // restore the layout
/// store.pinTile("weather", columns: 6)           // pin: the shortcut goes into a new row
/// store.resize("weather", to: .wide, columns: 6) // D15: 1×1 / 2×2 / 4×2 / 4×4
/// ```
///
/// Sizes. `TesseraTileDescriptor` carries a default size (D15, §3), but the authoritative size is
/// kept by TesseraTileStore: in a snapshot, shortcuts arrive with their current size, and a size
/// change is a store operation (§5, resize in edit mode).
///
/// Identifiers. `TesseraTileDescriptor.id` and `TesseraTileFolder.id` are `AnyHashable`. They go
/// into the file in a canonical form (`s:` for String, `i:` for Int, `u:` for UUID, `o:` for
/// anything else through `String(describing:)`), so the layout does not depend on the identifier
/// type. Hashable types without a stable `description` are not supported in persistence.
///
/// - Note: All methods and callbacks are called on the main thread.
public final class TesseraTileStore: ObservableObject {

    // MARK: - Public settings

    /// Change publication for the SwiftUI facade (iOS 15: `ObservableObject` only).
    ///
    /// In addition to it there is ``onChange``, which is more convenient for a UIKit coordinator that
    /// needs a ready snapshot rather than the fact of a change.
    public let objectWillChange = ObservableObjectPublisher()

    /// A callback after every state change: it receives a ready snapshot.
    ///
    /// Called on the main thread, after saving (if ``autosaves`` is on). The store is not modified in
    /// the callback, only read.
    public var onChange: ((TesseraTileGridSnapshot) -> Void)?

    /// The folder operation approval function (D14).
    ///
    /// Everything is allowed by default; the host may forbid individual operations. It is checked
    /// before the state changes in folder operations:
    /// `createFolder(from:onto:title:columns:)`, ``addToFolder(_:folderID:columns:)``,
    /// ``moveBetweenFolders(_:to:columns:)`` and ``extractFromFolder(_:toCell:columns:)``.
    public var approval: TesseraTileGroupingApproval = { _, _, _ in true }

    /// Autosave after every edit operation (on by default).
    ///
    /// Write errors do not interrupt the operation: they go to ``lastPersistenceError``, because
    /// losing persistence must not break the UI. Use ``save()`` for explicit handling.
    public var autosaves: Bool = true

    /// The last save/load error, for diagnostics.
    public private(set) var lastPersistenceError: Error?

    /// A backup of an unreadable state file set aside by the last ``load()``, for diagnostics and
    /// manual recovery.
    ///
    /// If the file does not decode or was written by a newer schema, `load()` renames it to
    /// `<name>.unreadable-<ISO date>.json` next to the original, so that the first autosave does not
    /// overwrite the data with the current version's schema. `nil` means no unreadable files were
    /// encountered.
    public private(set) var lastUnreadableFileBackupURL: URL?

    /// The canvas width the saved cells were computed for (D32).
    ///
    /// `nil` means there are no cells yet: a version 1 file or the first launch, the host grid width
    /// is not known yet. As soon as the host reports a width (``placeItems(columns:)`` or any
    /// operation with `columns`), cells are assigned by a one-time `TesseraTileLayoutEngine.packCompact`
    /// pass over the current order and saved right away. If the host width differs from
    /// `canvasColumns`, the file is not overwritten: the host gets the ``placements(forColumns:)``
    /// projection.
    public private(set) var canvasColumns: Int?

    /// The directory that holds the JSON state file.
    public let directoryURL: URL

    /// The path of the JSON state file.
    public let fileURL: URL

    // MARK: - Internal state

    /// The shortcut catalog in registration order (actions, icons, badges).
    private var catalog: [TesseraTileDescriptor] = []

    /// The catalog index by the canonical identifier key.
    private var catalogIndex: [String: Int] = [:]

    /// The grid item order: canonical keys of shortcuts and folders.
    ///
    /// A shortcut that lives in a folder does not occur in this array (the "one shortcut, one place"
    /// invariant).
    private var gridOrder: [String] = []

    /// The authoritative shortcut sizes by canonical key.
    ///
    /// A folder keeps its size in ``FolderRecord/size``.
    private var sizes: [String: TesseraTileSize] = [:]

    /// Folders in grid order (in `gridOrder` they stand under their keys).
    private var folderRecords: [FolderRecord] = []

    /// Whether the state file has been read: after that, new catalog shortcuts are not pinned
    /// automatically (otherwise shortcuts "unpinned" by the user would return on every launch).
    private var restoredFromDisk = false

    /// Whether the host registered a catalog (``setCatalog(_:)``): only then does ``load()`` prune
    /// folders against the catalog. Before a catalog is registered every shortcut is "unknown", and
    /// pruning would delete all folder contents.
    private var catalogRegistered = false

    /// An unreadable state file could not be set aside as a backup: ``save()`` retries before
    /// writing and does not overwrite the file.
    private var unreadableFilePending = false

    /// The source of the current date for the backup name (replaced in tests).
    var currentDate: () -> Date = { Date() }

    /// The JSON file schema version.
    ///
    /// Version 2 (D33): every top-level item has a `row`/`column` cell, and the document has the
    /// canvas width `columns`. Version 1 is read and migrated lazily (``placeItems(columns:)``).
    private static let schemaVersion = 2

    /// The explicit cells of top-level items by canonical key.
    ///
    /// There are records for invisible keys too (shortcuts outside the current catalog): they keep
    /// their cell but do not take part in layout and collisions (D30). While ``canvasColumns`` is
    /// `nil` (a "not laid out" state: a version 1 file or the first launch before the width is
    /// known), the dictionary is empty.
    private var placementsByKey: [String: TesseraTileGridPlacement] = [:]

    /// The last host grid width the store learned from a call with `columns`
    /// (``placeItems(columns:)``, ``resize(_:to:columns:)`` and so on).
    private var hostColumns: Int?

    /// The minimum number of shortcuts in a folder (D45): a folder of 0 or 1 shortcuts does not
    /// exist.
    ///
    /// The rule applies where shortcuts are **removed** from a folder (taking out, unpinning, moving
    /// to another folder, pruning against the catalog) and when a file is loaded; when a folder loses
    /// a shortcut and one remains, it is **dissolved**: the last shortcut takes the folder's cell
    /// with its own size. The only exception is the transitional state of the public
    /// ``createFolder(withTile:title:columns:)`` (a folder of one shortcut before the following
    /// ``addToFolder(_:folderID:columns:)``).
    static let minimumFolderTileCount = 2

    /// Folders that the file brought with one shortcut and that are not dissolved yet (D45).
    ///
    /// At the time of ``load()`` the catalog may not be registered: which of the folder's shortcuts
    /// really exist is unknown yet, and dissolving the folder is premature (an uninstalled app must
    /// not turn into an "invisible" shortcut on the grid). Such folders are remembered here, and
    /// pruning against the catalog (``pruneFoldersAgainstCatalog()``) dissolves them after the
    /// catalog is registered.
    private var underfilledFolderKeys: Set<String> = []

    /// Shortcuts that took the place of a dissolved folder during pruning against the catalog and on
    /// load, together with the folder's cell (D45).
    ///
    /// Their final cells are computed by the engine in `resolveDissolvedTiles()` (`inserting` on the
    /// folder cell: a larger shortcut pushes neighbors down).
    private var pendingDissolvedTiles: [(key: String, cell: TesseraTileGridPlacement)] = []

    /// The canonical default grid column count (6, D26).
    ///
    /// Needed when the host grid width is not known yet (``effectiveColumns``): `TesseraTileStore`
    /// has no screen width. The value is ``TesseraTileLayoutEngine/defaultColumns``. If the host set
    /// its own column count, the caller passes it to ``resize(_:to:columns:)``.
    static let defaultGridColumns = TesseraTileLayoutEngine.defaultColumns

    // MARK: - Initialization

    /// Creates a store.
    ///
    /// - Parameter directoryURL: The directory for the JSON file; `nil` means the default directory
    ///   (Application Support/TesseraStartScreen). The directory is injected for tests and to
    ///   isolate several start screens.
    public init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? TesseraTileStore.defaultDirectoryURL()
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent("tiles.json", isDirectory: false)
    }

    /// The default directory: Application Support/TesseraStartScreen.
    ///
    /// Application Support is the right place for state the user does not create by hand: it is not
    /// backed up like documents and not purged like Caches. The fallbacks are for sandboxes without
    /// Application Support.
    public static func defaultDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TesseraStartScreen", isDirectory: true)
    }

    // MARK: - Shortcut catalog

    /// Registers the app's shortcut catalog (D12).
    ///
    /// Shortcut actions are not serialized, so after a restart the host passes the catalog again, and
    /// ``load()`` applies the saved layout on top of it. Call this **before** `load()`: shortcuts
    /// unknown at load time stay in the file but do not reach the snapshot until they appear in the
    /// catalog.
    ///
    /// The size of new shortcuts comes from `TesseraTileDescriptor.size` (`.medium` by default,
    /// D12). Pass the whole catalog in one call: shortcuts missing from the current call are treated
    /// as removed and are pruned from folders.
    ///
    /// Repeated identifiers are dropped (the first wins). On the first launch (there is no state file
    /// yet) new shortcuts are pinned at the end of the grid right away; after a file is restored,
    /// they are not, so as not to resurrect unpinned ones. Shortcuts that disappeared from the
    /// catalog are removed from folders (the catalog is authoritative for their content), and a
    /// folder left with fewer than two shortcuts is dissolved (D45): if one shortcut remains, it
    /// takes the folder's cell with its own size (a larger one pushes neighbors down, D31), and an
    /// empty folder disappears, so an uninstalled app leaves no "dead" tiles. The same pruning runs
    /// after ``load()`` if the catalog is already registered, so the order of `setCatalog`/`load`
    /// calls does not affect folders. Folders of 0-1 shortcuts read from a file are dissolved here
    /// too. Shortcuts outside the catalog that stand directly on the grid are not deleted: they stay
    /// invisible keys and hold their place until they return to the catalog.
    ///
    /// Cells: if they already exist (``canvasColumns``), new shortcuts get a row at the end of the
    /// canvas, and returned invisible ones get their previous cell if it is free of visible items,
    /// otherwise also a new row at the end. Without cells (the first launch), the first-launch layout
    /// is assigned on the first ``placeItems(columns:)``. The method does not write the file.
    ///
    /// - Parameter descriptors: The shortcut catalog in initial order.
    public func setCatalog(_ descriptors: [TesseraTileDescriptor]) {
        // The keys visible before the catalog change: in a cell conflict they win over those that
        // have just returned to the catalog (D30).
        let settledBefore = Set(visibleGridKeys())

        var seen = Set<String>()
        var unique: [TesseraTileDescriptor] = []
        unique.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            let key = TesseraTileStore.storageKey(for: descriptor.id)
            guard seen.insert(key).inserted else { continue }
            unique.append(descriptor)
        }

        catalog = unique
        catalogRegistered = true
        catalogIndex.removeAll(keepingCapacity: true)
        for (index, descriptor) in unique.enumerated() {
            catalogIndex[TesseraTileStore.storageKey(for: descriptor.id)] = index
        }

        // Shortcuts the store did not know yet (no saved size): only these can be pinned
        // automatically on the first launch. This way re-registering the catalog does not resurrect
        // unpinned shortcuts.
        var introduced = Set<String>()
        for descriptor in unique {
            let key = TesseraTileStore.storageKey(for: descriptor.id)
            if sizes[key] == nil {
                sizes[key] = descriptor.size
                introduced.insert(key)
            }
        }

        pruneFoldersAgainstCatalog()

        if !restoredFromDisk {
            let onGrid = Set(gridOrder)
            for descriptor in unique {
                let key = TesseraTileStore.storageKey(for: descriptor.id)
                guard introduced.contains(key), !onGrid.contains(key) else { continue }
                gridOrder.append(key)
            }
        }

        // The cells of newly appeared keys are a new row at the end of the canvas (if cells already
        // exist), and returned invisible ones go to their place if it is free. Without cells (the
        // "not laid out" state) nothing is done: the first launch is laid out by a `packCompact`
        // pass when the width is known (``placeItems(columns:)``).
        reconcilePlacements(settled: settledBefore)

        notifyChange()
    }

    /// A shortcut by identifier.
    ///
    /// - Parameter id: The shortcut identifier.
    /// - Returns: The catalog shortcut with its current size, or `nil`.
    public func descriptor(withID id: AnyHashable) -> TesseraTileDescriptor? {
        guard let index = catalogIndex[TesseraTileStore.storageKey(for: id)] else { return nil }
        return resolved(catalog[index])
    }

    // MARK: - Snapshot

    /// The current grid snapshot: order, sizes, folders and unpinned shortcuts.
    ///
    /// The snapshot is built on request and not cached: the grid reads it after every change, and
    /// the store stays the single source of truth.
    ///
    /// The expanded folder panel (D17) does not enter the snapshot: the store keeps data, and the
    /// "folder is expanded" state is a representation. The host adds
    /// ``TesseraTileGridItem/folderContent(_:)`` to a copy of the items itself, so persistence does
    /// not change.
    ///
    /// - Returns: A consistent grid snapshot.
    public func snapshot() -> TesseraTileGridSnapshot {
        makeSnapshot(orderedBy: nil)
    }

    /// Builds a snapshot: items in the reading order of the cells.
    ///
    /// The `items` order is the VoiceOver order (``TesseraTileGridView`` hands it to the collection
    /// as the index order), so it must match how items are read on screen: row ascending, then
    /// logical column. `gridOrder` does not guarantee that after ``load()``, the v1 to v2 migration,
    /// ``setCatalog(_:)`` and a projection for another width, so the snapshot is always sorted by
    /// cells and does not take `gridOrder` as is.
    ///
    /// - Parameter columns: The width whose cells define the reading order: ``canvasColumns`` means
    ///   the saved cells, another width means a projection (D32); `nil` means the saved cells, and
    ///   without them (the "not laid out" state) the model order.
    /// - Returns: A snapshot without a cell table.
    private func makeSnapshot(orderedBy columns: Int?) -> TesseraTileGridSnapshot {
        var items: [TesseraTileGridItem] = []
        var placedKeys = Set<String>()

        for key in readingOrderedKeys(forColumns: columns) {
            if let record = folderRecords.first(where: { $0.key == key }) {
                items.append(.folder(materialize(record)))
                placedKeys.formUnion(record.tileKeys)
            } else if let index = catalogIndex[key] {
                items.append(.tile(resolved(catalog[index])))
                placedKeys.insert(key)
            }
        }

        let unpinned = catalog
            .filter { !placedKeys.contains(TesseraTileStore.storageKey(for: $0.id)) }
            .map(resolved)

        return TesseraTileGridSnapshot(items: items, unpinned: unpinned)
    }

    /// A grid snapshot with an explicit cell table for width `columns` (D30).
    ///
    /// The same items and off-grid shortcuts as ``snapshot()``, plus
    /// ``TesseraTileGridSnapshot/placementTable``: the cells from ``placements(forColumns:)`` (the
    /// saved layout with holes if `columns` matches ``canvasColumns``, otherwise a projection
    /// without holes, D32) and the declared width `columns`. A grid of the same width lays tiles out
    /// on these cells; a grid of another width ignores the table and packs by order.
    ///
    /// This is the standard path for the host and the edit coordinator: the grid shows the saved
    /// cells (holes), and ``onChange`` hands out the same snapshot when the host width is known. A
    /// host without a store and without a table still gets order-based packing.
    ///
    /// - Parameter columns: The host grid column count, greater than zero.
    /// - Returns: A snapshot; for `columns <= 0` no table is attached.
    public func snapshot(columns: Int) -> TesseraTileGridSnapshot {
        guard columns > 0 else { return snapshot() }
        // The item order is the reading order of exactly the cells that go into the table (for
        // another width, of the projection), so that VoiceOver reads tiles the way they lie on
        // screen.
        let base = makeSnapshot(orderedBy: columns)
        return TesseraTileGridSnapshot(
            items: base.items,
            unpinned: base.unpinned,
            placementTable: TesseraTileGridPlacementTable(
                cells: placements(forColumns: columns),
                columns: columns
            )
        )
    }

    // MARK: - Pinning

    /// Whether a shortcut is pinned (on the grid or in a folder).
    ///
    /// - Parameter tileID: The shortcut identifier.
    /// - Returns: `true` if the shortcut is on the grid or in a folder.
    public func isPinned(_ tileID: AnyHashable) -> Bool {
        let key = TesseraTileStore.storageKey(for: tileID)
        return gridOrder.contains(key) || folderRecords.contains { $0.tileKeys.contains(key) }
    }

    // MARK: - Folders (D14: only through host approval)

    /// The size of a newly created folder: always medium.
    ///
    /// As in Windows 10 Mobile, a folder is always a 2×2 tile and does not depend on the size of the
    /// target shortcut; a wide/large target is replaced by a medium folder.
    static let newFolderSize: TesseraTileSize = .medium

    /// The outcome of atomically creating a folder from two shortcuts.
    enum AtomicFolderResult {

        /// Both steps approved: the folder is created and the second shortcut is in it.
        case created(TesseraTileFolder)

        /// The host denied folder creation (the first step), or the shortcuts are not on the grid.
        case createDenied

        /// The host denied adding the second shortcut (the second step); the state did not
        /// change.
        case addDenied
    }

    /// The folder that holds a shortcut.
    ///
    /// - Parameter tileID: The shortcut identifier.
    /// - Returns: The folder, or `nil` if the shortcut is not in a folder.
    public func folderContaining(_ tileID: AnyHashable) -> TesseraTileFolder? {
        let key = TesseraTileStore.storageKey(for: tileID)
        guard let record = folderRecords.first(where: { $0.tileKeys.contains(key) }) else {
            return nil
        }
        return materialize(record)
    }

    // MARK: - Cells on the canvas (D30–D33)

    /// The saved cells of visible top-level items on a canvas of width ``canvasColumns`` (logical
    /// coordinates, 0 is the reading start).
    ///
    /// Empty while there are no cells (``canvasColumns`` is `nil`). This is exactly the saved
    /// layout: for a host with another width use ``placements(forColumns:)``. Folder contents have no
    /// cells.
    public var placements: [AnyHashable: TesseraTileGridPlacement] {
        guard canvasColumns != nil else { return [:] }
        return storedVisiblePlacements()
    }

    /// The cell of an item on the saved canvas.
    ///
    /// - Parameter id: The shortcut or folder identifier on the grid.
    /// - Returns: The cell, or `nil` if there are no cells yet or the item is not on the visible
    ///   grid.
    public func placement(of id: AnyHashable) -> TesseraTileGridPlacement? {
        guard canvasColumns != nil else { return nil }
        let key = TesseraTileStore.storageKey(for: id)
        guard visibleGridKeys().contains(key) else { return nil }
        return placementsByKey[key]
    }

    /// The cells of visible items for a host of width `columns` (D32).
    ///
    /// If `columns` matches ``canvasColumns``, the saved layout with holes is returned. Otherwise a
    /// **projection**: tiles in the reading order of the saved cells (row, then column) are packed
    /// by `TesseraTileLayoutEngine.packCompact` for the host width, without holes. The projection is
    /// computed on the fly and the file is **not overwritten**: going back to the previous width
    /// without edits returns the holes. Without cells (``canvasColumns`` is `nil`) it is packing of
    /// the current model order. A shortcut wider than `columns` takes a shrunk footprint
    /// (``TesseraTileLayoutEngine/fittingSize(_:columns:)``).
    ///
    /// With a width mismatch, the first edit operation accepts the layout for the host width as a
    /// new canvas (``canvasColumns`` is updated): cell-based operations compute coordinates with the
    /// engine and accept the projection as the canvas themselves (D31).
    ///
    /// - Parameter columns: The host grid column count, greater than zero.
    /// - Returns: Cells by identifier; empty for `columns <= 0`.
    public func placements(forColumns columns: Int) -> [AnyHashable: TesseraTileGridPlacement] {
        guard columns > 0 else { return [:] }
        if canvasColumns == columns {
            return storedVisiblePlacements()
        }
        var result: [AnyHashable: TesseraTileGridPlacement] = [:]
        for (key, placement) in projectedPlacements(columns: columns) {
            if let id = visibleItemID(forKey: key) {
                result[id] = placement
            }
        }
        return result
    }

    /// The identifiers of visible items in the cell reading order for width `columns` (row, then
    /// column; for equal cells, the model order).
    ///
    /// For a width equal to ``canvasColumns``, the order comes from the saved cells; otherwise from
    /// the projection (``placements(forColumns:)``).
    ///
    /// - Parameter columns: The host grid column count, greater than zero.
    /// - Returns: Identifiers in reading order; empty for `columns <= 0`.
    public func placementReadingOrder(forColumns columns: Int) -> [AnyHashable] {
        guard columns > 0 else { return [] }
        return readingOrderedKeys(forColumns: columns).compactMap { visibleItemID(forKey: $0) }
    }

    /// The keys of visible items in the cell reading order.
    ///
    /// A single source of order for ``snapshot()``, ``snapshot(columns:)`` and
    /// ``placementReadingOrder(forColumns:)``. The reading order is row ascending, then logical
    /// column (0 is the reading start, so in RTL the order is the same); cells do not overlap, and
    /// equal cells (a corrupted file) stay in model order.
    ///
    /// - Parameter columns: The host width; `nil` means no width: the saved cells, and if there are
    ///   none yet, the model order.
    /// - Returns: The canonical keys of visible items.
    private func readingOrderedKeys(forColumns columns: Int?) -> [String] {
        let visible = visibleGridKeys()
        if let columns, columns > 0 {
            let cells = canvasColumns == columns
                ? placementsByKey
                : projectedPlacements(columns: columns)
            return TesseraTileStore.readingSorted(visible, by: cells)
        }
        guard canvasColumns != nil else { return visible }
        return TesseraTileStore.readingSorted(visible, by: placementsByKey)
    }

    /// Reports the host grid width to the store and, if there are no cells yet, assigns them (lazy
    /// v1 to v2 migration and the first-launch layout, D33).
    ///
    /// One-time: if there are no cells (a version 1 file or the first launch), the current order of
    /// visible items is packed by the previous `TesseraTileLayoutEngine.packCompact` for `columns`,
    /// so nothing changes visibly; the cells of invisible keys go into new rows at the end, and the
    /// result is saved right away (with ``autosaves``). If cells already exist, the method only
    /// remembers the width; the file is not touched even if the width differs from
    /// ``canvasColumns`` (D32). The migration waits until a catalog is registered and there is
    /// something to lay out; then ``load()`` or the next call performs it. The migration does not
    /// save a file that ``load()`` has not read yet (otherwise it would overwrite it).
    ///
    /// The width is also remembered by operations with `columns` (``resize(_:to:columns:)``,
    /// ``moveItem(_:toCell:columns:)``, ``pinTile(_:columns:)`` and others).
    ///
    /// The ``onChange`` notification is not sent: the grid snapshot does not change.
    ///
    /// - Parameter columns: The host grid column count, greater than zero.
    /// - Returns: `true` if this call assigned the cells.
    @discardableResult
    public func placeItems(columns: Int) -> Bool {
        guard columns > 0 else { return false }
        hostColumns = columns
        let wasUnplaced = canvasColumns == nil
        migrateIfPossible()
        return wasUnplaced && canvasColumns != nil
    }

    // MARK: - Persistence

    /// Saves the state to JSON with an atomic write (§5).
    ///
    /// The directory is created if needed. The write is atomic: the file is either the old one or
    /// the new one in full, so an interrupted launch leaves no half of a layout. The version 2
    /// schema is written: every item has `row`/`column`, and the document has the canvas width
    /// `columns`; while there are no cells (``canvasColumns`` is `nil`), the fields are omitted, and
    /// the next `load()` treats the file as not laid out.
    ///
    /// If ``load()`` found an unreadable file and could not set it aside as a backup, the write first
    /// retries that attempt and throws an error on failure: an unreadable file is not overwritten.
    ///
    /// - Throws: A file system or JSON encoding error.
    public func save() throws {
        if unreadableFilePending {
            try backUpUnreadableFile()
        }

        let document = TileStoreDocument(
            version: TesseraTileStore.schemaVersion,
            columns: canvasColumns,
            items: makeDocumentItems(),
            sizes: sizes,
            folders: folderRecords.map {
                TileStoreDocument.Folder(key: $0.key, title: $0.title, size: $0.size, tileKeys: $0.tileKeys)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        lastPersistenceError = nil
    }

    /// Reads the saved state and applies it on top of the current catalog.
    ///
    /// The grid order, sizes, folders and pins are restored; the shortcut catalog (actions) stays
    /// what the host registered. Shortcuts from the file that are not in the catalog and stand
    /// directly on the grid are kept in the model as invisible keys: they do not reach the snapshot
    /// but hold their place until registered. If a catalog is already registered, folders are pruned
    /// against it, as in ``setCatalog(_:)``: unknown shortcuts are removed from folders, and a folder
    /// without a single catalog shortcut is dissolved. A folder that is in the file but absent from
    /// the grid order is not lost: it goes to the end of the grid.
    ///
    /// A version 1 file (no cells) migrates lazily (D33): `load()` runs before the grid width is
    /// known, so the cells are assigned by ``placeItems(columns:)``, a one-time `packCompact` pass
    /// over the saved order, with an immediate version 2 write. If the width is already known, the
    /// migration runs at the end of `load()`. A version newer than supported is handled as before (a
    /// backup, the state does not change).
    ///
    /// If there is no file, nothing happens (the first launch). A read error does not change the
    /// current state and is rethrown to the caller. If the file is read but does not decode or was
    /// written by a newer schema, it is renamed before any write to a backup
    /// `<name>.unreadable-<ISO date>.json` next to it (``lastUnreadableFileBackupURL``): the store
    /// keeps working with the current state, and autosave writes a new file without overwriting the
    /// unreadable one.
    ///
    /// - Throws: A read/decoding error or ``TesseraTileStoreError``.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // An I/O error (no access and so on) may be temporary: the file is not touched, the error is
        // just rethrown.
        let data = try Data(contentsOf: fileURL)

        let document: TileStoreDocument
        do {
            document = try JSONDecoder().decode(TileStoreDocument.self, from: data)
            guard document.version <= TesseraTileStore.schemaVersion else {
                throw TesseraTileStoreError.unsupportedSchemaVersion(document.version)
            }
        } catch {
            // The content was read but cannot be understood: the file is set aside as a backup
            // before the first autosave writes the current version's schema over it.
            lastPersistenceError = error
            unreadableFilePending = true
            try? backUpUnreadableFile()
            throw error
        }

        apply(document)
        if catalogRegistered {
            pruneFoldersAgainstCatalog()
        }
        restoredFromDisk = true
        // The cells from the file are brought to the invariants (bounds, collisions of visible
        // items); a version 1 file migrates if the host has already reported the width.
        reconcilePlacements()
        migrateIfPossible()
        notifyChange()
    }

    /// Renames an unreadable state file to a backup.
    ///
    /// The name is `<name>.unreadable-<ISO date>.json` in the same directory (time colons replaced
    /// with hyphens). Renaming within a directory is atomic; an existing copy is not overwritten:
    /// `-2`, `-3`… is appended to the name. If the file is already gone, there is nothing to set
    /// aside.
    ///
    /// - Throws: A file system error if the file could not be renamed.
    private func backUpUnreadableFile() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            unreadableFilePending = false
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: currentDate()).replacingOccurrences(of: ":", with: "-")
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension

        var lastError: Error?
        for attempt in 1...100 {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let backupURL = directoryURL.appendingPathComponent(
                "\(baseName).unreadable-\(stamp)\(suffix).\(fileExtension)",
                isDirectory: false
            )
            guard !fileManager.fileExists(atPath: backupURL.path) else { continue }
            do {
                // `moveItem` does not overwrite an existing file: if a copy was created between the
                // check and the rename, the next name is tried.
                try fileManager.moveItem(at: fileURL, to: backupURL)
                lastUnreadableFileBackupURL = backupURL
                unreadableFilePending = false
                return
            } catch {
                lastError = error
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    unreadableFilePending = false
                    return
                }
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    /// Applies the read document to the model.
    ///
    /// The method tolerates garbage in the file: duplicates are dropped, a shortcut cannot be both
    /// on the grid and in a folder, and folders without content are dissolved. That is cheaper than
    /// failing on a slightly corrupted state file.
    ///
    /// - Parameter document: The read document.
    private func apply(_ document: TileStoreDocument) {
        sizes = document.sizes

        var seenFolders = Set<String>()
        folderRecords = document.folders
            .filter { seenFolders.insert($0.key).inserted }
            .map {
                FolderRecord(
                    key: $0.key,
                    id: TesseraTileStore.identifier(fromStorageKey: $0.key),
                    title: $0.title,
                    size: $0.size,
                    tileKeys: $0.tileKeys
                )
            }

        // A shortcut belongs to at most one folder: the first in file order wins. A folder cannot
        // lie in a folder, so folder keys are dropped.
        let recordKeys = Set(folderRecords.map { $0.key })
        var claimed = Set<String>()
        for index in folderRecords.indices {
            folderRecords[index].tileKeys = folderRecords[index].tileKeys.filter {
                !recordKeys.contains($0) && claimed.insert($0).inserted
            }
        }

        // Empty folders make no sense on the grid: dissolve them.
        var dissolved = Set<String>()
        folderRecords.removeAll { record in
            if record.tileKeys.isEmpty {
                dissolved.insert(record.key)
                return true
            }
            return false
        }

        // D45: a folder of one shortcut (an old-version file, a manual edit) does not exist either,
        // but it can be dissolved only when the catalog is known: the shortcut may have disappeared
        // from the app. Such folders are remembered, and pruning against the catalog finishes the job
        // (``pruneFoldersAgainstCatalog()``).
        underfilledFolderKeys = Set(
            folderRecords
                .filter { $0.tileKeys.count < TesseraTileStore.minimumFolderTileCount }
                .map { $0.key }
        )
        pendingDissolvedTiles = []

        let folderKeys = Set(folderRecords.map { $0.key })
        var order: [String] = []
        var seenItems = Set<String>()
        for item in document.items {
            guard seenItems.insert(item.key).inserted else { continue }
            guard !dissolved.contains(item.key) else { continue }
            switch item.kind {
            case .folder:
                guard folderKeys.contains(item.key) else { continue }
            case .tile:
                // The shortcut may not be in the catalog yet: the place is remembered.
                break
            }
            order.append(item.key)
        }

        // Invariant: a shortcut from a folder is not duplicated on the grid.
        let tilesInFolders = Set(folderRecords.flatMap { $0.tileKeys })
        order.removeAll { tilesInFolders.contains($0) }

        // "Orphan" folders: present in `folders` but not in the grid order. Without a place on the
        // grid their shortcuts would vanish from the snapshot and from the unpinned list, so such
        // folders are put at the end of the grid in file order.
        let placed = Set(order)
        for record in folderRecords where !placed.contains(record.key) {
            order.append(record.key)
        }

        gridOrder = order
        applyStoredPlacements(from: document)
    }

    /// Applies the cells from the document to the model.
    ///
    /// The "not laid out" state (``canvasColumns`` is `nil`, no cells): a version 1 file; the
    /// document has no canvas width; a **partial** set, where at least one surviving item has no
    /// `row`/`column`. The lazy migration then assigns the cells.
    ///
    /// Individual bad values (negative, excessive, not fitting the canvas) are "offenders": their
    /// record is dropped, and ``reconcilePlacements(settled:)`` moves them to new rows at the end.
    /// It also resolves collisions of visible items, once it is known who is visible.
    ///
    /// - Parameter document: The read document.
    private func applyStoredPlacements(from document: TileStoreDocument) {
        placementsByKey = [:]
        canvasColumns = nil
        guard let columns = document.columns, columns > 0 else { return }

        var firstItems: [String: TileStoreDocument.Item] = [:]
        for item in document.items where firstItems[item.key] == nil {
            firstItems[item.key] = item
        }

        var parsed: [String: TesseraTileGridPlacement] = [:]
        for key in gridOrder {
            guard let item = firstItems[key], let row = item.row, let column = item.column else {
                return
            }
            parsed[key] = TesseraTileGridPlacement(row: row, column: column)
        }

        for (key, placement) in parsed where isPlacementValid(placement, forKey: key, columns: columns) {
            placementsByKey[key] = placement
        }
        canvasColumns = columns
    }

    /// The layout as JSON document items, with a "shortcut/folder" flag.
    ///
    /// - Returns: The items in grid order (with cells, if there are any).
    private func makeDocumentItems() -> [TileStoreDocument.Item] {
        let folderKeys = Set(folderRecords.map { $0.key })
        let hasCanvas = canvasColumns != nil
        return gridOrder.map { key in
            let placement = hasCanvas ? placementsByKey[key] : nil
            return TileStoreDocument.Item(
                kind: folderKeys.contains(key) ? .folder : .tile,
                key: key,
                row: placement?.row,
                column: placement?.column
            )
        }
    }

    // MARK: - Notifications and helper operations

    /// Reports a change after an operation: saving (if ``autosaves`` is on), then the snapshot to
    /// subscribers.
    ///
    /// The operation coordinates are already computed by the engine and are saved as is
    /// (``commitCells(_:columns:)``): there is no repacking.
    private func didChange() {
        if autosaves {
            saveIfPossible()
        }
        notifyChange()
    }

    /// Sends the snapshot to subscribers: `objectWillChange` and ``onChange``.
    ///
    /// If the store knows the host grid width (the edit coordinator reports it,
    /// ``placeItems(columns:)``), the snapshot goes with an explicit cell table
    /// (``snapshot(columns:)``): a host that applies `onChange` to the grid gets holes rather than
    /// order-based packing. Without a known width the snapshot is the previous kind: the grid lays it
    /// out by packing.
    private func notifyChange() {
        let current = hostColumns.map { snapshot(columns: $0) } ?? snapshot()
        objectWillChange.send()
        onChange?(current)
    }

    /// Saves the state, remembering the error instead of rethrowing it.
    private func saveIfPossible() {
        do {
            try save()
        } catch {
            lastPersistenceError = error
        }
    }

    /// Whether a grid key is visible in the snapshot: a folder or a shortcut from the current
    /// catalog.
    ///
    /// The other `gridOrder` keys are invisible: shortcuts that are not in the catalog (``load()``
    /// remembers their place until registration).
    ///
    /// - Parameter key: A canonical key from `gridOrder`.
    /// - Returns: `true` if the item reaches ``snapshot()``.
    private func isVisibleGridKey(_ key: String) -> Bool {
        catalogIndex[key] != nil || folderRecords.contains { $0.key == key }
    }

    /// The keys of visible grid items in snapshot order.
    ///
    /// The order matches `snapshot().items` and `layoutItems`: it is the cell reading order
    /// (``gridOrder``).
    ///
    /// - Returns: The canonical keys of visible items.
    private func visibleGridKeys() -> [String] {
        let folderKeys = Set(folderRecords.map { $0.key })
        return gridOrder.filter { catalogIndex[$0] != nil || folderKeys.contains($0) }
    }

    /// Applies a new order of visible items without moving the invisible ones.
    ///
    /// `visibleKeys` are the keys of snapshot items in the new order (the cell reading order,
    /// ``commitCells(_:columns:)``). `gridOrder` can contain keys that are not in the snapshot:
    /// shortcuts not yet registered in the catalog (``load()`` remembers them). Their place must not
    /// change because of an operation on another item, so they stay at their previous `gridOrder`
    /// indices, and visible items take the remaining positions in the new order.
    ///
    /// If `visibleKeys` has duplicates or an invisible key, the order does not change: it is better
    /// to keep the previous layout than to lose or duplicate a key in `gridOrder`. Checking that the
    /// set is complete is up to the caller.
    ///
    /// - Parameter visibleKeys: The canonical keys of visible items in the new order.
    /// - Returns: `true` if `gridOrder` changed.
    @discardableResult
    private func applyVisibleOrder(_ visibleKeys: [String]) -> Bool {
        let visibleSet = Set(visibleKeys)
        guard visibleSet.count == visibleKeys.count else { return false }

        let hidden = gridOrder.enumerated().filter { !isVisibleGridKey($0.element) }
        guard !hidden.contains(where: { visibleSet.contains($0.element) }) else { return false }

        var result = visibleKeys
        for (index, key) in hidden {
            result.insert(key, at: min(index, result.count))
        }

        guard result != gridOrder else { return false }
        gridOrder = result
        return true
    }

    // MARK: - Cells: internal operations

    /// Remembers the host width from a call with `columns`.
    ///
    /// - Parameter columns: The column count; `nil` and non-positive values are ignored.
    private func noteHostColumns(_ columns: Int?) {
        guard let columns = columns, columns > 0 else { return }
        hostColumns = columns
    }

    /// The width the cells are recomputed for after an operation: the last host width, otherwise the
    /// canvas width, otherwise the default (D26). Internal: the app list page takes it when the host
    /// did not pass columns.
    var effectiveColumns: Int {
        hostColumns ?? canvasColumns ?? TesseraTileStore.defaultGridColumns
    }

    /// The item size by key: a folder, then the saved size, then the catalog.
    private func storedSize(ofKey key: String) -> TesseraTileSize {
        if let record = folderRecords.first(where: { $0.key == key }) { return record.size }
        if let size = sizes[key] { return size }
        if let index = catalogIndex[key] { return catalog[index].size }
        return .medium
    }

    /// The item size shrunk to the canvas width (D15).
    private func footprint(ofKey key: String, columns: Int) -> TesseraTileSize {
        TesseraTileLayoutEngine.fittingSize(storedSize(ofKey: key), columns: columns)
    }

    /// The identifier of a visible item by key.
    private func visibleItemID(forKey key: String) -> AnyHashable? {
        if let record = folderRecords.first(where: { $0.key == key }) { return record.id }
        if let index = catalogIndex[key] { return catalog[index].id }
        return nil
    }

    /// The saved cells of visible items by identifier.
    private func storedVisiblePlacements() -> [AnyHashable: TesseraTileGridPlacement] {
        var result: [AnyHashable: TesseraTileGridPlacement] = [:]
        for key in visibleGridKeys() {
            guard let placement = placementsByKey[key], let id = visibleItemID(forKey: key) else { continue }
            result[id] = placement
        }
        return result
    }

    /// The previous compact packing (`packCompact`) of keys in the given order.
    ///
    /// - Parameters:
    ///   - keys: The keys in packing order.
    ///   - columns: The canvas width, greater than zero.
    /// - Returns: Cells by key (an item that did not fit is skipped).
    private func packedPlacements(of keys: [String], columns: Int) -> [String: TesseraTileGridPlacement] {
        guard columns > 0 else { return [:] }
        let slots = TesseraTileLayoutEngine.packCompact(
            items: keys.map { (id: AnyHashable($0), size: footprint(ofKey: $0, columns: columns)) },
            columns: columns,
            unit: 1
        )
        var result: [String: TesseraTileGridPlacement] = [:]
        for slot in slots {
            guard let key = slot.id.base as? String else { continue }
            result[key] = TesseraTileGridPlacement(row: slot.row, column: slot.column)
        }
        return result
    }

    /// A projection of the layout onto width `columns` without holes (D32): visible items in the
    /// reading order of the saved cells (in model order if there are no cells) are packed by
    /// `packCompact`.
    private func projectedPlacements(columns: Int) -> [String: TesseraTileGridPlacement] {
        var keys = visibleGridKeys()
        if canvasColumns != nil {
            keys = TesseraTileStore.readingSorted(keys, by: placementsByKey)
        }
        return packedPlacements(of: keys, columns: columns)
    }

    /// Keys in cell reading order (row, column); for equal cells and without cells, the original order
    /// (the sort is stable thanks to the index).
    private static func readingSorted(_ keys: [String], by cells: [String: TesseraTileGridPlacement]) -> [String] {
        keys.enumerated().sorted { lhs, rhs in
            switch (cells[lhs.element], cells[rhs.element]) {
            case let (left?, right?):
                if left != right { return TesseraTileGridPlacement.isReadingOrdered(left, before: right) }
                return lhs.offset < rhs.offset
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map { $0.element }
    }

    /// Whether a cell is valid: non-negative, not excessive and entirely within the canvas.
    private func isPlacementValid(_ placement: TesseraTileGridPlacement, forKey key: String, columns: Int) -> Bool {
        guard placement.row >= 0, placement.column >= 0,
              placement.row <= TesseraTileStore.maxPlacementRow,
              placement.column < columns else { return false }
        let size = footprint(ofKey: key, columns: columns)
        return placement.column + size.unitColumns <= columns
    }

    /// A reasonable row limit in a file: more is garbage, not a layout.
    private static let maxPlacementRow = 100_000

    /// A one-time lazy migration: assigns cells with a `packCompact` pass.
    ///
    /// It needs the host width, a registered catalog and a non-empty order. After the migration the
    /// file is saved right away, but only if that does not overwrite an unread state
    /// (``restoredFromDisk``, or there is no file).
    private func migrateIfPossible() {
        guard canvasColumns == nil, let columns = hostColumns, columns > 0,
              catalogRegistered, !gridOrder.isEmpty else { return }
        placementsByKey = packedPlacements(of: visibleGridKeys(), columns: columns)
        canvasColumns = columns
        reconcilePlacements()

        guard autosaves, restoredFromDisk || !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        saveIfPossible()
    }

    /// Brings the cells to the canvas invariants (D30).
    ///
    /// Does nothing while there are no cells. Otherwise:
    /// - records for keys that are not in the grid order are removed;
    /// - visible items (in grid order, "settled" ones, `settled`, first) keep their cell if it is
    ///   entirely within the canvas and does not intersect those already accepted; the others,
    ///   offenders and newcomers, are packed by `packCompact` into **new rows at the end of the
    ///   canvas** (the first row after the last one occupied by visible items; a single newcomer
    ///   goes into column 0);
    /// - invisible keys keep their cell if it is within the canvas bounds and **do not take part in
    ///   collisions**; without a valid cell they get one in the rows after the visible ones.
    ///
    /// - Parameter settled: The keys visible before the catalog change.
    private func reconcilePlacements(settled: Set<String> = []) {
        guard let columns = canvasColumns, columns > 0 else { return }

        let visible = visibleGridKeys()
        let visibleSet = Set(visible)
        let indexInGrid = Dictionary(
            gridOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // The item rectangle: (row, column, width, height) in units.
        typealias Rect = (row: Int, column: Int, width: Int, height: Int)
        func overlaps(_ a: Rect, _ b: Rect) -> Bool {
            a.column < b.column + b.width && b.column < a.column + a.width
                && a.row < b.row + b.height && b.row < a.row + a.height
        }

        var accepted: [Rect] = []
        var next: [String: TesseraTileGridPlacement] = [:]
        var pendingVisible: [String] = []

        let priority = visible.filter { settled.contains($0) } + visible.filter { !settled.contains($0) }
        for key in priority {
            let size = footprint(ofKey: key, columns: columns)
            if let placement = placementsByKey[key],
               isPlacementValid(placement, forKey: key, columns: columns) {
                let rect: Rect = (placement.row, placement.column, size.unitColumns, size.unitRows)
                if !accepted.contains(where: { overlaps($0, rect) }) {
                    accepted.append(rect)
                    next[key] = placement
                    continue
                }
            }
            pendingVisible.append(key)
        }
        pendingVisible.sort { (indexInGrid[$0] ?? 0) < (indexInGrid[$1] ?? 0) }

        var pendingHidden: [String] = []
        for key in gridOrder where !visibleSet.contains(key) {
            if let placement = placementsByKey[key], isPlacementValid(placement, forKey: key, columns: columns) {
                next[key] = placement
            } else {
                pendingHidden.append(key)
            }
        }

        // New rows at the end: below the last row occupied by visible items.
        var baseRow = accepted.map { $0.row + $0.height }.max() ?? 0
        for group in [pendingVisible, pendingHidden] where !group.isEmpty {
            let packed = packedPlacements(of: group, columns: columns)
            var bottom = baseRow
            for key in group {
                guard let cell = packed[key] else { continue }
                next[key] = TesseraTileGridPlacement(row: baseRow + cell.row, column: cell.column)
                let size = footprint(ofKey: key, columns: columns)
                bottom = max(bottom, baseRow + cell.row + size.unitRows)
            }
            baseRow = bottom
        }

        placementsByKey = next
    }

    /// Removes from folders the shortcuts that are no longer in the catalog and dissolves folders
    /// with fewer than two shortcuts left (D45).
    ///
    /// Called on catalog re-registration and after ``load()`` when a catalog is registered: an
    /// uninstalled app must not leave "dead" identifiers in folders, and a folder without a single
    /// catalog shortcut must not leave an empty tile on the grid. The policy: the catalog is
    /// authoritative for folder content (unknown shortcuts are deleted from them, and there are no
    /// **invisible** folder members after pruning), while shortcuts outside the catalog directly on
    /// the grid stay invisible keys.
    ///
    /// D45: a folder that lost shortcuts in pruning (or came from a file with one shortcut,
    /// ``underfilledFolderKeys``) stays if two or more shortcuts are visible; with one it is
    /// **dissolved**: the shortcut takes the folder's cell with its own size
    /// (``dissolveFolder(withKey:)``); with none it disappears. A folder that pruning did not touch
    /// is not affected by the rule (the transitional folder of
    /// ``createFolder(withTile:title:columns:)`` survives a catalog re-registration).
    private func pruneFoldersAgainstCatalog() {
        var affected = underfilledFolderKeys
        underfilledFolderKeys = []
        for index in folderRecords.indices {
            let before = folderRecords[index].tileKeys.count
            folderRecords[index].tileKeys.removeAll { catalogIndex[$0] == nil }
            if folderRecords[index].tileKeys.count != before {
                affected.insert(folderRecords[index].key)
            }
        }

        // The order follows the grid folders, not a set: the push-down cascade is deterministic.
        var removedAny = false
        for key in folderRecords.map({ $0.key }) where affected.contains(key) {
            guard let record = folderRecords.first(where: { $0.key == key }),
                  record.tileKeys.count < TesseraTileStore.minimumFolderTileCount else { continue }
            dissolveFolder(withKey: key)
            removedAny = true
        }
        if removedAny { resolveDissolvedTiles() }
    }

    /// Dissolves a folder structurally: removes it from the model and puts the single remaining
    /// shortcut in its place (D45).
    ///
    /// For pruning against the catalog and loading (user operations compute the same on a set of
    /// placements, ``dissolveFolderIfNeeded(withKey:in:columns:)``). An empty folder simply
    /// disappears. A shortcut with one remaining key takes the folder's index in `gridOrder`, and its
    /// cell is the folder's cell shrunk to the canvas
    /// (``TesseraTileLayoutEngine/clamped(cell:size:columns:)``); if cells already exist, the final
    /// decision is made by ``resolveDissolvedTiles()`` (pushing neighbors).
    ///
    /// - Parameter folderKey: The key of a folder with fewer than two shortcuts.
    private func dissolveFolder(withKey folderKey: String) {
        guard let recordIndex = folderRecords.firstIndex(where: { $0.key == folderKey }) else { return }
        let record = folderRecords.remove(at: recordIndex)
        let folderCell = placementsByKey.removeValue(forKey: folderKey)

        guard let remaining = record.tileKeys.first, record.tileKeys.count == 1 else {
            gridOrder.removeAll { $0 == folderKey }
            return
        }

        // A shortcut cannot also stay on the grid (the "one place" invariant), but a file may be
        // corrupted: the previous record is removed, and the place is the folder's.
        gridOrder.removeAll { $0 == remaining }
        if let position = gridOrder.firstIndex(of: folderKey) {
            gridOrder[position] = remaining
        } else {
            gridOrder.append(remaining)
        }

        if let columns = canvasColumns, columns > 0, let folderCell {
            let cell = TesseraTileLayoutEngine.clamped(
                cell: folderCell,
                size: storedSize(ofKey: remaining),
                columns: columns
            )
            placementsByKey[remaining] = cell
            pendingDissolvedTiles.append((key: remaining, cell: cell))
        }
    }

    /// Finalizes the cells of shortcuts that took the place of dissolved folders (D45): puts each on
    /// the folder cell through `TesseraTileLayoutEngine.inserting`.
    ///
    /// A larger shortcut (wide, large) pushes neighbors down in a cascade (D31), a column that is
    /// too far right shifts left, and a smaller one leaves a hole. If the visible set is not valid
    /// yet (a file with overlaps, or some shortcuts have no cells), the computation is skipped:
    /// ``reconcilePlacements(settled:)`` resolves the collisions. After the computation the model
    /// order is the cell reading order.
    private func resolveDissolvedTiles() {
        let pending = pendingDissolvedTiles
        pendingDissolvedTiles = []
        guard !pending.isEmpty, let columns = canvasColumns, columns > 0 else { return }

        let pendingKeys = Set(pending.map { $0.key })
        var items: [TesseraTilePlacedItem] = []
        for key in visibleGridKeys() where !pendingKeys.contains(key) {
            guard let cell = placementsByKey[key] else { return }
            items.append(TesseraTilePlacedItem(id: AnyHashable(key), size: storedSize(ofKey: key), cell: cell))
        }
        guard TesseraTileLayoutEngine.validate(items, columns: columns).isEmpty else { return }

        for entry in pending where catalogIndex[entry.key] != nil {
            items = TesseraTileLayoutEngine.inserting(
                id: AnyHashable(entry.key),
                size: storedSize(ofKey: entry.key),
                at: entry.cell,
                into: items,
                columns: columns
            )
        }
        for item in items {
            if let key = item.id.base as? String { placementsByKey[key] = item.cell }
        }
        applyVisibleOrder(TesseraTileStore.readingSorted(visibleGridKeys(), by: placementsByKey))
    }

    /// A shortcut with the authoritative size from the store.
    ///
    /// - Parameter descriptor: A catalog record.
    /// - Returns: A copy of the shortcut with its current size.
    private func resolved(_ descriptor: TesseraTileDescriptor) -> TesseraTileDescriptor {
        var copy = descriptor
        copy.size = sizes[TesseraTileStore.storageKey(for: descriptor.id)] ?? descriptor.size
        return copy
    }

    /// Builds the public folder model from an internal record.
    ///
    /// - Parameter record: The internal folder record.
    /// - Returns: The folder with resolved shortcuts and their sizes.
    private func materialize(_ record: FolderRecord) -> TesseraTileFolder {
        TesseraTileFolder(
            id: record.id,
            title: record.title,
            icon: record.icon,
            tiles: record.tileKeys.compactMap { key in
                guard let index = catalogIndex[key] else { return nil }
                return resolved(catalog[index])
            },
            size: record.size
        )
    }

    // MARK: - Canonical identifier keys

    /// The canonical form of an `AnyHashable` identifier for storage and comparison.
    ///
    /// The type goes into the prefix so that `String("1")` and `Int(1)` are not treated as one
    /// shortcut. Other hashable types are encoded through `description`: for persistence this works
    /// only if `description` is stable between launches (it is, for `URL`, for example).
    ///
    /// - Parameter id: The shortcut or folder identifier.
    /// - Returns: A string key.
    private static func storageKey(for id: AnyHashable) -> String {
        switch id.base {
        case let string as String: return "s:" + string
        case let int as Int: return "i:" + String(int)
        case let uuid as UUID: return "u:" + uuid.uuidString
        default: return "o:" + String(describing: id.base)
        }
    }

    /// Restores a folder identifier from a canonical key.
    ///
    /// Folders are created only by TesseraTileStore, so in practice this is always a `String`
    /// (`folder-UUID`); the other branches are for reading old/manual files.
    ///
    /// - Parameter key: A string key from the state file.
    /// - Returns: The identifier for the public model.
    private static func identifier(fromStorageKey key: String) -> AnyHashable {
        if key.hasPrefix("s:") {
            return AnyHashable(String(key.dropFirst(2)))
        }
        if key.hasPrefix("i:"), let value = Int(key.dropFirst(2)) {
            return AnyHashable(value)
        }
        if key.hasPrefix("u:"), let value = UUID(uuidString: String(key.dropFirst(2))) {
            return AnyHashable(value)
        }
        if key.hasPrefix("o:") {
            return AnyHashable(String(key.dropFirst(2)))
        }
        return AnyHashable(key)
    }
}

// MARK: - Cell-based operations (D30–D33)

/// Operations on top-level items **by coordinates**: the engine
/// (`TesseraTileLayoutEngine+Placement`) computes the new cells, and the store applies them as is.
///
/// There is no index-based API (D33): an item's position is its cell, and the reading order is
/// derived. Properties of the operations:
///
/// - holes do not collapse: an item leaving leaves a free cell, and growth and insertion push
///   obstructing tiles down in a cascade (D31);
/// - an operation ends with ``didChange()`` and writes the coordinates the engine computed, without
///   repacking;
/// - the host width `columns` is passed explicitly and also becomes the canvas width
///   (``canvasColumns``). If the saved layout was computed for another width, the first successful
///   operation accepts a repack in reading order (the D32 projection) as the new canvas and applies
///   its edit to it;
/// - the model order (`gridOrder`, which is also the `snapshot().items` order) after an operation is
///   the cell reading order (row, column), and the file writes items in it;
/// - shortcuts outside the catalog (invisible keys) keep their cells but do not take part in
///   collisions;
/// - collapsing empty rows is a separate operation, ``collapseEmptyRows(columns:)``: the edit layer
///   calls it only on drop, and the other operations do not collapse rows;
/// - a folder is never made of 0-1 shortcuts (D45): when an operation removes a shortcut from a
///   folder and one remains, the folder is dissolved, and the remaining shortcut takes its cell with
///   its own size (a larger one pushes neighbors down). The exception is the transitional folder of
///   ``createFolder(withTile:title:columns:)``.
///
/// An operation with invalid input (no item, not in the catalog, `columns <= 0`, host denial)
/// changes nothing and returns `false`; there is exactly one notification and one write per
/// successful operation. Grouping operations ask the host for approval (D14).
extension TesseraTileStore {

    // MARK: Move

    /// Moves a shortcut or folder to a cell (D31).
    ///
    /// The item stands on `cell`, limited by the canvas (a column that is too far right shifts left);
    /// obstructing tiles are pushed down in a cascade (`TesseraTileLayoutEngine.inserting`). The
    /// place the item vacated stays a hole: there is no repack. Host approval is not asked: this is a
    /// layout operation, not grouping (D14).
    ///
    /// - Parameters:
    ///   - itemID: The shortcut or folder identifier on the grid.
    ///   - cell: The desired top left cell (logical coordinates).
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the layout changed; `false` if the item is not on the grid, is already on
    ///   this cell and nothing moves, or `columns <= 0`.
    @discardableResult
    public func moveItem(_ itemID: AnyHashable, toCell cell: TesseraTileGridPlacement, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TesseraTileStore.storageKey(for: itemID)
        guard visibleGridKeys().contains(key) else { return false }

        let basis = cellBasis(columns: columns)
        let moved = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: storedSize(ofKey: key),
            at: cell,
            into: basis,
            columns: columns
        )
        guard moved != basis else { return false }
        commitCells(moved, columns: columns)
        didChange()
        return true
    }

    /// Moves a shortcut or folder to a new row at the end of the canvas (D33).
    ///
    /// The target is `TesseraTileLayoutEngine.newRowCell`: the first row after the last occupied one
    /// (not counting the moved item itself), column 0. The rest is as in
    /// ``moveItem(_:toCell:columns:)``.
    ///
    /// - Parameters:
    ///   - itemID: The shortcut or folder identifier on the grid.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the layout changed.
    @discardableResult
    public func moveItemToNewRow(_ itemID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TesseraTileStore.storageKey(for: itemID)
        guard visibleGridKeys().contains(key) else { return false }

        let basis = cellBasis(columns: columns)
        let cell = TesseraTileLayoutEngine.newRowCell(
            size: storedSize(ofKey: key),
            columns: columns,
            placements: basis,
            excluding: AnyHashable(key)
        )
        let moved = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: storedSize(ofKey: key),
            at: cell,
            into: basis,
            columns: columns
        )
        guard moved != basis else { return false }
        commitCells(moved, columns: columns)
        didChange()
        return true
    }

    // MARK: Size

    /// Changes the size of a shortcut or folder in place (D15, D31).
    ///
    /// The anchor cell stays (if the new width does not fit, the column shifts left); growth pushes
    /// obstructing tiles down in a cascade (`TesseraTileLayoutEngine.resizing`), shrinking leaves a
    /// hole. A shortcut in a folder or off the grid just changes its authoritative size; the cells
    /// do not change.
    ///
    /// - Parameters:
    ///   - itemID: The shortcut or folder identifier.
    ///   - size: The new size (D15).
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the size changed; `false` if there is no item, the size is the same, or
    ///   `columns <= 0`.
    @discardableResult
    public func resize(_ itemID: AnyHashable, to size: TesseraTileSize, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TesseraTileStore.storageKey(for: itemID)

        let folderIndex = folderRecords.firstIndex { $0.key == key }
        guard folderIndex != nil || catalogIndex[key] != nil else { return false }
        let currentSize: TesseraTileSize? = folderIndex.map { folderRecords[$0].size } ?? sizes[key]
        guard currentSize != size else { return false }

        // The layout is computed before the size is written: the basis carries the previous sizes.
        let basis = cellBasis(columns: columns)
        let resized = TesseraTileLayoutEngine.resizing(
            id: AnyHashable(key),
            to: size,
            in: basis,
            columns: columns
        )

        if let index = folderIndex {
            folderRecords[index].size = size
        } else {
            sizes[key] = size
        }
        commitCells(resized, columns: columns)
        didChange()
        return true
    }

    // MARK: Folders

    /// Creates a folder from two shortcuts in place of the target (D20, D31).
    ///
    /// The folder is always medium (2×2). It stands on the target shortcut's cell through
    /// `TesseraTileLayoutEngine.inserting`: a small target grows to 2×2 and pushes neighbors down in
    /// a cascade, and a column that is too far right shifts left. The target and source shortcuts
    /// leave the top level, and their cells stay holes except those covered by the folder. Inside
    /// the folder the order is: the target, then the source.
    ///
    /// The host approves both steps in turn (`.createFolder`, then `.addToFolder`, as with two
    /// separate calls); the state does not change before both approvals, so on a denial there is
    /// nothing to roll back.
    ///
    /// - Parameters:
    ///   - sourceID: The dragged shortcut on the grid.
    ///   - targetID: The shortcut on the grid in whose place the folder will stand.
    ///   - title: The folder title.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: The operation outcome (`.createDenied` also for invalid input).
    func createFolder(
        from sourceID: AnyHashable,
        onto targetID: AnyHashable,
        title: String = "",
        columns: Int
    ) -> AtomicFolderResult {
        guard columns > 0 else { return .createDenied }
        noteHostColumns(columns)
        let sourceKey = TesseraTileStore.storageKey(for: sourceID)
        let targetKey = TesseraTileStore.storageKey(for: targetID)
        let visible = Set(visibleGridKeys())
        guard sourceKey != targetKey,
              let sourceCatalog = catalogIndex[sourceKey],
              let targetCatalog = catalogIndex[targetKey],
              visible.contains(sourceKey), visible.contains(targetKey) else {
            return .createDenied
        }

        let basis = cellBasis(columns: columns)
        guard let targetItem = basis.first(where: { $0.id == AnyHashable(targetKey) }) else {
            return .createDenied
        }

        let folderID = AnyHashable("folder-" + UUID().uuidString)
        var record = FolderRecord(
            key: TesseraTileStore.storageKey(for: folderID),
            id: folderID,
            title: title,
            size: TesseraTileStore.newFolderSize,
            tileKeys: [targetKey]
        )
        guard approval(nil, catalog[targetCatalog], .createFolder) else { return .createDenied }
        guard approval(materialize(record), catalog[sourceCatalog], .addToFolder) else { return .addDenied }

        record.tileKeys.append(sourceKey)
        var items = TesseraTileLayoutEngine.removing(id: AnyHashable(sourceKey), from: basis)
        items = TesseraTileLayoutEngine.removing(id: AnyHashable(targetKey), from: items)
        items = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(record.key),
            size: record.size,
            at: targetItem.cell,
            into: items,
            columns: columns
        )

        folderRecords.append(record)
        gridOrder.removeAll { $0 == sourceKey || $0 == targetKey }
        gridOrder.append(record.key)
        commitCells(items, columns: columns)
        didChange()
        return .created(materialize(record))
    }

    /// Creates a folder from one shortcut in its place (D20, D31).
    ///
    /// The folder is always 2×2 and stands on the shortcut's cell through
    /// `TesseraTileLayoutEngine.inserting`: neighbors are pushed down in a cascade. The host approves
    /// creation (`.createFolder`).
    ///
    /// D45: a folder of one shortcut is a **transitional** state: the host must add a second shortcut
    /// to it right after (``addToFolder(_:folderID:columns:)``). The store enforces the "a folder is
    /// never made of 0-1 shortcuts" rule when shortcuts are **removed** from a folder and when a file
    /// is loaded; a one-shortcut folder is not dissolved on its own before that (and survives
    /// ``setCatalog(_:)``).
    ///
    /// - Parameters:
    ///   - tileID: The shortcut on the grid that becomes the first content of the folder.
    ///   - title: The folder title.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: The created folder, or `nil` (no shortcut on the grid, `columns <= 0`, or a host
    ///   denial).
    @discardableResult
    public func createFolder(withTile tileID: AnyHashable, title: String = "", columns: Int) -> TesseraTileFolder? {
        guard columns > 0 else { return nil }
        noteHostColumns(columns)
        let tileKey = TesseraTileStore.storageKey(for: tileID)
        guard let catalogPosition = catalogIndex[tileKey],
              visibleGridKeys().contains(tileKey) else {
            return nil
        }
        let basis = cellBasis(columns: columns)
        guard let tileItem = basis.first(where: { $0.id == AnyHashable(tileKey) }) else { return nil }
        guard approval(nil, catalog[catalogPosition], .createFolder) else { return nil }

        let folderID = AnyHashable("folder-" + UUID().uuidString)
        let record = FolderRecord(
            key: TesseraTileStore.storageKey(for: folderID),
            id: folderID,
            title: title,
            size: TesseraTileStore.newFolderSize,
            tileKeys: [tileKey]
        )
        var items = TesseraTileLayoutEngine.removing(id: AnyHashable(tileKey), from: basis)
        items = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(record.key),
            size: record.size,
            at: tileItem.cell,
            into: items,
            columns: columns
        )

        folderRecords.append(record)
        gridOrder.removeAll { $0 == tileKey }
        gridOrder.append(record.key)
        commitCells(items, columns: columns)
        didChange()
        return materialize(record)
    }

    /// Adds a shortcut from the grid to an existing folder.
    ///
    /// The shortcut leaves the top level, and its cell stays a hole (there is no repack); the folder
    /// keeps its cell and size.
    ///
    /// - Parameters:
    ///   - tileID: The shortcut on the grid.
    ///   - folderID: The folder identifier.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the state changed; `false` if the shortcut is already in this or another
    ///   folder, the shortcut/folder does not exist, the host denied it, or `columns <= 0`.
    @discardableResult
    public func addToFolder(_ tileID: AnyHashable, folderID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let tileKey = TesseraTileStore.storageKey(for: tileID)
        let folderKey = TesseraTileStore.storageKey(for: folderID)

        guard let catalogPosition = catalogIndex[tileKey],
              let folderIndex = folderRecords.firstIndex(where: { $0.key == folderKey }),
              !folderRecords[folderIndex].tileKeys.contains(tileKey),
              visibleGridKeys().contains(tileKey) else {
            return false
        }
        guard approval(materialize(folderRecords[folderIndex]), catalog[catalogPosition], .addToFolder) else {
            return false
        }

        let items = TesseraTileLayoutEngine.removing(id: AnyHashable(tileKey), from: cellBasis(columns: columns))
        gridOrder.removeAll { $0 == tileKey }
        folderRecords[folderIndex].tileKeys.append(tileKey)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Takes a shortcut out of a folder onto the grid, onto a cell (D31).
    ///
    /// The shortcut becomes a top-level item with its own size on `cell`, limited by the canvas;
    /// obstructing tiles are pushed down in a cascade. A folder is never made of 0-1 shortcuts (D45):
    /// if one shortcut remains in it, the folder is **dissolved**, and that shortcut takes its cell
    /// with its own size (``dissolveFolderIfNeeded(withKey:in:columns:)``) before the taken-out one
    /// is placed. If the folder became empty (it held one shortcut, the transitional folder of
    /// ``createFolder(withTile:title:columns:)``), it disappears, and its cell stays a hole. The host
    /// approves the move as `.moveBetweenFolders` with a `nil` target folder (D14). The operation is
    /// one model change (one `onChange`).
    ///
    /// - Parameters:
    ///   - tileID: A shortcut that lies in a folder.
    ///   - cell: The desired top left cell.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the state changed; `false` if the shortcut is not in a folder, the host
    ///   denied it, or `columns <= 0`.
    @discardableResult
    public func extractFromFolder(_ tileID: AnyHashable, toCell cell: TesseraTileGridPlacement, columns: Int) -> Bool {
        performExtract(tileID, cell: cell, columns: columns)
    }

    /// Takes a shortcut out of a folder into a new row at the end of the canvas (D33).
    ///
    /// Like ``extractFromFolder(_:toCell:columns:)``, but the cell is the first row after the last
    /// occupied one, column 0. A folder that dissolved (D45) or disappeared does not count in the
    /// row computation: the remaining shortcut stands on its cell with its own size, and the row is
    /// computed with it already.
    ///
    /// - Parameters:
    ///   - tileID: A shortcut that lies in a folder.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the state changed.
    @discardableResult
    public func extractFromFolderToNewRow(_ tileID: AnyHashable, columns: Int) -> Bool {
        performExtract(tileID, cell: nil, columns: columns)
    }

    /// Moves a shortcut from one folder to another without touching the rest of the layout.
    ///
    /// A source folder left with one shortcut is **dissolved** (D45): the remaining shortcut takes
    /// its cell with its own size; a larger shortcut pushes neighbors down (D31), a smaller one
    /// leaves a hole. A folder that became empty (a transitional one-shortcut folder) disappears,
    /// and its cell stays a hole (collapsing is ``collapseEmptyRows(columns:)``). The host approves
    /// the move as `.moveBetweenFolders` (D14). Returning to the start screen is
    /// ``extractFromFolder(_:toCell:columns:)``.
    ///
    /// - Parameters:
    ///   - tileID: A shortcut that lies in a folder.
    ///   - folderID: The target folder.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the state changed; `false` if the shortcut is in no folder, the target
    ///   equals the current folder or does not exist, the host denied it, or `columns <= 0`.
    @discardableResult
    public func moveBetweenFolders(_ tileID: AnyHashable, to folderID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let tileKey = TesseraTileStore.storageKey(for: tileID)
        let folderKey = TesseraTileStore.storageKey(for: folderID)

        guard let catalogPosition = catalogIndex[tileKey],
              let sourceIndex = folderRecords.firstIndex(where: { $0.tileKeys.contains(tileKey) }),
              let targetIndex = folderRecords.firstIndex(where: { $0.key == folderKey }),
              targetIndex != sourceIndex else {
            return false
        }
        guard approval(materialize(folderRecords[targetIndex]), catalog[catalogPosition], .moveBetweenFolders) else {
            return false
        }

        var items = cellBasis(columns: columns)
        let sourceKey = folderRecords[sourceIndex].key
        folderRecords[sourceIndex].tileKeys.removeAll { $0 == tileKey }
        folderRecords[targetIndex].tileKeys.append(tileKey)
        // D45: fewer than two remain in the source folder, so it is dissolved.
        dissolveFolderIfNeeded(withKey: sourceKey, in: &items, columns: columns)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Renames a folder (D35; as in Windows 10 Mobile).
    ///
    /// The title is normalized (``TesseraTileFolder/normalizedTitle(_:)``: whitespace and newlines at
    /// the edges are dropped, newlines inside become spaces, the length is at most
    /// ``TesseraTileFolder/maximumTitleLength``). An empty title returns the **default title**, the
    /// same one a new folder gets (`folderScreen.defaultTitle`, en/ru; the editor substitutes the
    /// same, and `TesseraTileEditConfiguration.folderTitle` only overrides it). The size, cell and
    /// content of the folder do not change; the operation does not touch the layout, so it does not
    /// need the grid width. Host approval (D14) is not needed: the title does not change folder
    /// composition.
    ///
    /// The state is saved (``autosaves``) and reported to subscribers with a single ``onChange``.
    ///
    /// - Parameters:
    ///   - folderID: The folder identifier on the start screen.
    ///   - newTitle: The new title (as typed by the user).
    /// - Returns: `true` if the title changed; `false` if there is no folder or the normalized title
    ///   equals the current one (no save and no `onChange`).
    @discardableResult
    public func renameFolder(_ folderID: AnyHashable, to newTitle: String) -> Bool {
        let folderKey = TesseraTileStore.storageKey(for: folderID)
        guard let index = folderRecords.firstIndex(where: { $0.key == folderKey }) else {
            return false
        }
        var title = TesseraTileFolder.normalizedTitle(newTitle)
        if title.isEmpty {
            title = TesseraStartScreenStrings.string(.folderScreenDefaultTitle)
        }
        guard folderRecords[index].title != title else { return false }

        folderRecords[index].title = title
        didChange()
        return true
    }

    /// Reorders a shortcut inside a folder (D40; as in Windows 10 Mobile).
    ///
    /// The order of shortcuts in a folder is the order of `FolderRecord.tileKeys`: it also goes into
    /// the file, into the snapshot's ``TesseraTileFolder/tiles`` and into the preview/panel. The
    /// operation changes only that: sizes, cells and folder composition do not change, and the grid
    /// width is not needed. Host approval (D14) is not asked, because the folder composition does not
    /// change (unlike a move between folders).
    ///
    /// `toIndex` is an index **among the folder's visible shortcuts** (those that are in the catalog
    /// and reach ``TesseraTileFolder/tiles``); a value outside `0...count - 1` is clamped to the
    /// bound. Invisible members (keys that are not in the catalog: before the first
    /// ``setCatalog(_:)`` after ``load()``) do not take part in the computation and stay in their
    /// places in the record. After the catalog is registered, pruning removes them anyway (D45), so
    /// in practice a folder without visible members simply refuses.
    ///
    /// The state is saved (``autosaves``) and reported to subscribers with a single ``onChange``.
    ///
    /// - Parameters:
    ///   - tileID: The identifier of a shortcut lying in this folder.
    ///   - folderID: The folder identifier on the start screen.
    ///   - toIndex: The new index among the folder's shortcuts.
    /// - Returns: `true` if the order changed; `false` if there is no folder/shortcut, the shortcut
    ///   is not in this folder, or the position does not change (no save and no `onChange`).
    @discardableResult
    public func moveWithinFolder(_ tileID: AnyHashable, folderID: AnyHashable, toIndex: Int) -> Bool {
        let folderKey = TesseraTileStore.storageKey(for: folderID)
        let tileKey = TesseraTileStore.storageKey(for: tileID)
        guard let folderIndex = folderRecords.firstIndex(where: { $0.key == folderKey }) else {
            return false
        }
        let keys = folderRecords[folderIndex].tileKeys
        var visible = keys.filter { catalogIndex[$0] != nil }
        guard let from = visible.firstIndex(of: tileKey), visible.count >= 2 else { return false }
        let destination = min(max(toIndex, 0), visible.count - 1)
        guard destination != from else { return false }

        visible.remove(at: from)
        visible.insert(tileKey, at: destination)
        // Invisible keys stay in their places: the visible slots are filled with the new order in
        // turn.
        var next = visible.makeIterator()
        folderRecords[folderIndex].tileKeys = keys.map { catalogIndex[$0] != nil ? (next.next() ?? $0) : $0 }
        didChange()
        return true
    }

    // MARK: Pinning

    /// Unpins a shortcut: leaving the grid leaves a hole (D30).
    ///
    /// A shortcut on the grid just leaves, and its cell stays free. A shortcut from a folder leaves
    /// it; if one shortcut remains in the folder, it is **dissolved** (D45): the remaining shortcut
    /// takes the folder's cell with its own size (``dissolveFolderIfNeeded(withKey:in:columns:)``).
    /// An emptied folder (a transitional one-shortcut one) disappears, and its cell stays a hole.
    /// Host approval is not asked (D14: unpinning is not grouping).
    ///
    /// - Parameters:
    ///   - tileID: The shortcut identifier.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the state changed.
    @discardableResult
    public func unpin(_ tileID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TesseraTileStore.storageKey(for: tileID)

        if let index = folderRecords.firstIndex(where: { $0.tileKeys.contains(key) }) {
            var items = cellBasis(columns: columns)
            let folderKey = folderRecords[index].key
            folderRecords[index].tileKeys.removeAll { $0 == key }
            // D45: fewer than two remain in the folder, so it is dissolved.
            dissolveFolderIfNeeded(withKey: folderKey, in: &items, columns: columns)
            commitCells(items, columns: columns)
            didChange()
            return true
        }

        guard catalogIndex[key] != nil, gridOrder.contains(key) else { return false }
        let items = TesseraTileLayoutEngine.removing(id: AnyHashable(key), from: cellBasis(columns: columns))
        gridOrder.removeAll { $0 == key }
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Pins a shortcut on the grid in a new row at the end of the canvas (D33).
    ///
    /// The size comes from the saved sizes or the descriptor default (D15); on a narrow grid the
    /// engine shrinks the tile (`fittingSize`), and the column is 0.
    ///
    /// - Parameters:
    ///   - tileID: The identifier of a shortcut from the catalog.
    ///   - columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the shortcut is pinned; `false` if it is not in the catalog, is already
    ///   on the grid or in a folder, or `columns <= 0`.
    @discardableResult
    public func pinTile(_ tileID: AnyHashable, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TesseraTileStore.storageKey(for: tileID)
        guard let catalogPosition = catalogIndex[key], !gridOrder.contains(key),
              folderContaining(tileID) == nil else { return false }

        if sizes[key] == nil {
            sizes[key] = catalog[catalogPosition].size
        }
        let size = storedSize(ofKey: key)
        let basis = cellBasis(columns: columns)
        let cell = TesseraTileLayoutEngine.newRowCell(size: size, columns: columns, placements: basis)
        let items = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: size,
            at: cell,
            into: basis,
            columns: columns
        )
        gridOrder.append(key)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    // MARK: Collapse

    /// Collapses the empty rows of the canvas (D31).
    ///
    /// A row is removed only if no item covers it (tall tiles cover all their rows). The edit layer
    /// calls it **only on drop**, never during a drag. Idempotent: on a layout without empty rows it
    /// changes nothing, does not write the file and does not notify.
    ///
    /// - Parameter columns: The host grid column count, greater than zero.
    /// - Returns: `true` if the layout changed.
    @discardableResult
    public func collapseEmptyRows(columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)

        let basis = cellBasis(columns: columns)
        let collapsed = TesseraTileLayoutEngine.collapsingEmptyRows(in: basis, columns: columns)
        guard collapsed != basis else { return false }
        commitCells(collapsed, columns: columns)
        didChange()
        return true
    }

    // MARK: Internals

    /// The common part of taking a shortcut out of a folder: a cell or a new row.
    ///
    /// - Parameters:
    ///   - tileID: A shortcut that lies in a folder.
    ///   - cell: The cell; `nil` means a new row at the end of the canvas.
    ///   - columns: The host grid column count.
    private func performExtract(_ tileID: AnyHashable, cell: TesseraTileGridPlacement?, columns: Int) -> Bool {
        guard columns > 0 else { return false }
        noteHostColumns(columns)
        let key = TesseraTileStore.storageKey(for: tileID)

        guard let catalogPosition = catalogIndex[key],
              let sourceIndex = folderRecords.firstIndex(where: { $0.tileKeys.contains(key) }) else {
            return false
        }
        guard approval(nil, catalog[catalogPosition], .moveBetweenFolders) else { return false }

        var items = cellBasis(columns: columns)
        let folderKey = folderRecords[sourceIndex].key
        folderRecords[sourceIndex].tileKeys.removeAll { $0 == key }
        // D45: a folder with one shortcut is dissolved before the taken-out one is placed: the
        // remaining shortcut takes the folder's cell, and the taken-out one goes to `cell` by the
        // usual rules (it may also land on the folder's cell, and then the remaining one moves down).
        dissolveFolderIfNeeded(withKey: folderKey, in: &items, columns: columns)

        let size = storedSize(ofKey: key)
        let target = cell ?? TesseraTileLayoutEngine.newRowCell(size: size, columns: columns, placements: items)
        items = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(key),
            size: size,
            at: target,
            into: items,
            columns: columns
        )
        gridOrder.append(key)
        commitCells(items, columns: columns)
        didChange()
        return true
    }

    /// Dissolves a folder that has fewer than two shortcuts left after one was removed (D45).
    ///
    /// Does nothing if the folder has enough shortcuts. Otherwise the folder disappears from the
    /// model and from the `items` set; the single remaining visible shortcut stands on the **folder's
    /// cell with its own size** through `TesseraTileLayoutEngine.inserting`: a larger one (wide,
    /// large) pushes neighbors down in a cascade (D31), a column that is too far right shifts left,
    /// and a smaller one leaves a hole. The shortcut size is the store's authoritative size
    /// (``storedSize(ofKey:)``), so the user's choice is not lost. An empty folder simply
    /// disappears.
    ///
    /// The `gridOrder` record and the reading order are set by ``commitCells(_:columns:)``; the
    /// caller must call it (and ``didChange()``) afterwards. In operations a folder has no invisible
    /// members: the catalog is authoritative (``pruneFoldersAgainstCatalog()``).
    ///
    /// - Parameters:
    ///   - folderKey: The key of the folder from which a shortcut was just removed.
    ///   - items: The working set of placements; updated in place.
    ///   - columns: The canvas width.
    /// - Returns: The key of the shortcut that took the folder's place, or `nil` (the folder stayed
    ///   or disappeared empty).
    @discardableResult
    private func dissolveFolderIfNeeded(
        withKey folderKey: String,
        in items: inout [TesseraTilePlacedItem],
        columns: Int
    ) -> String? {
        guard let index = folderRecords.firstIndex(where: { $0.key == folderKey }),
              folderRecords[index].tileKeys.count < TesseraTileStore.minimumFolderTileCount else {
            return nil
        }
        let record = folderRecords.remove(at: index)
        gridOrder.removeAll { $0 == folderKey }
        let folderCell = items.first { $0.id == AnyHashable(folderKey) }?.cell
        items = TesseraTileLayoutEngine.removing(id: AnyHashable(folderKey), from: items)

        guard record.tileKeys.count == 1, let remaining = record.tileKeys.first,
              catalogIndex[remaining] != nil, let cell = folderCell else {
            return nil
        }
        items = TesseraTileLayoutEngine.inserting(
            id: AnyHashable(remaining),
            size: storedSize(ofKey: remaining),
            at: cell,
            into: items,
            columns: columns
        )
        gridOrder.append(remaining)
        return remaining
    }

    /// The working set of placements of visible items for width `columns`: the starting point of
    /// every cell-based operation.
    ///
    /// If the canvas has the same width, the saved cells (with holes) are used; otherwise (D32) the
    /// ``placements(forColumns:)`` projection: a repack in reading order without holes, and the
    /// operation is applied to it. The method itself **changes nothing**: the canvas is accepted by
    /// ``commitCells(_:columns:)`` only after a successful operation, so a denial does not overwrite
    /// the file. Sizes are the requested ones (the engine shrinks the footprint). A set that fails
    /// `validate` is replaced by the projection.
    ///
    /// - Parameter columns: The column count, greater than zero.
    /// - Returns: Items in grid order; the identifier is the canonical key.
    private func cellBasis(columns: Int) -> [TesseraTilePlacedItem] {
        let keys = visibleGridKeys()

        func build(from cells: [String: TesseraTileGridPlacement]) -> [TesseraTilePlacedItem] {
            var items: [TesseraTilePlacedItem] = []
            items.reserveCapacity(keys.count)
            var missing: [String] = []
            for key in keys {
                if let cell = cells[key] {
                    items.append(TesseraTilePlacedItem(id: AnyHashable(key), size: storedSize(ofKey: key), cell: cell))
                } else {
                    missing.append(key)
                }
            }
            // Safety net: a visible key has no cell, so it goes to a new row at the end.
            for key in missing {
                let size = storedSize(ofKey: key)
                let cell = TesseraTileLayoutEngine.newRowCell(size: size, columns: columns, placements: items)
                items = TesseraTileLayoutEngine.inserting(
                    id: AnyHashable(key), size: size, at: cell, into: items, columns: columns
                )
            }
            return items
        }

        let stored = canvasColumns == columns ? placementsByKey : projectedPlacements(columns: columns)
        let items = build(from: stored)
        if TesseraTileLayoutEngine.validate(items, columns: columns).isEmpty {
            return items
        }
        return build(from: projectedPlacements(columns: columns))
    }

    /// Accepts the computed layout as the model: the cells of visible items, the canvas width and the
    /// reading order.
    ///
    /// The cells of invisible keys are kept (they do not take part in collisions), and those that do
    /// not fit the new width get a place at the end (``reconcilePlacements(settled:)``). `gridOrder`
    /// for visible items becomes the cell reading order; structural `gridOrder` edits (a shortcut
    /// leaving, a new folder) are made by the caller before the call. The notification and the write
    /// are up to the caller (``didChange()``).
    ///
    /// - Parameters:
    ///   - items: The placements of all visible items after the operation.
    ///   - columns: The canvas width (the host width).
    private func commitCells(_ items: [TesseraTilePlacedItem], columns: Int) {
        var next: [String: TesseraTileGridPlacement] = [:]
        for item in items {
            if let key = item.id.base as? String { next[key] = item.cell }
        }
        let visibleSet = Set(visibleGridKeys())
        for key in gridOrder where !visibleSet.contains(key) {
            if let placement = placementsByKey[key] { next[key] = placement }
        }
        placementsByKey = next
        canvasColumns = columns

        let ordered = TesseraTileStore.readingSorted(items.compactMap { $0.id.base as? String }, by: next)
        applyVisibleOrder(ordered)
        reconcilePlacements()
    }
}

// MARK: - Internal records

/// The internal folder record: shortcuts are stored by keys, not as copies.
///
/// Copies of `TesseraTileDescriptor` inside a folder would go stale on catalog re-registration (new
/// captions/icons), so the public ``TesseraTileFolder`` is built on request.
private struct FolderRecord {

    /// The canonical folder key (the folder stands in the grid order under it).
    var key: String

    /// The folder identifier for the public model.
    var id: AnyHashable

    /// The folder caption.
    var title: String

    /// The preview icon; not written to the file (runtime state).
    var icon: UIImage?

    /// The size of the folder tile.
    var size: TesseraTileSize

    /// The canonical shortcut keys in display order.
    var tileKeys: [String]
}

// MARK: - State JSON schema

/// The versioned state document (read only by TesseraTileStore).
///
/// The shortcut catalog does not go into the file: `action` is a closure and cannot be serialized.
/// Only the layout is stored: order, cells and canvas width (version 2), sizes, folders. Item keys
/// are canonical strings (see `TesseraTileStore.storageKey(for:)`), so the schema does not depend on
/// the type of the `AnyHashable` identifier.
private struct TileStoreDocument: Codable {

    /// The schema version; a record is read only if it is not newer than the current one.
    var version: Int

    /// The canvas width in units that `row`/`column` were computed for (version 2).
    ///
    /// The field is absent in a version 1 file and in the "not laid out" state.
    var columns: Int?

    /// The grid item order.
    var items: [Item]

    /// The shortcut sizes by canonical keys.
    var sizes: [String: TesseraTileSize]

    /// Folders with their content and sizes.
    var folders: [Folder]

    /// A grid order item.
    struct Item: Codable {

        /// What the item is: a shortcut or a folder.
        enum Kind: String, Codable {
            case tile
            case folder
        }

        var kind: Kind
        var key: String

        /// The row of the item's top left corner (version 2).
        var row: Int?

        /// The column of the item's top left corner (version 2).
        var column: Int?
    }

    /// A folder in the state file.
    struct Folder: Codable {
        var key: String
        var title: String
        var size: TesseraTileSize
        var tileKeys: [String]
    }
}
#endif
