// Layout by explicit coordinates: the pure "placement by cells" layer.
// Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 (tile grid) and
// "Implementation deviations"; decisions D30–D33 in docs/STATE.md.
//
// Layout used to be a function of order: ``TesseraTileLayoutEngine/pack(items:columns:unit:)``
// packed tiles strictly compactly along the array. Variant B (D30) makes the model
// explicit coordinates: every top-level element has a cell
// (``TesseraTileGridPlacement``), a tile is anchored to it, and holes are preserved. This file holds
// the pure operations on such a set: placement, insertion with a cascading push down
// (D31), in-place resize, removal without repacking, collapsing empty rows,
// finding a free cell, and validity checking.
//
// The layer knows nothing about UIKit, the store, or the grid: only `TesseraTileSize`, cells, and
// the column count. All functions are `static`, deterministic, and stateless.
// Cells are **logical** (column 0 is the start of reading); RTL mirroring is done by the
// view layer (document §9). The layer is used by the cell-based `TesseraTileStore` operations
// and by the coordinator's drag preview; order-based packing (`pack`, `packCompact`)
// remains in `TesseraTileLayoutEngine.swift` for layout rollback, the v1 → v2 migration, and
// projection onto a different canvas width.

import CoreGraphics

/// An element of a placement set: an identifier, a requested size, and the top-left
/// corner cell (D30).
///
/// A placement set is an array of such elements. The array order is **not the model**: it
/// exists only to match the result to the input (as in
/// ``TesseraTileLayoutEngine/pack(items:columns:unit:)``) and to keep the output deterministic.
/// The size here is the requested one (D15, as in `TesseraTileStore`); the footprint on the grid is
/// computed by the engine with ``TesseraTileLayoutEngine/fittingSize(_:columns:)``.
public struct TesseraTilePlacedItem: Equatable {

    /// The identifier of a top-level element (a tile or a folder).
    public var id: AnyHashable

    /// The requested tile size (D15).
    public var size: TesseraTileSize

    /// The top-left corner cell (logical coordinates, in units).
    public var cell: TesseraTileGridPlacement

    /// Creates a placement set element.
    ///
    /// - Parameters:
    ///   - id: The element identifier.
    ///   - size: The requested tile size.
    ///   - cell: The top-left corner cell.
    public init(id: AnyHashable, size: TesseraTileSize, cell: TesseraTileGridPlacement) {
        self.id = id
        self.size = size
        self.cell = cell
    }
}

/// The rectangle of a tile footprint in units — the engine's internal representation.
fileprivate struct PlacementRect: Equatable {

    var row: Int
    var column: Int
    var width: Int
    var height: Int

    /// The first row below the rectangle.
    var bottom: Int { row + height }

    /// The first column to the right of the rectangle.
    var trailing: Int { column + width }

    /// Whether two rectangles intersect (a shared edge is not an intersection).
    func overlaps(_ other: PlacementRect) -> Bool {
        row < other.bottom && other.row < bottom
            && column < other.trailing && other.column < trailing
    }
}

// MARK: - Placement by coordinates (D30)

extension TesseraTileLayoutEngine {

    // MARK: Slots and validation

    /// Slots at explicit cells, without packing.
    ///
    /// Each element lands exactly on its own cell; nothing is shifted or
    /// collapsed. Slots follow the **order of the input array**. As with
    /// ``pack(items:columns:unit:)``, with `fitting == false` a tile wider than the grid
    /// is skipped (the grid cannot draw it without distorting the size); with
    /// `fitting == true` the size is first shrunk by
    /// ``fittingSize(_:columns:)`` (geometry degradation, as in the layout for a narrow
    /// grid), and nothing is skipped. A slot carries the size its footprint was computed from.
    ///
    /// - Parameters:
    ///   - placements: The placement set.
    ///   - columns: The number of columns, greater than zero.
    ///   - unit: The unit size in points, greater than zero.
    ///   - fitting: Whether to shrink sizes to a narrow grid instead of skipping.
    /// - Returns: Slots in the order of `placements`; an empty array for degenerate
    ///   geometry.
    public static func slots(
        placements: [TesseraTilePlacedItem],
        columns: Int,
        unit: CGFloat,
        fitting: Bool = false
    ) -> [TesseraTileLayoutSlot] {
        guard columns > 0, unit.isFinite, unit > 0 else { return [] }

        var result: [TesseraTileLayoutSlot] = []
        result.reserveCapacity(placements.count)

        for item in placements {
            let size = fitting ? fittingSize(item.size, columns: columns) : item.size
            guard size.unitColumns > 0, size.unitRows > 0, size.unitColumns <= columns else { continue }

            result.append(
                TesseraTileLayoutSlot(
                    id: item.id,
                    size: size,
                    column: item.cell.column,
                    row: item.cell.row,
                    unit: unit
                )
            )
        }
        return result
    }

    /// Identifiers of the elements that violate the validity of the set.
    ///
    /// A violator is an element whose footprint (per ``fittingSize(_:columns:)``) goes beyond the
    /// canvas `[0, columns)` by columns, lies in a negative row or column, or
    /// intersects another element. An empty result means the set is valid.
    /// The order follows the input array, without repeats. With `columns <= 0` all elements
    /// are considered violators.
    ///
    /// - Parameters:
    ///   - placements: The placement set.
    ///   - columns: The number of columns.
    /// - Returns: The identifiers of the violators.
    public static func validate(_ placements: [TesseraTilePlacedItem], columns: Int) -> [AnyHashable] {
        guard columns > 0 else { return placements.map(\.id) }

        let rects = placements.map { placementRect($0, columns: columns) }
        var offenders: [AnyHashable] = []

        for (index, rect) in rects.enumerated() {
            var isOffender = rect.row < 0 || rect.column < 0 || rect.trailing > columns
            if !isOffender {
                for other in rects.indices where other != index && rect.overlaps(rects[other]) {
                    isOffender = true
                    break
                }
            }
            if isOffender { offenders.append(placements[index].id) }
        }
        return offenders
    }

    /// Whether the set contains intersecting footprints.
    ///
    /// Intersections only: going beyond the canvas is checked by ``validate(_:columns:)``.
    ///
    /// - Parameters:
    ///   - placements: The placement set.
    ///   - columns: The number of columns (needed to shrink sizes to a narrow grid).
    /// - Returns: `true` if at least two footprints intersect.
    public static func hasOverlaps(_ placements: [TesseraTilePlacedItem], columns: Int) -> Bool {
        guard columns > 0 else { return false }

        let rects = placements.map { placementRect($0, columns: columns) }
        for lhs in rects.indices {
            for rhs in rects.indices where rhs > lhs && rects[lhs].overlaps(rects[rhs]) {
                return true
            }
        }
        return false
    }

    // MARK: Cell

    /// Clamps a cell to the canvas for a tile size (D31).
    ///
    /// The row is at least 0; the column is limited so that
    /// `column + width ≤ columns`: a cell that is too far right is **shifted left**,
    /// never right. The width comes from ``fittingSize(_:columns:)``, so on a narrow
    /// grid a tile always fits. With `columns <= 0` the column is 0.
    ///
    /// - Parameters:
    ///   - cell: The desired cell.
    ///   - size: The tile size.
    ///   - columns: The number of columns.
    /// - Returns: A valid cell.
    public static func clamped(cell: TesseraTileGridPlacement, size: TesseraTileSize, columns: Int) -> TesseraTileGridPlacement {
        let width = fittingSize(size, columns: columns).unitColumns
        let maxColumn = max(0, columns - width)
        return TesseraTileGridPlacement(
            row: max(0, cell.row),
            column: min(max(0, cell.column), maxColumn)
        )
    }

    // MARK: Insertion and resize

    /// Puts an element on a cell; obstructing tiles are pushed down in a cascade
    /// (D31).
    ///
    /// The algorithm:
    ///
    /// 1. The cell is clamped to the canvas with ``clamped(cell:size:columns:)``, giving the
    ///    insertion rectangle `R`. If an element with this `id` already exists, it is
    ///    excluded from collisions (this is a move): the other elements are compared
    ///    only with `R`, not with its old place.
    /// 2. The other elements are visited in the reading order of their **original**
    ///    positions (row, then column, then index in the input array).
    /// 3. Each element is checked for intersection with everything already placed
    ///    (`R` and the previously processed ones, with their new positions). If there is
    ///    an intersection, the element moves **down** in the same column to the minimal row
    ///    that clears all intersecting rectangles (the bottom edge of the lowest
    ///    of them); the check repeats — this is the cascade: a shifted
    ///    element becomes an obstacle for the following ones.
    /// 4. Elements without intersections do not move, including holes above and around
    ///    the affected area. Nothing moves horizontally.
    ///
    /// The result is always free of intersections (each element is placed with a check against
    /// all the previous ones) and finite (a single pass, rows only grow). The array order
    /// is preserved; a new element is appended to the end, an existing one
    /// keeps its index. Idempotent: inserting an already valid
    /// placement onto its own cell does not change the set. With `columns <= 0`
    /// the input is returned unchanged. The input is assumed valid (footprint inside
    /// the canvas); intersections in the input are resolved by the same pass.
    ///
    /// - Parameters:
    ///   - id: The identifier of the element being inserted or moved.
    ///   - size: The element size (requested, D15).
    ///   - cell: The desired cell.
    ///   - placements: The current placement set.
    ///   - columns: The number of columns.
    /// - Returns: The new placement set.
    public static func inserting(
        id: AnyHashable,
        size: TesseraTileSize,
        at cell: TesseraTileGridPlacement,
        into placements: [TesseraTilePlacedItem],
        columns: Int
    ) -> [TesseraTilePlacedItem] {
        guard columns > 0 else { return placements }

        let moved = TesseraTilePlacedItem(
            id: id,
            size: size,
            cell: clamped(cell: cell, size: size, columns: columns)
        )
        let insertion = placementRect(moved, columns: columns)

        // The other elements in the reading order of their original positions.
        let others = placements.indices.filter { placements[$0].id != id }
        let order = others.sorted { lhs, rhs in
            let left = placements[lhs].cell
            let right = placements[rhs].cell
            if left.row != right.row { return left.row < right.row }
            if left.column != right.column { return left.column < right.column }
            return lhs < rhs
        }

        var placed: [PlacementRect] = [insertion]
        var newRows: [Int: Int] = [:]
        newRows.reserveCapacity(order.count)

        for index in order {
            var rect = placementRect(placements[index], columns: columns)
            while true {
                let blockers = placed.filter { $0.overlaps(rect) }
                guard let lowest = blockers.map(\.bottom).max() else { break }
                // The bottom edge of the lowest obstacle: we cannot go higher,
                // because the current row already intersects it.
                rect.row = lowest
            }
            newRows[index] = rect.row
            placed.append(rect)
        }

        // Assembly in input order: an existing element keeps its index,
        // a new one goes to the end.
        var result: [TesseraTilePlacedItem] = []
        result.reserveCapacity(placements.count + 1)
        var didPlaceMoved = false

        for index in placements.indices {
            if placements[index].id == id {
                if !didPlaceMoved {
                    result.append(moved)
                    didPlaceMoved = true
                }
                continue
            }
            var item = placements[index]
            item.cell.row = newRows[index] ?? item.cell.row
            result.append(item)
        }
        if !didPlaceMoved { result.append(moved) }
        return result
    }

    /// Resizes an element in place (D31).
    ///
    /// The anchor cell stays; if `column + new width > columns`, the column
    /// shifts left (``clamped(cell:size:columns:)``). Growth resolves
    /// intersections with the same push-down cascade as
    /// ``inserting(id:size:at:into:columns:)``. Shrinking moves nothing
    /// and leaves a hole. An unknown `id` or `columns <= 0` returns the input unchanged.
    ///
    /// - Parameters:
    ///   - id: The identifier of the element being resized.
    ///   - newSize: The new size.
    ///   - placements: The current placement set.
    ///   - columns: The number of columns.
    /// - Returns: The new placement set.
    public static func resizing(
        id: AnyHashable,
        to newSize: TesseraTileSize,
        in placements: [TesseraTilePlacedItem],
        columns: Int
    ) -> [TesseraTilePlacedItem] {
        guard columns > 0, let item = placements.first(where: { $0.id == id }) else {
            return placements
        }
        return inserting(id: id, size: newSize, at: item.cell, into: placements, columns: columns)
    }

    /// Removes an element from the set **without** repacking — the hole stays (D30).
    ///
    /// - Parameters:
    ///   - id: The identifier of the element being removed.
    ///   - placements: The current placement set.
    /// - Returns: The set without the element; the other elements do not move.
    public static func removing(id: AnyHashable, from placements: [TesseraTilePlacedItem]) -> [TesseraTilePlacedItem] {
        placements.filter { $0.id != id }
    }

    /// Collapses empty rows (D31).
    ///
    /// A row is removed only if **no** rectangle covers it —
    /// tall tiles (2×2, 4×4) cover all of their rows. Each element
    /// moves up by the number of removed rows above its top row;
    /// multi-row empty gaps (including empty rows at the very top)
    /// collapse entirely. A monotonic row mapping preserves the continuity of
    /// the footprint and creates no intersections. Horizontal coordinates do not change.
    ///
    /// Called by the edit layer **only on drop**, not during a drag (D31).
    ///
    /// - Parameters:
    ///   - placements: The current placement set.
    ///   - columns: The number of columns (needed to shrink sizes to a narrow grid:
    ///     the height of a large tile on a narrow grid comes from ``fittingSize(_:columns:)``).
    /// - Returns: The set without empty rows; the array order is preserved.
    public static func collapsingEmptyRows(
        in placements: [TesseraTilePlacedItem],
        columns: Int
    ) -> [TesseraTilePlacedItem] {
        guard columns > 0, !placements.isEmpty else { return placements }

        var covered = Set<Int>()
        var maxRow = 0
        for item in placements {
            let rect = placementRect(item, columns: columns)
            guard rect.row >= 0 else { continue }
            for row in rect.row..<rect.bottom { covered.insert(row) }
            maxRow = max(maxRow, rect.bottom)
        }

        // shift[r] is the number of empty rows lying strictly above row r.
        var shift = Array(repeating: 0, count: maxRow + 1)
        var removed = 0
        for row in 0...maxRow {
            shift[row] = removed
            if !covered.contains(row) { removed += 1 }
        }
        guard removed > 0 else { return placements }

        return placements.map { item in
            guard item.cell.row >= 0, item.cell.row <= maxRow else { return item }
            var shifted = item
            shifted.cell.row -= shift[item.cell.row]
            return shifted
        }
    }

    // MARK: Free cells

    /// The "new row" cell: the first row after the last occupied one, column 0
    /// (D30).
    ///
    /// For new pins and the "bottom" drop target. An empty set gives row 0.
    ///
    /// - Parameters:
    ///   - size: The size of the element being placed (column 0 always fits; the size is
    ///     taken into account for uniformity via ``clamped(cell:size:columns:)``).
    ///   - columns: The number of columns.
    ///   - placements: The current placement set.
    ///   - excluding: The identifier of an element that is ignored (the element being moved
    ///     frees its place).
    /// - Returns: The cell `(row: bottom edge, column: 0)`.
    public static func newRowCell(
        size: TesseraTileSize,
        columns: Int,
        placements: [TesseraTilePlacedItem],
        excluding id: AnyHashable? = nil
    ) -> TesseraTileGridPlacement {
        guard columns > 0 else { return TesseraTileGridPlacement(row: 0, column: 0) }

        var bottom = 0
        for item in placements where item.id != id {
            bottom = max(bottom, placementRect(item, columns: columns).bottom)
        }
        return clamped(cell: TesseraTileGridPlacement(row: bottom, column: 0), size: size, columns: columns)
    }

    /// The first free "top-left" cell for a size (first-fit).
    ///
    /// Rows are scanned top to bottom and columns left to right; the result is the first
    /// position where the whole rectangle is free. One is always found: below the last
    /// occupied row the space is free. Needed for move cases where the desired
    /// cell cannot be taken.
    ///
    /// - Parameters:
    ///   - size: The size of the element being placed.
    ///   - columns: The number of columns.
    ///   - placements: The current placement set.
    ///   - excluding: The identifier of an element that is ignored (the element being moved
    ///     frees its place).
    /// - Returns: The top-left corner cell.
    public static func firstFreeCell(
        size: TesseraTileSize,
        columns: Int,
        placements: [TesseraTilePlacedItem],
        excluding id: AnyHashable? = nil
    ) -> TesseraTileGridPlacement {
        guard columns > 0 else { return TesseraTileGridPlacement(row: 0, column: 0) }

        let fitted = fittingSize(size, columns: columns)
        let obstacles = placements
            .filter { $0.id != id }
            .map { placementRect($0, columns: columns) }
        let lastRow = obstacles.map(\.bottom).max() ?? 0

        for row in 0...max(0, lastRow) {
            for column in 0...(columns - fitted.unitColumns) {
                let candidate = PlacementRect(
                    row: row,
                    column: column,
                    width: fitted.unitColumns,
                    height: fitted.unitRows
                )
                if !obstacles.contains(where: { $0.overlaps(candidate) }) {
                    return TesseraTileGridPlacement(row: row, column: column)
                }
            }
        }
        return TesseraTileGridPlacement(row: max(0, lastRow), column: 0)
    }

    // MARK: Internals

    /// The element footprint: the cell plus the size shrunk to a narrow grid.
    fileprivate static func placementRect(_ item: TesseraTilePlacedItem, columns: Int) -> PlacementRect {
        let fitted = fittingSize(item.size, columns: columns)
        return PlacementRect(
            row: item.cell.row,
            column: item.cell.column,
            width: fitted.unitColumns,
            height: fitted.unitRows
        )
    }
}
