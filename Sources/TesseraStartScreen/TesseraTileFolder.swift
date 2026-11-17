// The model of a start screen folder (Start Screen).
// Design document: docs/STARTSCREEN-IOS-DESIGN.md — §3 (tile grid)
// (a folder is a grid element) and §14 (MVP clarifications)
// (D12: action tiles; D14: folder operations go only through the host
// approval function, see docs/STATE.md). Folder mutations (creation, adding
// a tile, moving between folders) are performed by `TesseraTileStore`, not by this model.

#if canImport(UIKit)
import UIKit

/// A start screen folder: a container of tiles that is itself an element of
/// the tile grid (docs/STARTSCREEN-IOS-DESIGN.md §3, §14; D14).
///
/// A folder is not a tile and carries no action: a tap on a folder opens its
/// contents, and the host handles navigation and expansion. Therefore the model has no
/// `action` and no `type` field — only identity, title, preview icon,
/// members, and the tile size on the grid.
///
/// The default size is ``TesseraTileSize/medium`` (2×2 units): a folder takes
/// a standard medium tile. The model also allows the other sizes from D15;
/// which sizes a folder may take is decided by `TesseraTileStore` and the host.
///
/// - Note: A folder never holds 0 or 1 tiles (D45): when one tile is left in it,
///   `TesseraTileStore` dissolves it, and the tile takes the folder's cell with its own
///   size. The exception is the transitional folder `TesseraTileStore.createFolder(withTile:title:columns:)`
///   before `addToFolder`.
///
/// - Note: Nested folders are not supported: `tiles` contains only tiles
///   (``TesseraTileDescriptor``). Folder creation, adding a tile, and moving
///   between folders go through the host approval function (D14).
public struct TesseraTileFolder {
    /// A stable folder identifier; unique within the start screen.
    ///
    /// `TesseraTileStore` uses it to address the folder when adding a tile and moving
    /// between folders (D14).
    public let id: AnyHashable

    /// The folder title (the tile caption and the accessibility label).
    public var title: String

    /// The folder preview icon. `nil` is allowed: the component shows a preview built from
    /// the contents or a placeholder.
    public var icon: UIImage?

    /// The tiles inside the folder, in display order.
    public var tiles: [TesseraTileDescriptor]

    /// The folder size as a grid element. `.medium` (2×2 units) by default.
    public var size: TesseraTileSize

    /// Creates a start screen folder.
    ///
    /// - Parameters:
    ///   - id: A unique folder identifier within the start screen.
    ///   - title: The folder title.
    ///   - icon: The preview icon; `nil` means no icon.
    ///   - tiles: The tiles inside the folder; empty by default.
    ///   - size: The folder size on the grid; `.medium` by default.
    public init(
        id: AnyHashable,
        title: String,
        icon: UIImage? = nil,
        tiles: [TesseraTileDescriptor] = [],
        size: TesseraTileSize = .medium
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tiles = tiles
        self.size = size
    }
}

// MARK: - Folder badge (D44)

extension TesseraTileFolder {

    /// The folder tile badge: the sum of the numeric badges of the member tiles (D44).
    ///
    /// Windows 10 Mobile does not describe a folder badge (§6.3): this is a library decision. The rule:
    /// - all `.count(n)` with `n > 0` are summed; the result is `.count(sum)`, and
    ///   "99+" for a sum above 99 is drawn by the badge itself (as for a tile);
    /// - if there are no positive counters but some tile has a `.dot`, the folder
    ///   shows `.dot`; a counter outranks a dot (a dot and a counter together give a
    ///   counter);
    /// - `.none`, `.count(0)`, and negative counters are ignored; if no
    ///   tile has a visible badge, the result is `.none`.
    ///
    /// Computed once when a snapshot is applied to a cell, not per frame
    /// (no per-frame work, see AGENTS.md). The sum saturates at `Int.max` instead of overflowing.
    /// There are no invisible members (outside the catalog) in ``tiles``: `TesseraTileStore` cleans the folder
    /// against the catalog (D45), so the helper does not look at them.
    ///
    /// - Parameter members: The folder's tiles.
    /// - Returns: The folder tile badge.
    static func aggregateBadge(of members: [TesseraTileDescriptor]) -> TesseraTileBadge {
        var sum = 0
        var hasDot = false
        for member in members {
            switch member.badge {
            case let .count(value) where value > 0:
                let (total, overflow) = sum.addingReportingOverflow(value)
                sum = overflow ? Int.max : total
            case .dot:
                hasDot = true
            case .none, .count:
                break
            }
        }
        if sum > 0 { return .count(sum) }
        return hasDot ? .dot : .none
    }

    /// The badge of this folder's tile (``aggregateBadge(of:)`` over ``tiles``).
    var aggregateBadge: TesseraTileBadge {
        TesseraTileFolder.aggregateBadge(of: tiles)
    }
}

// MARK: - Title rules (D35)

extension TesseraTileFolder {

    /// The maximum folder title length in characters (D35).
    ///
    /// Windows 10 Mobile (§6.7) has no character limit — the title is truncated to
    /// the header width, on a single line. The 64-character limit protects the layout
    /// (the panel header, the tile caption, the state file) and is not a product
    /// rule: in practice a title is always shorter than the header width and is truncated
    /// with an ellipsis. Characters (`Character`) are counted, not bytes or UTF-16 units.
    public static let maximumTitleLength = 64

    /// Normalizes the entered title to the form in which `TesseraTileStore` stores it.
    ///
    /// Line breaks inside the title are replaced with spaces (a title is a single
    /// line), leading and trailing whitespace and line breaks are dropped, the string
    /// is truncated to ``maximumTitleLength`` characters, and after truncation the edges
    /// are trimmed once more. An empty result means "use the default title" —
    /// the substitution is done by the caller (`TesseraTileStore` and the editor: they
    /// have different sources of the default).
    ///
    /// - Parameter raw: The string entered by the user.
    /// - Returns: The normalized title; empty if the input is empty or consisted
    ///   of whitespace only.
    static func normalizedTitle(_ raw: String) -> String {
        let singleLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(maximumTitleLength))
        return capped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
