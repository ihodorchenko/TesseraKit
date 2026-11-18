//
//  TileCollectionViewLayout.swift
//  TesseraStartScreen
//
//  The custom layout of the start screen tile grid.
//  Design document: docs/STARTSCREEN-IOS-DESIGN.md, §3 (the tile grid: the unit formula, unit
//  coordinates, holes are allowed, and tiles stand on explicit cells; implementation: a custom
//  UICollectionViewLayout, attributes are computed from the model, changes go through invalidation
//  with a context), §5 (edit mode: resize/reorder change the model cells and invalidate the layout),
//  §9 (Accessibility: RTL, the grid is mirrored by the view layer) and §14 (D15: four sizes, 1×1,
//  2×2, 4×2, 4×4).
//
//  Responsibilities: the layout does not store start screen state and knows nothing about
//  shortcuts/folders. It receives from TesseraTileGridView a list of "identifier - size" pairs,
//  converts them to unit coordinates through TesseraTileLayoutEngine (pure functions) and lays them
//  out as frames in points. Pixel geometry (width, margins, gaps) is the only thing this file owns;
//  order, sizes and folders come from the model (TesseraTileStore -> snapshot).
//
//  Performance discipline (§3, and CORE-IOS-DESIGN.md §2): geometry may be recomputed only in a
//  layout pass (prepare/collectionViewContentSize) or on explicit invalidation. None of it is
//  called in scrollViewDidScroll; TesseraTileGridView is responsible for that.
//

#if canImport(UIKit)
import UIKit

// MARK: - Invalidation reason

/// The reason for recomputing the layout (an internal detail that does not leave the module).
///
/// It is needed so that invalidation carries context: `resize` and `reorder` are not "a new data
/// set" but a repacking of the same set (§5). From the context UICollectionView understands that
/// cells need not be reloaded and only the attributes must be recomputed; the list of items for
/// that comes in ``TesseraTileLayoutInvalidationContext``.
enum TesseraTileLayoutInvalidationReason: Equatable {

    /// The set/sizes of the grid items changed: the model was repacked.
    case items

    /// Only the geometry changed (columns, margins, gap, reading direction): the set is the same,
    /// the frames may have moved.
    case geometry
}

// MARK: - Invalidation context

/// The grid layout invalidation context (§3, §5).
///
/// UICollectionView supports invalidation with a context (`invalidateLayout(with:)`): the context
/// lets it say *what* changed and avoid reloading cells when only a frame changed. Here the context
/// carries the reason and the item identifiers in grid order, so that a cell or the edit
/// coordinator can match attributes to the model without reading the snapshot again.
///
/// The class is internal: from outside, invalidation is triggered only by `TesseraTileGridView`, and
/// no public API for the context is needed (the minimal public surface rule, AGENTS.md).
final class TesseraTileLayoutInvalidationContext: UICollectionViewLayoutInvalidationContext {

    /// What exactly caused the recomputation.
    let reason: TesseraTileLayoutInvalidationReason

    /// The item identifiers in grid order at the time of invalidation.
    let itemIdentifiers: [AnyHashable]

    /// Creates an invalidation context.
    ///
    /// - Parameters:
    ///   - reason: The reason for recomputation.
    ///   - itemIdentifiers: The item identifiers in grid order.
    init(reason: TesseraTileLayoutInvalidationReason, itemIdentifiers: [AnyHashable]) {
        self.reason = reason
        self.itemIdentifiers = itemIdentifiers
        super.init()
    }
}

// MARK: - Tile attributes

/// Grid cell attributes: a frame plus the model it belongs to.
///
/// The ``UICollectionViewLayoutAttributes`` subclass is needed so that the edit coordinator and
/// tests can get the tile identifier and size straight from the attributes (for example, when
/// dragging and determining visibility), without manually rebuilding the "index -> item" mapping.
/// The class is internal: the geometry is exposed through `TesseraTileGridView.frame(forItemID:)`.
final class TesseraTileLayoutAttributes: UICollectionViewLayoutAttributes {

    /// The identifier of the shortcut or folder the attributes belong to.
    var itemID: AnyHashable?

    /// The tile size from the model (D15): the requested one, before a possible shrink to a narrow
    /// grid. The cell needs it to choose a font, and the coordinator needs it for resize.
    var tileSize: TesseraTileSize = .medium

    /// Copying is required: UICollectionView copies attributes during animations and reuse, and
    /// without the override the custom fields would be lost in the copy.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! TesseraTileLayoutAttributes
        copy.itemID = itemID
        copy.tileSize = tileSize
        return copy
    }
}

// MARK: - Layout

/// The tile grid layout on top of ``TesseraTileLayoutEngine``
/// (docs/STARTSCREEN-IOS-DESIGN.md §3; D15 in docs/DECISIONS.md).
///
/// ## How the geometry is computed (§3)
///
/// 1. Available width = `bounds.width − contentInsets.left − contentInsets.right`; the content edges
///    and the top margin are rounded to a pixel.
/// 2. The unit = ``TesseraTileLayoutEngine/unit(screenWidth:columns:gaps:scale:)``: the §3 formula,
///    rounded down to a pixel (the collection's `displayScale`, with `UIScreen.main.scale` as a
///    fallback); the gap between columns is ``itemSpacing`` (`gaps` in the §3 formula), also on the
///    pixel grid. The remaining width is split equally into margins: the grid is centered
///    (``TesseraTileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``).
/// 3. ``TesseraTileLayoutEngine/pack(items:columns:unit:)`` packs tiles strictly compactly into unit
///    coordinates. If the grid passed a table of explicit cells (``TesseraTileGridPlacementTable``)
///    and it is complete and valid for the current columns, the slots come from
///    ``TesseraTileLayoutEngine/slots(placements:columns:unit:fitting:)`` instead of packing: tiles
///    stand on their cells, holes are preserved, and there is no backfill. An incomplete, invalid
///    table, or one computed for another width, is ignored entirely: the layout uses packing, as it
///    did before explicit cells.
/// 4. ``TesseraTileLayoutEngine/rect(for:unit:gap:origin:)`` converts a slot into a frame in points;
///    the inner gaps are part of the frame of a wide/large tile. All frames are multiples of
///    `1 / scale`.
///
/// The position in unit coordinates is stored in the engine, so a screen rotation changes only the
/// unit: `prepare()` recomputes the frames without touching the model.
///
/// ## RTL (§9)
///
/// The engine works in LTR coordinates. Mirroring the grid is the job of the view layer: here the
/// frame of each slot is flipped horizontally if the collection's reading direction is right to
/// left. The item order does not change: item `0` stays first in reading order and visually ends up
/// on the right.
///
/// ## Invalidation (§3, §5)
///
/// - a width/height or reading direction change goes through `shouldInvalidateLayout` (sizes only:
///   a `contentOffset` change during scrolling does not invalidate, otherwise the layout would be
///   recomputed on every frame);
/// - resize/reorder and a set change are explicit invalidation with
///   ``TesseraTileLayoutInvalidationContext`` through ``setItems(_:reason:)``; the animation is
///   done by `TesseraTileGridView`.
///
/// ## The expanded folder panel (D17)
///
/// Expansion inserts the ``TesseraTileGridItem/folderContent(_:)`` panel **after the folder band**:
/// the rows of the folder tile, extended downward by the tiles that start in those rows and end
/// lower (``TesseraTileLayoutEngine/folderBandEndRow(for:in:)``); the tile itself stays in the set
/// and on screen (the item count grows by one). Therefore:
///
/// - the panel stretches over the full content width (all ``columns`` columns) and takes a
///   full-width row right under the folder band;
/// - its height in points is computed by
///   ``TesseraTileLayoutEngine/panelHeight(tileCount:width:columns:spacing:scale:)``: the unit and
///   the gap of the panel shortcuts are the same as the grid's (``itemSpacing``, pixel alignment);
///   the layout does not store `TesseraTileFolder`, only the shortcut count;
/// - the base packing does not change: the folder tile and its neighbors get the same slots as in
///   the collapsed grid, and everything that starts below the band is packed again and ends up under
///   the panel. With explicit cells there is no repack: the rows below the band stay on their cells,
///   holes between them are preserved, and the whole lower part shifts down by the panel height
///   and the gap
///   (``TesseraTileLayoutEngine/rowsBelowOffset(placedSlots:expandedFolderID:panelHeight:spacing:)``);
/// - band items (for example, a small tile to the right of a 2×2 folder, or a 2×2 shortcut that
///   starts in the folder rows and ends lower) stay in place: the panel starts below them and does
///   not intersect anything;
/// - the panel identifier equals the folder identifier, so the panel is not addressable as a model
///   item (``frame(forItemID:)`` by the folder identifier returns the frame of the folder tile
///   itself).
///
/// ## The "folder <-> panel" animation (D17)
///
/// The grid performs a single batch update: `insertItems` of the panel on expansion and
/// `deleteItems` of the panel on closing. The folder tile is neither deleted nor inserted, so its
/// attributes need no animation. The layout provides the panel attributes explicitly:
///
/// - on expansion the panel appears with height 0 (``initialLayoutAttributesForAppearingItem``) and
///   grows to ``panelHeight``; the top edge and the width do not change, so the items under the
///   panel simultaneously shift down;
/// - on closing the panel collapses to zero height (``finalLayoutAttributesForDisappearingItem``),
///   and the items under it rise while the folder tile stays in place.
///
/// The zero panel height is provided only for the duration of a batch update in which the panel
/// really appears or is removed (`prepare(forCollectionViewUpdates:)`). On `reloadData` (Reduce
/// Motion, a grid outside a window) UICollectionView does not animate the insertion, and the panel
/// must get its full size immediately, otherwise a zero-height artifact would show for a frame.
///
/// ## A narrow grid
///
/// D15 requires four sizes, and ``columns`` is 6 by default (D26). If the host sets fewer columns
/// than a tile's width, the layout does not drop the tile (otherwise the "index -> item" mapping
/// would drift) but shrinks its footprint: 2×2 at 2-3 columns and 1×1 at one. This is a degradation
/// of geometry, not a model change: `TesseraTileStore` and the cell still see the original
/// ``TesseraTileSize``.
final class TesseraTileCollectionViewLayout: UICollectionViewLayout {

    // MARK: - Configuration

    /// The grid column count (6 by default, D26, ``TesseraTileLayoutEngine/defaultColumns``). Values
    /// below 1 are clamped to 1; see "A narrow grid" in the class documentation.
    var columns: Int {
        get { columnCount }
        set {
            let clamped = max(1, newValue)
            guard clamped != columnCount else { return }
            columnCount = clamped
            invalidateGeometry()
        }
    }

    /// The outer grid margins in points (`margins` in the unit formula, §3).
    ///
    /// Negative and non-numeric values are treated as 0 in the computation. The margins are set
    /// here, not through `collectionView.contentInset`: the layout itself computes the full content
    /// width, and two sources of margins must not compete.
    var contentInsets: UIEdgeInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16) {
        didSet {
            guard contentInsets != oldValue else { return }
            invalidateGeometry()
        }
    }

    /// The gap between neighboring grid units in points (`gaps` in the §3 formula).
    ///
    /// A negative value is treated as 0. The gap is part of both the unit formula and the frame of
    /// each tile: wide tiles do not "eat" the inner gaps.
    var itemSpacing: CGFloat = 8 {
        didSet {
            guard itemSpacing != oldValue else { return }
            invalidateGeometry()
        }
    }

    /// The screen scale for pixel alignment, used instead of the collection's `displayScale`.
    ///
    /// `nil` means the scale is taken from the collection's `traitCollection.displayScale`
    /// (``resolvedDisplayScale(_:)``). An internal input for tests: a layout without a window cannot
    /// be moved to another scale any other way. `0` means no alignment.
    var displayScaleOverride: CGFloat? {
        didSet {
            guard displayScaleOverride != oldValue else { return }
            invalidateGeometry()
        }
    }

    /// The scale for pixel alignment by `displayScale`.
    ///
    /// The `displayScale` of a collection without a window may be `0`; then `UIScreen.main.scale` is
    /// used, and if that is not set either, there is no alignment (`0`). The same rule is used by
    /// the expanded folder panel cell: its shortcuts must land on the same pixel columns as the grid
    /// tiles.
    ///
    /// - Parameter traitScale: `traitCollection.displayScale`.
    /// - Returns: A positive scale, or `0` ("do not align").
    static func resolvedDisplayScale(_ traitScale: CGFloat) -> CGFloat {
        if traitScale.isFinite, traitScale > 0 {
            return traitScale
        }
        let screenScale = UIScreen.main.scale
        return screenScale.isFinite && screenScale > 0 ? screenScale : 0
    }

    // MARK: - Geometry queries

    /// The current column count; stored separately so that `columns` can be a computed property
    /// clamped to 1.
    private var columnCount: Int = TesseraTileLayoutEngine.defaultColumns

    /// The item identifiers in grid order (the index matches `IndexPath.item`). Updated in the
    /// layout pass.
    ///
    /// With an expanded folder the set contains both the folder tile and the panel
    /// (``TesseraTileGridItem/folderContent(_:)``), so the folder identifier occurs twice: for the
    /// tile and for the panel.
    private(set) var itemIdentifiers: [AnyHashable] = []

    /// The item frame in the collection's content coordinates.
    ///
    /// Content coordinates are the same ones in which UICollectionView stores cell frames: `(0, 0)`
    /// is the top left corner of the content, ignoring `contentOffset`. For the grid view's
    /// coordinates use `TesseraTileGridView.frame(forItemID:)`.
    ///
    /// The expanded folder panel shares the identifier with the folder tile but is not addressable
    /// as a model item: the folder identifier returns the frame of the tile itself (it stays in the
    /// set while the folder is expanded).
    ///
    /// - Parameter id: The shortcut or folder identifier.
    /// - Returns: The frame in points, or `nil` if the item is not in the current set.
    func frame(forItemID id: AnyHashable) -> CGRect? {
        ensureGeometry()
        guard let index = indexByID[id], attributesByIndex.indices.contains(index) else {
            return nil
        }
        return attributesByIndex[index].frame
    }

    /// The item frame by index in grid order (content coordinates).
    ///
    /// - Parameter index: The item index; out-of-range values give `nil`.
    /// - Returns: The frame in points, or `nil`.
    func frame(forItemAt index: Int) -> CGRect? {
        ensureGeometry()
        guard attributesByIndex.indices.contains(index) else { return nil }
        return attributesByIndex[index].frame
    }

    /// The item index in grid order.
    ///
    /// - Parameter id: The shortcut or folder identifier.
    /// - Returns: The index, or `nil` if there is no such item.
    func index(ofItemID id: AnyHashable) -> Int? {
        ensureGeometry()
        return indexByID[id]
    }

    // MARK: - Model

    /// The items in grid order: the identifier, the size model and the expanded folder panel flag.
    ///
    /// Stored as a copy: the layout does not retain `TesseraTileDescriptor` and `TesseraTileFolder`
    /// (they hold closures and `UIImage`); for geometry it needs only the identity, the D15 size,
    /// the explicit cell and the panel shortcut count (the panel height in points depends on it).
    private var layoutItems: [GeometryKey.Item] = []

    /// The declared canvas width of the explicit cell table; `nil` means there is no table or the
    /// width is not declared.
    private var layoutPlacementColumns: Int?

    /// Whether the last geometry rebuild used explicit cells.
    ///
    /// `false` means the layout used order-based packing: there was no table, or it is incomplete,
    /// invalid, or computed for another width. An internal property for fallback tests.
    private(set) var usesExplicitPlacements: Bool = false

    // MARK: - Layout pass state

    /// The key of the last recomputation: everything the geometry depends on.
    private var lastKey: GeometryKey?

    /// The attributes in grid order.
    private var attributesByIndex: [TesseraTileLayoutAttributes] = []

    /// A fast index lookup by identifier.
    private var indexByID: [AnyHashable: Int] = [:]

    /// The last computed content size.
    private var cachedContentSize: CGSize = .zero

    // MARK: - Folder panel animation state (D17)

    /// The index of the expanded folder panel in the current attribute set.
    ///
    /// `nil` if there is no panel or the geometry is not computed yet. Needed to tell a panel
    /// appearing from an ordinary tile.
    private var panelAttributeIndex: Int?

    /// The index of the panel that appears in the current batch update.
    ///
    /// Filled in ``prepare(forCollectionViewUpdates:)`` only for a real insertion; on `reloadData`
    /// it stays `nil` and the panel gets its full height immediately.
    private var appearingPanelIndex: Int?

    /// The frame of a panel that disappeared from the set on the last `setItems`.
    ///
    /// UICollectionView asks for the final attributes of a removed item after the layout has
    /// received the new set: the panel is no longer in it, and without a saved frame there is nothing
    /// to build the collapse from.
    private var disappearingPanel: (index: Int, attributes: TesseraTileLayoutAttributes)?

    // MARK: - Key type

    /// Everything the geometry depends on, as a single value.
    ///
    /// Comparing the key in ``ensureGeometry()`` avoids needless recomputation: UICollectionView may
    /// call `prepare()` more often than the width or the model really changes.
    private struct GeometryKey: Equatable {

        /// The collection's `bounds` size (the width sets the unit, the height only the content
        /// size).
        var boundsSize: CGSize

        /// The reading direction: in RTL the grid is mirrored (§9).
        var direction: UIUserInterfaceLayoutDirection

        /// The effective column count, at least 1.
        var columns: Int

        /// The sanitized outer margins.
        var insets: UIEdgeInsets

        /// The sanitized gap between units.
        var spacing: CGFloat

        /// The pixel alignment scale; `0` means no alignment.
        var scale: CGFloat

        /// The declared canvas width of the explicit cell table; `nil` if not declared or there is
        /// no table.
        var placementColumns: Int?

        /// The items in grid order.
        var items: [Item]

        /// An item on which only the geometry depends.
        struct Item: Equatable {

            /// The item identifier.
            var id: AnyHashable

            /// The tile size from the model (D15). The panel gets the ``TesseraTileSize/wide`` mark.
            var size: TesseraTileSize

            /// The item is the full-width panel of an expanded folder (D17).
            ///
            /// The panel does not take part in base packing: it takes a separate full-width row after
            /// the folder row.
            var isPanel: Bool

            /// The panel's shortcut count: the panel height in points depends on it.
            ///
            /// Only the count, not the shortcuts themselves: the layout does not retain
            /// `TesseraTileDescriptor` and `TesseraTileFolder` (they hold closures and `UIImage`).
            var folderTileCount: Int

            /// The explicit cell of the item from the snapshot table (logical coordinates); `nil` if
            /// there is no table or the item has no cell. Always `nil` for the panel: it is not a
            /// tile but a row under the folder band (and shares the identifier with the folder).
            ///
            /// Part of the key, so a change of cells alone (the same set and sizes) invalidates the
            /// layout and is animated as a reorder.
            var cell: TesseraTileGridPlacement?
        }
    }

    // MARK: - Model and invalidation

    /// The reason of the last invalidation, for tests and debugging.
    ///
    /// UICollectionView does not hand the context back to `prepare()`, so the layout remembers the
    /// custom context properties here: a test can check that resize/reorder went through
    /// invalidation with a context and not through `reloadData`.
    private(set) var lastInvalidationReason: TesseraTileLayoutInvalidationReason?

    /// Remembers the reason from the context and passes the invalidation on.
    ///
    /// Per the UIKit documentation, an override of `invalidateLayout(with:)` must call `super`; the
    /// layout does not cache attributes forever: the geometry key in ``ensureGeometry()`` still
    /// decides what to recompute.
    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if let tileContext = context as? TesseraTileLayoutInvalidationContext {
            lastInvalidationReason = tileContext.reason
        }
        super.invalidateLayout(with: context)
    }

    /// Accepts a new set of items and invalidates the layout with a context (§3, §5, D17).
    ///
    /// Called by `TesseraTileGridView` before `reloadData()` (a full reload) or inside
    /// `performBatchUpdates` (an animated resize/reorder). The method itself does not start an
    /// animation: that is done by the view layer that owns the collection.
    ///
    /// The appearance and disappearance of the folder panel arrive here too: on expansion the panel
    /// appears in the set (the item count grows by one), on closing it disappears; the folder tile
    /// stays in place. The geometry is rebuilt on a key change, and the invalidation carries the
    /// `.items` context: cells are not reloaded needlessly, and UICollectionView reaches the new
    /// frames with the view layer animation.
    ///
    /// The explicit cell table comes from the grid snapshot; the layout includes it in the geometry
    /// key (a change of cells alone recomputes the frames) and decides whether it applies to the
    /// current column count when the geometry is rebuilt.
    ///
    /// - Parameters:
    ///   - items: The grid items in display order.
    ///   - placements: The explicit cell table from the snapshot; `nil` means order-based packing.
    ///   - reason: The reason for recomputation (the set or only the geometry).
    func setItems(
        _ items: [TesseraTileGridItem],
        placements: TesseraTileGridPlacementTable? = nil,
        reason: TesseraTileLayoutInvalidationReason
    ) {
        // The attributes of a disappearing panel are remembered before the set changes: the new set
        // no longer has it, and UICollectionView will ask for the final attributes at the old
        // index (D17).
        capturePanelTransition(replacingWith: items)
        appearingPanelIndex = nil

        layoutItems = items.map { item in
            let panel = item.panelFolder
            return GeometryKey.Item(
                id: item.id,
                size: item.size,
                isPanel: panel != nil,
                folderTileCount: panel?.tiles.count ?? 0,
                cell: panel == nil ? placements?.cells[item.id] : nil
            )
        }
        layoutPlacementColumns = placements?.columns
        itemIdentifiers = layoutItems.map { $0.id }

        let context = TesseraTileLayoutInvalidationContext(
            reason: reason,
            itemIdentifiers: itemIdentifiers
        )
        invalidateLayout(with: context)
    }

    /// Remembers the attributes of a panel that disappears when a folder closes.
    ///
    /// Called from ``setItems(_:reason:)`` before the set is replaced: the layout still knows the old
    /// items and their attributes, so it can build the collapse animation from the previous frame.
    /// Only the transition "there was a panel, now there is none" counts as a disappearance; on an
    /// ordinary resize/reorder and on expansion (the panel appears) nothing is remembered: the folder
    /// tile does not go anywhere on expansion.
    ///
    /// - Parameter items: The new set of grid items.
    private func capturePanelTransition(replacingWith items: [TesseraTileGridItem]) {
        disappearingPanel = nil

        let oldPanelIndex = layoutItems.firstIndex { $0.isPanel }
        guard let oldPanelIndex,
              !items.contains(where: { $0.isFolderPanel }) else {
            return
        }

        // The geometry may not be computed yet: `frame(forItemID:)` and `prepare()` compute it
        // lazily. The attributes are needed in content coordinates, so they are recomputed from the
        // current (still old) items.
        ensureGeometry()

        guard attributesByIndex.indices.contains(oldPanelIndex),
              let copy = attributesByIndex[oldPanelIndex].copy() as? TesseraTileLayoutAttributes else {
            return
        }
        disappearingPanel = (index: oldPanelIndex, attributes: copy)
    }

    /// Invalidates the layout because of a configuration change (columns, margins, gap).
    private func invalidateGeometry() {
        let context = TesseraTileLayoutInvalidationContext(
            reason: .geometry,
            itemIdentifiers: layoutItems.map { $0.id }
        )
        invalidateLayout(with: context)
    }

    // MARK: - UICollectionViewLayout

    /// Recomputes the attributes if the geometry key changed.
    ///
    /// Not called on the scroll hot path: `shouldInvalidateLayout` returns `false` for a
    /// `contentOffset` change, so UICollectionView does not ask the layout to recompute on every
    /// frame (§3, the discipline of CORE-IOS-DESIGN.md §2).
    override func prepare() {
        super.prepare()
        ensureGeometry()
    }

    /// The content size: the height of the last row plus the bottom margin.
    override var collectionViewContentSize: CGSize {
        ensureGeometry()
        return cachedContentSize
    }

    /// The attributes of items intersecting a rectangle.
    ///
    /// The scan is linear: a start screen has tens of items, and a quadrant dictionary would cost
    /// more than the scan itself.
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        ensureGeometry()
        return attributesByIndex.filter { $0.frame.intersects(rect) }
    }

    /// The attributes of a single item by index.
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        ensureGeometry()
        guard attributesByIndex.indices.contains(indexPath.item) else { return nil }
        return attributesByIndex[indexPath.item]
    }

    // MARK: - Folder panel animation (D17)

    /// Parses a batch update: whether the current update makes a panel appear.
    ///
    /// UICollectionView calls this when the grid has already passed the new set through
    /// ``setItems(_:reason:)``. Only here can it be seen that the panel appears with an animation: on
    /// `reloadData` (Reduce Motion, a grid outside a window) this call does not happen, and the panel
    /// gets its full height immediately.
    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        appearingPanelIndex = nil

        // The geometry key is already new: the attributes must match the set the grid sent.
        ensureGeometry()

        for update in updateItems {
            guard case .insert = update.updateAction,
                  let indexPath = update.indexPathAfterUpdate else {
                continue
            }
            // A panel appeared: an expansion. The folder tile stays inserted and is not deleted, so
            // no other special attributes are needed for expansion.
            if let panelAttributeIndex, indexPath.item == panelAttributeIndex {
                appearingPanelIndex = indexPath.item
            }
        }
    }

    /// The initial attributes of an appearing item.
    ///
    /// On expansion the panel arrives with height 0 and grows to full: the top edge and the width do
    /// not change, so the items under the panel simultaneously shift down.
    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        if let appearingPanelIndex,
           itemIndexPath.item == appearingPanelIndex,
           itemIndexPath.item == panelAttributeIndex,
           let attributes = layoutAttributesForItem(at: itemIndexPath),
           let collapsed = collapsedPanelAttributes(from: attributes) {
            return collapsed
        }

        return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
    }

    /// The final attributes of a disappearing item.
    ///
    /// On closing the panel collapses to height 0: the top edge stays in place, so the items under
    /// the panel rise, and the folder tile stays visible where it was.
    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        if let panel = disappearingPanel,
           panel.index == itemIndexPath.item,
           let collapsed = collapsedPanelAttributes(from: panel.attributes) {
            return collapsed
        }

        return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
    }

    /// A copy of the panel attributes with a collapsed height (D17).
    ///
    /// The panel's top edge and width are kept: the panel "grows" downward after the folder row and
    /// collapses upward the same way. A copy is required: UICollectionView animates exactly the
    /// returned object, and the layout's own attribute frame must not be spoiled.
    ///
    /// - Parameter attributes: The full panel attributes.
    /// - Returns: A copy with `frame.size.height == 0`, or `nil` if copying is unavailable.
    private func collapsedPanelAttributes(
        from attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes? {
        guard let copy = attributes.copy() as? UICollectionViewLayoutAttributes else {
            return nil
        }
        var frame = copy.frame
        frame.size.height = 0
        copy.frame = frame
        return copy
    }

    /// Whether the layout must be recomputed when `bounds` changes.
    ///
    /// Invalidation only by size and reading direction. A `bounds.origin` change is scrolling; it
    /// must not return `true`, otherwise the layout would be recomputed on every frame (§3). A
    /// rotation and a width change alter the unit, so those are recomputed.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let lastKey else { return true }

        let sizeChanged = abs(newBounds.width - lastKey.boundsSize.width) > 0.5
            || abs(newBounds.height - lastKey.boundsSize.height) > 0.5
        guard let collectionView else { return sizeChanged }

        let directionChanged = collectionView.effectiveUserInterfaceLayoutDirection != lastKey.direction
        return sizeChanged || directionChanged
    }

    // MARK: - Geometry recomputation

    /// Recomputes the attributes if the geometry key differs from the last one.
    ///
    /// Called from the layout pass and from frame queries. If there is no collection yet (the layout
    /// was created before being installed in a collection), the geometry stays empty: the first
    /// `prepare()` after installation computes everything.
    private func ensureGeometry() {
        guard let collectionView else { return }

        let key = makeKey(for: collectionView)
        guard key != lastKey else { return }
        rebuild(for: key)
    }

    /// Builds the geometry key from the current state of the collection and the layout.
    private func makeKey(for collectionView: UICollectionView) -> GeometryKey {
        GeometryKey(
            boundsSize: collectionView.bounds.size,
            direction: collectionView.effectiveUserInterfaceLayoutDirection,
            columns: columns,
            insets: sanitized(insets: contentInsets),
            spacing: sanitized(spacing: itemSpacing),
            scale: displayScaleOverride.map { $0.isFinite ? max($0, 0) : 0 }
                ?? Self.resolvedDisplayScale(collectionView.traitCollection.displayScale),
            placementColumns: layoutPlacementColumns,
            items: layoutItems
        )
    }

    /// Rebuilds the attributes by the key.
    ///
    /// ``itemIdentifiers`` and ``cachedContentSize`` are updated here too: after this the layout is
    /// consistent with the model even if UICollectionView has not asked for attributes yet.
    ///
    /// Horizontal: the content edges and the top margin are rounded to a pixel, the unit is rounded
    /// down to a pixel
    /// (``TesseraTileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``), and the
    /// remaining width is split equally into margins, so the grid is centered. Hence all frames are
    /// multiples of `1 / scale`.
    ///
    /// Folder expansion (D17) is computed in three steps:
    ///
    /// 1. Base packing: all tiles, including the folder itself, get the same slots as in the
    ///    collapsed grid; the panel does not take part in packing.
    /// 2. The folder band: the folder rows, extended downward by the tiles that start in those rows
    ///    and end lower (``TesseraTileLayoutEngine/folderBandEndRow(for:in:)``). The panel takes a
    ///    full-width row right after the band and stretches over the whole content width.
    /// 3. Items that start below the band are packed again and end up under the panel. The band
    ///    items and everything above stay in place: the panel starts below them and overlaps no one.
    ///    With explicit cells there is no repack: the lower rows stay on their cells and shift down
    ///    by the panel height and the gap, holes are preserved.
    private func rebuild(for key: GeometryKey) {
        lastKey = key
        itemIdentifiers = key.items.map { $0.id }
        attributesByIndex.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        cachedContentSize = .zero
        panelAttributeIndex = nil
        usesExplicitPlacements = false

        guard !key.items.isEmpty else { return }

        // The content edges are on the pixel grid; the width between them is the available width of
        // the unit formula.
        let contentLeft = TesseraTileLayoutEngine.pixelRound(key.insets.left, scale: key.scale)
        let contentRight = TesseraTileLayoutEngine.pixelRound(
            key.boundsSize.width - key.insets.right,
            scale: key.scale
        )
        let contentWidth = contentRight - contentLeft
        let contentTop = TesseraTileLayoutEngine.pixelRound(key.insets.top, scale: key.scale)
        guard contentWidth.isFinite, contentWidth > 0 else { return }

        guard let metrics = TesseraTileLayoutEngine.gridMetrics(
            contentWidth: contentWidth,
            columns: key.columns,
            spacing: key.spacing,
            scale: key.scale
        ) else {
            return
        }
        let unit = metrics.unit
        let spacing = metrics.spacing
        // The left edge of the grid: the remainder after aligning the unit is split into margins.
        let gridLeft = contentLeft + metrics.leading

        // The panel does not take part in base packing: it is a separate full-width row under the
        // folder, not a tile. Only the tile footprint is shrunk for a narrow grid; the model
        // (TesseraTileSize) does not change, and the cell and TesseraTileStore see it.
        let panelIndices = key.items.indices.filter { key.items[$0].isPanel }
        let mainPanelIndex = panelIndices.first
        var baseIndices: [Int] = []
        baseIndices.reserveCapacity(key.items.count)
        var packItems: [(id: AnyHashable, size: TesseraTileSize)] = []
        packItems.reserveCapacity(key.items.count - panelIndices.count)
        for index in key.items.indices where !key.items[index].isPanel {
            baseIndices.append(index)
            packItems.append(
                (id: key.items[index].id, size: normalizedSize(key.items[index].size, columns: key.columns))
            )
        }

        // If the snapshot brought an explicit cell table and it is complete and valid for these
        // columns, tiles stand on their cells, without packing, and holes remain. Otherwise (no
        // table, incomplete, off-canvas, with overlaps, another width) the layout uses the previous
        // order-based packing.
        var explicitCells: [AnyHashable: TesseraTileGridPlacement] = [:]
        for index in baseIndices {
            if let cell = key.items[index].cell {
                explicitCells[key.items[index].id] = cell
            }
        }
        let explicitPlacements = TesseraTileGridPlacementTable.resolve(
            items: baseIndices.map { (id: key.items[$0].id, size: key.items[$0].size) },
            cells: explicitCells.isEmpty ? nil : explicitCells,
            placementColumns: key.placementColumns,
            columns: key.columns
        )
        let slots: [TesseraTileLayoutSlot]
        if let explicitPlacements {
            slots = TesseraTileLayoutEngine.slots(
                placements: explicitPlacements,
                columns: key.columns,
                unit: unit,
                fitting: true
            )
        } else {
            slots = TesseraTileLayoutEngine.pack(
                items: packItems,
                columns: key.columns,
                unit: unit
            )
        }

        // The engine skips only tiles wider than the grid; normalizedSize excludes that. A safety net
        // against future engine changes: better to end up without attributes than to get an index
        // mismatch.
        guard slots.count == baseIndices.count else { return }
        usesExplicitPlacements = explicitPlacements != nil

        /// The slots of base items by index in the set.
        var slotByIndex: [Int: TesseraTileLayoutSlot] = [:]
        slotByIndex.reserveCapacity(baseIndices.count)
        for (position, index) in baseIndices.enumerated() {
            slotByIndex[index] = slots[position]
        }

        /// The slot frame in points with the grid origin and RTL mirroring (§9).
        ///
        /// Mirroring happens inside the grid width (`metrics.width`), not the content width: this way
        /// the grid occupies the same pixel columns in LTR and RTL, and the panel shortcuts (the cell
        /// mirrors columns by the same rule) match the tiles.
        func elementFrame(for slot: TesseraTileLayoutSlot, top: CGFloat) -> CGRect {
            var rect = TesseraTileLayoutEngine.rect(
                for: slot,
                unit: unit,
                gap: spacing,
                origin: CGPoint(x: gridLeft, y: top)
            )
            if key.direction == .rightToLeft {
                let localX = rect.minX - gridLeft
                rect.origin.x = gridLeft + metrics.width - localX - rect.width
            }
            return rect
        }

        var frames: [CGRect?] = Array(repeating: nil, count: key.items.count)

        if let panelIndex = mainPanelIndex {
            panelAttributeIndex = panelIndex
            let panelHeight = TesseraTileLayoutEngine.panelHeight(
                tileCount: key.items[panelIndex].folderTileCount,
                width: contentWidth,
                columns: key.columns,
                spacing: key.spacing,
                scale: key.scale
            )
            let panelID = key.items[panelIndex].id
            // The folder tile stays in the set: its slot gives the band after which the panel
            // stands.
            let folderIndex = baseIndices.first { key.items[$0].id == panelID }

            if let folderIndex, let folderSlot = slotByIndex[folderIndex] {
                // The panel stands not under the last folder row but under the band; otherwise a tile
                // that starts in the folder rows and ends lower would stay in place under the panel.
                let bandEndRow = explicitPlacements.flatMap {
                    TesseraTileLayoutEngine.folderBandEndRow(
                        forFolder: panelID,
                        in: $0,
                        columns: key.columns
                    )
                } ?? TesseraTileLayoutEngine.folderBandEndRow(for: folderSlot, in: slots)

                // D17: the panel is a full-width row right after the folder band; its top edge is
                // the start of the next grid row.
                let panelTop = contentTop + CGFloat(bandEndRow) * (unit + spacing)
                frames[panelIndex] = CGRect(
                    x: contentLeft,
                    y: panelTop,
                    width: contentWidth,
                    height: panelHeight
                )

                var belowIndices: [Int] = []
                belowIndices.reserveCapacity(baseIndices.count)
                for index in baseIndices {
                    guard let slot = slotByIndex[index] else { continue }
                    if slot.row < bandEndRow {
                        // The folder band and everything above stay in place: at the band's fixed
                        // point no such tile goes below `bandEndRow`.
                        frames[index] = elementFrame(for: slot, top: contentTop)
                    } else {
                        belowIndices.append(index)
                    }
                }

                if explicitPlacements != nil {
                    // Explicit cells: the panel is an insertion, not a repack. The rows below the
                    // band stay on their cells (holes between them and above them are preserved) and
                    // shift down as a whole by the panel height and the gap.
                    let shift = TesseraTileLayoutEngine.rowsBelowOffset(
                        placedSlots: slots,
                        expandedFolderID: panelID,
                        panelHeight: panelHeight,
                        spacing: spacing
                    )
                    for index in belowIndices {
                        guard let slot = slotByIndex[index] else { continue }
                        frames[index] = elementFrame(for: slot, top: contentTop + shift)
                    }
                } else if !belowIndices.isEmpty {
                    // Everything that starts below the band is packed again from the left edge and
                    // stands right under the panel. The unit grid is preserved; the origin is the
                    // panel's bottom edge plus the gap.
                    let belowItems: [(id: AnyHashable, size: TesseraTileSize)] = belowIndices.map { index in
                        (
                            id: key.items[index].id,
                            size: normalizedSize(key.items[index].size, columns: key.columns)
                        )
                    }
                    let belowSlots = TesseraTileLayoutEngine.pack(
                        items: belowItems,
                        columns: key.columns,
                        unit: unit
                    )
                    guard belowSlots.count == belowIndices.count else { return }

                    let belowTop = panelTop + panelHeight + spacing
                    for (position, index) in belowIndices.enumerated() {
                        frames[index] = elementFrame(for: belowSlots[position], top: belowTop)
                    }
                }
            } else {
                // A panel without a folder tile does not occur in the normal flow (the grid inserts
                // it only next to an existing folder). A defensive path: the panel goes on top with
                // no height, and the base items use ordinary packing.
                frames[panelIndex] = CGRect(
                    x: contentLeft,
                    y: contentTop,
                    width: contentWidth,
                    height: 0
                )
                for index in baseIndices {
                    guard let slot = slotByIndex[index] else { continue }
                    frames[index] = elementFrame(for: slot, top: contentTop)
                }
            }
        } else {
            for index in baseIndices {
                guard let slot = slotByIndex[index] else { continue }
                frames[index] = elementFrame(for: slot, top: contentTop)
            }
        }

        // D17 expands one folder; extra panels (if the host still adds several) get an empty frame
        // so that indices do not drift.
        if let mainPanelIndex = mainPanelIndex {
            for index in panelIndices where index != mainPanelIndex {
                frames[index] = CGRect(
                    x: contentLeft,
                    y: contentTop,
                    width: contentWidth,
                    height: 0
                )
            }
        }

        var maximumY = contentTop
        attributesByIndex.reserveCapacity(key.items.count)

        for (index, item) in key.items.enumerated() {
            guard let frame = frames[index] else { return }

            let attributes = TesseraTileLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0)
            )
            attributes.itemID = item.id
            attributes.tileSize = item.size
            attributes.frame = frame
            attributesByIndex.append(attributes)

            // The panel is not addressable as a model item: `frame(forItemID:)` by the folder
            // identifier returns the frame of the folder tile itself.
            if !item.isPanel {
                indexByID[item.id] = index
            }
            maximumY = max(maximumY, frame.maxY)
        }

        cachedContentSize = CGSize(
            width: key.boundsSize.width,
            height: maximumY + key.insets.bottom
        )
    }

    // MARK: - Helper conversions

    /// Shrinks the tile footprint for a narrow grid without changing the model.
    ///
    /// D15 is designed for at least 4 columns; with fewer columns a wide tile does not fit. Instead
    /// of skipping it (which would shift the index mapping), the nearest smaller size is taken: 2×2
    /// at two or three columns and 1×1 at one. The rule lives in
    /// `TesseraTileLayoutEngine.fittingSize(_:columns:)`, so that the layout and the pure panel
    /// functions compute the same way.
    private func normalizedSize(_ size: TesseraTileSize, columns: Int) -> TesseraTileSize {
        TesseraTileLayoutEngine.fittingSize(size, columns: columns)
    }

    /// Sanitizes the outer margins: negative and non-numeric values become 0.
    private func sanitized(insets: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: sanitized(length: insets.top),
            left: sanitized(length: insets.left),
            bottom: sanitized(length: insets.bottom),
            right: sanitized(length: insets.right)
        )
    }

    /// Sanitizes the gap: a negative or non-numeric value becomes 0.
    private func sanitized(spacing: CGFloat) -> CGFloat {
        sanitized(length: spacing)
    }

    /// Sanitizes a single length value: a negative or non-numeric value becomes 0.
    private func sanitized(length: CGFloat) -> CGFloat {
        guard length.isFinite else { return 0 }
        return max(0, length)
    }
}

#endif
