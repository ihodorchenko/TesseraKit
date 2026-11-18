// Layout of the start screen tile grid in unit coordinates.
// Design document: docs/STARTSCREEN-IOS-DESIGN.md — §3 "Tile grid"
// (the unit formula, unit coordinates, holes are allowed) and §14 "MVP clarifications"
// (D15: four sizes — 1×1, 2×2, 4×2, 4×4).
//
// Order-based packing is strictly compact: ``TesseraTileLayoutEngine/pack(items:columns:unit:)``
// (implemented by ``TesseraTileLayoutEngine/packCompact(items:columns:unit:)``) puts
// tiles at the topmost-leftmost position and collapses the layout up and to the left. Since
// D30 this is **not** the main start screen layout but a fallback path (see below):
// normally tiles sit at explicit cells and holes are preserved.
//
// D17 (docs/DECISIONS.md) — the expanded folder panel: pure functions for the panel insertion index
// after the folder band, for the row offset below the panel, and for its height — at the
// end of the file. Also here: the pixel alignment of the unit and the grid geometry
// (``TesseraTileLayoutEngine/gridMetrics(contentWidth:columns:spacing:scale:)``).
// The main part of the engine stays free of UIKit and state.
//
// Placement by coordinates (`TesseraTileLayoutEngine+Placement.swift`): the drag
// preview, resize, insertion, and collapsing of empty rows work over a set of
// `TesseraTilePlacedItem` (identifier, size, cell). ``pack(items:columns:unit:)``
// remains order-based packing: a fallback for the grid layout without a cell table,
// the v1 → v2 migration, projection onto a different canvas width (D32), and the first-launch layout
// (`packCompact`).
//
// The module is intentionally pure: only CoreGraphics (`CGFloat`, `CGSize`, `CGRect`),
// the `TesseraTileSize` model, and the grid snapshot elements. No UIKit, layout context, or
// state — all functions are deterministic and testable without UI.

import CoreGraphics

/// A tile position on the grid in unit coordinates
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, "Layout model").
///
/// The position is stored as a ``column``/``row`` pair in units, not in points: on
/// screen rotation or a width change only ``unit`` changes, while unit
/// coordinates stay the same. ``size`` describes the requested tile size
/// (D15), ``unitColumns``/``unitRows`` — its actual footprint on the grid.
///
/// ``frame`` is a "raw" frame in points without gaps (unit × unit
/// coordinates). The final geometry with gaps between units and the content
/// origin is computed with ``TesseraTileLayoutEngine/rect(for:unit:gap:origin:)``.
public struct TesseraTileLayoutSlot: Equatable {
    /// The identifier of the tile the slot belongs to.
    public let id: AnyHashable

    /// The requested tile size (D15).
    public let size: TesseraTileSize

    /// The top-left corner column in units (zero-based, left to right).
    public let column: Int

    /// The top-left corner row in units (zero-based, top to bottom).
    public let row: Int

    /// The size of one unit in points that this layout was computed with.
    ///
    /// Stored as a snapshot so that ``frame`` and
    /// ``TesseraTileLayoutEngine/rect(for:unit:gap:origin:)`` can work without
    /// the geometry being passed again. On rotation or a width change the layout
    /// is rebuilt with ``TesseraTileLayoutEngine/pack(items:columns:unit:)`` and the new
    /// unit — unit coordinates do not change.
    public let unit: CGFloat

    /// Creates a layout slot.
    ///
    /// Slots are usually created by ``TesseraTileLayoutEngine/pack(items:columns:unit:)``;
    /// the initializer is public so that tests and consumers can build
    /// an expected value without running packing.
    ///
    /// - Parameters:
    ///   - id: The tile identifier.
    ///   - size: The tile size in units.
    ///   - column: The top-left corner column in units.
    ///   - row: The top-left corner row in units.
    ///   - unit: The unit size in points.
    public init(id: AnyHashable, size: TesseraTileSize, column: Int, row: Int, unit: CGFloat) {
        self.id = id
        self.size = size
        self.column = column
        self.row = row
        self.unit = unit
    }

    /// The footprint width of the tile in units.
    public var unitColumns: Int {
        size.unitColumns
    }

    /// The footprint height of the tile in units.
    public var unitRows: Int {
        size.unitRows
    }

    /// The slot rectangle in unit coordinates: `x = column`, `y = row`,
    /// `width = unitColumns`, `height = unitRows`.
    ///
    /// Handy for checks and debugging; for points use ``frame`` or
    /// ``TesseraTileLayoutEngine/rect(for:unit:gap:origin:)``.
    public var unitFrame: CGRect {
        CGRect(
            x: CGFloat(column),
            y: CGFloat(row),
            width: CGFloat(unitColumns),
            height: CGFloat(unitRows)
        )
    }

    /// The slot frame in points without gaps between units.
    ///
    /// This is `unit × unitFrame`. The real grid adds gaps between adjacent
    /// units, so drawing needs
    /// ``TesseraTileLayoutEngine/rect(for:unit:gap:origin:)``: it also accounts for
    /// the inner gaps of wide and large tiles.
    ///
    /// For a non-finite or non-positive ``unit`` it returns `.zero`.
    public var frame: CGRect {
        guard unit.isFinite, unit > 0 else { return .zero }

        return CGRect(
            x: CGFloat(column) * unit,
            y: CGFloat(row) * unit,
            width: CGFloat(unitColumns) * unit,
            height: CGFloat(unitRows) * unit
        )
    }
}

/// Pure layout functions of the tile grid
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, "Tile grid"; D15 in docs/DECISIONS.md).
///
/// The grid is described by the number of columns and the unit size in points. Order-based
/// packing (`pack`/`packCompact`) is strictly compact: every tile goes to the
/// topmost-leftmost position where it fits entirely, and after placement the whole
/// layout can be "collapsed" up and to the left to a fixed point. This is the fallback
/// path (a grid without a usable cell table), the v1 → v2 file migration, projection
/// onto a different canvas width (D32), and the first-launch layout. The main
/// layout is by explicit cells (`TesseraTileLayoutEngine+Placement.swift`, D30):
/// holes are preserved, collisions push tiles down (D31). The history of abandoning
/// "honest holes" and returning to them is in "Implementation notes and deviations" of
/// docs/STARTSCREEN-IOS-DESIGN.md.
///
/// All functions are `static` and hold no state: the result depends only on
/// the arguments. The reading direction (RTL) is not taken into account here — grid
/// mirroring is done by the view layer (document §9, "RTL"), and the engine works in
/// LTR coordinates.
public enum TesseraTileLayoutEngine {

    /// The default number of grid columns — 6 small columns (D26).
    ///
    /// As in Windows 10 Mobile (docs/W10M-STARTSCREEN.md §2): three medium tiles
    /// in a row, a wide one takes 4 columns of 6, a large one is 4×4. The single
    /// source of the default for ``TesseraTileGridView/columns`` and for the
    /// ``TesseraTileStore`` methods without a grid; the host may set its own `columns`.
    public static let defaultColumns = 6

    /// The size of one grid unit in points
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, "Layout model").
    ///
    /// The document formula: `unit = (screenWidth − margins − gaps × (N − 1)) / N`.
    /// The signature has no separate `margins`, so
    /// `screenWidth` is the already available content width: the host subtracts the outer
    /// margins itself, and the `gaps` parameter is the gap between two adjacent columns.
    ///
    /// Defensive cases: `columns <= 0`, non-finite `screenWidth`/`gaps`,
    /// a negative gap (treated as 0), and the situation when the gaps eat
    /// the whole width give `0`. A negative result is impossible.
    ///
    /// - Parameters:
    ///   - screenWidth: The available grid width in points (without outer margins).
    ///   - columns: The number of columns, greater than zero.
    ///   - gaps: The gap between adjacent columns in points.
    /// - Returns: The unit size in points, or `0` for degenerate geometry.
    public static func unit(screenWidth: CGFloat, columns: Int, gaps: CGFloat) -> CGFloat {
        guard columns > 0, screenWidth.isFinite, gaps.isFinite else { return 0 }

        let spacing = max(gaps, 0)
        let available = screenWidth - spacing * CGFloat(columns - 1)

        guard available.isFinite, available > 0 else { return 0 }

        return available / CGFloat(columns)
    }

    // MARK: - Pixel alignment

    /// The unit size rounded down to the screen's pixel grid.
    ///
    /// The formula is the same as in ``unit(screenWidth:columns:gaps:)``, but the result
    /// is rounded **down** to a multiple of `1 / scale`: at a width of 393 pt
    /// (content 361 pt, gap 8) the "raw" unit of 84.25 pt gives fractional pixels and
    /// blurry tile edges, while the aligned one is 84 pt at 3× and 84 pt at 2×. The width
    /// remainder is split equally into margins by the layout (the grid is centered, see
    /// ``gridMetrics(contentWidth:columns:spacing:scale:)``).
    ///
    /// For `scale <= 0` or a non-finite scale there is no alignment, and the result equals
    /// ``unit(screenWidth:columns:gaps:)``.
    ///
    /// - Parameters:
    ///   - screenWidth: The available grid width in points (without outer margins).
    ///   - columns: The number of columns, greater than zero.
    ///   - gaps: The gap between adjacent columns in points.
    ///   - scale: The screen scale (`displayScale`): pixels per point.
    /// - Returns: The unit in points, a multiple of `1 / scale`, or `0` for degenerate
    ///   geometry.
    public static func unit(
        screenWidth: CGFloat,
        columns: Int,
        gaps: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        pixelFloor(unit(screenWidth: screenWidth, columns: columns, gaps: gaps), scale: scale)
    }

    /// The pixel grid rounding tolerance: absorbs floating-point error
    /// (`84 × 3` may come out as `251.99999999`).
    private static let pixelEpsilon: CGFloat = 1e-6

    /// Normalizes the scale: a positive finite one is kept as is, otherwise `0`
    /// ("do not align").
    private static func alignmentScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 0
    }

    /// Rounds a value down to a multiple of `1 / scale`.
    ///
    /// - Parameters:
    ///   - value: The length in points.
    ///   - scale: The screen scale; `<= 0` leaves the value unchanged.
    /// - Returns: The aligned length.
    static func pixelFloor(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = alignmentScale(scale)
        guard scale > 0, value.isFinite else { return value }
        return (value * scale + pixelEpsilon).rounded(.down) / scale
    }

    /// Rounds a value to the nearest multiple of `1 / scale`.
    ///
    /// - Parameters:
    ///   - value: A length or coordinate in points.
    ///   - scale: The screen scale; `<= 0` leaves the value unchanged.
    /// - Returns: The aligned value.
    static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = alignmentScale(scale)
        guard scale > 0, value.isFinite else { return value }
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// The horizontal grid geometry in points.
    ///
    /// The same for desktop tiles and for the tiles of an expanded folder's
    /// panel: both sides compute it from the content width, gap, and scale,
    /// so the columns match to the pixel.
    struct GridMetrics: Equatable {

        /// The number of columns.
        var columns: Int

        /// The unit in points (pixel-aligned if a scale is given).
        var unit: CGFloat

        /// The gap between units in points (sanitized and aligned).
        var spacing: CGFloat

        /// The grid offset from the start of the content width: half of the remainder after
        /// aligning the unit (the grid is centered).
        var leading: CGFloat

        /// The width taken by `columns` units with gaps.
        var width: CGFloat

        /// The column offset from the start of the content width in LTR coordinates.
        ///
        /// - Parameter column: The zero-based column number.
        /// - Returns: The left edge of the column in points.
        func columnOffset(_ column: Int) -> CGFloat {
            leading + CGFloat(column) * (unit + spacing)
        }
    }

    /// Computes the horizontal grid geometry with pixel alignment.
    ///
    /// 1. The gap is sanitized (negative and non-finite become 0) and rounded
    ///    to the nearest pixel.
    /// 2. The unit is ``unit(screenWidth:columns:gaps:scale:)``: the §3 formula with
    ///    rounding down to a pixel.
    /// 3. The width remainder (`contentWidth − columns × unit − gaps`) is divided
    ///    equally into margins: the left margin gets half, rounded down to a pixel,
    ///    and the right one gets all the rest.
    ///
    /// Without a scale (`scale <= 0`) there is no alignment: the unit is the exact §3 formula,
    /// the remainder is zero, `leading == 0`.
    ///
    /// - Parameters:
    ///   - contentWidth: The grid content width (without outer margins).
    ///   - columns: The number of columns, greater than zero.
    ///   - spacing: The gap between units in points.
    ///   - scale: The screen scale; `<= 0` means do not align.
    /// - Returns: The geometry, or `nil` for a degenerate width/columns.
    static func gridMetrics(
        contentWidth: CGFloat,
        columns: Int,
        spacing: CGFloat,
        scale: CGFloat
    ) -> GridMetrics? {
        guard columns > 0, contentWidth.isFinite, contentWidth > 0 else { return nil }

        let alignedSpacing = pixelRound(spacing.isFinite ? max(spacing, 0) : 0, scale: scale)
        let alignedUnit = unit(
            screenWidth: contentWidth,
            columns: columns,
            gaps: alignedSpacing,
            scale: scale
        )
        guard alignedUnit.isFinite, alignedUnit > 0 else { return nil }

        let width = CGFloat(columns) * alignedUnit + CGFloat(columns - 1) * alignedSpacing
        let leading: CGFloat
        if alignmentScale(scale) > 0 {
            leading = pixelFloor(max(0, contentWidth - width) / 2, scale: scale)
        } else {
            leading = 0
        }

        return GridMetrics(
            columns: columns,
            unit: alignedUnit,
            spacing: alignedSpacing,
            leading: leading,
            width: width
        )
    }

    // MARK: - Expanded folder band

    /// The bottom edge of the "folder band" in unit rows (D17).
    ///
    /// The expanded folder panel is a full-width row, so it cannot
    /// sit right below the folder's last row if next to it stands a tile
    /// that starts in the folder's rows and ends lower (for example,
    /// a 2×2 tile from row 1 with a 2×2 folder in rows 0–1): the panel would cover
    /// its lower half. The band starts as `[folder.row, folder.row +
    /// unitRows)` and extends the bottom edge to `max(row + unitRows)` of all
    /// tiles intersecting the band, iteratively to a fixed point (an extension
    /// may catch the next tile).
    ///
    /// At the fixed point the split "stays / goes under the panel" by the
    /// top row `slot.row < bandEnd` is exact: a tile with `row < bandEnd`
    /// is either entirely above the band or intersects it — and then it is entirely
    /// inside it.
    ///
    /// - Parameters:
    ///   - folderSlot: The slot of the expanded folder's tile.
    ///   - slots: The slots of all layout tiles (the folder may be included).
    /// - Returns: The first row after the band: the panel starts from it.
    static func folderBandEndRow(for folderSlot: TesseraTileLayoutSlot, in slots: [TesseraTileLayoutSlot]) -> Int {
        let start = folderSlot.row
        var end = folderSlot.row + folderSlot.unitRows
        var changed = true

        while changed {
            changed = false
            for slot in slots where slot.row < end && slot.row + slot.unitRows > start {
                let bottom = slot.row + slot.unitRows
                if bottom > end {
                    end = bottom
                    changed = true
                }
            }
        }
        return end
    }

    /// Packs tiles strictly compactly
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3).
    ///
    /// **Order-based** packing is a fallback path (D30): the normal grid layout
    /// is by explicit cells and preserves holes, while this function is needed for
    /// rollback, the v1 → v2 migration, projection onto a different canvas width, and first
    /// launch. It works like
    /// ``packCompact(items:columns:unit:)``: each tile goes to the topmost-leftmost
    /// position where it fits entirely, then the layout
    /// collapses up and to the left to a fixed point. Empty units remain
    /// only where none of the **current** tiles fits; the "honest
    /// holes" of §3 are not allowed by this function.
    ///
    /// Strict compactness is a property of this function specifically: the layout by
    /// explicit cells does not apply it.
    ///
    /// The returned slots follow **the order of the input array**, not the grid
    /// traversal order: a slot can be matched to its tile by index. If
    /// a tile's width is greater than the column count (for example, `.wide` with `columns == 3`),
    /// the tile is skipped: the grid cannot draw it without distorting the size.
    ///
    /// - Parameters:
    ///   - items: "Tile identifier — tile size" pairs in grid order.
    ///   - columns: The number of columns, greater than zero (all D15 sizes need ≥ 4; the default is ``defaultColumns``).
    ///   - unit: The unit size in points, greater than zero.
    /// - Returns: Slots in the order of `items`; an empty array for degenerate
    ///   geometry or empty input.
    public static func pack(
        items: [(id: AnyHashable, size: TesseraTileSize)],
        columns: Int,
        unit: CGFloat
    ) -> [TesseraTileLayoutSlot] {
        packCompact(items: items, columns: columns, unit: unit)
    }

    // MARK: - Strict compactness

    /// Strictly compact packing: anchor + collapse.
    ///
    /// An algorithm in two phases:
    ///
    /// 1. **Anchor.** For each tile in array order, rows are scanned
    ///    top to bottom and columns left to right; the first position is chosen where
    ///    the whole `unitColumns × unitRows` rectangle is free. A later
    ///    tile therefore always takes a free place higher up, if there is one.
    /// 2. **Collapse.** ``stabilize(_:columns:)`` takes each tile off the
    ///    grid and looks for an earlier position for it (higher or further left in the same
    ///    row); the pass repeats to a fixed point. The anchor phase already
    ///    gives a fixed point for the current order, so in practice
    ///    the collapse moves nothing — it guarantees the invariant and insures
    ///    against future changes of the anchor strategy.
    ///
    /// A hole remains only where none of the current tiles fits
    /// (for example, to the right of a 2×2 if the next tile is 4×2). This is not an "honest
    /// hole" of §3 but a footprint of sizes: there is nothing to move into it. If a tile of
    /// a suitable size appears later, it takes this place on repacking; if
    /// a tile was dragged away, the lower ones move up.
    ///
    /// - Parameters:
    ///   - items: "Tile identifier — tile size" pairs in grid order.
    ///   - columns: The number of columns, greater than zero.
    ///   - unit: The unit size in points, greater than zero.
    /// - Returns: Slots in the order of `items`; an empty array for degenerate
    ///   geometry or empty input.
    static func packCompact(
        items: [(id: AnyHashable, size: TesseraTileSize)],
        columns: Int,
        unit: CGFloat
    ) -> [TesseraTileLayoutSlot] {
        guard columns > 0, unit.isFinite, unit > 0 else { return [] }

        // Phase 1 "anchor": grid occupancy is a matrix, because the scan goes
        // row by row and consecutively; rows are added as the packing grows.
        var occupied: [[Bool]] = []
        var slots: [TesseraTileLayoutSlot] = []
        slots.reserveCapacity(items.count)

        for item in items {
            let width = item.size.unitColumns
            let height = item.size.unitRows

            // A tile wider than the grid does not fit without distorting the size.
            guard width > 0, height > 0, width <= columns else { continue }

            var row = 0
            while true {
                ensureRows(&occupied, count: row + height, columns: columns)

                if let column = firstFreeColumn(
                    in: occupied,
                    row: row,
                    width: width,
                    height: height,
                    columns: columns
                ) {
                    markOccupied(
                        &occupied,
                        column: column,
                        row: row,
                        width: width,
                        height: height
                    )
                    slots.append(
                        TesseraTileLayoutSlot(
                            id: item.id,
                            size: item.size,
                            column: column,
                            row: row,
                            unit: unit
                        )
                    )
                    break
                }

                row += 1
            }
        }

        // Phase 2 "collapse": holes into which a tile can be moved up or
        // left do not remain.
        return stabilize(slots, columns: columns)
    }

    /// Collapses the layout up and to the left to a fixed point.
    ///
    /// Each tile in turn is taken off the grid and put at the earliest
    /// free position: first the rows above, then — in its own row — to the left of
    /// the current column. A position "to the right in the same row" or "below" is not
    /// considered an improvement, so the order of the slot array does not change —
    /// only the coordinates move.
    ///
    /// The pass repeats while at least one tile moved: moving an upper
    /// tile frees space for a lower one. Each move strictly decreases the
    /// lexicographic key `(row, column)` of one tile, so the loop
    /// is finite (there is a finite number of keys, and the sum of keys decreases).
    ///
    /// The function is internal: the public packing is ``pack(items:columns:unit:)``.
    /// An artificially "hanging" tile that has to be lifted
    /// is tested separately.
    ///
    /// - Parameters:
    ///   - slots: Slots in any order; coordinates are non-negative.
    ///   - columns: The number of columns, greater than zero.
    /// - Returns: Slots in the original order with compact coordinates; for
    ///   degenerate arguments (non-positive coordinates, a tile wider than the grid)
    ///   — the input array unchanged.
    static func stabilize(_ slots: [TesseraTileLayoutSlot], columns: Int) -> [TesseraTileLayoutSlot] {
        guard columns > 0, !slots.isEmpty else { return slots }
        guard slots.allSatisfy({
            $0.unitColumns > 0
                && $0.unitRows > 0
                && $0.unitColumns <= columns
                && $0.column >= 0
                && $0.row >= 0
        }) else {
            return slots
        }

        var working = slots

        // The occupancy matrix of the whole layout: the height reaches the last occupied row.
        var height = 0
        for slot in working {
            height = max(height, slot.row + slot.unitRows)
        }
        var occupied = Array(
            repeating: Array(repeating: false, count: columns),
            count: height
        )
        for slot in working {
            markOccupied(
                &occupied,
                column: slot.column,
                row: slot.row,
                width: slot.unitColumns,
                height: slot.unitRows
            )
        }

        var didMove = true
        while didMove {
            didMove = false

            // Traversal top to bottom and left to right: moving an upper tile
            // frees space for a lower one in the same pass.
            let order = working.indices.sorted { lhs, rhs in
                let left = working[lhs]
                let right = working[rhs]
                if left.row != right.row {
                    return left.row < right.row
                }
                return left.column < right.column
            }

            for index in order {
                let slot = working[index]

                // We take the tile off: its own units do not interfere with the search.
                unmarkOccupied(
                    &occupied,
                    column: slot.column,
                    row: slot.row,
                    width: slot.unitColumns,
                    height: slot.unitRows
                )

                if let target = firstEarlierFreePosition(
                    in: occupied,
                    column: slot.column,
                    row: slot.row,
                    width: slot.unitColumns,
                    height: slot.unitRows,
                    columns: columns
                ) {
                    working[index] = TesseraTileLayoutSlot(
                        id: slot.id,
                        size: slot.size,
                        column: target.column,
                        row: target.row,
                        unit: slot.unit
                    )
                    markOccupied(
                        &occupied,
                        column: target.column,
                        row: target.row,
                        width: slot.unitColumns,
                        height: slot.unitRows
                    )
                    didMove = true
                } else {
                    markOccupied(
                        &occupied,
                        column: slot.column,
                        row: slot.row,
                        width: slot.unitColumns,
                        height: slot.unitRows
                    )
                }
            }
        }

        return working
    }

    /// Converts a slot from unit coordinates to a frame in points
    /// (docs/STARTSCREEN-IOS-DESIGN.md §3, "Layout model").
    ///
    /// Coordinates:
    /// - `x = origin.x + column × (unit + gap)`,
    /// - `y = origin.y + row × (unit + gap)`,
    /// - `width = unitColumns × unit + (unitColumns − 1) × gap`,
    /// - `height = unitRows × unit + (unitRows − 1) × gap`.
    ///
    /// Inner gaps are part of the frame of a wide/large tile: a 2×2 tile
    /// takes two units and the gap between them, rather than "eating" it.
    ///
    /// - Parameters:
    ///   - slot: The slot in unit coordinates.
    ///   - unit: The unit size in points; `nil` means use
    ///     ``TesseraTileLayoutSlot/unit``, which the slot was computed with.
    ///   - gap: The gap between adjacent units in points; negative
    ///     is treated as 0.
    ///   - origin: The content origin of the grid (for example, `contentInset`).
    /// - Returns: A frame in points; `.zero` for a non-finite/non-positive
    ///   unit or an empty tile footprint.
    public static func rect(
        for slot: TesseraTileLayoutSlot,
        unit: CGFloat? = nil,
        gap: CGFloat = 0,
        origin: CGPoint = .zero
    ) -> CGRect {
        let scale = unit ?? slot.unit
        guard scale.isFinite, scale > 0 else { return .zero }

        let columns = slot.unitColumns
        let rows = slot.unitRows
        guard columns > 0, rows > 0 else { return .zero }

        let spacing = gap.isFinite ? max(gap, 0) : 0

        return CGRect(
            x: origin.x + CGFloat(slot.column) * (scale + spacing),
            y: origin.y + CGFloat(slot.row) * (scale + spacing),
            width: CGFloat(columns) * scale + CGFloat(columns - 1) * spacing,
            height: CGFloat(rows) * scale + CGFloat(rows - 1) * spacing
        )
    }

    // MARK: - Expanded folder panel (D17)

    /// The panel's vertical inner padding, in points.
    ///
    /// Horizontally the panel content adds no padding: tiles go into the same
    /// columns as the desktop tiles (the panel is already bounded by the layout margins).
    /// The header padding is ``panelPadding`` on each side.
    static let panelPadding: CGFloat = 12

    /// The panel header row height in points (one Dynamic Type line).
    static let panelHeaderHeight: CGFloat = 44

    /// The gap between the header and the panel content grid in points.
    static let panelHeaderSpacing: CGFloat = 8

    /// The default gap between the panel content grid cells, in points.
    ///
    /// Matches the default layout `itemSpacing`. The panel layout and cell
    /// take the actual grid gap (`itemSpacing`) so that
    /// the panel tiles land in the same columns as the tiles under the panel; this
    /// value is only for legacy inputs without a gap
    /// (``panelHeight(for:width:columns:)``, ``panelHeight(tileCount:width:columns:)``).
    static let panelContentSpacing: CGFloat = 8

    /// The height of the full-width expanded folder panel in points with the default gap
    /// and without pixel alignment (D17).
    ///
    /// A legacy input: equal to
    /// ``panelHeight(tileCount:width:columns:spacing:scale:)`` with the gap
    /// ``panelContentSpacing`` and `scale == 0`.
    ///
    /// - Parameters:
    ///   - tileCount: The number of tiles in the panel content grid; a negative value
    ///     is treated as 0.
    ///   - width: The full panel width in points (the grid content width).
    ///   - columns: The number of columns of the panel content grid, greater than zero.
    /// - Returns: The panel height in points.
    static func panelHeight(tileCount: Int, width: CGFloat, columns: Int) -> CGFloat {
        panelHeight(
            tileCount: tileCount,
            width: width,
            columns: columns,
            spacing: panelContentSpacing,
            scale: 0
        )
    }

    /// The height of the full-width expanded folder panel in points (D17).
    ///
    /// The panel consists of a header row and a square content grid:
    ///
    /// - the outer top and bottom padding is 12 pt each (`panelPadding`);
    /// - the header is 44 pt: the height is fixed because the header takes
    ///   exactly one line;
    /// - the gap between the header and the grid is 8 pt (`panelHeaderSpacing`);
    /// - the content tiles are square: their side and the gaps between them are the unit and
    ///   the gap of the **desktop grid** with the same pixel alignment
    ///   (``gridMetrics(contentWidth:columns:spacing:scale:)``), so a panel
    ///   tile is the same 1×1 tile in the same columns as the tiles under the panel.
    ///
    /// The final formula (rows are `ceil(count / columns)`):
    ///
    /// `height = padding × 2 + header + header gap + rows × unit +
    /// (rows − 1) × grid gap`.
    ///
    /// The formula must match the metrics of `TesseraFolderPanelCell`: the cell
    /// lays out its content with these same numbers, so the panel height exactly
    /// fits the last row of tiles.
    ///
    /// Degenerate geometry (a non-finite/non-positive width, a width where the
    /// gaps eat all the space, `columns <= 0`) gives `0`: a panel without height,
    /// like a tile without room.
    ///
    /// - Parameters:
    ///   - tileCount: The number of tiles; a negative value is treated as 0.
    ///   - width: The full panel width in points (the grid content width without
    ///     the layout's outer margins).
    ///   - columns: The number of columns of the panel content grid, greater than zero.
    ///   - spacing: The desktop grid gap (`itemSpacing`).
    ///   - scale: The screen scale; `<= 0` means no pixel alignment.
    /// - Returns: The panel height in points.
    static func panelHeight(
        tileCount: Int,
        width: CGFloat,
        columns: Int,
        spacing: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        guard let metrics = gridMetrics(
            contentWidth: width,
            columns: columns,
            spacing: spacing,
            scale: scale
        ) else {
            return 0
        }

        let count = max(0, tileCount)
        let rows = count == 0 ? 0 : (count + columns - 1) / columns
        let headerHeight = panelPadding * 2 + panelHeaderHeight

        guard rows > 0 else { return pixelRound(headerHeight, scale: scale) }

        let contentHeight = CGFloat(rows) * metrics.unit + CGFloat(rows - 1) * metrics.spacing
        return pixelRound(headerHeight + panelHeaderSpacing + contentHeight, scale: scale)
    }

    /// Shrinks a tile footprint for a narrow grid without changing the model (D15).
    ///
    /// D15 is designed for at least 4 columns (6 by default, D26); with fewer
    /// columns a wide tile does not fit. Instead of skipping the tile (which would break the
    /// "index → element" correspondence) the nearest smaller size is taken: 2×2 with two or three
    /// columns and 1×1 with one. This is a degradation of geometry, not of the model:
    /// the tile's `TesseraTileSize` in `TesseraTileStore` does not change.
    ///
    /// Relation to the column clamp: a tile's footprint on the grid is always
    /// `fittingSize`, so `column + width ≤ columns` is achievable for any
    /// cell: ``clamped(cell:size:columns:)`` shifts the column left precisely by the
    /// shrunk width. With 6 columns (D26) there is no shrinking — all four D15 sizes
    /// (at most 4 columns) fit as is; shrinking works only with
    /// `columns < 4`. The function depends only on the width and does not change behavior.
    ///
    /// - Parameters:
    ///   - size: The requested tile size.
    ///   - columns: The number of grid columns.
    /// - Returns: A size that is guaranteed to fit the grid.
    static func fittingSize(_ size: TesseraTileSize, columns: Int) -> TesseraTileSize {
        guard columns > 0 else { return size }
        guard size.unitColumns > columns else { return size }
        return columns >= 2 ? .medium : .small
    }

    // MARK: - Internal packing

    /// Extends the occupancy matrix to `count` rows.
    private static func ensureRows(_ grid: inout [[Bool]], count: Int, columns: Int) {
        guard grid.count < count else { return }

        let newRows = Array(
            repeating: Array(repeating: false, count: columns),
            count: count - grid.count
        )
        grid.append(contentsOf: newRows)
    }

    /// Looks for the first free column in row `row` for a rectangle
    /// `width × height`.
    private static func firstFreeColumn(
        in grid: [[Bool]],
        row: Int,
        width: Int,
        height: Int,
        columns: Int
    ) -> Int? {
        guard width <= columns else { return nil }

        for column in 0...(columns - width) {
            if isFree(in: grid, column: column, row: row, width: width, height: height) {
                return column
            }
        }
        return nil
    }

    /// Checks that a rectangle is entirely free.
    ///
    /// The caller must extend the matrix to `row + height` rows beforehand
    /// (``ensureRows``), so indexing here is safe.
    private static func isFree(
        in grid: [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) -> Bool {
        for currentRow in row..<(row + height) {
            for currentColumn in column..<(column + width) where grid[currentRow][currentColumn] {
                return false
            }
        }
        return true
    }

    /// Marks a rectangle as occupied.
    private static func markOccupied(
        _ grid: inout [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) {
        for currentRow in row..<(row + height) {
            for currentColumn in column..<(column + width) {
                grid[currentRow][currentColumn] = true
            }
        }
    }

    /// Clears the occupancy mark of a rectangle.
    ///
    /// Needed by the collapse: a tile is temporarily "lifted" off the grid so that its
    /// own units do not interfere with the search for an earlier position.
    private static func unmarkOccupied(
        _ grid: inout [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int
    ) {
        for currentRow in row..<(row + height) {
            for currentColumn in column..<(column + width) {
                grid[currentRow][currentColumn] = false
            }
        }
    }

    /// Looks for the earliest free position that comes **before** the current one.
    ///
    /// The traversal is the same as in anchor packing: top to bottom, left to right. Rows
    /// above are checked entirely — a move up is allowed into any column; in
    /// its own row — only the columns left of the current one. The source position is
    /// not part of the check: the caller has already taken the rectangle off the grid.
    ///
    /// The caller must keep at least `row + height` rows in the matrix:
    /// the collapse builds it up to the layout's last occupied row, which is
    /// no less than any slot position.
    ///
    /// - Parameters:
    ///   - grid: The grid occupancy without the tile being checked.
    ///   - column: The tile's current column.
    ///   - row: The tile's current row.
    ///   - width: The tile footprint width in units.
    ///   - height: The tile footprint height in units.
    ///   - columns: The number of grid columns.
    /// - Returns: The column and row of an earlier position, or `nil`.
    private static func firstEarlierFreePosition(
        in grid: [[Bool]],
        column: Int,
        row: Int,
        width: Int,
        height: Int,
        columns: Int
    ) -> (column: Int, row: Int)? {
        guard width <= columns else { return nil }

        for currentRow in 0...row {
            let lastColumn = currentRow == row ? column - 1 : columns - width
            guard lastColumn >= 0 else { continue }

            for currentColumn in 0...lastColumn {
                if isFree(
                    in: grid,
                    column: currentColumn,
                    row: currentRow,
                    width: width,
                    height: height
                ) {
                    return (column: currentColumn, row: currentRow)
                }
            }
        }
        return nil
    }
}

#if canImport(UIKit)

/// The expanded folder panel: pure functions of position and shift (D17).
///
/// Expanding a folder in the Windows Phone style (D17) inserts the panel
/// ``TesseraTileGridItem/folderContent(_:)`` **after the folder band** — the rows of the
/// ``TesseraTileGridItem/folder(_:)`` tile, extended down by the tiles that start
/// in those rows and end lower (``folderBandEndRow(for:in:)``).
/// The folder tile itself stays in place and remains visible the whole time the folder is
/// expanded: the panel is a separate full-width row under the band, not a replacement
/// of the tile. The panel stretches to the full grid width and grows down to
/// ``panelHeight(for:width:columns:spacing:scale:)``; everything that starts below
/// the band goes under the panel — visually the rows shift down by its height and
/// the grid gap. The geometry in points itself is assembled by
/// `TesseraTileCollectionViewLayout`.
///
/// The functions of this extension know nothing about UICollectionView: given the model,
/// the column count, and the panel height, they answer questions — at which array index
/// to insert the panel, whether there is anything under the panel to shift, and how tall
/// the panel will be.
///
/// Placement is computed by the same strictly compact packing as the
/// regular layout: the functions call ``pack(items:columns:unit:)`` with a unit of 1.
/// Unit
/// coordinates do not depend on the scale, so a unit of one gives exactly the same
/// rows and columns as the real geometry in points.
extension TesseraTileLayoutEngine {

    /// The expansion geometry in unit coordinates.
    ///
    /// `slots` are the slots of all elements of the set except the panel itself (the panel is not
    /// packed as a tile); `bandEndRow` is the first row after the "folder
    /// band" (``folderBandEndRow(for:in:)``): the full-width
    /// panel row starts from it.
    private struct FolderPanelGeometry {

        /// Element slots by identifier.
        var slots: [AnyHashable: TesseraTileLayoutSlot]

        /// The first row after the folder band: the panel starts from it.
        /// Everything that starts above stays in place; everything that starts from
        /// it and lower goes under the panel.
        var bandEndRow: Int

        /// The folder index in the original element array.
        var folderIndex: Int
    }

    /// Computes the unit coordinates of the elements and the bottom edge of the folder band.
    ///
    /// - Parameters:
    ///   - items: The grid elements in display order.
    ///   - columns: The number of columns, greater than zero.
    ///   - expandedFolderID: The identifier of the expanded folder.
    /// - Returns: The geometry, or `nil` if there is no folder in the set.
    private static func folderPanelGeometry(
        items: [TesseraTileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable
    ) -> FolderPanelGeometry? {
        guard columns > 0 else { return nil }

        guard let folderIndex = items.firstIndex(where: { item in
            guard case .folder(let folder) = item else { return false }
            return folder.id == expandedFolderID
        }) else {
            return nil
        }

        // The panel does not take part in packing: it is not a tile but a separate row under
        // the folder, whose height is computed in points, not in units.
        let packItems: [(id: AnyHashable, size: TesseraTileSize)] = items.compactMap { item in
            guard !item.isFolderPanel else { return nil }
            return (id: item.id, size: fittingSize(item.size, columns: columns))
        }
        let packedSlots = pack(items: packItems, columns: columns, unit: 1)

        var slots: [AnyHashable: TesseraTileLayoutSlot] = [:]
        slots.reserveCapacity(packedSlots.count)
        for slot in packedSlots {
            slots[slot.id] = slot
        }

        guard let folderSlot = slots[expandedFolderID] else { return nil }

        return FolderPanelGeometry(
            slots: slots,
            bandEndRow: folderBandEndRow(for: folderSlot, in: packedSlots),
            folderIndex: folderIndex
        )
    }

    /// The array index for the panel without taking the layout into account (D17).
    ///
    /// A legacy input: the panel goes right after the folder tile (the folder index
    /// + 1), band neighbors are not taken into account, so the order of
    /// elements may not match the visual one. The grid uses
    /// ``folderPanelInsertionIndex(items:columns:expandedFolderID:)``.
    ///
    /// - Parameters:
    ///   - items: The base grid elements in display order (a snapshot of
    ///     `TesseraTileStore`, without the panel).
    ///   - expandedFolderID: The identifier of the expanded folder; `nil` means no expansion.
    /// - Returns: The index of the folder tile + 1, or `nil` if there is no such folder or
    ///   the panel is already present in the set.
    public static func folderPanelInsertionIndex(
        items: [TesseraTileGridItem],
        expandedFolderID: AnyHashable?
    ) -> Int? {
        guard let expandedFolderID else { return nil }
        guard !items.contains(where: { $0.isFolderPanel }) else { return nil }
        guard let folderIndex = items.firstIndex(where: { item in
            guard case .folder(let folder) = item else { return false }
            return folder.id == expandedFolderID
        }) else {
            return nil
        }
        return folderIndex + 1
    }

    /// The array index from which the panel is inserted into the element set
    /// (D17).
    ///
    /// The panel is a separate element of the set, not a replacement of a tile: the folder tile
    /// stays at its index, so `displayItems.count == items.count + 1`.
    /// Geometrically the panel sits as a full-width row under the **folder band**
    /// (``folderBandEndRow(for:in:)``): tiles that start in the folder's rows
    /// and end lower stay above the panel together with the folder. So that the
    /// element order matches the visual one (VoiceOver, collection indices),
    /// the panel is inserted after the **last** element in the array that
    /// stays above the panel (`row < bandEnd`) — but not earlier than right after
    /// the folder tile.
    ///
    /// An example (4 columns): `[folder 2×2, small, small, tile 2×2]` — the tile
    /// sits in rows 1–2, the band is rows 0–2, the insertion index is 4 (after
    /// the tile), not 1.
    ///
    /// - Parameters:
    ///   - items: The base grid elements in display order (a snapshot of
    ///     `TesseraTileStore`, without the panel).
    ///   - columns: The number of grid columns. With `columns <= 0` there is no geometry, and
    ///     the result matches ``folderPanelInsertionIndex(items:expandedFolderID:)``.
    ///   - expandedFolderID: The identifier of the expanded folder; `nil` means no expansion.
    /// - Returns: The index for inserting `.folderContent(folder)`, or `nil` if
    ///   there is no such folder or the panel is already present in the set.
    public static func folderPanelInsertionIndex(
        items: [TesseraTileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable?
    ) -> Int? {
        guard let fallback = folderPanelInsertionIndex(
            items: items,
            expandedFolderID: expandedFolderID
        ) else {
            return nil
        }
        guard let expandedFolderID,
              let geometry = folderPanelGeometry(
                  items: items,
                  columns: columns,
                  expandedFolderID: expandedFolderID
              ) else {
            return fallback
        }

        var lastIndexAbovePanel = geometry.folderIndex
        for (index, item) in items.enumerated() {
            guard let slot = geometry.slots[item.id],
                  slot.row < geometry.bandEndRow else { continue }
            lastIndexAbovePanel = max(lastIndexAbovePanel, index)
        }
        return lastIndexAbovePanel + 1
    }

    /// The row offset under the panel from its top edge in points (D17).
    ///
    /// The panel sits as a full-width row right after the **folder band**
    /// (``folderBandEndRow(for:in:)``) and grows down. Everything that **starts**
    /// from this row and lower, the layout puts under the panel: the first row under
    /// the panel starts at `panelHeight + spacing` from its top edge —
    /// exactly by that much the rows shift down that before expansion
    /// started where the panel is. The band elements (for example, a small tile to the right of
    /// a 2×2 folder or a 2×2 tile starting in the folder's rows) stay in
    /// place: the panel starts below them.
    ///
    /// The function is needed by tests and by the host that computes scrolling: the layout
    /// itself puts elements under the panel by the same rule. If there is
    /// nothing under the panel (the folder band is the last), the shift is `0`; if the panel is already
    /// in the set, it is also `0`: its effect is already accounted for by the layout.
    ///
    /// - Parameters:
    ///   - items: The base grid elements in display order (without the panel).
    ///   - columns: The number of grid columns, greater than zero.
    ///   - expandedFolderID: The identifier of the expanded folder.
    ///   - panelHeight: The panel height in points, computed
    ///     ``panelHeight(for:width:columns:spacing:scale:)``.
    ///   - spacing: The grid gap (`itemSpacing`), 8 pt by default — the default layout
    ///     gap; negative and non-finite mean 0.
    /// - Returns: `panelHeight + spacing` if there is something under the panel to shift,
    ///   otherwise `0`.
    public static func rowsBelowOffset(
        items: [TesseraTileGridItem],
        columns: Int,
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat,
        spacing: CGFloat = 8
    ) -> CGFloat {
        guard panelHeight.isFinite, panelHeight > 0 else { return 0 }
        guard columns > 0, let expandedFolderID else { return 0 }
        guard !items.contains(where: { $0.isFolderPanel }) else { return 0 }
        guard let geometry = folderPanelGeometry(
            items: items,
            columns: columns,
            expandedFolderID: expandedFolderID
        ) else {
            return 0
        }

        // Everything that starts from the row right after the folder band goes under the panel.
        // The folder itself is not counted: the panel sits under it, not in its place.
        for (index, item) in items.enumerated() where !item.isFolderPanel {
            guard index != geometry.folderIndex,
                  let slot = geometry.slots[item.id] else { continue }
            if slot.row >= geometry.bandEndRow {
                return panelHeight + (spacing.isFinite ? max(spacing, 0) : 0)
            }
        }
        return 0
    }

    // MARK: Folder panel over placements by coordinates

    /// The expansion geometry from already computed slots.
    ///
    /// Unlike ``folderPanelGeometry(items:columns:expandedFolderID:)`` it packs
    /// nothing: holes on the grid are preserved, the panel does not repack — rows
    /// below the band stay in their places (the layout shifts them down by the height of
    /// the panel).
    ///
    /// - Parameters:
    ///   - placedSlots: The slots of all elements of the set without the panel, in
    ///     display order.
    ///   - expandedFolderID: The identifier of the expanded folder.
    /// - Returns: The geometry, or `nil` if there is no folder among the slots;
    ///   `folderIndex` is the folder index in `placedSlots`.
    private static func folderPanelGeometry(
        placedSlots: [TesseraTileLayoutSlot],
        expandedFolderID: AnyHashable
    ) -> FolderPanelGeometry? {
        guard let folderIndex = placedSlots.firstIndex(where: { $0.id == expandedFolderID }) else {
            return nil
        }

        var byID: [AnyHashable: TesseraTileLayoutSlot] = [:]
        byID.reserveCapacity(placedSlots.count)
        for slot in placedSlots {
            byID[slot.id] = slot
        }

        return FolderPanelGeometry(
            slots: byID,
            bandEndRow: folderBandEndRow(for: placedSlots[folderIndex], in: placedSlots),
            folderIndex: folderIndex
        )
    }

    /// The bottom edge of the expanded folder band over a placement set.
    ///
    /// The same formula as ``folderBandEndRow(for:in:)``, but over cells rather than
    /// packing: tiles are counted with sizes shrunk to `columns`, holes are not
    /// filled.
    ///
    /// - Parameters:
    ///   - folderID: The identifier of the expanded folder.
    ///   - placements: The placement set (without the panel).
    ///   - columns: The number of columns.
    /// - Returns: The first row after the band, or `nil` if the folder is not in the set
    ///   or does not fit the grid.
    public static func folderBandEndRow(
        forFolder folderID: AnyHashable,
        in placements: [TesseraTilePlacedItem],
        columns: Int
    ) -> Int? {
        let placed = slots(placements: placements, columns: columns, unit: 1, fitting: true)
        guard let folderSlot = placed.first(where: { $0.id == folderID }) else { return nil }
        return folderBandEndRow(for: folderSlot, in: placed)
    }

    /// The panel insertion index from already computed slots.
    ///
    /// The rule is the same as for
    /// ``folderPanelInsertionIndex(items:columns:expandedFolderID:)``: the panel
    /// goes after the **last** element in the array that stays above
    /// the panel (`row < bandEnd`), but not earlier than right after the folder. The placement
    /// is not recomputed — slots are taken as is, holes are preserved.
    ///
    /// - Parameters:
    ///   - placedSlots: The slots of elements in display order, without the panel.
    ///   - expandedFolderID: The identifier of the expanded folder; `nil` means no expansion.
    /// - Returns: The index for inserting the panel, or `nil` if there is no folder
    ///   among the slots.
    public static func folderPanelInsertionIndex(
        placedSlots: [TesseraTileLayoutSlot],
        expandedFolderID: AnyHashable?
    ) -> Int? {
        guard let expandedFolderID,
              let geometry = folderPanelGeometry(
                  placedSlots: placedSlots,
                  expandedFolderID: expandedFolderID
              ) else {
            return nil
        }

        var lastIndexAbovePanel = geometry.folderIndex
        for (index, slot) in placedSlots.enumerated() where slot.row < geometry.bandEndRow {
            lastIndexAbovePanel = max(lastIndexAbovePanel, index)
        }
        return lastIndexAbovePanel + 1
    }

    /// The panel insertion index over a placement set.
    ///
    /// The element order is the order of the `placements` array. A wrapper over
    /// ``folderPanelInsertionIndex(placedSlots:expandedFolderID:)``: slots are taken
    /// with sizes shrunk to `columns`, no repacking.
    ///
    /// - Parameters:
    ///   - placements: The placement set in display order, without the panel.
    ///   - columns: The number of columns.
    ///   - expandedFolderID: The identifier of the expanded folder; `nil` means no expansion.
    /// - Returns: The index for inserting the panel, or `nil`.
    public static func folderPanelInsertionIndex(
        placements: [TesseraTilePlacedItem],
        columns: Int,
        expandedFolderID: AnyHashable?
    ) -> Int? {
        folderPanelInsertionIndex(
            placedSlots: slots(placements: placements, columns: columns, unit: 1, fitting: true),
            expandedFolderID: expandedFolderID
        )
    }

    /// The row offset under the panel from already computed slots.
    ///
    /// The semantics of ``rowsBelowOffset(items:columns:expandedFolderID:panelHeight:spacing:)``
    /// are kept: everything that **starts** from the row right after the folder band and
    /// lower goes under the panel by `panelHeight + spacing` (holes between rows
    /// stay: the panel is an insertion, not a repack). If there is nothing under the panel, `0`.
    ///
    /// - Parameters:
    ///   - placedSlots: The slots of elements in display order, without the panel.
    ///   - expandedFolderID: The identifier of the expanded folder.
    ///   - panelHeight: The panel height in points.
    ///   - spacing: The grid gap (`itemSpacing`); negative and non-finite mean 0.
    /// - Returns: `panelHeight + spacing` if there is something under the panel to shift,
    ///   otherwise `0`.
    public static func rowsBelowOffset(
        placedSlots: [TesseraTileLayoutSlot],
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat,
        spacing: CGFloat = 8
    ) -> CGFloat {
        guard panelHeight.isFinite, panelHeight > 0, let expandedFolderID,
              let geometry = folderPanelGeometry(
                  placedSlots: placedSlots,
                  expandedFolderID: expandedFolderID
              ) else {
            return 0
        }

        for (index, slot) in placedSlots.enumerated()
        where index != geometry.folderIndex && slot.row >= geometry.bandEndRow {
            return panelHeight + (spacing.isFinite ? max(spacing, 0) : 0)
        }
        return 0
    }

    /// The row offset under the panel over a placement set.
    ///
    /// A wrapper over ``rowsBelowOffset(placedSlots:expandedFolderID:panelHeight:spacing:)``.
    ///
    /// - Parameters:
    ///   - placements: The placement set in display order, without the panel.
    ///   - columns: The number of columns.
    ///   - expandedFolderID: The identifier of the expanded folder.
    ///   - panelHeight: The panel height in points.
    ///   - spacing: The grid gap (`itemSpacing`).
    /// - Returns: `panelHeight + spacing` if there is something under the panel to shift,
    ///   otherwise `0`.
    public static func rowsBelowOffset(
        placements: [TesseraTilePlacedItem],
        columns: Int,
        expandedFolderID: AnyHashable?,
        panelHeight: CGFloat,
        spacing: CGFloat = 8
    ) -> CGFloat {
        rowsBelowOffset(
            placedSlots: slots(placements: placements, columns: columns, unit: 1, fitting: true),
            expandedFolderID: expandedFolderID,
            panelHeight: panelHeight,
            spacing: spacing
        )
    }

    /// The height of the full-width expanded folder panel in points with the default gap
    /// and without pixel alignment (D17).
    ///
    /// A legacy input: the content gap is 8 pt (the default layout gap),
    /// the unit is not pixel-aligned. The grid layout computes the
    /// height with ``panelHeight(for:width:columns:spacing:scale:)`` using the
    /// actual `itemSpacing` and the screen scale.
    ///
    /// - Parameters:
    ///   - folder: The expanded folder.
    ///   - width: The full panel width in points (the grid content width).
    ///   - columns: The number of content grid columns, greater than zero.
    /// - Returns: The panel height in points; `0` for degenerate geometry.
    public static func panelHeight(
        for folder: TesseraTileFolder,
        width: CGFloat,
        columns: Int
    ) -> CGFloat {
        panelHeight(tileCount: folder.tiles.count, width: width, columns: columns)
    }

    /// The height of the full-width expanded folder panel in points (D17).
    ///
    /// The panel tiles are 1×1 tiles of the same grid: the side and gap are the unit and
    /// the desktop grid gap with pixel alignment; the formula is in
    /// ``panelHeight(tileCount:width:columns:spacing:scale:)``. The number of columns is
    /// the grid's column count (6 by default, D26).
    ///
    /// - Parameters:
    ///   - folder: The expanded folder.
    ///   - width: The full panel width in points (the grid content width).
    ///   - columns: The number of content grid columns, greater than zero.
    ///   - spacing: The grid gap (`itemSpacing`).
    ///   - scale: The screen scale; `<= 0` means no pixel alignment.
    /// - Returns: The panel height in points; `0` for degenerate geometry.
    public static func panelHeight(
        for folder: TesseraTileFolder,
        width: CGFloat,
        columns: Int,
        spacing: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        panelHeight(
            tileCount: folder.tiles.count,
            width: width,
            columns: columns,
            spacing: spacing,
            scale: scale
        )
    }
}

#endif
