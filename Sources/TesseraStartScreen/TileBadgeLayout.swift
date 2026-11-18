// Layout of the tile badge in the bottom corner (D29).
// Design document: docs/STARTSCREEN-IOS-DESIGN.md — §4 "Badge" and
// "Implementation notes and deviations" (D47); docs/W10M-STARTSCREEN.md §1.

#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif

/// The layout of the badge in the **bottom** corner of a tile at the end of the line, and the space
/// reserved for it in the title (D29).
///
/// As in Windows 10 Mobile (W10M), the badge (a capsule with a counter, or a dot) sits in the bottom-right
/// corner in LTR and in the bottom-left corner in RTL. The same calculation is used by the static
/// grid cell (``TesseraTileCell``) and the live tile (``TesseraLiveTileView``),
/// so their corners never diverge.
///
/// ## Title and badge
///
/// The tile title is pinned to the bottom, so it shares the bottom row with the badge. To keep them
/// from overlapping, the badge takes space from the title in one of two ways
/// (``Arrangement``):
/// - ``Arrangement/beside`` — the title stays in the bottom row but becomes
///   narrower by the badge width plus a gap (``titleTrailingReserve``). It is chosen
///   as long as the title keeps at least ``minimumTitleFraction`` of the content width and
///   at least ``minimumTitleWidth`` pt;
/// - ``Arrangement/above`` — on a narrow tile (1×1) the title keeps its full
///   width but rises above the badge row (``titleBottomReserve``). If the icon then
///   lacks height, the icon yields (the "text matters more" rule).
///   A small tile with an icon does not use this way (D47, below).
///
/// The way is chosen by the geometry **outside edit mode** and does not change in edit mode:
/// the title does not jump between modes when entering edit mode.
///
/// ## Small 1×1 tile with a badge: icon and badge, no title (D47)
///
/// As in W10M, on a small tile with a visible badge (a capsule or a dot) the title is not
/// drawn: the icon and the badge remain (``Arrangement/iconAndBadge``). The icon
/// is centered in the upper zone of the tile, above the badge row
/// (``smallTileIconFrame(tileSize:inset:bottomReserve:)``), and the badge is in the bottom corner
/// at the end of the line; they do not intersect, and the icon is pushed out by neither the badge nor
/// the title. In this mode the title is hidden only visually: the VoiceOver label and value
/// stay the same. The decision whether to hide the title is made by the caller
/// (``make(tileSize:badgeSize:inset:isRightToLeft:editClearance:hidesTitle:)``):
/// which knows the tile's model size (`TesseraTileSize.small`) and whether it has an icon —
/// without an icon the title stays, otherwise the tile would show nothing but the badge.
/// A small tile without a badge and the 2×2, 4×2, and 4×4 tiles are laid out as before.
///
/// ## Edit mode: avoiding the size arrow
///
/// In edit mode the size arrow sits in the same bottom corner and reaches into the tile by
/// `diameter − overhang` (``TesseraTileEditControlView/badgeClearance(forTileSize:maxDiameter:)``).
/// The badge shifts along the bottom row away from the corner by this amount plus
/// ``editGap`` (to the left in LTR, to the right in RTL), so the badge and arrow frames do not
/// intersect. This is the least intrusive solution: the badge stays visible,
/// the title in the "above" mode does not suffer, and in the "beside" mode the title narrows
/// by the same shift. If the badge does not fit to the right of the button (the "99+" capsule on a
/// 1×1 tile is already about 57 pt wide, with a large Dynamic Type), it is **hidden only while
/// in edit mode** (``isHiddenByEditControls``): lifting it up between the buttons
/// would run into the icon (D47) or push out the title of a 1×1 tile.
struct TesseraTileBadgeLayout: Equatable {

    /// How the title yields space to the badge.
    enum Arrangement: Equatable {

        /// No badge: nothing is reserved for the title.
        case none

        /// The title is in the bottom row, narrower by the badge width.
        case beside

        /// The title is above the badge row, at full width.
        case above

        /// No title: the icon is above the badge row and the badge is in the corner (D47).
        case iconAndBadge
    }

    /// The smallest icon side of a small tile with a badge, in pt: even when the badge
    /// is inflated by Dynamic Type and the upper zone lacks room, the icon does not
    /// disappear (the badge is drawn over it).
    static let minimumSmallIconSide: CGFloat = 12

    /// The largest icon side of a small tile with a badge, in pt.
    static let maximumSmallIconSide: CGFloat = 34

    /// The fraction of the tile's shorter side above which the icon of a small tile with a badge
    /// does not grow.
    static let smallIconSideFraction: CGFloat = 0.45

    /// The gap between the badge and the title, in pt.
    static let titleGap: CGFloat = 4

    /// The gap between the badge and the size arrow in edit mode, in pt.
    static let editGap: CGFloat = 2

    /// The smallest title width in the "beside" mode, in pt.
    static let minimumTitleWidth: CGFloat = 40

    /// The smallest fraction of the content width left to the title in the "beside" mode.
    static let minimumTitleFraction: CGFloat = 0.6

    /// The badge frame in tile coordinates; zero if there is no badge.
    var frame: CGRect = .zero

    /// The way the title avoids the badge.
    var arrangement: Arrangement = .none

    /// Whether the badge is hidden in edit mode because it does not fit next to
    /// the size arrow.
    var isHiddenByEditControls = false

    /// The width the title gives to the badge at the end-of-line side ("beside"
    /// mode), in pt.
    var titleTrailingReserve: CGFloat = 0

    /// The height of the bottom row the title gives to the badge ("above" mode), in pt.
    var titleBottomReserve: CGFloat = 0

    /// The height of the badge's bottom row with a gap that the icon of a small tile
    /// leaves to the badge (D47), in pt. Always computed when there is a badge: the decision
    /// whether to show the icon instead of the title is made by the caller (for a live
    /// tile it depends on the icon of the particular face).
    var iconBottomReserve: CGFloat = 0

    /// Computes the layout.
    ///
    /// - Parameters:
    ///   - tileSize: The tile size.
    ///   - badgeSize: The intrinsic badge size (`.zero` means no badge).
    ///   - inset: The tile inset: the badge offset from the bottom and side edges and
    ///     the title margin.
    ///   - isRightToLeft: The reading direction.
    ///   - editClearance: How much of the bottom corner at the end of the line is taken by the size arrow
    ///     inside the tile; `0` outside edit mode or when there is no arrow.
    ///   - hidesTitle: `true` for a small tile with an icon: there is no title, and nothing
    ///     is reserved for it (``Arrangement/iconAndBadge``, D47). Without a
    ///     badge the flag changes nothing.
    /// - Returns: The badge frame and the title reserve.
    static func make(
        tileSize: CGSize,
        badgeSize: CGSize,
        inset: CGFloat,
        isRightToLeft: Bool,
        editClearance: CGFloat,
        hidesTitle: Bool = false
    ) -> TesseraTileBadgeLayout {
        guard badgeSize.width > 0, badgeSize.height > 0,
              tileSize.width > 0, tileSize.height > 0 else {
            return TesseraTileBadgeLayout()
        }

        let width = tileSize.width
        let contentWidth = max(0, width - inset * 2)
        let normalY = tileSize.height - inset - badgeSize.height

        // The position outside edit mode: at the edge with the inset `inset`; a badge that is too wide
        // is pressed to the margin instead of sticking out of the tile.
        func originX(margin: CGFloat) -> CGFloat {
            isRightToLeft ? margin : width - margin - badgeSize.width
        }
        func fits(_ x: CGFloat) -> Bool {
            x >= inset - 0.001 && x + badgeSize.width <= width - inset + 0.001
        }
        let normalX = max(inset, min(originX(margin: inset), width - inset - badgeSize.width))

        var layout = TesseraTileBadgeLayout()
        var x = normalX
        var trailingMargin = inset

        if editClearance > 0 {
            let margin = max(inset, editClearance + editGap)
            let shiftedX = originX(margin: margin)
            if fits(shiftedX) {
                x = shiftedX
                trailingMargin = margin
            } else {
                // Does not fit to the right of the arrow: while in edit mode the badge is hidden, and
                // the title reserves space as outside edit mode.
                layout.isHiddenByEditControls = true
            }
        }
        layout.frame = CGRect(x: x, y: normalY, width: badgeSize.width, height: badgeSize.height)
        layout.iconBottomReserve = badgeSize.height + titleGap

        // D47: a small tile with an icon has no title and no reserve either.
        if hidesTitle {
            layout.arrangement = .iconAndBadge
            return layout
        }

        // The way is decided by the geometry outside edit mode (the title does not jump).
        let normalReserve = badgeSize.width + titleGap
        let besideWidth = contentWidth - normalReserve
        let threshold = max(minimumTitleWidth, contentWidth * minimumTitleFraction)
        if besideWidth >= threshold {
            layout.arrangement = .beside
            layout.titleTrailingReserve = (trailingMargin - inset) + normalReserve
        } else {
            layout.arrangement = .above
            layout.titleBottomReserve = badgeSize.height + titleGap
        }
        return layout
    }

    /// The icon frame of a small tile with a badge (D47).
    ///
    /// The icon is centered in the **upper zone**: from the top margin to the gap above the
    /// badge row. The zone does not depend on the badge side or on edit mode, so in RTL
    /// and when the badge shifts away from the size arrow the icon stays in place, and the unpin
    /// button (the top corner at the end of the line) does not reach it. The side is
    /// the zone height, but no more than ``smallIconSideFraction`` of the tile's shorter side,
    /// ``maximumSmallIconSide``, the content width, and the width between the edit buttons
    /// (the icon does not go under the unpin button even in edit mode); and no less than
    /// ``minimumSmallIconSide``: with a large Dynamic Type the badge goes over the
    /// icon, but the icon stays.
    ///
    /// - Parameters:
    ///   - tileSize: The tile size.
    ///   - inset: The tile inset.
    ///   - bottomReserve: The ``iconBottomReserve`` of the badge layout.
    /// - Returns: The icon frame in tile coordinates.
    static func smallTileIconFrame(
        tileSize: CGSize,
        inset: CGFloat,
        bottomReserve: CGFloat
    ) -> CGRect {
        let zoneHeight = max(0, tileSize.height - inset * 2 - bottomReserve)
        let contentWidth = max(0, tileSize.width - inset * 2)
        // The icon is centered and in edit mode must not run onto the unpin button
        // in the top corner: it reaches into the tile by `diameter − overhang`
        // (for a small tile the diameter is the minimum). The reserve is always taken, not
        // only in edit mode, so that the icon does not jump when entering edit mode.
        let buttonReserve = TesseraTileEditControlView.minimumDiameter
            - TesseraTileEditControlView.cornerOverhang
        let limit = min(
            zoneHeight,
            min(tileSize.width, tileSize.height) * smallIconSideFraction,
            maximumSmallIconSide,
            contentWidth,
            tileSize.width - 2 * buttonReserve - 1
        )
        let side = max(minimumSmallIconSide, floor(limit))
        let x = ((tileSize.width - side) / 2).rounded()
        let y = inset + max(0, ((zoneHeight - side) / 2).rounded())
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
