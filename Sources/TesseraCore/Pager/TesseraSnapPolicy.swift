//
//  TesseraSnapPolicy.swift
//  TesseraCore
//
//  Configuration and computation of custom snapping for non-full-page pages (peek).
//  Design document: docs/CORE-IOS-DESIGN.md (conceptual API surface:
//  TesseraSnapPolicy is the snapping configuration) and the `snapping` pager mode
//  (the two pager modes:
//  page width != screen width, `decelerationRate = .fast`,
//  nearest center + velocity threshold).
//

import CoreGraphics

/// The alignment to which snapping brings a page.
///
/// The modes differ in the formula for the "nearest" index (see
/// `TesseraSnapPolicy.targetContentOffset(proposedOffset:velocity:itemWidth:pageCount:startOffset:)`),
/// not in the sign of the resulting offset: the policy returns the offset of the page start.
public enum TesseraSnapAlignment {
    /// Align to the leading edge: index = `floor(offset / itemWidth + 0.5)`.
    case leading
    /// Align to the center: index = `round(offset / itemWidth)`.
    case center
}

/// The snapping policy for the `snapping` mode: a velocity threshold and an alignment.
///
/// A pure configuration struct with no UIKit dependencies: the computation of
/// `targetContentOffset` is deterministic and fully testable without a scroll view.
/// The consumer (a pager in `snapping` mode or `TesseraPanoScrollView`) calls
/// `targetContentOffset(...)` from
/// `UIScrollViewDelegate.scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)`,
/// passing `proposedOffset` from the `inout` pointer parameter, `velocity`
/// converted from UIKit's points/ms to pt/s (`× 1000`), and the gesture's start
/// offset from `scrollViewWillBeginDragging`.
///
/// In `snapping` mode the consumer additionally sets
/// `decelerationRate = .fast`; that is its responsibility, and the policy does not control deceleration.
///
/// All values are in the scroll view's content coordinates (points), ignoring
/// `contentInset`. If the consumer uses an inset or viewport offset for centering,
/// converting to these coordinates is its job: the signature intentionally
/// does not take the viewport width, so the policy remains a single formula.
public struct TesseraSnapPolicy {
    /// The swipe velocity threshold in pt/s: a swipe faster than the threshold moves to the neighboring
    /// section, a slower one stays on the nearest. Defaults to 600 pt/s.
    ///
    /// Expected to be non-negative; a negative value is normalized to zero
    /// so that zero velocity is never treated as a "fast swipe".
    public var velocityThreshold: CGFloat

    /// The section alignment. Defaults to `.center`.
    public var alignment: TesseraSnapAlignment

    /// - Parameters:
    ///   - velocityThreshold: The velocity threshold in pt/s, 600 by default.
    ///   - alignment: The alignment, `.center` by default.
    public init(velocityThreshold: CGFloat = 600, alignment: TesseraSnapAlignment = .center) {
        self.velocityThreshold = velocityThreshold
        self.alignment = alignment
    }

    /// Returns the offset the scroll view should settle on after a gesture.
    ///
    /// Algorithm:
    /// 1. Degenerate input (`itemWidth <= 0` or `pageCount <= 0`): return
    ///    `proposedOffset` unchanged (there is nothing to snap to).
    /// 2. The nearest index `nearest` relative to `proposedOffset`:
    ///    - `.center`:  `nearest = round(proposedOffset / itemWidth)`;
    ///    - `.leading`: `nearest = floor(proposedOffset / itemWidth + 0.5)`.
    /// 3. If `|velocity| > velocityThreshold`, step one section in the direction of the
    ///    velocity sign (`velocity > 0` gives `+1`, `velocity < 0` gives `-1`) from the reference
    ///    index: the section where the gesture began (the one nearest to `startOffset`
    ///    by the same alignment formula), or, if `startOffset` is not provided,
    ///    from `nearest`. Otherwise use `nearest`.
    /// 4. The result is `index * itemWidth`, clamped to `[0, (pageCount - 1) * itemWidth]`.
    ///
    /// Anchoring on the start section is needed because `proposedOffset` of a fast
    /// flick already includes inertia: stepping from `nearest(proposed)` would skip
    /// a section. With `startOffset`, one gesture moves by at most one
    /// section from the start (Windows Phone behavior), and a slow gesture (below the threshold)
    /// stays on the section nearest to `proposedOffset`.
    ///
    /// The velocity sign follows the `UIScrollView` convention: positive velocity
    /// increases `contentOffset.x` (in LTR that is the next section; in RTL the consumer
    /// normalizes coordinates by the reading direction, see the progress invariant in docs/CORE-IOS-DESIGN.md).
    ///
    /// - Important: `UIScrollViewDelegate.scrollViewWillEndDragging` reports
    ///   velocity in **points/ms**; the consumer must convert it to pt/s
    ///   (`× 1000`) before the call, because ``velocityThreshold`` is in pt/s.
    ///
    /// The `.center` and `.leading` formulas coincide for a non-negative
    /// `proposedOffset` (round to nearest, halves round up) but
    /// diverge for negative values (`round(-0.5) == -1`,
    /// `floor(0) == 0`); such an index is then clamped to zero. The separate formulas
    /// are kept so that the contract stays correct with shifted coordinates
    /// (insets, a non-negative origin).
    ///
    /// - Parameters:
    ///   - proposedOffset: The offset proposed by the system (usually
    ///     `targetContentOffset.pointee`).
    ///   - velocity: The gesture's horizontal velocity in pt/s (signed).
    ///   - itemWidth: The width of one section (the snapping step) in pt.
    ///   - pageCount: The number of sections.
    ///   - startOffset: `contentOffset.x` at the start of the gesture (usually saved in
    ///     `scrollViewWillBeginDragging`); `nil` or a non-finite value means
    ///     anchoring on `nearest(proposedOffset)`, as before the parameter existed.
    /// - Returns: The clamped target offset; for degenerate input,
    ///   `proposedOffset` as is.
    public func targetContentOffset(proposedOffset: CGFloat,
                                    velocity: CGFloat,
                                    itemWidth: CGFloat,
                                    pageCount: Int,
                                    startOffset: CGFloat? = nil) -> CGFloat {
        // Degenerate geometry: snapping is impossible, return the system's proposal.
        guard itemWidth > 0, pageCount > 0 else { return proposedOffset }

        let nearestIndex = self.nearestIndex(for: proposedOffset, itemWidth: itemWidth)
        let threshold = max(velocityThreshold, 0)

        let targetIndex: CGFloat
        if abs(velocity) > threshold {
            // Fast swipe: step one section in the direction of motion from the gesture's
            // start section (without it, from the one nearest to the proposed offset).
            let baseIndex: CGFloat
            if let startOffset, startOffset.isFinite {
                baseIndex = self.nearestIndex(for: startOffset, itemWidth: itemWidth)
            } else {
                baseIndex = nearestIndex
            }
            targetIndex = velocity > 0 ? baseIndex + 1 : baseIndex - 1
        } else {
            // Slow gesture or hold: stay on the nearest section.
            targetIndex = nearestIndex
        }

        // Equivalent to clamping the index to [0, pageCount - 1], but in offset coordinates.
        let lowerBound: CGFloat = 0
        let upperBound = CGFloat(pageCount - 1) * itemWidth
        return min(max(targetIndex * itemWidth, lowerBound), upperBound)
    }

    /// The nearest section index by the document's formulas (the two pager modes).
    private func nearestIndex(for proposedOffset: CGFloat, itemWidth: CGFloat) -> CGFloat {
        let position = proposedOffset / itemWidth
        switch alignment {
        case .center:
            // round(proposedOffset / itemWidth): round to nearest,
            // halves go away from zero (the standard Swift rule).
            return position.rounded()
        case .leading:
            // floor(proposedOffset / itemWidth + 0.5): halves always round up.
            return (position + 0.5).rounded(.down)
        }
    }
}
