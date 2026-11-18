// Coordinates of a top-level element of the start screen grid (D30–D33).
//
// Design document: docs/STARTSCREEN-IOS-DESIGN.md §3 (tile grid; persistence of
// TesseraTileStore) and decisions D30–D33 in docs/DECISIONS.md.

import Foundation

/// The explicit cell of a top-level element (a tile or a folder) on the grid canvas
/// (D30).
///
/// Coordinates are in **units** and **logical**: `column == 0` is the start of reading
/// (in RTL that is the right edge; only the view layer mirrors, see document §9), `row == 0` is
/// the top row. The cell is the element's top-left corner; its footprint on the
/// canvas is determined by its size (D15; on a narrow grid it is adjusted by
/// ``TesseraTileLayoutEngine/fittingSize(_:columns:)``).
///
/// The value is stored in `tiles.json` (schema version 2) together with the canvas width;
/// for the width see ``TesseraTileStore/canvasColumns``.
public struct TesseraTileGridPlacement: Equatable, Hashable, Codable, Sendable {

    /// Row of the top-left corner (zero-based, top to bottom).
    public var row: Int

    /// Column of the top-left corner (zero-based, in reading direction).
    public var column: Int

    /// Creates a cell.
    ///
    /// - Parameters:
    ///   - row: Row of the top-left corner.
    ///   - column: Column of the top-left corner.
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Reading order: by row first, then by column.
    ///
    /// - Parameters:
    ///   - lhs: The first cell.
    ///   - rhs: The second cell.
    /// - Returns: `true` if `lhs` is read before `rhs`.
    public static func isReadingOrdered(_ lhs: TesseraTileGridPlacement, before rhs: TesseraTileGridPlacement) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }
}
