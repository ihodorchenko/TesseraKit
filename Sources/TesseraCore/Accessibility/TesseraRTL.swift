import UIKit

/// Normalizes pager progress by reading direction (LTR/RTL).
///
/// Per the contract in `docs/CORE-IOS-DESIGN.md`: in RTL, `t` is normalized by the
/// reading direction. The raw `t = contentOffset.x / pageWidth` grows against the
/// reading direction in RTL, so it must not be handed to consumers directly. After normalization,
/// `0` is the first page in reading order and `pageCount - 1` is the last; the Pivot
/// indicator, the Panorama headers, and the StartScreen pager share the same
/// knowledge of direction and do not duplicate mirroring themselves.
///
/// The functions are pure: they read no state, do not write `contentOffset` (only the pager
/// and the controller write it), and do not require the main thread, so they
/// are suitable for contract tests.
public enum TesseraRTL {

    /// Converts the pager's raw progress into progress in reading direction.
    ///
    /// - LTR: `t` is returned unchanged.
    /// - RTL: `CGFloat(pageCount - 1) - t`, which mirrors around the middle of the
    ///   strip so that the edge pages swap places while the fractional part
    ///   (the continuous transition progress) is preserved.
    /// - `pageCount <= 1`: `t` is returned unchanged, because there is nothing to normalize and
    ///   the only page is always both "first" and "last".
    ///
    /// The function is continuous and does not round `t`: it is used for animations
    /// (`frame`/`transform`/`alpha`). For a discrete page index, use
    /// ``pageIndex(for:pageCount:layoutDirection:)``, which has a different rounding
    /// rule; see that method's documentation.
    ///
    /// - Parameters:
    ///   - t: The raw progress `contentOffset.x / pageWidth`.
    ///   - pageCount: The number of pages; values `<= 1` are treated as "no normalization
    ///     needed".
    ///   - layoutDirection: The interface layout direction.
    /// - Returns: The progress in reading direction.
    public static func normalizedProgress(
        _ t: CGFloat,
        pageCount: Int,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGFloat {
        guard pageCount > 1 else { return t }
        guard layoutDirection == .rightToLeft else { return t }

        return CGFloat(pageCount - 1) - t
    }

    /// The page index for raw progress `t`, taking the reading direction into account.
    ///
    /// Rule ("the integer part is the index", see `docs/CORE-IOS-DESIGN.md`):
    /// - LTR: `clamp(Int(t.rounded(.down)), 0, pageCount - 1)`.
    /// - RTL: `pageCount - 1 - <the same clamp>`: the index of the page
    ///   occupying the visible area is taken first, then mirrored into reading order.
    /// - `pageCount <= 1`: always `0`.
    ///
    /// Rounding happens before mirroring on purpose: the index is the page that
    /// is currently in frame, not the entry progress of the next one. For fractional `t` this gives
    /// `pageCount - 1 - floor(t)`, which in the middle of a transition differs by one from
    /// `floor(normalizedProgress(t))`; continuous animations should use
    /// ``normalizedProgress(_:pageCount:layoutDirection:)``, not this method.
    ///
    /// Defensive cases: `NaN` gives `0` (undefined progress is treated as the
    /// first page); infinities are clamped to the bounds, so
    /// `Int(_:)` cannot overflow on garbage intermediate values.
    ///
    /// - Parameters:
    ///   - t: The raw progress `contentOffset.x / pageWidth`.
    ///   - pageCount: The number of pages; values `<= 1` give `0`.
    ///   - layoutDirection: The interface layout direction.
    /// - Returns: The page index in reading order.
    public static func pageIndex(
        for t: CGFloat,
        pageCount: Int,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Int {
        guard pageCount > 1 else { return 0 }

        let index = clampedIndex(for: t, pageCount: pageCount)
        guard layoutDirection == .rightToLeft else { return index }

        return pageCount - 1 - index
    }

    /// The discrete page index in raw content coordinates (LTR order).
    ///
    /// Clamps the result to `0...pageCount - 1` before converting to `Int`, so
    /// infinities and very large `t` values do not cause overflow.
    ///
    /// - Parameters:
    ///   - t: The raw progress.
    ///   - pageCount: The number of pages, strictly greater than one (checked by the caller).
    /// - Returns: The index in `0...pageCount - 1`.
    private static func clampedIndex(for t: CGFloat, pageCount: Int) -> Int {
        guard !t.isNaN else { return 0 }

        let upperBound = CGFloat(pageCount - 1)
        let clamped = min(max(t.rounded(.down), 0), upperBound)

        return Int(clamped)
    }
}
