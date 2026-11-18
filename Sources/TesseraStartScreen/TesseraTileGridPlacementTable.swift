// The explicit cell table in a grid snapshot: the "side" input of the layout (D30).
//
// Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 (the tile grid) and the implementation notes
// for explicit cells; decisions D30–D33 in docs/DECISIONS.md.
//
// Before explicit cells, the layout was a function of order:
// ``TesseraTileLayoutEngine/pack(items:columns:unit:)`` packed tiles strictly compactly by the
// snapshot array. So that the grid can represent real holes, a snapshot gets an optional cell
// table (a "sidecar"): identifier -> ``TesseraTileGridPlacement``. The ``TesseraTileGridItem`` enum
// does not change (that would be source-breaking), and a snapshot without a table is laid out
// exactly as before.
//
// This file is the pure part: the table itself and the rule for whether it can be trusted
// (``TesseraTileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``).
// The rule is shared by the layout and by the grid's auxiliary calculations (base layout frames)
// so that they never diverge. It knows nothing about UIKit.

import CoreGraphics

/// A table of explicit cells for top-level items, attached to a grid snapshot (D30).
///
/// The cells are **logical**, as in ``TesseraTileGridPlacement``: column 0 is the reading start;
/// the layout mirrors RTL when it computes frames. The table describes the layout for a specific
/// canvas width: ``columns``.
///
/// The layout accepts the table only if it covers every snapshot item (except the expanded folder
/// panel), its width matches the grid's column count, and the set passes
/// ``TesseraTileLayoutEngine/validate(_:columns:)`` (off-canvas cells and overlaps are invalid).
/// Otherwise the whole table is ignored and the grid is laid out by the previous
/// ``TesseraTileLayoutEngine/pack(items:columns:unit:)`` in snapshot order, with no partial
/// substitution: a half-correct layout is worse than an honest repack.
public struct TesseraTileGridPlacementTable: Equatable {

    /// Cells keyed by top-level item identifiers.
    ///
    /// Extra identifiers (absent from the snapshot) are ignored; missing ones make the table
    /// incomplete, and the layout falls back to order-based packing.
    public var cells: [AnyHashable: TesseraTileGridPlacement]

    /// Canvas width in columns the cells were computed for.
    ///
    /// If set and different from the grid's column count, the table is ignored (for another width
    /// the store returns a projection without holes, D32, but the host computes the projection
    /// for its own width). `nil` means the width is not declared: the table is checked only by
    /// `validate` at the current grid width.
    public var columns: Int?

    /// Creates a table.
    ///
    /// - Parameters:
    ///   - cells: Cells keyed by item identifiers.
    ///   - columns: The canvas width the cells were computed for; `nil` if not declared.
    public init(cells: [AnyHashable: TesseraTileGridPlacement], columns: Int? = nil) {
        self.cells = cells
        self.columns = columns
    }

    /// Whether the table is applicable on a grid of the given width, and the resulting placement.
    ///
    /// The rule for falling back to order-based packing (`nil`):
    ///
    /// - there is no table (`cells == nil`) or the item set is empty;
    /// - the declared width `placementColumns` differs from `columns`;
    /// - at least one item has no cell (the table is incomplete);
    /// - the set fails ``TesseraTileLayoutEngine/validate(_:columns:)``: a footprint leaves the
    ///   canvas, a cell is negative, or footprints overlap.
    ///
    /// Otherwise it returns the placements **in `items` order** with the requested sizes (D15);
    /// shrinking to a narrow grid is done by
    /// ``TesseraTileLayoutEngine/slots(placements:columns:unit:fitting:)`` and `validate`.
    ///
    /// - Parameters:
    ///   - items: Items in snapshot order (without the panel): identifier and requested size.
    ///   - cells: Cells keyed by identifiers; `nil` means there is no table.
    ///   - placementColumns: The declared canvas width of the table; `nil` if not declared.
    ///   - columns: The grid's column count, greater than zero.
    /// - Returns: Placements for ``TesseraTileLayoutEngine/slots(placements:columns:unit:fitting:)``,
    ///   or `nil`, in which case the layout must use order-based packing.
    static func resolve(
        items: [(id: AnyHashable, size: TesseraTileSize)],
        cells: [AnyHashable: TesseraTileGridPlacement]?,
        placementColumns: Int?,
        columns: Int
    ) -> [TesseraTilePlacedItem]? {
        guard let cells, columns > 0, !items.isEmpty else { return nil }
        if let placementColumns, placementColumns != columns { return nil }

        var placed: [TesseraTilePlacedItem] = []
        placed.reserveCapacity(items.count)
        for item in items {
            guard let cell = cells[item.id] else { return nil }
            placed.append(TesseraTilePlacedItem(id: item.id, size: item.size, cell: cell))
        }
        guard TesseraTileLayoutEngine.validate(placed, columns: columns).isEmpty else { return nil }
        return placed
    }
}

// MARK: - Snapshot reading order

extension TesseraTileGridSnapshot {

    /// A snapshot whose items follow the reading order of the explicit cells.
    ///
    /// The order of snapshot items is the collection index order, and therefore the VoiceOver
    /// traversal order (see "Accessibility" in ``TesseraTileGridView``). A host with its own cell
    /// table (without ``TesseraTileStore``) may supply items in any order; an applicable table
    /// (``TesseraTileGridPlacementTable/resolve(items:cells:placementColumns:columns:)``) defines
    /// how items lie on screen, and the order is brought in line with it: row ascending, then
    /// logical column (in RTL columns are logical, so the order is the same). Equal cells (which
    /// cannot occur: ``TesseraTileLayoutEngine/validate(_:columns:)``) keep the original order.
    ///
    /// If the table is not applicable (missing, incomplete, different width, overlaps), the layout
    /// packs by `items` order, and that order is kept as is. A snapshot with an expanded folder
    /// panel in `items` is also left untouched: the grid adds the panel itself after sorting.
    ///
    /// - Parameter columns: The grid's column count.
    /// - Returns: `self` if the order is already correct or the table is not applicable;
    ///   otherwise a copy with reordered items.
    func readingOrdered(columns: Int) -> TesseraTileGridSnapshot {
        guard placementTable != nil, !items.contains(where: { $0.isFolderPanel }),
              let placed = TesseraTileGridPlacementTable.resolve(
                  items: items.map { (id: $0.id, size: $0.size) },
                  cells: placementTable?.cells,
                  placementColumns: placementTable?.columns,
                  columns: columns
              ) else {
            return self
        }
        var cellByID: [AnyHashable: TesseraTileGridPlacement] = [:]
        cellByID.reserveCapacity(placed.count)
        for item in placed { cellByID[item.id] = item.cell }

        let sorted = items.enumerated().sorted { lhs, rhs in
            guard let left = cellByID[lhs.element.id], let right = cellByID[rhs.element.id],
                  left != right else {
                return lhs.offset < rhs.offset
            }
            return TesseraTileGridPlacement.isReadingOrdered(left, before: right)
        }
        guard sorted.map({ $0.offset }) != Array(items.indices) else { return self }
        return TesseraTileGridSnapshot(
            items: sorted.map { $0.element },
            unpinned: unpinned,
            placementTable: placementTable
        )
    }
}
