// The model of a start screen tile (Start Screen).
// Design document: docs/STARTSCREEN-IOS-DESIGN.md — §3 (tile grid)
// (layout model, unit coordinates) and §14 (MVP clarifications)
// (D12/D15: a tile is just an action with no `type` field; four tile sizes).
// D14 (folders and the approval function) is described in docs/STATE.md; the folder model is
// in TesseraTileFolder.swift, folder operations are in TesseraTileStore.

#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif

/// The size of a tile on the start screen grid, in units
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, §14; D15 in docs/STATE.md).
///
/// Sizes are given as "columns × rows" pairs:
/// - ``small`` — 1×1,
/// - ``medium`` — 2×2,
/// - ``wide`` — 4×2,
/// - ``large`` — 4×4.
///
/// The values are sizes in units, not in points: the grid is recomputed
/// for any screen width, and tile positions are stored in unit coordinates
/// (document §3, "Layout model"). The `String` raw value is used by the
/// persistence of `TesseraTileStore`. The declaration order of the cases is the "ascending"
/// order (`CaseIterable`) and is **not** the order of the size cycle on a tap on the size
/// arrow: the cycle is set explicitly in ``cycleOrder`` (D28).
public enum TesseraTileSize: String, CaseIterable, Codable, Hashable {
    /// 1×1 unit.
    case small

    /// 2×2 units; the default size of a tile (D12).
    case medium

    /// 4×2 units: a "wide" tile.
    case wide

    /// 4×4 units: a "large" tile.
    case large

    /// The order of the size cycle on a tap on the size arrow (D28):
    /// small → wide → medium → large → small.
    ///
    /// This is the Windows 10 Mobile order (small → wide → medium), with
    /// ``large`` appended at the end (the set of four sizes is D15). It is set explicitly and is not taken
    /// from `allCases`: nobody chose the declaration order ("ascending") for the
    /// cycle. The storage format is unaffected — the size itself is persisted.
    static let cycleOrder: [TesseraTileSize] = [.small, .wide, .medium, .large]

    /// The next size in the cycle among the supported ones (D28).
    ///
    /// Starting from the position of the current size in ``cycleOrder``, it goes forward, wrapping around, and
    /// takes the first size from `supported`; unsupported sizes are skipped.
    /// The order of the `supported` list itself does not affect the result (the host sets
    /// a set, not an order). The current size need not be in `supported`
    /// (the host may have excluded it): then the nearest supported size
    /// further along the cycle is taken. If only the current size itself is supported, the cycle
    /// closes on it; if the set is empty, the current size is returned as well.
    ///
    /// - Parameter supported: The sizes supported for the element.
    /// - Returns: The next size; equal to `self` when there is nothing to change.
    func next(among supported: [TesseraTileSize]) -> TesseraTileSize {
        let order = TesseraTileSize.cycleOrder
        guard let start = order.firstIndex(of: self) else { return self }
        for offset in 1...order.count {
            let candidate = order[(start + offset) % order.count]
            if supported.contains(candidate) {
                return candidate
            }
        }
        return self
    }

    /// The tile size in units: the width is the number of columns, the height is the number of rows.
    ///
    /// For all cases `width` and `height` are positive integers;
    /// the layout engine uses them as integers (`unitColumns`/`unitRows`).
    public var unitSize: CGSize {
        switch self {
        case .small:
            return CGSize(width: 1, height: 1)
        case .medium:
            return CGSize(width: 2, height: 2)
        case .wide:
            return CGSize(width: 4, height: 2)
        case .large:
            return CGSize(width: 4, height: 4)
        }
    }

    /// The tile width in units (the number of grid columns).
    public var unitColumns: Int {
        Int(unitSize.width)
    }

    /// The tile height in units (the number of grid rows).
    public var unitRows: Int {
        Int(unitSize.height)
    }
}

/// An attention badge on a tile: a red dot or a counter
/// (docs/STARTSCREEN-IOS-DESIGN.md §14; D12 in docs/STATE.md).
///
/// The badge is not part of the live flip: it is a separate element in a tile corner
/// (document §4, "Badge"). The model stores the intent, while the appearance and the
/// VoiceOver announcement are built by the component.
public enum TesseraTileBadge: Equatable, Hashable {
    /// No badge.
    case none

    /// A red dot without a number: "there is something new".
    case dot

    /// An attention counter. A non-positive value is not shown:
    /// see ``isVisible``.
    case count(Int)

    /// Whether the badge should be shown visually.
    ///
    /// `.count(0)` and negative counters are treated as no badge:
    /// this way the model does not require the view to re-check the sign and does not show
    /// an empty red dot. `.dot` and a positive counter are visible.
    public var isVisible: Bool {
        switch self {
        case .none:
            return false
        case .dot:
            return true
        case let .count(value):
            return value > 0
        }
    }

    /// The `accessibilityValue` for VoiceOver (D34).
    ///
    /// A positive counter is announced as a number; a dot without a number is announced as a
    /// localized "has a notification" string (otherwise a blind user
    /// would not learn that a notification exists); `.none` and a non-positive counter give
    /// `nil`. A single source for the grid cell, the folder panel tile, and
    /// ``TesseraLiveTileView``.
    var accessibilityValueText: String? {
        switch self {
        case let .count(value) where value > 0:
            return String(value)
        case .dot:
            return TesseraStartScreenStrings.string(.a11yBadgeDot)
        case .none, .count:
            return nil
        }
    }
}

#if canImport(UIKit)

/// A start screen tile is just an action on a tile
/// (docs/STARTSCREEN-IOS-DESIGN.md §3, §14; D12 in docs/STATE.md).
///
/// A tile has **no** `type` field: grouping by app type is not
/// used. A tile is described by an identifier, a title, an icon,
/// an action, a badge, a tile size, and an optional live content
/// source. The action is the only behavior: a tap on the tile calls
/// ``action``, while transitions, opening folders, and other navigation are left to the host.
///
/// The model is a plain value (`struct`): `TesseraTileStore` stores an array of tiles and
/// replaces/mutates their copies without turning the component into a source of global
/// state. Live content (flips, stagger, pauses) is the job of `LiveTileEngine`
/// (document §4): a tile carries a reference to the provider
/// (``liveContent``), and the grid hands it to the engine when a cell is shown.
public struct TesseraTileDescriptor {
    /// A stable tile identifier.
    ///
    /// Must be unique within the start screen: `TesseraTileStore` uses it
    /// to find the tile for resize, unpin, and folder operations (D14). Behavior with
    /// duplicate identifiers is undefined.
    public let id: AnyHashable

    /// The tile title — the static tile caption (document §9, "A tile is
    /// a single element").
    ///
    /// For a live tile the accessibility label is built from the
    /// ``liveContent`` provider (`frontFace.title` + `detail`), because
    /// VoiceOver must read the visible front face; `title` remains the
    /// tile caption and the fallback for an empty front.
    public var title: String

    /// The tile icon. `nil` is allowed: the tile shows a placeholder or only the caption.
    public var icon: UIImage?

    /// The tap action. Called by the component on the main thread.
    ///
    /// The closure is part of the tile's identity and is not replaced on resize;
    /// to change the behavior, the host creates a new ``TesseraTileDescriptor``.
    public let action: () -> Void

    /// The attention badge — a red dot or a counter (D12). `.none` by default.
    public var badge: TesseraTileBadge

    /// The tile size in units (D15). `.medium` by default.
    public var size: TesseraTileSize

    /// The live content source of the tile (§4, "Content model"; D15).
    ///
    /// `nil` means a static tile: the grid draws the icon, the title, and the badge as
    /// before. If a provider is set, the grid cell shows
    /// ``TesseraLiveTileView`` and hands the content to ``TesseraLiveTileEngine``:
    /// the engine reads the faces itself, schedules flips with a stagger, and pauses them
    /// off screen, in the background, and under Reduce Motion.
    ///
    /// - Note: The provider is a runtime reference, like ``action``: `TesseraTileStore` does not
    ///   serialize it and does not compare tiles by this field. The host passes the
    ///   provider when registering the catalog together with the action and the icon.
    public var liveContent: TesseraLiveTileContentProvider?

    /// Creates a start screen tile.
    ///
    /// - Parameters:
    ///   - id: A unique tile identifier within the start screen.
    ///   - title: The tile title.
    ///   - icon: The icon; `nil` means no icon.
    ///   - action: The tap action; called on the main thread.
    ///   - badge: The attention badge; `.none` by default.
    ///   - size: The tile size; `.medium` by default (D12).
    ///   - liveContent: The live content provider; `nil` by default —
    ///     a static tile (D15).
    public init(
        id: AnyHashable,
        title: String,
        icon: UIImage? = nil,
        action: @escaping () -> Void,
        badge: TesseraTileBadge = .none,
        size: TesseraTileSize = .medium,
        liveContent: TesseraLiveTileContentProvider? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.action = action
        self.badge = badge
        self.size = size
        self.liveContent = liveContent
    }
}

#endif
